//`include "/home/eugenio/pulp_cluster/packages/pulp_cluster_package.sv"

module pulp_cluster_rtl_basic_dma64 
  import pulp_cluster_package::*;
  (
  input logic clk,
  input logic rst,

  // Configuration Registers
  input logic [31:0] conf_info_reg1,
  input logic [31:0] conf_info_reg3,
  input logic [31:0] conf_info_reg2,
  input logic conf_done,

  // DMA Read Control Interface
  output logic dma_read_ctrl_valid,
  output logic [31:0] dma_read_ctrl_data_index,
  output logic [31:0] dma_read_ctrl_data_length,
  output logic [2:0] dma_read_ctrl_data_size,
  input logic dma_read_ctrl_ready,

  // DMA Read Channel Interface
  input logic dma_read_chnl_valid,
  input logic [63:0] dma_read_chnl_data,
  output logic dma_read_chnl_ready,

  // DMA Write Control Interface
  output logic dma_write_ctrl_valid,
  output logic [31:0] dma_write_ctrl_data_index,
  output logic [31:0] dma_write_ctrl_data_length,
  output logic [2:0] dma_write_ctrl_data_size,
  input logic dma_write_ctrl_ready,

  // DMA Write Channel Interface
  output logic dma_write_chnl_valid,
  output logic [63:0] dma_write_chnl_data,
  input logic dma_write_chnl_ready,

  // Accelerator Control
  output logic acc_done,
  output logic [31:0] debug
);


  localparam AxiAw  = 32; //originally 48
  localparam AxiDw  = 64;
  localparam AxiIw  = 6;
  localparam NMst   = 1;
  localparam NSlv   = 3;
  localparam AxiIwMst = AxiIw + $clog2(NMst);
  localparam AxiWideBeWidth = AxiDw/8;
  localparam AxiWideByteOffset = $clog2(AxiWideBeWidth);
  localparam AxiUw = 10;
  localparam AXI_USER_WIDTH = 0;
  localparam int unsigned AXI_STRB_WIDTH = AxiDw / 8;

  localparam bit[AxiAw-1:0] ClustBase       = 'h50000000;
  localparam bit[AxiAw-1:0] ClustPeriphOffs = 'h00200000;
  localparam bit[AxiAw-1:0] ClustExtOffs    = 'h00400000;
  localparam bit[      5:0] ClustIdx        = 'h1;
  localparam bit[AxiAw-1:0] ClustBaseAddr   = ClustBase;
  localparam bit[AxiAw-1:0] L2BaseAddr      = 'h78000000;
  localparam bit[AxiAw-1:0] L2Size          = 'h10000000;
  localparam bit[AxiAw-1:0] BootAddr        = L2BaseAddr + 'h8080;
  localparam bit[AxiAw-1:0] ClustReturnInt  = 'h50200100; 


  logic s_cluster_en_sa_boot ;
  logic s_cluster_fetch_en   ;
  logic s_cluster_eoc        ;
  logic s_cluster_busy       ;


  AXI_BUS #(
      .AXI_ADDR_WIDTH( AxiAw   ),
      .AXI_DATA_WIDTH( AxiDw   ),
      .AXI_ID_WIDTH  ( AxiIw   ),
      .AXI_USER_WIDTH( AxiUw   )
  ) soc_to_cluster_axi_bus();

  AXI_BUS #(
      .AXI_ADDR_WIDTH( AxiAw ),
      .AXI_DATA_WIDTH( AxiDw ),
      .AXI_ID_WIDTH  ( AxiIw ),
      .AXI_USER_WIDTH( AxiUw )
  ) axi_slave();

  AXI_BUS_ASYNC_GRAY #(
     .AXI_ADDR_WIDTH ( AxiAw   ),
     .AXI_DATA_WIDTH ( AxiDw   ),
     .AXI_ID_WIDTH   ( AxiIw   ),
     .AXI_USER_WIDTH ( AxiUw   ),
     .LOG_DEPTH      ( 3       )
  ) async_soc_to_cluster_axi_bus();

  AXI_BUS_ASYNC_GRAY #(
     .AXI_ADDR_WIDTH ( AxiAw ),
     .AXI_DATA_WIDTH ( AxiDw ),
     .AXI_ID_WIDTH   ( AxiIw ),
     .AXI_USER_WIDTH ( AxiUw ),
     .LOG_DEPTH      ( 3     )
  ) async_cluster_to_soc_axi_bus();

  axi_cdc_src_intf   #(
    .AXI_ADDR_WIDTH ( AxiAw   ),
    .AXI_DATA_WIDTH ( AxiDw   ),
    .AXI_ID_WIDTH   ( AxiIw-2 ),
    .AXI_USER_WIDTH ( AxiUw   ),
    .LOG_DEPTH      ( 3       )
  ) soc_to_cluster_src_cdc_fifo_i  (
      .src_clk_i  ( s_clk                        ),
      .src_rst_ni ( s_rstn                       ),
      .src        ( soc_to_cluster_axi_bus       ),
      .dst        ( async_soc_to_cluster_axi_bus )
      );

  axi_cdc_dst_intf   #(
    .AXI_ADDR_WIDTH ( AxiAw ),
    .AXI_DATA_WIDTH ( AxiDw ),
    .AXI_ID_WIDTH   ( AxiIw ),
    .AXI_USER_WIDTH ( AxiUw ),
    .LOG_DEPTH      ( 3     )
    ) cluster_to_soc_dst_cdc_fifo_i (
      .dst_clk_i  ( s_clk                        ),
      .dst_rst_ni ( s_rstn                       ),
      .src        ( async_cluster_to_soc_axi_bus ),
      .dst        ( axi_slave                    )
      );




  localparam pulp_cluster_cfg_t PulpClusterCfg = '{
    CoreType: pulp_cluster_package::RISCY,
    NumCores: 8,
    DmaNumPlugs: 4,
    DmaNumOutstandingBursts: 8,
    DmaBurstLength: 256,
    NumMstPeriphs: 1,
    NumSlvPeriphs: 12,
    ClusterAlias: 1,
    ClusterAliasBase: 'h0,
    NumSyncStages: 3,
    UseHci: 1,
    TcdmSize: 128*1024,
    TcdmNumBank: 16,
    HwpePresent: 1,
    HwpeCfg: '{NumHwpes: 3, HwpeList: {SOFTEX, NEUREKA, REDMULE}},
    HwpeNumPorts: 9,
    iCacheNumBanks: 2,
    iCacheNumLines: 1,
    iCacheNumWays: 4,
    iCacheSharedSize: 4*1024,
    iCachePrivateSize: 512,
    iCachePrivateDataWidth: 32,
    EnableReducedTag: 1,
    L2Size: 1000*1024,
    DmBaseAddr: 'h60203000,
    BootRomBaseAddr: BootAddr,
    BootAddr: BootAddr,
    EnablePrivateFpu: 1,
    EnablePrivateFpDivSqrt: 0,
    EnableSharedFpu: 0,
    EnableSharedFpDivSqrt: 0,
    NumSharedFpu: 0,
    NumAxiIn: NumAxiSubordinatePorts,
    NumAxiOut: NumAxiManagerPorts,
    AxiIdInWidth: AxiIw-2,
    AxiIdOutWidth:AxiIw,
    AxiAddrWidth: AxiAw,
    AxiDataInWidth: AxiDw,
    AxiDataOutWidth: AxiDw,
    AxiUserWidth: AxiUw,
    AxiMaxInTrans: 64,
    AxiMaxOutTrans: 64,
    AxiCdcLogDepth: 3,
    AxiCdcSyncStages: 3,
    SyncStages: 3,
    ClusterBaseAddr: ClustBaseAddr,
    ClusterPeriphOffs: ClustPeriphOffs,
    ClusterExternalOffs: ClustExtOffs,
    EnableRemapAddress: 0,
    default: '0
  };

  pulp_cluster #(
    .Cfg ( PulpClusterCfg )
   ) cluster_i (
    .clk_i                       ( clk                                  ),
    .rst_ni                      ( rst                                  ),
    .pwr_on_rst_ni               (                                      ),
    .ref_clk_i                   (                                      ),
    .axi_isolate_i               ( '0                                   ),
    .axi_isolated_o              (                                      ),
    .pmu_mem_pwdn_i              ( 1'b0                                 ), 
    .base_addr_i                 (                                      ),
    .dma_pe_evt_ack_i            ( '1                                   ),
    .dma_pe_evt_valid_o          (                                      ),
    .dma_pe_irq_ack_i            ( 1'b1                                 ),
    .dma_pe_irq_valid_o          (                                      ),
    .dbg_irq_valid_i             ( '0                                   ),
    .mbox_irq_i                  ( '0                                   ),
    .pf_evt_ack_i                ( 1'b1                                 ),
    .pf_evt_valid_o              (                                      ),
    .async_cluster_events_wptr_i ( '0                                   ),
    .async_cluster_events_rptr_o (                                      ),
    .async_cluster_events_data_i ( '0                                   ),
    .en_sa_boot_i                ( s_cluster_en_sa_boot                 ),
    .test_mode_i                 ( 1'b0                                 ),
    .fetch_en_i                  ( s_cluster_fetch_en                   ),
    .eoc_o                       ( s_cluster_eoc                        ),
    .busy_o                      ( s_cluster_busy                       ),
    .cluster_id_i                (                                      ),

    .async_data_master_aw_wptr_o ( async_cluster_to_soc_axi_bus.aw_wptr ),
    .async_data_master_aw_rptr_i ( async_cluster_to_soc_axi_bus.aw_rptr ),
    .async_data_master_aw_data_o ( async_cluster_to_soc_axi_bus.aw_data ),
    .async_data_master_ar_wptr_o ( async_cluster_to_soc_axi_bus.ar_wptr ),
    .async_data_master_ar_rptr_i ( async_cluster_to_soc_axi_bus.ar_rptr ),
    .async_data_master_ar_data_o ( async_cluster_to_soc_axi_bus.ar_data ),
    .async_data_master_w_data_o  ( async_cluster_to_soc_axi_bus.w_data  ),
    .async_data_master_w_wptr_o  ( async_cluster_to_soc_axi_bus.w_wptr  ),
    .async_data_master_w_rptr_i  ( async_cluster_to_soc_axi_bus.w_rptr  ),
    .async_data_master_r_wptr_i  ( async_cluster_to_soc_axi_bus.r_wptr  ),
    .async_data_master_r_rptr_o  ( async_cluster_to_soc_axi_bus.r_rptr  ),
    .async_data_master_r_data_i  ( async_cluster_to_soc_axi_bus.r_data  ),
    .async_data_master_b_wptr_i  ( async_cluster_to_soc_axi_bus.b_wptr  ),
    .async_data_master_b_rptr_o  ( async_cluster_to_soc_axi_bus.b_rptr  ),
    .async_data_master_b_data_i  ( async_cluster_to_soc_axi_bus.b_data  ),

    .async_data_slave_aw_wptr_i  ( async_soc_to_cluster_axi_bus.aw_wptr ),
    .async_data_slave_aw_rptr_o  ( async_soc_to_cluster_axi_bus.aw_rptr ),
    .async_data_slave_aw_data_i  ( async_soc_to_cluster_axi_bus.aw_data ),
    .async_data_slave_ar_wptr_i  ( async_soc_to_cluster_axi_bus.ar_wptr ),
    .async_data_slave_ar_rptr_o  ( async_soc_to_cluster_axi_bus.ar_rptr ),
    .async_data_slave_ar_data_i  ( async_soc_to_cluster_axi_bus.ar_data ),
    .async_data_slave_w_data_i   ( async_soc_to_cluster_axi_bus.w_data  ),
    .async_data_slave_w_wptr_i   ( async_soc_to_cluster_axi_bus.w_wptr  ),
    .async_data_slave_w_rptr_o   ( async_soc_to_cluster_axi_bus.w_rptr  ),
    .async_data_slave_r_wptr_o   ( async_soc_to_cluster_axi_bus.r_wptr  ),
    .async_data_slave_r_rptr_i   ( async_soc_to_cluster_axi_bus.r_rptr  ),
    .async_data_slave_r_data_o   ( async_soc_to_cluster_axi_bus.r_data  ),
    .async_data_slave_b_wptr_o   ( async_soc_to_cluster_axi_bus.b_wptr  ),
    .async_data_slave_b_rptr_i   ( async_soc_to_cluster_axi_bus.b_rptr  ),
    .async_data_slave_b_data_o   ( async_soc_to_cluster_axi_bus.b_data  )
  );


  // Instantiate the AXI-to-DMA FIFO module
  axi2dmafifo #(
    .AXI_ADDR_WIDTH     (32      ),
    .AXI_DATA_WIDTH     (64      ),
    .AXI_ID_WIDTH       (4       ),
    .AXI_USER_WIDTH     (8       ),
    .FIFO_DEPTH         (4       )
  ) axi2dmafifo_o (
    .clk                         ( clk                                  ),
    .rst                         ( rst                                  ),

    .axi_master                  ( axi_slave                            ),

    .dma_read_ctrl_valid         ( dma_read_ctrl_valid                  ),
    .dma_read_ctrl_data_index    ( dma_read_ctrl_data_index             ),
    .dma_read_ctrl_data_length   ( dma_read_ctrl_data_length            ),
    .dma_read_ctrl_data_size     ( dma_read_ctrl_data_size              ),
    .dma_read_ctrl_ready         ( dma_read_ctrl_ready                  ),

    .dma_read_chnl_valid         ( dma_read_chnl_valid                  ),
    .dma_read_chnl_data          ( dma_read_chnl_data                   ),
    .dma_read_chnl_ready         ( dma_read_chnl_ready                  ),

    .dma_write_ctrl_valid        ( dma_write_ctrl_valid                 ),
    .dma_write_ctrl_data_index   ( dma_write_ctrl_data_index            ),
    .dma_write_ctrl_data_length  ( dma_write_ctrl_data_length           ),
    .dma_write_ctrl_data_size    ( dma_write_ctrl_data_size             ),
    .dma_write_ctrl_ready        ( dma_write_ctrl_ready                 ),

    .dma_write_chnl_valid        (dma_write_chnl_valid                  ),
    .dma_write_chnl_data         ( dma_write_chnl_data                  ),
    .dma_write_chnl_ready        ( dma_write_chnl_ready                 )
  );


  // Instantiate the Cluster Control module
  cluster_control cluster_control_inst (
    .clk                         ( clk                                  ),
    .rst_n                       ( ~rst                                 ),
    .conf_done                   ( conf_done                            ),
    .reg_0                       ( conf_info_reg1                       ),
    .reg_1                       ( conf_info_reg2                       ),
    .reg_2                       ( conf_info_reg3                       ),
    .reg_3                       (                                      ), 
    .target_addresses            ( target_addresses                     ),
    .fetch_enable                ( s_cluster_fetch_en                   ),
    .boot_enable                 ( s_cluster_en_sa_boot                 ),
    .acc_done                    ( acc_done                             ),

    .axi_slave                   ( soc_to_cluster_axi_bus               ),
    .eoc                         ( s_cluster_eoc                        )
  );


endmodule
