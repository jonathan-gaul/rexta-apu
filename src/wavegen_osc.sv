// =============================================================================
// wavegen_osc.sv
// Audrey Audio Controller — Oscillator Core
//
// Project : rexta / Audrey
// Device  : Tang Nano 1K (Gowin GW1NZ-LV1)
// Author  : rexta project
// Version : 0.3 (all waveform fixes applied)
//
// Instantiated by wavegen.sv (top-level voice wrapper).
//
// Waveforms:
//   - Sawtooth
//   - Triangle  (with ring modulation)
//   - Pulse     (variable duty cycle, 12-bit PW)
//   - Noise     (23-bit LFSR, MOS 6581 feedback taps, overflow-clocked)
//   - Sine      (32-point quarter-wave LUT, quadrant mirrored)
//
// Multi-waveform AND supported (authentic SID behaviour).
//
// Changes in v0.3:
//   - Triangle uses subtraction not bitwise NOT (correct symmetric fold)
//   - Noise LFSR clocked from accumulator overflow not bit-22 edge
//   - Sine upgraded to 32-point quarter-wave LUT
//   - Sine Q3 formula corrected to 1 + lut (mirrors Q2)
//   - Waveform combiner uses pure assign (Icarus compat)
//   - any_wave uses explicit OR chain
//   - Module renamed to wavegen_osc
// =============================================================================

module wavegen_osc (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        sample_strobe,

    input  logic [15:0] freq,
    input  logic [11:0] pulse_width,
    input  logic [7:0]  wave_ctrl,
    input  logic [7:0]  env_vol,        // reserved, unused until ADSR integration

    input  logic        next_msb,
    input  logic        next_sync,
    output logic        this_msb,
    output logic        this_sync,

    output logic [15:0] sample_out
);

// =============================================================================
// wave_ctrl bit assignments
// [7] NOISE  [6] PULSE  [5] SAW  [4] TRI  [3] SINE  [2] RING_MOD  [1] SYNC  [0] GATE
// =============================================================================
localparam WC_NOISE    = 7;
localparam WC_PULSE    = 6;
localparam WC_SAW      = 5;
localparam WC_TRI      = 4;
localparam WC_SINE     = 3;
localparam WC_RING_MOD = 2;
localparam WC_SYNC     = 1;
localparam WC_GATE     = 0;

// =============================================================================
// Register latch
// =============================================================================
logic [15:0] freq_r;
logic [11:0] pw_r;
logic [7:0]  wc_r;

always @(posedge clk) begin
    if (!rst_n) begin
        freq_r <= 16'h0;
        pw_r   <= 12'h0;
        wc_r   <= 8'h0;
    end else if (sample_strobe) begin
        freq_r <= freq;
        pw_r   <= pulse_width;
        wc_r   <= wave_ctrl;
    end
end

// =============================================================================
// Phase accumulator
// Incremented by {freq_r, 16'h0} each sample strobe.
// 33-bit sum captures carry for overflow detection and hard sync pulse.
//
// Frequency: output_freq = (freq / 2^16) * (48000 / 2^16) Hz
// e.g. 440Hz => freq = round(440 * 2^32 / 48000) >> 16 = 0x0253
// =============================================================================
logic [31:0] phase_acc;
logic        phase_overflow;
logic [32:0] acc_sum;

always_comb begin
    acc_sum = {1'b0, phase_acc} + {1'b0, {freq_r, 16'h0}};
end

always @(posedge clk) begin
    if (!rst_n) begin
        phase_acc      <= 32'h0;
        phase_overflow <= 1'b0;
    end else if (sample_strobe) begin
        if (wc_r[WC_SYNC] && next_sync) begin
            phase_acc      <= 32'h0;
            phase_overflow <= 1'b0;
        end else begin
            phase_acc      <= acc_sum[31:0];
            phase_overflow <= acc_sum[32];
        end
    end
end

assign this_msb  = phase_acc[31];
assign this_sync = phase_overflow;

// =============================================================================
// Waveform generators — all produce 12-bit unsigned (0x000-0xFFF)
// =============================================================================

// --- Sawtooth ---
logic [11:0] wave_saw;
assign wave_saw = phase_acc[31:20];

// --- Triangle ---
// Fold: rising for lower half (MSB=0), falling for upper half (MSB=1).
// Subtraction gives correct symmetric triangle (not bitwise NOT).
// Ring mod XORs fold direction with next voice MSB.
logic [11:0] wave_tri;
logic        tri_fold;
assign tri_fold = wc_r[WC_RING_MOD] ? (phase_acc[31] ^ next_msb) : phase_acc[31];
assign wave_tri = tri_fold ? (12'hFFF - {1'b0, phase_acc[30:20]})
                           : {1'b0, phase_acc[30:20]};

// --- Pulse ---
// All-ones when top 12 bits of accumulator >= pulse width threshold.
logic [11:0] wave_pulse;
assign wave_pulse = (phase_acc[31:20] >= pw_r) ? 12'hFFF : 12'h000;

// --- Noise (LFSR) ---
// 23-bit maximal-length LFSR, MOS 6581 feedback taps (bits 22 and 17).
// Clocked on accumulator overflow — ties noise rate to oscillator frequency.
logic [22:0] lfsr;
logic [11:0] wave_noise;

always @(posedge clk) begin
    if (!rst_n) begin
        lfsr <= 23'h7FFFFF;
    end else if (sample_strobe) begin
        if (phase_overflow) begin
            lfsr <= {lfsr[21:0], lfsr[22] ^ lfsr[17]};
        end
    end
end

assign wave_noise = {lfsr[20], lfsr[18], lfsr[14], lfsr[11],
                     lfsr[9],  lfsr[5],  lfsr[2],  lfsr[0],
                     4'b0000};

// --- Sine ---
// 32-point quarter-wave LUT, mirrored across quadrants.
// LUT: round(2047 * sin(n * pi/2 / 32)) for n = 0..31
//
// Output centred at 0x800 (unsigned), so output stage subtract gives signed:
//   Q0 (0-90):    0x800 rising  to 0xFFF  = 2048 + lut
//   Q1 (90-180):  0xFFF falling to 0x800  = 4095 - lut
//   Q2 (180-270): 0x800 falling to 0x001  = 2048 - lut
//   Q3 (270-360): 0x001 rising  to 0x800  = 1    + lut
logic [1:0]  sine_q;
logic [4:0]  sine_idx;
logic [10:0] sine_lut;
logic [11:0] wave_sine;

assign sine_q   = phase_acc[31:30];
assign sine_idx = phase_acc[29:25];

always_comb begin
    case (sine_idx)
        5'd0:  sine_lut = 11'd0;
        5'd1:  sine_lut = 11'd100;
        5'd2:  sine_lut = 11'd201;
        5'd3:  sine_lut = 11'd300;
        5'd4:  sine_lut = 11'd399;
        5'd5:  sine_lut = 11'd497;
        5'd6:  sine_lut = 11'd594;
        5'd7:  sine_lut = 11'd690;
        5'd8:  sine_lut = 11'd783;
        5'd9:  sine_lut = 11'd875;
        5'd10: sine_lut = 11'd965;
        5'd11: sine_lut = 11'd1052;
        5'd12: sine_lut = 11'd1137;
        5'd13: sine_lut = 11'd1219;
        5'd14: sine_lut = 11'd1299;
        5'd15: sine_lut = 11'd1375;
        5'd16: sine_lut = 11'd1447;
        5'd17: sine_lut = 11'd1517;
        5'd18: sine_lut = 11'd1582;
        5'd19: sine_lut = 11'd1644;
        5'd20: sine_lut = 11'd1702;
        5'd21: sine_lut = 11'd1756;
        5'd22: sine_lut = 11'd1805;
        5'd23: sine_lut = 11'd1850;
        5'd24: sine_lut = 11'd1891;
        5'd25: sine_lut = 11'd1927;
        5'd26: sine_lut = 11'd1959;
        5'd27: sine_lut = 11'd1986;
        5'd28: sine_lut = 11'd2008;
        5'd29: sine_lut = 11'd2025;
        5'd30: sine_lut = 11'd2037;
        5'd31: sine_lut = 11'd2045;
        default: sine_lut = 11'd0;
    endcase
end

always_comb begin
    case (sine_q)
        2'd0: wave_sine = 12'd2048 + {1'b0, sine_lut};  // 0x800->0xFFF rising
        2'd1: wave_sine = 12'd4095 - {1'b0, sine_lut};  // 0xFFF->0x800 falling
        2'd2: wave_sine = 12'd2048 - {1'b0, sine_lut};  // 0x800->0x001 falling
        2'd3: wave_sine = 12'd1    + {1'b0, sine_lut};  // 0x001->0x800 rising
        default: wave_sine = 12'd2048;
    endcase
end

// =============================================================================
// Multi-waveform AND combiner
// Pure assign avoids Icarus "constant selects in always_*" limitation.
// Each wave ANDs as 12'hFFF (identity) when not selected.
// =============================================================================
logic [11:0] waveform_combined;
logic        any_wave;

assign any_wave = wc_r[7] | wc_r[6] | wc_r[5] | wc_r[4] | wc_r[3];

assign waveform_combined = !any_wave         ? 12'h000 :
                           (wc_r[5] ? wave_saw   : 12'hFFF) &
                           (wc_r[4] ? wave_tri   : 12'hFFF) &
                           (wc_r[6] ? wave_pulse : 12'hFFF) &
                           (wc_r[7] ? wave_noise : 12'hFFF) &
                           (wc_r[3] ? wave_sine  : 12'hFFF);

// =============================================================================
// Output stage
// 12-bit unsigned -> 16-bit signed:
//   shift left 4 -> 0x0000-0xFFF0
//   subtract 0x8000 -> -32768..+32752
// =============================================================================
always @(posedge clk) begin
    if (!rst_n) begin
        sample_out <= 16'h0;
    end else if (sample_strobe) begin
        sample_out <= {waveform_combined, 4'b0000} - 16'h8000;
    end
end

// Suppress unused input warnings - env_vol used by wrapper, GATE used by ADSR
(* keep *) logic _unused = &{env_vol, wave_ctrl[0]};

endmodule