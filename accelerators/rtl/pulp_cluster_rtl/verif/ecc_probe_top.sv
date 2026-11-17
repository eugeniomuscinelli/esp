// ECC elaboration probe (plan Step 3.4 / Risk R2 / Open Question 2).
//
// Purpose: elaborate the UNMODIFIED pulp_cluster - including the hard-instantiated
// hci_ecc_interconnect and ECC TCDM banks - with the bring-up configuration this
// integration will use, on the exact QuestaSim version of this installation.
// This is a pure elaboration target: no stimulus, all inputs left unconnected.
//
// The configuration mirrors the reference integration's wrapper Cfg
// (esp_first_pulp_integration .../pulp_cluster_rtl_basic_dma64.sv:222-273) with the
// planned bring-up deltas: HwpePresent=0, HwpeNumPorts=0 (HWPEs re-enabled at
// validation rung 5). Note UseHci=1 and !HwpePresent both select the
// hci_ecc_interconnect branch in rtl/cluster_interconnect_wrap.sv, so this probe
// does exercise the ECC interconnect and the ECC TCDM path.

module ecc_probe_top;

  import pulp_cluster_package::*;

  localparam logic [31:0] BootAddr = 32'hA010B700; // L2 base 0xA0103680 + 0x8080

  localparam pulp_cluster_cfg_t Cfg = '{
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
    AxiIdInWidth: 6,
    AxiIdOutWidth: 6,
    AxiAddrWidth: 32,
    AxiDataInWidth: 64,
    AxiDataOutWidth: 64,
    AxiUserWidth: 10,
    AxiMaxInTrans: 64,
    AxiMaxOutTrans: 64,
    AxiCdcLogDepth: 3,
    AxiCdcSyncStages: 3,
    SyncStages: 3,
    ClusterBaseAddr: 'h50000000,
    ClusterPeriphOffs: 'h00200000,
    ClusterExternalOffs: 'h00400000,
    EnableRemapAddress: 0,
    default: '0
  };

  pulp_cluster #(.Cfg(Cfg)) dut ();

endmodule
