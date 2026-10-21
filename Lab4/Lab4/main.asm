.include "m328Pdef.inc"

; PORT B PINS
.equ LCD_E    = 3      ; PB3 (Arduino pin 11)
.equ LCD_RS   = 5      ; PB5 (Arduino pin 13)

; PORT C PINS
.equ LCD_D4   = 0      ; PC0 (Arduino pin A0)
.equ LCD_D5   = 1      ; PC1 (Arduino pin A1)
.equ LCD_D6   = 2      ; PC2 (Arduino pin A2)
.equ LCD_D7   = 3      ; PC3 (Arduino pin A3)

; PORT D PINS
.equ FAN_PWM  = 5      ; PD5 (Arduino pin 5), OC0B

.equ LCD_DATA = (1<<LCD_D4) | (1<<LCD_D5) | (1<<LCD_D6) | (1<<LCD_D7)

; PWM
.equ PWM_TOP    = 199  ; 16 MHz / 200 counts = 80 kHz
.equ DUTY_START = 19   ; OCR0B = 19 -> (19 + 1) / 200 = 10%
.equ DUTY_STEP  = 20   ; 20 counts = 10% per step

; LCD commands (HD44780)
.equ LCD_FUNC  = 0x28  ; 4-bit bus, 2 lines, 5x8 font
.equ LCD_OFF   = 0x08  ; display off
.equ LCD_CLEAR = 0x01  ; clear and cursor home
.equ LCD_ENTRY = 0x06  ; cursor moves right, no shift
.equ LCD_ON    = 0x0C  ; display on, cursor off

; Timing (Timer2 ticks of 100 us)
.equ TICK_COUNTS = 200 ; 2 MHz timer clock * 100 us
.equ WAIT_POWER  = 250 ; 25 ms, done twice at power-up (LCD needs > 40 ms)
.equ WAIT_RESET  = 50  ; 5 ms after the first reset nibble (needs > 4.1 ms)
.equ WAIT_CLEAR  = 20  ; 2 ms for clear (needs 1.52 ms)
.equ WAIT_25MS   = 250 ; longest single wait
.equ RAMP_WAITS  = 40  ; 40 * 25 ms = 1 s between speed steps


; REGISTER USAGE
.def duty       = R19   ; OCR0B value, DUTY_START-PWM_TOP
; R16, R17        = scratch (only aliased locally inside subroutines)


.cseg

.org 0x0000
    jmp RESET

.org INT_VECTORS_SIZE

; LCD strings in program memory, null terminated and padded to an even length

str_hello:
    .db "Hello check-in", 0, 0

RESET:

    ldi R16, high(RAMEND)
    out SPH, R16
    ldi R16, low(RAMEND)
    out SPL, R16

    ; LCD outputs (R/W tied to ground, write only)

    sbi DDRB, LCD_E     ; PB3 (Arduino pin 11), LCD E
    sbi DDRB, LCD_RS    ; PB5 (Arduino pin 13), LCD RS
    ldi R16, LCD_DATA
    out DDRC, R16       ; PC0-PC3 (Arduino pins A0-A3), LCD D4-D7

    ; Fan PWM output

    sbi DDRD, FAN_PWM   ; PD5 (Arduino pin 5), fan PWM input

    ; Timer0: fast PWM with TOP = OCR0A (mode 7), no prescaler.
    ; 16 MHz / (PWM_TOP + 1) = 80 kHz. OC0B goes high at BOTTOM and low
    ; after the count passes OCR0B, so DC = (OCR0B + 1) / 200.
    ldi R16, (1<<COM0B1) | (1<<WGM01) | (1<<WGM00)
    out TCCR0A, R16     ; non-inverting PWM on OC0B
    ldi R16, PWM_TOP
    out OCR0A, R16
    ldi duty, DUTY_START
    out OCR0B, duty
    ldi R16, (1<<WGM02) | (1<<CS00)
    out TCCR0B, R16     ; prescaler 1, starts the PWM

    ; Timer2: CTC, 16 MHz / 8 = 2 MHz, 200 counts = 100 us per tick.
    ; Only used by wait for LCD timing.
    ldi R16, (1<<WGM21)
    sts TCCR2A, R16
    ldi R16, TICK_COUNTS - 1
    sts OCR2A, R16
    ldi R16, (1<<CS21)
    sts TCCR2B, R16     ; prescaler 8, starts the timer

    ; LCD text

    rcall lcd_init

    ldi ZL, low(str_hello*2)
    ldi ZH, high(str_hello*2)
    rcall lcd_string

main_loop:

    ; Every second, speed the fan up 10%. After 100% it starts over at 10%.

    ldi R17, RAMP_WAITS
    ldi R16, WAIT_25MS

ramp_wait:
    rcall wait
    dec R17
    brne ramp_wait      ; 1 s not up yet

    subi duty, -DUTY_STEP
    cpi duty, PWM_TOP + 1
    brlo ramp_set       ; still at or below 100%
    ldi duty, DUTY_START

ramp_set:
    out OCR0B, duty     ; double buffered, takes effect next PWM period
    rjmp main_loop


; LCD INIT
;
; Standard HD44780 power-up sequence for a 4-bit bus. The LCD starts in
; 8-bit mode, so 0x3 is sent three times as a reset, then 0x2 switches
; it to 4-bit. After that every command goes out as two nibbles.

lcd_init:

    push R16

    ldi R16, WAIT_POWER
    rcall wait
    rcall wait          ; LCD power-up

    cbi PORTB, LCD_RS   ; commands

    ldi R16, 0x03
    rcall lcd_nibble
    ldi R16, WAIT_RESET
    rcall wait
    ldi R16, 0x03
    rcall lcd_nibble
    rcall lcd_nibble
    ldi R16, 0x02
    rcall lcd_nibble    ; now in 4-bit mode

    ldi R16, LCD_FUNC
    rcall lcd_cmd
    ldi R16, LCD_OFF
    rcall lcd_cmd
    ldi R16, LCD_CLEAR
    rcall lcd_cmd
    ldi R16, WAIT_CLEAR
    rcall wait
    ldi R16, LCD_ENTRY
    rcall lcd_cmd
    ldi R16, LCD_ON
    rcall lcd_cmd

    pop R16
    ret


; Prints the null-terminated string in flash at Z (byte address).
lcd_string:

    push R16

ls_loop:
    lpm R16, Z+
    tst R16
    breq ls_ret         ; end of string
    rcall lcd_char
    rjmp ls_loop

ls_ret:
    pop R16
    ret


; Sends command R16 to the LCD (RS low).
lcd_cmd:
    cbi PORTB, LCD_RS
    rcall lcd_byte
    ret


; Sends character R16 to the LCD (RS high).
lcd_char:
    sbi PORTB, LCD_RS
    rcall lcd_byte
    ret


; Sends R16 to the LCD as two nibbles, high first. R16 is unchanged.
lcd_byte:
    swap R16
    rcall lcd_nibble    ; high nibble
    swap R16
    rcall lcd_nibble    ; low nibble
    ret


; LCD NIBBLE
; Input: R16 = nibble in bits 3-0
;
; Puts the nibble on D4-D7 and pulses E; the LCD latches on the falling
; edge. E has to stay high at least 450 ns, so the nops hold it for
; 6 * 62.5 ns plus the cbi itself, about 500 ns. Then waits one tick
; (100 us) for the LCD to finish (most commands take 37 us).

lcd_nibble:

    push R16

    andi R16, LCD_DATA
    out PORTC, R16

    sbi PORTB, LCD_E
    nop
    nop
    nop
    nop
    nop
    nop
    cbi PORTB, LCD_E

    ldi R16, 1
    rcall wait

    pop R16
    ret


; WAIT
; Input: R16 = number of 100 us Timer2 ticks (1-255)
;
; Restarts Timer2 first so the first tick is a full 100 us.

wait:
.def ticks = R16
.def zero  = R17

    push ticks
    push zero

    clr zero
    sts TCNT2, zero
    sbi TIFR2, OCF2A    ; clear any old flag (write 1 to clear)

wait_loop:
    sbis TIFR2, OCF2A
    rjmp wait_loop      ; tick not done yet
    sbi TIFR2, OCF2A
    dec ticks
    brne wait_loop

    pop zero
    pop ticks
    ret

.undef ticks
.undef zero

.exit
