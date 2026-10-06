.include "m328Pdef.inc"

.equ SEG_DASH = 0x40

; PORT B PINS
.equ RPG_A    = 0      ; PB0 (Arduino pin 8)
.equ RPG_B    = 1      ; PB1 (Arduino pin 9)
.equ SR_SER   = 2      ; PB2 (Arduino pin 10)
.equ SR_SRCLK = 3      ; PB3 (Arduino pin 11)
.equ SR_RCLK  = 4      ; PB4 (Arduino pin 12)

.equ RPG_DETENT = (1<<RPG_A) | (1<<RPG_B)   ; A and B both high = resting in a click


; REGISTER USAGE
.def rpg_prev   = R20   ; RPG A/B on the previous read (same bits as PINB)
.def ones       = R21   ; ones digit of the count (0-9)
.def tens       = R22   ; tens digit of the count (0-6)
.def overflowed = R23   ; 1 = counted past 60, showing "--"
; R16, R17, R18   = scratch (only aliased locally inside subroutines)


; SRAM VARIABLES
.dseg
.org 0x0100

lut:            .byte 10      ; 7-segment lookup table (digits 0-9)

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

    ldi R16, 0x3F       ; 0
    sts lut, R16
    ldi R16, 0x06       ; 1
    sts lut+1, R16
    ldi R16, 0x5B       ; 2
    sts lut+2, R16
    ldi R16, 0x4F       ; 3
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

    ; RPG inputs (external 10k pull-ups on the board)

    cbi DDRB, RPG_A
    cbi DDRB, RPG_B

    ; Shift register outputs

    sbi DDRB, SR_SER
    sbi DDRB, SR_SRCLK
    sbi DDRB, SR_RCLK

    ; Initial state

    rcall read_rpg
    mov rpg_prev, R16   ; start from wherever the knob is resting

    clr ones            ; count = 00
    clr tens
    clr overflowed

    rcall show

main_loop:

    ; RPG: compare current state to previous to find the direction

    rcall read_rpg      ; R16 = current A/B
    cp R16, rpg_prev
    breq main_loop      ; no change, knob hasn't moved

    mov R17, rpg_prev   ; R17 = previous state, for the direction check
    mov rpg_prev, R16   ; save current as the new previous

    ; One click = 11 -> ... -> 11. Only count when the knob lands back in
    ; the detent; the state it came from tells which way it turned.

    cpi R16, RPG_DETENT
    brne main_loop      ; still between clicks

    cpi R17, (1<<RPG_A)
    breq rpg_cw         ; came from 01: clockwise

    cpi R17, (1<<RPG_B)
    breq rpg_ccw        ; came from 10: counter-clockwise

    rjmp main_loop      ; came from 00 (missed a step), ignore

rpg_cw:

    ; Clockwise: count up, past 60 shows "--"

    tst overflowed
    brne rpg_done       ; already "--", stay there

    cpi tens, 6
    brne cw_inc         ; tens = 6 only at 60

    ldi overflowed, 1   ; 60 -> "--"
    rjmp rpg_show

cw_inc:
    inc ones
    cpi ones, 10
    brne rpg_show
    clr ones            ; 9 rolls over to the next ten
    inc tens
    rjmp rpg_show

rpg_ccw:

    ; Counter-clockwise: count down, stop at 00

    tst overflowed
    breq ccw_dec
    clr overflowed      ; "--" -> 60 (ones/tens still hold 60)
    rjmp rpg_show

ccw_dec:
    tst ones
    brne ccw_ones

    tst tens
    breq rpg_done       ; already 00, stay there

    ldi ones, 9         ; 0 borrows from the tens
    dec tens
    rjmp rpg_show

ccw_ones:
    dec ones

rpg_show:
    rcall show

rpg_done:
    rjmp main_loop


; Displays the count on both digits, or "--" after overflow.
show:

    tst overflowed
    breq show_digits

    ldi R16, SEG_DASH
    ldi R17, SEG_DASH
    rjmp show_out

show_digits:

    mov R16, ones
    rcall digit_to_seg
    mov R17, R16        ; R17 = ones pattern

    mov R16, tens
    rcall digit_to_seg  ; R16 = tens pattern

show_out:

    rcall display
    ret


; DISPLAY SUBROUTINE
;
; R16 = tens pattern, R17 = ones pattern
; Each: bit 7 is decimal point, bits 6-0 are segments g-a
;
; The shift registers are daisy-chained, so 16 bits go out on one data
; line. The first byte shifted in gets pushed through to the second
; (far) register, so tens goes first and ones stays in the first (near)
; register. The latch is pulsed once at the end so both digits change
; together.

display:

    push R16

    rcall shift_byte    ; tens -> far register
    mov R16, R17
    rcall shift_byte    ; ones -> near register

    sbi PORTB, SR_RCLK  ; pulse latch clock
    cbi PORTB, SR_RCLK

    pop R16
    ret


; Shifts R16 out on SER, MSB first.
shift_byte:
.def pattern   = R16
.def bits_left = R18

    push pattern
    push bits_left

    ldi bits_left, 8

shift_loop:

    lsl pattern         ; shift MSB into carry
    brcs set_ser_1      ; 1 shifted out

    cbi PORTB, SR_SER   ; SER = 0
    rjmp shift_clock

set_ser_1:
    sbi PORTB, SR_SER   ; SER = 1

shift_clock:

    sbi PORTB, SR_SRCLK ; pulse shift clock
    cbi PORTB, SR_SRCLK

    dec bits_left
    brne shift_loop

    pop bits_left
    pop pattern
    ret

.undef pattern
.undef bits_left


; READ RPG
; Output: R16 = bit 0 is A, bit 1 is B
;
; Both pins are read with one IN so A and B come from the same instant.

read_rpg:
    in R16, PINB
    andi R16, (1<<RPG_A) | (1<<RPG_B)
    ret


; DIGIT TO 7-SEGMENT LOOKUP
; Input:  R16 = digit to display (0-9)
; Output: R16 = segment pattern for that digit
;
; Used once for the ones digit and once for the tens digit. The pattern
; for digit d is at address lut + d. That address is 16 bits (XH:XL), so
; the digit is added to the low byte, then any carry to the high byte.

digit_to_seg:
.def zero = R18

    push zero
    push XL
    push XH

    ldi XL, low(lut)
    ldi XH, high(lut)

    clr zero
    add XL, R16         ; low byte += digit
    adc XH, zero        ; high byte += carry

    ld R16, X           ; R16 = lut[digit]

    pop XH
    pop XL
    pop zero
    ret

.undef zero

.exit
