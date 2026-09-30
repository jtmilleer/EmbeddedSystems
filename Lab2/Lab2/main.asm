.include "m328Pdef.inc"

.equ SHORT_MAX_TICKS  = 100
.equ BUTTON_MIN_TICKS = 101
.equ BUTTON_MAX_TICKS = 200
.equ LONG_MIN_TICKS   = 201

.equ SEG_DASH = 0x20


; REGISTER USAGE
.def counter    = R20   ; counter value (0-F)
.def mode       = R21   ; 0 = 1-second, 1 = 10-second
.def b_ticks    = R22   ; how many ticks Button B has been held
.def a_prev     = R23   ; Button A state on the previous pass
.def overflowed = R24   ; 1 = counted past F, showing "-"
.def stopped    = R25   ; 1 = stopped, 0 = counting
; YH:YL (R29:R28) = 10-ms ticks since last count
; R16, R17, R18   = scratch (not aliased, used for different things)

; SRAM VARIABLES
.dseg
.org 0x0100

lut:            .byte 16      ; 7-segment lookup table

.cseg

.org 0x0000
    jmp RESET

.org INT_VECTORS_SIZE

RESET:

    ldi R16, high(RAMEND)
    out SPH, R16
    ldi R16, low(RAMEND)
    out SPL, R16


    ; 7-segment lookup table

    ldi R16, 0x5F       ; 0
    sts lut, R16
    ldi R16, 0x06       ; 1
    sts lut+1, R16
    ldi R16, 0x3B       ; 2
    sts lut+2, R16
    ldi R16, 0x2F       ; 3
    sts lut+3, R16
    ldi R16, 0x66       ; 4
    sts lut+4, R16
    ldi R16, 0x6D       ; 5
    sts lut+5, R16
    ldi R16, 0x7D       ; 6
    sts lut+6, R16
    ldi R16, 0x07       ; 7
    sts lut+7, R16
    ldi R16, 0x7F       ; 8
    sts lut+8, R16
    ldi R16, 0x6F       ; 9
    sts lut+9, R16
    ldi R16, 0x77       ; A
    sts lut+10, R16
    ldi R16, 0x7C       ; b
    sts lut+11, R16
    ldi R16, 0x59       ; C
    sts lut+12, R16
    ldi R16, 0x3E       ; d
    sts lut+13, R16
    ldi R16, 0x79       ; E
    sts lut+14, R16
    ldi R16, 0x71       ; F
    sts lut+15, R16

    ; Shift register outputs

    sbi DDRB, 0         ; PB0 = SER     (Arduino pin 8)
    sbi DDRB, 1         ; PB1 = SRCLK   (Arduino pin 9)
    sbi DDRB, 2         ; PB2 = RCLK    (Arduino pin 10)

    ; Button inputs (released = HIGH, pressed = LOW)

    cbi DDRD, 2         ; PD2 = Button B (mode / reset / clear)
    cbi DDRD, 3         ; PD3 = Button A (start / stop)
    sbi PORTD, 2
    sbi PORTD, 3

    ; Initial state: showing 0, stopped, waiting for Button A

    clr counter         ; counter = 0
    clr mode            ; 1-second mode
    clr b_ticks         ; Button B not held
    ldi a_prev, (1<<3)  ; Button A released
    clr overflowed      ; no overflow
    ldi stopped, 1      ; stopped
    clr YL              ; tick count = 0
    clr YH

    rcall show

main_loop:

    rcall delay_10ms

    ; Button A: start/stop on each new press

    in R16, PIND
    andi R16, (1<<3)    ; 0 = pressed, (1<<3) = released

    cp R16, a_prev
    breq btn_a_done     ; no change since last pass

    mov a_prev, R16
    tst R16
    brne btn_a_done     ; just released, ignore

    tst overflowed
    brne btn_a_done     ; overflowed: A does nothing until cleared

    ldi R16, 1
    eor stopped, R16    ; just pressed: toggle start/stop

btn_a_done:

    ; Button B: measure hold time, act on release

    sbic PIND, 2        ; skip next line if pressed (LOW)
    rjmp btn_b_released

    ; Pressed: count ticks, capped at 255 so it can't wrap
    cpi b_ticks, 255
    breq btn_b_done
    inc b_ticks
    rjmp btn_b_done

btn_b_released:

    tst b_ticks
    breq btn_b_done     ; wasn't pressed

    cpi b_ticks, SHORT_MAX_TICKS
    brlo b_short        ; < 1 s

    cpi b_ticks, BUTTON_MIN_TICKS
    brlo clear_hold     ; exactly 1 s: ignore

    cpi b_ticks, BUTTON_MAX_TICKS
    brlo b_mode         ; > 1 s and < 2 s

    cpi b_ticks, LONG_MIN_TICKS
    brlo clear_hold     ; exactly 2 s: ignore

    ; > 2 s: clear overflow back to 0, stopped
    tst overflowed
    breq clear_hold
    clr overflowed
    rjmp reset_to_zero

b_short:

    ; < 1 s: reset to 0, only while stopped (and not overflowed)
    tst stopped
    breq clear_hold
    tst overflowed
    brne clear_hold

reset_to_zero:

    clr counter
    clr YL
    clr YH
    rcall show
    rjmp clear_hold

b_mode:

    ; > 1 s and < 2 s: toggle 1 s / 10 s mode
    ldi R16, 1
    eor mode, R16

    clr YL              ; start a fresh interval in the new mode
    clr YH

    rcall show          ; update decimal point right away

clear_hold:
    clr b_ticks

btn_b_done:

    tst stopped
    breq counting    ; Stopped: skip counting
    rjmp main_loop

counting:

    ; Check to see if 1 or 10 sec has passed

    adiw YL, 1

    tst mode
    brne check_10s

    cpi YL, low(100)
    ldi R16, high(100)
    cpc YH, R16
    brsh count_up
    rjmp main_loop

check_10s:

    cpi YL, low(1000)
    ldi R16, high(1000)
    cpc YH, R16
    brsh count_up
    rjmp main_loop

count_up:

    clr YL
    clr YH

    cpi counter, 0x0F
    breq overflow       ; incrementing past F

    inc counter
    rcall show
    rjmp main_loop

overflow:

    ldi overflowed, 1   ; show "-"
    ldi stopped, 1      ; stop
    rcall show
    rjmp main_loop


; Displays counter, or "-" after overflow.
; Decimal point ON in 10-second mode.
show:

    tst overflowed ; Check overflow
    breq show_digit

    ldi R16, SEG_DASH
    rjmp show_dp

show_digit:

    mov R16, counter
    rcall hex_to_seg

show_dp:

    tst mode
    breq show_out
    ori R16, 0x80       ; decimal point on

show_out:

    rcall display
    ret

delay_10ms:

    push R17
    push R18

    ldi R17, 208

d10_outer:
    ldi R18, 255

d10_inner:

    dec R18
    brne d10_inner

    dec R17
    brne d10_outer

    pop R18
    pop R17
    ret

; DISPLAY SUBROUTINE
;
; R16 = bit 7 is decimal point, bits 6-0 are segments

display:

    push R16
    push R17

    ldi R17, 8

rotate_loop:

    lsl R16             ; shift MSB into carry
    brcs set_ser_in_1   ; 1 shifted out,

    cbi PORTB, 0        ; SER = 0
    rjmp shift_clock

set_ser_in_1:
    sbi PORTB, 0        ; SER = 1

shift_clock:

    sbi PORTB, 1        ; pulse shift clock
    cbi PORTB, 1

    dec R17
    brne rotate_loop ; if R17 doesn't go to 0 (all nums shifted not in), jump back up.

    sbi PORTB, 2        ; pulse latch clock
    cbi PORTB, 2

    pop R17
    pop R16
    ret

; HEX TO 7-SEGMENT LOOKUP
; Input:  R16 = 0-F
; Output: R16 = segment pattern

hex_to_seg:

    push R18
    push XL
    push XH

    andi R16, 0x0F

    ldi XL, low(lut)
    ldi XH, high(lut)

    clr R18
    add XL, R16
    adc XH, R18

    ld R16, X

    pop XH
    pop XL
    pop R18
    ret

.exit
