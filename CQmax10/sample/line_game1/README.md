# 1-Key Line Game (MAX10 + PMOD-TFTLCD/ILI9341)

## Files

```
rtl/reset_sync.sv        external reset button -> sync internal reset
rtl/debounce.sv           button debouncer
rtl/spi_byte_master.sv    write-only SPI byte engine (mode 0, MSB first)
rtl/font5x7_pkg.sv         5x7 digit font (0-9) for the score readout
rtl/lcd_ili9341_ctrl.sv   ILI9341 init + a single FILL_RECT primitive
rtl/game_core.sv           game logic: movement, collision, score, FSM
rtl/line_game_top.sv       top level / pin-facing module
line_game_pins.tcl         Quartus pin + I/O standard assignments
```

## Quartus setup
1. New Project Wizard: device **10M08SCE144C8G**, top-level entity `line_game_top`.
2. Add all files under `rtl/` as design files (SystemVerilog).
3. Run `line_game_pins.tcl` (Tools -> Tcl Scripts...) to apply pin locations,
   or transcribe the assignments into your own `.qsf` by hand.
4. Compile, then verify the Fitter didn't drop `collision_mem` to logic
   cells — it should show up as an M9K instance in the Fitter report. If it
   doesn't (e.g. because of how your Quartus version infers memory from a
   packed-array-of-bits declaration), the fallback is to add
   `(* ramstyle = "M9K" *)` right above the `collision_mem` declaration in
   `game_core.sv`.

## How it plays
- Line starts at (0,0) and grows one pixel per tick, diagonally
  down-right by default.
- Hold **Button A**: the line's vertical direction flips to up-right.
  Release: back to down-right. Horizontal direction only changes when the
  line bounces off the left/right field edges (x=0, x=319).
- Game over when the line would cross y=0 or y=200 (the game
  field/info-area boundary), or when it re-crosses a pixel it has already
  drawn.
- On game over: ~2s pause, then release+press the button to restart.
- Score (pixels drawn) is shown in green in the 320x40 info strip at the
  bottom, redrawn each step it changes.

## Things I could not verify without hardware/simulation — check these first
This was written directly to spec without access to a simulator or the
actual PMOD-TFTLCD/CQ-MAX10-A schematics, so please simulate (or at least
carefully desk-check) before programming the board. Specific spots most
likely to need correction, based on how the previous ILI9341 bring-up
went:

- **Button/reset polarity** — `debounce.sv`/`reset_sync.sv` assume both
  pins are pulled high externally (idle=1, pressed=0). If your board
  wires them the other way, flip the inversion in those two files (or
  enable the on-chip weak pull-ups in `line_game_pins.tcl` if there's no
  external resistor at all).
- **No hardware LCD reset pin** — the pin table has no RESX line, so
  `lcd_ili9341_ctrl.sv` resets the panel purely with the SWRESET (0x01)
  command. This only works if RESX is tied to a pull-up on the PMOD
  board. If it's tied to another GPIO instead, that pin needs to be added
  and driven high for a few ms before `rst` is released.
- **MADCTL / orientation** — `MADCTL_VALUE = 8'h28` is a common
  landscape default, not verified against your specific panel mounting.
  If the image is rotated or mirrored, try `8'h48`, `8'h88`, or `8'hE8`
  (these swap the row/column/BGR bits) — similar to the orientation fix
  needed during the Tang Primer / PMOD-TFTLCD bring-up.
- **SPI clock rate** — `SCLK_HALF_CYCLES=2` gives 12.5 MHz. The ILI9341
  datasheet's write cycle time suggests this is safely within spec, but
  slow it down (increase the parameter) if you see corrupted writes.
- **Timing** — `STEP_MS=20` (50 steps/sec) is a guess at a playable
  speed; it's a parameter on `game_core`, easy to retune.
- The whole design is written with the synthesis-safe style you've
  used before (no behavioural `initial` blocks other than the constant
  ROM preload in the LCD controller, which Quartus treats as memory
  initialization data, not simulation-only behavior).

## Possible follow-ups
- A real "GAME OVER" message reusing the font ROM (currently only digits
  0-9 are defined).
- Double-buffering / partial-window optimizations if the SPI clock needs
  to be conservative and pixel draws start to lag the tick rate.
