// =============================================================================
// i2s_tx.sv
// Audrey Audio Controller — I2S Transmitter
//
// Project : rexta / Audrey
// Device  : Tang Nano 1K (Gowin GW1NZ-LV1)
// Author  : rexta project
// Version : 0.1
//
// Drives a standard I2S interface suitable for the PCM5102A DAC.
//
// Signal timing (standard I2S, Philips format):
//   - LRCLK low  = left  channel
//   - LRCLK high = right channel
//   - Data is MSB first, transitions on BCLK falling edge,
//     captured by DAC on BCLK rising edge
//   - Data is delayed one BCLK cycle after LRCLK transition (I2S format)
//
// Parameters:
//   MCLK_DIV : divide clk_audio to produce BCLK
//               clk_audio = 49.152MHz
//               BCLK = 48kHz * 16 bits * 2 ch = 1.536MHz
//               49.152MHz / 1.536MHz = 32 -> MCLK_DIV = 16 (toggle = half period)
//
// Sample strobe:
//   The i2s_tx generates its own sample_strobe output, asserted when it
//   needs a new stereo sample pair. This replaces the external strobe used
//   during simulation — the I2S timing IS the sample clock.
//
// PCM5102A pin connections:
//   BCK  <- bclk
//   LRCK <- lrclk
//   DIN  <- data
//   SCK  <- leave floating or tie to MCLK if available (PCM5102A has internal PLL)
//   FMT  <- GND (I2S format)
//   DEMP <- GND (no de-emphasis)
//   XSMT <- VCC (unmute)
//   FLT  <- GND (normal latency filter)
// =============================================================================

module i2s_tx (
    // -----------------------------------------------------------------
    // Clock and reset
    // -----------------------------------------------------------------
    input  logic        clk,            // 49.152MHz audio clock
    input  logic        rst_n,

    // -----------------------------------------------------------------
    // Sample input — latched when sample_req is asserted
    // -----------------------------------------------------------------
    input  logic [15:0] left_in,        // 16-bit signed left  channel
    input  logic [15:0] right_in,       // 16-bit signed right channel
    output logic        sample_req,     // asserted one clk before new sample needed

    // -----------------------------------------------------------------
    // I2S output pins
    // -----------------------------------------------------------------
    output logic        bclk,           // bit clock  (1.536MHz)
    output logic        lrclk,          // LR clock   (48kHz)
    output logic        data            // serial data (MSB first)
);

// =============================================================================
// Clock divider — generate BCLK at 1.536MHz from 49.152MHz
// 49.152 / 1.536 = 32, so toggle every 16 clk cycles
// =============================================================================
localparam BCLK_DIV = 16;              // toggle period in clk cycles

logic [4:0] bclk_counter;
logic       bclk_rise;                 // one clk pulse on BCLK rising edge
logic       bclk_fall;                 // one clk pulse on BCLK falling edge

always @(posedge clk) begin
    if (!rst_n) begin
        bclk_counter <= 5'h0;
        bclk         <= 1'b0;
    end else begin
        if (bclk_counter == BCLK_DIV - 1) begin
            bclk_counter <= 5'h0;
            bclk         <= ~bclk;
        end else begin
            bclk_counter <= bclk_counter + 5'h1;
        end
    end
end

// Edge detection on bclk
logic bclk_prev;
always @(posedge clk) bclk_prev <= bclk;
assign bclk_rise = bclk & ~bclk_prev;
assign bclk_fall = ~bclk & bclk_prev;

// =============================================================================
// Bit counter and LRCLK generation
// 32 BCLK cycles per channel (16 data bits + 16 padding), 64 total per frame
// LRCLK toggles every 32 BCLK cycles
// =============================================================================
logic [5:0] bit_counter;   // 0-63 across full stereo frame

always @(posedge clk) begin
    if (!rst_n) begin
        bit_counter <= 6'h0;
        lrclk       <= 1'b0;
    end else if (bclk_rise) begin
        if (bit_counter == 6'd63) begin
            bit_counter <= 6'h0;
        end else begin
            bit_counter <= bit_counter + 6'h1;
        end
        // LRCLK: low for bits 0-31 (left), high for bits 32-63 (right)
        lrclk <= bit_counter[5];
    end
end

// =============================================================================
// Shift register — load on LRCLK transition, shift on BCLK falling edge
//
// I2S format: data transitions on falling BCLK, one cycle after LRCLK edge.
// So we load the shift register one BCLK after the transition.
//
// Shift register is 16 bits. After 16 bits are sent the remaining
// 16 BCLK cycles of each half-frame output 0 (padding for 16-bit in 32-bit slot).
// =============================================================================
logic [15:0] shift_reg;
logic [3:0]  bit_index;     // which bit of the 16-bit word we're sending (0-15)
logic        sending;        // true during the 16 data bits

always @(posedge clk) begin
    if (!rst_n) begin
        shift_reg  <= 16'h0;
        bit_index  <= 4'h0;
        sending    <= 1'b0;
        data       <= 1'b0;
        sample_req <= 1'b0;
    end else begin
        sample_req <= 1'b0;

        if (bclk_fall) begin
            // Detect LRCLK transitions (bit 0 and bit 32 of frame)
            if (bit_counter == 6'd0) begin
                // Left channel start — load left sample, delay one cycle (I2S format)
                shift_reg <= left_in;
                bit_index <= 4'h0;
                sending   <= 1'b1;
                data      <= left_in[15];   // MSB first
            end else if (bit_counter == 6'd32) begin
                // Right channel start
                shift_reg  <= right_in;
                bit_index  <= 4'h0;
                sending    <= 1'b1;
                data       <= right_in[15];
                // Request new sample pair — gives the voice engine one full
                // frame period (1/48kHz = ~1024 clk cycles) to produce it
                sample_req <= 1'b1;
            end else if (sending) begin
                if (bit_index == 4'd14) begin
                    // Last shift — next cycle outputs bit 0, then padding
                    data      <= shift_reg[14];
                    shift_reg <= {shift_reg[13:0], 1'b0};
                    bit_index <= bit_index + 4'h1;
                end else if (bit_index == 4'd15) begin
                    // Done with data bits — output 0 for padding
                    data    <= 1'b0;
                    sending <= 1'b0;
                end else begin
                    data      <= shift_reg[14];
                    shift_reg <= {shift_reg[13:0], 1'b0};
                    bit_index <= bit_index + 4'h1;
                end
            end else begin
                data <= 1'b0;   // padding bits
            end
        end
    end
end

endmodule