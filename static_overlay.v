`timescale 1ns / 1ps

// =============================================================================
// Module : static_overlay
//
// Renders two lines of status text in the top-left corner of the video frame:
//   Line 0 (mode)   : BYPASS / SINGLE / TINT   / EXTRA
//   Line 1 (filter) : NONE / GRAY / INVERT / BRIGHT / THRESH /
//                     BLUE / GREEN / RED / PLASMA / SOUND / SPRITE
//
// Font    : 5x7 pixel bitmap, displayed at 2x scale (10x14 on screen).
// Layout  : Each character slot = 16 px wide (5*2 font + 3*2 gap, power-of-2).
//           Each line slot      = 16 px tall (7*2 font + 2*2 gap, power-of-2).
//           This allows char/line indexing by simple bit-select (no divider).
//
// Rendering:
//   - Semi-transparent dark-grey background box over the text area.
//   - White (#FFFFFF) text pixels, dark (#202020) background pixels.
//   - All other pixels pass the filtered video through unchanged.
//
// Character code table (5-bit internal index):
//   00=SPC  01=A  02=B  03=D  04=E  05=G  06=H  07=I
//   08=L    09=M  0A=N  0B=O  0C=P  0D=R  0E=S  0F=T
//   10=U    11=V  12=X  13=Y
// =============================================================================

module static_overlay #(
    parameter DATA_WIDTH = 24,
    parameter IMG_WIDTH  = 1920,
    parameter IMG_HEIGHT = 1080
)(
    input  wire                   clk,
    input  wire                   n_rst,

    input  wire [DATA_WIDTH-1:0]  i_vid_data,
    input  wire                   i_vid_hsync,
    input  wire                   i_vid_vsync,
    input  wire                   i_vid_VDE,

    output reg  [DATA_WIDTH-1:0]  o_vid_data,
    output reg                    o_vid_hsync,
    output reg                    o_vid_vsync,
    output reg                    o_vid_VDE,

    input  wire [1:0]             sw,
    input  wire [3:0]             btn
);

    // =========================================================================
    // Layout parameters
    // TEXT_X / TEXT_Y : top-left pixel of first character
    // CHAR_SLOT = 16  : px per char slot  (5 font + 3 gap) * scale=2
    // LINE_SLOT = 16  : px per line slot  (7 font + 1 gap) * scale=2
    // NUM_CHARS = 6   : characters per line
    // NUM_LINES = 2   : lines of text
    // =========================================================================
    localparam TEXT_X     = 8;
    localparam TEXT_Y     = 8;
    localparam CHAR_SLOT  = 16;   // power-of-2 - enables bit-select division
    localparam LINE_SLOT  = 16;   // power-of-2
    localparam NUM_CHARS  = 6;
    localparam NUM_LINES  = 2;

    // Background box with 4-pixel padding on every side
    localparam BG_X1 = TEXT_X - 4;                              // 4
    localparam BG_Y1 = TEXT_Y - 4;                              // 4
    localparam BG_X2 = TEXT_X + NUM_CHARS * CHAR_SLOT + 3;     // 107
    localparam BG_Y2 = TEXT_Y + NUM_LINES * LINE_SLOT + 3;     // 43

    // =========================================================================
    // Character code constants
    // =========================================================================
    localparam [4:0] CH_SPC = 5'h00;
    localparam [4:0] CH_A   = 5'h01;
    localparam [4:0] CH_B   = 5'h02;
    localparam [4:0] CH_D   = 5'h03;
    localparam [4:0] CH_E   = 5'h04;
    localparam [4:0] CH_G   = 5'h05;
    localparam [4:0] CH_H   = 5'h06;
    localparam [4:0] CH_I   = 5'h07;
    localparam [4:0] CH_L   = 5'h08;
    localparam [4:0] CH_M   = 5'h09;
    localparam [4:0] CH_N   = 5'h0A;
    localparam [4:0] CH_O   = 5'h0B;
    localparam [4:0] CH_P   = 5'h0C;
    localparam [4:0] CH_R   = 5'h0D;
    localparam [4:0] CH_S   = 5'h0E;
    localparam [4:0] CH_T   = 5'h0F;
    localparam [4:0] CH_U   = 5'h10;
    localparam [4:0] CH_V   = 5'h11;
    localparam [4:0] CH_X   = 5'h12;
    localparam [4:0] CH_Y   = 5'h13;

    // =========================================================================
    // Pixel counters
    // =========================================================================
    reg [$clog2(IMG_WIDTH)-1:0]  col_cnt;
    reg [$clog2(IMG_HEIGHT):0]   row_cnt;
    reg                           vde_prev, vsync_prev;

    wire vde_fall   = vde_prev  & ~i_vid_VDE;
    wire vsync_rise = ~vsync_prev & i_vid_vsync;

    // =========================================================================
    // Font ROM  - font_row_fn(char_code, row_idx) → 5-bit pixel pattern
    //   Bit[4] = leftmost pixel, Bit[0] = rightmost pixel
    // =========================================================================
    function [4:0] font_row_fn;
        input [4:0] char_code;
        input [2:0] row_idx;
        begin
            case (char_code)
                // ------- SPACE -------
                CH_SPC: font_row_fn = 5'b00000;

                // ------- A -------
                CH_A: case (row_idx)
                    3'd0: font_row_fn = 5'b01110;
                    3'd1: font_row_fn = 5'b10001;
                    3'd2: font_row_fn = 5'b10001;
                    3'd3: font_row_fn = 5'b11111;
                    3'd4: font_row_fn = 5'b10001;
                    3'd5: font_row_fn = 5'b10001;
                    3'd6: font_row_fn = 5'b10001;
                    default: font_row_fn = 5'b00000;
                endcase

                // ------- B -------
                CH_B: case (row_idx)
                    3'd0: font_row_fn = 5'b11110;
                    3'd1: font_row_fn = 5'b10001;
                    3'd2: font_row_fn = 5'b10001;
                    3'd3: font_row_fn = 5'b11110;
                    3'd4: font_row_fn = 5'b10001;
                    3'd5: font_row_fn = 5'b10001;
                    3'd6: font_row_fn = 5'b11110;
                    default: font_row_fn = 5'b00000;
                endcase

                // ------- D -------
                CH_D: case (row_idx)
                    3'd0: font_row_fn = 5'b11110;
                    3'd1: font_row_fn = 5'b10001;
                    3'd2: font_row_fn = 5'b10001;
                    3'd3: font_row_fn = 5'b10001;
                    3'd4: font_row_fn = 5'b10001;
                    3'd5: font_row_fn = 5'b10001;
                    3'd6: font_row_fn = 5'b11110;
                    default: font_row_fn = 5'b00000;
                endcase

                // ------- E -------
                CH_E: case (row_idx)
                    3'd0: font_row_fn = 5'b11111;
                    3'd1: font_row_fn = 5'b10000;
                    3'd2: font_row_fn = 5'b10000;
                    3'd3: font_row_fn = 5'b11110;
                    3'd4: font_row_fn = 5'b10000;
                    3'd5: font_row_fn = 5'b10000;
                    3'd6: font_row_fn = 5'b11111;
                    default: font_row_fn = 5'b00000;
                endcase

                // ------- G -------
                CH_G: case (row_idx)
                    3'd0: font_row_fn = 5'b01110;
                    3'd1: font_row_fn = 5'b10000;
                    3'd2: font_row_fn = 5'b10000;
                    3'd3: font_row_fn = 5'b10111;
                    3'd4: font_row_fn = 5'b10001;
                    3'd5: font_row_fn = 5'b10001;
                    3'd6: font_row_fn = 5'b01110;
                    default: font_row_fn = 5'b00000;
                endcase

                // ------- H -------
                CH_H: case (row_idx)
                    3'd0: font_row_fn = 5'b10001;
                    3'd1: font_row_fn = 5'b10001;
                    3'd2: font_row_fn = 5'b10001;
                    3'd3: font_row_fn = 5'b11111;
                    3'd4: font_row_fn = 5'b10001;
                    3'd5: font_row_fn = 5'b10001;
                    3'd6: font_row_fn = 5'b10001;
                    default: font_row_fn = 5'b00000;
                endcase

                // ------- I -------
                CH_I: case (row_idx)
                    3'd0: font_row_fn = 5'b11111;
                    3'd1: font_row_fn = 5'b00100;
                    3'd2: font_row_fn = 5'b00100;
                    3'd3: font_row_fn = 5'b00100;
                    3'd4: font_row_fn = 5'b00100;
                    3'd5: font_row_fn = 5'b00100;
                    3'd6: font_row_fn = 5'b11111;
                    default: font_row_fn = 5'b00000;
                endcase

                // ------- L -------
                CH_L: case (row_idx)
                    3'd0: font_row_fn = 5'b10000;
                    3'd1: font_row_fn = 5'b10000;
                    3'd2: font_row_fn = 5'b10000;
                    3'd3: font_row_fn = 5'b10000;
                    3'd4: font_row_fn = 5'b10000;
                    3'd5: font_row_fn = 5'b10000;
                    3'd6: font_row_fn = 5'b11111;
                    default: font_row_fn = 5'b00000;
                endcase

                // ------- M -------
                CH_M: case (row_idx)
                    3'd0: font_row_fn = 5'b10001;
                    3'd1: font_row_fn = 5'b11011;
                    3'd2: font_row_fn = 5'b10101;
                    3'd3: font_row_fn = 5'b10001;
                    3'd4: font_row_fn = 5'b10001;
                    3'd5: font_row_fn = 5'b10001;
                    3'd6: font_row_fn = 5'b10001;
                    default: font_row_fn = 5'b00000;
                endcase

                // ------- N -------
                CH_N: case (row_idx)
                    3'd0: font_row_fn = 5'b10001;
                    3'd1: font_row_fn = 5'b11001;
                    3'd2: font_row_fn = 5'b10101;
                    3'd3: font_row_fn = 5'b10011;
                    3'd4: font_row_fn = 5'b10001;
                    3'd5: font_row_fn = 5'b10001;
                    3'd6: font_row_fn = 5'b10001;
                    default: font_row_fn = 5'b00000;
                endcase

                // ------- O -------
                CH_O: case (row_idx)
                    3'd0: font_row_fn = 5'b01110;
                    3'd1: font_row_fn = 5'b10001;
                    3'd2: font_row_fn = 5'b10001;
                    3'd3: font_row_fn = 5'b10001;
                    3'd4: font_row_fn = 5'b10001;
                    3'd5: font_row_fn = 5'b10001;
                    3'd6: font_row_fn = 5'b01110;
                    default: font_row_fn = 5'b00000;
                endcase

                // ------- P -------
                CH_P: case (row_idx)
                    3'd0: font_row_fn = 5'b11110;
                    3'd1: font_row_fn = 5'b10001;
                    3'd2: font_row_fn = 5'b10001;
                    3'd3: font_row_fn = 5'b11110;
                    3'd4: font_row_fn = 5'b10000;
                    3'd5: font_row_fn = 5'b10000;
                    3'd6: font_row_fn = 5'b10000;
                    default: font_row_fn = 5'b00000;
                endcase

                // ------- R -------
                CH_R: case (row_idx)
                    3'd0: font_row_fn = 5'b11110;
                    3'd1: font_row_fn = 5'b10001;
                    3'd2: font_row_fn = 5'b10001;
                    3'd3: font_row_fn = 5'b11110;
                    3'd4: font_row_fn = 5'b10100;
                    3'd5: font_row_fn = 5'b10010;
                    3'd6: font_row_fn = 5'b10001;
                    default: font_row_fn = 5'b00000;
                endcase

                // ------- S -------
                CH_S: case (row_idx)
                    3'd0: font_row_fn = 5'b01111;
                    3'd1: font_row_fn = 5'b10000;
                    3'd2: font_row_fn = 5'b10000;
                    3'd3: font_row_fn = 5'b01110;
                    3'd4: font_row_fn = 5'b00001;
                    3'd5: font_row_fn = 5'b00001;
                    3'd6: font_row_fn = 5'b11110;
                    default: font_row_fn = 5'b00000;
                endcase

                // ------- T -------
                CH_T: case (row_idx)
                    3'd0: font_row_fn = 5'b11111;
                    3'd1: font_row_fn = 5'b00100;
                    3'd2: font_row_fn = 5'b00100;
                    3'd3: font_row_fn = 5'b00100;
                    3'd4: font_row_fn = 5'b00100;
                    3'd5: font_row_fn = 5'b00100;
                    3'd6: font_row_fn = 5'b00100;
                    default: font_row_fn = 5'b00000;
                endcase

                // ------- U -------
                CH_U: case (row_idx)
                    3'd0: font_row_fn = 5'b10001;
                    3'd1: font_row_fn = 5'b10001;
                    3'd2: font_row_fn = 5'b10001;
                    3'd3: font_row_fn = 5'b10001;
                    3'd4: font_row_fn = 5'b10001;
                    3'd5: font_row_fn = 5'b10001;
                    3'd6: font_row_fn = 5'b01110;
                    default: font_row_fn = 5'b00000;
                endcase

                // ------- V -------
                CH_V: case (row_idx)
                    3'd0: font_row_fn = 5'b10001;
                    3'd1: font_row_fn = 5'b10001;
                    3'd2: font_row_fn = 5'b10001;
                    3'd3: font_row_fn = 5'b10001;
                    3'd4: font_row_fn = 5'b01010;
                    3'd5: font_row_fn = 5'b01010;
                    3'd6: font_row_fn = 5'b00100;
                    default: font_row_fn = 5'b00000;
                endcase

                // ------- X -------
                CH_X: case (row_idx)
                    3'd0: font_row_fn = 5'b10001;
                    3'd1: font_row_fn = 5'b10001;
                    3'd2: font_row_fn = 5'b01010;
                    3'd3: font_row_fn = 5'b00100;
                    3'd4: font_row_fn = 5'b01010;
                    3'd5: font_row_fn = 5'b10001;
                    3'd6: font_row_fn = 5'b10001;
                    default: font_row_fn = 5'b00000;
                endcase

                // ------- Y -------
                CH_Y: case (row_idx)
                    3'd0: font_row_fn = 5'b10001;
                    3'd1: font_row_fn = 5'b10001;
                    3'd2: font_row_fn = 5'b01010;
                    3'd3: font_row_fn = 5'b00100;
                    3'd4: font_row_fn = 5'b00100;
                    3'd5: font_row_fn = 5'b00100;
                    3'd6: font_row_fn = 5'b00100;
                    default: font_row_fn = 5'b00000;
                endcase

                default: font_row_fn = 5'b00000;
            endcase
        end
    endfunction

    // =========================================================================
    // String lookup - string_char_fn(line, char_pos, sw, btn) → char_code
    //   line 0 = mode  (depends only on sw)
    //   line 1 = filter (depends on sw and btn)
    // =========================================================================
    function [4:0] string_char_fn;
        input        line;        // 0 = mode, 1 = filter
        input  [2:0] char_pos;   // 0..5
        input  [1:0] sw_in;
        input  [3:0] btn_in;
        begin
            if (line == 1'b0) begin
                // ---- Mode line ----
                case (sw_in)
                    2'b00: case (char_pos) // "BYPASS"
                        3'd0: string_char_fn = CH_B;
                        3'd1: string_char_fn = CH_Y;
                        3'd2: string_char_fn = CH_P;
                        3'd3: string_char_fn = CH_A;
                        3'd4: string_char_fn = CH_S;
                        3'd5: string_char_fn = CH_S;
                        default: string_char_fn = CH_SPC;
                    endcase
                    2'b01: case (char_pos) // "SINGLE"
                        3'd0: string_char_fn = CH_S;
                        3'd1: string_char_fn = CH_I;
                        3'd2: string_char_fn = CH_N;
                        3'd3: string_char_fn = CH_G;
                        3'd4: string_char_fn = CH_L;
                        3'd5: string_char_fn = CH_E;
                        default: string_char_fn = CH_SPC;
                    endcase
                    2'b10: case (char_pos) // "TINT  "
                        3'd0: string_char_fn = CH_T;
                        3'd1: string_char_fn = CH_I;
                        3'd2: string_char_fn = CH_N;
                        3'd3: string_char_fn = CH_T;
                        default: string_char_fn = CH_SPC;
                    endcase
                    2'b11: case (char_pos) // "EXTRA "
                        3'd0: string_char_fn = CH_E;
                        3'd1: string_char_fn = CH_X;
                        3'd2: string_char_fn = CH_T;
                        3'd3: string_char_fn = CH_R;
                        3'd4: string_char_fn = CH_A;
                        default: string_char_fn = CH_SPC;
                    endcase
                endcase
            end
            else begin
                // ---- Filter line ----
                case (sw_in)
                    // Bypass - no filter text
                    2'b00: string_char_fn = CH_SPC;

                    // Single-pixel filters
                    2'b01: begin
                        if (btn_in[0]) case (char_pos) // "GRAY  "
                            3'd0: string_char_fn = CH_G;
                            3'd1: string_char_fn = CH_R;
                            3'd2: string_char_fn = CH_A;
                            3'd3: string_char_fn = CH_Y;
                            default: string_char_fn = CH_SPC;
                        endcase
                        else if (btn_in[1]) case (char_pos) // "INVERT"
                            3'd0: string_char_fn = CH_I;
                            3'd1: string_char_fn = CH_N;
                            3'd2: string_char_fn = CH_V;
                            3'd3: string_char_fn = CH_E;
                            3'd4: string_char_fn = CH_R;
                            3'd5: string_char_fn = CH_T;
                            default: string_char_fn = CH_SPC;
                        endcase
                        else if (btn_in[2]) case (char_pos) // "BRIGHT"
                            3'd0: string_char_fn = CH_B;
                            3'd1: string_char_fn = CH_R;
                            3'd2: string_char_fn = CH_I;
                            3'd3: string_char_fn = CH_G;
                            3'd4: string_char_fn = CH_H;
                            3'd5: string_char_fn = CH_T;
                            default: string_char_fn = CH_SPC;
                        endcase
                        else if (btn_in[3]) case (char_pos) // "THRESH"
                            3'd0: string_char_fn = CH_T;
                            3'd1: string_char_fn = CH_H;
                            3'd2: string_char_fn = CH_R;
                            3'd3: string_char_fn = CH_E;
                            3'd4: string_char_fn = CH_S;
                            3'd5: string_char_fn = CH_H;
                            default: string_char_fn = CH_SPC;
                        endcase
                        else case (char_pos) // "NONE  "
                            3'd0: string_char_fn = CH_N;
                            3'd1: string_char_fn = CH_O;
                            3'd2: string_char_fn = CH_N;
                            3'd3: string_char_fn = CH_E;
                            default: string_char_fn = CH_SPC;
                        endcase
                    end

                    // Colour tint mode
                    2'b10: begin
                        if (btn_in[0]) case (char_pos) // "BLUE  "
                            3'd0: string_char_fn = CH_B;
                            3'd1: string_char_fn = CH_L;
                            3'd2: string_char_fn = CH_U;
                            3'd3: string_char_fn = CH_E;
                            default: string_char_fn = CH_SPC;
                        endcase
                        else if (btn_in[1]) case (char_pos) // "GREEN "
                            3'd0: string_char_fn = CH_G;
                            3'd1: string_char_fn = CH_R;
                            3'd2: string_char_fn = CH_E;
                            3'd3: string_char_fn = CH_E;
                            3'd4: string_char_fn = CH_N;
                            default: string_char_fn = CH_SPC;
                        endcase
                        else if (btn_in[2]) case (char_pos) // "RED   "
                            3'd0: string_char_fn = CH_R;
                            3'd1: string_char_fn = CH_E;
                            3'd2: string_char_fn = CH_D;
                            default: string_char_fn = CH_SPC;
                        endcase
                        else case (char_pos) // "NONE  "
                            3'd0: string_char_fn = CH_N;
                            3'd1: string_char_fn = CH_O;
                            3'd2: string_char_fn = CH_N;
                            3'd3: string_char_fn = CH_E;
                            default: string_char_fn = CH_SPC;
                        endcase
                    end

                    // Extra features
                    2'b11: begin
                        if (btn_in[0]) case (char_pos) // "PLASMA"
                            3'd0: string_char_fn = CH_P;
                            3'd1: string_char_fn = CH_L;
                            3'd2: string_char_fn = CH_A;
                            3'd3: string_char_fn = CH_S;
                            3'd4: string_char_fn = CH_M;
                            3'd5: string_char_fn = CH_A;
                            default: string_char_fn = CH_SPC;
                        endcase
                        else if (btn_in[1]) case (char_pos) // "SOUND "
                            3'd0: string_char_fn = CH_S;
                            3'd1: string_char_fn = CH_O;
                            3'd2: string_char_fn = CH_U;
                            3'd3: string_char_fn = CH_N;
                            3'd4: string_char_fn = CH_D;
                            default: string_char_fn = CH_SPC;
                        endcase
                        else if (btn_in[2]) case (char_pos) // "SPRITE"
                            3'd0: string_char_fn = CH_S;
                            3'd1: string_char_fn = CH_P;
                            3'd2: string_char_fn = CH_R;
                            3'd3: string_char_fn = CH_I;
                            3'd4: string_char_fn = CH_T;
                            3'd5: string_char_fn = CH_E;
                            default: string_char_fn = CH_SPC;
                        endcase
                        else string_char_fn = CH_SPC; // btn[3]=reserved or no button
                    end

                    default: string_char_fn = CH_SPC;
                endcase
            end
        end
    endfunction

    // =========================================================================
    // Overlay pixel computation (fully combinatorial)
    //
    // Pixel position arithmetic uses unsigned subtraction.
    // If col_cnt < TEXT_X then sx wraps to a huge value; in_text_x catches this.
    // Bit-selects exploit CHAR_SLOT=16 and LINE_SLOT=16 being powers of two:
    //   sx[6:4] → character index 0-5  (sx in 0..95)
    //   sx[3:1] → unscaled x within font (0-7; valid font cols = 0-4)
    //   sy[4]   → line index 0 or 1
    //   sy[3:1] → unscaled y within font (0-7; valid font rows = 0-6)
    // =========================================================================
    wire [10:0] sx = col_cnt[10:0] - TEXT_X[10:0];
    wire [10:0] sy = row_cnt[10:0] - TEXT_Y[10:0];

    // Is the current pixel inside the text columns / rows?
    wire in_text_x = (col_cnt >= TEXT_X) &&
                     (col_cnt <  TEXT_X + NUM_CHARS * CHAR_SLOT);  // < 104
    wire in_text_y = (row_cnt >= TEXT_Y) &&
                     (row_cnt <  TEXT_Y + NUM_LINES * LINE_SLOT);  // < 40

    // Is it inside the dark background box?
    wire in_bg = (col_cnt >= BG_X1) && (col_cnt <= BG_X2) &&
                 (row_cnt >= BG_Y1) && (row_cnt <= BG_Y2);

    // Break down pixel offset using bit-selection (division by power-of-2)
    wire [2:0] char_pos     = sx[6:4];   // which character (0-5)
    wire [2:0] font_col     = sx[3:1];   // unscaled x within char slot (0-7)
    wire       line_idx     = sy[4];     // which line (0 or 1)
    wire [2:0] font_row_idx = sy[3:1];   // unscaled y within line slot (0-7)

    // Gap pixels: char slot cols 5-7 and line slot row 7 are gaps, not font
    wire is_font_col = (font_col < 3'd5);
    wire is_font_row = (font_row_idx < 3'd7);
    wire is_text_pix = in_text_x && in_text_y && is_font_col && is_font_row;

    // Character and font lookup
    wire [4:0] char_code  = string_char_fn(line_idx, char_pos, sw, btn);
    wire [4:0] font_bits  = font_row_fn(char_code, font_row_idx);
    // font_col 0 → bit[4] (leftmost), font_col 4 → bit[0] (rightmost)
    wire       font_pixel = font_bits[4 - font_col[2:0]];

    // Final composited pixel:
    //   font pixel set  → white text
    //   inside BG box   → dark grey background
    //   otherwise       → pass video through unchanged
    wire [23:0] comp_pixel =
        (is_text_pix && font_pixel) ? 24'hFFFFFF :  // white text
        in_bg                       ? 24'h202020 :  // dark background
                                      i_vid_data;   // video passthrough

    // =========================================================================
    // Pixel counter update + registered output
    // =========================================================================
    always @(posedge clk) begin
        if (!n_rst) begin
            o_vid_data  <= 24'd0;
            o_vid_hsync <= 1'b0;
            o_vid_vsync <= 1'b0;
            o_vid_VDE   <= 1'b0;
            vde_prev    <= 1'b0;
            vsync_prev  <= 1'b0;
            col_cnt     <= 0;
            row_cnt     <= 0;
        end
        else begin
            vde_prev   <= i_vid_VDE;
            vsync_prev <= i_vid_vsync;

            // Pass sync signals through with one-cycle latency
            o_vid_hsync <= i_vid_hsync;
            o_vid_vsync <= i_vid_vsync;
            o_vid_VDE   <= i_vid_VDE;

            // Register the composited pixel
            o_vid_data <= i_vid_VDE ? comp_pixel : i_vid_data;

            // Column counter - increments during active video
            if (i_vid_VDE)
                col_cnt <= (col_cnt == IMG_WIDTH - 1) ? 0 : col_cnt + 1'b1;
            else
                col_cnt <= 0;

            // Row counter - increments at end of each active line
            if (vde_fall && (row_cnt < IMG_HEIGHT))
                row_cnt <= row_cnt + 1'b1;

            // Reset row counter on vsync
            if (vsync_rise)
                row_cnt <= 0;
        end
    end

endmodule
