// pulp_cluster_rtl_basic_dma64: ESP RTL-flow accelerator wrapper embedding the
// PULP cluster (dma64 design point).
//
// Port of the reference integration's wrapper
// (esp_first_pulp_integration .../pulp_cluster_rtl_basic_dma64.sv) with:
//   - un-renamed IPs (pulp_cluster, axi_cdc_*_intf, axi_xbar_intf, mock_uart_axi -
//     library isolation replaces the old pulp_ prefixing, see report Step 1/5);
//   - the reworked bridge modules (axi2dmafifo, cluster_control) and the new
//     boot_offset register semantics;
//   - bring-up cluster configuration: RISCY x8, 128 KiB/16-bank ECC TCDM,
//     unmodified ECC HCI (probe-validated), HWPEs disabled (re-enabled at
//     validation rung 5);
//   - single-sourced address constants (L2BaseAddr feeds the xbar rule, the
//     translator BASE_ADDR, cluster_control L2_BASE_ADDR and the cluster
//     BootRom/Boot addresses - four-constant invariant, risk R7).
//
// Topology:
//   ESP socket conf/dma channels
//     - cluster_control (AXI master) -> axi_cdc_src -> cluster AXI slave (boot regs)
//     - cluster AXI master -> axi_cdc_dst -> axi_xbar 1x2:
//         rule 0x03002000-0x03003000 -> mock_uart_axi (printf, simulation sink)
//         rule [L2BaseAddr, +L2Size) + default -> axi2dmafifo -> ESP DMA channels

module pulp_cluster_rtl_basic_dma64
  import pulp_cluster_package::*;
(
  input  logic clk,
  input  logic rst,   // active-low (ESP socket reset)

  // Configuration registers (per hw/pulp_cluster.xml: boot_offset/spare0/spare1)
  input  logic [31:0] conf_info_boot_offset,
  input  logic [31:0] conf_info_spare0,
  input  logic [31:0] conf_info_spare1,
  input  logic conf_done,

  // DMA read control
  output logic        dma_read_ctrl_valid,
  output logic [31:0] dma_read_ctrl_data_index,
  output logic [31:0] dma_read_ctrl_data_length,
  output logic [2:0]  dma_read_ctrl_data_size,
  // multiOT socket extension: request tag, echoed on the data channel
  output logic [3:0]  dma_read_ctrl_data_tag,
  input  logic        dma_read_ctrl_ready,

  // DMA read channel
  input  logic        dma_read_chnl_valid,
  input  logic [63:0] dma_read_chnl_data,
  // multiOT socket extension: tag echo + last-beat marker of the request
  input  logic [3:0]  dma_read_chnl_tag,
  input  logic        dma_read_chnl_last,
  output logic        dma_read_chnl_ready,

  // DMA write control
  output logic        dma_write_ctrl_valid,
  output logic [31:0] dma_write_ctrl_data_index,
  output logic [31:0] dma_write_ctrl_data_length,
  output logic [2:0]  dma_write_ctrl_data_size,
  input  logic        dma_write_ctrl_ready,

  // DMA write channel
  output logic        dma_write_chnl_valid,
  output logic [63:0] dma_write_chnl_data,
  input  logic        dma_write_chnl_ready,

  // P2P/multicast user fields (unused)
  output logic [5:0] dma_write_ctrl_data_user,
  output logic [5:0] dma_read_ctrl_data_user,

  // Accelerator control
  output logic acc_done,
  output logic [31:0] debug
);

  assign dma_write_ctrl_data_user = 6'b0;
  assign dma_read_ctrl_data_user  = 6'b0;

  // ---------------------------------------------------------------------------
  // Geometry and address map
  // ---------------------------------------------------------------------------
  localparam int unsigned AxiAw = 32;
  localparam int unsigned AxiDw = 64;
  localparam int unsigned AxiIw = 6;
  localparam int unsigned AxiUw = 10;
  localparam int unsigned NMst  = 1;                     // xbar slave ports
  localparam int unsigned NSlv  = 2;                     // xbar master ports
  localparam int unsigned AxiIwMst = AxiIw + $clog2(NMst);
  localparam int unsigned CdcLogDepth = 3;

  localparam logic [AxiAw-1:0] ClustBase       = 'h5000_0000;
  localparam logic [AxiAw-1:0] ClustPeriphOffs = 'h0020_0000;
  localparam logic [AxiAw-1:0] ClustExtOffs    = 'h0040_0000;
  localparam logic [5:0]       ClustIdx        = 'h1;
  // The cluster-visible L2 window == the ESP accelerator's virtualized DMA buffer.
  // MUST equal the software BASE_ADDRESS and the pulp-runtime linker L2 ORIGIN
  // (checked by scripts/check_constants.sh).
  localparam logic [AxiAw-1:0] L2BaseAddr      = 'hA010_3680;
  localparam logic [AxiAw-1:0] L2Size          = 'h0030_0000;
  localparam logic [AxiAw-1:0] UartBase        = 'h0300_2000;
  localparam logic [AxiAw-1:0] UartSize        = 'h0000_1000;
  // Default boot entry: pulp-runtime _start (vectors at L2+0x8000, entry +0x80).
  // The runtime value is L2BaseAddr + conf_info_boot_offset (cluster_control).
  localparam logic [AxiAw-1:0] BootAddr        = L2BaseAddr + 'h8080;

  // Bring-up cluster configuration (probe-validated, see verif/ecc_probe_top.sv)
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
    HwpePresent: 0,
    HwpeCfg: '{NumHwpes: 0, HwpeList: '0},
    HwpeNumPorts: 0,
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
    AxiIdInWidth: AxiIw,
    AxiIdOutWidth: AxiIw,
    AxiAddrWidth: AxiAw,
    AxiDataInWidth: AxiDw,
    AxiDataOutWidth: AxiDw,
    AxiUserWidth: AxiUw,
    AxiMaxInTrans: 64,
    AxiMaxOutTrans: 64,
    AxiCdcLogDepth: CdcLogDepth,
    AxiCdcSyncStages: 3,
    SyncStages: 3,
    ClusterBaseAddr: ClustBase,
    ClusterPeriphOffs: ClustPeriphOffs,
    ClusterExternalOffs: ClustExtOffs,
    EnableRemapAddress: 0,
    default: '0
  };

  logic s_cluster_en_sa_boot;
  logic s_cluster_fetch_en;
  logic s_cluster_eoc;
  logic s_cluster_busy;

  // ---------------------------------------------------------------------------
  // Buses and clock-domain crossings (single clock here: both CDC halves run on
  // the tile clock; the cluster's ports are natively asynchronous gray-pointer
  // bundles, so the CDCs are mandatory adapters)
  // ---------------------------------------------------------------------------
  AXI_BUS #(
    .AXI_ADDR_WIDTH(AxiAw), .AXI_DATA_WIDTH(AxiDw),
    .AXI_ID_WIDTH(AxiIw), .AXI_USER_WIDTH(AxiUw)
  ) soc_to_cluster_axi_bus ();

  AXI_BUS #(
    .AXI_ADDR_WIDTH(AxiAw), .AXI_DATA_WIDTH(AxiDw),
    .AXI_ID_WIDTH(AxiIw), .AXI_USER_WIDTH(AxiUw)
  ) axi_slave [NMst-1:0] ();

  AXI_BUS_ASYNC_GRAY #(
    .AXI_ADDR_WIDTH(AxiAw), .AXI_DATA_WIDTH(AxiDw),
    .AXI_ID_WIDTH(AxiIw), .AXI_USER_WIDTH(AxiUw), .LOG_DEPTH(CdcLogDepth)
  ) async_soc_to_cluster_axi_bus ();

  AXI_BUS_ASYNC_GRAY #(
    .AXI_ADDR_WIDTH(AxiAw), .AXI_DATA_WIDTH(AxiDw),
    .AXI_ID_WIDTH(AxiIw), .AXI_USER_WIDTH(AxiUw), .LOG_DEPTH(CdcLogDepth)
  ) async_cluster_to_soc_axi_bus ();

  axi_cdc_src_intf #(
    .AXI_ADDR_WIDTH(AxiAw), .AXI_DATA_WIDTH(AxiDw),
    .AXI_ID_WIDTH(AxiIw), .AXI_USER_WIDTH(AxiUw), .LOG_DEPTH(CdcLogDepth)
  ) soc_to_cluster_src_cdc_fifo_i (
    .src_clk_i  ( clk                          ),
    .src_rst_ni ( rst                          ),
    .src        ( soc_to_cluster_axi_bus       ),
    .dst        ( async_soc_to_cluster_axi_bus )
  );

  axi_cdc_dst_intf #(
    .AXI_ADDR_WIDTH(AxiAw), .AXI_DATA_WIDTH(AxiDw),
    .AXI_ID_WIDTH(AxiIw), .AXI_USER_WIDTH(AxiUw), .LOG_DEPTH(CdcLogDepth)
  ) cluster_to_soc_dst_cdc_fifo_i (
    .dst_clk_i  ( clk                          ),
    .dst_rst_ni ( rst                          ),
    .src        ( async_cluster_to_soc_axi_bus ),
    .dst        ( axi_slave[0]                 )
  );

  // ---------------------------------------------------------------------------
  // Local crossbar: cluster master -> {axi2dmafifo (L2 window, default), mock UART}
  // ---------------------------------------------------------------------------
  AXI_BUS #(
    .AXI_ADDR_WIDTH(AxiAw), .AXI_DATA_WIDTH(AxiDw),
    .AXI_ID_WIDTH(AxiIwMst), .AXI_USER_WIDTH(AxiUw)
  ) axi_master [NSlv-1:0] ();

  mock_uart_axi #(
    .AxiIw ( AxiIwMst ),
    .AxiAw ( AxiAw    ),
    .AxiDw ( AxiDw    ),
    .AxiUw ( AxiUw    )
  ) i_mock_uart (
    .clk_i  ( clk           ),
    .rst_ni ( rst           ),
    .test_i ( '0            ),
    .uart   ( axi_master[1] )
  );

  typedef axi_pkg::xbar_rule_32_t rule_t;
  rule_t [NSlv-1:0] addr_map;
  assign addr_map[0] = '{idx: 1, start_addr: UartBase,   end_addr: UartBase + UartSize};
  assign addr_map[1] = '{idx: 0, start_addr: L2BaseAddr, end_addr: L2BaseAddr + L2Size};

  localparam axi_pkg::xbar_cfg_t XbarCfg = '{
    NoSlvPorts:         NMst,
    NoMstPorts:         NSlv,
    MaxMstTrans:        8,
    MaxSlvTrans:        8,
    FallThrough:        1'b1,
    LatencyMode:        axi_pkg::NO_LATENCY,
    PipelineStages:     0,
    AxiIdWidthSlvPorts: AxiIw,
    AxiIdUsedSlvPorts:  AxiIw,
    UniqueIds:          1'b1,
    AxiAddrWidth:       AxiAw,
    AxiDataWidth:       AxiDw,
    NoAddrRules:        NSlv
  };

  axi_xbar_intf #(
    .AXI_USER_WIDTH ( AxiUw   ),
    .Cfg            ( XbarCfg ),
    .rule_t         ( rule_t  )
  ) i_xbar (
    .clk_i                 ( clk        ),
    .rst_ni                ( rst        ),
    .test_i                ( 1'b0       ),
    .slv_ports             ( axi_slave  ),
    .mst_ports             ( axi_master ),
    .addr_map_i            ( addr_map   ),
    .en_default_mst_port_i ( '1         ),  // everything unmapped -> port 0 (DMA);
    .default_mst_port_i    ( '0         )   // below-window addrs get SLVERR there
  );

  // ---------------------------------------------------------------------------
  // The PULP cluster
  // ---------------------------------------------------------------------------
  pulp_cluster #(
    .Cfg ( PulpClusterCfg )
  ) cluster_i (
    .clk_i                       ( clk                  ),
    .rst_ni                      ( rst                  ),
    .pwr_on_rst_ni               ( rst                  ),
    .ref_clk_i                   ( clk                  ),
    .axi_isolate_i               ( '0                   ),
    .axi_isolated_o              (                      ),
    .pmu_mem_pwdn_i              ( 1'b0                 ),
    .base_addr_i                 ( ClustBase[31:28]     ),
    .dma_pe_evt_ack_i            ( '1                   ),
    .dma_pe_evt_valid_o          (                      ),
    .dma_pe_irq_ack_i            ( 1'b1                 ),
    .dma_pe_irq_valid_o          (                      ),
    .dbg_irq_valid_i             ( '0                   ),
    .mbox_irq_i                  ( '0                   ),
    .pf_evt_ack_i                ( 1'b1                 ),
    .pf_evt_valid_o              (                      ),
    .async_cluster_events_wptr_i ( '0                   ),
    .async_cluster_events_rptr_o (                      ),
    .async_cluster_events_data_i ( '0                   ),
    .en_sa_boot_i                ( s_cluster_en_sa_boot ),
    .test_mode_i                 ( 1'b0                 ),
    .fetch_en_i                  ( s_cluster_fetch_en   ),
    .eoc_o                       ( s_cluster_eoc        ),
    .busy_o                      ( s_cluster_busy       ),
    .cluster_id_i                ( ClustIdx             ),

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

  // ---------------------------------------------------------------------------
  // Bridges to the ESP socket
  // ---------------------------------------------------------------------------
  axi2dmafifo #(
    .AXI_ADDR_WIDTH ( AxiAw      ),
    .AXI_DATA_WIDTH ( AxiDw      ),
    .AXI_ID_WIDTH   ( AxiIwMst   ),
    .AXI_USER_WIDTH ( AxiUw      ),
    .FIFO_DEPTH     ( 10         ),
    .BASE_ADDR      ( L2BaseAddr )
  ) axi2dmafifo_i (
    .clk    ( clk           ),
    .rst_ni ( rst           ),
    .axi_s  ( axi_master[0] ),

    .dma_read_ctrl_valid        ( dma_read_ctrl_valid        ),
    .dma_read_ctrl_data_index   ( dma_read_ctrl_data_index   ),
    .dma_read_ctrl_data_length  ( dma_read_ctrl_data_length  ),
    .dma_read_ctrl_data_size    ( dma_read_ctrl_data_size    ),
    .dma_read_ctrl_data_tag     ( dma_read_ctrl_data_tag     ),
    .dma_read_ctrl_ready        ( dma_read_ctrl_ready        ),
    .dma_read_chnl_valid        ( dma_read_chnl_valid        ),
    .dma_read_chnl_data         ( dma_read_chnl_data         ),
    .dma_read_chnl_tag          ( dma_read_chnl_tag          ),
    .dma_read_chnl_last         ( dma_read_chnl_last         ),
    .dma_read_chnl_ready        ( dma_read_chnl_ready        ),
    .dma_write_ctrl_valid       ( dma_write_ctrl_valid       ),
    .dma_write_ctrl_data_index  ( dma_write_ctrl_data_index  ),
    .dma_write_ctrl_data_length ( dma_write_ctrl_data_length ),
    .dma_write_ctrl_data_size   ( dma_write_ctrl_data_size   ),
    .dma_write_ctrl_ready       ( dma_write_ctrl_ready       ),
    .dma_write_chnl_valid       ( dma_write_chnl_valid       ),
    .dma_write_chnl_data        ( dma_write_chnl_data        ),
    .dma_write_chnl_ready       ( dma_write_chnl_ready       )
  );

  cluster_control #(
    .NUM_CORES           ( PulpClusterCfg.NumCores ),
    .CLUSTER_BASE_ADDR   ( ClustBase               ),
    .CLUSTER_PERIPH_OFFS ( ClustPeriphOffs         ),
    .BOOT_REG_OFFS       ( 32'h40                  ),
    .L2_BASE_ADDR        ( L2BaseAddr              )
  ) cluster_control_i (
    .clk           ( clk                    ),
    .rst_ni        ( rst                    ),
    .conf_done     ( conf_done              ),
    .boot_offset_i ( conf_info_boot_offset  ),
    .acc_done      ( acc_done               ),
    .fetch_enable  ( s_cluster_fetch_en     ),
    .boot_enable   ( s_cluster_en_sa_boot   ),
    .eoc           ( s_cluster_eoc          ),
    .axi_m         ( soc_to_cluster_axi_bus )
  );

  // Observability (spare registers reserved for future use)
  assign debug = {26'b0,
                  s_cluster_busy, s_cluster_eoc,
                  s_cluster_fetch_en, s_cluster_en_sa_boot,
                  conf_done, acc_done};

  // keep the spare register inputs referenced (lint)
  logic [63:0] unused_spare;
  assign unused_spare = {conf_info_spare0, conf_info_spare1};

endmodule
