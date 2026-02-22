// =============================================================================
// wavegen_tb.sv
// Testbench for wavegen oscillator core
//
// Simulates the 49.152MHz audio clock, generates sample_strobe at 48kHz,
// and exercises each waveform in turn.
//
// To view waveforms: dump to VCD and open in GTKWave.
// Each waveform is run for 256 samples (enough to see several cycles at
// a mid-range frequency).
// =============================================================================

`timescale 1ns/1ps

module wavegen_tb;

// ---------------------------------------------------------------------------
// Clock parameters
// 49.152MHz => period = ~20.345ns, we'll use 20ns for simplicity
// Sample strobe every 1024 cycles => every 20480ns (~48.83kHz, close enough)
// ---------------------------------------------------------------------------
localparam CLK_PERIOD    = 20;      // ns
localparam STROBE_PERIOD = 1024;    // clocks per sample

// ---------------------------------------------------------------------------
// DUT signals
// ---------------------------------------------------------------------------
logic        clk;
logic        rst_n;
logic        sample_strobe;

logic [15:0] freq;
logic [11:0] pulse_width;
logic [7:0]  wave_ctrl;
logic [7:0]  env_vol;

logic        next_msb;
logic        next_sync;
logic        this_msb;
logic        this_sync;

logic [15:0] sample_out;

// ---------------------------------------------------------------------------
// DUT instantiation
// ---------------------------------------------------------------------------
wavegen dut (
    .clk           (clk),
    .rst_n         (rst_n),
    .sample_strobe (sample_strobe),
    .freq          (freq),
    .pulse_width   (pulse_width),
    .wave_ctrl     (wave_ctrl),
    .env_vol       (env_vol),
    .next_msb      (next_msb),
    .next_sync     (next_sync),
    .this_msb      (this_msb),
    .this_sync     (this_sync),
    .sample_out    (sample_out)
);

// ---------------------------------------------------------------------------
// Clock generation
// ---------------------------------------------------------------------------
initial clk = 0;
always #(CLK_PERIOD/2) clk = ~clk;

// ---------------------------------------------------------------------------
// Sample strobe generation (every STROBE_PERIOD clocks)
// ---------------------------------------------------------------------------
integer strobe_counter;
initial strobe_counter = 0;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        strobe_counter <= 0;
        sample_strobe  <= 0;
    end else begin
        if (strobe_counter == STROBE_PERIOD - 1) begin
            strobe_counter <= 0;
            sample_strobe  <= 1;
        end else begin
            strobe_counter <= strobe_counter + 1;
            sample_strobe  <= 0;
        end
    end
end

// ---------------------------------------------------------------------------
// VCD dump
// ---------------------------------------------------------------------------
initial begin
    $dumpfile("wavegen_tb.vcd");
    $dumpvars(0, wavegen_tb);
end

// ---------------------------------------------------------------------------
// Helper task: run N samples and print output
// ---------------------------------------------------------------------------
task run_samples(input integer n);
    integer i;
    for (i = 0; i < n; i = i + 1) begin
        @(posedge clk);
        while (!sample_strobe) @(posedge clk);
        $display("t=%0t sample=%0d (0x%04X)", $time, $signed(sample_out), sample_out);
    end
endtask

// ---------------------------------------------------------------------------
// Test sequence
// freq = 0x0100_0000 => ~11.2Hz * (2^16/1) ... let's use something audible
// For ~440Hz: freq = round(440 * 2^32 / 48000) = 0x0253_3FFF
// We'll use 0x0200_0000 for easy math (~14.3Hz * something)
// Actually for TB we just want to see waveform shape, freq doesn't matter much
// Use 0x0800_0000 for a fast sweep through the waveform in few samples
// ---------------------------------------------------------------------------
initial begin
    // Initialise
    rst_n       = 0;
    freq        = 16'h0800;   // moderately fast for simulation
    pulse_width = 12'h800;    // 50% duty cycle
    wave_ctrl   = 8'h00;
    env_vol     = 8'hFF;
    next_msb    = 1'b0;
    next_sync   = 1'b0;

    repeat(4) @(posedge clk);
    rst_n = 1;
    repeat(4) @(posedge clk);

    // ------------------------------------------------------------------
    // Test 1: Sawtooth
    // ------------------------------------------------------------------
    $display("\n--- SAWTOOTH ---");
    wave_ctrl = 8'b0010_0000;  // SAW only
    run_samples(32);

    // ------------------------------------------------------------------
    // Test 2: Triangle
    // ------------------------------------------------------------------
    $display("\n--- TRIANGLE ---");
    wave_ctrl = 8'b0001_0000;  // TRI only
    run_samples(32);

    // ------------------------------------------------------------------
    // Test 3: Pulse 50%
    // ------------------------------------------------------------------
    $display("\n--- PULSE 50% ---");
    pulse_width = 12'h800;
    wave_ctrl   = 8'b0100_0000;  // PULSE only
    run_samples(32);

    // ------------------------------------------------------------------
    // Test 4: Pulse 25%
    // ------------------------------------------------------------------
    $display("\n--- PULSE 25% ---");
    pulse_width = 12'h400;
    wave_ctrl   = 8'b0100_0000;
    run_samples(32);

    // ------------------------------------------------------------------
    // Test 5: Noise
    // ------------------------------------------------------------------
    $display("\n--- NOISE ---");
    wave_ctrl = 8'b1000_0000;  // NOISE only
    run_samples(32);

    // ------------------------------------------------------------------
    // Test 6: Sine
    // ------------------------------------------------------------------
    $display("\n--- SINE ---");
    wave_ctrl = 8'b0000_1000;  // SINE only
    run_samples(32);

    // ------------------------------------------------------------------
    // Test 7: SAW + PULSE (multi-waveform AND)
    // ------------------------------------------------------------------
    $display("\n--- SAW + PULSE (AND) ---");
    pulse_width = 12'h800;
    wave_ctrl   = 8'b0110_0000;  // SAW | PULSE
    run_samples(32);

    // ------------------------------------------------------------------
    // Test 8: Triangle with ring mod (next_msb toggling)
    // ------------------------------------------------------------------
    $display("\n--- TRIANGLE + RING MOD ---");
    wave_ctrl = 8'b0001_0100;  // TRI | RING_MOD
    // Simulate a slow next_msb toggle to show ring mod effect
    fork
        begin
            repeat(16) begin
                next_msb = ~next_msb;
                repeat(STROBE_PERIOD * 2) @(posedge clk);
            end
        end
        run_samples(32);
    join

    // ------------------------------------------------------------------
    // Test 9: Hard sync
    // Pulse a next_sync signal partway through to reset accumulator
    // ------------------------------------------------------------------
    $display("\n--- HARD SYNC ---");
    next_msb  = 1'b0;
    wave_ctrl = 8'b0010_0010;  // SAW | SYNC
    fork
        begin
            repeat(STROBE_PERIOD * 10) @(posedge clk);
            // Fire sync pulse
            next_sync = 1'b1;
            @(posedge clk);
            next_sync = 1'b0;
            repeat(STROBE_PERIOD * 10) @(posedge clk);
            next_sync = 1'b1;
            @(posedge clk);
            next_sync = 1'b0;
        end
        run_samples(32);
    join

    $display("\n--- DONE ---");
    $finish;
end

endmodule