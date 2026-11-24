// Copyright (c) 2011-2026 Columbia University, System Level Design Group
// SPDX-License-Identifier: Apache-2.0
//
// Self-checking testbench for noc2aximst, the memory-tile proxy between the
// NoC planes and the AXI port toward the DDR controller.
//
// What it models
//   - The two request queues (coherence plane, DMA plane) and the two response
//     queues, with random gaps and random back-pressure.
//   - An AXI memory that behaves like the worst legal DDR controller for this
//     proxy: bursts are served strictly in the order their ARs were accepted,
//     a read returns the data that was committed when its AR was accepted, and
//     a write is committed only when its B response is taken. It stores every
//     write strobe in the byte lane it arrives on and returns whole bus words,
//     as the Xilinx upsizer inside the DDR4 MIG does.
//
// What it checks
//   - Every response flit against a reference memory that is updated from the
//     NoC-level requests alone, in 64-bit words. The reference does not depend
//     on the AXI data width, so the same stimulus must give the same answers
//     at MEM_AXIDW = 64 and 128.
//   - AXI rules the proxy must respect: stable address channels, W beat count
//     and WLAST, narrow-transfer strobes inside the 64-bit lane the beat
//     address selects, and for full-width (16-byte) beats no burst crossing a
//     4 KB boundary.
//   - At the end, the AXI memory holds exactly the reference contents.
//   - With +define+WITH_REF, a second proxy (module noc2aximst_ref, normally
//     the version before a change) gets the same inputs and every output is
//     compared on every cycle.
//
// Stimulus runs in epochs. In each epoch the CPU plane and the DMA plane work
// on different memory regions, because the proxy defines no order between
// requests that arrive on different planes; the regions are swapped between
// epochs after everything has drained, so each plane reads back what the other
// one wrote.

`timescale 1ns / 1ps

import esp_global_sv::*;
import noc2aximst_pkg::*;

module noc2aximst_tb;

    parameter int NUM_EPOCHS    = 12;
    parameter int OPS_PER_EPOCH = 60;
    parameter int MULTI_OT      = 1;   // dma_multi_ot generic of the proxy
    parameter int ETH           = 0;   // 1: debug-link / Ethernet instance (eth_dma = 1)
    parameter int STALLS        = 1;   // 0: no back-pressure anywhere (throughput run)
    parameter int MAX_DMA_WORDS = 2600; // longest DMA request, in 64-bit words
    // The proxy holds a DMA read behind earlier writes, but not a DMA write
    // behind earlier reads that are still in flight (a limitation stated in
    // its source). A memory that executes commands in arrival order, like the
    // MIG, can then apply a younger write before an older read has finished.
    // The built-in AXI memory hides this by sampling read data when the AR is
    // accepted. With WAR_SAFE = 1 the stimulus itself keeps a DMA write from
    // following a DMA read that has not completed; -1 picks 1 when the MIG
    // front end is the memory and 0 otherwise.
    parameter int WAR_SAFE      = -1;

    localparam int COH_FLIT = 2 + ARCH_BITS;
    localparam int DMA_FLIT = DMA_NOC_FLIT_SIZE;
    localparam int LANES    = MEM_AXIDW / ARCH_BITS;   // 64-bit lanes per bus word
    localparam int BB       = MEM_AXIDW / 8;           // bytes per bus word
    localparam int LOG_BB   = $clog2(BB);
    localparam int WPF      = DMA_NOC_WIDTH / ARCH_BITS; // 64-bit words per DMA flit
    localparam int YX       = GLOB_YX_WIDTH;

    localparam logic [YX-1:0] MEM_Y = 0, MEM_X = 0, SRC_Y = 1, SRC_X = 2;

    // The multi-outstanding path holds a DMA read until earlier writes have
    // their B response, so there the memory may delay a write's effect until
    // B. The classic path and the Ethernet instance give no such guarantee
    // (a read can overtake a posted write below the port); for them the
    // memory applies a write when its data beat is accepted.
    localparam bit LAZY_COMMIT = (MULTI_OT != 0) && (ETH == 0);
`ifdef WITH_MIG_AXI
    localparam bit war_safe = (WAR_SAFE != 0);
`else
    localparam bit war_safe = (WAR_SAFE > 0);
`endif

    typedef logic [MEM_AXIDW-1:0] busword_t;
    typedef logic [DMA_FLIT-1:0]  dflit_t;
    typedef logic [COH_FLIT-1:0]  cflit_t;

    // ------------------------------------------------------------------
    // Clock, reset, bookkeeping
    // ------------------------------------------------------------------
    logic clk = 1'b0;
    logic rstn = 1'b0;
    always #5 clk = ~clk;

    int unsigned cycle = 0;
    always @(posedge clk) cycle <= cycle + 1;

    int errors = 0;
    task automatic fail(input string msg);
        errors++;
        $display("TB_ERROR @%0t (cycle %0d): %s", $time, cycle, msg);
        if (errors > 20) begin
            $display("NOC2AXIMST_TB_FAIL: too many errors");
            $finish;
        end
    endtask

    function automatic int unsigned rnd(input int unsigned lo, input int unsigned hi);
        return $urandom_range(hi, lo);
    endfunction
    function automatic bit chance(input int pct);
        return ($urandom_range(99, 0) < pct);
    endfunction

    // ------------------------------------------------------------------
    // DUT ports
    // ------------------------------------------------------------------
    logic [1:0]                     AR_ID, R_ID, AW_ID, B_ID;
    logic [GLOB_PHYS_ADDR_BITS-1:0] AR_ADDR, AW_ADDR;
    logic [7:0]                     AR_LEN, AW_LEN;
    logic [2:0]                     AR_SIZE, AW_SIZE, AR_PROT, AW_PROT;
    logic [1:0]                     AR_BURST, AW_BURST, R_RESP, B_RESP;
    logic                           AR_LOCK, AW_LOCK;
    logic                           AR_VALID, AR_READY, R_VALID, R_READY, R_LAST;
    logic                           AW_VALID, AW_READY, W_VALID, W_READY, W_LAST;
    logic                           B_VALID, B_READY;
    logic [MEM_AXIDW-1:0]           R_DATA, W_DATA;
    logic [MEM_AXIDW/8-1:0]         W_STRB;

    logic                coh_rdreq, coh_empty, coh_wrreq, coh_full;
    cflit_t              coh_dout, coh_din;
    logic                dma_rdreq, dma_empty, dma_wrreq, dma_full;
    dflit_t              dma_dout, dma_din;

    assign R_RESP = 2'b00;
    assign B_RESP = 2'b00;

    noc2aximst #(
        .tech              (0),
        .mst_index         (ETH),
        .axitran           (ETH ? 0 : 1),
        .little_end        (ETH ? 0 : 1),
        .eth_dma           (ETH),
        .narrow_noc        (0),
        .cacheline         (ETH ? 1 : 2),
        .this_coh_flit_size(COH_FLIT),
        .dma_multi_ot      (MULTI_OT)
    ) dut (
        .ARESETn(rstn), .ACLK(clk), .local_y(MEM_Y), .local_x(MEM_X),
        .AR_ID, .AR_ADDR, .AR_LEN, .AR_SIZE, .AR_BURST, .AR_LOCK, .AR_PROT, .AR_VALID, .AR_READY,
        .R_ID, .R_DATA, .R_RESP, .R_LAST, .R_VALID, .R_READY,
        .AW_ID, .AW_ADDR, .AW_LEN, .AW_SIZE, .AW_BURST, .AW_LOCK, .AW_PROT, .AW_VALID, .AW_READY,
        .W_DATA, .W_STRB, .W_LAST, .W_VALID, .W_READY,
        .B_ID, .B_RESP, .B_VALID, .B_READY,
        .coherence_req_rdreq(coh_rdreq), .coherence_req_data_out(coh_dout), .coherence_req_empty(coh_empty),
        .coherence_rsp_snd_wrreq(coh_wrreq), .coherence_rsp_snd_data_in(coh_din), .coherence_rsp_snd_full(coh_full),
        .dma_rcv_rdreq(dma_rdreq), .dma_rcv_data_out(dma_dout), .dma_rcv_empty(dma_empty),
        .dma_snd_wrreq(dma_wrreq), .dma_snd_data_in(dma_din), .dma_snd_full(dma_full)
    );

`ifdef WITH_REF
    // Same inputs into the reference proxy; every output compared every cycle.
    logic [1:0]                     rAR_ID, rAW_ID;
    logic [GLOB_PHYS_ADDR_BITS-1:0] rAR_ADDR, rAW_ADDR;
    logic [7:0]                     rAR_LEN, rAW_LEN;
    logic [2:0]                     rAR_SIZE, rAW_SIZE, rAR_PROT, rAW_PROT;
    logic [1:0]                     rAR_BURST, rAW_BURST;
    logic                           rAR_LOCK, rAW_LOCK, rAR_VALID, rR_READY, rAW_VALID, rW_VALID, rW_LAST, rB_READY;
    logic [MEM_AXIDW-1:0]           rW_DATA;
    logic [MEM_AXIDW/8-1:0]         rW_STRB;
    logic                           rcoh_rdreq, rcoh_wrreq, rdma_rdreq, rdma_wrreq;
    cflit_t                         rcoh_din;
    dflit_t                         rdma_din;

    noc2aximst_ref #(
        .tech(0), .mst_index(ETH), .axitran(ETH ? 0 : 1), .little_end(ETH ? 0 : 1), .eth_dma(ETH),
        .narrow_noc(0), .cacheline(ETH ? 1 : 2), .this_coh_flit_size(COH_FLIT), .dma_multi_ot(MULTI_OT)
    ) ref_dut (
        .ARESETn(rstn), .ACLK(clk), .local_y(MEM_Y), .local_x(MEM_X),
        .AR_ID(rAR_ID), .AR_ADDR(rAR_ADDR), .AR_LEN(rAR_LEN), .AR_SIZE(rAR_SIZE), .AR_BURST(rAR_BURST),
        .AR_LOCK(rAR_LOCK), .AR_PROT(rAR_PROT), .AR_VALID(rAR_VALID), .AR_READY,
        .R_ID, .R_DATA, .R_RESP, .R_LAST, .R_VALID, .R_READY(rR_READY),
        .AW_ID(rAW_ID), .AW_ADDR(rAW_ADDR), .AW_LEN(rAW_LEN), .AW_SIZE(rAW_SIZE), .AW_BURST(rAW_BURST),
        .AW_LOCK(rAW_LOCK), .AW_PROT(rAW_PROT), .AW_VALID(rAW_VALID), .AW_READY,
        .W_DATA(rW_DATA), .W_STRB(rW_STRB), .W_LAST(rW_LAST), .W_VALID(rW_VALID), .W_READY,
        .B_ID, .B_RESP, .B_VALID, .B_READY(rB_READY),
        .coherence_req_rdreq(rcoh_rdreq), .coherence_req_data_out(coh_dout), .coherence_req_empty(coh_empty),
        .coherence_rsp_snd_wrreq(rcoh_wrreq), .coherence_rsp_snd_data_in(rcoh_din), .coherence_rsp_snd_full(coh_full),
        .dma_rcv_rdreq(rdma_rdreq), .dma_rcv_data_out(dma_dout), .dma_rcv_empty(dma_empty),
        .dma_snd_wrreq(rdma_wrreq), .dma_snd_data_in(rdma_din), .dma_snd_full(dma_full)
    );

    always @(negedge clk) if (rstn) begin
        if ({AR_VALID, R_READY, AW_VALID, W_VALID, B_READY, coh_rdreq, coh_wrreq, dma_rdreq, dma_wrreq} !==
            {rAR_VALID, rR_READY, rAW_VALID, rW_VALID, rB_READY, rcoh_rdreq, rcoh_wrreq, rdma_rdreq, rdma_wrreq})
            fail("REF: handshake outputs differ");
        if (AR_VALID && {AR_ID, AR_ADDR, AR_LEN, AR_SIZE, AR_BURST, AR_LOCK, AR_PROT} !==
                        {rAR_ID, rAR_ADDR, rAR_LEN, rAR_SIZE, rAR_BURST, rAR_LOCK, rAR_PROT})
            fail("REF: AR channel differs");
        if (AW_VALID && {AW_ID, AW_ADDR, AW_LEN, AW_SIZE, AW_BURST, AW_LOCK, AW_PROT} !==
                        {rAW_ID, rAW_ADDR, rAW_LEN, rAW_SIZE, rAW_BURST, rAW_LOCK, rAW_PROT})
            fail("REF: AW channel differs");
        if (W_VALID && {W_DATA, W_STRB, W_LAST} !== {rW_DATA, rW_STRB, rW_LAST})
            fail("REF: W channel differs");
        if (coh_wrreq && coh_din !== rcoh_din) fail("REF: coherence response flit differs");
        if (dma_wrreq && dma_din !== rdma_din) fail("REF: DMA response flit differs");
    end
`endif

    // ------------------------------------------------------------------
    // Memory contents
    // ------------------------------------------------------------------
    // Unwritten memory reads as a fixed function of its address, so reads of
    // untouched locations are checkable too.
    function automatic logic [63:0] init_dword(input longint unsigned dw);
        logic [63:0] x;
        x = dw * 64'h9E3779B97F4A7C15 + 64'hD1B54A32D192ED03;
        x ^= x >> 29;
        x *= 64'hBF58476D1CE4E5B9;
        x ^= x >> 32;
        return x;
    endfunction

    // AXI-side memory: bus words, committed writes only. The 64-bit word at
    // 8-byte address index dw lives in bus word dw / LANES, lane dw % LANES.
    busword_t axi_mem[longint unsigned];
    function automatic busword_t axi_mem_read(input longint unsigned bw);
        busword_t r;
        if (axi_mem.exists(bw)) return axi_mem[bw];
        for (int l = 0; l < LANES; l++) r[64*l+:64] = init_dword(bw * LANES + l);
        return r;
    endfunction

    // Reference memory: 64-bit words as they sit on the bus, updated from the
    // NoC-level requests only.
    logic [63:0] ref_mem[longint unsigned];
    function automatic logic [63:0] ref_read(input longint unsigned dw);
        if (ref_mem.exists(dw)) return ref_mem[dw];
        return init_dword(dw);
    endfunction

    function automatic logic [63:0] bswap(input logic [63:0] d);
        logic [63:0] r;
        for (int i = 0; i < 8; i++) r[8*i+:8] = d[63-8*i-:8];
        return r;
    endfunction
    // Data as the proxy puts it on the bus / takes it from the bus.
    function automatic logic [63:0] to_bus(input logic [63:0] d);
        return ETH ? d : bswap(d);
    endfunction

    // ------------------------------------------------------------------
    // AXI memory model
    // ------------------------------------------------------------------
    typedef struct {
        logic [1:0] id;
        int         len;
        int         ready_cycle;
        busword_t   data[$];
    } rburst_t;
    rburst_t rq[$];
    int      r_idx = 0;

    typedef struct {
        longint unsigned addr;
        int              len;
        int              size;
    } awreq_t;
    awreq_t awq[$];
    int     w_idx = 0;

    typedef struct {
        longint unsigned bw;
        busword_t        data;
        logic [MEM_AXIDW/8-1:0] strb;
    } wbeat_t;
    typedef struct {
        int     ready_cycle;
        wbeat_t beats[$];
    } bresp_t;
    bresp_t bq[$];
    wbeat_t cur_beats[$];

    // statistics
    int n_ar_full = 0, n_ar_narrow = 0, n_aw_full = 0, n_aw_narrow = 0;
    int n_narrow_4k_cross = 0, n_r_beats = 0, n_w_beats = 0;
    int max_rd_outstanding = 0;

    function automatic longint unsigned beat_addr(input longint unsigned a0, input int size, input int n);
        longint unsigned al;
        if (n == 0) return a0;
        al = (a0 >> size) << size;
        return al + (longint'(n) << size);
    endfunction

    // previous-cycle copies for the stability checks
    logic                           p_arv = 0, p_arr = 0, p_awv = 0, p_awr = 0, p_wv = 0, p_wr = 0;
    logic [GLOB_PHYS_ADDR_BITS+14:0] p_ar, p_aw;
    logic [1:0]                      p_arid;
    int                              n_arid_changed = 0;
    logic [MEM_AXIDW+MEM_AXIDW/8:0] p_w;

`ifndef WITH_MIG_AXI
    always @(posedge clk) begin
        if (!rstn) begin
            AR_READY <= 1'b0; R_VALID <= 1'b0; R_LAST <= 1'b0; R_ID <= '0; R_DATA <= '0;
            AW_READY <= 1'b0; W_READY <= 1'b0; B_VALID <= 1'b0; B_ID <= '0;
        end else begin
            // ---------------- stability of the address and data channels
            if (p_arv && !p_arr && (!AR_VALID || p_ar !== {AR_ADDR, AR_LEN, AR_SIZE, AR_PROT[1:0]}))
                fail("AXI: AR changed or dropped before AR_READY");
            // Known behaviour of the multi-outstanding path, not checked as an
            // error: the id of a waiting first AR is the lowest free context,
            // and it can change if another context frees meanwhile.
            if (p_arv && !p_arr && AR_VALID && p_arid !== AR_ID) n_arid_changed++;
            if (p_awv && !p_awr && (!AW_VALID || p_aw !== {AW_ADDR, AW_LEN, AW_SIZE, AW_ID, AW_PROT[1:0]}))
                fail("AXI: AW changed or dropped before AW_READY");
            if (p_wv && !p_wr && (!W_VALID || p_w !== {W_DATA, W_STRB, W_LAST}))
                fail("AXI: W changed or dropped before W_READY");
            p_arv <= AR_VALID; p_arr <= AR_READY; p_ar <= {AR_ADDR, AR_LEN, AR_SIZE, AR_PROT[1:0]}; p_arid <= AR_ID;
            p_awv <= AW_VALID; p_awr <= AW_READY; p_aw <= {AW_ADDR, AW_LEN, AW_SIZE, AW_ID, AW_PROT[1:0]};
            p_wv  <= W_VALID;  p_wr  <= W_READY;  p_w  <= {W_DATA, W_STRB, W_LAST};

            // ---------------- AR: accept, check, snapshot the data
            if (AR_VALID && AR_READY) begin
                rburst_t b;
                check_ax("AR", AR_ADDR, AR_LEN, AR_SIZE, AR_BURST);
                if (AR_SIZE == LOG_BB) n_ar_full++; else n_ar_narrow++;
                b.data.delete();  // b is static storage: start from an empty burst
                b.id = AR_ID;
                b.len = AR_LEN;
                b.ready_cycle = cycle + (STALLS ? rnd(1, 8) : 1);
                for (int n = 0; n <= AR_LEN; n++)
                    b.data.push_back(axi_mem_read(beat_addr(AR_ADDR, AR_SIZE, n) >> LOG_BB));
                rq.push_back(b);
                if (rq.size() > max_rd_outstanding) max_rd_outstanding = rq.size();
            end
            AR_READY <= (rq.size() < 12) && (!STALLS || chance(70));

            // ---------------- R: strictly in AR order
            if (R_VALID && R_READY) begin
                n_r_beats++;
                if (r_idx == rq[0].len) begin
                    void'(rq.pop_front());
                    r_idx = 0;
                end else r_idx++;
            end
            if (R_VALID && !R_READY) begin
                // hold
            end else if (rq.size() > 0 && cycle >= rq[0].ready_cycle && (!STALLS || chance(75))) begin
                R_VALID <= 1'b1;
                R_DATA  <= rq[0].data[r_idx];
                R_LAST  <= (r_idx == rq[0].len);
                R_ID    <= rq[0].id;
            end else begin
                R_VALID <= 1'b0;
                R_LAST  <= 1'b0;
            end

            // ---------------- AW
            if (AW_VALID && AW_READY) begin
                awreq_t a;
                check_ax("AW", AW_ADDR, AW_LEN, AW_SIZE, AW_BURST);
                if (AW_SIZE == LOG_BB) n_aw_full++; else n_aw_narrow++;
                a.addr = AW_ADDR; a.len = AW_LEN; a.size = AW_SIZE;
                awq.push_back(a);
            end
            AW_READY <= (awq.size() < 4) && (!STALLS || chance(70));

            // ---------------- W: beats of the oldest accepted AW
            if (W_VALID && W_READY) begin
                wbeat_t          wb;
                longint unsigned a;
                n_w_beats++;
                if (awq.size() == 0) fail("AXI: W beat with no accepted AW");
                else begin
                    a = beat_addr(awq[0].addr, awq[0].size, w_idx);
                    wb.bw = a >> LOG_BB; wb.data = W_DATA; wb.strb = W_STRB;
                    check_wstrb(a, awq[0].size, W_STRB);
                    if (LAZY_COMMIT) cur_beats.push_back(wb);
                    else commit_beat(wb);
                    if (W_LAST !== (w_idx == awq[0].len))
                        fail($sformatf("AXI: W_LAST=%0b at beat %0d of a %0d-beat burst", W_LAST, w_idx, awq[0].len + 1));
                    if (w_idx == awq[0].len) begin
                        bresp_t br;
                        br.ready_cycle = cycle + (STALLS ? rnd(1, 24) : 1);
                        br.beats = cur_beats;
                        bq.push_back(br);
                        cur_beats.delete();
                        void'(awq.pop_front());
                        w_idx = 0;
                    end else w_idx++;
                end
            end
            W_READY <= (awq.size() > 0) && (!STALLS || chance(75));

            // ---------------- B: the write becomes visible when B is taken
            if (B_VALID && B_READY) begin
                foreach (bq[0].beats[i]) commit_beat(bq[0].beats[i]);
                void'(bq.pop_front());
            end
            if (B_VALID && !B_READY) begin
                // hold
            end else if (bq.size() > 0 && cycle >= bq[0].ready_cycle) begin
                B_VALID <= 1'b1;
                B_ID    <= '0;
            end else B_VALID <= 1'b0;
        end
    end

`else
    // ------------------------------------------------------------------
    // Alternative memory (+define+WITH_MIG_AXI): the AXI front end of the
    // Xilinx DDR4 MIG (ddr4_v2_2 "axi" shim: register slices, upsizer to the
    // 512-bit native word, command translation, read/write arbitration) in
    // front of a model of the MIG native interface. This checks the proxy
    // against the controller's own AXI logic at the configured bus width.
    // The native model executes commands strictly in the order they were
    // accepted, as the controller does with Ordering = Strict.
    // ------------------------------------------------------------------
`ifndef MIG_FAMILY
`define MIG_FAMILY "virtexuplus"
`endif
    localparam int MC_DW = 512;
    localparam int MC_AW = 31;
    logic               app_en, app_rdy, app_wdf_wren, app_wdf_end, app_wdf_rdy, app_rd_valid;
    logic [2:0]         app_cmd;
    logic [MC_AW-1:0]   app_addr;
    logic [MC_DW/8-1:0] app_wdf_mask;
    logic [MC_DW-1:0]   app_wdf_data, app_rd_data;
    wire  [9:0]         mig_rid, mig_bid;

    ddr4_v2_2_20_axi #(
        .C_FAMILY(`MIG_FAMILY), .C_ECC("ON"),
        .C_S_AXI_ID_WIDTH(10), .C_S_AXI_ADDR_WIDTH(34), .C_S_AXI_DATA_WIDTH(MEM_AXIDW),
        .C_MC_DATA_WIDTH(MC_DW), .C_MC_ADDR_WIDTH(MC_AW), .C_MC_BURST_MODE("8"), .C_MC_nCK_PER_CLK(4),
        .C_S_AXI_SUPPORTS_NARROW_BURST(0), .C_RD_WR_ARB_ALGORITHM("RD_PRI_REG"),
        .C_S_AXI_REG_EN0(20'h00000), .C_S_AXI_REG_EN1(20'h00000)
    ) mig_axi (
        .aclk(clk), .aresetn(rstn),
        .s_axi_awid({8'h00, AW_ID}), .s_axi_awaddr({2'b00, AW_ADDR}), .s_axi_awlen(AW_LEN), .s_axi_awsize(AW_SIZE),
        .s_axi_awburst(AW_BURST), .s_axi_awlock(1'b0), .s_axi_awcache(4'h0), .s_axi_awprot(AW_PROT), .s_axi_awqos(4'h0),
        .s_axi_awvalid(AW_VALID), .s_axi_awready(AW_READY),
        .s_axi_wdata(W_DATA), .s_axi_wstrb(W_STRB), .s_axi_wlast(W_LAST), .s_axi_wvalid(W_VALID), .s_axi_wready(W_READY),
        .s_axi_bid(mig_bid), .s_axi_bresp(), .s_axi_bvalid(B_VALID), .s_axi_bready(B_READY),
        .s_axi_arid({8'h00, AR_ID}), .s_axi_araddr({2'b00, AR_ADDR}), .s_axi_arlen(AR_LEN), .s_axi_arsize(AR_SIZE),
        .s_axi_arburst(AR_BURST), .s_axi_arlock(1'b0), .s_axi_arcache(4'h0), .s_axi_arprot(AR_PROT), .s_axi_arqos(4'h0),
        .s_axi_arvalid(AR_VALID), .s_axi_arready(AR_READY),
        .s_axi_rid(mig_rid), .s_axi_rdata(R_DATA), .s_axi_rresp(), .s_axi_rlast(R_LAST), .s_axi_rvalid(R_VALID),
        .s_axi_rready(R_READY),
        .s_axi_aruser(1'b0), .s_axi_awuser(1'b0),
        .mc_app_en(app_en), .mc_app_cmd(app_cmd), .mc_app_sz(), .mc_app_addr(app_addr), .mc_app_hi_pri(),
        .mc_app_autoprecharge(), .mc_app_rdy(app_rdy), .mc_init_complete(1'b1),
        .mc_app_wdf_wren(app_wdf_wren), .mc_app_wdf_mask(app_wdf_mask), .mc_app_wdf_data(app_wdf_data),
        .mc_app_wdf_end(app_wdf_end), .mc_app_wdf_rdy(app_wdf_rdy),
        .mc_app_rd_valid(app_rd_valid), .mc_app_rd_data(app_rd_data), .mc_app_rd_end(app_rd_valid),
        .mc_app_ecc_multiple_err(8'h00)
    );
    assign R_ID = mig_rid[1:0];
    assign B_ID = mig_bid[1:0];

    // Native-interface memory: 512-bit words, eight 64-bit words each, in
    // address order. A command address counts 64-bit words.
    logic [MC_DW-1:0] nat_mem[longint unsigned];
    function automatic logic [MC_DW-1:0] nat_read(input longint unsigned w);
        logic [MC_DW-1:0] r;
        if (nat_mem.exists(w)) return nat_mem[w];
        for (int l = 0; l < 8; l++) r[64*l+:64] = init_dword(w * 8 + l);
        return r;
    endfunction
    typedef struct { bit is_write; longint unsigned w; } ncmd_t;
    typedef struct { logic [MC_DW-1:0] data; logic [MC_DW/8-1:0] mask; } nwd_t;
    typedef struct { logic [MC_DW-1:0] data; int ready_cycle; } nrd_t;
    ncmd_t ncmdq[$];
    nwd_t  nwdq[$];
    nrd_t  nrdq[$];
    int    nat_rd_cmds = 0, nat_wr_cmds = 0, nat_wr_bytes_cmds = 0;
    int    rd_out = 0, wr_out = 0;

    always @(posedge clk) begin
        if (!rstn) begin
            app_rdy <= 1'b0; app_wdf_rdy <= 1'b0; app_rd_valid <= 1'b0; app_rd_data <= '0;
        end else begin
            if (app_en && app_rdy) begin
                ncmd_t c;
                if (app_addr[2:0] != 3'b000) fail("MIG native: command address not aligned to a 512-bit word");
                c.is_write = (app_cmd != 3'b001);
                c.w        = app_addr >> 3;
                case (app_cmd)
                    3'b000:  nat_wr_cmds++;
                    3'b001:  nat_rd_cmds++;
                    3'b011:  nat_wr_bytes_cmds++;   // masked write with ECC: read-modify-write
                    default: fail($sformatf("MIG native: unexpected command %0d", app_cmd));
                endcase
                ncmdq.push_back(c);
            end
            if (app_wdf_wren && app_wdf_rdy) begin
                nwd_t d;
                d.data = app_wdf_data; d.mask = app_wdf_mask;
                nwdq.push_back(d);
            end
            // Execute in command order; a write waits for its data word.
            while (ncmdq.size() > 0) begin
                if (ncmdq[0].is_write) begin
                    logic [MC_DW-1:0] cur;
                    if (nwdq.size() == 0) break;
                    cur = nat_read(ncmdq[0].w);
                    for (int l = 0; l < MC_DW / 8; l++)
                        if (!nwdq[0].mask[l]) cur[8*l+:8] = nwdq[0].data[8*l+:8];
                    nat_mem[ncmdq[0].w] = cur;
                    void'(nwdq.pop_front());
                end else begin
                    nrd_t r;
                    r.data        = nat_read(ncmdq[0].w);
                    r.ready_cycle = cycle + (STALLS ? rnd(2, 10) : 2);
                    nrdq.push_back(r);
                end
                void'(ncmdq.pop_front());
            end
            if (nrdq.size() > 0 && cycle >= nrdq[0].ready_cycle) begin
                app_rd_valid <= 1'b1;
                app_rd_data  <= nrdq[0].data;
                void'(nrdq.pop_front());
            end else app_rd_valid <= 1'b0;
            app_rdy     <= !STALLS || chance(85);
            app_wdf_rdy <= !STALLS || chance(85);

            // Passive checks on the proxy's AXI port.
            if (AR_VALID && AR_READY) begin
                check_ax("AR", AR_ADDR, AR_LEN, AR_SIZE, AR_BURST);
                if (AR_SIZE == LOG_BB) n_ar_full++; else n_ar_narrow++;
                rd_out++;
                if (rd_out > max_rd_outstanding) max_rd_outstanding = rd_out;
            end
            if (R_VALID && R_READY) begin
                n_r_beats++;
                if (R_LAST) rd_out--;
            end
            if (AW_VALID && AW_READY) begin
                awreq_t a;
                check_ax("AW", AW_ADDR, AW_LEN, AW_SIZE, AW_BURST);
                if (AW_SIZE == LOG_BB) n_aw_full++; else n_aw_narrow++;
                a.addr = AW_ADDR; a.len = AW_LEN; a.size = AW_SIZE;
                awq.push_back(a);
                wr_out++;
            end
            if (W_VALID && W_READY) begin
                n_w_beats++;
                if (awq.size() > 0) begin
                    check_wstrb(beat_addr(awq[0].addr, awq[0].size, w_idx), awq[0].size, W_STRB);
                    if (W_LAST) begin void'(awq.pop_front()); w_idx = 0; end
                    else w_idx++;
                end
            end
            if (B_VALID && B_READY) wr_out--;
        end
    end
`endif

    task automatic commit_beat(input wbeat_t wb);
        busword_t cur;
        cur = axi_mem_read(wb.bw);
        for (int l = 0; l < BB; l++) if (wb.strb[l]) cur[8*l+:8] = wb.data[8*l+:8];
        axi_mem[wb.bw] = cur;
    endtask

    task automatic check_ax(input string ch, input longint unsigned addr, input int len, input int size, input int burst);
        longint unsigned bytes;
        if ($test$plusargs("TB_VERBOSE"))
            $display("  [%0d] %s addr %h len %0d size %0d", cycle, ch, addr, len, size);
        if (burst != 1) fail($sformatf("AXI: %s burst type %0d, expected INCR", ch, burst));
        if (size > LOG_BB) fail($sformatf("AXI: %s size %0d exceeds the %0d-bit bus", ch, size, MEM_AXIDW));
        bytes = (longint'(len) + 1) << size;
        if (((addr >> size) << size) % 4096 + bytes > 4096) begin
            // Full-width bursts must respect the 4 KB rule. Bursts of 8-byte
            // beats keep the historical 256-beat split and are only counted.
            if (size == LOG_BB && MEM_AXIDW > ARCH_BITS)
                fail($sformatf("AXI: %s full-width burst crosses a 4 KB boundary (addr %h, %0d beats)", ch, addr, len + 1));
            else n_narrow_4k_cross++;
        end
        if (size == LOG_BB && MEM_AXIDW > ARCH_BITS && (addr % BB) != 0)
            fail($sformatf("AXI: %s full-width burst at unaligned address %h", ch, addr));
    endtask

    // A beat narrower than the bus may only strobe bytes of the 64-bit lane its
    // address selects. Inside that lane ESP keeps its own byte order.
    task automatic check_wstrb(input longint unsigned a, input int size, input logic [MEM_AXIDW/8-1:0] strb);
        logic [MEM_AXIDW/8-1:0] allowed;
        if (size >= LOG_BB) return;
        allowed = '0;
        allowed[8*((a >> 3) % LANES)+:8] = 8'hFF;
        if ((strb & ~allowed) != 0)
            fail($sformatf("AXI: narrow W beat at %h strobes %h outside its 64-bit lane", a, strb));
    endtask

    // ------------------------------------------------------------------
    // NoC request queues (show-ahead FIFOs with random gaps)
    // ------------------------------------------------------------------
    cflit_t coh_q[$];
    dflit_t dma_q[$];

    always @(posedge clk) begin
        if (!rstn) begin
            coh_empty <= 1'b1; dma_empty <= 1'b1; coh_dout <= '0; dma_dout <= '0;
        end else begin
            bit c_free, d_free;
            c_free = coh_empty;
            d_free = dma_empty;
            if (!coh_empty && coh_rdreq) begin void'(coh_q.pop_front()); c_free = 1; end
            if (!dma_empty && dma_rdreq) begin void'(dma_q.pop_front()); d_free = 1; end
            if (coh_empty && coh_rdreq) fail("NoC: coherence_req_rdreq while empty");
            if (dma_empty && dma_rdreq) fail("NoC: dma_rcv_rdreq while empty");
            if (c_free) begin
                if (coh_q.size() > 0 && (!STALLS || chance(80))) begin
                    coh_dout <= coh_q[0]; coh_empty <= 1'b0;
                end else coh_empty <= 1'b1;
            end
            if (d_free) begin
                if (dma_q.size() > 0 && (!STALLS || chance(80))) begin
                    dma_dout <= dma_q[0]; dma_empty <= 1'b0;
                end else dma_empty <= 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------
    // NoC response queues and scoreboard
    // ------------------------------------------------------------------
    typedef struct { dflit_t data; dflit_t mask; string what; } dexp_t;
    typedef struct { cflit_t data; cflit_t mask; string what; } cexp_t;
    dexp_t dma_exp[$];
    cexp_t coh_exp[$];
    int    n_dma_flits = 0, n_coh_flits = 0;

    always @(posedge clk) begin
        if (!rstn) begin
            coh_full <= 1'b0; dma_full <= 1'b0;
        end else begin
            if (dma_wrreq) begin
                n_dma_flits++;
                if (dma_full) fail("NoC: dma_snd_wrreq while full");
                if (dma_exp.size() == 0) fail($sformatf("NoC: unexpected DMA response flit %h", dma_din));
                else begin
                    dexp_t e;
                    e = dma_exp.pop_front();
                    if ((dma_din & e.mask) !== (e.data & e.mask))
                        fail($sformatf("DMA response mismatch (%s): got %h expected %h mask %h", e.what, dma_din, e.data, e.mask));
                end
            end
            if (coh_wrreq) begin
                n_coh_flits++;
                if (coh_full) fail("NoC: coherence_rsp_snd_wrreq while full");
                if (coh_exp.size() == 0) fail($sformatf("NoC: unexpected coherence response flit %h", coh_din));
                else begin
                    cexp_t e;
                    e = coh_exp.pop_front();
                    if ((coh_din & e.mask) !== (e.data & e.mask))
                        fail($sformatf("Coherence response mismatch (%s): got %h expected %h", e.what, coh_din, e.data));
                end
            end
            dma_full <= STALLS && chance(20);
            coh_full <= STALLS && chance(20);
        end
    end

    // ------------------------------------------------------------------
    // Packet builders
    // ------------------------------------------------------------------
    function automatic dflit_t dma_hdr(input logic [4:0] msg, input logic [7:0] reserved, input logic [3:0] tid);
        dflit_t f;
        f = '0;
        f[DMA_FLIT-1-:2]            = PREAMBLE_HEADER;
        f[DMA_FLIT-3-:YX]           = SRC_Y;
        f[DMA_FLIT-3-YX-:YX]        = SRC_X;
        f[DMA_FLIT-3-2*YX-:YX]      = MEM_Y;
        f[DMA_FLIT-3-3*YX-:YX]      = MEM_X;
        f[DMA_FLIT-3-4*YX-:5]       = msg;
        f[DMA_FLIT-3-4*YX-5-:8]     = reserved;
        f[DMA_TRAN_ID_MSB:DMA_TRAN_ID_LSB] = tid[DMA_TRAN_ID_WIDTH-1:0];
        return f;
    endfunction
    // Response header: source and destination swapped; routing bits not compared.
    task automatic expect_dma_hdr(input logic [4:0] msg, input logic [3:0] tid, input string what);
        dexp_t e;
        e.data = '0; e.mask = '0;
        e.data[DMA_FLIT-1-:2]       = PREAMBLE_HEADER;
        e.data[DMA_FLIT-3-:YX]      = MEM_Y;
        e.data[DMA_FLIT-3-YX-:YX]   = MEM_X;
        e.data[DMA_FLIT-3-2*YX-:YX] = SRC_Y;
        e.data[DMA_FLIT-3-3*YX-:YX] = SRC_X;
        e.data[DMA_FLIT-3-4*YX-:5]  = msg;
        e.data[DMA_TRAN_ID_MSB:DMA_TRAN_ID_LSB] = tid[DMA_TRAN_ID_WIDTH-1:0];
        e.mask[DMA_FLIT-1:DMA_TRAN_ID_LSB] = '1;
        e.what = {what, " header"};
        dma_exp.push_back(e);
    endtask
    function automatic dflit_t dma_body(input logic [1:0] pre, input logic [DMA_NOC_WIDTH-1:0] payload);
        return {pre, payload};
    endfunction

    function automatic cflit_t coh_hdr(input logic [4:0] msg, input logic [7:0] reserved);
        cflit_t f;
        f = '0;
        f[COH_FLIT-1-:2]        = PREAMBLE_HEADER;
        f[COH_FLIT-3-:YX]       = SRC_Y;
        f[COH_FLIT-3-YX-:YX]    = SRC_X;
        f[COH_FLIT-3-2*YX-:YX]  = MEM_Y;
        f[COH_FLIT-3-3*YX-:YX]  = MEM_X;
        f[COH_FLIT-3-4*YX-:5]   = msg;
        f[COH_FLIT-3-4*YX-5-:8] = reserved;
        return f;
    endfunction
    task automatic expect_coh_hdr(input logic [4:0] msg, input string what);
        cexp_t e;
        e.data = '0; e.mask = '0;
        e.data[COH_FLIT-1-:2]       = PREAMBLE_HEADER;
        e.data[COH_FLIT-3-:YX]      = MEM_Y;
        e.data[COH_FLIT-3-YX-:YX]   = MEM_X;
        e.data[COH_FLIT-3-2*YX-:YX] = SRC_Y;
        e.data[COH_FLIT-3-3*YX-:YX] = SRC_X;
        e.data[COH_FLIT-3-4*YX-:5]  = msg;
        e.mask[COH_FLIT-1-:2+4*YX+5] = '1;
        e.what = {what, " header"};
        coh_exp.push_back(e);
    endtask

    // ------------------------------------------------------------------
    // Operations (accelerator DMA and CPU instance)
    // ------------------------------------------------------------------
    int n_dma_rd = 0, n_dma_wr = 0, n_cpu_rd = 0, n_cpu_wr = 0;
    int n_dma_rd_fullwidth_eligible = 0;
    logic [3:0] tran_cnt = 0;

    // Non-coherent DMA read of `words` 64-bit words.
    task automatic op_dma_read(input longint unsigned addr, input int words);
        dflit_t f;
        string  what;
        what = $sformatf("DMA read addr %h words %0d", addr, words);
        tran_cnt++;
        dma_q.push_back(dma_hdr(DMA_TO_DEV, 8'h00, tran_cnt));
        dma_q.push_back(dma_body(PREAMBLE_BODY, DMA_NOC_WIDTH'(addr)));
        dma_q.push_back(dma_body(PREAMBLE_TAIL, DMA_NOC_WIDTH'(words)));
        expect_dma_hdr(DMA_TO_DEV, tran_cnt, what);
        for (int j = 0; j < (words + WPF - 1) / WPF; j++) begin
            dexp_t e;
            e.data = '0; e.mask = '0;
            for (int k = 0; k < WPF; k++)
                if (j * WPF + k < words) begin
                    e.data[64*k+:64] = to_bus(ref_read((addr >> 3) + j * WPF + k));
                    e.mask[64*k+:64] = '1;
                end
            e.data[DMA_FLIT-1-:2] = (j == (words + WPF - 1) / WPF - 1) ? PREAMBLE_TAIL : PREAMBLE_BODY;
            e.mask[DMA_FLIT-1-:2] = '1;
            e.what = $sformatf("%s flit %0d", what, j);
            dma_exp.push_back(e);
        end
        n_dma_rd++;
        if (addr % 16 == 0 && words % 2 == 0) n_dma_rd_fullwidth_eligible++;
    endtask

    // Non-coherent DMA write of `words` random 64-bit words.
    task automatic op_dma_write(input longint unsigned addr, input int words);
        int nf;
        nf = (words + WPF - 1) / WPF;
        dma_q.push_back(dma_hdr(DMA_FROM_DEV, 8'h00, 4'h0));
        dma_q.push_back(dma_body(PREAMBLE_BODY, DMA_NOC_WIDTH'(addr)));
        dma_q.push_back(dma_body(PREAMBLE_BODY, DMA_NOC_WIDTH'(words)));
        for (int j = 0; j < nf; j++) begin
            logic [DMA_NOC_WIDTH-1:0] p;
            for (int k = 0; k < WPF; k++) begin
                p[64*k+:64] = {$urandom, $urandom};
                if (j * WPF + k < words) ref_mem[(addr >> 3) + j * WPF + k] = to_bus(p[64*k+:64]);
            end
            dma_q.push_back(dma_body(j == nf - 1 ? PREAMBLE_TAIL : PREAMBLE_BODY, p));
        end
        n_dma_wr++;
    endtask

    function automatic logic [7:0] strb_pat(input int size);
        case (size)
            0: return 8'b10000000;
            1: return 8'b11000000;
            2: return 8'b11110000;
            default: return 8'b11111111;
        endcase
    endfunction

    // CPU read: `beats` beats of 2**size bytes, replayed from the CPU's AXI request.
    task automatic op_cpu_read(input longint unsigned addr, input int size, input int beats);
        logic [4:0] msg;
        string      what;
        what = $sformatf("CPU read addr %h size %0d beats %0d", addr, size, beats);
        msg  = (size == 0) ? REQ_GETS_B : (size == 1) ? REQ_GETS_HW : REQ_GETS_W;
        coh_q.push_back(coh_hdr(msg, {4'h0, (size == 3), 3'b000}));
        coh_q.push_back({PREAMBLE_BODY, 64'(addr)});
        coh_q.push_back({PREAMBLE_TAIL, 64'(beats)});
        expect_coh_hdr(RSP_DATA, what);
        for (int b = 0; b < beats; b++) begin
            cexp_t e;
            e.data = {(b == beats - 1) ? PREAMBLE_TAIL : PREAMBLE_BODY,
                      to_bus(ref_read(beat_addr(addr, size, b) >> 3))};
            e.mask = '1;
            e.what = $sformatf("%s beat %0d", what, b);
            coh_exp.push_back(e);
        end
        n_cpu_rd++;
    endtask

    // CPU write: one single-beat AXI write per data flit.
    task automatic op_cpu_write(input longint unsigned addr, input int size, input int beats);
        logic [4:0] msg;
        msg = (size == 0) ? REQ_GETM_B : (size == 1) ? REQ_GETM_HW : REQ_GETM_W;
        coh_q.push_back(coh_hdr(msg, {4'h0, (size == 3), 3'b000}));
        coh_q.push_back({PREAMBLE_BODY, 64'(addr)});
        for (int b = 0; b < beats; b++) begin
            logic [63:0]     d, bus, cur;
            logic [7:0]      m;
            longint unsigned a;
            d   = {$urandom, $urandom};
            a   = addr + (longint'(b) << size);
            bus = to_bus(d);
            m   = strb_pat(size) >> a[2:0];
            cur = ref_read(a >> 3);
            for (int l = 0; l < 8; l++) if (m[l]) cur[8*l+:8] = bus[8*l+:8];
            ref_mem[a >> 3] = cur;
            coh_q.push_back({(b == beats - 1) ? PREAMBLE_TAIL : PREAMBLE_BODY, d});
        end
        n_cpu_wr++;
    endtask

    // ------------------------------------------------------------------
    // Operations (debug-link / Ethernet instance, eth_dma = 1)
    // ------------------------------------------------------------------
    function automatic logic [31:0] half_of(input logic [63:0] d, input longint unsigned a);
        return a[2] ? d[31:0] : d[63:32];
    endfunction
    task automatic ref_write32(input longint unsigned a, input logic [31:0] d);
        logic [63:0] cur;
        cur = ref_read(a >> 3);
        if (a[2]) cur[31:0] = d; else cur[63:32] = d;
        ref_mem[a >> 3] = cur;
    endtask

    task automatic op_ahb_read(input longint unsigned addr);
        cexp_t e;
        coh_q.push_back(coh_hdr(AHB_RD, 8'h00));
        coh_q.push_back({PREAMBLE_TAIL, 64'(addr)});
        expect_coh_hdr(RSP_AHB_RD, $sformatf("AHB read %h", addr));
        e.data = {PREAMBLE_TAIL, ref_read(addr >> 3)};
        e.mask = '1;
        e.what = $sformatf("AHB read %h data", addr);
        coh_exp.push_back(e);
        n_cpu_rd++;
    endtask

    task automatic op_ahb_write(input longint unsigned addr, input int words);
        coh_q.push_back(coh_hdr(AHB_WR, 8'h00));
        coh_q.push_back({PREAMBLE_BODY, 64'(addr)});
        for (int i = 0; i < words; i++) begin
            logic [31:0] d;
            d = $urandom;
            ref_write32(addr + 4 * i, d);
            coh_q.push_back({(i == words - 1) ? PREAMBLE_TAIL : PREAMBLE_BODY, 32'h0, d});
        end
        n_cpu_wr++;
    endtask

    task automatic op_eth_dma_read(input longint unsigned addr, input int words);
        string what;
        what = $sformatf("ETH DMA read addr %h words %0d", addr, words);
        tran_cnt++;
        dma_q.push_back(dma_hdr(REQ_DMA_READ, 8'h00, tran_cnt));
        dma_q.push_back(dma_body(PREAMBLE_BODY, DMA_NOC_WIDTH'(addr)));
        dma_q.push_back(dma_body(PREAMBLE_TAIL, DMA_NOC_WIDTH'(words)));
        expect_dma_hdr(RSP_DATA_DMA, tran_cnt, what);
        for (int i = 0; i < words; i++) begin
            dexp_t e;
            e.data = '0;
            e.data[31:0] = half_of(ref_read((addr + 4 * i) >> 3), addr + 4 * i);
            e.data[DMA_FLIT-1-:2] = (i == words - 1) ? PREAMBLE_TAIL : PREAMBLE_BODY;
            e.mask = '1;
            e.what = $sformatf("%s word %0d", what, i);
            dma_exp.push_back(e);
        end
        n_dma_rd++;
    endtask

    task automatic op_eth_dma_write(input longint unsigned addr, input int words);
        dma_q.push_back(dma_hdr(REQ_DMA_WRITE, 8'h00, 4'h0));
        dma_q.push_back(dma_body(PREAMBLE_BODY, DMA_NOC_WIDTH'(addr)));
        for (int i = 0; i < words; i++) begin
            logic [31:0] d;
            d = $urandom;
            ref_write32(addr + 4 * i, d);
            dma_q.push_back(dma_body((i == words - 1) ? PREAMBLE_TAIL : PREAMBLE_BODY, DMA_NOC_WIDTH'(d)));
        end
        n_dma_wr++;
    endtask

    // ------------------------------------------------------------------
    // Stimulus
    // ------------------------------------------------------------------
    localparam longint unsigned REGION_BASE [2] = '{64'h8A00_0000, 64'h8A20_0000};
    localparam int              REGION_BYTES    = 64 * 1024;

    function automatic bit all_idle();
        return coh_q.size() == 0 && dma_q.size() == 0 && coh_empty && dma_empty &&
               coh_exp.size() == 0 && dma_exp.size() == 0 &&
`ifdef WITH_MIG_AXI
               rd_out == 0 && wr_out == 0 && ncmdq.size() == 0 && nrdq.size() == 0 && awq.size() == 0;
`else
               rq.size() == 0 && awq.size() == 0 && bq.size() == 0 && !B_VALID;
`endif
    endfunction

    task automatic drain(input string where);
        int guard;
        guard = 0;
        while (!all_idle()) begin
            @(posedge clk);
            guard++;
            if (guard > 400000) begin
                fail($sformatf("timeout draining %s: coh_q %0d dma_q %0d coh_exp %0d dma_exp %0d rq %0d awq %0d bq %0d",
                               where, coh_q.size(), dma_q.size(), coh_exp.size(), dma_exp.size(),
                               rq.size(), awq.size(), bq.size()));
                $display("NOC2AXIMST_TB_FAIL: deadlock");
                $finish;
            end
        end
        repeat (10) @(posedge clk);
    endtask

    // A DMA request: mostly 16-byte aligned with an even word count (what a
    // 128-bit accelerator issues), sometimes not, and placed anywhere relative
    // to the 4 KB boundaries.
    task automatic rand_dma_shape(input longint unsigned base, input bit is_write,
                                  output longint unsigned addr, output int words);
        int sel, maxw;
        sel = rnd(0, 99);
        if      (sel < 35) words = rnd(1, 16);
        else if (sel < 70) words = rnd(17, 700);
        else               words = rnd(701, MAX_DMA_WORDS);
        if (!chance(25)) words = (words + 1) & ~1;
        // Known defect of the historical 256-beat split, present before this
        // testbench existed: a request of 256*n + 1 eight-byte beats (n >= 1)
        // loses its last beat on the DMA write path and on the classic
        // (single-outstanding) DMA read path, and the write then hangs the
        // proxy. Such a length is odd, so a 128-bit accelerator never issues
        // it. Keep it out of the random stimulus.
        if (words > 256 && words % 256 == 1 && (is_write || MULTI_OT == 0)) words++;
        maxw = REGION_BYTES / 8 - words;
        addr = base + 8 * longint'(rnd(0, maxw));
        if (!chance(25)) addr = addr & ~64'hF;
        if (chance(15)) addr = addr & ~64'hFFF;  // on a 4 KB boundary
        if (addr + 8 * words > base + REGION_BYTES) addr = base;
    endtask

    task automatic epoch_acc(input int e);
        longint unsigned cpu_base, dma_base, addr;
        int words, size, beats;
        cpu_base = REGION_BASE[e % 2];
        dma_base = REGION_BASE[(e + 1) % 2];
        for (int i = 0; i < OPS_PER_EPOCH; i++) begin
            int sel;
            sel = rnd(0, 99);
            if (sel < 40) begin
                rand_dma_shape(dma_base, 1'b0, addr, words);
                op_dma_read(addr, words);
            end else if (sel < 60) begin
                rand_dma_shape(dma_base, 1'b1, addr, words);
                if (war_safe) begin
                    int guard;
                    guard = 0;
                    while (dma_exp.size() != 0 && guard < 400000) begin @(posedge clk); guard++; end
                end
                op_dma_write(addr, words);
            end else begin
                size  = rnd(0, 3);
                beats = chance(60) ? rnd(1, 2) : rnd(1, 9);
                addr  = cpu_base + (longint'(rnd(0, REGION_BYTES - 256)) >> size << size);
                if (sel < 82) op_cpu_read(addr, size, beats);
                // The proxy computes the write strobe once per request, from
                // the first address, so a multi-beat write narrower than 8
                // bytes would strobe the first beat's lanes on every beat.
                // The CPUs never issue one; the testbench does not either.
                else op_cpu_write(addr, size, (size == 3) ? beats : 1);
            end
            // Sometimes let the queues run dry, sometimes pile requests up.
            if (chance(30)) repeat (rnd(1, 400)) @(posedge clk);
        end
    endtask

    task automatic epoch_eth(input int e);
        longint unsigned cpu_base, dma_base, addr;
        cpu_base = REGION_BASE[e % 2];
        dma_base = REGION_BASE[(e + 1) % 2];
        for (int i = 0; i < OPS_PER_EPOCH; i++) begin
            int sel;
            sel = rnd(0, 99);
            if (sel < 25) begin
                addr = dma_base + 4 * longint'(rnd(0, REGION_BYTES / 4 - 400));
                op_eth_dma_read(addr, rnd(1, 380));
            end else if (sel < 50) begin
                addr = dma_base + 4 * longint'(rnd(0, REGION_BYTES / 4 - 400));
                op_eth_dma_write(addr, rnd(1, 380));
            end else if (sel < 75) begin
                addr = cpu_base + 4 * longint'(rnd(0, REGION_BYTES / 4 - 64));
                op_ahb_read(addr);
            end else begin
                addr = cpu_base + 4 * longint'(rnd(0, REGION_BYTES / 4 - 64));
                op_ahb_write(addr, rnd(1, 40));
            end
            if (chance(30)) repeat (rnd(1, 200)) @(posedge clk);
        end
    endtask

    // Final check: the AXI memory holds what the requests said it should.
    task automatic check_final_memory();
        int n;
        n = 0;
        foreach (ref_mem[dw]) begin
            logic [63:0] got;
`ifdef WITH_MIG_AXI
            logic [MC_DW-1:0] nw;
            nw  = nat_read(dw >> 3);
            got = nw[64*(dw % 8)+:64];
`else
            busword_t bw;
            bw  = axi_mem_read(dw / LANES);
            got = bw[64*(dw % LANES)+:64];
`endif
            if (got !== ref_mem[dw])
                fail($sformatf("final memory: 8-byte word at %h is %h, expected %h", dw * 8, got, ref_mem[dw]));
            n++;
        end
        $display("  final memory check: %0d written 64-bit words compared", n);
    endtask

    int t0_cycle, t0_beats;

    initial begin
        $display("noc2aximst_tb: MEM_AXIDW=%0d ARCH_BITS=%0d DMA_NOC_WIDTH=%0d MULTI_OT=%0d ETH=%0d STALLS=%0d",
                 MEM_AXIDW, ARCH_BITS, DMA_NOC_WIDTH, MULTI_OT, ETH, STALLS);
        repeat (8) @(posedge clk);
        rstn = 1'b1;
        repeat (4) @(posedge clk);

        if (!ETH) begin
            // Directed: one long aligned read with the request queue kept busy,
            // used for the beats-per-cycle figure when STALLS = 0.
            op_dma_read(REGION_BASE[0], 4096);
            wait (n_ar_full + n_ar_narrow > 0);
            t0_cycle = cycle; t0_beats = n_r_beats;
            drain("directed long read");
            $display("  long aligned read of 4096 words: %0d R beats in %0d cycles (%0d full-width ARs, %0d narrow ARs)",
                     n_r_beats - t0_beats, cycle - t0_cycle, n_ar_full, n_ar_narrow);
            // Directed: read, write and read back across a 4 KB boundary from an
            // address that is 16-byte aligned but not 4 KB aligned.
            op_dma_write(REGION_BASE[0] + 64'hFF0, 1024);
            op_dma_read(REGION_BASE[0] + 64'hFF0, 1024);
            op_dma_read(REGION_BASE[0] + 64'hFF8, 1023);
            drain("directed 4 KB crossing");
            // Directed: 514 words is 257 full-width beats, one more than a burst.
            op_dma_write(REGION_BASE[0] + 64'h3000, 514);
            op_dma_read(REGION_BASE[0] + 64'h3000, 514);
            op_dma_write(REGION_BASE[0] + 64'h5FF0, 516);
            op_dma_read(REGION_BASE[0] + 64'h5FF0, 516);
            drain("directed 257-beat requests");
        end

        for (int e = 0; e < NUM_EPOCHS; e++) begin
            if (ETH) epoch_eth(e); else epoch_acc(e);
            drain($sformatf("epoch %0d", e));
        end

        check_final_memory();

        $display("  requests: %0d DMA reads (%0d full-width eligible), %0d DMA writes, %0d CPU reads, %0d CPU writes",
                 n_dma_rd, n_dma_rd_fullwidth_eligible, n_dma_wr, n_cpu_rd, n_cpu_wr);
        $display("  AXI: AR full-width %0d narrow %0d | AW full-width %0d narrow %0d | R beats %0d W beats %0d",
                 n_ar_full, n_ar_narrow, n_aw_full, n_aw_narrow, n_r_beats, n_w_beats);
        $display("  AXI: bursts of 8-byte beats crossing 4 KB (historical split, not an error): %0d", n_narrow_4k_cross);
        $display("  AXI: cycles in which a waiting AR changed its id (known, see the testbench): %0d", n_arid_changed);
        $display("  NoC: %0d DMA response flits, %0d coherence response flits; most read bursts queued at the memory: %0d",
                 n_dma_flits, n_coh_flits, max_rd_outstanding);
`ifdef WITH_MIG_AXI
        $display("  MIG native interface: %0d read commands, %0d write commands, %0d masked (read-modify-write) writes",
                 nat_rd_cmds, nat_wr_cmds, nat_wr_bytes_cmds);
`endif
        if (errors == 0) $display("NOC2AXIMST_TB_PASS");
        else $display("NOC2AXIMST_TB_FAIL: %0d error(s)", errors);
        $finish;
    end

endmodule
