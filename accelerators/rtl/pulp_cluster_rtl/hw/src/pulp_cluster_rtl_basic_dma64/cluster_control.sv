// cluster_control: bridges ESP's accelerator invocation model (conf_done/acc_done)
// to the PULP cluster's boot protocol.
//
// Reworked port of the reference implementation
// (esp_first_pulp_integration/accelerators/rtl/pulp_rtl/rtl/cluster_control.sv) with
// the four fixes from the integration plan Step 4 (report §4):
//   1. fully parameterized (core count, cluster address map, L2 window base) —
//      no hard-coded 0x50200040 / +0x8080 magic inside the module;
//   2. every AXI master output is driven (the reference left the whole AR/R
//      channel and aw_id/aw_user/w_user floating -> X propagation into the CDC);
//   3. the per-core boot-address writes are confirmed on the B channel before
//      the next write is issued (the reference fired-and-forgot on w_ready);
//   4. boot address = L2_BASE_ADDR + boot_offset_i, where boot_offset_i comes
//      from the ESP user register `boot_offset` (default 0x8080 = pulp-runtime
//      `_start`: vector table at L2+0x8000, entry at +0x80). The reference used
//      `reg1 + 0x8080` with reg1 = the host's physical buffer pointer, which only
//      landed inside the cluster's L2 window by allocator coincidence.
//
// Boot flow (target registers read from the actual cluster_control_unit RTL,
// vendor/cluster_peripherals/cluster_control_unit/cluster_control_unit.sv:44-60):
//   conf_done -> write (L2_BASE_ADDR + boot_offset_i) to the per-core boot-address
//   registers at CLUSTER_BASE + PERIPH_OFFS + 0x40 + 4*i -> assert en_sa_boot ->
//   assert fetch_en -> wait eoc -> pulse acc_done.

module cluster_control #(
    parameter int unsigned NUM_CORES         = 8,
    parameter logic [31:0] CLUSTER_BASE_ADDR = 32'h5000_0000,
    parameter logic [31:0] CLUSTER_PERIPH_OFFS = 32'h0020_0000,
    parameter logic [31:0] BOOT_REG_OFFS     = 32'h0000_0040,
    parameter logic [31:0] L2_BASE_ADDR      = 32'hA010_3680
) (
    input  logic        clk,
    input  logic        rst_ni,

    // ESP socket side
    input  logic        conf_done,
    input  logic [31:0] boot_offset_i,   // ESP user register: entry offset in the buffer
    output logic        acc_done,

    // Cluster side
    output logic        fetch_enable,
    output logic        boot_enable,
    input  logic        eoc,
    AXI_BUS.Master      axi_m
);

  localparam logic [31:0] BootRegBase =
      CLUSTER_BASE_ADDR + CLUSTER_PERIPH_OFFS + BOOT_REG_OFFS;

  logic [31:0] boot_addr;
  assign boot_addr = L2_BASE_ADDR + boot_offset_i;

  typedef enum logic [2:0] {
    IDLE, WRITE_ADDR, WRITE_DATA, WRITE_RESP, BOOT_ENABLE, FETCH_ENABLE, WAIT_COMPUTE, DONE
  } state_t;

  state_t state_q, state_d;
  logic [$clog2(NUM_CORES)-1:0] core_q, core_d;

  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= IDLE;
      core_q  <= '0;
    end else begin
      state_q <= state_d;
      core_q  <= core_d;
    end
  end

  always_comb begin
    state_d = state_q;
    core_d  = core_q;

    // AW defaults
    axi_m.aw_valid  = 1'b0;
    axi_m.aw_addr   = '0;
    axi_m.aw_id     = '0;
    axi_m.aw_len    = 8'd0;          // single beat
    axi_m.aw_size   = 3'b010;        // 4-byte register write
    axi_m.aw_burst  = 2'b01;         // INCR
    axi_m.aw_lock   = 1'b0;
    axi_m.aw_cache  = 4'b0;
    axi_m.aw_prot   = 3'b0;
    axi_m.aw_qos    = 4'b0;
    axi_m.aw_region = 4'b0;
    axi_m.aw_atop   = 6'b0;
    axi_m.aw_user   = '0;
    // W defaults: 32-bit value replicated on both 32-bit lanes so the addressed
    // lane always carries boot_addr, with strobes selecting the lane (fix 2 of
    // the reference's all-ones-strobe + low-lane-only data scheme).
    axi_m.w_valid = 1'b0;
    axi_m.w_data  = {2{boot_addr}};
    axi_m.w_strb  = '0;
    axi_m.w_last  = 1'b1;
    axi_m.w_user  = '0;
    // B/AR/R defaults (reference left AR/R undriven entirely)
    axi_m.b_ready  = 1'b1;
    axi_m.ar_valid = 1'b0;
    axi_m.ar_addr  = '0;
    axi_m.ar_id    = '0;
    axi_m.ar_len   = 8'd0;
    axi_m.ar_size  = 3'b010;
    axi_m.ar_burst = 2'b01;
    axi_m.ar_lock  = 1'b0;
    axi_m.ar_cache = 4'b0;
    axi_m.ar_prot  = 3'b0;
    axi_m.ar_qos   = 4'b0;
    axi_m.ar_region= 4'b0;
    axi_m.ar_user  = '0;
    axi_m.r_ready  = 1'b1;

    boot_enable  = 1'b0;
    fetch_enable = 1'b0;
    acc_done     = 1'b0;

    unique case (state_q)

      IDLE: begin
        core_d = '0;
        if (conf_done) state_d = WRITE_ADDR;
      end

      WRITE_ADDR: begin
        axi_m.aw_valid = 1'b1;
        axi_m.aw_addr  = BootRegBase + 32'(core_q) * 4;
        if (axi_m.aw_ready) state_d = WRITE_DATA;
      end

      WRITE_DATA: begin
        axi_m.w_valid = 1'b1;
        // strobe the addressed 4-byte lane of the 64-bit bus
        axi_m.w_strb  = core_q[0] ? 8'hF0 : 8'h0F;
        if (axi_m.w_ready) state_d = WRITE_RESP;
      end

      WRITE_RESP: begin
        if (axi_m.b_valid) begin   // b_ready is constant 1
          if (core_q == NUM_CORES - 1) begin
            core_d  = '0;
            state_d = BOOT_ENABLE;
          end else begin
            core_d  = core_q + 1;
            state_d = WRITE_ADDR;
          end
        end
      end

      BOOT_ENABLE: begin
        boot_enable = 1'b1;
        state_d     = FETCH_ENABLE;
      end

      FETCH_ENABLE: begin
        boot_enable  = 1'b1;
        fetch_enable = 1'b1;
        state_d      = WAIT_COMPUTE;
      end

      WAIT_COMPUTE: begin
        boot_enable  = 1'b1;
        fetch_enable = 1'b1;
        if (eoc) state_d = DONE;
      end

      DONE: begin
        acc_done = 1'b1;
        state_d  = IDLE;
      end

      default: state_d = IDLE;
    endcase
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (rst_ni && axi_m.b_valid && axi_m.b_ready && state_q == WRITE_RESP) begin
      assert (axi_m.b_resp == 2'b00)
        else $error("cluster_control: boot-address write %0d returned b_resp=%0b",
                    core_q, axi_m.b_resp);
    end
  end
`endif

endmodule
