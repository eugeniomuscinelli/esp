module axitrafficgen_rtl_basic_dma64 (
    input logic clk,
    input logic rst,
    
    /* <<--params-def-->> */
    input logic [31:0] conf_info_reg1,
    input logic [31:0] conf_info_reg2,
    input logic conf_done,

    input logic dma_read_ctrl_ready,
    output logic dma_read_ctrl_valid,
    output logic [31:0] dma_read_ctrl_data_index,
    output logic [31:0] dma_read_ctrl_data_length,
    output logic [2:0] dma_read_ctrl_data_size,

    output logic dma_read_chnl_ready,
    input logic dma_read_chnl_valid,
    input logic [63:0] dma_read_chnl_data,

    input logic dma_write_ctrl_ready,
    output logic dma_write_ctrl_valid,
    output logic [31:0] dma_write_ctrl_data_index,
    output logic [31:0] dma_write_ctrl_data_length,
    output logic [2:0] dma_write_ctrl_data_size,

    input logic dma_write_chnl_ready,
    output logic dma_write_chnl_valid,
    output logic [63:0] dma_write_chnl_data,

    output logic acc_done,
    output logic [31:0] debug
);




  // AXI Master Interface
  AXI_BUS.Master axi_master();

  // Instantiate the axi2dmafifo module
  axi2dmafifo #(
    .AXI_ADDR_WIDTH ( 32 ),
    .AXI_DATA_WIDTH ( 64 ),
    .AXI_ID_WIDTH   (  4 ),
    .AXI_USER_WIDTH (  8 ),
    .FIFO_DEPTH     (  4 )
  ) axi2dmafifo_inst (
    .clk                        (clk                        ),
    .rst                        (rst                        ),
    .axi_master                 (axi_master                 ),
    .dma_read_ctrl_valid        (dma_read_ctrl_valid        ),
    .dma_read_ctrl_data_index   (dma_read_ctrl_data_index   ),
    .dma_read_ctrl_data_length  (dma_read_ctrl_data_length  ),
    .dma_read_ctrl_data_size    (dma_read_ctrl_data_size    ),
    .dma_read_ctrl_ready        (dma_read_ctrl_ready        ),
    .dma_read_chnl_valid        (dma_read_chnl_valid        ),
    .dma_read_chnl_data         (dma_read_chnl_data         ),
    .dma_read_chnl_ready        (dma_read_chnl_ready        ),
    .dma_write_ctrl_valid       (dma_write_ctrl_valid       ),
    .dma_write_ctrl_data_index  (dma_write_ctrl_data_index  ),
    .dma_write_ctrl_data_length (dma_write_ctrl_data_length ),
    .dma_write_ctrl_data_size   (dma_write_ctrl_data_size   ),
    .dma_write_ctrl_ready       (dma_write_ctrl_ready       ),
    .dma_write_chnl_valid       (dma_write_chnl_valid       ),
    .dma_write_chnl_data        (dma_write_chnl_data        ),
    .dma_write_chnl_ready       (dma_write_chnl_ready       )
  );


  /* 
    logic acc_done_reg;

    // Assignments
    assign dma_read_ctrl_valid = 1'b0;
    assign dma_read_chnl_ready = 1'b1;
    assign dma_write_ctrl_valid = 1'b0;
    assign dma_write_chnl_valid = 1'b0;
    assign debug = 32'd0;
    assign acc_done = conf_done;         */

endmodule
