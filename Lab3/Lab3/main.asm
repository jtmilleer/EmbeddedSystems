.include "m328Pdef.inc"

.equ SEG_DASH = 0x40


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

main_loop:
    rjmp main_loop


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
