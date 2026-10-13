# Embedded Systems Labs

AVR assembly labs for the ATmega328P (Arduino Uno, 16 MHz), built in
Microchip Studio. Each lab is its own solution: `LabN/LabN.atsln`, with the
source in `LabN/LabN/main.asm`. Lab3 is the most up-to-date reference for
style.

## File layout

Keep sections in this order:

1. `.include "m328Pdef.inc"`
2. `.equ` constants: display patterns, pin numbers (grouped by port), timing
   values
3. `; REGISTER USAGE` block of global `.def`s
4. `.dseg` SRAM variables, only if needed
5. `.cseg`, reset vector (`.org 0x0000` / `jmp RESET`), then
   `.org INT_VECTORS_SIZE`
6. Lookup tables in flash (`.db`)
7. `RESET:` stack setup, then pin/peripheral setup, then initial state
8. `main_loop:`
9. Subroutines
10. `.exit` as the last line

## Formatting

- Indent instructions with 4 spaces. Never tabs.
- Labels start in column 0 on their own line.
- Lowercase mnemonics and register aliases (`ldi`, `rcall`, `counter`).
  Uppercase for I/O registers, bit names, and constants (`PORTB`, `OCF0A`,
  `TICKS_1S`). Registers are written `R16`, not `r16`.
- Inline comments line up: the `;` goes 20 characters past the indent
  (`    rjmp btn_up         ; not pressed`). If the instruction is longer,
  use one space before the `;`.
- One blank line after a label that starts a section, and between logical
  groups of instructions. No blank line after short local branch labels.
- Two blank lines between subroutines.
- No trailing whitespace.

## Naming

- Labels and register aliases: `snake_case` (`check_button`, `rpg_prev`).
  The one exception is `RESET`.
- Branch labels inside a subroutine share a short prefix from its name
  (`check_button` -> `btn_up`, `btn_short`, `btn_ret`; `countdown_tick` ->
  `cd_dec`, `cd_ret`).
- Constants: `UPPER_SNAKE_CASE`. Name pins by function and use them
  everywhere instead of raw bit numbers:

  ```asm
  .equ SR_SER   = 2      ; PB2 (Arduino pin 10)
  ...
      sbi DDRB, SR_SER
  ```

- Write bit masks with `(1<<NAME)`, not hex literals.

## Registers

- Global state lives in `R19`-`R25` with a `.def` alias, listed in the
  `; REGISTER USAGE` block with a short comment on what each holds.
- `R16`-`R18` are scratch. Add a comment line in the block saying so.
- For readability inside a subroutine, alias scratch registers locally with
  `.def` right after the label and `.undef` them right after `ret`.
- Subroutines `push`/`pop` any scratch register they use that isn't an
  input/output, in reverse order.
- Use `X`/`Y`/`Z` for 16-bit values and pointers (`adiw`, `lpm R16, Z`).

## Comments

- Comments explain *why* or what the hardware is doing, not restate the
  instruction. Keep them short and plain, in lowercase except for names.
  - Good: `brne main_loop      ; number selected, RPG disabled`
  - Bad: `brne main_loop      ; branch if not equal`
- Every pin setup line notes the Arduino pin and wiring
  (`; PD2 (Arduino pin 2), active low`).
- Every subroutine gets a header block, preceded by two blank lines:

  ```asm
  ; DIGIT TO 7-SEGMENT LOOKUP
  ; Input:  R16 = digit to display (0-9)
  ; Output: R16 = segment pattern for that digit
  ;
  ; A few sentences on how it works, if it isn't obvious.

  digit_to_seg:
  ```

  Small helpers can use a single sentence instead
  (`; Shifts R16 out on SER, MSB first.`).
- Comment group headings inside code are a short phrase on their own line
  (`; Shift register outputs`), followed by a blank line.
- Explain timing math where it's set up (prescaler, tick length, counts).

## Code conventions

- Initialize the stack first thing in `RESET`.
- Prefer `sbi`/`cbi`/`sbic`/`sbis` for single pins.
- Use `rcall`/`rjmp` within the file; `jmp` only for the reset vector.
- Lookup tables go in program memory with `.db` and are read with `lpm`
  (address is `lut*2`). Pad `.db` lines to an even byte count.
- Use `TIFR` flag polling for timing instead of busy-wait delay loops.
- Avoid `PC-n` relative branches; use a named label.
- Use named `.equ` constants instead of magic numbers in compares.
