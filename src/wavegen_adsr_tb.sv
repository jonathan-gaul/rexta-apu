// =============================================================================
// wavegen_adsr_tb.sv
// Testbench for wavegen_adsr envelope generator
//
// Tests:
//   1. Full ADSR cycle — gate on, wait for sustain, gate off, wait for idle
//   2. Retrigger mid-release_rate — gate on again before envelope reaches zero
//   3. Fast settings — short attack/decay to verify rate table at low values
//   4. Zero sustain — verify envelope decays to zero and holds
// =============================================================================

`timescale 1ns/1ps

module wavegen_adsr_tb;

localparam CLK_PERIOD    = 20;      // 49.152MHz ~ 20ns
localparam STROBE_PERIOD = 1024;    // samples at 48kHz

logic        clk;
logic        rst_n;
logic        sample_strobe;
logic [3:0]  attack;
logic [3:0]  decay;
logic [3:0]  sustain;
logic [3:0]  release_rate;
logic        gate;
logic [7:0]  envelope_out;

// DUT
wavegen_adsr dut (
    .clk          (clk),
    .rst_n        (rst_n),
    .sample_strobe(sample_strobe),
    .attack       (attack),
    .decay        (decay),
    .sustain      (sustain),
    .release_rate      (release_rate),
    .gate         (gate),
    .envelope_out (envelope_out)
);

// Clock
initial clk = 0;
always #(CLK_PERIOD/2) clk = ~clk;

// Sample strobe
integer strobe_counter;
initial strobe_counter = 0;
always @(posedge clk) begin
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

// VCD
initial begin
    $dumpfile("wavegen_adsr_tb.vcd");
    $dumpvars(0, wavegen_adsr_tb);
end

// Helper: wait N sample strobes, printing envelope each time
task wait_samples(input integer n);
    integer i;
    for (i = 0; i < n; i = i + 1) begin
        @(posedge clk);
        while (!sample_strobe) @(posedge clk);
        $display("t=%0t gate=%0b env=%0d (0x%02X) state=%0d",
            $time, gate, envelope_out, envelope_out, dut.state);
    end
endtask

// Helper: set gate high, wait for sustain state
task wait_for_sustain;
    $display("  [waiting for sustain...]");
    @(posedge clk);
    while (!sample_strobe) @(posedge clk);
    while (dut.state !== 3'd3) begin   // SUSTAIN = 3
        @(posedge clk);
        while (!sample_strobe) @(posedge clk);
        $display("t=%0t gate=%0b env=%0d state=%0d",
            $time, gate, envelope_out, dut.state);
    end
    $display("  [reached sustain, env=%0d]", envelope_out);
endtask

initial begin
    // Initialise
    rst_n   = 0;
    gate    = 0;
    attack  = 4'd1;   // 8ms
    decay   = 4'd2;   // 48ms
    sustain = 4'd8;   // mid level (~136/255)
    release_rate = 4'd3;   // 72ms

    repeat(4) @(posedge clk);
    rst_n = 1;
    repeat(4) @(posedge clk);

    // ------------------------------------------------------------------
    // Test 1: Full ADSR cycle
    // ------------------------------------------------------------------
    $display("\n--- TEST 1: Full ADSR cycle ---");
    $display("A=%0d D=%0d S=%0d R=%0d", attack, decay, sustain, release_rate);

    gate = 1;
    wait_for_sustain;

    // Hold at sustain for 20 samples
    $display("  [holding sustain for 20 samples]");
    wait_samples(20);

    // Release
    $display("  [gate off -> release_rate]");
    gate = 0;

    // Wait until idle (envelope = 0)
    @(posedge clk);
    while (!sample_strobe) @(posedge clk);
    while (dut.state !== 3'd0) begin    // IDLE = 0
        @(posedge clk);
        while (!sample_strobe) @(posedge clk);
        $display("t=%0t gate=%0b env=%0d state=%0d",
            $time, gate, envelope_out, dut.state);
    end
    $display("  [reached idle, env=%0d]", envelope_out);

    // ------------------------------------------------------------------
    // Test 2: Retrigger mid-release_rate
    // ------------------------------------------------------------------
    $display("\n--- TEST 2: Retrigger mid-release_rate ---");
    gate = 1;
    wait_for_sustain;
    wait_samples(10);

    gate = 0;
    $display("  [gate off -> release_rate, waiting 30 samples]");
    wait_samples(30);
    $display("  [retriggering at env=%0d]", envelope_out);

    gate = 1;
    wait_for_sustain;
    $display("  [sustain reached after retrigger]");
    wait_samples(5);
    gate = 0;

    // Wait for idle
    while (dut.state !== 3'd0) begin
        @(posedge clk);
        while (!sample_strobe) @(posedge clk);
    end

    // ------------------------------------------------------------------
    // Test 3: Fast attack/decay (rate index 0)
    // ------------------------------------------------------------------
    $display("\n--- TEST 3: Fast settings (A=0 D=0 S=8 R=0) ---");
    attack  = 4'd0;
    decay   = 4'd0;
    sustain = 4'd8;
    release_rate = 4'd0;

    gate = 1;
    wait_for_sustain;
    wait_samples(5);
    gate = 0;
    while (dut.state !== 3'd0) begin
        @(posedge clk);
        while (!sample_strobe) @(posedge clk);
        $display("t=%0t env=%0d state=%0d", $time, envelope_out, dut.state);
    end
    $display("  [idle reached]");

    // ------------------------------------------------------------------
    // Test 4: Zero sustain
    // ------------------------------------------------------------------
    $display("\n--- TEST 4: Zero sustain (envelope decays to 0) ---");
    attack  = 4'd1;
    decay   = 4'd1;
    sustain = 4'd0;
    release_rate = 4'd1;

    gate = 1;
    wait_for_sustain;
    $display("  [sustain reached at env=%0d]", envelope_out);
    wait_samples(10);
    gate = 0;
    while (dut.state !== 3'd0) begin
        @(posedge clk);
        while (!sample_strobe) @(posedge clk);
    end
    $display("  [idle, env=%0d]", envelope_out);

    $display("\n--- DONE ---");
    $finish;
end

endmodule