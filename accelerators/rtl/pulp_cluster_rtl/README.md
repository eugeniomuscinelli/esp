# PULP Cluster as an ESP RTL-flow Accelerator (`pulp_cluster_rtl`)

A programmable 8-core RISC-V (RI5CY) PULP cluster integrated as a standard ESP
accelerator tile on the ESP DMA socket — **without renaming any PULP IP**: the whole
cluster and its 34 Bender-pinned dependencies compile into a dedicated HDL library
(`pulp_cluster_rtl`), isolated from the CVA6 core's same-named `common_cells`/`axi`/
`fpnew` copies in `work`.

Full design rationale, verification evidence, deviation log and risk register:
[`pulp_esp_integration_report.md`](pulp_esp_integration_report.md). The approved plan
lives at `~/pulp_esp_reintegration_plan.md` (out of tree).

## Layout

```
pulp_cluster_rtl/
├── hw/pulp_cluster.xml            # ESP descriptor: device_id 075, regs boot_offset/spare0/spare1
├── hw/src/pulp_cluster_rtl_basic_dma64/
│   ├── pulp_cluster_rtl_basic_dma64.sv   # wrapper: cluster + CDCs + xbar + bridges
│   ├── axi2dmafifo.sv                    # AXI4 slave -> ESP DMA protocol translator
│   └── cluster_control.sv                # conf_done/acc_done <-> boot protocol bridge
├── pulp_cluster_rtl.sverilog      # per-acc filelist (vendor/-relative; Bender-generated)
├── pulp_cluster_rtl.defines       # +define+ set, fed to ACC_MODELSIM_DEFS
├── scripts/gen_vendor.sh          # regenerates vendor/ + the two files above
├── scripts/check_constants.sh     # four-constant invariant check (make check)
├── patches/                       # minimal upstream-candidate fixes (applied by gen_vendor)
├── verif/                         # ECC elaboration probe + bridge-module TBs
├── sw/baremetal/                  # host app + program-image headers (+ rung-2 generator)
└── vendor/                        # GENERATED (gitignored): pulp_cluster @07988cd + 34 deps
```

## Address contract (the four-constant invariant)

The cluster sees main memory through a **virtual window** at `0xA0103680` (+3 MiB):
ESP's per-accelerator TLB maps window offsets to the host-allocated buffer, so no
physical address appears anywhere. Four constants must agree (checked by `make check`):
wrapper `L2BaseAddr` (single source for the RTL), every program header's
`BASE_ADDRESS`, the host app's `BOOT_OFFSET` (+0x8080 = pulp-runtime `_start`) vs. the
wrapper's `BootAddr`, and — when compiling new cluster programs — the pulp-runtime
`astral-cluster` linker `L2 ORIGIN`.

## Reproduce from a fresh clone

```sh
git clone <this fork> esp && cd esp && git checkout pulp-cluster-clean-integration
git submodule update --init rtl/cores/ariane/ariane
source /opt/cad/scripts/tools_env.sh          # choose questa (or PATH=/opt/cad/questa/bin:$PATH)
make -C accelerators/rtl/pulp_cluster_rtl vendor    # fetch cluster + 34 deps, regen filelist
make -C accelerators/rtl/pulp_cluster_rtl check     # four-constant invariant
cd socs/xilinx-vc707-xc7vx485t
make pulp_cluster_rtl-hls                     # install XML+RTL into tech/virtex7/acc
make esp-xconfig                              # HUMAN ACTION (GUI): 2x2; NoC widths 64/64;
                                              #   tiles: (0,0) mem, (0,1) cpu, (1,0) acc
                                              #   PULP_CLUSTER_RTL/basic_dma64, (1,1) IO
make pulp_cluster_rtl-baremetal               # build the host test program
TEST_PROGRAM=./soft-build/ariane/baremetal/pulp_cluster_rtl.exe make sim
# in vsim: run -all   (use `make sim-gui` for waveforms)
```

Use **`make sim`** — not `make qsim`: only the ModelSim/Questa flow in
`utils/make/modelsim.mk` has the per-accelerator library rules.

Optional module-level checks (no SoC needed): `make -C accelerators/rtl/pulp_cluster_rtl
bridge-tbs` (directed bridge TBs) and `... ecc-probe` (cluster elaboration probe).

## Selecting the cluster program

The host app embeds one program image header (`sw/baremetal/pulp_cluster.c`,
`HEADER_FILE`, default `rung2_smoke.h`):

| header | purpose | needs PULP toolchain? |
|---|---|---|
| `rung2_smoke.h` | memory-write smoke test, self-checking (`RUNG2 PASS/FAIL`) | no — hand-assembled RV32I (`gen_rung2_stimuli.py`) |
| `rung3_uart.h` | printf-path test: core 0 prints `RUNG3 OK` through the mock UART (`[TB UART]` transcript lines) | no — `gen_rung2_stimuli.py --uart` |
| `optmatmul_M8_8x8.h` | 8×8 parallel matmul benchmark, self-checking (`SUMMARY: SUCCESS`, prints cycle counts) | prebuilt (from the reference integration) |

(The reference tree's `stimuli.h` was **not** carried over: it is a sparse, unpadded
artifact whose core-0 control flow jumps through uninitialized data — see the report's
rung-3 analysis.)

**Compiling new cluster programs** requires the PULP-extended GCC
(`riscv32-unknown-elf-gcc` with `-march=rv32imcxgap9`; not installed on this machine)
plus pulp-runtime (branch `astral`, pin `3ba9a349`) with `kernel/chips/astral-cluster/
link.ld` `L2 ORIGIN` set to `0xA0103680` and the matching `memory_map.h` edits; then
ELF → `stim_utils.py` → `generate_padded_stimuli.py` (see
`/home/eugenio/cluster_test_generator`) → header. Set `PULP_RUNTIME=<path>` so
`make check` also validates the linker leg.

## Cluster configuration notes

Bring-up config (wrapper `PulpClusterCfg`): RI5CY ×8, 128 KiB/16-bank TCDM
(**bank ECC disabled** — `patches/pulp_cluster/0002`: with `HwpePresent=0`, a
combination upstream never simulates with ECC, the ECC bank path corrupts TCDM under
concurrent DMA+core stores; see the report's rung-4 analysis), **ECC HCI**
interconnect on, HMR unit present, HWPEs **disabled** (`HwpePresent=0`; the
`{REDMULE, NEUREKA, SOFTEX}` set compiles and is the validation-rung-5 re-enable,
which is also where TCDM ECC gets re-evaluated in its upstream-tested configuration).
The full-ECC configuration *elaborates* cleanly (ECC probe) — the historical Questa
"internal error" workaround is NOT what this patch is about.

Two vendored-RTL patches address `N_HWPE==0` deficiencies in the ECC HCI interconnect
(upstream never simulates that combination — its TB always has HWPEs): `patches/hci/0001`
gates out the dangling ECC-encode chain that otherwise fires ~5000 `HCI RQ-4` protocol
warnings and double-drives the memory response signals; `patches/pulp_cluster/0002`
disables TCDM bank ECC (the no-HWPE datapath feeds the ECC banks un-encoded → corruption).
Both are re-evaluated at rung 5 when the HWPEs return. Full analysis: report §3, "HCI
protocol warnings".

Build hooks (set in the SoC design Makefile): `ACC_MODELSIM_DEFS` is filled from
`pulp_cluster_rtl.defines`; `ACC_MODELSIM_VLOGOPT = -suppress 2986 -suppress 2577
-svinputport=relaxed` compensates Questa 2022.3 strictness. (No `vsim`-level assertion
suppression is used — the earlier `-suppress 3837` was removed once `patches/hci/0001`
eliminated the double-drive at its source.) **Simulator flow note:** the generated
`modelsim.ini` must keep `VoptFlow = 1` (the cache-regeneration procedure in the report §7
does this): Questa 2022.3's deprecated novopt compile path crashes on several PULP sources,
and ModelSim DE 2023.2 is unusable for this design (details: report, Step 8 gate).
