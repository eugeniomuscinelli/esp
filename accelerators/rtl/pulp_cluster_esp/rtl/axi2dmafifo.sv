//`include "/axi/include/axi/typedef.svh"
//`include "/axi/src/axi_pkg.sv"
//`include "/axi/src/axi_intf.sv"
//`include "/axi/include/axi/assign.svh"

module axi2dmafifo #(
  parameter int unsigned AXI_ADDR_WIDTH = 32,
  parameter int unsigned AXI_DATA_WIDTH = 64,
  parameter int unsigned AXI_ID_WIDTH   = 4,
  parameter int unsigned AXI_USER_WIDTH = 8,
  parameter int unsigned FIFO_DEPTH     = 4  // Define the depth of FIFO for storing pending transactions
)(
  input logic clk,
  input logic rst,

  // AXI Master Interface
  AXI_BUS.Master axi_master,

  // DMA Read Control Channel
  output logic dma_read_ctrl_valid,
  output logic [31:0] dma_read_ctrl_data_index,
  output logic [31:0] dma_read_ctrl_data_length,
  output logic [2:0] dma_read_ctrl_data_size,
  input  logic dma_read_ctrl_ready,

  // DMA Read Channel Channel
  input  logic dma_read_chnl_valid,
  input  logic [AXI_DATA_WIDTH-1:0] dma_read_chnl_data,
  output logic dma_read_chnl_ready,

  // DMA Write Control Channel
  output logic dma_write_ctrl_valid,
  output logic [31:0] dma_write_ctrl_data_index,
  output logic [31:0] dma_write_ctrl_data_length,
  output logic [2:0] dma_write_ctrl_data_size,
  input  logic dma_write_ctrl_ready,

  // DMA Write Channel Channel
  output logic dma_write_chnl_valid,
  output logic [AXI_DATA_WIDTH-1:0] dma_write_chnl_data,
  input  logic dma_write_chnl_ready
);

  // FIFO for storing pending transactions
  typedef struct packed {
    logic is_write;                      // 1 if it's a write transaction, 0 if it's a read
    logic [AXI_ID_WIDTH-1:0] id;         // Transaction ID
    logic [AXI_ADDR_WIDTH-1:0] addr;     // Address for the transaction
    logic [7:0] len;                     // Burst length
    logic [2:0] size;                    // Burst size
    logic valid;                         // Indicates if the entry is valid (turned to 0 once transaction has been processed )
  } transaction_t;

  transaction_t transaction_fifo[FIFO_DEPTH];
  logic [$clog2(FIFO_DEPTH)-1:0] fifo_wr_ptr, fifo_rd_ptr;
  logic fifo_empty, fifo_full;

  // AXI handshaking logic
  assign axi_master.aw_ready = dma_write_ctrl_ready && !fifo_full;
  assign dma_write_ctrl_valid = axi_master.aw_valid && !fifo_full;

  assign axi_master.w_ready = dma_write_chnl_ready;
  assign dma_write_chnl_valid = axi_master.w_valid;

  assign axi_master.ar_ready = dma_read_ctrl_ready && !fifo_full;
  assign dma_read_ctrl_valid = axi_master.ar_valid && !fifo_full;

  assign axi_master.r_valid = dma_read_chnl_valid;
  assign dma_read_chnl_ready = axi_master.r_ready;

  // State machine to handle transactions
  typedef enum logic [1:0] {
    IDLE,
    AXI_READ_DATA,
    AXI_WRITE_DATA,
    RESPONSE
  } state_t;

  state_t state, next_state;

  logic [31:0] beat_counter;

  // Sequential logic for state transitions
  always_ff @(posedge clk or posedge rst) begin

    if (rst) begin

      state <= IDLE;

    end else begin

      state <= next_state;

    end

  end

  // FIFO logic
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin

      fifo_wr_ptr <= 0;
      fifo_rd_ptr <= 0;
      fifo_empty  <= 1;
      fifo_full   <= 0;

      for (int i = 0; i < FIFO_DEPTH; i++) begin
        transaction_fifo[i].valid <= 1'b0;
      end

    end else begin

      // Capture write transactions (AW channel) and store them in the FIFO
      if (axi_master.aw_valid && axi_master.aw_ready && !fifo_full) begin

        transaction_fifo[fifo_wr_ptr] = '{
          is_write: 1'b1,
          id: axi_master.aw_id,
          addr: axi_master.aw_addr,
          len: axi_master.aw_len,
          size: axi_master.aw_size,
          valid: 1'b1
        };
        fifo_wr_ptr <= fifo_wr_ptr + 1;
        fifo_empty  <= 0;
        if (fifo_wr_ptr + 1 == fifo_rd_ptr) fifo_full <= 1;

      end

      // Capture read transactions (AR channel) and store them in the FIFO
      if (axi_master.ar_valid && axi_master.ar_ready && !fifo_full) begin

        transaction_fifo[fifo_wr_ptr] = '{
          is_write: 1'b0,
          id: axi_master.ar_id,
          addr: axi_master.ar_addr,
          len: axi_master.ar_len,
          size: axi_master.ar_size,
          valid: 1'b1
        };
        fifo_wr_ptr <= fifo_wr_ptr + 1;                           
        fifo_empty  <= 0;
        if (fifo_wr_ptr + 1 == fifo_rd_ptr) fifo_full <= 1;

      end

      // Update the read pointer and clear the valid bit when a write transaction is completed
      if (state == RESPONSE && axi_master.b_ready) begin

        transaction_fifo[fifo_rd_ptr].valid <= 1'b0;
        fifo_rd_ptr <= fifo_rd_ptr + 1;
        fifo_full   <= 0;
        if (fifo_rd_ptr + 1 == fifo_wr_ptr) fifo_empty <= 1;

      end

      // Update the read pointer for read transactions when the last beat is processed
      if (state == AXI_READ_DATA && axi_master.r_ready && dma_read_chnl_valid && axi_master.r_last) begin

        transaction_fifo[fifo_rd_ptr].valid <= 1'b0;
        fifo_rd_ptr <= fifo_rd_ptr + 1;
        fifo_full   <= 0;
        if (fifo_rd_ptr + 1 == fifo_wr_ptr) fifo_empty <= 1;

      end

    end

  end

  // Combinational logic for state transitions and output control
  always_comb begin
    // Default values
    next_state = state;

    case (state)

      IDLE: begin

        beat_counter = 32'h0;
        axi_master.b_valid = 1'b0;
        axi_master.r_last = 1'b0;

        if (!fifo_empty && transaction_fifo[fifo_rd_ptr].valid) begin

          if (transaction_fifo[fifo_rd_ptr].is_write) begin

            // Start processing write transaction
            dma_write_ctrl_data_index = transaction_fifo[fifo_rd_ptr].addr;
            dma_write_ctrl_data_length = transaction_fifo[fifo_rd_ptr].len;
            dma_write_ctrl_data_size = transaction_fifo[fifo_rd_ptr].size;
            next_state = AXI_WRITE_DATA;

          end else begin

            // Start processing read transaction
            dma_read_ctrl_data_index = transaction_fifo[fifo_rd_ptr].addr;
            dma_read_ctrl_data_length = transaction_fifo[fifo_rd_ptr].len;
            dma_read_ctrl_data_size = transaction_fifo[fifo_rd_ptr].size;
            next_state = AXI_READ_DATA;

          end

        end

      end

      AXI_READ_DATA: begin

        if (axi_master.r_ready && dma_read_chnl_valid) begin

          axi_master.r_data = dma_read_chnl_data;
          axi_master.r_id = transaction_fifo[fifo_rd_ptr].id; // Return the ID for read response
          beat_counter = beat_counter + 1;

          if (beat_counter == transaction_fifo[fifo_rd_ptr].len) begin
            axi_master.r_last = 1'b1;
            next_state = IDLE;

          end

        end

      end

      AXI_WRITE_DATA: begin

        if (axi_master.w_valid && dma_write_chnl_ready) begin

          // Apply strobe to the data
          for (int i = 0; i < AXI_DATA_WIDTH/8; i++) begin

            if (axi_master.w_strb[i]) begin

              dma_write_chnl_data[i*8 +: 8] = axi_master.w_data[i*8 +: 8];

            end else begin

              dma_write_chnl_data[i*8 +: 8] = 8'h00; // Mask the invalid bytes

            end

          end

          beat_counter = beat_counter + 1;

          if (beat_counter == transaction_fifo[fifo_rd_ptr].len) begin

            axi_master.w_last = 1'b1;
            next_state = RESPONSE;

          end

        end

      end

      RESPONSE: begin

        axi_master.w_last = 1'b0;
        axi_master.b_valid = 1'b1;
        axi_master.b_id = transaction_fifo[fifo_rd_ptr].id; // Return the ID for write response

        if (axi_master.b_ready) begin

          next_state = IDLE;

        end

      end

    endcase
    
  end

endmodule
