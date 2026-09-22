.include "m328Pdef.inc"

.dseg
.org 0x0100
lut: .byte 16          ; 16-byte lookup table for hex digits 0-F



.cseg
.org 0
	; init table
	ldi R16, 0x5F   ; 0
	sts lut, R16
	ldi R16, 0x06   ; 1
	sts lut+1, R16
	ldi R16, 0x3B   ; 2
	sts lut+2, R16
	ldi R16, 0x2F   ; 3
	sts lut+3, R16
	ldi R16, 0x66   ; 4
	sts lut+4, R16
	ldi R16, 0x6D   ; 5
	sts lut+5, R16
	ldi R16, 0x7D   ; 6
	sts lut+6, R16
	ldi R16, 0x07   ; 7
	sts lut+7, R16
	ldi R16, 0x7F   ; 8
	sts lut+8, R16
	ldi R16, 0x6F   ; 9
	sts lut+9, R16
	ldi R16, 0x77   ; A
	sts lut+10, R16
	ldi R16, 0x7C   ; b
	sts lut+11, R16
	ldi R16, 0x59   ; C
	sts lut+12, R16
	ldi R16, 0x3E   ; d
	sts lut+13, R16
	ldi R16, 0x79   ; E
	sts lut+14, R16
	ldi R16, 0x71   ; F
	sts lut+15, R16






	sbi DDRB, 0     ; PB0 (SER) as output. pin 8 on board
	sbi DDRB, 1     ; PB1 (SRCLK) as output. pin 9 on board
	sbi DDRB, 2     ; PB2 (RCLK) as output. pin 10 on board

	cbi DDRD, 2     ; PD2 (button B) as input. pin 2 on board (increment for test)
	cbi DDRD, 3     ; PD3 (button A) as input. pin 3 on board (decrement for test)




	ldi R20, 0      ; R20 = persistent counter (0-15), starts at 0
	mov R16, R20
	rcall hex_to_seg ; convert counter segment pattern
	rcall display    ; call display subroutine


main_loop:
	rcall delay_1s       ; swap for delay_10s to count every 10 sec
	inc R20
	andi R20, 0x0F       ; wrap counter to 0-15
	mov R16, R20
	rcall hex_to_seg     ; convert counter segment pattern
	rcall display
	rjmp main_loop




display:
	; backup used registers on stack
	push R16
	push R17
	in R17, SREG
	push R17
	
	ldi R17, 8 ; loop --> go through all 8 bits

rotate_loop:
	rol R16 ; rotate left trough Carry
	BRCS set_ser_in_1 ; branch if Carry is set ( a 1 was shifted out)
	cbi PORTB, 0 ; set SER to 0
	rjmp end
set_ser_in_1:
	sbi PORTB, 0 ; set SER to 1
end:
	sbi PORTB, 1 
	cbi PORTB, 1   ; generate SRCLK pulse
	dec R17
	brne rotate_loop
	

	sbi PORTB, 2    ;  generate RCLK pulse
	cbi PORTB, 2

	; restore registers from stack
	pop R17
	out SREG, R17
	pop R17
	pop R16
	
	ret



hex_to_seg:
	push R18
	push R19
	push R26              ; XL
	push R27              ; XH

	andi R16, 0x0F        ; make sure it's 0-15

	ldi R26, low(lut)     ; X = base address of table
	ldi R27, high(lut)
	clr R18
	add R26, R16          ; X = X + offset
	adc R27, R18          ; carry into high byte if needed

	ld  R19, X            ; R19 = table[offset]
	mov R16, R19          ; return value in R16

	pop R27
	pop R26
	pop R19
	pop R18
	ret



; busy-wait ~1 sec. trimmed by 182 cycles so one full main_loop
; pass (delay + inc + hex_to_seg + display) = 16,000,000 cycles @ 16 MHz
delay_1s:
	push R21
	push R22
	push R23

	ldi R21, 82
	ldi R22, 43
	ldi R23, 196          ; was 0 (256): 60 fewer inner loops = -180 cycles
d1_loop:
	dec R23
	brne d1_loop
	dec R22
	brne d1_loop
	dec R21
	brne d1_loop
	rjmp PC+1             ; 2-cycle pad (was lpm+nop = 4): -2 cycles

	pop R23
	pop R22
	pop R21
	ret



; busy-wait 10 sec (calls delay_1s 10 times)
delay_10s:
	push R24
	ldi R24, 10
d10_loop:
	rcall delay_1s
	dec R24
	brne d10_loop
	pop R24
	ret
.exit