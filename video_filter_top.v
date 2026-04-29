`timescale 1ns / 1ps

module video_filter_top #
(
    parameter DATA_WIDTH = 24
)
(
    input  wire                   clk,
    input  wire                   n_rst,

    // Video input
    input  wire [DATA_WIDTH-1:0]  i_vid_data,
    input  wire                   i_vid_hsync,
    input  wire                   i_vid_vsync,
    input  wire                   i_vid_VDE,

    // Control
    input  wire [3:0]             btn,
    input  wire [1:0]             sw,

    // LED debug
    output wire [3:0]             led,

    // Video output
    output wire [DATA_WIDTH-1:0]  o_vid_data,
    output wire                   o_vid_hsync,
    output wire                   o_vid_vsync,
    output wire                   o_vid_VDE
);

    // -------------------------------------------------------------------------
    // Mode control signals
    // use_multi_pixel now means "colour tint mode" (sw == 2'b10)
    // -------------------------------------------------------------------------
    wire use_bypass;
    wire use_single_pixel;
    wire use_multi_pixel;   // reused as use_tint — sw == 2'b10
    wire use_extra;
    wire extra_motion_det;

    assign led[0] = use_bypass;
    assign led[1] = use_single_pixel;
    assign led[2] = use_multi_pixel;
    assign led[3] = use_extra & extra_motion_det;

    // -------------------------------------------------------------------------
    // Sub-module output wires
    // -------------------------------------------------------------------------
    wire [DATA_WIDTH-1:0] single_vid_data;
    wire                  single_vid_hsync;
    wire                  single_vid_vsync;
    wire                  single_vid_VDE;

    // sw==10 → colour tint (replaces multi-pixel)
    wire [DATA_WIDTH-1:0] tint_vid_data;
    wire                  tint_vid_hsync;
    wire                  tint_vid_vsync;
    wire                  tint_vid_VDE;

    wire [DATA_WIDTH-1:0] extra_vid_data;
    wire                  extra_vid_hsync;
    wire                  extra_vid_vsync;
    wire                  extra_vid_VDE;

    // -------------------------------------------------------------------------
    // Mux output (feeds into static_overlay)
    // -------------------------------------------------------------------------
    reg  [DATA_WIDTH-1:0] mux_vid_data;
    reg                   mux_vid_hsync;
    reg                   mux_vid_vsync;
    reg                   mux_vid_VDE;

    // -------------------------------------------------------------------------
    // Mode controller  (unchanged — use_multi_pixel fires on sw==2'b10)
    // -------------------------------------------------------------------------
    mode_controller mode_ctrl_inst (
        .sw(sw),
        .use_bypass(use_bypass),
        .use_single_pixel(use_single_pixel),
        .use_multi_pixel(use_multi_pixel),
        .use_extra(use_extra),
        .led()
    );

    // -------------------------------------------------------------------------
    // Single-pixel filter  (sw == 2'b01)
    // -------------------------------------------------------------------------
    my_filter single_filter_inst (
        .clk(clk),
        .n_rst(n_rst),
        .i_vid_data(i_vid_data),
        .i_vid_hsync(i_vid_hsync),
        .i_vid_vsync(i_vid_vsync),
        .i_vid_VDE(i_vid_VDE),
        .o_vid_data(single_vid_data),
        .o_vid_hsync(single_vid_hsync),
        .o_vid_vsync(single_vid_vsync),
        .o_vid_VDE(single_vid_VDE),
        .btn(btn)
    );

    // -------------------------------------------------------------------------
    // Colour tint  (sw == 2'b10)
    //   btn[0] = BLUE tint
    //   btn[1] = GREEN tint
    //   btn[2] = RED tint
    //   no btn = passthrough
    // -------------------------------------------------------------------------
    colour_tint #(
        .DATA_WIDTH(DATA_WIDTH)
    ) tint_inst (
        .clk(clk),
        .n_rst(n_rst),
        .i_vid_data(i_vid_data),
        .i_vid_hsync(i_vid_hsync),
        .i_vid_vsync(i_vid_vsync),
        .i_vid_VDE(i_vid_VDE),
        .o_vid_data(tint_vid_data),
        .o_vid_hsync(tint_vid_hsync),
        .o_vid_vsync(tint_vid_vsync),
        .o_vid_VDE(tint_vid_VDE),
        .btn(btn)
    );

    // -------------------------------------------------------------------------
    // Extra features  (sw == 2'b11)
    // -------------------------------------------------------------------------
    extra_features #(
        .DATA_WIDTH(DATA_WIDTH),
        .IMG_WIDTH (1920),
        .IMG_HEIGHT(1080)
    ) extra_inst (
        .clk         (clk),
        .n_rst       (n_rst),
        .i_vid_data  (i_vid_data),
        .i_vid_hsync (i_vid_hsync),
        .i_vid_vsync (i_vid_vsync),
        .i_vid_VDE   (i_vid_VDE),
        .o_vid_data  (extra_vid_data),
        .o_vid_hsync (extra_vid_hsync),
        .o_vid_vsync (extra_vid_vsync),
        .o_vid_VDE   (extra_vid_VDE),
        .o_motion_det(extra_motion_det),
        .btn         (btn)
    );

    // -------------------------------------------------------------------------
    // Mode selection mux
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!n_rst) begin
            mux_vid_data  <= 0;
            mux_vid_hsync <= 0;
            mux_vid_vsync <= 0;
            mux_vid_VDE   <= 0;
        end
        else begin
            if (use_bypass) begin
                mux_vid_data  <= i_vid_data;
                mux_vid_hsync <= i_vid_hsync;
                mux_vid_vsync <= i_vid_vsync;
                mux_vid_VDE   <= i_vid_VDE;
            end
            else if (use_single_pixel) begin
                mux_vid_data  <= single_vid_data;
                mux_vid_hsync <= single_vid_hsync;
                mux_vid_vsync <= single_vid_vsync;
                mux_vid_VDE   <= single_vid_VDE;
            end
            else if (use_multi_pixel) begin   // sw==10 → colour tint
                mux_vid_data  <= tint_vid_data;
                mux_vid_hsync <= tint_vid_hsync;
                mux_vid_vsync <= tint_vid_vsync;
                mux_vid_VDE   <= tint_vid_VDE;
            end
            else begin                         // sw==11 → extra features
                mux_vid_data  <= extra_vid_data;
                mux_vid_hsync <= extra_vid_hsync;
                mux_vid_vsync <= extra_vid_vsync;
                mux_vid_VDE   <= extra_vid_VDE;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Static overlay — composites status text, drives final HDMI output
    // -------------------------------------------------------------------------
    static_overlay #(
        .DATA_WIDTH(DATA_WIDTH),
        .IMG_WIDTH (1920),
        .IMG_HEIGHT(1080)
    ) overlay_inst (
        .clk        (clk),
        .n_rst      (n_rst),
        .i_vid_data (mux_vid_data),
        .i_vid_hsync(mux_vid_hsync),
        .i_vid_vsync(mux_vid_vsync),
        .i_vid_VDE  (mux_vid_VDE),
        .o_vid_data (o_vid_data),
        .o_vid_hsync(o_vid_hsync),
        .o_vid_vsync(o_vid_vsync),
        .o_vid_VDE  (o_vid_VDE),
        .sw         (sw),
        .btn        (btn)
    );

endmodule
