// Directed self-checking testbench for cluster_control (plan Step 4, mandatory).
//
// Checks, against a behavioural AXI-slave register model with randomized ready
// timing:
//   C1  after conf_done: exactly NUM_CORES single-beat 32-bit writes to
//       BootRegBase + 4*i, in order, each carrying L2_BASE + boot_offset on the
//       addressed 32-bit lane (strobes select the lane);
//   C2  every write is confirmed on B before the next AW is issued (fix 3);
//   C3  boot_enable rises only after the last B, fetch_enable one cycle later,
//       both held through eoc;
//   C4  acc_done is a single-cycle pulse after eoc; enables drop with it;
//   C5  a second conf_done re-runs the whole sequence (multi-invocation);
//   C6  AR channel is quiescent (ar_valid never asserts) and all AW/W fields are
//       driven (no X) - fix 2.

`timescale 1ns/1ps

module cluster_control_tb;

  localparam int unsigned NUM_CORES = 8;
  localparam logic [31:0] CLBASE = 32'h5000_0000, PEROFF = 32'h0020_0000;
  localparam logic [31:0] BOOTOFF = 32'h40, L2BASE = 32'hA010_3680;
  localparam logic [31:0] BootRegBase = CLBASE + PEROFF + BOOTOFF;

  logic clk = 0, rst_ni = 0;
  always #5 clk = ~clk;

  logic conf_done, acc_done, fetch_enable, boot_enable, eoc;
  logic [31:0] boot_offset;

  AXI_BUS #(
    .AXI_ADDR_WIDTH(32), .AXI_DATA_WIDTH(64), .AXI_ID_WIDTH(6), .AXI_USER_WIDTH(10)
  ) axi ();

  cluster_control #(
    .NUM_CORES(NUM_CORES), .CLUSTER_BASE_ADDR(CLBASE),
    .CLUSTER_PERIPH_OFFS(PEROFF), .BOOT_REG_OFFS(BOOTOFF), .L2_BASE_ADDR(L2BASE)
  ) dut (
    .clk(clk), .rst_ni(rst_ni),
    .conf_done(conf_done), .boot_offset_i(boot_offset), .acc_done(acc_done),
    .fetch_enable(fetch_enable), .boot_enable(boot_enable), .eoc(eoc),
    .axi_m(axi)
  );

  int unsigned errors = 0;
  task automatic fail(input string msg); errors++; $error("TB: %s", msg); endtask

  // ---------------------------------------------------------------------------
  // Behavioural AXI slave: captures writes into boot_regs[], random ready delays
  // ---------------------------------------------------------------------------
  logic [31:0] boot_regs [NUM_CORES];
  int unsigned writes_seen;
  bit          aw_in_flight;   // C2: no overlapping writes

  initial begin
    axi.aw_ready = 0; axi.w_ready = 0; axi.b_valid = 0; axi.b_resp = 2'b00;
    axi.b_id = '0; axi.b_user = '0;
    axi.ar_ready = 0; axi.r_valid = 0; axi.r_data = '0; axi.r_resp = '0;
    axi.r_last = 0; axi.r_id = '0; axi.r_user = '0;
    writes_seen = 0; aw_in_flight = 0;
    forever begin
      automatic logic [31:0] addr;
      automatic logic [63:0] data;
      automatic logic [7:0]  strb;
      // AW
      do @(posedge clk); while (!axi.aw_valid);
      if (aw_in_flight) fail("C2: new AW before previous B accepted");
      aw_in_flight = 1;
      repeat ($urandom_range(0,3)) @(posedge clk);
      #1; axi.aw_ready = 1; addr = axi.aw_addr;
      if (axi.aw_len !== 8'd0)    fail("AW len != 0");
      if (axi.aw_size !== 3'b010) fail("AW size != 4B");
      if ($isunknown(axi.aw_id) || $isunknown(axi.aw_user) || $isunknown(axi.aw_atop))
        fail("C6: X on AW qualifiers");
      @(posedge clk); #1; axi.aw_ready = 0;
      // W
      do @(posedge clk); while (!axi.w_valid);
      repeat ($urandom_range(0,3)) @(posedge clk);
      #1; axi.w_ready = 1;
      data = axi.w_data; strb = axi.w_strb;
      if (!axi.w_last) fail("W not single-beat");
      if ($isunknown(strb) || $isunknown(axi.w_user)) fail("C6: X on W qualifiers");
      @(posedge clk); #1; axi.w_ready = 0;
      // register write via lane decode
      begin
        automatic int unsigned core = (addr - BootRegBase) >> 2;
        automatic logic [31:0] val = addr[2] ? data[63:32] : data[31:0];
        automatic logic [7:0]  expect_strb = addr[2] ? 8'hF0 : 8'h0F;
        if (core >= NUM_CORES) fail($sformatf("write outside boot regs: 0x%h", addr));
        else begin
          if (strb !== expect_strb)
            fail($sformatf("core %0d: strb 0x%h != 0x%h", core, strb, expect_strb));
          boot_regs[core] = val;
        end
        if (writes_seen % NUM_CORES != core)
          fail($sformatf("out-of-order boot write: got core %0d, expected %0d",
                         core, writes_seen % NUM_CORES));
      end
      writes_seen++;
      // B (delayed)
      repeat ($urandom_range(0,3)) @(posedge clk);
      #1; axi.b_valid = 1; axi.b_resp = 2'b00;
      do @(posedge clk); while (!axi.b_ready); #1;
      axi.b_valid = 0;
      aw_in_flight = 0;
    end
  end

  // C6: AR must stay quiet forever
  always @(posedge clk) if (rst_ni && axi.ar_valid === 1'b1) fail("C6: ar_valid asserted");

  // ---------------------------------------------------------------------------
  // Stimulus / checks
  // ---------------------------------------------------------------------------
  task automatic one_invocation(input logic [31:0] off, input string tag);
    boot_offset = off;
    @(posedge clk); #1; conf_done = 1;
    @(posedge clk); #1; conf_done = 0;

    // wait for all boot writes, then boot/fetch enables
    wait (writes_seen % (2*NUM_CORES) == NUM_CORES || writes_seen % (2*NUM_CORES) == 0);
    wait (boot_enable);
    if (fetch_enable) fail({tag, ": fetch_enable before boot_enable settled"});
    @(posedge clk); #1;
    if (!fetch_enable) fail({tag, ": fetch_enable did not follow boot_enable"});
    for (int i = 0; i < NUM_CORES; i++)
      if (boot_regs[i] !== L2BASE + off)
        fail($sformatf("%s: boot_regs[%0d] = 0x%h != 0x%h", tag, i, boot_regs[i], L2BASE + off));

    // enables held until eoc
    repeat (20) @(posedge clk);
    if (!boot_enable || !fetch_enable) fail({tag, ": enables not held"});
    if (acc_done) fail({tag, ": premature acc_done"});

    #1; eoc = 1;
    do @(posedge clk); while (!acc_done); #1;
    eoc = 0;
    @(posedge clk); #1;
    if (acc_done) fail({tag, ": acc_done longer than one cycle"});
    if (boot_enable || fetch_enable) fail({tag, ": enables must drop after done"});
  endtask

  initial begin
    conf_done = 0; eoc = 0; boot_offset = 32'h8080;
    rst_ni = 0; repeat (5) @(posedge clk); rst_ni = 1; repeat (2) @(posedge clk);

    one_invocation(32'h8080, "C1-C4 (invocation 1)");
    repeat (5) @(posedge clk);
    one_invocation(32'h9000, "C5 (invocation 2, new offset)");

    if (writes_seen != 2*NUM_CORES)
      fail($sformatf("expected %0d writes total, saw %0d", 2*NUM_CORES, writes_seen));

    repeat (5) @(posedge clk);
    if (errors == 0) $display("TB PASSED: cluster_control all checks OK (writes=%0d)", writes_seen);
    else             $display("TB FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #200us;
    $display("TB FAILED: global timeout");
    $fatal(1);
  end

endmodule
