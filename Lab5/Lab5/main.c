/*
 * Lab5.c
 *
 * Remotely controlled analog interface over RS232 (9600 8N1):
 *
 *   G          single ADC measurement
 *   M,n,dt     n measurements (2-20), dt seconds apart (1-10)
 *   S,c,v      set DAC channel c (0 or 1) to v volts, format "n.nn"
 *
 * The ADC reads A0. The MAX518 DAC is driven over I2C (A4/A5).
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
#define DAC_V_MAX   500     /* hundredths of a volt */

#define VREF_MV     5000UL
#define ADC_STEPS   1024UL  /* 10-bit ADC */

#define TICKS_1S    15625U  /* 16 MHz / 1024 */

/* MAX518 address is 0101 1 AD1 AD0 with AD1 = AD0 = GND */
#define MAX518_ADDR (0x2C << 1)
#define DAC_STEPS   256UL   /* VOUT = 5 V * N / 256 */
#define DAC_CODE_MAX 255
#define DAC_VREF_CV 500UL   /* 5.00 V in hundredths of a volt */


/* UART */

static char uart_getc_blocking(void)
{
    uint16_t c;

    do {
        c = uart_getc();
    } while (c & UART_NO_DATA);

    return (char)c;
}

/* Sends CR before LF so lines start at the left edge of the terminal. */
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
 * Reads one line without its line ending. Blank lines are skipped so a
 * CR+LF ending doesn't produce an empty command. Returns 0 if the line
 * was too long for buf.
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


/* Parsing */

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

/* Parses "n.nn" into hundredths of a volt ("2.37" -> 237) to avoid floats. */
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
 * AVcc reference, channel ADC0, right adjusted (ADLAR = 0) for the full
 * 10-bit result. Prescaler 128 gives a 125 kHz ADC clock, inside the
 * 50-200 kHz range needed for 10-bit resolution.
 */
static void adc_init(void)
{
    ADMUX = (1 << REFS0);
    ADCSRA = (1 << ADEN) | (1 << ADPS2) | (1 << ADPS1) | (1 << ADPS0);
}

static uint16_t adc_read(void)
{
    ADCSRA |= (1 << ADSC);
    while (ADCSRA & (1 << ADSC))
        ;
    return ADC;
}

static uint16_t adc_to_mv(uint16_t raw)
{
    return (uint16_t)((raw * VREF_MV) / ADC_STEPS);
}


/* MAX518 DAC */

/*
 * N = v * 256 / 5, rounded to the nearest integer for the smallest
 * quantization error. 5.00 V would be 256, so it clamps to 255.
 */
static uint8_t dac_code(uint16_t centivolts)
{
    uint32_t n = ((uint32_t)centivolts * DAC_STEPS + DAC_VREF_CV / 2) / DAC_VREF_CV;

    if (n > DAC_CODE_MAX)
        n = DAC_CODE_MAX;
    return (uint8_t)n;
}

/* Address byte, command byte (bit 0 = channel), output byte. */
static uint8_t dac_write(uint8_t channel, uint8_t code)
{
    uint8_t ok = !i2c_start(MAX518_ADDR | I2C_WRITE) &&
                 !i2c_write(channel & 0x01) &&
                 !i2c_write(code);

    i2c_stop();
    return ok;
}


/* Timer1 */

/* CTC mode, prescaler 1024: 15625 counts per second, so OCF1A sets every 1 s. */
static void timer1_init(void)
{
    TCCR1A = 0;
    TCCR1B = (1 << WGM12) | (1 << CS12) | (1 << CS10);
    OCR1A = TICKS_1S - 1;
}

static void timer1_restart(void)
{
    TCNT1 = 0;
    TIFR1 = (1 << OCF1A);
}

/* The timer keeps running while printing, so samples don't drift. */
static void wait_seconds(uint8_t s)
{
    while (s--) {
        while (!(TIFR1 & (1 << OCF1A)))
            ;
        TIFR1 = (1 << OCF1A);
    }
}


/* Commands */

static void cmd_get(void)
{
    uint16_t mv = adc_to_mv(adc_read());

    printf("v=%u.%03u V\n", mv / 1000, mv % 1000);
}

static void cmd_multi(uint8_t n, uint8_t dt)
{
    uint8_t i;
    uint16_t t = 0;

    timer1_restart();
    for (i = 0; i < n; i++) {
        uint16_t mv;

        if (i > 0) {
            wait_seconds(dt);
            t += dt;
        }
        mv = adc_to_mv(adc_read());
        printf("t=%u s, v=%u.%03u V\n", t, mv / 1000, mv % 1000);
    }
}

static void cmd_set(uint8_t channel, uint16_t centivolts)
{
    uint8_t code = dac_code(centivolts);
    /* actual output for this code, rounded to 0.01 V */
    uint16_t cv = (uint16_t)((code * DAC_VREF_CV + DAC_STEPS / 2) / DAC_STEPS);

    if (!dac_write(channel, code)) {
        printf("Error: no response from DAC (check I2C wiring)\n");
        return;
    }

    printf("DAC channel %u set to %u.%02u V (%ud)\n",
           channel, cv / 100, cv % 100, code);
}

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
    timer1_init();
    i2c_init();                                 /* 100 kHz SCL */
    sei();                                      /* UART library uses interrupts */

    printf("Lab5 analog interface ready\n");

    while (1) {
        if (!uart_getline(line, sizeof(line))) {
            printf("Error: command too long\n");
            continue;
        }
        handle_line(line);
    }
}
