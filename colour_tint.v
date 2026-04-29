`timescale 1ns / 1ps

// =============================================================================
// Module : colour_tint
//
// Applies a colour tint to incoming video based on btn:
//   btn[0] = BLUE  tint  (boost blue,  halve red and green)
//   btn[1] = GREEN tint  (boost green, halve red and blue)
//   btn[2] = RED   tint  (boost red,   halve green and blue)
//   no btn = passthrough
//
// Activated when sw == 2'b10.
// All sync signals are registered with the same one-cycle latency as the data.
// =============================================================================

module colour_tint #(
    parameter DATA_WIDTH = 24
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

    input  wire [3:0]             btn
);

    // Unpack channels — same {red, blu, gre} convention used across all modules
    wire [7:0] red_in = i_vid_data[23:16];
    wire [7:0] blu_in = i_vid_data[15:8];
    wire [7:0] gre_in = i_vid_data[7:0];

    // ── Tint computation (combinatorial) ─────────────────────────────────────
    // "Halve" a channel:  >> 1  (saturates at 0, max 127)
    // "Full" a channel:   leave unchanged
    // "Boost" a channel:  clamp-add 40 to push it brighter without overflow

    function [7:0] boost;
        input [7:0] ch;
        begin
            boost = (ch > 8'd215) ? 8'd255 : ch + 8'd40;
        end
    endfunction

    reg [7:0] r_out, g_out, b_out;

    always @(*) begin
        if (btn[0]) begin
            // BLUE tint
            r_out = red_in >> 1;
            g_out = gre_in >> 1;
            b_out = boost(blu_in);
        end
        else if (btn[1]) begin
            // GREEN tint
            r_out = red_in >> 1;
            g_out = boost(gre_in);
            b_out = blu_in >> 1;
        end
        else if (btn[2]) begin
            // RED tint
            r_out = boost(red_in);
            g_out = gre_in >> 1;
            b_out = blu_in >> 1;
        end
        else begin
            // No button held — passthrough
            r_out = red_in;
            g_out = gre_in;
            b_out = blu_in;
        end
    end

    // ── Registered output ─────────────────────────────────────────────────────
    always @(posedge clk) begin
        if (!n_rst) begin
            o_vid_data  <= 24'd0;
            o_vid_hsync <= 1'b0;
            o_vid_vsync <= 1'b0;
            o_vid_VDE   <= 1'b0;
        end
        else begin
            o_vid_hsync <= i_vid_hsync;
            o_vid_vsync <= i_vid_vsync;
            o_vid_VDE   <= i_vid_VDE;
            o_vid_data  <= i_vid_VDE ? {r_out, b_out, g_out} : i_vid_data;
        end
    end

endmodule
