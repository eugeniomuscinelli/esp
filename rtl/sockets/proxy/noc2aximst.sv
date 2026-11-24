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
    parameter integer this_coh_flit_size = 34,
    parameter integer dma_multi_ot       = 0 //Enable multiple outstanding DMA reads
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
    input  logic [           MEM_AXIDW-1 : 0] R_DATA,
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
    output logic [           MEM_AXIDW-1 : 0] W_DATA,
    output logic [              MEM_AW-1 : 0] W_STRB,
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

    // Currently multiple outstanding tx are supported only for DMA reads
    //AR_ID is dynamically muxed DMA reads use a per-context index
    // coherence reads keep using mst_index. 
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
    localparam int DMA_HDR_SIZE_LSB       = 4;
    localparam int DMA_HDR_SIZE_MSB       = 5;
    localparam int DMA_HDR_SIZE_VALID_BIT = 6;


    logic [DMA_NOC_FLIT_SIZE-1 : 0] dma_header;
    logic [DMA_NOC_FLIT_SIZE-1 : 0] dma_header_reg;
    logic sample_dma_header;

    logic [`RESERVED_WIDTH-1 : 0] reserved;
    logic [`PREAMBLE_WIDTH-1 : 0] preamble;
    logic [`PREAMBLE_WIDTH-1 : 0] dma_preamble;
    // Head-of-queue message type, decoded without popping, so admission
    // can tell reads from writes before deciding whether to dequeue.
    logic [`MSG_TYPE_WIDTH-1 : 0] coh_head_msg;
    logic [`MSG_TYPE_WIDTH-1 : 0] dma_head_msg;
    logic                         coh_head_is_read;
    logic                         dma_head_is_read;

    logic [this_coh_flit_size-`PREAMBLE_WIDTH-1 : 0] coh_rd_data_flit;
    integer i, j;

    // -------------------------------------------------------------------------
    // Memory bus wider than the CPU word (MEM_AXIDW > ARCH_BITS)
    // -------------------------------------------------------------------------
    // The AXI data ports are MEM_AXIDW bits wide: LANES words of ARCH_BITS.
    // A transfer of ARCH_BITS or less is then a narrow AXI transfer. The word
    // at an address occupies the lane given by the address bits just above
    // the word offset (bit 3 for 64-bit words on a 128-bit bus), which is the
    // lane AXI assigns to it; inside a lane the bytes are laid out exactly as
    // on an ARCH_BITS bus. So the memory holds the same bytes at the same
    // addresses whatever the bus width.
    //   reads:  take the word from the lane of the beat's address;
    //   writes: drive the word on every lane, strobe only the address's lane.
    // The byte offset inside the bus word is tracked per burst, because the
    // lane changes from beat to beat. With MEM_AXIDW = ARCH_BITS there is one
    // lane and all of this folds to the previous behaviour.
    localparam int LANES    = MEM_AXIDW / ARCH_BITS;
    localparam int LANE_W   = (LANES > 1) ? $clog2(LANES) : 1;
    localparam int WORD_LSB = $clog2(ARCH_BITS / 8);   // first address bit above the word offset
    localparam int OFF_W    = WORD_LSB + LANE_W;       // byte offset inside a bus word (and one spare bit when LANES = 1)

    // Byte offset of a transfer of 2**size bytes at address a, aligned to the
    // transfer size as AXI aligns every beat after the first.
    function automatic logic [OFF_W-1:0] bus_offset(input logic [GLOB_PHYS_ADDR_BITS-1:0] a,
                                                    input logic [2:0] size);
        logic [OFF_W-1:0] off;
        off = a[OFF_W-1:0];
        return (off >> size) << size;
    endfunction

    // -------------------------------------------------------------------------
    // Full-width DMA beats
    // -------------------------------------------------------------------------
    // When a DMA flit is exactly one bus word (DMA_NOC_WIDTH = MEM_AXIDW), a
    // non-coherent DMA request can move one flit per AXI beat instead of one
    // ARCH_BITS word: AxSIZE = BUS_SIZE, no packing or unpacking. A request
    // takes this path when its address is aligned to the bus word and its
    // length is a whole number of bus words (what an accelerator with a
    // DMA_NOC_WIDTH-wide DMA port issues); any other request keeps ARCH_BITS
    // beats on the wide bus, which is correct at the old rate. Reads use it on
    // the multi-outstanding path only; the classic read path and the Ethernet
    // instance are unchanged.
    //
    // 4 KB rule. A full-width burst of 256 beats is exactly 4 KB, so the
    // historical split (256 beats from wherever the request starts) would
    // cross a 4 KB boundary on every burst of a request that does not start on
    // one. Full-width requests are split on 4 KB boundaries instead: the first
    // burst runs to the end of its 4 KB page, the following ones are whole
    // pages, the last one carries the remainder. With page_off the request's
    // first beat inside its page:
    //     bursts    = ceil((page_off + beats) / 256)
    //     first len = min(beats, 256 - page_off) - 1
    //     last len  = (page_off + beats - 1) mod 256
    // which is the historical formula when page_off = 0. ARCH_BITS-beat bursts
    // keep the historical split.
    localparam bit WIDE_DMA = (LANES > 1) && (DMA_NOC_WIDTH == MEM_AXIDW) && (eth_dma == 0);
    localparam int BUS_SIZE = $clog2(MEM_AW);          // AxSIZE of a full-width beat
    // The split above needs 256 full-width beats per 4 KB page, i.e. a
    // 128-bit bus; checked at simulation start under ESP_SVA.

    logic        rd_wide;         // the DMA read in flight uses full-width beats
    logic        rd_wide_next;
    logic [7:0]  first_len;       // AR_LEN of the first burst of the request
    logic [7:0]  first_len_next;
    logic [31:0] rd_beats;        // full-width beats of the request (combinational)
    logic [7:0]  rd_page_off;
    logic [31:0] wr_beats;
    logic [7:0]  wr_page_off;
    logic [8:0]  wr_first;        // beats of the first write burst
    // Next write burst, from cs.count (beats still to send after this burst;
    // exact on the full-width path, "beats - 1" on the historical one).
    logic [7:0]  wr_next_len;
    logic [31:0] wr_next_count;
    // One bus word as a DMA flit, and a DMA flit as one bus word.
    logic [MEM_AXIDW-1:0] r_flit_wide;
    logic [MEM_AXIDW-1:0] w_data_wide;
    logic                 w_wide_beat;

    // Main FSM reads (CPU, debug link, classic DMA): offset of the beat it
    // takes next. Loaded when its AR is accepted, advanced on every R beat.
    logic [OFF_W-1:0]  rd_off;
    logic [LANE_W-1:0] rd_lane;
    assign rd_lane = (LANES > 1) ? rd_off[WORD_LSB+:LANE_W] : '0;
    // Writes: offset of the W beat driven next. Loaded when the AW is
    // accepted, advanced on every W beat.
    logic [OFF_W-1:0]  wr_off;
    logic [LANE_W-1:0] wr_lane;
    assign wr_lane = (LANES > 1) ? wr_off[WORD_LSB+:LANE_W] : '0;
    // Lane of the R beat in front of the proxy, and the word in it.
    logic [LANE_W-1:0]      r_lane;
    logic [ARCH_BITS-1 : 0] r_word;

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

    localparam int unsigned DMA_AXI_SIZE = (ARCH_BITS == 32 || eth_dma == 1) ? XSIZE_WORD : XSIZE_DWORD;

    // Multi-outstanding read path in use. The Ethernet DMA instance
    // (eth_dma = 1) always takes the classic path, which issues its
    // one-word reads.
    localparam bit MULTI_OT = (dma_multi_ot != 0) && (eth_dma == 0);

    (* mark_debug = "true" *) reg_type cs, ns;
    logic [31:0] eth_dma_rdata32;

    // Context table for up to MAX_DMA_OT outstanding non-coherent DMA reads.
    // Capped at 4 by the 2-bit AR_ID/R_ID ports toward the memory controller
    // (widening needs rtl/sockets/bus/amba.vhd's XID_WIDTH too), and must be
    // a power of two for the response-FIFO pointers to wrap correctly.
    localparam MAX_DMA_OT = 4;
    localparam CTX_IDX_W  = (MAX_DMA_OT > 1) ? $clog2(MAX_DMA_OT) : 1;
    localparam FIFO_CNT_W = $clog2(MAX_DMA_OT + 1);

    logic                                         ctx_valid     [0:MAX_DMA_OT-1];
    logic [DMA_NOC_FLIT_SIZE-1:0]                 ctx_rsp_header[0:MAX_DMA_OT-1];
    // AXI bursts still to drain for the context after its first one.
    logic [31:0]                                  ctx_count     [0:MAX_DMA_OT-1];
    logic [$clog2(DMA_NOC_WIDTH/ARCH_BITS):0]     ctx_word_cnt  [0:MAX_DMA_OT-1];
    logic [DMA_NOC_WIDTH-1:0]                     ctx_noc_data  [0:MAX_DMA_OT-1];
    // Lane of the next R beat of the context (memory bus wider than ARCH_BITS).
    logic [LANE_W-1:0]                            ctx_lane      [0:MAX_DMA_OT-1];
    // The context's request uses full-width beats.
    logic                                         ctx_wide      [0:MAX_DMA_OT-1];

    // Free-slot allocation. Lowest free slot wins: the loop runs from the
    // highest index down, so the last assignment (the lowest free index)
    // survives.
    logic                 any_ctx_valid;
    logic                 ctx_alloc_avail;
    logic [CTX_IDX_W-1:0] ctx_alloc_idx;
    always_comb begin
        any_ctx_valid   = 1'b0;
        ctx_alloc_avail = 1'b0;
        ctx_alloc_idx   = '0;
        for (int s = MAX_DMA_OT - 1; s >= 0; s = s - 1) begin
            any_ctx_valid = any_ctx_valid | ctx_valid[s];
            if (!ctx_valid[s]) begin
                ctx_alloc_avail = 1'b1;
                ctx_alloc_idx   = CTX_IDX_W'(s);
            end
        end
    end

    // Continuation AR issue: a >256-beat request becomes several back-to-back
    // AXI bursts (same AR_ID), published as one context on the first AR so
    // the response FSM can drain it while later ARs are still issuing.

    // Correctness assumes the memory returns bursts in the order ARs were accepted 
    logic [31:0]          req_bursts;       // ceil(beats/256) for the request in flight
    logic [31:0]          req_bursts_next;  // combinational, from the length flit
    logic                 req_bursts_en;    // latch req_bursts_next / last_len_next
    logic [31:0]          ar_left;          // ARs still to issue, current one included; rests at 1
    logic                 ar_left_dec;      // a non-final AR of the request was accepted
    logic [7:0]           last_len;         // AR_LEN of the final burst: (beats-1) mod 256
    logic [7:0]           last_len_next;
    logic                 ctx_burst_dec;    // one burst of the active context has drained
    logic                 ar_first;         // the next AR is the first of its request
    // Index of the context the request in flight was allocated. ctx_alloc_idx is
    // combinational from ctx_valid, so the cycle after ctx_alloc_en it already
    // points at the next free slot; continuation ARs must keep the index that
    // was published, or the response FSM never accepts their data.
    logic [CTX_IDX_W-1:0] ctx_cur_idx;

    // Response FSM states: DMA_RSP_IDLE waits for a context to need draining,
    // DMA_RSP_HEADER emits its header, DMA_RSP_DATA packs AXI R-beats into
    // NoC flits and sends them.
    localparam [1:0] DMA_RSP_IDLE    = 2'b00;
    localparam [1:0] DMA_RSP_HEADER  = 2'b01;
    localparam [1:0] DMA_RSP_DATA    = 2'b10;
    logic [1:0] dma_rsp_state, dma_rsp_next;

    // Tracks allocation order so responses drain in the order issued, per
    // this memory tile; cross-tile reordering is resolved on the accelerator
    // side via get_dma_tran_id, the per-slot id echoed into the response header.
    logic [CTX_IDX_W-1:0]  rsp_fifo [0:MAX_DMA_OT-1];
    logic [CTX_IDX_W-1:0]  rsp_fifo_rd;
    logic [CTX_IDX_W-1:0]  rsp_fifo_wr;
    logic [FIFO_CNT_W-1:0] rsp_fifo_cnt;
    logic                  rsp_fifo_empty;
    assign rsp_fifo_empty = (rsp_fifo_cnt == '0);

    // Active context = head of response FIFO.
    logic [CTX_IDX_W-1:0] active_ctx;
    assign active_ctx = rsp_fifo[rsp_fifo_rd];

    // Combinational control strobes consumed by the sequential block.
    logic        ctx_alloc_en;
    logic        ctx_free_en;
    logic        rsp_fifo_push;
    logic        rsp_fifo_pop;
    logic        rsp_data_handshake;

    // Response-FSM next-state for word_cnt and packed flit data.
    logic [DMA_NOC_WIDTH-1:0]                     rsp_noc_data_next;
    logic [$clog2(DMA_NOC_WIDTH/ARCH_BITS):0]     rsp_word_cnt_next;

    // DMA AR channel, driven by the main FSM for every burst of a request.
    logic        dma_ar_valid;
    logic [GLOB_PHYS_ADDR_BITS-1:0] dma_ar_addr;
    logic [7:0]  dma_ar_len;
    logic [2:0]  dma_ar_size;
    logic [2:0]  dma_ar_prot;
    logic [1:0]  dma_ar_id;

    // RAW fix: writes are posted (no B wait), and AW/AR take independent
    // paths below this port, so a younger read's AR could reach memory
    // before an older write commits. pending_writes counts outstanding
    // AW's; a newly dequeued read's AR (and its continuations) wait for it.

    // Known gap: a younger write can still overtake an older in-flight read
    // (WAR direction), unaddressed; a per-address CAM is the precise fix.
    logic [7:0] pending_writes;
    wire        aw_hs = AW_VALID & AW_READY;
    wire        b_hs  = B_VALID  & B_READY;

    always_comb begin
        ns = cs;
        next_state = current_state;
        preamble     = pad_coherence_req_data_out[this_coh_flit_size-1:this_coh_flit_size-`PREAMBLE_WIDTH];
        dma_preamble = pad_dma_rcv_data_out[DMA_NOC_FLIT_SIZE-1:DMA_NOC_FLIT_SIZE-`PREAMBLE_WIDTH];

        // Peek the pending head-of-queue message type so RECEIVE_HEADER can
        // gate only reads on context/AR-ID availability below. Writes never
        // allocate a context or share an AR_ID with one, so they must not be
        // held behind a condition that exists to protect the context table.
        coh_head_msg = pad_coherence_req_data_out[this_coh_flit_size - `PREAMBLE_WIDTH - 4*GLOB_YX_WIDTH - 1 : this_coh_flit_size - `PREAMBLE_WIDTH - 4*GLOB_YX_WIDTH - `MSG_TYPE_WIDTH];
        dma_head_msg = pad_dma_rcv_data_out[DMA_NOC_FLIT_SIZE - `PREAMBLE_WIDTH - 4*GLOB_YX_WIDTH - 1 : DMA_NOC_FLIT_SIZE - `PREAMBLE_WIDTH - 4*GLOB_YX_WIDTH - `MSG_TYPE_WIDTH];
        coh_head_is_read = (coh_head_msg == REQ_GETS_W) || (coh_head_msg == REQ_GETS_HW) ||
                           (coh_head_msg == REQ_GETS_B) || (coh_head_msg == AHB_RD);
        dma_head_is_read = (dma_head_msg == DMA_TO_DEV) || (dma_head_msg == REQ_DMA_READ);
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
        ctx_burst_dec      = 1'b0;
        req_bursts_next    = '0;
        req_bursts_en      = 1'b0;
        last_len_next      = '0;
        first_len_next     = '0;
        rd_wide_next       = 1'b0;
        rd_beats           = '0;
        rd_page_off        = '0;
        wr_beats           = '0;
        wr_page_off        = '0;
        wr_first           = '0;
        ar_left_dec        = 1'b0;
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
                ns.dma_size = DMA_AXI_SIZE;
                // Stall coherence while any DMA context is active: they share
                // the AXI master's AR_ID space. Writes use AW_ID = mst_index
                // unconditionally (never muxed with a context index), so they
                // never collide and skip this check.
                if (coherence_req_empty == 1'b0 &&
                    (!coh_head_is_read || !any_ctx_valid)) begin
                    coherence_req_rdreq = 1'b1;
                    ns.msg      = pad_coherence_req_data_out[this_coh_flit_size - `PREAMBLE_WIDTH - 4*GLOB_YX_WIDTH - 1 : this_coh_flit_size - `PREAMBLE_WIDTH - 4*GLOB_YX_WIDTH - `MSG_TYPE_WIDTH];
                    reserved    = pad_coherence_req_data_out[this_coh_flit_size - `PREAMBLE_WIDTH - 4*GLOB_YX_WIDTH - `MSG_TYPE_WIDTH - 1 : this_coh_flit_size - `PREAMBLE_WIDTH - 4*GLOB_YX_WIDTH - `MSG_TYPE_WIDTH - `RESERVED_WIDTH];
                    ns.ax_prot = reserved[2:0];
                    if (axitran == 0) ns.hsize_msb = 0;
                    else ns.hsize_msb = reserved[3];

                    sample_header = 1'b1;
                    next_state    = RECEIVE_ADDRESS;
                end else if (dma_rcv_empty == 1'b0 &&
                             (!dma_head_is_read || ctx_alloc_avail) &&
                             (!MULTI_OT || coherence_req_empty)) begin
                    // ctx_alloc_avail gates reads only (writes never allocate
                    // a context, so gating them too would stall for no reason).
                    // coherence_req_empty stops DMA from refilling slots
                    // forever and starving the CPU once any_ctx_valid blocks above.
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
                ns.wr_wide      = 1'b0;
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
                        coh_rd_data_flit[ARCH_BITS*i+:ARCH_BITS] = fix_endian(r_word, little_end);

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
                    ns.ar_size = DMA_AXI_SIZE;
                    ns.aw_size = DMA_AXI_SIZE;

                    if (cs.msg == DMA_TO_DEV || cs.msg == REQ_DMA_READ) begin
                        next_state = DMA_RECEIVE_READ_LENGTH;
                        ns.ar_addr = dma_rcv_data_out[GLOB_PHYS_ADDR_BITS-1 : 0];
                    end else begin
                        ns.aw_len  = 0;
                        ns.aw_addr = dma_rcv_data_out[GLOB_PHYS_ADDR_BITS-1 : 0];
                        if (cs.msg == DMA_FROM_DEV) begin
                            ns.coh_dma_flag = 1'b0;
                            // Non-coherent DMA sends its length so mem2ext (FPGA
                            // instances without a DDR controller) knows the payload
                            // size up front; coherent DMA skips it since mem2ext
                            // assumes LLC is present and doesn't need it.
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
                    // Multi-OT: ceil(beats/256) bursts and the final burst's
                    // length, computed up front so the context can publish on
                    // the first AR. cs.count/ns.ar_len below is classic-path only.
                    req_bursts_next = (dma_rcv_data_out[31:0] + 32'd255) >> 8;
                    last_len_next   = dma_rcv_data_out[7:0] - 8'd1;
                    first_len_next  = (req_bursts_next > 32'd1) ? 8'd255 : last_len_next;
                    req_bursts_en   = 1'b1;
                    // Full-width beats: address aligned to the bus word and a
                    // whole number of bus words. Split on 4 KB boundaries (see
                    // the note on full-width DMA beats near the top).
                    rd_wide_next = MULTI_OT && WIDE_DMA &&
                                   (cs.ar_addr[BUS_SIZE-1:0] == '0) &&
                                   (dma_rcv_data_out[LANE_W-1:0] == '0) &&
                                   (dma_rcv_data_out[31:0] != '0);
                    if (rd_wide_next) begin
                        rd_beats        = dma_rcv_data_out[31:0] >> LANE_W;
                        rd_page_off     = 8'(cs.ar_addr[11:0] >> BUS_SIZE);
                        req_bursts_next = (rd_beats + 32'(rd_page_off) + 32'd255) >> 8;
                        last_len_next   = rd_beats[7:0] + rd_page_off - 8'd1;
                        first_len_next  = (req_bursts_next > 32'd1) ? (8'd255 - rd_page_off)
                                                                    : (rd_beats[7:0] - 8'd1);
                        ns.ar_size      = 3'(BUS_SIZE);
                    end
                    if (eth_dma == 1) begin
                        ns.ar_len = 0;
                    end else if (ns.count > 255) begin
                        ns.ar_len = 255;
                        ns.count  = ns.count - 256;
                    end else begin
                        ns.ar_len = ns.count;
                        ns.count  = 0;
                    end
                    // Classic path pre-sets ar_valid here; multi-OT must not,
                    // since the RAW gate can hold dma_ar_valid low on entry,
                    // and `dma_ar_valid | cs.ar_valid` would then emit a
                    // spurious orphan AR (AR_ID=mst_index, no context), wedging the R channel.
                    if (!MULTI_OT) ns.ar_valid = 1'b1;
                    // The multi-outstanding path counts bursts with req_bursts and
                    // ar_left and never drains cs.count. Clear it so that a later
                    // coherence read on the axitran = 0 path, which does not reload
                    // the count, does not issue extra bursts.
                    if (MULTI_OT) ns.count = 0;
                    next_state  = DMA_READ_REQUEST;
                end
            end

            DMA_READ_REQUEST: begin
                // Multi-OT: issue every AR via dma_ar_*, allocating a context
                // on the first one. The response FSM owns header/data
                // forwarding from there; this FSM returns to RECEIVE_HEADER
                // once the last AR is accepted.
                if (!MULTI_OT) begin
                    // Classic single-outstanding path, unchanged: hold AR,
                    // then walk to header/data emission in this same FSM.
                    // Deliberately carries no RAW gate, so with the switch off
                    // this read path behaves as before.
                    ns.ar_valid = 1'b1;
                    if (AR_READY == 1'b1) begin
                        if (cs.burst_flag == 0) begin
                            if (dma_snd_full == 1'b0) begin
                                dma_snd_data_in = dma_header_reg;
                                dma_snd_wrreq   = 1'b1;
                                next_state      = DMA_SEND_DATA;
                            end else next_state = DMA_SEND_HEADER;
                        end else next_state = DMA_SEND_DATA;
                        ns.ar_valid = 1'b0;
                    end
                end else if (pending_writes == '0) begin
                    // Hand the fabric every burst before returning to
                    // RECEIVE_HEADER, so no other request's AR can interleave.
                    // Every AR shares one id: the first uses the free slot,
                    dma_ar_valid = 1'b1;
                    dma_ar_addr  = cs.ar_addr;
                    dma_ar_len   = ar_first ? first_len :
                                   ((ar_left > 32'd1) ? 8'd255 : last_len);
                    dma_ar_size  = cs.ar_size;
                    dma_ar_prot  = cs.ar_prot;
                    dma_ar_id    = 2'(ar_first ? ctx_alloc_idx : ctx_cur_idx);
                    if (AR_READY == 1'b1) begin
                        // Publish the context on the first AR so the response
                        // FSM can drain burst 1 while later ARs are still being
                        // issued. ar_first is true only for that first AR.
                        if (ar_first) begin
                            ctx_alloc_en  = 1'b1;
                            rsp_fifo_push = 1'b1;
                        end
                        if (ar_left > 32'd1) begin
                            ar_left_dec = 1'b1;
                            ns.ar_addr  = cs.ar_addr +
                                          ((dma_ar_len + 1) << cs.ar_size);
                            next_state  = DMA_READ_REQUEST;
                        end else begin
                            next_state  = RECEIVE_HEADER;
                        end
                    end
                end
            end

            // DMA_SEND_HEADER and DMA_SEND_DATA belong to the classic path.
            DMA_SEND_HEADER: begin
                if (dma_snd_full == 1'b0) begin
                    next_state      = DMA_SEND_DATA;
                    dma_snd_data_in = dma_header_reg;
                    dma_snd_wrreq   = 1'b1;
                end
            end

            DMA_SEND_DATA: begin
                if (dma_snd_full == 1'b0) begin
                    if (R_VALID == 1'b1) begin
                        if (eth_dma == 1) begin
                            ns.dma_noc_data = '0;
                            ns.dma_noc_data[31:0] = eth_dma_rdata32;
                            ns.word_cnt = 0;
                        end else begin
                            ns.dma_noc_data[ARCH_BITS*cs.word_cnt+:ARCH_BITS] =
                                fix_endian(r_word, little_end);
                            ns.word_cnt = cs.word_cnt + 1;
                        end

                        if (R_LAST == 1'b0) begin
                            if ((ns.word_cnt == DMA_NOC_WIDTH / ARCH_BITS) || (eth_dma == 1)) begin
                                ns.word_cnt     = 0;
                                dma_snd_wrreq   = 1'b1;
                                dma_snd_data_in = {PREAMBLE_BODY, ns.dma_noc_data};
                            end
                        end else begin
                            ns.word_cnt   = 0;
                            dma_snd_wrreq = 1'b1;
                            if (cs.count == 0) begin
                                dma_snd_data_in = {PREAMBLE_TAIL, ns.dma_noc_data};
                                next_state      = RECEIVE_HEADER;
                            end else begin
                                dma_snd_data_in = {PREAMBLE_BODY, ns.dma_noc_data};
                                if (eth_dma == 1) begin
                                    ns.ar_len  = 0;
                                    ns.count   = cs.count - 1;
                                    ns.ar_addr = cs.ar_addr + 4;
                                end else if (cs.count > 255) begin
                                    ns.ar_len = 255;
                                    ns.count  = cs.count - 256;
                                    ns.ar_addr = cs.ar_addr + ((cs.ar_len + 1) << cs.ar_size);
                                end else begin
                                    ns.ar_len = cs.count;
                                    ns.count  = 0;
                                    ns.ar_addr = cs.ar_addr + ((cs.ar_len + 1) << cs.ar_size);
                                end
                                ns.burst_flag = 1;  // Give the new address for the new burst
                                ns.ar_valid   = 1'b1;
                                next_state    = DMA_READ_REQUEST;
                            end
                        end
                    end
                end
            end

            DMA_RECEIVE_WRITE_LENGTH: begin
                if (dma_rcv_empty == 1'b0) begin
                    dma_rcv_rdreq = 1'b1;
                    ns.count      = dma_rcv_data_out[31:0] - 1;
                    if (eth_dma == 1) begin
                        ns.aw_len   = 0;
                        ns.word_rem = 0;
                        ns.count    = 0;
                    end else if (ns.count > 255) begin
                        ns.aw_len   = 255;
                        ns.word_rem = 255;
                        ns.count    = ns.count - 256;

                    end else begin
                        ns.aw_len   = ns.count;
                        ns.word_rem = ns.count;
                        ns.count    = 0;
                    end
                    // Full-width beats (see the note near the top): one flit
                    // per beat, first burst up to the 4 KB boundary. cs.count
                    // then holds the exact number of beats left after the
                    // current burst.
                    if (WIDE_DMA && (cs.aw_addr[BUS_SIZE-1:0] == '0) &&
                        (dma_rcv_data_out[LANE_W-1:0] == '0) &&
                        (dma_rcv_data_out[31:0] != '0) && (cs.dma_size_valid == 1'b0)) begin
                        wr_beats    = dma_rcv_data_out[31:0] >> LANE_W;
                        wr_page_off = 8'(cs.aw_addr[11:0] >> BUS_SIZE);
                        wr_first    = (wr_beats + 32'(wr_page_off) > 32'd256) ? (9'd256 - 9'(wr_page_off))
                                                                             : wr_beats[8:0];
                        ns.wr_wide  = 1'b1;
                        ns.aw_size  = 3'(BUS_SIZE);
                        ns.aw_len   = 8'(wr_first - 9'd1);
                        ns.word_rem = 8'(wr_first - 9'd1);
                        ns.count    = wr_beats - 32'(wr_first);
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
                                ns.aw_len   = wr_next_len;
                                ns.word_rem = wr_next_len;
                                ns.count    = wr_next_count;
                                ns.aw_addr = cs.aw_addr + ((cs.aw_len + 1) << cs.aw_size);
                            end
                        end else begin
                            ns.word_rem = cs.word_rem - 1;
                            // BURST CONTINUES
                            if ((ns.word_cnt == DMA_NOC_WIDTH / ARCH_BITS) || cs.wr_wide || (eth_dma == 1)) begin
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
                                ns.aw_len   = wr_next_len;
                                ns.word_rem = wr_next_len;
                                ns.count    = wr_next_count;
                                ns.aw_addr = cs.aw_addr + ((cs.aw_len + 1) << cs.aw_size);
                            end
                        end else begin
                            // BURST CONTINUES
                            if ((ns.word_cnt == DMA_NOC_WIDTH / ARCH_BITS) || cs.wr_wide || (eth_dma == 1)) begin
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

        // Response FSM: drains DMA responses to dma_snd, decoupled from the
        // main FSM so it's free to dequeue the next request. 
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
                    R_ID == 2'(active_ctx)) begin

                    rsp_data_handshake = 1'b1;

                    if (WIDE_DMA && ctx_wide[active_ctx]) begin
                        // Full-width beat: the bus word is the flit.
                        rsp_noc_data_next = DMA_NOC_WIDTH'(r_flit_wide);
                        rsp_word_cnt_next = DMA_NOC_WIDTH / ARCH_BITS;
                    end else begin
                        rsp_noc_data_next = ctx_noc_data[active_ctx];
                        rsp_noc_data_next[ARCH_BITS*ctx_word_cnt[active_ctx]+:ARCH_BITS] =
                            fix_endian(r_word, little_end);
                        rsp_word_cnt_next = ctx_word_cnt[active_ctx] + 1;
                    end

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
                            // Final burst - send tail and free the context.
                            dma_snd_data_in = {PREAMBLE_TAIL, rsp_noc_data_next};
                            ctx_free_en     = 1'b1;
                            rsp_fifo_pop    = 1'b1;
                            dma_rsp_next    = DMA_RSP_IDLE;
                        end else begin
                            // More bursts of this request are already queued at
                            // the fabric and return in order: account for the
                            // burst and keep streaming the same packet.
                            dma_snd_data_in = {PREAMBLE_BODY, rsp_noc_data_next};
                            ctx_burst_dec   = 1'b1;
                            dma_rsp_next    = DMA_RSP_DATA;
                        end
                    end
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
        eth_dma_rdata32       = '0;

        dma_payload_live      = dma_rcv_data_out[DMA_NOC_WIDTH-1 : 0];
        dma_payload_pref      = cs.dma_flit[DMA_NOC_WIDTH-1 : 0];

        if (ARCH_BITS == 64) begin
            eth_dma_rdata32 = (cs.ar_addr[2] == 1'b0) ? r_word[63:32] : r_word[31:0];
        end else begin
            eth_dma_rdata32 = r_word[31:0];
        end

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
                if (coherence_rsp_snd_full == 1'b0 && dma_rsp_state == DMA_RSP_IDLE) r_ready_comb = 1'b1;
            end
            DMA_SEND_DATA: begin
                // Classic path. Unreachable when MULTI_OT is set, where the
                // response FSM block below drives R_READY instead.
                if (dma_snd_full == 1'b0 && cs.sample_flag == 2'b00) r_ready_comb = 1'b1;
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

        // R_READY override: accept beats only for the context at the head
        // of the response FIFO. A refused beat for any other context never
        // blocks the head, since the memory returns bursts in AR order
        if (dma_rsp_state == DMA_RSP_DATA && dma_snd_full == 1'b0 &&
            R_ID == 2'(active_ctx)) begin
            r_ready_comb = 1'b1;
        end
    end

    // AR channel mux: DMA reads use dma_ar_* (driven by the main FSM for every
    // burst of a request); coherence reads keep the legacy cs.ar_* path. AR_ID
    // is the per-context index for DMA, or mst_index for coherence.
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
    // The word goes out on every lane; only the lane of the beat's address is
    // strobed (see the note on wide memory buses near the top).
    // A full-width DMA write beat carries the whole flit on all strobes.
    assign w_wide_beat = WIDE_DMA && cs.wr_wide && (current_state == DMA_WRITE_DATA);
    assign W_DATA   = w_wide_beat ? w_data_wide : {LANES{w_data_comb}};
    always_comb begin
        W_STRB = '0;
        W_STRB[AW*wr_lane+:AW] = w_strb_comb;
        if (w_wide_beat) W_STRB = '1;
    end

    // Bus word <-> DMA flit for full-width beats: word by word, with the same
    // byte order fix as the ARCH_BITS path. The write side follows the
    // prefetch flag exactly as the ARCH_BITS datapath does.
    always_comb begin
        r_flit_wide = '0;
        w_data_wide = '0;
        if (WIDE_DMA) begin
            for (int l = 0; l < LANES; l++) begin
                r_flit_wide[ARCH_BITS*l+:ARCH_BITS] = fix_endian(R_DATA[ARCH_BITS*l+:ARCH_BITS], little_end);
                w_data_wide[ARCH_BITS*l+:ARCH_BITS] =
                    fix_endian((cs.sample_flag != 2'b00) ? cs.dma_flit[ARCH_BITS*l+:ARCH_BITS]
                                                         : dma_rcv_data_out[ARCH_BITS*l+:ARCH_BITS], little_end);
            end
        end
    end

    // Next write burst (see wr_next_len).
    always_comb begin
        if (cs.wr_wide) begin
            if (cs.count > 32'd256) begin
                wr_next_len   = 8'd255;
                wr_next_count = cs.count - 32'd256;
            end else begin
                wr_next_len   = cs.count[7:0] - 8'd1;
                wr_next_count = '0;
            end
        end else begin
            if (cs.count > 32'd255) begin
                wr_next_len   = 8'd255;
                wr_next_count = cs.count - 32'd256;
            end else begin
                wr_next_len   = cs.count[7:0];
                wr_next_count = '0;
            end
        end
    end
    assign B_READY  = 1'b1;

    // -------------------------------------------------------------------------
    // Simulation-only invariants
    // -------------------------------------------------------------------------
    // Guarded on ESP_SVA, which the ModelSim/Questa flows define for simulation
    // compiles only (utils/make/modelsim.mk) and the Vivado flow never does.
    // SYNTHESIS is not a reliable simulation/synthesis discriminator in the
    // ESP flows. The first six properties come with the multi-outstanding
    // read path (they were not carried into this tree with it); the rest
    // cover a memory bus wider than the CPU word.
`ifdef ESP_SVA
    // Read-after-write gate: no DMA read AR while a posted write is unconfirmed.
    raw_gate_no_read_with_pending_writes : assert property (
        @(posedge ACLK) disable iff (ARESETn == 1'b0)
        ((current_state == DMA_READ_REQUEST) && dma_ar_valid && AR_READY)
            |-> (pending_writes == '0))
        else $error("noc2aximst: DMA read AR issued with %0d posted write(s) unconfirmed",
                    pending_writes);

    pending_writes_no_underflow : assert property (
        @(posedge ACLK) disable iff (ARESETn == 1'b0)
        (b_hs && !aw_hs) |-> (pending_writes != '0))
        else $error("noc2aximst: B response received with no posted write outstanding");

    pending_writes_no_overflow : assert property (
        @(posedge ACLK) disable iff (ARESETn == 1'b0)
        (aw_hs && !b_hs) |-> (pending_writes != 8'hFF))
        else $error("noc2aximst: pending_writes counter overflow");

    // In-order return. The response FSM assumes the memory returns bursts in
    // the order their ARs were accepted. A memory that reorders across ids
    // would offer a beat the FSM refuses and the R channel would wedge; this
    // turns that silent deadlock into a simulation failure.
    rsp_beat_matches_active_ctx : assert property (
        @(posedge ACLK) disable iff (ARESETn == 1'b0)
        (dma_rsp_state == DMA_RSP_DATA && R_VALID)
            |-> (R_ID == 2'(active_ctx)))
        else $error("noc2aximst: R beat for ctx %0d while draining ctx %0d: the memory returned bursts out of AR order (check C0.DDR4_Ordering = Strict)",
                    R_ID, active_ctx);

    ar_left_no_underflow : assert property (
        @(posedge ACLK) disable iff (ARESETn == 1'b0)
        ((current_state == DMA_READ_REQUEST) && dma_ar_valid && AR_READY)
            |-> (ar_left != '0))
        else $error("noc2aximst: AR accepted with no burst left to issue");

    ctx_published_with_bursts : assert property (
        @(posedge ACLK) disable iff (ARESETn == 1'b0)
        ctx_alloc_en |-> (req_bursts != '0))
        else $error("noc2aximst: context published for a zero-burst request");

    // Full-width DMA beats: aligned to the bus word, and no burst crosses a
    // 4 KB boundary (first beat's position in the page plus the length).
    wide_ar_aligned_within_4k : assert property (
        @(posedge ACLK) disable iff (ARESETn == 1'b0)
        (dma_ar_valid && rd_wide)
            |-> (dma_ar_size == 3'(BUS_SIZE) && dma_ar_addr[BUS_SIZE-1:0] == '0 &&
                 (9'(dma_ar_addr[11:0] >> BUS_SIZE) + 9'(dma_ar_len) <= 9'd255)))
        else $error("noc2aximst: full-width read burst misaligned or crossing 4 KB (addr %h len %0d)",
                    dma_ar_addr, dma_ar_len);

    wide_aw_aligned_within_4k : assert property (
        @(posedge ACLK) disable iff (ARESETn == 1'b0)
        (AW_VALID && cs.wr_wide)
            |-> (AW_SIZE == 3'(BUS_SIZE) && AW_ADDR[BUS_SIZE-1:0] == '0 &&
                 (9'(AW_ADDR[11:0] >> BUS_SIZE) + 9'(AW_LEN) <= 9'd255)))
        else $error("noc2aximst: full-width write burst misaligned or crossing 4 KB (addr %h len %0d)",
                    AW_ADDR, AW_LEN);

    // Limits checked at simulation start. MAX_DMA_OT must fit the 2-bit
    // AR_ID/R_ID ports and be a power of two (the response-order FIFO pointers
    // wrap by overflow). The lane logic handles one or two ARCH_BITS words per
    // bus word, and the 4 KB split of full-width bursts needs 16-byte beats.
    initial begin
        if (MAX_DMA_OT != 2 && MAX_DMA_OT != 4)
            $fatal(1, "noc2aximst: MAX_DMA_OT = %0d; supported values are 2 and 4", MAX_DMA_OT);
        if (LANES != 1 && LANES != 2)
            $fatal(1, "noc2aximst: MEM_AXIDW = %0d with ARCH_BITS = %0d is not supported", MEM_AXIDW, ARCH_BITS);
        if (WIDE_DMA && BUS_SIZE != 4)
            $fatal(1, "noc2aximst: full-width DMA beats need a 128-bit memory bus (MEM_AXIDW = %0d)", MEM_AXIDW);
    end
`endif

    // Lane tracking on a memory bus wider than ARCH_BITS (see the note near the
    // top). The response FSM owns the R channel in DMA_RSP_DATA and uses the
    // active context's lane; otherwise the main FSM does, with rd_off.
    assign r_lane = (dma_rsp_state == DMA_RSP_DATA) ? ctx_lane[active_ctx] : rd_lane;
    assign r_word = R_DATA[ARCH_BITS*((LANES > 1) ? r_lane : '0)+:ARCH_BITS];

    always_ff @(posedge ACLK, negedge ARESETn) begin
        if (ARESETn == 1'b0) begin
            rd_off <= '0;
            wr_off <= '0;
        end else begin
            // cs.ar_valid is the main FSM's AR (the multi-outstanding path
            // drives dma_ar_valid instead and tracks lanes per context).
            if (cs.ar_valid && AR_READY) rd_off <= bus_offset(cs.ar_addr, cs.ar_size);
            else if (R_VALID && R_READY && dma_rsp_state != DMA_RSP_DATA)
                rd_off <= rd_off + (OFF_W'(1) << cs.ar_size);
            if (AW_VALID && AW_READY) wr_off <= bus_offset(cs.aw_addr, cs.aw_size);
            else if (W_VALID && W_READY) wr_off <= wr_off + (OFF_W'(1) << cs.aw_size);
        end
    end

    // Posted-write counter (RAW fix, see declaration). ++ on AW, -- on B;
    // simultaneous AW+B nets to zero. Coherence writes also wait for theirs
    // inline in WRITE_RESPONSE_WAIT -- counted here too, harmless.
    always_ff @(posedge ACLK, negedge ARESETn) begin
        if (ARESETn == 1'b0) begin
            pending_writes <= '0;
        end else begin
            case ({aw_hs, b_hs})
                2'b10:   pending_writes <= pending_writes + 8'd1;
                // Saturate at zero: a spurious/unmatched B must never wrap
                // the counter to 0xFF and wedge the read gate permanently.
                2'b01:   pending_writes <= (pending_writes == '0) ? '0
                                           : pending_writes - 8'd1;
                default: pending_writes <= pending_writes;
            endcase
        end
    end

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
            cs.dma_size      <= DMA_AXI_SIZE;
            cs.wr_wide       <= 1'b0;
        end else begin
            current_state <= next_state;
            cs            <= ns;
        end
    end

    // Multi-OT context table + response FSM sequential block. ctx_alloc_en
    // captures the request on its first AR; ctx_free_en frees the slot on
    // response-tail; rsp_fifo serializes drain order per memory tile.
    always_ff @(posedge ACLK, negedge ARESETn) begin
        if (ARESETn == 1'b0) begin
            dma_rsp_state <= DMA_RSP_IDLE;
            rsp_fifo_rd   <= '0;
            rsp_fifo_wr   <= '0;
            rsp_fifo_cnt  <= '0;
            for (int k = 0; k < MAX_DMA_OT; k = k + 1) rsp_fifo[k] <= '0;
            for (int k = 0; k < MAX_DMA_OT; k = k + 1) begin
                ctx_valid[k]      <= 1'b0;
                ctx_rsp_header[k] <= '0;
                ctx_count[k]      <= '0;
                ctx_word_cnt[k]   <= '0;
                ctx_lane[k]       <= '0;
                ctx_wide[k]       <= 1'b0;
                ctx_noc_data[k]   <= '0;
            end
            req_bursts  <= '0;
            ar_left     <= '0;
            last_len    <= '0;
            first_len   <= '0;
            rd_wide     <= 1'b0;
            ar_first    <= 1'b1;
            ctx_cur_idx <= '0;
        end else begin
            dma_rsp_state <= dma_rsp_next;

            // Allocate a context on the first AR handshake of a request: the
            // response header to echo, and the number of AXI bursts still to
            // drain after the first one, i.e. ceil(beats/256) - 1.
            if (ctx_alloc_en) begin
                ctx_valid[ctx_alloc_idx]      <= 1'b1;
                ctx_rsp_header[ctx_alloc_idx] <= dma_header_reg;
                ctx_count[ctx_alloc_idx]      <= req_bursts - 32'd1;
                ctx_word_cnt[ctx_alloc_idx]   <= '0;
                ctx_lane[ctx_alloc_idx]       <= LANE_W'(bus_offset(cs.ar_addr, cs.ar_size) >> WORD_LSB);
                ctx_wide[ctx_alloc_idx]       <= rd_wide;
                ctx_noc_data[ctx_alloc_idx]   <= '0;
            end

            // Free on response-tail.
            if (ctx_free_en) begin
                ctx_valid[active_ctx] <= 1'b0;
            end

            // Response R handshake updates packed-flit accumulator.
            if (rsp_data_handshake) begin
                ctx_lane[active_ctx]     <= ctx_lane[active_ctx] + 1'b1;
                ctx_word_cnt[active_ctx] <= rsp_word_cnt_next;
                ctx_noc_data[active_ctx] <= rsp_noc_data_next;
            end

            // Continuation-AR bookkeeping. The burst count and the final burst
            // length are latched when the length flit arrives; ar_first marks
            // the AR that publishes the context; ar_left counts the ARs still
            // to issue for the request in flight.
            if (req_bursts_en) begin
                req_bursts <= req_bursts_next;
                ar_left    <= req_bursts_next;
                last_len   <= last_len_next;
                first_len  <= first_len_next;
                rd_wide    <= rd_wide_next;
            end
            if (ar_left_dec)        ar_left <= ar_left - 32'd1;
            if (ctx_alloc_en)       ctx_cur_idx <= ctx_alloc_idx;
            if (ctx_alloc_en)       ar_first <= 1'b0;
            else if (req_bursts_en) ar_first <= 1'b1;

            // One burst of the active context has finished draining.
            if (ctx_burst_dec)
                ctx_count[active_ctx] <= ctx_count[active_ctx] - 32'd1;

            // Response FIFO push/pop. Both can fire in the same cycle when a
            // freeing context is immediately replaced by a new allocation.
            if (rsp_fifo_push && !rsp_fifo_pop) begin
                rsp_fifo[rsp_fifo_wr] <= ctx_alloc_idx;
                rsp_fifo_wr           <= rsp_fifo_wr + 1'b1;
                rsp_fifo_cnt          <= rsp_fifo_cnt + 1'b1;
            end else if (!rsp_fifo_push && rsp_fifo_pop) begin
                rsp_fifo_rd  <= rsp_fifo_rd + 1'b1;
                rsp_fifo_cnt <= rsp_fifo_cnt - 1'b1;
            end else if (rsp_fifo_push && rsp_fifo_pop) begin
                rsp_fifo[rsp_fifo_wr] <= ctx_alloc_idx;
                rsp_fifo_wr           <= rsp_fifo_wr + 1'b1;
                rsp_fifo_rd           <= rsp_fifo_rd + 1'b1;
                // cnt unchanged
            end
        end
    end


    // Create Response Header (COH)
    logic [    `MSG_TYPE_WIDTH-1 : 0] input_msg_type;
    logic [    `MSG_TYPE_WIDTH-1 : 0] msg_type;
    logic [ this_coh_flit_size-1 : 0] header_v;
    logic [     GLOB_PHYS_ADDR_BITS-1 : 0] origin_y;
    logic [     GLOB_PHYS_ADDR_BITS-1 : 0] origin_x;
    logic [`NEXT_ROUTING_WIDTH-1 : 0] go_right;
    logic [`NEXT_ROUTING_WIDTH-1 : 0] go_left;


    always_comb begin
        input_msg_type = pad_coherence_req_data_out[this_coh_flit_size - `PREAMBLE_WIDTH - 4*GLOB_YX_WIDTH - 1:this_coh_flit_size - `PREAMBLE_WIDTH - 4*GLOB_YX_WIDTH - `MSG_TYPE_WIDTH];

        if (input_msg_type == AHB_RD) msg_type = RSP_AHB_RD;
        else msg_type = RSP_DATA;

        origin_y = pad_coherence_req_data_out[this_coh_flit_size - `PREAMBLE_WIDTH - 1 : this_coh_flit_size - `PREAMBLE_WIDTH - GLOB_YX_WIDTH];
        origin_x = pad_coherence_req_data_out[this_coh_flit_size - `PREAMBLE_WIDTH - GLOB_YX_WIDTH - 1 : this_coh_flit_size - `PREAMBLE_WIDTH - 2*GLOB_YX_WIDTH];
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
    logic [      GLOB_YX_WIDTH-1 : 0] origin_y_dma;
    logic [      GLOB_YX_WIDTH-1 : 0] origin_x_dma;
    logic [`NEXT_ROUTING_WIDTH-1 : 0] go_right_dma;
    logic [`NEXT_ROUTING_WIDTH-1 : 0] go_left_dma;


    always_comb begin

        input_msg_type_dma = pad_dma_rcv_data_out[DMA_NOC_FLIT_SIZE - `PREAMBLE_WIDTH - 4*GLOB_YX_WIDTH - 1:DMA_NOC_FLIT_SIZE - `PREAMBLE_WIDTH - 4*GLOB_YX_WIDTH - `MSG_TYPE_WIDTH];

        if (input_msg_type_dma == REQ_DMA_READ) msg_type_dma = RSP_DATA_DMA;
        else msg_type_dma = DMA_TO_DEV;

        //reserved_resp_dma = 0;
        origin_y_dma = pad_dma_rcv_data_out[DMA_NOC_FLIT_SIZE - `PREAMBLE_WIDTH - 1 : DMA_NOC_FLIT_SIZE - `PREAMBLE_WIDTH - GLOB_YX_WIDTH];
        origin_x_dma = pad_dma_rcv_data_out[DMA_NOC_FLIT_SIZE - `PREAMBLE_WIDTH - GLOB_YX_WIDTH - 1 : DMA_NOC_FLIT_SIZE - `PREAMBLE_WIDTH - 2*GLOB_YX_WIDTH];
        header_v_dma = 0;
        header_v_dma[DMA_NOC_FLIT_SIZE-1 : DMA_NOC_FLIT_SIZE-`PREAMBLE_WIDTH] = PREAMBLE_HEADER;
        header_v_dma[DMA_NOC_FLIT_SIZE - `PREAMBLE_WIDTH - 1 : DMA_NOC_FLIT_SIZE - `PREAMBLE_WIDTH - GLOB_YX_WIDTH] = local_y;
        header_v_dma[DMA_NOC_FLIT_SIZE - `PREAMBLE_WIDTH - GLOB_YX_WIDTH - 1 : DMA_NOC_FLIT_SIZE - `PREAMBLE_WIDTH - 2*GLOB_YX_WIDTH] = local_x;
        header_v_dma[DMA_NOC_FLIT_SIZE - `PREAMBLE_WIDTH - 2*GLOB_YX_WIDTH - 1 : DMA_NOC_FLIT_SIZE - `PREAMBLE_WIDTH - 3*GLOB_YX_WIDTH] = origin_y_dma;
        header_v_dma[DMA_NOC_FLIT_SIZE - `PREAMBLE_WIDTH - 3*GLOB_YX_WIDTH - 1 : DMA_NOC_FLIT_SIZE - `PREAMBLE_WIDTH - 4*GLOB_YX_WIDTH] = origin_x_dma;
        header_v_dma[DMA_NOC_FLIT_SIZE - `PREAMBLE_WIDTH - 4*GLOB_YX_WIDTH - 1 : DMA_NOC_FLIT_SIZE - `PREAMBLE_WIDTH -  4*GLOB_YX_WIDTH - `MSG_TYPE_WIDTH] = msg_type_dma;
        //header_v_dma[`NOC_FLIT_SIZE - `PREAMBLE_WIDTH - `MSG_TYPE_WIDTH - `RESERVED_WIDTH : `NOC_FLIT_SIZE - `PREAMBLE_WIDTH - 12 - `MSG_TYPE_WIDTH] = reserved_resp_dma;

        // Echo the DMA transaction id into the response header so
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

endmodule
