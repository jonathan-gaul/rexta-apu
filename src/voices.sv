// =============================================================================
// voices.sv
// Audrey Audio Controller — 4-Voice Time-Multiplexed Engine
//
// Project : rexta / Audrey
// Device  : Tang Nano 1K (Gowin GW1NZ-LV1)
// Author  : rexta project
// Version : 0.3 (time-multiplexed, single engine, 4 voice register bank)
//
// A single voice engine processes all 4 voices sequentially within each
// sample period. At 48.6MHz with 47kHz sample rate there are ~1024 clock
// cycles per sample. Processing 4 voices takes ~20 cycles each = ~80 cycles
// total, leaving ~944 cycles idle. Completely inaudible.
//
// Per-voice state (saved/restored each sample):
//   phase_acc   : 32 bits  phase accumulator
//   lfsr        : 23 bits  noise LFSR
//   adsr_state  :  3 bits  ADSR state machine
//   envelope    :  8 bits  current envelope value
//   rate_cnt    : 13 bits  ADSR rate counter
//   gate_prev   :  1 bit   previous gate value for edge detection
//   voice_out   : 16 bits  last computed sample output
//
// Register interface:
//   Currently all voice parameters are hardwired internally.
//   TODO: Replace with SPI register file inputs:
//     freq        [0:3] : 16-bit frequency word per voice
//     pulse_width [0:3] : 12-bit pulse width per voice
//     wave_ctrl   [0:3] :  8-bit waveform control per voice
//     attack      [0:3] :  4-bit attack  rate per voice
//     decay       [0:3] :  4-bit decay   rate per voice
//     sustain     [0:3] :  4-bit sustain level per voice
//     release_rate[0:3] :  4-bit release rate per voice
// =============================================================================

module voices (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        sample_strobe,

    output logic [15:0] left_out,
    output logic [15:0] right_out
);

// =============================================================================
// Voice parameters — hardwired for initial test
// TODO: Replace with SPI register file inputs (see module header)
// =============================================================================
logic [15:0] freq        [0:3];
logic [11:0] pulse_width [0:3];
logic [7:0]  wave_ctrl   [0:3];
logic [3:0]  attack      [0:3];
logic [3:0]  decay       [0:3];
logic [3:0]  sustain     [0:3];
logic [3:0]  release_rate[0:3];

genvar r;
generate
    for (r = 0; r < 4; r++) begin : regs
        assign freq[r]         = 16'h0261;
        assign pulse_width[r]  = 12'h800;
        assign wave_ctrl[r]    = 8'b0010_0001;  // SAW + GATE
        assign attack[r]       = 4'd1;
        assign decay[r]        = 4'd0;
        assign sustain[r]      = 4'd15;
        assign release_rate[r] = 4'd3;
    end
endgenerate

// =============================================================================
// Per-voice state registers
// =============================================================================
logic [31:0] v_phase_acc  [0:3];
logic [22:0] v_lfsr       [0:3];
logic [2:0]  v_adsr_state [0:3];
logic [7:0]  v_envelope   [0:3];
logic [12:0] v_rate_cnt   [0:3];
logic        v_gate_prev  [0:3];
logic [15:0] v_out        [0:3];

// =============================================================================
// Sequencer state
// =============================================================================
typedef enum logic [2:0] {
    SEQ_IDLE    = 3'd0,
    SEQ_LOAD    = 3'd1,
    SEQ_OSC     = 3'd2,
    SEQ_ADSR    = 3'd3,
    SEQ_MUL     = 3'd4,
    SEQ_SAVE    = 3'd5,
    SEQ_MIX     = 3'd6
} seq_state_t;

seq_state_t seq_state;
logic [1:0]  voice_idx;     // current voice being processed (0-3)
logic        processing;    // true while processing voices

// =============================================================================
// Working registers (loaded from voice state bank)
// =============================================================================
logic [31:0] w_phase_acc;
logic [22:0] w_lfsr;
logic [2:0]  w_adsr_state;
logic [7:0]  w_envelope;
logic [12:0] w_rate_cnt;
logic        w_gate_prev;

// Current voice parameters
logic [15:0] w_freq;
logic [11:0] w_pw;
logic [7:0]  w_wc;
logic [3:0]  w_attack;
logic [3:0]  w_decay;
logic [3:0]  w_sustain;
logic [3:0]  w_release;

// =============================================================================
// Oscillator combinational logic (operates on working registers)
// =============================================================================

// Phase accumulator next value
logic [32:0] acc_sum;
logic        phase_overflow;
assign acc_sum       = {1'b0, w_phase_acc} + {1'b0, {w_freq, 16'h0}};
assign phase_overflow = acc_sum[32];

// Waveform generators
logic [11:0] wave_saw;
logic [11:0] wave_tri;
logic [11:0] wave_pulse;
logic [11:0] wave_noise;
logic [11:0] wave_sine;

assign wave_saw   = w_phase_acc[31:20];
assign wave_tri   = w_phase_acc[31] ? (12'hFFF - {1'b0, w_phase_acc[30:20]})
                                     : {1'b0, w_phase_acc[30:20]};
assign wave_pulse = (w_phase_acc[31:20] >= w_pw) ? 12'hFFF : 12'h000;

// Noise - combinational LFSR next value
logic [22:0] lfsr_next;
assign lfsr_next = phase_overflow ? {w_lfsr[21:0], w_lfsr[22] ^ w_lfsr[17]}
                                  : w_lfsr;

assign wave_noise = {w_lfsr[20], w_lfsr[18], w_lfsr[14], w_lfsr[11],
                     w_lfsr[9],  w_lfsr[5],  w_lfsr[2],  w_lfsr[0],
                     4'b0000};

// Sine LUT (16-point quarter wave)
logic [1:0]  sine_q;
logic [3:0]  sine_idx;
logic [10:0] sine_lut;

assign sine_q   = w_phase_acc[31:30];
assign sine_idx = w_phase_acc[29:26];

always_comb begin
    case (sine_idx)
        4'd0:  sine_lut = 11'd0;
        4'd1:  sine_lut = 11'd201;
        4'd2:  sine_lut = 11'd399;
        4'd3:  sine_lut = 11'd594;
        4'd4:  sine_lut = 11'd783;
        4'd5:  sine_lut = 11'd965;
        4'd6:  sine_lut = 11'd1137;
        4'd7:  sine_lut = 11'd1299;
        4'd8:  sine_lut = 11'd1447;
        4'd9:  sine_lut = 11'd1582;
        4'd10: sine_lut = 11'd1702;
        4'd11: sine_lut = 11'd1805;
        4'd12: sine_lut = 11'd1891;
        4'd13: sine_lut = 11'd1959;
        4'd14: sine_lut = 11'd2008;
        4'd15: sine_lut = 11'd2037;
        default: sine_lut = 11'd0;
    endcase
end

always_comb begin
    case (sine_q)
        2'd0: wave_sine = 12'd2048 + {1'b0, sine_lut};
        2'd1: wave_sine = 12'd4095 - {1'b0, sine_lut};
        2'd2: wave_sine = 12'd2048 - {1'b0, sine_lut};
        2'd3: wave_sine = 12'd1    + {1'b0, sine_lut};
        default: wave_sine = 12'd2048;
    endcase
end

// Waveform combiner
logic [11:0] waveform_combined;
logic        any_wave;

assign any_wave = w_wc[7] | w_wc[6] | w_wc[5] | w_wc[4] | w_wc[3];

assign waveform_combined = !any_wave          ? 12'h000 :
                           (w_wc[5] ? wave_saw   : 12'hFFF) &
                           (w_wc[4] ? wave_tri   : 12'hFFF) &
                           (w_wc[6] ? wave_pulse : 12'hFFF) &
                           (w_wc[7] ? wave_noise : 12'hFFF) &
                           (w_wc[3] ? wave_sine  : 12'hFFF);

// Oscillator output (before envelope)
logic [15:0] osc_out;
assign osc_out = {waveform_combined, 4'b0000} - 16'h8000;

// =============================================================================
// ADSR combinational logic
// =============================================================================

// ADSR state encoding
localparam ADSR_IDLE    = 3'd0;
localparam ADSR_ATTACK  = 3'd1;
localparam ADSR_DECAY   = 3'd2;
localparam ADSR_SUSTAIN = 3'd3;
localparam ADSR_RELEASE = 3'd4;

// Gate edge detection
logic gate_cur;
logic gate_rise;
logic gate_fall;
assign gate_cur  = w_wc[0];
assign gate_rise = gate_cur & ~w_gate_prev;
assign gate_fall = ~gate_cur & w_gate_prev;

// Sustain level scaling
logic [7:0] sustain_level;
assign sustain_level = {w_sustain, w_sustain};

// Rate tables
logic [12:0] attack_rate;
logic [12:0] dr_rate;

always_comb begin
    case (w_attack)
        4'd0:  attack_rate = 13'd1;
        4'd1:  attack_rate = 13'd2;
        4'd2:  attack_rate = 13'd3;
        4'd3:  attack_rate = 13'd4;
        4'd4:  attack_rate = 13'd7;
        4'd5:  attack_rate = 13'd10;
        4'd6:  attack_rate = 13'd13;
        4'd7:  attack_rate = 13'd15;
        4'd8:  attack_rate = 13'd19;
        4'd9:  attack_rate = 13'd47;
        4'd10: attack_rate = 13'd94;
        4'd11: attack_rate = 13'd150;
        4'd12: attack_rate = 13'd188;
        4'd13: attack_rate = 13'd562;
        4'd14: attack_rate = 13'd938;
        4'd15: attack_rate = 13'd1500;
        default: attack_rate = 13'd1;
    endcase
end

always_comb begin
    logic [3:0] dr_sel;
    dr_sel = (w_adsr_state == ADSR_DECAY) ? w_decay : w_release;
    case (dr_sel)
        4'd0:  dr_rate = 13'd1;
        4'd1:  dr_rate = 13'd4;
        4'd2:  dr_rate = 13'd9;
        4'd3:  dr_rate = 13'd14;
        4'd4:  dr_rate = 13'd21;
        4'd5:  dr_rate = 13'd32;
        4'd6:  dr_rate = 13'd38;
        4'd7:  dr_rate = 13'd45;
        4'd8:  dr_rate = 13'd56;
        4'd9:  dr_rate = 13'd141;
        4'd10: dr_rate = 13'd281;
        4'd11: dr_rate = 13'd450;
        4'd12: dr_rate = 13'd562;
        4'd13: dr_rate = 13'd1688;
        4'd14: dr_rate = 13'd2812;
        4'd15: dr_rate = 13'd4500;
        default: dr_rate = 13'd1;
    endcase
end

logic [12:0] current_rate;
always_comb begin
    case (w_adsr_state)
        ADSR_ATTACK:  current_rate = attack_rate;
        ADSR_DECAY:   current_rate = dr_rate;
        ADSR_RELEASE: current_rate = dr_rate;
        default:      current_rate = 13'd1;
    endcase
end

// =============================================================================
// Envelope multiply
// =============================================================================
logic signed [23:0] mul_result;
assign mul_result = $signed(osc_out) * $signed({1'b0, w_envelope});

// =============================================================================
// Sequencer state machine
// Processes each voice in turn within the sample period
// =============================================================================
integer v;

always @(posedge clk) begin
    if (!rst_n) begin
        seq_state <= SEQ_IDLE;
        voice_idx <= 2'd0;
        left_out  <= 16'h0;
        right_out <= 16'h0;

        for (v = 0; v < 4; v = v + 1) begin
            v_phase_acc [v] <= 32'h0;
            v_lfsr      [v] <= 23'h7FFFFF;
            v_adsr_state[v] <= ADSR_IDLE;
            v_envelope  [v] <= 8'h0;
            v_rate_cnt  [v] <= 13'h0;
            v_gate_prev [v] <= 1'b0;
            v_out       [v] <= 16'h0;
        end

        w_phase_acc  <= 32'h0;
        w_lfsr       <= 23'h7FFFFF;
        w_adsr_state <= ADSR_IDLE;
        w_envelope   <= 8'h0;
        w_rate_cnt   <= 13'h0;
        w_gate_prev  <= 1'b0;
        w_freq       <= 16'h0;
        w_pw         <= 12'h0;
        w_wc         <= 8'h0;
        w_attack     <= 4'h0;
        w_decay      <= 4'h0;
        w_sustain    <= 4'h0;
        w_release    <= 4'h0;

    end else begin
        case (seq_state)

            SEQ_IDLE: begin
                if (sample_strobe) begin
                    voice_idx <= 2'd0;
                    seq_state <= SEQ_LOAD;
                end
            end

            SEQ_LOAD: begin
                // Load working registers from voice state bank
                w_phase_acc  <= v_phase_acc [voice_idx];
                w_lfsr       <= v_lfsr      [voice_idx];
                w_adsr_state <= v_adsr_state[voice_idx];
                w_envelope   <= v_envelope  [voice_idx];
                w_rate_cnt   <= v_rate_cnt  [voice_idx];
                w_gate_prev  <= v_gate_prev [voice_idx];
                w_freq       <= freq        [voice_idx];
                w_pw         <= pulse_width [voice_idx];
                w_wc         <= wave_ctrl   [voice_idx];
                w_attack     <= attack      [voice_idx];
                w_decay      <= decay       [voice_idx];
                w_sustain    <= sustain     [voice_idx];
                w_release    <= release_rate[voice_idx];
                seq_state    <= SEQ_OSC;
            end

            SEQ_OSC: begin
                // Advance phase accumulator
                // Combinational logic (acc_sum, waveforms) already computed
                if (w_wc[1] && 1'b0) begin  // SYNC disabled for now
                    w_phase_acc <= 32'h0;
                end else begin
                    w_phase_acc <= acc_sum[31:0];
                end
                w_lfsr    <= lfsr_next;
                seq_state <= SEQ_ADSR;
            end

            SEQ_ADSR: begin
                // Run ADSR state machine for this voice
                if (gate_rise || (w_adsr_state == ADSR_IDLE && gate_cur)) begin
                    w_adsr_state <= ADSR_ATTACK;
                    w_rate_cnt   <= 13'h0;
                end else if (gate_fall) begin
                    w_adsr_state <= ADSR_RELEASE;
                    w_rate_cnt   <= 13'h0;
                end else begin
                    case (w_adsr_state)
                        ADSR_IDLE: begin
                            w_envelope <= 8'h0;
                        end
                        ADSR_ATTACK: begin
                            if (w_envelope == 8'hFF) begin
                                w_adsr_state <= ADSR_DECAY;
                                w_rate_cnt   <= 13'h0;
                            end else if (w_rate_cnt >= current_rate - 1) begin
                                w_rate_cnt <= 13'h0;
                                w_envelope <= w_envelope + 8'h1;
                            end else begin
                                w_rate_cnt <= w_rate_cnt + 13'h1;
                            end
                        end
                        ADSR_DECAY: begin
                            if (w_envelope <= sustain_level) begin
                                w_adsr_state <= ADSR_SUSTAIN;
                            end else if (w_rate_cnt >= current_rate - 1) begin
                                w_rate_cnt <= 13'h0;
                                w_envelope <= w_envelope - 8'h1;
                            end else begin
                                w_rate_cnt <= w_rate_cnt + 13'h1;
                            end
                        end
                        ADSR_SUSTAIN: begin
                            w_envelope <= sustain_level;
                        end
                        ADSR_RELEASE: begin
                            if (w_envelope == 8'h0) begin
                                w_adsr_state <= ADSR_IDLE;
                            end else if (w_rate_cnt >= current_rate - 1) begin
                                w_rate_cnt <= 13'h0;
                                w_envelope <= w_envelope - 8'h1;
                            end else begin
                                w_rate_cnt <= w_rate_cnt + 13'h1;
                            end
                        end
                        default: w_adsr_state <= ADSR_IDLE;
                    endcase
                end
                w_gate_prev <= gate_cur;
                seq_state   <= SEQ_MUL;
            end

            SEQ_MUL: begin
                // mul_result is combinational — just register the output
                // and save state back to voice bank
                v_phase_acc [voice_idx] <= w_phase_acc;
                v_lfsr      [voice_idx] <= w_lfsr;
                v_adsr_state[voice_idx] <= w_adsr_state;
                v_envelope  [voice_idx] <= w_envelope;
                v_rate_cnt  [voice_idx] <= w_rate_cnt;
                v_gate_prev [voice_idx] <= w_gate_prev;
                v_out       [voice_idx] <= mul_result[23:8];
                seq_state               <= SEQ_SAVE;
            end

            SEQ_SAVE: begin
                if (voice_idx == 2'd3) begin
                    seq_state <= SEQ_MIX;
                end else begin
                    voice_idx <= voice_idx + 2'd1;
                    seq_state <= SEQ_LOAD;
                end
            end

            SEQ_MIX: begin
                // Sum all 4 voice outputs and barrel shift right by 2
                logic signed [17:0] mix;
                mix = $signed({{2{v_out[0][15]}}, v_out[0]}) +
                      $signed({{2{v_out[1][15]}}, v_out[1]}) +
                      $signed({{2{v_out[2][15]}}, v_out[2]}) +
                      $signed({{2{v_out[3][15]}}, v_out[3]});
                left_out  <= mix[17:2];
                right_out <= mix[17:2];
                seq_state <= SEQ_IDLE;
            end

            default: seq_state <= SEQ_IDLE;

        endcase
    end
end

endmodule