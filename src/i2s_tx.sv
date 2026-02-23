// =============================================================================
// i2s_tx.sv
// Audrey Audio Controller — I2S Transmitter
//
// Project : rexta / Audrey
// Device  : Tang Nano 1K (Gowin GW1NZ-LV1)
// Author  : rexta project
// Version : 0.5 (back to v0.3 with inverted BCLK output)
//
// v0.3 produced data on DIN but transitions were on BCLK rising edge.
// Inverting BCLK output means the DAC sees transitions on its falling edge.
// =============================================================================

module i2s_tx (
    input  logic        clk,
    input  logic        rst_n,

    input  logic [15:0] left_in,
    input  logic [15:0] right_in,
    output logic        sample_req,

    output logic        bclk,
    output logic        lrclk,
    output logic        data
);

localparam HALF_PERIOD = 16;

logic [3:0] clk_div;
logic [5:0] bit_count;
logic       bclk_int;   // internal BCLK before inversion

// BCLK internal: high when clk_div < HALF_PERIOD/2
assign bclk_int = (clk_div < HALF_PERIOD / 2);

// Invert BCLK on output so data transitions appear on falling edge at DAC
assign bclk = ~bclk_int;

// LRCLK
assign lrclk = bit_count[5];

always @(posedge clk) begin
    if (!rst_n) begin
        clk_div    <= 4'h0;
        bit_count  <= 6'h0;
        sample_req <= 1'b0;
    end else begin
        sample_req <= 1'b0;

        if (clk_div == HALF_PERIOD - 1) begin
            clk_div <= 4'h0;
            if (bit_count == 6'd63) begin
                bit_count  <= 6'h0;
                sample_req <= 1'b1;
            end else begin
                bit_count <= bit_count + 6'h1;
            end
        end else begin
            clk_div <= clk_div + 4'h1;
        end
    end
end

// Sample latches
logic [15:0] left_latch;
logic [15:0] right_latch;

always @(posedge clk) begin
    if (!rst_n) begin
        left_latch  <= 16'h0;
        right_latch <= 16'h0;
    end else if (sample_req) begin
        left_latch  <= left_in;
        right_latch <= right_in;
    end
end

// Shift register — updates when bclk_int goes high (= BCLK output falling edge)
logic [15:0] shift_reg;

always @(posedge clk) begin
    if (!rst_n) begin
        shift_reg <= 16'h0;
        data      <= 1'b0;
    end else if (clk_div == HALF_PERIOD - 1) begin
        case (bit_count)
            6'd0: begin
                shift_reg <= {left_latch[14:0], 1'b0};
                data      <= left_latch[15];
            end
            6'd32: begin
                shift_reg <= {right_latch[14:0], 1'b0};
                data      <= right_latch[15];
            end
            6'd1,  6'd2,  6'd3,  6'd4,  6'd5,  6'd6,  6'd7,
            6'd8,  6'd9,  6'd10, 6'd11, 6'd12, 6'd13, 6'd14, 6'd15,
            6'd33, 6'd34, 6'd35, 6'd36, 6'd37, 6'd38, 6'd39,
            6'd40, 6'd41, 6'd42, 6'd43, 6'd44, 6'd45, 6'd46, 6'd47: begin
                data      <= shift_reg[15];
                shift_reg <= {shift_reg[14:0], 1'b0};
            end
            default: data <= 1'b0;
        endcase
    end
end

endmodule