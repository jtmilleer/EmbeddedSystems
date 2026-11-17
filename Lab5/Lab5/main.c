/*
 * Lab5.c
 *
 * Remotely controlled ADC/DAC interface. This file currently implements
 * the RS232 command protocol only (9600 8N1):
 *
 *   G          single ADC measurement
 *   M,n,dt     n measurements (2-20), dt seconds apart (1-10)
 *   S,c,v      set DAC channel c (0 or 1) to v volts, format "n.nn"
 *
 * Commands end with CR and/or LF (Serial Monitor line ending setting).
 * G reads the ADC on A0. S drives a MAX518 DAC over I2C (A4/A5). M is
 * still a stub.
 *
 * Created: 11/9/2026 7:53:59 AM
 * Author : jtmil
 */

#ifndef F_CPU
#define F_CPU 16000000UL
#endif

#include <avr/io.h>
#include <avr/interrupt.h>
#include <stdio.h>
#include <stdint.h>

#include "uart.h"       /* avr-uart by Andy Gock, based on Peter Fleury's library */
#include "i2cmaster.h"  /* Peter Fleury's I2C master library (twimaster.c) */

#define BAUD        9600

#define LINE_MAX    32

#define M_N_MIN     2
#define M_N_MAX     20
#define M_DT_MIN    1
#define M_DT_MAX    10
#define DAC_CH_MAX  1
#define DAC_V_MAX   500     /* max output voltage in hundredths of a volt */

#define VREF_MV     5000UL  /* AVcc reference, in millivolts */
#define ADC_STEPS   1024UL  /* 10-bit ADC */

/*
 * MAX518 slave address is 0 1 0 1 1 AD1 AD0. AD1 and AD0 are tied to GND,
 * so the 7-bit address is 0x2C. The I2C library takes it shifted left with
 * the R/W bit in bit 0.
 */
#define MAX518_ADDR (0x2C << 1)
#define DAC_STEPS   256UL   /* 8-bit DAC, VOUT = VDD * N / 256 */
#define DAC_CODE_MAX 255
#define DAC_VREF_CV 500UL   /* MAX518 reference is VDD (5.00 V), in centivolts */


/* UART (the library's interrupt-driven ring buffers do the actual I/O) */

/* Blocks until the library's receive buffer has a byte. */
static char uart_getc_blocking(void)
{
    uint16_t c;

    do {
        c = uart_getc();
    } while (c & UART_NO_DATA);

    return (char)c;
}

static int uart_stream_put(char c, FILE *stream)
{
    (void)stream;
    if (c == '\n')
        uart_putc('\r');
    uart_putc(c);
    return 0;
}

static FILE uart_out = FDEV_SETUP_STREAM(uart_stream_put, NULL, _FDEV_SETUP_WRITE);

/*
 * Reads one line into buf, without the line ending. Blank lines are
 * skipped so a CR+LF ending doesn't produce an empty command. Characters
 * past the buffer size are dropped, and the line is flagged as too long.
 * Returns 1 if the line fit, 0 if it overflowed.
 */
static uint8_t uart_getline(char *buf, uint8_t size)
{
    uint8_t len = 0;
    uint8_t overflow = 0;

    for (;;) {
        char c = uart_getc_blocking();

        if (c == '\r' || c == '\n') {
            if (len == 0 && !overflow)
                continue;
            buf[len] = '\0';
            return !overflow;
        }

        if (len < size - 1)
            buf[len++] = c;
        else
            overflow = 1;
    }
}


/* Parsing helpers */

/*
 * Parses an unsigned decimal integer starting at *p and advances *p past
 * it. Returns 0 if there are no digits or the value doesn't fit in 16 bits.
 */
static uint8_t parse_uint(const char **p, uint16_t *out)
{
    const char *s = *p;
    uint32_t val = 0;

    if (*s < '0' || *s > '9')
        return 0;

    while (*s >= '0' && *s <= '9') {
        val = val * 10 + (uint8_t)(*s - '0');
        if (val > UINT16_MAX)
            return 0;
        s++;
    }

    *out = (uint16_t)val;
    *p = s;
    return 1;
}

/*
 * Parses a voltage in the exact form "n.nn" and advances *p past it.
 * The result is in hundredths of a volt (e.g. "2.37" -> 237), which keeps
 * float math out of the parser.
 */
static uint8_t parse_voltage(const char **p, uint16_t *centivolts)
{
    const char *s = *p;

    if (s[0] < '0' || s[0] > '9' || s[1] != '.' ||
        s[2] < '0' || s[2] > '9' || s[3] < '0' || s[3] > '9')
        return 0;

    *centivolts = (uint16_t)(s[0] - '0') * 100 + (s[2] - '0') * 10 + (s[3] - '0');
    *p = s + 4;
    return 1;
}

static uint8_t expect_char(const char **p, char c)
{
    if (**p != c)
        return 0;
    (*p)++;
    return 1;
}


/* ADC */

/*
 * AVcc reference, channel ADC0 (PC0, Arduino pin A0), right adjusted for
 * the full 10-bit result. Prescaler 128 gives a 125 kHz ADC clock, inside
 * the 50-200 kHz range needed for full 10-bit resolution.
 */
static void adc_init(void)
{
    ADMUX = (1 << REFS0);
    ADCSRA = (1 << ADEN) | (1 << ADPS2) | (1 << ADPS1) | (1 << ADPS0);
}

/* Starts one conversion and waits for it to finish. */
static uint16_t adc_read(void)
{
    ADCSRA |= (1 << ADSC);
    while (ADCSRA & (1 << ADSC))
        ;
    return ADC;
}

/* Converts a raw reading to millivolts: V = ADC * VREF / 1024. */
static uint16_t adc_to_mv(uint16_t raw)
{
    return (uint16_t)((raw * VREF_MV) / ADC_STEPS);
}


/* MAX518 DAC (over I2C, PC4/SDA = Arduino A4, PC5/SCL = Arduino A5) */

/*
 * Picks the DAC code with the smallest quantization error. VOUT = 5 V * N
 * / 256, so N = v * 256 / 5 rounded to the nearest integer. 5.00 V would be
 * N = 256, which doesn't fit, so it clamps to 255 (4.98 V).
 */
static uint8_t dac_code(uint16_t centivolts)
{
    uint32_t n = ((uint32_t)centivolts * DAC_STEPS + DAC_VREF_CV / 2) / DAC_VREF_CV;

    if (n > DAC_CODE_MAX)
        n = DAC_CODE_MAX;
    return (uint8_t)n;
}

/*
 * MAX518 write is: address byte, command byte, output byte. The command
 * byte's bit 0 selects the channel; RST and PD stay 0 for normal output.
 */
static uint8_t dac_write(uint8_t channel, uint8_t code)
{
    uint8_t ok = !i2c_start(MAX518_ADDR | I2C_WRITE) &&
                 !i2c_write(channel & 0x01) &&
                 !i2c_write(code);

    i2c_stop();
    return ok;
}


/* Command handlers (M is a stub until the timing is done) */

static void cmd_get(void)
{
    uint16_t mv = adc_to_mv(adc_read());

    printf("v=%u.%03u V\n", mv / 1000, mv % 1000);
}

static void cmd_multi(uint8_t n, uint8_t dt)
{
    printf("M: %u measurements, %u s apart (ADC not implemented)\n", n, dt);
}

static void cmd_set(uint8_t channel, uint16_t centivolts)
{
    uint8_t code = dac_code(centivolts);
    /* actual output in mV, so the quantization error is visible */
    uint16_t mv = (uint16_t)((code * DAC_VREF_CV * 10) / DAC_STEPS);

    if (!dac_write(channel, code)) {
        printf("Error: no response from DAC (check I2C wiring)\n");
        return;
    }

    printf("DAC channel %u set to %u.%02u V (code %u, output %u.%03u V)\n",
           channel, centivolts / 100, centivolts % 100,
           code, mv / 1000, mv % 1000);
}


/* Command parser */

static void handle_line(const char *line)
{
    const char *p = line + 1;
    uint16_t a, b;

    switch (line[0]) {
    case 'G':
        if (*p != '\0')
            break;
        cmd_get();
        return;

    case 'M':
        if (!expect_char(&p, ',') || !parse_uint(&p, &a) ||
            !expect_char(&p, ',') || !parse_uint(&p, &b) || *p != '\0')
            break;
        if (a < M_N_MIN || a > M_N_MAX) {
            printf("Error: n must be %u-%u\n", M_N_MIN, M_N_MAX);
            return;
        }
        if (b < M_DT_MIN || b > M_DT_MAX) {
            printf("Error: dt must be %u-%u s\n", M_DT_MIN, M_DT_MAX);
            return;
        }
        cmd_multi((uint8_t)a, (uint8_t)b);
        return;

    case 'S':
        if (!expect_char(&p, ',') || !parse_uint(&p, &a) ||
            !expect_char(&p, ',') || !parse_voltage(&p, &b) || *p != '\0')
            break;
        if (a > DAC_CH_MAX) {
            printf("Error: channel must be 0 or 1\n");
            return;
        }
        if (b > DAC_V_MAX) {
            printf("Error: voltage must be 0.00-%u.%02u V\n",
                   DAC_V_MAX / 100, DAC_V_MAX % 100);
            return;
        }
        cmd_set((uint8_t)a, b);
        return;
    }

    printf("Error: invalid command \"%s\"\n", line);
}


int main(void)
{
    char line[LINE_MAX];

    uart_init(UART_BAUD_SELECT(BAUD, F_CPU));   /* library sets 8N1 */
    stdout = &uart_out;
    adc_init();
    i2c_init();     /* library sets 100 kHz SCL; needs 4.7k pull-ups on A4/A5 */
    sei();                                      /* library is interrupt driven */

    printf("Lab5 analog interface ready\n");

    while (1) {
        if (!uart_getline(line, sizeof(line))) {
            printf("Error: command too long\n");
            continue;
        }
        handle_line(line);
    }
}
