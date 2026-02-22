// =============================================================================
// wavegen_adsr.sv
// Audrey Audio Controller — ADSR Envelope Generator
//
// Project : rexta / Audrey
// Device  : Tang Nano 1K (Gowin GW1NZ-LV1)
// Author  : rexta project
// Version : 0.1
//
// Produces an 8-bit envelope amplitude (0-255) based on ADSR parameters
// and the GATE input. One instance per voice.
//
// State machine:
//   IDLE    -> ATTACK  on GATE rising edge
//   ATTACK  -> DECAY   when envelope reaches 255
//   DECAY   -> SUSTAIN when envelope reaches sustain level
//   SUSTAIN -> RELEASE on GATE falling edge
//   RELEASE -> IDLE    when envelope reaches 0
//
// The envelope counter increments/decrements by 1 every N sample strobes,
// where N is determined by the attack/decay/release rate tables.
// Sustain is a target level, not a rate.
//
// Rate tables (samples per envelope step at 48kHz):
//   Attack  values: 2ms..8s   across 256 steps
//   Decay   values: 6ms..24s  across 256 steps
//   Release values: same table as decay
//
// Output envelope_out is applied to oscillator output by the top-level
// wrapper as: sample_out = (osc_out * envelope_out) >> 8
// =============================================================================

module wavegen_adsr (
    // -----------------------------------------------------------------
    // Clocks and reset
    // -----------------------------------------------------------------
    input  logic        clk,            // 49.152MHz audio clock
    input  logic        rst_n,          // active-low synchronous reset

    // -----------------------------------------------------------------
    // Sample strobe — asserted for one clk cycle every 48kHz period
    // -----------------------------------------------------------------
    input  logic        sample_strobe,

    // -----------------------------------------------------------------
    // ADSR parameters (from register file)
    // -----------------------------------------------------------------
    input  logic [3:0]  attack,         // attack  rate  (0-15)
    input  logic [3:0]  decay,          // decay   rate  (0-15)
    input  logic [3:0]  sustain,        // sustain level (0-15, scaled to 0-255)
    input  logic [3:0]  release_rate,        // release rate (0-15)

    // -----------------------------------------------------------------
    // Gate control
    // -----------------------------------------------------------------
    input  logic        gate,           // 1 = attack/decay/sustain, 0 = release

    // -----------------------------------------------------------------
    // Envelope output
    // -----------------------------------------------------------------
    output logic [7:0]  envelope_out    // 8-bit amplitude multiplier (0-255)
);

// =============================================================================
// State machine
// =============================================================================
typedef enum logic [2:0] {
    IDLE    = 3'd0,
    ATTACK  = 3'd1,
    DECAY   = 3'd2,
    SUSTAIN = 3'd3,
    RELEASE = 3'd4
} adsr_state_t;

adsr_state_t state;

// =============================================================================
// Gate edge detection
// =============================================================================
logic gate_prev;
logic gate_rise;
logic gate_fall;

always @(posedge clk) begin
    if (!rst_n) begin
        gate_prev <= 1'b0;
    end else if (sample_strobe) begin
        gate_prev <= gate;
    end
end

assign gate_rise = gate & ~gate_prev;
assign gate_fall = ~gate & gate_prev;

// =============================================================================
// Rate lookup tables
// Returns the number of sample strobes between each envelope step.
// 20-bit counter supports up to ~21 seconds at 48kHz.
// =============================================================================
logic [19:0] attack_rate;
logic [19:0] dr_rate;       // shared decay/release table

always_comb begin
    case (attack)
        4'd0:  attack_rate = 20'd1;
        4'd1:  attack_rate = 20'd2;
        4'd2:  attack_rate = 20'd3;
        4'd3:  attack_rate = 20'd4;
        4'd4:  attack_rate = 20'd7;
        4'd5:  attack_rate = 20'd10;
        4'd6:  attack_rate = 20'd13;
        4'd7:  attack_rate = 20'd15;
        4'd8:  attack_rate = 20'd19;
        4'd9:  attack_rate = 20'd47;
        4'd10: attack_rate = 20'd94;
        4'd11: attack_rate = 20'd150;
        4'd12: attack_rate = 20'd188;
        4'd13: attack_rate = 20'd562;
        4'd14: attack_rate = 20'd938;
        4'd15: attack_rate = 20'd1500;
        default: attack_rate = 20'd1;
    endcase
end

always_comb begin
    // Decay and release share the same rate table, selected by state
    logic [3:0] dr_sel;
    dr_sel = (state == DECAY) ? decay : release_rate;
    case (dr_sel)
        4'd0:  dr_rate = 20'd1;
        4'd1:  dr_rate = 20'd4;
        4'd2:  dr_rate = 20'd9;
        4'd3:  dr_rate = 20'd14;
        4'd4:  dr_rate = 20'd21;
        4'd5:  dr_rate = 20'd32;
        4'd6:  dr_rate = 20'd38;
        4'd7:  dr_rate = 20'd45;
        4'd8:  dr_rate = 20'd56;
        4'd9:  dr_rate = 20'd141;
        4'd10: dr_rate = 20'd281;
        4'd11: dr_rate = 20'd450;
        4'd12: dr_rate = 20'd562;
        4'd13: dr_rate = 20'd1688;
        4'd14: dr_rate = 20'd2812;
        4'd15: dr_rate = 20'd4500;
        default: dr_rate = 20'd1;
    endcase
end

// =============================================================================
// Sustain level scaling
// Sustain is 4-bit (0-15), scaled to 8-bit (0-255) by multiplying by 17.
// This gives: 0->0, 1->17, 8->136, 15->255
// =============================================================================
logic [7:0] sustain_level;
assign sustain_level = {sustain, sustain};  // replicate nibble: 0xS -> 0xSS

// =============================================================================
// Envelope counter and rate divider
// =============================================================================
logic [7:0]  envelope;      // current envelope value (0-255)
logic [19:0] rate_counter;  // counts sample strobes between steps
logic [19:0] current_rate;  // rate for current state

always_comb begin
    case (state)
        ATTACK:  current_rate = attack_rate;
        DECAY:   current_rate = dr_rate;
        RELEASE: current_rate = dr_rate;
        default: current_rate = 20'd1;
    endcase
end

always @(posedge clk) begin
    if (!rst_n) begin
        state        <= IDLE;
        envelope     <= 8'h00;
        rate_counter <= 20'h0;
    end else if (sample_strobe) begin

        // --- Gate edge handling (highest priority) ---
        if (gate_rise) begin
            state        <= ATTACK;
            rate_counter <= 20'h0;
            // Note: don't reset envelope on re-trigger — allows retriggering
            // mid-release to produce natural-sounding re-attack from current level
        end else if (gate_fall) begin
            state        <= RELEASE;
            rate_counter <= 20'h0;
        end else begin

            // --- State machine ---
            case (state)

                IDLE: begin
                    envelope <= 8'h00;
                end

                ATTACK: begin
                    if (rate_counter >= current_rate - 1) begin
                        rate_counter <= 20'h0;
                        if (envelope == 8'hFF) begin
                            state <= DECAY;
                        end else begin
                            envelope <= envelope + 8'h01;
                        end
                    end else begin
                        rate_counter <= rate_counter + 20'h1;
                    end
                end

                DECAY: begin
                    if (envelope <= sustain_level) begin
                        state <= SUSTAIN;
                    end else if (rate_counter >= current_rate - 1) begin
                        rate_counter <= 20'h0;
                        envelope     <= envelope - 8'h01;
                    end else begin
                        rate_counter <= rate_counter + 20'h1;
                    end
                end

                SUSTAIN: begin
                    // Hold at sustain level — gate fall handled above
                    envelope <= sustain_level;
                end

                RELEASE: begin
                    if (envelope == 8'h00) begin
                        state <= IDLE;
                    end else if (rate_counter >= current_rate - 1) begin
                        rate_counter <= 20'h0;
                        envelope     <= envelope - 8'h01;
                    end else begin
                        rate_counter <= rate_counter + 20'h1;
                    end
                end

                default: state <= IDLE;

            endcase
        end
    end
end

assign envelope_out = envelope;

endmodule