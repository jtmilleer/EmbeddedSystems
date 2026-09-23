.include "m328Pdef.inc"


; ============================================================
; CONSTANTS
; ============================================================

.equ MODE_1S  = 0
.equ MODE_10S = 1

; Timer interrupt occurs every 10 ms
;
; > 1 second = at least 101 ticks
; < 2 seconds = fewer than 200 ticks
.equ BUTTON_MIN_TICKS = 101
.equ BUTTON_MAX_TICKS = 200


; ============================================================
; SRAM VARIABLES
; ============================================================

.dseg
.org 0x0100

lut:            .byte 16      ; 7-segment lookup table

counter_value:  .byte 1       ; displayed hexadecimal count 0-F
increment_mode: .byte 1       ; 0 = 1-second mode, 1 = 10-second mode

button_ticks:   .byte 1       ; how long Button B has been held
elapsed_lo:     .byte 1       ; low byte of 10-ms elapsed counter
elapsed_hi:     .byte 1       ; high byte

display_dirty:  .byte 1       ; 1 = display needs updating



; ============================================================
; INTERRUPT VECTOR TABLE
; ============================================================

.cseg

.org 0x0000
    jmp RESET

; Timer1 Compare Match A vector
.org OC1Aaddr
    jmp TIMER1_COMPA_ISR


; Put normal program code after interrupt vector table
.org 0x0034


; ============================================================
; RESET / INITIALIZATION
; ============================================================

RESET:

    ; --------------------------------------------------------
    ; Initialize stack
    ; --------------------------------------------------------

    ldi R16, high(RAMEND)
    out SPH, R16

    ldi R16, low(RAMEND)
    out SPL, R16


    ; --------------------------------------------------------
    ; Initialize 7-segment lookup table
    ; --------------------------------------------------------

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


    ; ========================================================
    ; SHIFT REGISTER OUTPUTS
    ; ========================================================

    sbi DDRB, 0         ; PB0 = SER     (Arduino pin 8)
    sbi DDRB, 1         ; PB1 = SRCLK   (Arduino pin 9)
    sbi DDRB, 2         ; PB2 = RCLK    (Arduino pin 10)


    ; ========================================================
    ; BUTTON INPUTS
    ; ========================================================

    cbi DDRD, 2         ; PD2 = Button B
    cbi DDRD, 3         ; PD3 = Button A

    ; Enable internal pull-ups
    ;
    ; Released = HIGH
    ; Pressed  = LOW
    sbi PORTD, 2
    sbi PORTD, 3


    ; ========================================================
    ; INITIALIZE VARIABLES
    ; ========================================================

    clr R16

    ; Counter starts at zero
    sts counter_value, R16

    ; Start in 1-second mode
    sts increment_mode, R16

    ; Button not currently held
    sts button_ticks, R16

    ; Clear stopwatch timing counter
    sts elapsed_lo, R16
    sts elapsed_hi, R16


    ; Force initial display update
    ldi R16, 1
    sts display_dirty, R16


    ; ========================================================
    ; SET UP TIMER1
    ;
    ; 16 MHz CPU
    ; Prescaler = 64
    ;
    ; Timer frequency:
    ;
    ; 16,000,000 / 64 = 250,000 Hz
    ;
    ; One Timer1 count:
    ;
    ; 1 / 250,000 = 4 us
    ;
    ; For 10 ms:
    ;
    ; 10 ms / 4 us = 2500 timer counts
    ;
    ; Therefore:
    ;
    ; OCR1A = 2499
    ;
    ; because the timer counts:
    ;
    ; 0 ... 2499 = 2500 counts
    ; ========================================================

    cli


    ; Timer1 Control Register A
    clr R16
    sts TCCR1A, R16


    ; Timer1 Control Register B
    ;
    ; WGM12 = 1  -> CTC mode
    ;
    ; CS11 = 1
    ; CS10 = 1
    ;
    ; Gives prescaler of 64
    ldi R16, (1<<WGM12) | (1<<CS11) | (1<<CS10)
    sts TCCR1B, R16


    ; Clear Timer1 counter
    clr R16
    sts TCNT1H, R16
    sts TCNT1L, R16


    ; OCR1A = 2499 = 0x09C3

    ldi R16, high(2499)
    sts OCR1AH, R16

    ldi R16, low(2499)
    sts OCR1AL, R16


    ; Enable Timer1 Output Compare A interrupt
    ldi R16, (1<<OCIE1A)
    sts TIMSK1, R16


    ; Enable global interrupts
    sei



; ============================================================
; MAIN LOOP
;
; Timer1 handles all stopwatch timing.
;
; The main loop only updates the physical display whenever
; display_dirty = 1.
; ============================================================

main_loop:

    lds R16, display_dirty

    tst R16
    breq main_loop


    ; Clear dirty flag
    clr R16
    sts display_dirty, R16


    ; --------------------------------------------------------
    ; Get current hexadecimal counter value
    ; --------------------------------------------------------

    lds R16, counter_value

    ; Convert 0-F into 7-segment pattern
    rcall hex_to_seg


    ; --------------------------------------------------------
    ; Decimal point indicates timing mode
    ;
    ; 1-second mode:
    ;     DP OFF
    ;
    ; 10-second mode:
    ;     DP ON
    ; --------------------------------------------------------

    lds R17, increment_mode

    tst R17
    breq dp_off


; ------------------------------------------------------------
; 10 SECOND MODE
; ------------------------------------------------------------

dp_on:

    ; Assuming bit 7 controls decimal point
    ori R16, 0x80

    rjmp update_display


; ------------------------------------------------------------
; 1 SECOND MODE
; ------------------------------------------------------------

dp_off:

    ; Clear bit 7 = decimal point off
    andi R16, 0x7F


update_display:

    rcall display

    rjmp main_loop



; ============================================================
; TIMER1 COMPARE A INTERRUPT
;
; Called automatically every 10 ms.
; ============================================================

TIMER1_COMPA_ISR:

    ; --------------------------------------------------------
    ; Save registers and status register
    ; --------------------------------------------------------

    push R16
    in R16, SREG
    push R16

    push R17
    push R18
    push R24
    push R25


    ; ========================================================
    ; INCREMENT ELAPSED TIME
    ;
    ; elapsed_hi:elapsed_lo is a 16-bit counter
    ;
    ; Each count = 10 ms
    ; ========================================================

    lds R24, elapsed_lo
    lds R25, elapsed_hi

    adiw R24, 1

    sts elapsed_lo, R24
    sts elapsed_hi, R25


    ; ========================================================
    ; CHECK BUTTON B
    ;
    ; Button B = PD2
    ;
    ; Because of internal pull-up:
    ;
    ; PD2 = 1 --> released
    ; PD2 = 0 --> pressed
    ; ========================================================

    sbis PIND, 2
    rjmp button_pressed


; ============================================================
; BUTTON RELEASED
; ============================================================

button_released:

    lds R18, button_ticks

    ; If button_ticks = 0, button wasn't being held
    tst R18
    breq check_stopwatch_time


    ; --------------------------------------------------------
    ; Has button been held MORE than 1 second?
    ;
    ; Interrupt = 10 ms
    ;
    ; 100 ticks = exactly 1.00 second
    ;
    ; Requirement says MORE than 1 second,
    ; so valid range begins at 101 ticks.
    ; --------------------------------------------------------

    cpi R18, BUTTON_MIN_TICKS
    brlo reset_button


    ; --------------------------------------------------------
    ; Has button been held LESS than 2 seconds?
    ;
    ; 200 ticks = exactly 2.00 seconds
    ;
    ; Therefore R18 must be below 200.
    ; --------------------------------------------------------

    cpi R18, BUTTON_MAX_TICKS
    brsh reset_button


    ; ========================================================
    ; VALID PRESS:
    ;
    ; 101 <= button_ticks < 200
    ;
    ; Toggle increment mode
    ; ========================================================

    lds R17, increment_mode

    ldi R16, 1

    ; XOR with 1 toggles:
    ;
    ; 0 -> 1
    ; 1 -> 0
    eor R17, R16

    sts increment_mode, R17


    ; --------------------------------------------------------
    ; Reset elapsed stopwatch timing when changing mode
    ;
    ; This means switching to a new mode starts a fresh
    ; 1-second or 10-second interval.
    ; --------------------------------------------------------

    clr R16

    sts elapsed_lo, R16
    sts elapsed_hi, R16


    ; --------------------------------------------------------
    ; Tell main loop to update display
    ;
    ; Needed because decimal point changes immediately.
    ; --------------------------------------------------------

    ldi R16, 1
    sts display_dirty, R16



; ============================================================
; RESET BUTTON HOLD COUNTER
; ============================================================

reset_button:

    clr R18
    sts button_ticks, R18

    rjmp check_stopwatch_time



; ============================================================
; BUTTON PRESSED
; ============================================================

button_pressed:

    lds R18, button_ticks


    ; --------------------------------------------------------
    ; Stop counting after 200 ticks
    ;
    ; This prevents the 8-bit value from overflowing if
    ; Button B is held down for a long time.
    ;
    ; Once it reaches 200, the press can no longer satisfy
    ; the "less than 2 seconds" requirement anyway.
    ; --------------------------------------------------------

    cpi R18, BUTTON_MAX_TICKS
    brsh check_stopwatch_time


    inc R18
    sts button_ticks, R18



; ============================================================
; CHECK STOPWATCH TIME
;
; MODE 0:
;
; 100 Timer1 interrupts
; 100 x 10 ms = 1 second
;
; MODE 1:
;
; 1000 Timer1 interrupts
; 1000 x 10 ms = 10 seconds
; ============================================================

check_stopwatch_time:

    lds R17, increment_mode

    tst R17
    breq check_1_second


; ============================================================
; CHECK 10 SECOND MODE
; ============================================================

check_10_seconds:

    lds R24, elapsed_lo
    lds R25, elapsed_hi


    ; 1000 decimal = 0x03E8

    cpi R24, low(1000)

    ldi R16, high(1000)
    cpc R25, R16


    ; If elapsed < 1000 ticks, we're done
    brlo timer_isr_done


    ; Otherwise 10 seconds have elapsed
    rjmp increment_counter



; ============================================================
; CHECK 1 SECOND MODE
; ============================================================

check_1_second:

    lds R24, elapsed_lo
    lds R25, elapsed_hi


    ; 100 decimal = 0x0064

    cpi R24, low(100)

    ldi R16, high(100)
    cpc R25, R16


    ; If elapsed < 100 ticks, we're done
    brlo timer_isr_done


    ; Otherwise 1 second has elapsed



; ============================================================
; INCREMENT STOPWATCH COUNTER
; ============================================================

increment_counter:

    ; Reset elapsed timer
    clr R16

    sts elapsed_lo, R16
    sts elapsed_hi, R16


    ; Get counter
    lds R16, counter_value

    ; Increment
    inc R16

    ; Keep only bottom four bits:
    ;
    ; 0 ... F then wrap back to 0
    andi R16, 0x0F

    sts counter_value, R16


    ; Tell main program to redraw display
    ldi R16, 1
    sts display_dirty, R16



; ============================================================
; FINISH INTERRUPT
; ============================================================

timer_isr_done:

    ; Restore registers
    pop R25
    pop R24
    pop R18
    pop R17

    pop R16
    out SREG, R16

    pop R16

    reti



; ============================================================
; DISPLAY SUBROUTINE
;
; R16 contains:
;
; bit 7   = decimal point
; bits 6:0 = segments
; ============================================================

display:

    push R16
    push R17

    in R17, SREG
    push R17


    ; Send all 8 bits
    ldi R17, 8


rotate_loop:

    ; Shift MSB into Carry
    lsl R16

    brcs set_ser_in_1


    ; SER = 0
    cbi PORTB, 0

    rjmp shift_clock


set_ser_in_1:

    ; SER = 1
    sbi PORTB, 0


shift_clock:

    ; Pulse shift-register clock
    sbi PORTB, 1
    cbi PORTB, 1

    dec R17
    brne rotate_loop


    ; Pulse latch clock
    sbi PORTB, 2
    cbi PORTB, 2


    ; Restore registers
    pop R17
    out SREG, R17

    pop R17
    pop R16

    ret



; ============================================================
; HEX TO 7-SEGMENT LOOKUP
;
; Input:
;     R16 = hexadecimal number 0-F
;
; Output:
;     R16 = corresponding segment pattern
; ============================================================

hex_to_seg:

    push R18
    push R19
    push R26
    push R27


    ; Force input into 0-F range
    andi R16, 0x0F


    ; X = address of lookup table
    ldi R26, low(lut)
    ldi R27, high(lut)


    clr R18

    ; X += R16
    add R26, R16
    adc R27, R18


    ; Load lookup-table value
    ld R19, X

    ; Return result in R16
    mov R16, R19


    pop R27
    pop R26
    pop R19
    pop R18

    ret


.exit