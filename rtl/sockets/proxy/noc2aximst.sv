// Copyright (c) 2011-2026 Columbia University, System Level Design Group
// SPDC-License-Identifier: Apache-2.0

`timescale 1ns / 1ps

import esp_global_sv::*;
import noc2aximst_pkg::*;


`define PREAMBLE_WIDTH 2
`define MSG_TYPE_WIDTH 5
`define RESERVED_WIDTH 8
`define NEXT_ROUTING_WIDTH 5

module noc2aximst #(
    parameter integer tech               = 0,
    parameter integer mst_index          = 0,
    parameter integer axitran            = 0,
    parameter integer little_end         = 0,
    parameter integer eth_dma            = 0,
    parameter integer narrow_noc         = 0,
    parameter integer cacheline          = 4,
    parameter integer this_coh_flit_size = 34
) (
    input logic                               ARESETn,
    input logic                               ACLK,
    input logic  [       GLOB_YX_WIDTH-1 : 0] local_y,
    input logic  [       GLOB_YX_WIDTH-1 : 0] local_x,
    output logic [                     1 : 0] AR_ID,
    output logic [ GLOB_PHYS_ADDR_BITS-1 : 0] AR_ADDR,
    output logic [                     7 : 0] AR_LEN,
    output logic [                     2 : 0] AR_SIZE,
    output logic [                     1 : 0] AR_BURST,
    output logic                              AR_LOCK,
    output logic [                     2 : 0] AR_PROT,
    output logic                              AR_VALID,
    input  logic                              AR_READY,
    input  logic [                     1 : 0] R_ID,
    input  logic [               AXIDW-1 : 0] R_DATA,
    input  logic [                     1 : 0] R_RESP,       // not used
    input  logic                              R_LAST,
    input  logic                              R_VALID,
    output logic                              R_READY,
    output logic [                     1 : 0] AW_ID,
    output logic [ GLOB_PHYS_ADDR_BITS-1 : 0] AW_ADDR,
    output logic [                     7 : 0] AW_LEN,
    output logic [                     2 : 0] AW_SIZE,
    output logic [                     1 : 0] AW_BURST,
    output logic                              AW_LOCK,
    output logic [                     2 : 0] AW_PROT,
    output logic                              AW_VALID,
    input  logic                              AW_READY,
    output logic [               AXIDW-1 : 0] W_DATA,
    output logic [                  AW-1 : 0] W_STRB,
    output logic                              W_LAST,
    output logic                              W_VALID,
    input  logic                              W_READY,
    input  logic [                     1 : 0] B_ID,
    input  logic [                     1 : 0] B_RESP,       // not used
    input  logic                              B_VALID,      // not used
    output logic                              B_READY,
    output logic                              coherence_req_rdreq,
    input  logic [  this_coh_flit_size-1 : 0] coherence_req_data_out,
    input  logic                              coherence_req_empty,

    output logic                              coherence_rsp_snd_wrreq,
    output logic [  this_coh_flit_size-1 : 0] coherence_rsp_snd_data_in,
    input  logic                              coherence_rsp_snd_full,

    output logic                              dma_rcv_rdreq,
    input  logic [   DMA_NOC_FLIT_SIZE-1 : 0] dma_rcv_data_out,
    input  logic                              dma_rcv_empty,

    output logic                              dma_snd_wrreq,
    output logic [   DMA_NOC_FLIT_SIZE-1 : 0] dma_snd_data_in,
    input  logic                              dma_snd_full

);

    // AR_ID is dynamically muxed below: DMA reads use a per-context index
    // (so the memory controller can demux R_ID across MAX_DMA_OT outstanding
    // reads); coherence reads keep using mst_index. AW_ID stays static — the
    // write path is still single-outstanding here.
    assign AW_ID    = mst_index;

    assign AW_LOCK  = 1'b0;
    assign AR_LOCK  = 1'b0;

    assign AR_BURST = XBURST_INCR;
    assign AW_BURST = XBURST_INCR;

    logic [MAX_NOC_FLIT_SIZE-this_coh_flit_size : 0] this_noc_flit_pad;
    assign this_noc_flit_pad = 0;
    logic [MAX_NOC_FLIT_SIZE-1 : 0] pad_coherence_req_data_out;
    assign pad_coherence_req_data_out = {this_noc_flit_pad, coherence_req_data_out};


    logic [MAX_NOC_FLIT_SIZE-DMA_NOC_FLIT_SIZE : 0] dma_noc_flit_pad;
    assign dma_noc_flit_pad = 0;
    logic [MAX_NOC_FLIT_SIZE-1 : 0] pad_dma_rcv_data_out;
    assign pad_dma_rcv_data_out = {dma_noc_flit_pad, dma_rcv_data_out};


    logic [this_coh_flit_size-1 : 0] header;
    logic [this_coh_flit_size-1 : 0] header_reg;
    logic sample_header;

    // This version complements the WSTRB-aware `axislv2noc` implementation.
    // When `axislv2noc` splits a non-coherent DMA beat into subword packets, it
    // encodes the effective write size in DMA-header reserved bits [6:4].
    // Decode that override here so `AW_SIZE`/`W_STRB` preserve the original
    // byte-lane intent when the request is replayed on the AXI side.
    // Delay impact in this block:
    // - No new FSM states are added for the DMA size-override path.
    // - Decode is combinational and reuses the existing AW/W request flow.
    // - Extra latency comes indirectly from `axislv2noc` emitting more packets.
    localparam int DMA_HDR_SIZE_LSB       = 4;
    localparam int DMA_HDR_SIZE_MSB       = 5;
    localparam int DMA_HDR_SIZE_VALID_BIT = 6;


    logic [DMA_NOC_FLIT_SIZE-1 : 0] dma_header;
    logic [DMA_NOC_FLIT_SIZE-1 : 0] dma_header_reg;
    logic sample_dma_header;

    logic [`RESERVED_WIDTH-1 : 0] reserved;
    logic [`PREAMBLE_WIDTH-1 : 0] preamble;
    logic [`PREAMBLE_WIDTH-1 : 0] dma_preamble;

    logic [this_coh_flit_size-`PREAMBLE_WIDTH-1 : 0] coh_rd_data_flit;
    integer i, j;

    logic [4 : 0] current_state;
    logic [4 : 0] next_state;

    localparam RECEIVE_HEADER = 5'b00000;
    localparam RECEIVE_ADDRESS = 5'b00001;
    localparam RECEIVE_LENGTH = 5'b00010;
    localparam READ_REQUEST = 5'b00011;
    localparam SEND_HEADER = 5'b00100;
    localparam SEND_DATA = 5'b00101;
    localparam WRITE_REQUEST = 5'b00110;
    localparam WRITE_DATA_EDCL = 5'b00111;
    localparam WRITE_DATA = 5'b01000;
    localparam WRITE_DATA_WAIT = 5'b10110;
    localparam WRITE_RESPONSE_WAIT = 5'b10111;
    //parameter WRITE_LAST_DATA = 5'b01001;

    localparam DMA_RECEIVE_ADDRESS = 5'b01010;
    localparam DMA_RECEIVE_READ_LENGTH = 5'b01011;
    localparam DMA_READ_REQUEST = 5'b01100;
    localparam DMA_SEND_HEADER = 5'b01101;
    localparam DMA_SEND_DATA = 5'b01110;

    localparam DMA_RECEIVE_WRITE_LENGTH = 5'b01111;
    localparam DMA_WRITE_REQUEST = 5'b10000;
    //parameter DMA_WRITE_WAIT           = 5'b10001;
    localparam DMA_WRITE_DATA = 5'b10010;
    //parameter DMA_WRITE_LAST_DATA      = 5'b10011;
    localparam DMA_WRITE_DATA_COH = 5'b10100;
    localparam DMA_WRITE_DATA_ETH = 5'b10101;

    reg_type cs, ns;

    // -------------------------------------------------------------------------
    // Multi-outstanding DMA read context table
    // -------------------------------------------------------------------------
    // Holds up to MAX_DMA_OT outstanding non-coherent DMA reads. Each context
    // captures the request state needed to: (1) issue continuation AXI bursts
    // for transactions whose total length exceeds 256 beats; (2) re-emit the
    // response header back to the originator; (3) pack AXI R-channel data
    // into DMA NoC flits.
    //
    // MAX_DMA_OT is bounded by AR_ID width toward the memory controller
    // (2 bits -> 4 max). Set to 2 to stay bit-compatible with esp_dma_axi.
    // ctx_alloc_idx is a single bit because MAX_DMA_OT=2.
    //
    // Concurrency rules enforced below:
    // - Coherence requests are stalled while any DMA context is active to
    //   avoid AR_ID collisions on the shared AXI master interface.
    // - DMA dequeue from the request queue is gated by ctx_alloc_avail so
    //   the table is never overrun.
    // -------------------------------------------------------------------------
    localparam MAX_DMA_OT = 2;

    logic                                         ctx_valid     [0:MAX_DMA_OT-1];
    logic [DMA_NOC_FLIT_SIZE-1:0]                 ctx_rsp_header[0:MAX_DMA_OT-1];
    logic [GLOB_PHYS_ADDR_BITS-1:0]               ctx_ar_addr   [0:MAX_DMA_OT-1];
    logic [7:0]                                   ctx_ar_len    [0:MAX_DMA_OT-1];
    logic [2:0]                                   ctx_ar_size   [0:MAX_DMA_OT-1];
    logic [2:0]                                   ctx_ar_prot   [0:MAX_DMA_OT-1];
    logic [31:0]                                  ctx_count     [0:MAX_DMA_OT-1];
    logic [$clog2(DMA_NOC_WIDTH/ARCH_BITS):0]     ctx_word_cnt  [0:MAX_DMA_OT-1];
    logic [DMA_NOC_WIDTH-1:0]                     ctx_noc_data  [0:MAX_DMA_OT-1];

    // Free-slot allocation (1-bit index, MAX_DMA_OT=2).
    logic        any_ctx_valid;
    logic        ctx_alloc_avail;
    logic        ctx_alloc_idx;
    assign any_ctx_valid   = ctx_valid[0] | ctx_valid[1];
    assign ctx_alloc_avail = ~ctx_valid[0] | ~ctx_valid[1];
    assign ctx_alloc_idx   = ctx_valid[0] ? 1'b1 : 1'b0;

    // Response FSM — owns the dma_snd path for DMA read responses.
    // States:
    //  DMA_RSP_IDLE   — wait for any in-flight context to need draining
    //  DMA_RSP_HEADER — emit the response header for the active context
    //  DMA_RSP_DATA   — pack AXI R-beats into NoC flits and send
    //  DMA_RSP_CONT_AR — re-issue AXI AR for the next 256-beat segment of a
    //                    multi-segment context (large DMA transfers)
    localparam [1:0] DMA_RSP_IDLE    = 2'b00;
    localparam [1:0] DMA_RSP_HEADER  = 2'b01;
    localparam [1:0] DMA_RSP_DATA    = 2'b10;
    localparam [1:0] DMA_RSP_CONT_AR = 2'b11;
    logic [1:0] dma_rsp_state, dma_rsp_next;

    // Response order FIFO — tracks allocation order so responses drain to
    // the NoC in the same order they were issued (per-this-noc2aximst).
    // End-to-end reordering across memory tiles is then resolved by the
    // accelerator-side response FSM via get_dma_tran_id.
    logic        rsp_fifo [0:MAX_DMA_OT-1];
    logic        rsp_fifo_rd;
    logic        rsp_fifo_wr;
    logic [1:0]  rsp_fifo_cnt;
    logic        rsp_fifo_empty;
    assign rsp_fifo_empty = (rsp_fifo_cnt == 2'd0);

    // Active context = head of response FIFO.
    logic        active_ctx;
    assign active_ctx = rsp_fifo[rsp_fifo_rd];

    // Combinational control strobes consumed by the sequential block.
    logic        ctx_alloc_en;
    logic        ctx_free_en;
    logic        rsp_cont_en;
    logic        rsp_fifo_push;
    logic        rsp_fifo_pop;
    logic        rsp_data_handshake;

    // Response-FSM next-state for word_cnt and packed flit data.
    logic [DMA_NOC_WIDTH-1:0]                     rsp_noc_data_next;
    logic [$clog2(DMA_NOC_WIDTH/ARCH_BITS):0]     rsp_word_cnt_next;

    // DMA AR channel mux (initial request and continuation bursts).
    logic        dma_ar_valid;
    logic [GLOB_PHYS_ADDR_BITS-1:0] dma_ar_addr;
    logic [7:0]  dma_ar_len;
    logic [2:0]  dma_ar_size;
    logic [2:0]  dma_ar_prot;
    logic [1:0]  dma_ar_id;

    // Response FSM owns AR during continuation-burst state.
    logic        rsp_needs_ar;
    assign rsp_needs_ar = (dma_rsp_state == DMA_RSP_CONT_AR);

    function automatic logic [2:0] target_dma_axi_size();
        if (ARCH_BITS == 32) return XSIZE_WORD;
        return XSIZE_DWORD;
    endfunction

    // Decode `nocpackage` DMA size encoding:
    // 00=byte, 01=halfword, 10=word, 11=dword.
    function automatic logic [2:0] dma_code_to_axi_size(input logic [1:0] code);
        case (code)
            2'b00:   return XSIZE_BYTE;
            2'b01:   return XSIZE_HWORD;
            2'b10:   return XSIZE_WORD;
            default: return XSIZE_DWORD;
        endcase
    endfunction

    // Rebuild AXI byte enables from the effective transfer size/address.
    // For WSTRB-split DMA packets the payload still carries one replicated word;
    // `W_STRB` selects the intended byte lanes at the final AXI target.
    function automatic logic [AW-1:0] compute_axi_wstrb(input logic [2:0] axi_size,
                                                        input logic [GLOB_PHYS_ADDR_BITS-1:0] axi_addr);
        logic [AW-1:0] wstrb;

        wstrb = '0;
        if (ARCH_BITS == 32) begin
            if (axi_size == XSIZE_BYTE)
                wstrb = 4'b1000 >> axi_addr[$clog2(AW)-1:0];
            else if (axi_size == XSIZE_HWORD)
                wstrb = 4'b1100 >> axi_addr[$clog2(AW)-1:0];
            else
                wstrb = 4'b1111;
        end else begin
            if (axi_size == XSIZE_BYTE)
                wstrb = 8'b10000000 >> axi_addr[$clog2(AW)-1:0];
            else if (axi_size == XSIZE_HWORD)
                wstrb = 8'b11000000 >> axi_addr[$clog2(AW)-1:0];
            else if (axi_size == XSIZE_WORD)
                wstrb = 8'b11110000 >> axi_addr[$clog2(AW)-1:0];
            else
                wstrb = 8'b11111111 >> axi_addr[$clog2(AW)-1:0];
        end
        return wstrb;
    endfunction

    always_comb begin
        ns = cs;
        next_state = current_state;
        preamble     = pad_coherence_req_data_out[this_coh_flit_size-1:this_coh_flit_size-`PREAMBLE_WIDTH];
        dma_preamble = pad_dma_rcv_data_out[DMA_NOC_FLIT_SIZE-1:DMA_NOC_FLIT_SIZE-`PREAMBLE_WIDTH];
        reserved = 0;
        sample_header = 1'b0;
        sample_dma_header = 1'b0;
        coherence_req_rdreq = 0;
        coherence_rsp_snd_data_in = 0;  //TODO: change this to an assign
        coherence_rsp_snd_wrreq = 1'b0;
        dma_rcv_rdreq = 0;
        dma_snd_data_in = 0;
        dma_snd_wrreq = 1'b0;
        coh_rd_data_flit = 0;
        ns.aw_valid = 1'b0;
        ns.ar_valid = 1'b0;

        // Response FSM combinational defaults.
        dma_rsp_next       = dma_rsp_state;
        ctx_alloc_en       = 1'b0;
        ctx_free_en        = 1'b0;
        rsp_cont_en        = 1'b0;
        rsp_fifo_push      = 1'b0;
        rsp_fifo_pop       = 1'b0;
        rsp_data_handshake = 1'b0;
        dma_ar_valid       = 1'b0;
        dma_ar_addr        = '0;
        dma_ar_len         = '0;
        dma_ar_size        = '0;
        dma_ar_prot        = '0;
        dma_ar_id          = '0;
        rsp_noc_data_next  = ctx_noc_data[active_ctx];
        rsp_word_cnt_next  = ctx_word_cnt[active_ctx];

        case (current_state)

            RECEIVE_HEADER: begin
                ns.dma_size_valid = 1'b0;
                ns.dma_size = target_dma_axi_size();
                // Stall coherence requests while any DMA context is active —
                // they share the same AXI master, so a fresh AR for a coherence
                // request would collide with the in-flight DMA AR_IDs.
                if (coherence_req_empty == 1'b0 && !any_ctx_valid) begin
                    coherence_req_rdreq = 1'b1;
                    ns.msg      = pad_coherence_req_data_out[this_coh_flit_size - `PREAMBLE_WIDTH - 4*GLOB_YX_WIDTH - 1 : this_coh_flit_size - `PREAMBLE_WIDTH - 4*GLOB_YX_WIDTH - `MSG_TYPE_WIDTH];
                    reserved    = pad_coherence_req_data_out[this_coh_flit_size - `PREAMBLE_WIDTH - 4*GLOB_YX_WIDTH - `MSG_TYPE_WIDTH - 1 : this_coh_flit_size - `PREAMBLE_WIDTH - 4*GLOB_YX_WIDTH - `MSG_TYPE_WIDTH - `RESERVED_WIDTH];
                    ns.ax_prot = reserved[2:0];
                    if (axitran == 0) ns.hsize_msb = 0;
                    else ns.hsize_msb = reserved[3];

                    sample_header = 1'b1;
                    next_state    = RECEIVE_ADDRESS;
                end else if (dma_rcv_empty == 1'b0 && ctx_alloc_avail) begin
                    // Gate DMA dequeue on a free context slot. Extra requests
                    // simply wait in dma_rcv until a slot frees.
                    dma_rcv_rdreq = 1'b1;
                    ns.msg      = pad_dma_rcv_data_out[DMA_NOC_FLIT_SIZE - `PREAMBLE_WIDTH - 4*GLOB_YX_WIDTH - 1:DMA_NOC_FLIT_SIZE - `PREAMBLE_WIDTH - 4*GLOB_YX_WIDTH - `MSG_TYPE_WIDTH];
                    reserved    = pad_dma_rcv_data_out[DMA_NOC_FLIT_SIZE - `PREAMBLE_WIDTH - 4*GLOB_YX_WIDTH - `MSG_TYPE_WIDTH - 1:DMA_NOC_FLIT_SIZE - `PREAMBLE_WIDTH - 4*GLOB_YX_WIDTH - `MSG_TYPE_WIDTH - `RESERVED_WIDTH];
                    ns.ax_prot = reserved[2:0];
                    // `axislv2noc` sets reserved[6:4] only when partial WSTRB is
                    // split into subword DMA packets. Carry that override into the
                    // write path so `AW_SIZE` and `W_STRB` match the original beat.
                    ns.dma_size_valid = reserved[DMA_HDR_SIZE_VALID_BIT];
                    if (reserved[DMA_HDR_SIZE_VALID_BIT] == 1'b1)
                        ns.dma_size = dma_code_to_axi_size(
                            reserved[DMA_HDR_SIZE_MSB:DMA_HDR_SIZE_LSB]
                        );
                    next_state = DMA_RECEIVE_ADDRESS;
                    sample_dma_header = 1'b1;
                end
                ns.burst_flag   = 0;
                ns.coh_dma_flag = 0;
                ns.sample_flag  = 2'b00;
                //coh_rd_data_flit  = 0;    
                ns.dma_noc_data = 0;
                ns.word_cnt     = 0;
            end

            RECEIVE_ADDRESS: begin
                if (coherence_req_empty == 1'b0) begin
                    coherence_req_rdreq = 1'b1;
                    if (cs.msg == REQ_GETS_W || cs.msg == REQ_GETS_HW || cs.msg == REQ_GETS_B || cs.msg == AHB_RD) begin
                        ns.ar_prot = cs.ax_prot;
                        ns.ar_addr = coherence_req_data_out[GLOB_PHYS_ADDR_BITS-1 : 0];
                        if (cs.msg == REQ_GETS_B) ns.ar_size = XSIZE_BYTE;
                        else if (cs.msg == REQ_GETS_HW) ns.ar_size = XSIZE_HWORD;
                        else if (ARCH_BITS == 64 && cs.hsize_msb == 1) ns.ar_size = XSIZE_DWORD;
                        else ns.ar_size = XSIZE_WORD;
                        if (axitran == 0) begin
                            ns.ar_len   = cacheline - 1;
                            ns.ar_valid = 1'b1;
                            next_state  = READ_REQUEST;
                        end else next_state = RECEIVE_LENGTH;
                    end

                    else if (cs.msg == REQ_GETM_W || cs.msg == REQ_GETM_HW || cs.msg == REQ_GETM_B || cs.msg == AHB_WR) begin
                        ns.aw_prot  = cs.ax_prot;
                        ns.aw_addr  = coherence_req_data_out[GLOB_PHYS_ADDR_BITS-1:0];
                        ns.aw_len   = 0;
                        ns.aw_valid = 1'b1;
                        next_state  = WRITE_REQUEST;
                        if (cs.msg == REQ_GETM_B) ns.aw_size = XSIZE_BYTE;
                        else if (cs.msg == REQ_GETM_HW) ns.aw_size = XSIZE_HWORD;
                        else if (ARCH_BITS == 64 && cs.hsize_msb == 1) ns.aw_size = XSIZE_DWORD;
                        else ns.aw_size = XSIZE_WORD;

                        if (ARCH_BITS == 32) begin
                            if (ns.aw_size == XSIZE_BYTE)
                                ns.w_strb = 4'b1000 >> ns.aw_addr[$clog2(AW)-1:0];
                            else if (ns.aw_size == XSIZE_HWORD)
                                ns.w_strb = 4'b1100 >> ns.aw_addr[$clog2(AW)-1:0];
                            else ns.w_strb = 4'b1111;
                        end else begin
                            if (cs.msg == AHB_WR) begin
                                if (ns.aw_addr[2] == 0) ns.w_strb = 8'b11110000;
                                else ns.w_strb = 8'b00001111;
                            end else begin
                                if (ns.aw_size == XSIZE_BYTE)
                                    ns.w_strb = 8'b10000000 >> ns.aw_addr[$clog2(AW)-1:0];
                                else if (ns.aw_size == XSIZE_HWORD)
                                    ns.w_strb = 8'b11000000 >> ns.aw_addr[$clog2(AW)-1:0];
                                else if (ns.aw_size == XSIZE_WORD)
                                    ns.w_strb = 8'b11110000 >> ns.aw_addr[$clog2(AW)-1:0];
                                else if (ns.aw_size == XSIZE_DWORD)
                                    ns.w_strb = 8'b11111111 >> ns.aw_addr[$clog2(AW)-1:0];
                            end
                        end
                    end else next_state = RECEIVE_HEADER;
                end
            end

            RECEIVE_LENGTH: begin
                if (coherence_req_empty == 1'b0) begin
                    coherence_req_rdreq = 1'b1;
                    ns.count            = coherence_req_data_out[11 : 0] - 1;
                    ns.ar_valid         = 1'b1;
                    if (ns.count > 255) begin
                        ns.ar_len = 255;
                        ns.count  = ns.count - 256;
                    end else begin
                        ns.ar_len = ns.count;
                        ns.count  = 0;
                    end
                    next_state = READ_REQUEST;
                end
            end

            READ_REQUEST: begin
                ns.ar_valid = 1'b1;
                if (AR_READY == 1'b1) begin
                    if (cs.burst_flag == 0) begin
                        if (coherence_rsp_snd_full == 1'b0) begin
                            coherence_rsp_snd_data_in = header_reg;
                            coherence_rsp_snd_wrreq   = 1'b1;
                            next_state                = SEND_DATA;
                        end else next_state = SEND_HEADER;
                    end else next_state = SEND_DATA;
                    ns.ar_valid = 1'b0;
                end
            end

            SEND_HEADER: begin
                if (coherence_rsp_snd_full == 1'b0) begin
                    coherence_rsp_snd_data_in = header_reg;
                    coherence_rsp_snd_wrreq   = 1'b1;
                    next_state                = SEND_DATA;
                end
            end

            SEND_DATA: begin
                if (coherence_rsp_snd_full == 1'b0) begin
                    if (R_VALID == 1'b1) begin
                        coherence_rsp_snd_wrreq = 1'b1;
                        //TODO: improve axi-rdata to NoC packing
                        for (
                            i = 0; i < (this_coh_flit_size - `PREAMBLE_WIDTH) / ARCH_BITS; i = i + 1
                        )
                        coh_rd_data_flit[ARCH_BITS*i+:ARCH_BITS] = fix_endian(R_DATA, little_end);

                        if (R_LAST == 1'b1) begin
                            if (cs.count == 0) begin
                                coherence_rsp_snd_data_in = {PREAMBLE_TAIL, coh_rd_data_flit};
                                next_state                = RECEIVE_HEADER;
                            end else begin  // If another burst is needed
                                coherence_rsp_snd_data_in = {PREAMBLE_BODY, coh_rd_data_flit};
                                if (cs.count > 255) begin
                                    ns.ar_len = 255;
                                    ns.count  = cs.count - 256;
                                end else begin
                                    ns.ar_len = cs.count;
                                    ns.count  = 0;
                                end
                                ns.ar_addr    = cs.ar_addr + ((cs.ar_len + 1) << cs.ar_size);
                                ns.burst_flag = 1;
                                next_state    = READ_REQUEST;
                            end
                        end else coherence_rsp_snd_data_in = {PREAMBLE_BODY, coh_rd_data_flit};
                    end
                end
            end

            WRITE_REQUEST: begin
                ns.aw_valid = 1'b1;
                if (AW_READY == 1'b1) begin
                    if (cs.msg == AHB_WR && ARCH_BITS == 64) next_state = WRITE_DATA_EDCL;
                    else next_state = WRITE_DATA;
                    ns.aw_valid = 1'b0;
                end
            end

            WRITE_DATA: begin
                if (coherence_req_empty == 1'b0) begin
                    ns.preamble_flag = preamble;
                    if (W_READY == 1'b1) begin
                        coherence_req_rdreq = 1'b1;
                        next_state          = WRITE_RESPONSE_WAIT;
                    end
                end
            end
            WRITE_RESPONSE_WAIT: begin
                if (B_VALID == 1'b1) begin
                    if (cs.preamble_flag == PREAMBLE_BODY) begin
                        ns.aw_addr  = get_next_axi_addr(cs.aw_addr, cs.aw_size);
                        next_state  = WRITE_REQUEST;
                        ns.aw_valid = 1'b1;
                    end else if (cs.preamble_flag == PREAMBLE_TAIL) begin
                        next_state = RECEIVE_HEADER;
                    end
                end
            end

            WRITE_DATA_EDCL: begin
                if (coherence_req_empty == 1'b0) begin
                    if (W_READY == 1'b1) begin
                        coherence_req_rdreq = 1'b1;
                        if (cs.aw_addr[2] == 1'b0) begin
                            ns.w_strb = 8'b11110000;
                        end else begin
                            ns.w_strb = 8'b00001111;
                        end
                        ns.aw_addr = cs.aw_addr + 4'b0100;
                        if (preamble == PREAMBLE_TAIL) next_state = RECEIVE_HEADER;
                        else begin
                            next_state  = WRITE_REQUEST;
                            ns.aw_valid = 1'b1;
                        end
                    end
                end
            end

            DMA_RECEIVE_ADDRESS: begin
                if (dma_rcv_empty == 1'b0) begin
                    dma_rcv_rdreq = 1'b1;
                    ns.ar_prot    = cs.ax_prot;
                    ns.ar_size    = target_dma_axi_size();
                    ns.aw_size    = target_dma_axi_size();

                    if (cs.msg == DMA_TO_DEV || cs.msg == REQ_DMA_READ) begin
                        next_state = DMA_RECEIVE_READ_LENGTH;
                        ns.ar_addr = dma_rcv_data_out[GLOB_PHYS_ADDR_BITS-1 : 0];
                    end else begin
                        ns.aw_len  = 0;
                        ns.aw_addr = dma_rcv_data_out[GLOB_PHYS_ADDR_BITS-1 : 0];
                        if (cs.msg == DMA_FROM_DEV) begin
                            ns.coh_dma_flag = 1'b0;
                            /* Note: in order to support ESP instances without DDR controller,
                               non coherent DMA is sending the transaction length to work with FPGA-based
                               memory proxy (mem2ext) for which the length of the payload must be known
                               when the transaction begins. The external link can only handle
                               non-coherent DMA and LLC requests (i.e. it assumes LLC is present),
                               therefore coherent DMA requests do not send the transaction
                               length to reduce the NoC packet overhead.*/
                            next_state      = DMA_RECEIVE_WRITE_LENGTH;
                        end else begin
                            ns.aw_valid     = 1'b1;
                            ns.coh_dma_flag = 1'b1;
                            next_state      = DMA_WRITE_REQUEST;
                        end

                        if (cs.dma_size_valid == 1'b1) begin
                            ns.aw_size = cs.dma_size;
                        end

                        // Preserve legacy coherent-DMA behavior unless an explicit
                        // size override is present. Non-coherent split DMA packets
                        // use the decoded size to rebuild the original AXI WSTRB.
                        ns.w_strb = '0;
                        if (cs.msg == REQ_DMA_WRITE && cs.dma_size_valid == 1'b0) begin
                            ns.w_strb = {AW{1'b1}};
                        end else begin
                            ns.w_strb = compute_axi_wstrb(ns.aw_size, ns.aw_addr);
                        end
                    end
                end
            end

            DMA_RECEIVE_READ_LENGTH: begin
                if (dma_rcv_empty == 1'b0) begin
                    dma_rcv_rdreq = 1'b1;
                    ns.count      = dma_rcv_data_out[31:0] - 1;
                    if (ns.count > 255) begin
                        ns.ar_len = 255;
                        ns.count  = ns.count - 256;
                    end else begin
                        ns.ar_len = ns.count;
                        ns.count  = 0;
                    end
                    ns.ar_valid = 1'b1;
                    next_state  = DMA_READ_REQUEST;
                end
            end

            DMA_READ_REQUEST: begin
                // Issue the initial AR via the dma_ar_* mux and allocate a
                // context slot to remember the request. The response FSM
                // owns header emission and R-data forwarding from here on,
                // so we return to RECEIVE_HEADER as soon as AR is accepted.
                //
                // If the response FSM is currently re-issuing a continuation
                // AR (DMA_RSP_CONT_AR), it has priority — we stall.
                if (!rsp_needs_ar) begin
                    dma_ar_valid = 1'b1;
                    dma_ar_addr  = cs.ar_addr;
                    dma_ar_len   = cs.ar_len;
                    dma_ar_size  = cs.ar_size;
                    dma_ar_prot  = cs.ar_prot;
                    dma_ar_id    = {1'b0, ctx_alloc_idx};
                    if (AR_READY == 1'b1) begin
                        ctx_alloc_en  = 1'b1;
                        rsp_fifo_push = 1'b1;
                        next_state    = RECEIVE_HEADER;
                    end
                end
            end

            // DMA_SEND_HEADER and DMA_SEND_DATA are now serviced by the
            // response FSM (added after the main case statement below).
            // They are unreachable from the main FSM after the
            // DMA_READ_REQUEST rewrite; the dead-fall recovery below just
            // returns to RECEIVE_HEADER if some path ever ends up here.
            DMA_SEND_HEADER: begin
                next_state = RECEIVE_HEADER;
            end

            DMA_SEND_DATA: begin
                next_state = RECEIVE_HEADER;
            end

            DMA_RECEIVE_WRITE_LENGTH: begin
                if (dma_rcv_empty == 1'b0) begin
                    dma_rcv_rdreq = 1'b1;
                    ns.count      = dma_rcv_data_out[31:0] - 1;
                    if (ns.count > 255) begin
                        ns.aw_len   = 255;
                        ns.word_rem = 255;
                        ns.count    = ns.count - 256;

                    end else begin
                        ns.aw_len   = ns.count;
                        ns.word_rem = ns.count;
                        ns.count    = 0;
                    end
                    next_state  = DMA_WRITE_REQUEST;
                    ns.aw_valid = 1'b1;
                end
            end

            DMA_WRITE_REQUEST: begin
                ns.aw_valid = 1'b1;
                if (AW_READY == 1'b1) begin
                    if (cs.msg == REQ_DMA_WRITE && eth_dma == 1) next_state = DMA_WRITE_DATA_ETH;
                    else begin
                        if (cs.coh_dma_flag) next_state = DMA_WRITE_DATA_COH;
                        else next_state = DMA_WRITE_DATA;
                    end

                    //Pipeline prefetch for DMA except ethernet
                    if (eth_dma != 1) begin
                        ns.sample_flag = 2'b00;
                        if (dma_rcv_empty == 1'b0) begin
                            dma_rcv_rdreq = 1'b1;
                            ns.dma_flit   = dma_rcv_data_out;
                            if (dma_preamble == PREAMBLE_BODY) ns.sample_flag = 2'b01;
                            else if (dma_preamble == PREAMBLE_TAIL) ns.sample_flag = 2'b10;
                        end
                    end
                    ns.aw_valid = 1'b0;
                end
            end

            DMA_WRITE_DATA: begin
                // 1. If we have PREFETCHED data (or are busy unpacking a wide flit)
                if (cs.sample_flag != 2'b00) begin
                    if (W_READY == 1'b1) begin
                        ns.word_cnt    = cs.word_cnt + 1;
                        ns.sample_flag = 2'b00;

                        if (cs.word_rem == 0) begin
                            // BURST IS DONE
                            ns.word_cnt = 0;
                            if (cs.count == 0 || cs.sample_flag == 2'b10) begin
                                next_state = RECEIVE_HEADER;
                            end else begin
                                ns.aw_valid = 1'b1;
                                next_state  = DMA_WRITE_REQUEST;
                                // Start next burst logic
                                if (cs.count > 255) begin
                                    ns.aw_len   = 255;
                                    ns.word_rem = 255;
                                    ns.count    = cs.count - 256;
                                end else begin
                                    ns.aw_len   = cs.count;
                                    ns.word_rem = cs.count;
                                    ns.count    = 0;
                                end
                                ns.aw_addr = cs.aw_addr + ((cs.aw_len + 1) << cs.aw_size);
                            end
                        end else begin
                            ns.word_rem = cs.word_rem - 1;
                            // BURST CONTINUES
                            if ((ns.word_cnt == DMA_NOC_WIDTH / ARCH_BITS) || (eth_dma == 1)) begin
                                // Flit exhausted, need to fetch the next one from NoC
                                ns.word_cnt = 0;
                                if (dma_rcv_empty == 1'b0) begin
                                    dma_rcv_rdreq = 1'b1;
                                    ns.dma_flit   = dma_rcv_data_out;
                                    if (dma_rcv_data_out[DMA_NOC_FLIT_SIZE-1:DMA_NOC_FLIT_SIZE-2] == 2'b10)
                                        ns.sample_flag = 2'b10;
                                    else ns.sample_flag = 2'b01;
                                    ns.word_rem = cs.word_rem - 1;
                                end
                            end else begin
                                // Flit still has more words to unpack
                                ns.sample_flag = 2'b11;
                            end
                        end
                    end
                end  // 2. If we do NOT have prefetched data, but the NoC queue has data NOW
                else if (cs.sample_flag == 2'b00 && dma_rcv_empty == 1'b0) begin
                    dma_rcv_rdreq = 1'b1;
                    ns.dma_flit   = dma_rcv_data_out;

                    if (dma_rcv_data_out[DMA_NOC_FLIT_SIZE-1:DMA_NOC_FLIT_SIZE-2] == 2'b10)
                        ns.sample_flag = 2'b10;
                    else ns.sample_flag = 2'b01;

                    if (W_READY == 1'b1) begin
                        ns.word_cnt    = cs.word_cnt + 1;
                        ns.sample_flag = 2'b00;

                        if (cs.word_rem == 0) begin
                            // BURST IS DONE
                            ns.word_cnt = 0;
                            if (cs.count == 0) begin
                                next_state = RECEIVE_HEADER;
                            end else begin
                                ns.aw_valid = 1'b1;
                                next_state  = DMA_WRITE_REQUEST;
                                // Start next burst logic
                                if (cs.count > 255) begin
                                    ns.aw_len   = 255;
                                    ns.word_rem = 255;
                                    ns.count    = cs.count - 256;
                                end else begin
                                    ns.aw_len   = cs.count;
                                    ns.word_rem = cs.count;
                                    ns.count    = 0;
                                end
                                ns.aw_addr = cs.aw_addr + ((cs.aw_len + 1) << cs.aw_size);
                            end
                        end else begin
                            // BURST CONTINUES
                            if ((ns.word_cnt == DMA_NOC_WIDTH / ARCH_BITS) || (eth_dma == 1)) begin
                                ns.word_cnt = 0;
                                //We don't prefetch here because we already used our 1 read
                            end else begin
                                ns.sample_flag = 2'b11;
                            end
                            ns.word_rem = cs.word_rem - 1;
                        end
                    end
                end
            end

            DMA_WRITE_DATA_COH: begin
                if (cs.sample_flag != 2'b0) begin
                    if (W_READY == 1'b1) begin
                        ns.sample_flag = 2'b00;
                        if (cs.sample_flag == 2'b10) next_state = RECEIVE_HEADER;
                        else begin
                            ns.aw_valid = 1'b1;
                            next_state  = DMA_WRITE_REQUEST;
                            ns.aw_addr  = cs.aw_addr + ((cs.aw_len + 1) << cs.aw_size);
                        end
                    end

                end else if (cs.sample_flag == 2'b00 && dma_rcv_empty == 1'b0) begin
                    dma_rcv_rdreq = 1'b1;
                    ns.dma_flit   = dma_rcv_data_out;

                    if (dma_preamble == PREAMBLE_TAIL) begin
                        ns.sample_flag = 2'b10;
                    end else ns.sample_flag = 2'b01;

                    if (W_READY == 1'b1) begin
                        ns.sample_flag = 2'b00;

                        if (dma_preamble == PREAMBLE_TAIL) next_state = RECEIVE_HEADER;
                        else begin
                            ns.aw_valid = 1'b1;
                            next_state  = DMA_WRITE_REQUEST;
                            ns.aw_addr  = cs.aw_addr + ((cs.aw_len + 1) << cs.aw_size);
                        end
                    end
                end
            end

            DMA_WRITE_DATA_ETH: begin
                if (dma_rcv_empty == 1'b0) begin
                    if (W_READY == 1'b1) begin
                        dma_rcv_rdreq = 1'b1;
                        ns.aw_addr    = cs.aw_addr + 4'b0100;
                        if (dma_preamble == PREAMBLE_TAIL) begin
                            next_state = RECEIVE_HEADER;
                        end else begin
                            ns.aw_valid = 1'b1;
                            next_state  = DMA_WRITE_REQUEST;
                            ns.aw_valid = 1'b1;
                        end
                    end
                end
            end
        endcase

        // -----------------------------------------------------------------
        // Response FSM — drains DMA read responses from the AXI master back
        // to the dma_snd NoC queue, decoupled from the main FSM so the main
        // FSM is free to dequeue and issue the next request.
        //
        // Last-assignment-wins overrides dma_snd_data_in/dma_snd_wrreq from
        // the main case when this FSM is active. Per-context AXI R demux
        // gates on R_ID == {1'b0, active_ctx} (see also r_ready_comb).
        // -----------------------------------------------------------------
        case (dma_rsp_state)
            DMA_RSP_IDLE: begin
                if (!rsp_fifo_empty) begin
                    dma_rsp_next = DMA_RSP_HEADER;
                end
            end

            DMA_RSP_HEADER: begin
                if (dma_snd_full == 1'b0) begin
                    dma_snd_data_in = ctx_rsp_header[active_ctx];
                    dma_snd_wrreq   = 1'b1;
                    dma_rsp_next    = DMA_RSP_DATA;
                end
            end

            DMA_RSP_DATA: begin
                // Forward AXI R-channel data to dma_snd as packed NoC flits.
                // Only consume R beats tagged with the active context's ID.
                if (dma_snd_full == 1'b0 && R_VALID == 1'b1 &&
                    R_ID == {1'b0, active_ctx}) begin

                    rsp_data_handshake = 1'b1;

                    rsp_noc_data_next = ctx_noc_data[active_ctx];
                    rsp_noc_data_next[ARCH_BITS*ctx_word_cnt[active_ctx]+:ARCH_BITS] =
                        fix_endian(R_DATA, little_end);
                    rsp_word_cnt_next = ctx_word_cnt[active_ctx] + 1;

                    if (R_LAST == 1'b0) begin
                        if ((rsp_word_cnt_next == DMA_NOC_WIDTH / ARCH_BITS) ||
                            (eth_dma == 1)) begin
                            rsp_word_cnt_next = 0;
                            dma_snd_wrreq     = 1'b1;
                            dma_snd_data_in   = {PREAMBLE_BODY, rsp_noc_data_next};
                        end
                    end else begin
                        rsp_word_cnt_next = 0;
                        dma_snd_wrreq     = 1'b1;
                        if (ctx_count[active_ctx] == 0) begin
                            // Final burst — send tail and free the context.
                            dma_snd_data_in = {PREAMBLE_TAIL, rsp_noc_data_next};
                            ctx_free_en     = 1'b1;
                            rsp_fifo_pop    = 1'b1;
                            dma_rsp_next    = DMA_RSP_IDLE;
                        end else begin
                            // More bursts needed for this context — emit body
                            // and re-issue AR (continuation).
                            dma_snd_data_in = {PREAMBLE_BODY, rsp_noc_data_next};
                            rsp_cont_en     = 1'b1;
                            dma_rsp_next    = DMA_RSP_CONT_AR;
                        end
                    end
                end
            end

            DMA_RSP_CONT_AR: begin
                // Re-issue AXI AR for the next segment of a multi-segment
                // context (transfers whose total length is > 256 beats).
                dma_ar_valid = 1'b1;
                dma_ar_addr  = ctx_ar_addr[active_ctx];
                dma_ar_len   = ctx_ar_len[active_ctx];
                dma_ar_size  = ctx_ar_size[active_ctx];
                dma_ar_prot  = ctx_ar_prot[active_ctx];
                dma_ar_id    = {1'b0, active_ctx};
                if (AR_READY == 1'b1) begin
                    dma_rsp_next = DMA_RSP_DATA;
                end
            end

            default: dma_rsp_next = DMA_RSP_IDLE;
        endcase
    end

    // -------------------------------------------------------------------------
    // COMBINATIONAL W-CHANNEL PATH (Flow-Through)
    // -------------------------------------------------------------------------
    logic                     w_valid_comb;
    logic [        AXIDW-1:0] w_data_comb;
    logic                     w_last_comb;
    logic [           AW-1:0] w_strb_comb;
    logic                     r_ready_comb;

    logic [        AXIDW-1:0] dma_live_flit_swapped;
    logic [        AXIDW-1:0] dma_pref_flit_swapped;

    logic [DMA_NOC_WIDTH-1:0] dma_payload_live;
    logic [DMA_NOC_WIDTH-1:0] dma_payload_pref;

    always_comb begin
        w_valid_comb          = 1'b0;
        w_data_comb           = '0;
        w_last_comb           = 1'b0;
        w_strb_comb           = cs.w_strb;
        r_ready_comb          = 1'b0;

        dma_live_flit_swapped = '0;
        dma_pref_flit_swapped = '0;

        dma_payload_live      = dma_rcv_data_out[DMA_NOC_WIDTH-1 : 0];
        dma_payload_pref      = cs.dma_flit[DMA_NOC_WIDTH-1 : 0];

        if (little_end == 0) begin
            dma_live_flit_swapped = dma_payload_live[ARCH_BITS*cs.word_cnt+:ARCH_BITS];
            dma_pref_flit_swapped = dma_payload_pref[ARCH_BITS*cs.word_cnt+:ARCH_BITS];
        end else begin
            for (j = 0; j < (ARCH_BITS / 8); j = j + 1) begin
                dma_live_flit_swapped[8*j +: 8] = dma_payload_live[ARCH_BITS * (cs.word_cnt + 1) - 8*(j+1) +: 8];
                dma_pref_flit_swapped[8*j +: 8] = dma_payload_pref[ARCH_BITS * (cs.word_cnt + 1) - 8*(j+1) +: 8];
            end
        end

        case (current_state)
            SEND_DATA: begin
                if (coherence_rsp_snd_full == 1'b0) r_ready_comb = 1'b1;
            end
            DMA_SEND_DATA: begin
                // Dead branch: DMA_SEND_DATA is unreachable from the main FSM.
                // R_READY for DMA reads is driven by the response FSM block
                // below (overrides r_ready_comb).
            end
            WRITE_DATA: begin
                if (coherence_req_empty == 1'b0) begin
                    w_valid_comb = 1'b1;
                    w_data_comb  = fix_endian(coherence_req_data_out[ARCH_BITS-1:0], little_end);
                    w_last_comb  = 1'b1;
                end
            end
            WRITE_DATA_EDCL: begin
                if (coherence_req_empty == 1'b0) begin
                    w_valid_comb = 1'b1;
                    w_last_comb  = 1'b1;
                    if (cs.aw_addr[2] == 1'b0) begin
                        w_data_comb = {coherence_req_data_out[31:0], 32'b0};
                        w_strb_comb = 8'b11110000;
                    end else begin
                        w_data_comb = {32'b0, coherence_req_data_out[31:0]};
                        w_strb_comb = 8'b00001111;
                    end
                end
            end
            DMA_WRITE_DATA, DMA_WRITE_DATA_COH: begin
                if (cs.sample_flag == 2'b01 || cs.sample_flag == 2'b10 || cs.sample_flag == 2'b11) begin
                    w_valid_comb = 1'b1;
                    w_data_comb  = dma_pref_flit_swapped;
                    w_last_comb  = (cs.word_rem == 0);
                end else if (cs.sample_flag == 2'b00 && dma_rcv_empty == 1'b0) begin
                    w_valid_comb = 1'b1;
                    w_data_comb  = dma_live_flit_swapped;
                    w_last_comb  = (cs.word_rem == 0);
                end
            end

            DMA_WRITE_DATA_ETH: begin
                if (dma_rcv_empty == 1'b0) begin
                    w_valid_comb = 1'b1;
                    w_last_comb  = 1'b1;

                    if (ARCH_BITS == 64) begin
                        if (cs.aw_addr[2] == 1'b0) begin
                            w_data_comb = {dma_rcv_data_out[31:0], 32'b0};
                            w_strb_comb = 8'b11110000;
                        end else begin
                            w_data_comb = {32'b0, dma_rcv_data_out[31:0]};
                            w_strb_comb = 8'b00001111;
                        end
                    end else begin
                        // 32-bit architecture fallback
                        w_data_comb = dma_rcv_data_out[AXIDW-1:0];
                        w_strb_comb = {AW{1'b1}};
                    end
                end
            end
            default: ;
        endcase

        // Response FSM R_READY override: accept AXI R beats only for the
        // currently active context (R_ID demux). This is what makes
        // MAX_DMA_OT outstanding reads safe — the memory controller may
        // interleave R beats across IDs, but we only consume the active one.
        if (dma_rsp_state == DMA_RSP_DATA && dma_snd_full == 1'b0 &&
            R_ID == {1'b0, active_ctx}) begin
            r_ready_comb = 1'b1;
        end
    end

    // AR channel mux: DMA reads use dma_ar_* (driven by main FSM during the
    // initial request and by the response FSM during continuation bursts);
    // coherence reads keep the legacy cs.ar_* path. AR_ID is the per-context
    // index for DMA, or mst_index for coherence.
    assign AR_VALID = dma_ar_valid | cs.ar_valid;
    assign AR_ADDR  = dma_ar_valid ? dma_ar_addr : cs.ar_addr;
    assign AR_LEN   = dma_ar_valid ? dma_ar_len  : cs.ar_len;
    assign AR_SIZE  = dma_ar_valid ? dma_ar_size : cs.ar_size;
    assign AR_PROT  = dma_ar_valid ? dma_ar_prot : cs.ar_prot;
    assign AR_ID    = dma_ar_valid ? dma_ar_id   : mst_index;
    assign AW_VALID = cs.aw_valid;
    assign AW_ADDR  = cs.aw_addr;
    assign AW_LEN   = cs.aw_len;
    assign AW_SIZE  = cs.aw_size;
    assign AW_PROT  = cs.aw_prot;
    assign W_LAST   = w_last_comb;
    assign W_VALID  = w_valid_comb;
    assign R_READY  = r_ready_comb;
    assign W_DATA   = w_data_comb;
    assign W_STRB   = w_strb_comb;
    assign B_READY  = 1'b1;

    always_ff @(posedge ACLK, negedge ARESETn) begin
        if (ARESETn == 1'b0) begin
            current_state    <= RECEIVE_HEADER;
            cs.msg           <= REQ_GETS_W;
            cs.dma_flit      <= 0;
            cs.ax_prot       <= 0;
            cs.word_cnt      <= 0;
            cs.preamble_flag <= PREAMBLE_BODY;
            cs.aw_addr       <= 0;
            cs.ar_addr       <= 0;
            cs.ar_len        <= 0;
            cs.ar_size       <= 3'b010;
            cs.ar_prot       <= 0;
            cs.ar_valid      <= 1'b0;
            cs.aw_len        <= 0;
            cs.aw_size       <= 3'b010;
            cs.aw_prot       <= 0;
            cs.w_strb        <= 0;
            cs.aw_valid      <= 0;
            cs.count         <= 0;
            cs.sample_flag   <= 0;
            cs.burst_flag    <= 0;
            cs.coh_dma_flag  <= 0;
            cs.dma_noc_data  <= 0;
            cs.word_rem      <= 0;
            cs.hsize_msb     <= 0;
            cs.dma_size_valid <= 1'b0;
            cs.dma_size      <= target_dma_axi_size();
        end else begin
            current_state <= next_state;
            cs            <= ns;
        end
    end

    // -------------------------------------------------------------------------
    // Multi-outstanding context table + response FSM sequential block
    // -------------------------------------------------------------------------
    // ctx_alloc_en captures the request on the cycle AR is accepted (so the
    // context owns the as-issued ar_len/count split). ctx_free_en frees the
    // slot on response-tail. rsp_fifo serializes drain order per memory tile.
    always_ff @(posedge ACLK, negedge ARESETn) begin
        if (ARESETn == 1'b0) begin
            dma_rsp_state <= DMA_RSP_IDLE;
            rsp_fifo_rd   <= 1'b0;
            rsp_fifo_wr   <= 1'b0;
            rsp_fifo_cnt  <= 2'd0;
            rsp_fifo[0]   <= 1'b0;
            rsp_fifo[1]   <= 1'b0;
            for (int k = 0; k < MAX_DMA_OT; k = k + 1) begin
                ctx_valid[k]      <= 1'b0;
                ctx_rsp_header[k] <= '0;
                ctx_ar_addr[k]    <= '0;
                ctx_ar_len[k]     <= '0;
                ctx_ar_size[k]    <= '0;
                ctx_ar_prot[k]    <= '0;
                ctx_count[k]      <= '0;
                ctx_word_cnt[k]   <= '0;
                ctx_noc_data[k]   <= '0;
            end
        end else begin
            dma_rsp_state <= dma_rsp_next;

            // Allocate a context on AR handshake. Snapshot the as-issued
            // ar_addr/len/size/prot from `cs` (= the live request) and the
            // remaining count from `ns.count` (already split off the first
            // 256-beat segment in DMA_RECEIVE_READ_LENGTH).
            if (ctx_alloc_en) begin
                ctx_valid[ctx_alloc_idx]      <= 1'b1;
                ctx_rsp_header[ctx_alloc_idx] <= dma_header_reg;
                ctx_ar_addr[ctx_alloc_idx]    <= cs.ar_addr;
                ctx_ar_len[ctx_alloc_idx]     <= cs.ar_len;
                ctx_ar_size[ctx_alloc_idx]    <= cs.ar_size;
                ctx_ar_prot[ctx_alloc_idx]    <= cs.ar_prot;
                ctx_count[ctx_alloc_idx]      <= ns.count;
                ctx_word_cnt[ctx_alloc_idx]   <= '0;
                ctx_noc_data[ctx_alloc_idx]   <= '0;
            end

            // Free on response-tail.
            if (ctx_free_en) begin
                ctx_valid[active_ctx] <= 1'b0;
            end

            // Response R handshake updates packed-flit accumulator.
            if (rsp_data_handshake) begin
                ctx_word_cnt[active_ctx] <= rsp_word_cnt_next;
                ctx_noc_data[active_ctx] <= rsp_noc_data_next;
            end

            // Continuation: advance addr by the just-completed burst and
            // split off the next 256-beat segment.
            if (rsp_cont_en) begin
                ctx_ar_addr[active_ctx] <=
                    ctx_ar_addr[active_ctx] +
                    ((ctx_ar_len[active_ctx] + 1) << ctx_ar_size[active_ctx]);
                if (ctx_count[active_ctx] > 255) begin
                    ctx_ar_len[active_ctx]  <= 255;
                    ctx_count[active_ctx]   <= ctx_count[active_ctx] - 256;
                end else begin
                    ctx_ar_len[active_ctx]  <= ctx_count[active_ctx][7:0];
                    ctx_count[active_ctx]   <= 0;
                end
            end

            // Response FIFO push/pop. Both can fire in the same cycle when a
            // freeing context is immediately replaced by a new allocation.
            if (rsp_fifo_push && !rsp_fifo_pop) begin
                rsp_fifo[rsp_fifo_wr] <= ctx_alloc_idx;
                rsp_fifo_wr           <= ~rsp_fifo_wr;
                rsp_fifo_cnt          <= rsp_fifo_cnt + 1;
            end else if (!rsp_fifo_push && rsp_fifo_pop) begin
                rsp_fifo_rd  <= ~rsp_fifo_rd;
                rsp_fifo_cnt <= rsp_fifo_cnt - 1;
            end else if (rsp_fifo_push && rsp_fifo_pop) begin
                rsp_fifo[rsp_fifo_wr] <= ctx_alloc_idx;
                rsp_fifo_wr           <= ~rsp_fifo_wr;
                rsp_fifo_rd           <= ~rsp_fifo_rd;
                // cnt unchanged
            end
        end
    end


    // Create Response Header (COH)
    logic [    `MSG_TYPE_WIDTH-1 : 0] input_msg_type;
    logic [    `MSG_TYPE_WIDTH-1 : 0] msg_type;
    logic [ this_coh_flit_size-1 : 0] header_v;
    logic [                    2 : 0] origin_y;
    logic [                    2 : 0] origin_x;
    logic [`NEXT_ROUTING_WIDTH-1 : 0] go_right;
    logic [`NEXT_ROUTING_WIDTH-1 : 0] go_left;


    always_comb begin
        input_msg_type = pad_coherence_req_data_out[this_coh_flit_size - `PREAMBLE_WIDTH - 4*GLOB_YX_WIDTH - 1:this_coh_flit_size - `PREAMBLE_WIDTH - 4*GLOB_YX_WIDTH - `MSG_TYPE_WIDTH];

        if (input_msg_type == AHB_RD) msg_type = RSP_AHB_RD;
        else msg_type = RSP_DATA;

        origin_y = pad_coherence_req_data_out[  this_coh_flit_size - `PREAMBLE_WIDTH - GLOB_YX_WIDTH + 2 :   this_coh_flit_size - `PREAMBLE_WIDTH - GLOB_YX_WIDTH];
        origin_x = pad_coherence_req_data_out[this_coh_flit_size - `PREAMBLE_WIDTH - 2*GLOB_YX_WIDTH + 2 : this_coh_flit_size - `PREAMBLE_WIDTH - 2*GLOB_YX_WIDTH];
        header_v = 0;
        header_v[this_coh_flit_size-1 : this_coh_flit_size-`PREAMBLE_WIDTH] = PREAMBLE_HEADER;
        header_v[this_coh_flit_size - `PREAMBLE_WIDTH - 1 : this_coh_flit_size - `PREAMBLE_WIDTH - GLOB_YX_WIDTH] = local_y;
        header_v[this_coh_flit_size - `PREAMBLE_WIDTH - GLOB_YX_WIDTH - 1 : this_coh_flit_size - `PREAMBLE_WIDTH - 2*GLOB_YX_WIDTH] = local_x;
        header_v[this_coh_flit_size - `PREAMBLE_WIDTH - 2*GLOB_YX_WIDTH - 1 : this_coh_flit_size - `PREAMBLE_WIDTH - 3*GLOB_YX_WIDTH] = origin_y;
        header_v[this_coh_flit_size - `PREAMBLE_WIDTH - 3*GLOB_YX_WIDTH - 1 : this_coh_flit_size - `PREAMBLE_WIDTH - 4*GLOB_YX_WIDTH] = origin_x;
        header_v[this_coh_flit_size - `PREAMBLE_WIDTH - 4*GLOB_YX_WIDTH - 1 : this_coh_flit_size - `PREAMBLE_WIDTH -  4*GLOB_YX_WIDTH - `MSG_TYPE_WIDTH] = msg_type;

        if (local_x < origin_x) go_right = 5'b01000;
        else go_right = 5'b10111;

        if (local_x > origin_x) go_left = 5'b00100;
        else go_left = 5'b11011;

        if (local_y < origin_y)
            header_v[`NEXT_ROUTING_WIDTH-1 : 0] = (5'b01110) & go_left & go_right;
        else header_v[`NEXT_ROUTING_WIDTH-1 : 0] = (5'b01101) & go_left & go_right;

        if (local_y == origin_y && local_x == origin_x)
            header_v[`NEXT_ROUTING_WIDTH-1 : 0] = 5'b10000;

        header = header_v;

    end

    // Create Response Header (DMA)
    logic [    `MSG_TYPE_WIDTH-1 : 0] input_msg_type_dma;
    logic [    `MSG_TYPE_WIDTH-1 : 0] msg_type_dma;
    logic [  DMA_NOC_FLIT_SIZE-1 : 0] header_v_dma;
    logic [                    2 : 0] origin_y_dma;
    logic [                    2 : 0] origin_x_dma;
    logic [`NEXT_ROUTING_WIDTH-1 : 0] go_right_dma;
    logic [`NEXT_ROUTING_WIDTH-1 : 0] go_left_dma;


    always_comb begin

        input_msg_type_dma = pad_dma_rcv_data_out[DMA_NOC_FLIT_SIZE - `PREAMBLE_WIDTH - 4*GLOB_YX_WIDTH - 1:DMA_NOC_FLIT_SIZE - `PREAMBLE_WIDTH - 4*GLOB_YX_WIDTH - `MSG_TYPE_WIDTH];

        if (input_msg_type_dma == REQ_DMA_READ) msg_type_dma = RSP_DATA_DMA;
        else msg_type_dma = DMA_TO_DEV;

        //reserved_resp_dma = 0;
        origin_y_dma = pad_dma_rcv_data_out[DMA_NOC_FLIT_SIZE - `PREAMBLE_WIDTH - GLOB_YX_WIDTH + 2:DMA_NOC_FLIT_SIZE - `PREAMBLE_WIDTH - GLOB_YX_WIDTH];
        origin_x_dma = pad_dma_rcv_data_out[DMA_NOC_FLIT_SIZE - `PREAMBLE_WIDTH - 2*GLOB_YX_WIDTH + 2:DMA_NOC_FLIT_SIZE - `PREAMBLE_WIDTH - 2*GLOB_YX_WIDTH];
        header_v_dma = 0;
        header_v_dma[DMA_NOC_FLIT_SIZE-1 : DMA_NOC_FLIT_SIZE-`PREAMBLE_WIDTH] = PREAMBLE_HEADER;
        header_v_dma[DMA_NOC_FLIT_SIZE - `PREAMBLE_WIDTH - 1 : DMA_NOC_FLIT_SIZE - `PREAMBLE_WIDTH - GLOB_YX_WIDTH] = local_y;
        header_v_dma[DMA_NOC_FLIT_SIZE - `PREAMBLE_WIDTH - GLOB_YX_WIDTH - 1 : DMA_NOC_FLIT_SIZE - `PREAMBLE_WIDTH - 2*GLOB_YX_WIDTH] = local_x;
        header_v_dma[DMA_NOC_FLIT_SIZE - `PREAMBLE_WIDTH - 2*GLOB_YX_WIDTH - 1 : DMA_NOC_FLIT_SIZE - `PREAMBLE_WIDTH - 3*GLOB_YX_WIDTH] = origin_y_dma;
        header_v_dma[DMA_NOC_FLIT_SIZE - `PREAMBLE_WIDTH - 3*GLOB_YX_WIDTH - 1 : DMA_NOC_FLIT_SIZE - `PREAMBLE_WIDTH - 4*GLOB_YX_WIDTH] = origin_x_dma;
        header_v_dma[DMA_NOC_FLIT_SIZE - `PREAMBLE_WIDTH - 4*GLOB_YX_WIDTH - 1 : DMA_NOC_FLIT_SIZE - `PREAMBLE_WIDTH -  4*GLOB_YX_WIDTH - `MSG_TYPE_WIDTH] = msg_type_dma;
        //header_v_dma[`NOC_FLIT_SIZE - `PREAMBLE_WIDTH - `MSG_TYPE_WIDTH - `RESERVED_WIDTH : `NOC_FLIT_SIZE - `PREAMBLE_WIDTH - 12 - `MSG_TYPE_WIDTH] = reserved_resp_dma;

        // Echo the DMA transaction ID from the request header into the
        // response header so the accelerator-side response FSM can match
        // returning packets to its outstanding-table slot (see
        // DMA_TRAN_ID_* in noc2aximst-pkg.sv and rtl/noc/nocpackage.vhd).
        header_v_dma[DMA_TRAN_ID_MSB:DMA_TRAN_ID_LSB] =
            pad_dma_rcv_data_out[DMA_TRAN_ID_MSB:DMA_TRAN_ID_LSB];

        if (local_x < origin_x_dma) go_right_dma = 5'b01000;
        else go_right_dma = 5'b10111;

        if (local_x > origin_x_dma) go_left_dma = 5'b00100;
        else go_left_dma = 5'b11011;

        if (local_y < origin_y_dma)
            header_v_dma[`NEXT_ROUTING_WIDTH-1 : 0] = (5'b01110) & go_left_dma & go_right_dma;
        else header_v_dma[`NEXT_ROUTING_WIDTH-1 : 0] = (5'b01101) & go_left_dma & go_right_dma;

        if (local_y == origin_y_dma && local_x == origin_x_dma)
            header_v_dma[`NEXT_ROUTING_WIDTH-1 : 0] = 5'b10000;

        dma_header = header_v_dma;

    end

    // Register Response Header
    always_ff @(posedge ACLK, negedge ARESETn) begin
        if (ARESETn == 1'b0) begin
            header_reg     <= 0;
            dma_header_reg <= 0;
        end else begin
            if (sample_header == 1'b1) header_reg <= header;
            if (sample_dma_header == 1'b1) dma_header_reg <= dma_header;
        end
    end


    function automatic logic [ARCH_BITS-1:0] fix_endian(input logic [ARCH_BITS-1:0] data_in_word,
                                                        input int endian);
        logic [ARCH_BITS-1:0] data_out_word;
        integer j;

        if (endian == 0) begin  //big-endian
            data_out_word = data_in_word;
        end else begin
            data_out_word = '0;
            for (j = 0; j < (ARCH_BITS / 8); j = j + 1) begin
                data_out_word[8*j+:8] = data_in_word[ARCH_BITS-8*(j+1)+:8];
            end
        end
        return data_out_word;
    endfunction

    function automatic logic [GLOB_PHYS_ADDR_BITS-1:0] get_next_axi_addr(
        input logic [GLOB_PHYS_ADDR_BITS-1:0] current_addr, input logic [2:0] axi_size);
        logic [GLOB_PHYS_ADDR_BITS-1:0] next_addr;

        case (axi_size)
            XSIZE_BYTE:  next_addr = current_addr + 1;  // +1 byte 
            XSIZE_HWORD: next_addr = current_addr + 2;  // +2 bytes
            XSIZE_WORD:  next_addr = current_addr + 4;  // +4 bytes
            XSIZE_DWORD: next_addr = current_addr + 8;  // +8 bytes
            default:     next_addr = current_addr;  // Should not happen for valid sizes
        endcase

        return next_addr;
    endfunction


endmodule
