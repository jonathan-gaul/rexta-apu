// =============================================================================
// audrey_top_test.sv
// Audrey — First Audio Test Top Level
//
// Project : rexta / Audrey
// Device  : Tang Nano 1K (Gowin GW1NZ-LV1)
// Author  : rexta project
// Version : 0.4 (4-voice array)
// =============================================================================

module audrey_top_test (
    input  logic clk_27m,

    output logic i2s_bclk,
    output logic i2s_lrclk,
    output logic i2s_data,

    output logic led_r,
    output logic led_g,
    output logic led_b,

    output logic dbg_req
);

// =============================================================================
// PLL — 27MHz -> 48.6MHz
// =============================================================================
logic clk_audio;
logic pll_locked;

Gowin_rPLL pll (
    .clkin  (clk_27m),
    .clkout (clk_audio)
);

assign pll_locked = 1'b1;

// =============================================================================
// Reset
// =============================================================================
logic [7:0] reset_counter;
logic       rst_n;

always @(posedge clk_audio) begin
    if (!pll_locked) begin
        reset_counter <= 8'h0;
        rst_n         <= 1'b0;
    end else if (!rst_n) begin
        if (reset_counter == 8'hFF)
            rst_n <= 1'b1;
        else
            reset_counter <= reset_counter + 8'h1;
    end
end

// =============================================================================
// I2S transmitter
// =============================================================================
logic        sample_req;
logic [15:0] left_sample;
logic [15:0] right_sample;

i2s_tx i2s (
    .clk        (clk_audio),
    .rst_n      (rst_n),
    .left_in    (left_sample),
    .right_in   (right_sample),
    .sample_req (sample_req),
    .bclk       (i2s_bclk),
    .lrclk      (i2s_lrclk),
    .data       (i2s_data)
);

// =============================================================================
// 4-voice array
// =============================================================================
voices v (
    .clk          (clk_audio),
    .rst_n        (rst_n),
    .sample_strobe(sample_req),
    .left_out     (left_sample),
    .right_out    (right_sample)
);

// =============================================================================
// Heartbeat LED and debug
// =============================================================================
logic [25:0] led_counter;
always @(posedge clk_audio) begin
    if (!rst_n)
        led_counter <= 26'h0;
    else
        led_counter <= led_counter + 26'h1;
end

assign led_r   = 1'b1;
assign led_g   = ~led_counter[25];
assign led_b   = 1'b1;
assign dbg_req = sample_req;

endmodule