.include "m328Pdef.inc"
.cseg
.org 0
	sbi DDRB, 0     ; PB0 (SER) as output. pin 8 on board
	sbi DDRB, 1     ; PB1 (SRCLK) as output. pin 9 on board
	sbi DDRB, 2     ; PB2 (RCLK) as output. pin 10 on board

	cbi DDRD, 2     ; PD2 (button 1) as input. pin 2 on board (increment for test)
	cbi DDRD, 3     ; PD3 (button 2) as input. pin 3 on board (decrement for test)

	ldi R16, 0x70 ; load pattern to display
	rcall display ; call display subroutine


main_loop:
	sbic PIND, 2         ; skip next instr if PD2 is 0 (i.e., skip if pressed)
	rjmp check_dec       ; not pressed, go check the other button
	inc R16
	rcall display

wait_release_inc:
	sbis PIND, 2         ; wait here while PD2 is still 0 (still pressed)
	rjmp wait_release_inc
	rjmp main_loop

check_dec:
	sbic PIND, 3
	rjmp main_loop
	dec R16
	rcall display
wait_release_dec:
	sbis PIND, 3
	rjmp wait_release_dec

	rjmp main_loop




display:
	; backup used registers on stack
	push R16
	push R17
	in R17, SREG
	push R17
	
	ldi R17, 8 ; loop --> go through all 8 bits

loop:
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
	brne loop
	

	sbi PORTB, 2    ;  generate RCLK pulse
	cbi PORTB, 2

	; restore registers from stack
	pop R17
	out SREG, R17
	pop R17
	pop R16
	
	ret
.exit