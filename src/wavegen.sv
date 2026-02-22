// =============================================================================
// wavegen.sv
// Audrey Audio Controller — Complete Voice Engine (Oscillator + ADSR)
//
// Project : rexta / Audrey
// Device  : Tang Nano 1K (Gowin GW1NZ-LV1)
// Author  : rexta project
// Version : 0.1
//
// Top-level wrapper instantiating:
//   - wavegen_osc  : phase accumulator + waveform generators
//   - wavegen_adsr : ADSR envelope generator
//
// The oscillator output (16-bit signed) is multiplied by the envelope
// (8-bit unsigned, 0-255) and scaled back to 16-bit signed:
//
//   sample_out = (osc_out * envelope) >> 8
//
// This multiplication is signed x unsigned, handled by sign-extending
// the envelope to match. The Tang Nano 1K has DSP blocks that will
// absorb this multiply cleanly without eating LUTs.
//
// Instantiate 8 of these for the full Audrey voice array.
// =============================================================================

module wavegen (
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
    // Oscillator registers
    // -----------------------------------------------------------------
    input  logic [15:0] freq,           // 16-bit frequency word
    input  logic [11:0] pulse_width,    // 12-bit pulse width (0x000-0xFFF)
    input  logic [7:0]  wave_ctrl,      // waveform select + control flags

    // -----------------------------------------------------------------
    // ADSR registers
    // -----------------------------------------------------------------
    input  logic [3:0]  attack,         // attack rate  (0-15)
    input  logic [3:0]  decay,          // decay rate   (0-15)
    input  logic [3:0]  sustain,        // sustain level (0-15)
    input  logic [3:0]  release_rate,   // release rate (0-15)

    // -----------------------------------------------------------------
    // Cross-voice connections (for ring mod / hard sync)
    // -----------------------------------------------------------------
    input  logic        next_msb,       // MSB of next voice accumulator
    input  logic        next_sync,      // sync pulse from next voice
    output logic        this_msb,       // our accumulator MSB
    output logic        this_sync,      // our sync pulse

    // -----------------------------------------------------------------
    // Audio output
    // -----------------------------------------------------------------
    output logic [15:0] sample_out      // 16-bit signed PCM sample
);

// =============================================================================
// Oscillator instance
// =============================================================================
logic [15:0] osc_out;

wavegen_osc osc (
    .clk           (clk),
    .rst_n         (rst_n),
    .sample_strobe (sample_strobe),
    .freq          (freq),
    .pulse_width   (pulse_width),
    .wave_ctrl     (wave_ctrl),
    .env_vol       (8'hFF),             // full volume - envelope applied below
    .next_msb      (next_msb),
    .next_sync     (next_sync),
    .this_msb      (this_msb),
    .this_sync     (this_sync),
    .sample_out    (osc_out)
);

// =============================================================================
// ADSR envelope instance
// Gate is wave_ctrl[0] (the GATE bit)
// =============================================================================
logic [7:0] envelope;

wavegen_adsr adsr (
    .clk           (clk),
    .rst_n         (rst_n),
    .sample_strobe (sample_strobe),
    .attack        (attack),
    .decay         (decay),
    .sustain       (sustain),
    .release_rate  (release_rate),
    .gate          (wave_ctrl[0]),      // GATE bit from wave_ctrl register
    .envelope_out  (envelope)
);

// =============================================================================
// Envelope multiply
//
// osc_out  : 16-bit signed  (-32768..+32752)
// envelope :  8-bit unsigned (0..255)
//
// Multiply: 16-bit signed x 8-bit unsigned = 24-bit signed result
// We take bits [23:8] of the result to scale back to 16-bit.
//
// When envelope = 0x00 -> silence
// When envelope = 0xFF -> ~full amplitude (255/256 of original)
//
// The multiply is registered to give the synthesiser flexibility and
// to avoid a long combinational path.
// =============================================================================
logic signed [23:0] multiply_result;
logic signed [15:0] osc_signed;

assign osc_signed      = osc_out;
assign multiply_result = osc_signed * $signed({1'b0, envelope});

always @(posedge clk) begin
    if (!rst_n) begin
        sample_out <= 16'h0;
    end else if (sample_strobe) begin
        sample_out <= multiply_result[23:8];
    end
end

endmodule