// samegame_pkg.sv
//
// Shared constants for the "さめがめ" (SameGame) FPGA implementation.
// Imported by every game-logic module so that the board geometry, the empty
// marker and the colour depth stay consistent across the design.

package samegame_pkg;

    // board geometry (fixed by the specification)
    localparam int COLS = 16;             // 16 columns
    localparam int ROWS = 12;             // 12 rows
    localparam int BLOCK = 20;            // block size, pixels
    localparam int SCREEN_W = 320;        // COLS * BLOCK
    localparam int SCREEN_H = 240;        // ROWS * BLOCK
    localparam int CELLS  = COLS * ROWS;  // 192 cells

    // cell encoding (3 bit): 0..4 = Logo0..Logo4, 7 = Empty
    localparam logic [2:0] EMPTY  = 3'b111;
    localparam logic [2:0] NLOGO  = 3'd5;   // number of distinct logos

    // logo ROM geometry
    localparam int LOGO_W = 20;
    localparam int LOGO_H = 20;
    localparam int LOGO_PIXELS = LOGO_W * LOGO_H;      // 400
    localparam int ROM_DEPTH  = 5 * LOGO_PIXELS;       // 2000 entries

    // animation speed (spec: 5 pixel / frame)
    localparam int ANIM_STEP = 5;
    localparam int FRAMES_PER_CELL = BLOCK / ANIM_STEP; // 4

    // erase blink (spec: 6 frames)
    localparam int BLINK_FRAMES = 6;

endpackage
