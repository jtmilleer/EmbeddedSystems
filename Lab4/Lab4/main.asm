.include "m328Pdef.inc"

; PORT B PINS
.equ RPG_A    = 0      ; PB0 (Arduino pin 8), PCINT0
.equ RPG_B    = 1      ; PB1 (Arduino pin 9), PCINT1
.equ LCD_E    = 3      ; PB3 (Arduino pin 11)
.equ LCD_RS   = 5      ; PB5 (Arduino pin 13)

; PORT C PINS
.equ LCD_D4   = 0      ; PC0 (Arduino pin A0)
.equ LCD_D5   = 1      ; PC1 (Arduino pin A1)
.equ LCD_D6   = 2      ; PC2 (Arduino pin A2)
.equ LCD_D7   = 3      ; PC3 (Arduino pin A3)

; PORT D PINS
.equ BUTTON   = 2      ; PD2 (Arduino pin 2), INT0, active low
.equ FAN_PWM  = 5      ; PD5 (Arduino pin 5), OC0B
.equ TACH_IN  = 3      ; PD3 (Arduino pin 3), INT1, open collector

.equ LCD_DATA = (1<<LCD_D4) | (1<<LCD_D5) | (1<<LCD_D6) | (1<<LCD_D7)
.equ RPG_DETENT = (1<<RPG_A) | (1<<RPG_B)   ; A and B both high = resting in a click

; PWM
.equ PWM_TOP    = 199  ; 16 MHz / 200 counts = 80 kHz
.equ DUTY_MIN   = 1    ; (1 + 1) / 200 = 1%
.equ DUTY_MAX   = PWM_TOP  ; OCR0B = TOP keeps OC0B high, 100%
.equ DUTY_START = 99   ; (99 + 1) / 200 = 50%
.equ DUTY_STEP  = 2    ; 2 counts = 1% per RPG click
.equ PCT_FULL   = 100  ; only value with a hundreds digit
.equ TENTHS_HALF = 5   ; tenths digit when (OCR0B + 1) is odd

; Timer0 control A with OC0B disconnected (fan off) and connected (fan on)
.equ PWM_MODE   = (1<<WGM01) | (1<<WGM00)
.equ PWM_ON     = PWM_MODE | (1<<COM0B1)

; LCD commands (HD44780)
.equ LCD_8BIT  = 0x03  ; upper nibble of "8-bit mode", sent alone during reset
.equ LCD_4BIT  = 0x02  ; upper nibble of "4-bit mode", sent alone during reset
.equ LCD_FUNC  = 0x28  ; 4-bit bus, 2 lines, 5x8 font
.equ LCD_OFF   = 0x08  ; display off
.equ LCD_CLEAR = 0x01  ; clear and cursor home
.equ LCD_ENTRY = 0x06  ; cursor moves right, no shift
.equ LCD_ON    = 0x0C  ; display on, cursor off
.equ LCD_LINE1 = 0x80  ; cursor to start of line 1
.equ LCD_LINE2 = 0xC0  ; cursor to start of line 2

; Timing (ticks of 100 us, counted off the 80 kHz PWM)
.equ PERIODS_PER_TICK = 8  ; 8 PWM periods * 12.5 us = 100 us
.equ WAIT_POWER  = 250 ; 25 ms, done four times for the 100 ms power-up wait
.equ WAIT_RESET  = 50  ; 5 ms after the first reset nibble and the 4-bit switch
.equ WAIT_SHORT  = 3   ; 200 us between the other reset nibbles (3 ticks since
                       ; the first one can be short)
.equ WAIT_CLEAR  = 20  ; 2 ms for clear (needs up to 1.64 ms)
.equ WAIT_1MS    = 10  ; 1 ms per release check
.equ RELEASE_MS  = 20  ; button must read high this long before INT0 is re-armed

; Fan status values
.equ STATUS_OFF     = 0
.equ STATUS_STOPPED = 1
.equ STATUS_LOW     = 2
.equ STATUS_OK      = 3


; REGISTER USAGE
.def duty       = R19   ; OCR0B value, DUTY_MIN-DUTY_MAX
.def rpg_prev   = R20   ; RPG A/B on the previous read (same bits as PINB)
.def fan_on     = R21   ; 1 = fan running, RPG enabled
.def lcd_update = R22   ; 1 = an ISR changed the DC or status, main loop redraws
.def tach_count = R23   ; number of tach pulses since the last Timer1 compare match
.def tach_sample = R24   ; Completed 500 ms pulse count
.def tach_ready  = R25   ; 1 = new RPM measurement available
.def fan_status = R26    ; 0 = off, 1 = stopped, 2 = low, 3 = ok
; R16, R17        = scratch (only aliased locally inside subroutines)


.cseg

.org 0x0000
    jmp RESET

.org INT0addr
    rjmp button_isr

.org PCI0addr
    rjmp rpg_isr

.org OC1Aaddr
    rjmp timer1_isr

.org INT1addr
    rjmp tach_isr

.org INT_VECTORS_SIZE

; LCD strings in program memory, null terminated and padded to an even length

str_dc:
    .db "DC = ", 0

str_fan_on:
    .db "Fan: ON ", 0, 0

str_fan_off:
    .db "Fan: OFF", 0, 0

str_fan_stopped:
    .db "Fan: stopped    ", 0, 0

str_fan_low:
    .db "Fan: low RPM    ", 0, 0

str_fan_ok:
    .db "Fan: RPM OK     ", 0, 0

RESET:

    ldi R16, high(RAMEND)
    out SPH, R16
    ldi R16, low(RAMEND)
    out SPL, R16

    ; LCD outputs (R/W tied to ground, write only)

    sbi DDRB, LCD_E     ; PB3 (Arduino pin 11), LCD E
    cbi PORTB, LCD_E    ; E idles low, only pulsed by lcd_strobe
    sbi DDRB, LCD_RS    ; PB5 (Arduino pin 13), LCD RS
    ldi R16, LCD_DATA
    out DDRC, R16       ; PC0-PC3 (Arduino pins A0-A3), LCD D4-D7

    ; Fan PWM output

    sbi DDRD, FAN_PWM   ; PD5 (Arduino pin 5), fan PWM input
    cbi PORTD, FAN_PWM  ; low whenever OC0B is disconnected (fan off)

    ; RPG and button inputs, debounced and pulled up in hardware

    cbi DDRB, RPG_A     ; PB0 (Arduino pin 8), RPG A
    cbi DDRB, RPG_B     ; PB1 (Arduino pin 9), RPG B
    cbi DDRD, BUTTON    ; PD2 (Arduino pin 2), pushbutton, active low

    ;tachometer input
    cbi DDRD, TACH_IN ; PD3 (Arduino pin 3), tachometer input


    ; Timer0: fast PWM with TOP = OCR0A (mode 7), no prescaler.
    ; 16 MHz / (PWM_TOP + 1) = 80 kHz. OC0B goes high at BOTTOM and low
    ; after the count passes OCR0B, so DC = (OCR0B + 1) / 200.
    ; OCF0A sets every 12.5 us at TOP, which wait also uses as its clock.
    ; The timer keeps running when the fan is off.
    ldi R16, PWM_ON
    out TCCR0A, R16     ; non-inverting PWM on OC0B, fan starts on
    ldi fan_on, 1
    ldi R16, PWM_TOP
    out OCR0A, R16
    ldi duty, DUTY_START
    out OCR0B, duty
    ldi R16, (1<<WGM02) | (1<<CS00)
    out TCCR0B, R16     ; prescaler 1, starts the PWM

    ;Timer1
    ldi R16, 0
    sts TCCR1A, R16 ;Clear Timer1 control register A.
    sts TCCR1B, R16 ;Clear Timer1 control register B.
    ldi R16, HIGH(0x7A11)
    sts OCR1AH, R16
    ldi R16, LOW(0x7A11)
    sts OCR1AL, R16
    ldi R16, 0
    sts TCNT1H, R16 ;Clear Timer1 counter register high byte.
    sts TCNT1L, R16 ;Clear Timer1 counter register low byte.
    ldi R16, (1<<OCF1A) ;Clear Timer1 compare match A flag.
    out TIFR1, R16
    ldi R16, (1<<OCIE1A) ;Enable Timer1 compare match A interrupt.
    sts TIMSK1, R16
    ldi R16, (1<<WGM12) | (1<<CS12) 
    sts TCCR1B, R16 ;Set Timer1 to CTC mode with a prescaler of 256.
    

    ldi fan_status, STATUS_OFF ;Initialize fan status to off
    
    ; LCD text

    rcall lcd_init

    rcall show_dc
    rcall show_status
    clr lcd_update

    ; Interrupts: button on the falling edge of INT0 (press), RPG on any
    ; change of PB0 or PB1

    ldi R16, (1<<ISC01) | (1<<ISC10) | (1<<ISC11)  ; INT0 falling edge, INT1 rising edge
    sts EICRA, R16
    ldi R16, (1<<INTF0) | (1<<INTF1)  ; clear any old edges (write 1 to clear)
    out EIFR, R16
    ldi R16, (1<<INT0) | (1<<INT1)  ; enable INT0 and INT1
    out EIMSK, R16

    ldi R16, (1<<PCINT0) | (1<<PCINT1)
    sts PCMSK0, R16
    in rpg_prev, PINB
    andi rpg_prev, (1<<RPG_A) | (1<<RPG_B)  ; start from wherever the knob is resting
    ldi R16, (1<<PCIF0)
    out PCIFR, R16
    ldi R16, (1<<PCIE0)
    sts PCICR, R16

    clr tach_count ; Start with zero pulses
    clr tach_ready ; Initialize ready flag
    clr tach_sample ; Initialize sample value


    sei

main_loop:

     ; Check if a new tachometer measurement is available
    tst tach_ready
    breq ml_lcd

    ; Safely retrieve the measurement
    in R16, SREG
    cli                     ; Temporarily disable interrupts

    mov R17, tach_sample    ; Copy completed pulse count
    clr tach_ready          ; Mark measurement as processed

    out SREG, R16           ; Restore previous interrupt state

      ; Determine fan status
    ; R17 contains pulses measured during 500 ms
    ; R18 will hold the new fan status

    ldi R18, STATUS_OFF
    tst fan_on
    breq ml_status_compare  ; Fan intentionally off

    tst R17
    breq ml_stopped         ; Zero pulses = stopped

    cpi R17, 44
    brlo ml_low_rpm         ; Fewer than 44 pulses

    ldi R18, STATUS_OK      ; 44 or more pulses
    rjmp ml_status_compare

ml_stopped:
    ldi R18, STATUS_STOPPED
    rjmp ml_status_compare

ml_low_rpm:
    ldi R18, STATUS_LOW


ml_status_compare:

    ; Only update the LCD if fan status changed
    cp R18, fan_status
    breq ml_lcd

    mov fan_status, R18
    ldi lcd_update, 1

    rjmp ml_lcd


ml_no_sample:
    out SREG, R16           ; Restore interrupts before continuing
    
ml_lcd:
    ; The ISRs do the work. The LCD is only touched here, since its waits
    ; are too slow for an ISR.

    tst lcd_update
    breq ml_rearm       ; nothing changed
    clr lcd_update      ; cleared first so a change mid-redraw isn't lost
    rcall show_dc
    rcall show_status

ml_rearm:
    sbic EIMSK, INT0
    rjmp main_loop      ; button already armed
    rcall button_rearm
    rjmp main_loop


; BUTTON ISR (INT0, falling edge)
;
; Toggles the fan right on the press. Off disconnects OC0B from the timer
; so PD5 falls back to its PORTD value (low); on reconnects it, and the
; PWM picks up at the duty cycle it had before.
;
; INT0 is switched off until button_rearm sees the button released, so
; bounce and fan noise on the slow release edge can't count as a second
; press.

button_isr:

    push R16
    in R16, SREG
    push R16

    cbi EIMSK, INT0     ; ignore the button until it's released

    ldi R16, 1
    eor fan_on, R16     ; flip on/off
    ldi R16, PWM_MODE
    tst fan_on
    breq btn_set        ; now off, leave OC0B disconnected
    ldi R16, PWM_ON

btn_set:
    out TCCR0A, R16

    ; Reset old RPM status when turning the fan back on
    tst fan_on
    breq btn_update_lcd
    ldi fan_status, STATUS_OFF

btn_update_lcd:
    ldi lcd_update, 1

    pop R16
    out SREG, R16
    pop R16
    reti


; BUTTON REARM
;
; Called from main_loop while INT0 is off. Returns once PD2 has read high
; (released) for RELEASE_MS straight, starting over on any low read. Then
; it clears edges latched in the meantime and turns INT0 back on. The RPG
; still works during this since it runs on its own interrupt.

button_rearm:
.def released = R17

    push R16
    push released

br_restart:
    ldi released, RELEASE_MS

br_loop:
    sbis PIND, BUTTON
    rjmp br_restart     ; still held or bouncing
    ldi R16, WAIT_1MS
    rcall wait
    dec released
    brne br_loop

    sbi EIFR, INTF0     ; drop edges from the release (write 1 to clear)
    sbi EIMSK, INT0

    pop released
    pop R16
    ret

.undef released


; RPG ISR (PCINT0, any change on A or B)
;
; Same direction check as Lab3: when the knob lands back on a detent (both
; high), the state it came from gives the direction. Each click moves the
; duty cycle 1%, clamped to 1-100%. Only works while the fan is on.

rpg_isr:

    push R16
    in R16, SREG
    push R16
    push R17

    in R16, PINB
    andi R16, (1<<RPG_A) | (1<<RPG_B)
    mov R17, rpg_prev   ; R17 = previous state
    mov rpg_prev, R16   ; tracked even when off so turning on starts clean

    tst fan_on
    breq rpg_ret        ; fan off, RPG disabled
    cpi R16, RPG_DETENT
    brne rpg_ret        ; still between clicks

    cpi R17, (1<<RPG_A)
    breq rpg_cw         ; came from 01: clockwise
    cpi R17, (1<<RPG_B)
    breq rpg_ccw        ; came from 10: counter-clockwise
    rjmp rpg_ret        ; missed a step, ignore

rpg_cw:
    cpi duty, DUTY_MAX
    breq rpg_ret        ; already 100%
    subi duty, -DUTY_STEP
    rjmp rpg_set

rpg_ccw:
    cpi duty, DUTY_MIN
    breq rpg_ret        ; already 1%
    subi duty, DUTY_STEP

rpg_set:
    out OCR0B, duty     ; double buffered, takes effect next PWM period
    ldi lcd_update, 1   ; main loop redraws the DC

rpg_ret:
    pop R17
    pop R16
    out SREG, R16
    pop R16
    reti

; TIMER1 ISR (Compare Match A)
; Executes every 500 ms.
; Saves tachometer pulse count and resets for next interval.

timer1_isr:

    push R16
    in R16, SREG
    push R16

    ; Save completed pulse count
    mov tach_sample, tach_count

    ; Reset counter for next 500 ms
    clr tach_count

    ; Notify main loop that new measurement is available
    ldi tach_ready, 1

    pop R16
    out SREG, R16
    pop R16
    reti



; TACHOMETER ISR (INT1, rising edge)
; Counts tachometer pulses, saturating at 44.
; 44 pulses per 500 ms corresponds to 2640 RPM.

tach_isr:

    push R16
    in R16, SREG
    push R16

    cpi tach_count, 44
    brsh tach_ret          ; Don't count above 44

    inc tach_count         ; Increment pulse count

tach_ret:
    pop R16
    out SREG, R16
    pop R16
    reti


; SHOW DUTY CYCLE
; Input: duty = OCR0B value
;
; Writes "DC = xx.x%" on line 1. DC = (OCR0B + 1) / 2 percent, so the
; whole percent is (OCR0B + 1) shifted right once and the bit shifted out
; is the half percent (tenths digit 5 or 0). The leading zero is dropped
; and two spaces at the end clear what a longer value left behind.

show_dc:
.def pct    = R17
.def tenths = R18

    push R16
    push pct
    push tenths
    push ZL
    push ZH

    ldi R16, LCD_LINE1
    rcall lcd_cmd
    ldi ZL, low(str_dc*2)
    ldi ZH, high(str_dc*2)
    rcall lcd_string

    ; Split into whole percent and tenths

    mov pct, duty
    inc pct             ; OCR0B + 1, at most 200
    clr tenths
    lsr pct
    brcc sd_hundreds    ; even, x.0%
    ldi tenths, TENTHS_HALF

sd_hundreds:
    cpi pct, PCT_FULL
    brne sd_tens
    ldi R16, '1'
    rcall lcd_char
    ldi R16, '0'
    rcall lcd_char      ; tens digit of 100
    clr pct
    rjmp sd_ones

sd_tens:
    ldi R16, '0'

sd_tens_loop:
    cpi pct, 10
    brlo sd_tens_done   ; pct is now the ones digit
    subi pct, 10
    inc R16
    rjmp sd_tens_loop

sd_tens_done:
    cpi R16, '0'
    breq sd_ones        ; under 10%, no leading zero
    rcall lcd_char

sd_ones:
    mov R16, pct
    subi R16, -'0'
    rcall lcd_char
    ldi R16, '.'
    rcall lcd_char
    mov R16, tenths
    subi R16, -'0'
    rcall lcd_char
    ldi R16, '%'
    rcall lcd_char
    ldi R16, ' '
    rcall lcd_char
    rcall lcd_char      ; "100.0%" is two longer than "1.0%"

    pop ZH
    pop ZL
    pop tenths
    pop pct
    pop R16
    ret

.undef pct
.undef tenths



; SHOW FAN STATUS
; Displays the current operating condition on LCD line 2.

show_status:

    push R16
    push ZL
    push ZH

    ; Move cursor to beginning of second line
    ldi R16, LCD_LINE2
    rcall lcd_cmd

    ; Fan OFF always takes priority
    tst fan_on
    breq ss_off

    ; Check measured operating status
    cpi fan_status, STATUS_STOPPED
    breq ss_stopped

    cpi fan_status, STATUS_LOW
    breq ss_low

    cpi fan_status, STATUS_OK
    breq ss_ok

    ; Waiting for first RPM measurement
    ldi ZL, low(str_fan_on*2)
    ldi ZH, high(str_fan_on*2)
    rjmp ss_print

ss_off:
    ldi ZL, low(str_fan_off*2)
    ldi ZH, high(str_fan_off*2)
    rjmp ss_print

ss_stopped:
    ldi ZL, low(str_fan_stopped*2)
    ldi ZH, high(str_fan_stopped*2)
    rjmp ss_print

ss_low:
    ldi ZL, low(str_fan_low*2)
    ldi ZH, high(str_fan_low*2)
    rjmp ss_print

ss_ok:
    ldi ZL, low(str_fan_ok*2)
    ldi ZH, high(str_fan_ok*2)


ss_print:
    rcall lcd_string

    pop ZH
    pop ZL
    pop R16
    ret


; LCD INIT
;
; Standard HD44780 power-up sequence for a 4-bit bus. The LCD powers up
; in 8-bit mode, so only upper nibbles go out until it's
; switched: 0x3 three times as a reset (waits of 5 ms, 200 us, 200 us),
; then 0x2 for 4-bit mode and another 5 ms. After that every command goes
; out as two nibbles.

lcd_init:

    push R16

    ldi R16, WAIT_POWER
    rcall wait
    rcall wait
    rcall wait
    rcall wait          ; 100 ms for the LCD to power up

    cbi PORTB, LCD_RS   ; commands

    ; Reset, still in 8-bit mode

    ldi R16, LCD_8BIT
    rcall lcd_nibble
    ldi R16, WAIT_RESET
    rcall wait
    ldi R16, LCD_8BIT
    rcall lcd_nibble
    ldi R16, WAIT_SHORT
    rcall wait
    ldi R16, LCD_8BIT
    rcall lcd_nibble
    ldi R16, WAIT_SHORT
    rcall wait
    ldi R16, LCD_4BIT
    rcall lcd_nibble    ; now in 4-bit mode
    ldi R16, WAIT_RESET
    rcall wait

    ; Configuration, two nibbles per command

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
; Puts the nibble on D4-D7, strobes E, then waits one tick (100 us) for
; the LCD to finish (most commands take 40 us).

lcd_nibble:

    push R16

    andi R16, LCD_DATA
    out PORTC, R16      ; data is set up well before E rises
    rcall lcd_strobe

    ldi R16, 1
    rcall wait

    pop R16
    ret


; LCD STROBE
;
; Pulses E so the LCD latches D4-D7 on the falling edge. E has to stay
; high at least 230 ns at 5 V (450 ns at lower supplies), so the nops
; hold it for 6 * 62.5 ns plus the cbi itself, about 500 ns.

lcd_strobe:
    sbi PORTB, LCD_E
    nop
    nop
    nop
    nop
    nop
    nop
    cbi PORTB, LCD_E
    ret


; WAIT
; Input: R16 = number of 100 us ticks (1-255)
;
; Counts Timer0 PWM periods (OCF0A at TOP, every 12.5 us), 8 per tick.
; Timer0 can't be restarted without glitching the PWM, so the first
; period may be short and a 1-tick wait is at least 87.5 us. The LCD's
; ordinary commands need 40 us, so that's still plenty.

wait:
.def ticks   = R16
.def periods = R17

    push ticks
    push periods

    sbi TIFR0, OCF0A    ; clear any old flag (write 1 to clear)

wait_tick:
    ldi periods, PERIODS_PER_TICK

wait_loop:
    sbis TIFR0, OCF0A
    rjmp wait_loop      ; PWM period not done yet
    sbi TIFR0, OCF0A
    dec periods
    brne wait_loop
    dec ticks
    brne wait_tick

    pop periods
    pop ticks
    ret

.undef ticks
.undef periods

.exit
