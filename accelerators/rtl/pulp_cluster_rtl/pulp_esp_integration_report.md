# PULP Cluster → ESP: Implementation Report

Companion to the approved plan (`/home/eugenio/pulp_esp_reintegration_plan.md`).
Flow A (RTL-flow accelerator on the ESP DMA socket), Steps 1–9. Continuously updated;
this file reflects the true current state of the work.

---

## 1. Executive summary — status board

**Plain language:** we are re-integrating the PULP multi-core cluster into ESP as an
accelerator tile, on a clean ESP tree, without renaming thousands of PULP modules the way the
first integration did. The gamble behind the whole approach — that the simulator can keep two
different versions of identically-named hardware libraries apart, one set for the CPU and one
for the cluster — was tested first and **it works** on our simulator.

| Step | Status | Headline |
|---|---|---|
| Setup (env, repos, branch) | ✅ done | Questa **2022.3_1** selected; all repos at plan commits; branch `pulp-cluster-clean-integration` |
| 1. Library-coexistence smoke test | ✅ **PASS** | Same-named package *and* module coexist in `work` + second lib; own-library-first binding confirmed → **no-rename strategy holds; Risk R1 retired** |
| 2. Accelerator skeleton | ✅ done | Hand-generated (accgen is broken on RHEL — 2 upstream bugs found, see deviations D2/D3); installed to `tech/virtex7/acc/`; xconfig/socketgen part of the verify chain deferred to Step 6 (needs the GUI) |
| 3. Cluster RTL import + ECC experiment | ✅ done | 34 deps imported at exact lock pins, zero renames; **ECC probe PASS on Questa 2022.3_1** → R2 retired, OQ2 answered, disable-ecc fallback unused; one genuine upstream pulp_cluster bug found & patched (`no_hwpe_gen` HCI-v2 tie-off); R4 materialized as predicted and is handled by 3 documented vlog options |
| 4. Bridge modules (fix + directed TBs) | ✅ done | Both modules reworked (all 9 + 4 defects addressed); **both directed TBs PASS** on Questa 2022.3_1 (axi2dmafifo: 10 scenarios; cluster_control: 6 checks, 2 invocations) |
| 5. Wrapper + build wiring | ✅ file work done | Real wrapper written (un-renamed IPs, probe-validated Cfg, single-sourced constants), standalone elaboration PASS; hooks wired in the SoC Makefile; **compile-via-real-make-rule gate deferred behind Step 6** (needs a configured design) |
| 6. SoC configuration | ✅ done | User ran esp-xconfig (2×2, NoC 64/64, TILE_1_0 = PULP_CLUSTER_RTL/basic_dma64); config + socketgen outputs verified; **OQ6 resolved** (user fields 6-bit, match); **OQ5 decided: Option A** (keep 0xA0103680) |
| 7. Software flow | ✅ done | Host app rewritten (boot_offset semantics, span-sized buffer, rung-2 self-check); toolchain-free rung-2 image hand-assembled + objdump-verified; reference headers imported (Option A); R7 check script wired (`make check` → PASS). **PULP-extended GCC confirmed absent** — needed only for NEW cluster programs (see §2/§5) |
| 8. Validation ladder rungs 1–4 | ✅ **all four PASS, transcript-clean** | rung 1: full-SoC elab clean · rung 2: `RUNG2 PASS` (12 ms) · rung 3: `[TB UART] RUNG3 OK` · rung 4: `matrixMul -> success, nr. of errors: 0` + `SUMMARY: SUCCESS`, **0 HCI RQ-4 warnings, 0 double-drives, no assertion suppression** (after root-causing the HCI warning storm: same `N_HWPE==0` ECC-interconnect deficiency as the rung-4 corruption — dangling ECC-encode chain; fixed by `patches/hci/0001` + bank ECC off `patches/pulp_cluster/0002`) |
| 9. Hygiene / final report | ✅ done | stimuli.h dropped; README/report finalized; regression re-run on the clean patch stack |
| Phase 1: self-checking matmul baseline | ✅ **PASS** | New host-verified test (Ariane golden model): `MATMUL PASS: N=8, 0/64 mismatches`; wall-clock cycle windows **DMA_IN 399 · COMPUTE 1217 · DMA_OUT 155 · TOTAL 1771**; baseline recorded for the Phase-2 multiOT comparison (§11) |
| Phase 2: multiOT extension + head-to-head | ✅ **PASS, faster** | `esp_dma_axi` socket extension ported (7 files, verbatim) + translator read-pipelining on branch `pulp-cluster-multiot`; identical frozen test: `MATMUL PASS 0/64`, **DMA_IN 399→300 (−24.8%), TOTAL 1771→1670 (−5.7%)**, COMPUTE/DMA_OUT unchanged as designed; mechanism trace-proven (§12; stale-build mirage caught → D15) |

Validation ladder: rung 1 (compile/elab) ✅ **PASS** · rung 2 (memory write) ✅ **PASS**
(`RUNG2 PASS: buffer[0x9000] = expected magic`, 12 ms sim time — full loop: host boot →
image load → conf_done → 8 boot-reg AXI writes → cluster boot → i-fetch through
axi2dmafifo/ESP-DMA/TLB → store-back → EoC → acc_done → host check) · rung 3 (printf) ✅
**PASS** (`[TB UART] RUNG3 OK`) · rung 4 (matmul) ✅ **PASS, transcript-clean**
(`SUMMARY: SUCCESS`, `nr. of errors: 0`; 0 HCI RQ-4 warnings, 0 double-drives — see the
"HCI protocol warnings" analysis in §3) · rungs 5–6 stretch, not started. End-of-sim
"Errors: 2" = the testbench's own stop assertion (top.vhd:203) when the host app exits —
benign.

---

## 2. Environment record

**Plain language:** all CAD tools come from one setup script. We recorded exact versions
because one of the plan's key questions (the old QuestaSim crash on the ECC interconnect) can
only be answered relative to a specific simulator version.

- Setup command (required in every shell that invokes a CAD tool):
  `source /opt/cad/scripts/tools_env.sh`
  - Gotcha found: the script must not be `source`d through a pipe (`source … | tail` runs it
    in a subshell and the exports are lost).
  - The script is interactive on a TTY (asks modelsim vs. questa); non-interactive default is
    ModelSim. We **override to Questa** by prepending `/opt/cad/questa/bin` to `PATH` after
    sourcing (documented choice, see below).
  - It also activates the Python venv `~/venvs/esp311` (ESP tooling deps).
- Tool versions (recorded from command output):
  - **QuestaSim: `Questa Sim-64 vsim 2022.3_1 Simulator 2022.08 Aug 12 2022`** — the chosen
    simulator. Rationale: (a) same major version the clean pulp_cluster pins on IIS machines
    (`QUESTA ?= questa-2022.3`, `pulp_cluster/Makefile:7-8`), making the ECC-first experiment
    directly comparable to the upstream known-good configuration; (b) the thesis-era failure
    was on 2024.3, which is not installed here.
  - ModelSim DE 2023.2 (`/opt/cad/modelsim`) — available, not used.
  - Vivado v2023.2, Vitis HLS 2023.2 (`XILINX_VIVADO=/opt/Xilinx/Vivado/2023.2`).
  - Catapult 2024.1_2 (present on PATH; unused).
  - RISC-V toolchains: `riscv64-unknown-elf-gcc (GCC) 9.2.0` at `/opt/riscv` (host/Ariane
    bare-metal); xpack `riscv-none-elf-gcc 15.2.0` at `~/toolchains/…` (plain RV32, **no
    Xpulp**); `/opt/riscv32imc` exists but contains **no gcc**.
  - Licenses: `LM_LICENSE_FILE=1720@bioeelincad.ee.columbia.edu`,
    `XILINXD_LICENSE_FILE=2177@espdev.cs.columbia.edu` (set by the env script).
- **Open environment item (matters at Step 7):** no PULP-extended GCC
  (`riscv32-unknown-elf-gcc` with `-march=rv32imcxgap9`) found so far. Will search
  exhaustively at Step 7 and STOP-AND-ASK if absent, since cluster programs (pulp-runtime
  RISCY/CV32 targets) need it.
- Repos and pins (sanity-checked at start; all clean, all matching the plan):
  - reference: `/home/eugenio/esp_first_pulp_integration` @ `ea736df5` (read-only)
  - clean cluster: `/home/eugenio/pulp_cluster` @ `07988cd` (read-only)
  - target: `/home/eugenio/esp_clean_integration_target` @ `a45f2bb8` (2026.1.0),
    branch `pulp-cluster-clean-integration`
  - header generator: `/home/eugenio/cluster_test_generator` @ `73dc0ef` (read-only)

---

## 3. Step-by-step log

### Step 1 — Library-coexistence smoke test ✅ PASS

**Plain language:** before betting the integration on it, we checked that QuestaSim really
keeps two different libraries apart when both contain a package and a module with the *same
name* — the exact situation we will create by compiling the PULP cluster's `common_cells`,
`axi`, `fpnew`, … next to the CPU's older copies.

**What was done.** Three synthetic SystemVerilog files in
`/tmp/…/scratchpad/step1_smoke/`:

- `work_side.sv`: `package collide_pkg` (VERSION=1, 8-bit `payload_t`) + `module dup_mod`
  ("resolved from WORK") + `module consumer_work` importing the package and instantiating
  `dup_mod`.
- `lib_side.sv`: same two names, different content (VERSION=2, 32-bit, "resolved from
  TESTLIB") + `consumer_lib`.
- `smoke_top.sv` (in `work`): instantiates `consumer_work` and `consumer_lib`.

Commands (Questa 2022.3_1):

```
vlib work && vlib testlib && vmap testlib ./testlib
vlog -sv -quiet -work testlib lib_side.sv           # no -L: compile-time isolation
vlog -sv -quiet -work work work_side.sv smoke_top.sv
vsim -c -quiet -L work -L testlib smoke_top -do "run -all; quit -f"
```

**Observed output (verbatim):**

```
# SMOKE: consumer_work sees collide_pkg VERSION=1 width=8
# SMOKE: dup_mod resolved from WORK
# SMOKE: consumer_lib sees collide_pkg VERSION=2 width=32
# SMOKE: dup_mod resolved from TESTLIB
# SMOKE: done
# Errors: 0, Warnings: 0
```

**Interpretation.** Package imports bind at `vlog` time within the target library; module
instantiation at elaboration resolves in the instantiating unit's own library before the `-L`
search list — for both packages and modules, on this exact simulator version. The
`consumer_lib` case is the *harder* variant of what ESP does (ESP's generated VHDL uses a
library-qualified `entity pulp_cluster_rtl.…`, which cannot mis-bind at all).
**Gate passed → Risk R1 retired.** The mass renaming is confirmed unnecessary on this
installation.

### Step 5 — Wrapper + build wiring ✅ (file work; gate joined with Step 6)

**Plain language:** the placeholder RTL was replaced with the real thing: a wrapper that
contains the cluster, the two bridges, the little crossbar that splits "memory traffic" from
"printf traffic", and the clock-domain adapters the cluster requires. It elaborates cleanly
standalone. The last check of this step — compiling through ESP's own make rule — needs a
configured SoC, which is the Step 6 human action, so the two gates run together.

**What was done:**

- `hw/src/pulp_cluster_rtl_basic_dma64/pulp_cluster_rtl_basic_dma64.sv` — port of the
  reference wrapper with un-renamed IPs (`pulp_cluster`, `axi_cdc_{src,dst}_intf`,
  `axi_xbar_intf` with `axi_pkg::xbar_rule_32_t`/`xbar_cfg_t`, `mock_uart_axi`), the
  probe-validated bring-up Cfg (RISCY ×8, ECC HCI/TCDM, `HwpePresent=0`), the new bridge
  interfaces (`boot_offset` register → `cluster_control.boot_offset_i`;
  `BASE_ADDR`/`L2_BASE_ADDR` parameters fed from one `L2BaseAddr` localparam — R7
  single-sourcing), a driven `debug` output ({busy, eoc, fetch_en, en_sa_boot, conf_done,
  acc_done}), and `BootAddr = L2BaseAddr + 'h8080` computed instead of hard-coded. The stale
  accgen stub `.v` was deleted (and the tech dir clean-reinstalled — `cp -r` install does not
  remove stale files; noted for reproducibility).
- Standalone gate: vlog (ESP flags + hook options + 18 defines) of bridges + wrapper on top
  of the vendored library, then `vopt pulp_cluster_rtl_basic_dma64` → **PASS**.
- Build hooks (the only edit outside the accelerator dir, in the sanctioned location
  `socs/xilinx-vc707-xc7vx485t/Makefile`, "Modelsim Simulation Options" section):
  `ACC_MODELSIM_DEFS := $(shell cat …/pulp_cluster_rtl.defines)` (single-sourced) and
  `ACC_MODELSIM_VLOGOPT := -suppress 2986 -suppress 2577 -svinputport=relaxed`.
- Xilinx simlib cache (`.cache/modelsim/xilinx_lib`, needed once by `make sim`) launched in
  the background (`compile_simlib`, Vivado 2023.2; log at scratchpad/simlib_prewarm.log).

**OQ5 investigation (window base) — decision material, see §5:** the L2 window base is
*cluster-virtual*: the ESP socket translates DMA indices through the per-accelerator TLB to
wherever the host buffer physically lives (bare-metal bump allocator at `0xa0100000`,
`soft/common/drivers/baremetal/probe/probe.c:28`; Linux would use the `ACC_MEM` pool at
`0xA0200000`, `socmap_gen.py:160`). No RTL constant needs to match any physical address —
only the four cluster-side constants must agree among themselves.

### Step 2 — Accelerator skeleton ✅

**Plain language:** we created the empty "slot" for the accelerator: the descriptor that tells
ESP its name, ID and configuration registers, placeholder RTL for the two design points, and
the software templates. ESP's generator script turned out to be broken on this machine's OS,
so we reproduced its intended output by hand, byte-for-byte in spirit but with deterministic
register ordering.

**accgen.sh attempt and the two upstream bugs it exposed (deviations D2, D3):**

1. Ran `tools/accgen/accgen.sh` non-interactively (stdin feed: name `pulp_cluster`, flow `R`,
   ESP path default, id `075`, registers `boot_offset`=32896(0x8080)/`spare0`/`spare1`,
   width 64, sizes 1024/1024, chunking 1, batching 1, not in-place).
2. **Bug 1 (fatal on RHEL):** the script runs under `set -e` and uses util-linux `rename`
   (`accgen.sh:361-370`), which **exits 4 when no file matches** — verified:
   `rename accelerator foo *` on non-matching files → `exit=4`. The first no-match rename in
   `hw/src` kills the script; it died after copying raw templates (log:
   scratchpad/accgen2.log, `exit=4`, tree left with un-renamed `acc_full_basic_dma*`).
3. **Bug 2 (would corrupt output even if 1 didn't hit):** `accgen.sh:374` reads
   `sed -i "s/cc_full_name/$LOWERFULL/g"` — a typo (the old tree has `s/acc_full_name/` at
   its line 358). Applied to the template's `module acc_full_name_basic_dma64` it would
   produce `apulp_cluster_rtl_basic_dma64`, which socketgen would never match.
4. Decision: **hand-generate**, replicating accgen's intended logic (the plan explicitly
   allowed "run accgen.sh *or create by hand*"). No ESP files were modified.

**What was created** (all under `accelerators/rtl/pulp_cluster_rtl/`):

- `hw/pulp_cluster.xml` — file *must* be named `<name-without-_rtl>.xml` (install rule
  `accelerators/rtl/common/hls/Makefile`: `NAME_SHORT=$(TARGET_NAME:_rtl=); cp
  ../$$NAME_SHORT.xml $(RTL_OUT)/$(TARGET_NAME).xml`). Content: `name="pulp_cluster_rtl"`
  (matches the directory, fixing the old tree's cosmetic mismatch), `device_id="075"`,
  `data_size="4"`, `hls_tool="rtl"`, params in order `boot_offset, spare0, spare1` → ESP
  register bank 16/17/18 → APB offsets **0x40/0x44/0x48** (deterministic — accgen iterates a
  bash assoc array with unspecified order; our order is explicit and mirrored in all sw
  defines).
- `hw/src/pulp_cluster_rtl_basic_dma{32,64}/…​.v` — accgen template stubs with the three
  `conf_info_*` ports inserted at the `<<--params-list/def-->>` markers (markers left in
  place, exactly as accgen does). The dma64 stub is replaced by the real wrapper in Step 5;
  dma32 is filtered out by socketgen on a 64-bit-DMA SoC.
- `hw/hls/Makefile` → symlink `../../../common/hls/Makefile`.
- `sw/{baremetal,linux/{app,driver,include}}` — templates fully substituted (**no** corrupt
  identifiers this time, unlike the old tree's Linux driver): `SLD_PULP_CLUSTER 0x075`,
  `DEV_NAME "sld,pulp_cluster_rtl"`, `PULP_CLUSTER_{BOOT_OFFSET,SPARE0,SPARE1}_REG
  0x40/0x44/0x48`, OF match `eb_075` / `sld,pulp_cluster_rtl`, token `int64_t`. Rewritten
  with the real loading flow in Step 7.

**Verification (gate):**

```
cd socs/xilinx-vc707-xc7vx485t && make pulp_cluster_rtl-hls
```
→ `tech/virtex7/acc/pulp_cluster_rtl/{pulp_cluster_rtl.xml, pulp_cluster_rtl_basic_dma32/,
pulp_cluster_rtl_basic_dma64/}` created and `tech/virtex7/acc/installed.log` contains
`pulp_cluster_rtl` (this is exactly the directory soc.py:50-71 scans for the GUI). Residual
placeholder scan: only the marker comment lines remain (as with real accgen output).
Generated artifacts are already covered by the tree's ignore rules
(`tech/virtex7/acc/.gitignore:1`, `accelerators/.gitignore:55` `hls-work-*`) — nothing
regenerable gets committed. The `esp-xconfig` + `socketgen` legs of this step's verify chain
are deferred to Step 6 (HUMAN ACTION required for the GUI).

### Step 3 — Cluster RTL import + ECC-first experiment ✅

**Plain language:** we brought the actual PULP cluster source code (and its 34 dependent
libraries) into the accelerator directory, at exactly the versions the PULP maintainers
pinned, with **no renaming of anything**. Then we ran the experiment the old thesis never
could: elaborate the cluster *with all its error-correction hardware enabled* on our
simulator. It works — the old crash does not reproduce here, so this integration keeps the
fault-tolerant configuration instead of patching it out.

**Import mechanism** (`scripts/gen_vendor.sh`, committed; `vendor/` + `scripts/bin/` are
gitignored and fully regenerable — run the script on a fresh clone):

1. Clone `pulp-platform/pulp_cluster @ 07988cd01c…` into `vendor/pulp_cluster`, apply the
   local patches (see below) on a forced-clean checkout (idempotent re-runs).
2. `bender checkout` (bender 0.24.0, self-bootstrapped into `scripts/bin/`) **inside the
   cluster repo**, so its committed `Bender.lock` drives resolution: "Checked out 34
   dependencies" — the exact pin set of the plan's collision table, including the
   `scm` yml-vs-lock discrepancy resolved the same way upstream resolves it.
3. Flatten `.bender/git/checkouts/<pkg>-<16hex>/` → `vendor/<pkg>/` so committed filelist
   paths are machine-independent (no bender hash dirs, plan risk R9).
4. `bender script flist-plus` with targets `rtl mchan cluster_standalone scm_use_fpga_scm
   cv32e40p_use_ff_regfile cv32e40p_include_tracer simulation` and the 9 known-good `-D`
   defines → split into **`pulp_cluster_rtl.sverilog`** (801 entries: `+incdir+` lines +
   vendor-relative paths — the exact format `utils/make/modelsim.mk:120-153` rebases onto
   `accelerators/rtl/<acc>/vendor/`) and **`pulp_cluster_rtl.defines`** (18 `+define+`
   lines, consumed via `ACC_MODELSIM_DEFS`; flist-plus emits the `TARGET_*` defines
   itself). Excluded: iDMA testbenches, deprecated `pulp_sync.sv`, the standalone cluster
   TB + DPI elfloader. `tb/mock_uart{,_axi}.sv` appended explicitly (printf sink) instead
   of dragging every dependency's `-t test` sources in.
5. Filelist self-check: every referenced file must exist under `vendor/` (build fails
   otherwise).

**Notable target-set decisions** (deviations D4):
- `-t test` dropped (vs. the reference flow) → `riscv_tracer.sv` disappeared because
  upstream guards it with `any(test, cv32e40p_include_tracer)` (`vendor/riscv/Bender.yml:50`);
  first vopt failed with `Module 'riscv_tracer' is not defined` (`riscv_core.sv:1404`,
  under `TRACE_EXECUTION`). Fixed by adding the designed knob `-t cv32e40p_include_tracer`.
- `-t mchan` retained → neither of the reference tree's two "synthesis fix" patches is even
  compiled in this configuration (`idma_wrap.sv` is target-excluded; the `BE_WIDTH` code is
  in the non-mchan `ifdef` branch), so the import carries **no** patches from the reference.
  To be revisited only at validation rung 6 (FPGA synthesis) if Vivado's filelist ever
  includes those paths.

**Local patch (new upstream pulp_cluster bug, found by this work):**
`patches/0001-pulp_cluster-fix-no_hwpe_gen-tie-off-for-hci-v2.patch`. With
`HwpePresent=0`, `rtl/pulp_cluster.sv`'s `no_hwpe_gen` branch drives
`s_hci_hwpe[0].boffs`/`.lrdy` — members that **do not exist** in the pinned HCI revision's
`hci_core_intf` (`vendor/hci/rtl/common/hci_interfaces.sv:26-73` has `r_ready/id/ecc/ereq/…`
instead; `boffs`/`lrdy` are HCI-v1 names). Upstream never elaborates this branch (its TB
always enables HWPEs), the reference integration didn't either. The patch replaces the two
stale assigns with the v2 tie-offs (`r_ready='1`, `id/ecc/ereq='0`, `r_eready='1`).
vopt error before fix: `(vopt-7063) Failed to find 'boffs' in hierarchical name
's_hci_hwpe[0].boffs'` at `pulp_cluster.sv:1243`.

**The ECC-first experiment (plan Step 3.4, Risk R2, OQ2)** — probe committed as
`verif/ecc_probe_top.sv` + `verif/run_ecc_probe.sh`:

- Probe = unmodified-ECC `pulp_cluster` (ECC HCI selected because `UseHci=1` and
  `HwpePresent=0` both pick the `hci_ecc_interconnect` branch; ECC TCDM + HMR are
  hard-instantiated) with the bring-up Cfg (RISCY ×8, TCDM 128 KiB/16 banks, AXI 32a/64d/
  id6/user10, HWPEs off), elaboration-only.
- Compile flags = **exactly ESP's** acc-library flags (`VLOGOPT` from `modelsim.mk:9-14` +
  `ariane.mk:200-208`, incdirs stripped) + the 18 PULP defines — so the probe predicts the
  Step 5 build.
- Three compile findings on the way (this is plan risk **R4 materializing**, each fix is a
  targeted option for the `ACC_MODELSIM_VLOGOPT` hook, documented in `run_ecc_probe.sh`):
  1. `-pedanticerrors` promotes suppressible `vlog-2986` (`axi_test.sv:2607`, hierarchical
     ref in constant context) to an error → `-suppress 2986`.
  2. Questa 2022.3's default `-svinputport=net` rejects typed input ports ("Net data types
     must be 4-state", `neureka_ctrl_fsm.sv:39` `input flags_engine_t`) →
     `-svinputport=relaxed` (VCS-compatible semantics; typed inputs become variables).
  3. `-pedanticerrors` promotes `vlog-2577` (enum `==` mismatch, `softex_pkg.sv:207`) →
     `-suppress 2577`.
  Final hook value: `ACC_MODELSIM_VLOGOPT = -suppress 2986 -suppress 2577 -svinputport=relaxed`.
- **Result:**
  `PROBE: PASS - unmodified ECC cluster elaborates on Questa Sim-64 vsim 2022.3_1`.
  All 801 files vlog cleanly (including neureka/redmule/softex) and `vopt` elaborates the
  full ECC cluster. **R2 retired on this installation; the disable-ecc fallback was not
  needed and is not carried.** OQ2 is thereby answered for 2022.3_1: no internal error —
  consistent with the hypothesis that the thesis-era crash was specific to the 2024.3-era
  simulator, which is not installed here and cannot be re-probed (deviation D1).

**OQ3 resolved (cluster_control_unit register map)** — now read from the actual RTL,
`vendor/cluster_peripherals/cluster_control_unit/cluster_control_unit.sv:44-60` (header
comment) + decode logic (`:194-335`): `0x000` EoC (bit 0), `0x008` per-core fetch-enable,
`0x040-0x07F` per-core 32-bit boot addresses (write decode `boot_addr_n[add[5:2]] = wdata`
at `:320`), `0x100` cluster return value. Reset value of every boot-address register is the
`BOOT_ADDR` parameter (`:364`), i.e. `Cfg.BootAddr` — the runtime AXI writes are a
*re-programming* on top of a sane default. Confirms the plan's `0x50200040 + 4*i` contract.

**OQ8 resolved (ATOPs)** — the cluster's external AXI master issues **no ATOPs** in this
configuration: `per2axi` contains zero `atop` references; the core's `data_atop_o` is left
unconnected (`core_region.sv:202`); the instruction bus ties `aw_atop='0`
(`pulp_cluster.sv:1437`); mchan has no atop signals (idma would, but is not compiled).
`axi2dmafifo` may safely ignore the `atop` field; no atop filter is needed.

### Step 8 — validation ladder: analyses for rungs 3 and 4

**Rung 3 (printf).** First attempt used the reference tree's `stimuli.h`; cores trapped at
`0xA010B600`. Diagnosis: the header is a *sparse, unpadded* artifact (494 entries spanning
0x8728 bytes — it never went through `generate_padded_stimuli.py`); disassembly shows a
valid entry at +0x8080 and vector table at +0x8000, but at runtime two cores jump to garbage
pointers (`0x4c8e7536`, `0x12e2f260`) — the `axi2dmafifo` SLVERR path caught the resulting
wild fetches loudly instead of hanging (the new error handling paying off). Since the
reference README's actual test was always `optmatmul_M8_8x8.h`, `stimuli.h` was judged a
broken leftover and **dropped** (deviation D12). Rung 3 was redone deterministically:
`gen_rung2_stimuli.py --uart` emits `rung3_uart.h` (core 0 prints "RUNG3 OK\n" byte-by-byte
to the mock UART at 0x03002000, then raises EoC; encodings objdump-verified). Result:
`[TB UART] RUNG3 OK` + the rung-2 magic check green in the same run.

**Rung 4 (matmul) — and a genuine functional find.** With `optmatmul_M8_8x8.h` the program
ran deep (mchan DMA into TCDM through the translator, `Perf CYCLES: 606` printed, the
**XpulpV2 SIMD kernel executed** — `pv.shuffle2.b` visible in the RI5CY trace) and then
core 0 did `jalr x1, x23` with `x23 = 0x4c8e7537`: a corrupted callee-saved spill. The
instruction traces (TRACE_EXECUTION) are conclusive: the prologue stored good values
(`sw x9 (0) → PA 0x500007FC`, `sw x18 (0xa0104000) → 0x7F8`), and the epilogue loads
returned the *same garbage word* `0x4c8e7537` from **four consecutive TCDM stack slots**
while neighbouring slots read back correctly — TCDM-internal corruption (PA 0x500007xx
never crosses the AXI/DMA bridge), the value appears 365 times in the trace, and it does
not exist anywhere in the program image. Experiment: disabling **TCDM bank ECC only**
(`EnableEcc/EccInterco: 1→0`, interconnect ECC left on) makes the benchmark pass its own
self-check: `== test: matrixMul -> success, nr. of errors: 0, execution time: 573` +
`==== SUMMARY: SUCCESS`. Conclusion: the ECC bank path corrupts words under concurrent
mchan-DMA + multi-core store traffic **in the `HwpePresent=0` configuration** — a
combination upstream never simulates with ECC (their TB always enables the HWPEs; this is
the second `HwpePresent=0` latent bug after the `no_hwpe_gen` tie-off). Shipped as
`patches/pulp_cluster/0002-tcdm-bank-ecc-off-bringup.patch` with re-evaluation scheduled at
rung 5 (HWPEs on = the upstream-tested ECC configuration). This finding also *functionally
vindicates* the reference integration's ECC-off patch — which we had classified as a mere
Questa-crash workaround, and whose test could never have caught corruption anyway (its
result validation was commented out; our benchmark self-check is what exposed it).

Cluster benchmark number for the record: 8×8 optimized (macload/SIMD) matmul,
**573 cycles** end-to-end on the 8-core cluster (thesis-era baseline comparison: the
reference reported ~180× speedup for 8-bit matmul vs. single-Ariane; a fresh Ariane-side
baseline run is left as an optional follow-up since it needs a host-side matmul program,
not any accelerator work).

### Step 8 — HCI protocol warnings (rung-4 re-examination, and the completed ECC story)

**Plain language.** After rung 4 passed *functionally*, the QuestaSim transcript still held a
flood of "HCI RQ-4 NORETIRE protocol violation!" warnings. A passing test with thousands of
protocol warnings is not a green rung — a warning storm can hide real corruption — so rung 4
went back to yellow until dispositioned. Investigation showed the warnings and the earlier
rung-4 ECC corruption are **two faces of one upstream deficiency**: the *ECC* variant of the
cluster's internal interconnect only wires up its memory-side ECC machinery when at least one
HWPE is present. In our bring-up config (no HWPEs) that machinery is left half-connected — it
dangles (producing the warnings and a harmless double-drive) *and* it leaves the path to the
ECC memory banks un-encoded (producing the data corruption). Two small, independent fixes
make it fully clean: gate the dangling logic out, and turn the bank ECC off. Both are the
correct configuration for a no-HWPE ECC-interconnect cluster; both get revisited when the
HWPEs come back (rung 5). After the fix the same matmul run has **zero** HCI warnings, zero
double-drives, and still passes.

**1 — Characterization** (transcript `socs/xilinx-vc707-xc7vx485t/modelsim/transcript`).

| template | count | emitting scope (instance family) | source | time window | example |
|---|---|---|---|---|---|
| `HCI RQ-4 NORETIRE protocol violation!` | **5060** | `…cluster_i.cluster_interconnect_wrap_i.hci_gen.i_hci_interconnect.all_except_hwpe_mem_assign[0..15].HCI_RQ4` and `…all_except_hwpe_mem_enc[0..15].HCI_RQ4` (2530 each; only these two 16-wide interface arrays, never `cores`/`dma`/`ext`/`mems`) | `vendor/hci/rtl/common/hci_interfaces.sv:194` | throughout compute (first at ~22.8 ms sim, recurring across the matmul — one per retired request on the dangling arrays) | `HCI RQ-4 NORETIRE protocol violation!  Time: 22833215001 ps  Scope: …i_hci_interconnect.all_except_hwpe_mem_assign[2].HCI_RQ4  File: …/hci/rtl/common/hci_interfaces.sv Line: 194` |
| `axi2dmafifo: unsupported AR … -> SLVERR` | few | our translator | `axi2dmafifo.sv:355` | scattered | benign, expected (the wild-fetch guard; see rung-3 analysis) |
| `vlog-2600` redundant-digit lint, `vcom-1083` in ESP's own `rtl/sim/tb/tb_iolink.vhd`, `vopt-10587 +acc` | 6 total | compile-time / ESP TB | — | elaboration | cosmetic, unrelated |

Also present before the fix (masked by `VSIMOPT += -suppress 3837`): **≈144 `vsim-3837`
"written by more than one continuous assignment"** on the *response* members
(`r_data`, `r_valid`, `gnt`, `r_id`, `r_user`, `r_opc`, `r_ecc`, `r_evalid`) of
`all_except_hwpe_mem[*]` — the same instance family. That double-drive and the RQ-4 warnings
have a single cause (below), so both are fixed together and the suppression is removed.

**2 — Source of the assertion.** `vendor/hci/rtl/common/hci_interfaces.sv:189-194`:
```systemverilog
// RQ-4 NORETIRE
property hci_rq4_noretire_rule;
  @(posedge clk_assert)
  ($past(req) & ~req) |-> ($past(req) & $past(gnt)) | WAIVE_RQ4_ASSERT;
endproperty;
HCI_RQ4: assert property(hci_rq4_noretire_rule)
  else `HCI_ASSERT_SEVERITY("HCI RQ-4 NORETIRE protocol violation!", 1);
```
Plain-language rule: on an HCI request channel an initiator **must not retire (drop) a
`req` that has not yet been granted** — once `req` is asserted it stays until `req & gnt`.
The assertion is compiled in every `hci_core_intf` (guarded only by `` `ifndef SYNTHESIS ``
/ VERILATOR / VCS — so it *is* live in this Questa run) unless the enclosing interface's
`WAIVE_RQ4_ASSERT` parameter is set (as `hci_router.sv:124` does for its grant-less virtual
input).

**3 — Root cause** (`vendor/hci/rtl/ecc/hci_ecc_interconnect.sv`). Our cluster selects the
**ECC** interconnect (`hci_ecc_interconnect`, chosen by `UseHci || !HwpePresent`). Inside it,
the memory-side datapath is built in two mutually-exclusive generate arms keyed on `N_HWPE`:
- `hwpe_branch_gen` (`N_HWPE>0`): an `hci_arbiter` merges the encoded core path
  (`all_except_hwpe_mem_enc`) with the encoded HWPE path and drives the banks (`mems`).
- `no_hwpe_branch_gen` (`N_HWPE==0`, **our case**): `mems` is bound **directly** to the raw
  `all_except_hwpe_mem` via `hci_core_assign` — bypassing all ECC encoding.

But the `post_lic_encoding` loop that builds the encoded arrays
(`all_except_hwpe_mem` → `all_except_hwpe_mem_assign` via `hci_core_assign`, then
`hci_ecc_enc` → `all_except_hwpe_mem_enc`) is written **outside** the `N_HWPE>0` guard — it is
generated unconditionally (line 254; still ungated in latest upstream `v2.6.0:264`,
verified). With `N_HWPE==0` its output `all_except_hwpe_mem_enc` is consumed by nothing, so:
- **the warnings**: the encode chain's requests are never granted (no arbiter downstream) and
  the LIC retires them → `HCI_RQ4` fires on `_assign` and `_enc` every transaction (5060×);
- **the double-drive**: `hci_core_assign(target=all_except_hwpe_mem, initiator=…_assign)`
  drives `all_except_hwpe_mem`'s response members (per `hci_core_assign.sv:35-39`:
  `assign tcdm_target.r_data = tcdm_initiator.r_data;` …), and so does the *real*
  `no_hwpe_branch_gen` binding — hence `vsim-3837` on exactly those signals.

This is category **(b) — a consequence of our (upstream-untested) configuration**, not (a) a
fault our wrapper/bridge/clocking introduces: everything is *internal* to the cluster's HCI,
independent of the ESP socket, and driven purely by `HwpePresent=0`. Confirmed against
upstream (category (c) check): the clean `pulp_cluster` TB always sets `HwpePresent:1,
HwpeNumPorts:9` (`tb/pulp_cluster_tb.sv:292-294`), so upstream *never* exercises
`N_HWPE==0` with the ECC interconnect and never sees these assertions. The plain
`hci_interconnect` has **no** ECC-encode chain at all (grep: 0 `post_lic_encoding`/`hci_ecc_enc`),
which is why the **reference thesis integration — which patched `hci_ecc_interconnect` →
plain `hci_interconnect` — never saw these warnings or the ECC-datapath mismatch.** This ties
the finding directly to **Risk R2 / Open Question 2**: the old integration's ECC removal was,
unwittingly, structurally correct on the *memory* side too, not merely a QuestaSim-crash dodge.

**4 — Impact assessment.** Do they fire on the matmul data path, and can they mask
corruption? The RQ-4 warnings fire on the **dead** `_assign`/`_enc` arrays, which route to
nothing — so they do not themselves corrupt data. But they are **not benign noise**: they are
the visible symptom of a genuinely mis-wired ECC interconnect, and the *same* mis-wiring, with
bank ECC enabled, is what corrupts real data (the rung-4 stack corruption). The decisive
experiment: apply only the dangling-chain gate (below) and re-run **with bank ECC re-enabled**
→ warnings drop to **0** but the matmul **still corrupts** (1.2 M illegal-instruction reports,
same `0xA010B600` signature). That proves (i) the warnings and the double-drive are one issue,
fixed by the gate; and (ii) the ECC-bank corruption is a *separate, deeper* consequence of the
same `N_HWPE==0` deficiency — the un-encoded `no_hwpe_branch_gen` path feeding ECC banks — that
the gate cannot fix and that only bank-ECC-off resolves. So the passing matmul is **not**
coincidental: with both fixes the data path is a plain (non-ECC) TCDM path with no dangling
logic and no double-drive, exercised end-to-end and self-checked (`nr. of errors: 0`).

**5 — Fix applied** (both within the no-global-edits rules — vendored RTL patches +
one SoC-Makefile line reverted; nothing in `utils/make` or `tools/`):
- `patches/hci/0001-gate-post-lic-ecc-chain-when-no-hwpe.patch` — wrap `post_lic_encoding`
  and the `arb_valid_handshake` taps in `if (N_HWPE > 0)`, tying the now-unused error/handshake
  signals to `'0` in the `else`. This removes the dead chain → **0 RQ-4 warnings, 0
  `vsim-3837`**. It is the minimal, upstream-shaped fix (mirrors how `hwpe_branch_gen`/
  `no_hwpe_branch_gen` already gate the rest of the datapath) and an upstream-report candidate.
- `patches/pulp_cluster/0002-tcdm-bank-ecc-off-bringup.patch` — kept and now *justified by
  structure* (not just "corruption dodge"): with `N_HWPE==0` the banks cannot receive encoded
  data, so `EnableEcc/EccInterco` must be `0`. Re-enabled at rung 5 with the HWPEs.
- **`VSIMOPT += -suppress 3837` removed** from `socs/xilinx-vc707-xc7vx485t/Makefile`: it was
  masking the double-drive, which the gate now eliminates at the source. **No assertion is
  blanket-suppressed** — the RQ-4 property is left fully live; it simply no longer has a
  dangling instance to fire on.

**Verification (definitive config: patch 0001 no-hwpe tie-off + 0002 ECC-off + hci/0001 gate +
common_cells backport; no warning suppression):** all three rungs re-run from a clean
per-accelerator library build —
`rung4: PASS (SUMMARY: SUCCESS, nr. of errors: 0) HCI_RQ4=0 double_drive=0 illegal=0` ·
`rung3: PASS (RUNG3 OK) HCI_RQ4=0` · `rung2: PASS (RUNG2 PASS) HCI_RQ4=0`. Residual transcript
warnings: 6, all cosmetic (2 vlog-2600 redundant-digit lint, 3 vcom-1083 in ESP's own
`tb_iolink.vhd`, 1 vopt-10587 `+acc`) plus the expected `axi2dmafifo … SLVERR` guard lines.
**Rung 4 is green.**

### Step 8 — the two `axi2dmafifo … SLVERR` warnings (rung-4 spot check, dispositioned benign)

**Plain language.** The passing optmatmul transcript contains exactly two lines of the form
`axi2dmafifo: unsupported AR (addr 0xa0038220 len 3 size 3 burst 1) -> SLVERR`. These are not
a bug and not luck: they are our own Step-4 error guard doing its job on two *speculative*
instruction prefetches that the cluster's instruction cache invents on its own and never
actually uses. The cache's little hardware prefetcher scans every freshly fetched cache line
for things that *look like* jump instructions and fetches their targets ahead of time; twice
per run, a bit pattern in the matmul image happens to look like a jump to an address ~800 KiB
*below* the accelerator's memory window, so the prefetcher asks for a line from an address
that maps to nothing. Our translator (correctly) refuses, returns an error response with
all-zero data, and the cluster (verifiably) throws the result away. The test's success does
not depend on those two reads in any way. Everywhere else this same event passes silently —
the upstream testbench feeds the prefetcher random garbage with an OK response, and the old
reference integration would have forwarded it as a wild DMA read — ours is the only
implementation that even *notices*. Disposition: benign; warning kept (it is a useful canary);
the exact transaction shape is now replayed in the directed TB. **Rung 4 stays green, no
caveat.**

**1 — Characterization** (same optmatmul run as above; transcript totals `Errors: 0,
Warnings: 2` — these two lines are the *only* warnings in the entire run).

| # | AR | time | source of the message |
|---|---|---|---|
| 1 | addr `0xA0038220`, len 3, size 3 (8 B), burst INCR | 23 822 875 ns | `$warning` in the simulation-only contract check, `axi2dmafifo.sv:355` |
| 2 | addr `0xA0088340`, len 3, size 3 (8 B), burst INCR | 23 824 315 ns | same |

Both addresses are **below** the L2 window base `0xA0103680` (by 0xCB460 and 0x7B340); both
fall in the perf-counter-printing phase; both are 4×8 B = 32-byte reads — the size of one
instruction-cache line.

**2 — What the guard actually rejects.** Line 355 is only the `$warning`; the decision is
`req_err()` (`axi2dmafifo.sv:96-105`), which flags WRAP bursts, multi-beat FIXED, multi-beat
narrow, size > 8 B, and `bad_window = (addr < BASE_ADDR)`. For these two ARs the *shape* is
fully supported — 64-bit INCR bursts are the standard i-cache refill shape and hundreds were
served in this same run — the **only** failing term is `bad_window`. (The message text
"unsupported AR" plus the burst fields can mislead; the address is the culprit. Below-window
addresses reach the translator because the wrapper xbar routes everything unmapped to master
port 0 = `axi2dmafifo` (`en_default_mst_port_i='1'`, wrapper lines 225-226/244-257), a
deliberate choice so that stray traffic gets a *bounded, visible* answer instead of a NoC
decode error.) The FSM's `ERR_RD` drain returns `len+1` beats of `r_resp=SLVERR` with
deterministic all-zero data (`r_data` keeps its `'0` default, line 221) and never touches the
ESP DMA.

**3 — Who issues them: the snitch icache L0 prefetcher, with the arithmetic to prove it.**
The active instruction cache is the snitch-based `pulp_icache_wrap`
(`+define+SNITCH_ICACHE`, instantiated at `vendor/pulp_cluster/rtl/pulp_cluster.sv:1261-1308`)
with `LINE_WIDTH=256` over the 64-bit AXI port — refills are exactly the observed
`len=3, size=3, INCR` bursts (`vendor/cluster_icache/src/snitch_icache_refill.sv:110-122`).
Its per-core L0 cache has a hardware prefetcher, **enabled out of reset**
(`cluster_icache_ctrl_reg_top.sv:404-408`, `RESVAL=1`), that *pre-decodes every 32-bit lane*
of a line on an L0 hit: patterns that decode as JAL (or backward conditional branches,
statically predicted taken) get their target prefetched
(`snitch_icache_l0.sv:448,462-484,528`). Two 32-bit words of the optmatmul image are
false-positive JALs with large negative offsets, and the prefetcher's line-aligned targets
reproduce the warned addresses **exactly**:

| image word (at addr) | decodes as | JAL target | `& ~0x1F` (line align) | = warned AR |
|---|---|---|---|---|
| `0x82F2C8EF` @ `0xA010B9F8` | `jal x17, -0xD37D2` | `0xA0038226` | `0xA0038220` | #1 ✓ |
| `0x9557C8EF` @ `0xA010BA04` | `jal x17, -0x836AC` | `0xA0088358` | `0xA0088340` | #2 ✓ |

This is a **(b)-type cause in the task's taxonomy applied to the socket** — a consequence of
normal cluster micro-architecture meeting our (correct) bounded window — not an integration
bug and not a program bug. Confirmation that nothing architectural is involved: neither
address appears anywhere in the 8 per-core `TRACE_EXECUTION` logs or the host commit trace
(zero grep hits across all 9 files) — never a PC, never a register value, never a load/store
target.

**4 — Why the pass is genuine (mechanism, not luck).** Every hop on the return path
(wrapper xbar and CDC, cluster `axi_isolate`/ID remap, `cluster_bus_wrap` xbar) transports
`r_resp` untouched; the *only* reader is the refill unit (`snitch_icache_refill.sv:122`),
which then validates the all-zero line into L1 and L0 regardless — and the error indication
is dropped at three independent points (`snitch_icache_l0.sv:423` hard-wires `in_error_o='0`;
`snitch_icache_handler.sv:359` forces `error=0` on L1 hits; `pulp_cluster.sv:1295` leaves
`fetch_rerror_o` unconnected — RI5CY's instruction port has no error input at all). There is
**no retry mechanism anywhere on the fetch path** — so of the three hypotheses, (a)
"retried as single beats" is impossible, and the answer is **(b) dead speculative fetch**:
the zero line terminates in the cache arrays under its full below-window tag
(`snitch_icache_handler.sv:325` — no aliasing possible) with no core waiting. It could only
ever be *executed* if a core's architectural PC entered the below-window range — which a
correct program never does, this run demonstrably didn't, and which would in any case hit
all-zero words that decode as an **illegal instruction** (deterministic trap, not silent
corruption). Not (c): nothing is masked, because nothing ever demands this data.
One collateral finding worth recording for later rungs: had the same SLVERR hit an **mchan
DMA read** instead, it would be silently swallowed — mchan's `ext_rx_if.sv:79` declares
`axi_master_r_resp_i` and never reads it, and there is no DMA error IRQ/status. A program
bug that DMAs from outside the window would therefore write zeros to TCDM with only our
transcript warning as evidence — one more reason to keep the warning verbose.

**5 — Calibration against the other two implementations, and disposition.**
*Upstream standalone TB:* `axi_sim_mem` answers **every** address with `RESP_OKAY` and
`$urandom` data (warnings disabled), and its xbar defaults unmapped addresses to the mock
UART (`pslverr=0`) — the same prefetches happen there and are fed random garbage, silently;
upstream tests pass regardless, independently confirming the data is never consumed.
*Old reference integration:* its `axi2dmafifo` rebased with an unguarded 32-bit subtraction
and hardwired `r_resp=OKAY` — these two ARs would have wrapped to DMA indices
`0x1FFE6974`/`0x1FFF0998` and been forwarded as **real DMA reads** through `esp_acc_dma`'s
TLB (index truncated modulo the loaded entries, unwritten-entry physical address): bounded
in sim, but on FPGA an arbitrary-physical-address read, answered OKAY. Our SLVERR drain is
strictly safer than both. **Disposition: benign by proven mechanism; no RTL change** —
"supporting" the burst is not meaningful (there is no memory below the window to read;
the window *is* the accelerator's entire view of memory), and per-occurrence verbosity is
right (2 lines/run; a *storm* of them would be a real program/DMA bug worth seeing).
TB coverage added: scenario **S9b** in `verif/axi2dmafifo_tb.sv` replays the literal
in-the-wild AR (`0xA0038220`, len 3, size 3, INCR) and checks all four beats return
SLVERR with zero data, no DMA transaction is issued, and the translator recovers into the
following burst scenario — `TB PASSED: axi2dmafifo all scenarios OK (dma_reads=10
dma_writes=19)` (the 4 TB warnings are the expected contract `$warning` fires of S7/S8/S9/
S9b, one per error scenario). Cross-reference: §4 defect table, rows 9 and 1 — this event
is the Step-4 "unsupported requests drain with SLVERR instead of parking the FSM" fix
*observed working in the wild*; the rung-3 analysis above shows the same guard catching the
broken `stimuli.h`'s genuinely-wild fetches.

### Step 8 gate — full-design compile: three root-caused blockers (in progress)

**Plain language:** compiling the whole SoC through ESP's own build system surfaced four
independent problems, none of them in our RTL. Each was root-caused, fixed in a sanctioned
location, and is documented here because at least two of them are upstream bugs (and one
finally demystifies the "QuestaSim internal error" folklore from the thesis).

1. **Questa 2022.3_1 internal error on `common_cells/src/id_queue.sv` — fully root-caused.**
   Symptom: `vgentd.c(684)` ICE in the per-accelerator library compile, while the identical
   filelist/flags passed standalone (Step 3 probe). Bisection (report-worthy chain of false
   leads included): factory `modelsim.ini` → clean; ESP-generated ini → deterministic ICE;
   suspicion first fell on the ini's `suppress = 8780,8891,1491,12110` line (removing `12110`
   "fixed" it) — but that was a **false negative**: with 12110 unsuppressed, `-pedanticerrors`
   promotes the vlog-12110 message to an error that aborts vlog at startup, before reaching
   `id_queue`. vlog-12110 turned out to be the *"-novopt is deprecated"* warning: ESP's ini
   sets `VoptFlow = 0`, putting every vlog in the deprecated `-novopt` mode, **and that code
   path is what crashes Questa 2022.3_1 on this file**. Durable fix (sanctioned hook, SoC
   Makefile): `ACC_MODELSIM_VLOGOPT += -vopt` — compile the accelerator library in the
   default vopt flow. Verified: rule-exact command, fresh library, rc=0, zero errors across
   all ~800 files. (The `work` compile keeps ESP's stock `-novopt` behaviour and does not
   ICE on ariane's older sources.) Echo of thesis-era OQ2: same ICE class, now with a
   mechanism instead of folklore.
2. **CV32 tracer needs UVM** (`cv32e40p_tracer.sv:27` `` `include "uvm_macros.svh"``): pulled
   in by the `CV32E40P_TRACE_EXECUTION` define (from the `cv32e40p_include_tracer` bender
   target); resolves against the factory ini's UVM paths but not against ESP's generated
   ini. Dead code for the RISCY bring-up config → the define is filtered out of
   `pulp_cluster_rtl.defines` in `gen_vendor.sh` (the RI5CY `riscv_tracer`, plain SV, stays).
3. **socketgen `desc` truncation off-by-one (upstream bug):** for `desc` attributes longer
   than 31 chars, `tools/socketgen/socketgen.py:187-188` emits `acc.desc[0:30]` (30 chars)
   into a 31-char VHDL string constant → `vcom-1272 Length of expected is 31; length of
   actual is 30` on `sld_devices.vhd`. Workaround: accelerator `desc` shortened to
   "PULP cluster accelerator" (padding path is correct). Upstream fix would be `[0:31]`.
4. **The novopt rabbit hole, fully mapped (supersedes the `-vopt` hook of item 1).**
   Follow-up findings changed the fix:
   - `-vopt`-compiled acc libraries carry no machine code, and ESP's `VoptFlow=0` vsim
     needs it: elaboration died with `vsim-3171 Could not find machine code for
     'pulp_cluster_rtl.id_queue'` and the automatic vlog regeneration subinvocation
     re-entered novopt mode and re-crashed. Catch-22 via that route.
   - The true id_queue trigger is **bit-indexing packed-struct array elements**
     (`linked_data_q[i][0]`); upstream fixed it in common_cells `0d3b168` ("id_queue:
     Fix struct accesses (#254)"). Backporting those three hunks onto v1.35.0 makes
     id_queue compile **cleanly in novopt mode** →
     `patches/common_cells/0001-id_queue-struct-access-backport-0d3b168.patch`.
   - But the novopt codegen bug is a *family*: `axi/src/axi_lite_dw_converter.sv`
     (vgentd.c(3294)) and `riscv/rtl/riscv_cs_registers.sv` (vgentd.c(684)) also ICE;
     for cs_registers three targeted hypotheses (PMP struct cross-assigns, variable-
     indexed member arrays, per-element FF drivers, even stubbing the whole
     `PULP_SECURE` arm) all failed to localize the trigger — whack-a-mole with unknown
     depth.
   - **ModelSim DE 2023.2 pivot tested and rejected:** DE reports "-novopt has no
     effect on this product" (the ModelSim lineage always does codegen) *and its
     vgentd ICEs on id_queue and axi_lite_dw_converter even in its default flow* —
     strictly worse. This also explains upstream ESP's ini choices: `VoptFlow=0` +
     `suppress 12110` are no-ops-with-silenced-warnings on ModelSim-lineage tools.
   - **Resolution: keep Questa, run the modern vopt flow** — the generated ini keeps
     `VoptFlow = 1` (one changed line in a regenerated build artifact; the cache
     rebuild script documents it) so every vlog compiles in vopt mode (proven clean
     end-to-end over all ~800 files) and vsim auto-vopts at elaboration. The id_queue
     backport is kept (correct upstream fix); the speculative cs_registers hoist, the
     mock_uart_axi rework and the dw_converter exclusion were all reverted (vendor
     tree stays pristine except the two justified patches).
5. **Xilinx simlib compiled with the wrong simulator:** ESP's `.cache/modelsim/xilinx_lib`
   rule lets Vivado auto-detect the simulator; Vivado picked `/opt/cad/modelsim/bin`
   (ModelSim DE 2023.2) even with Questa first in `PATH` (`compile_simlib.log`:
   "Using modelsim simulator tools from '/opt/cad/modelsim/bin/'"), so every
   unisim-referencing vcom failed with "This version of the compiler is incompatible with
   the library .dat file". Repair (gitignored artifacts only): cache rebuilt manually with
   `compile_simlib -simulator questa -simulator_exec_path /opt/cad/questa/bin` plus a
   verbatim replay of the rule's ini post-processing seds (`utils/make/modelsim.mk:95-104`).

---

## 4. Bridge-module changes (defect table)

**Plain language:** the two adapter modules were not copied — they were re-worked against the
defect list from the plan, and each fix is exercised by a dedicated testbench scenario. The
ESP-side protocol is unchanged (verified in the plan: the socket RTL is identical old→new),
so the architecture (request FIFO + one-transaction-at-a-time FSM) is preserved.

New sources (compiled into the acc library alongside the wrapper, via the
`tech/<lib>/acc/<acc>` leg of `MODELSIM_ACC_LIB_RULE`):
`hw/src/pulp_cluster_rtl_basic_dma64/axi2dmafifo.sv` (9 states vs. the reference's 11 —
the three duplicated sub-word RMW paths collapsed into one strobe-driven path, plus two new
error-drain states) and `hw/src/pulp_cluster_rtl_basic_dma64/cluster_control.sv` (8 states —
adds WRITE_RESP). TBs: `verif/axi2dmafifo_tb.sv`, `verif/cluster_control_tb.sv`, runner
`verif/run_bridge_tbs.sh`. Result (verbatim):
`TB PASSED: axi2dmafifo all scenarios OK (dma_reads=10 dma_writes=19)` ·
`TB PASSED: cluster_control all checks OK (writes=16)`.

### axi2dmafifo

| Plan defect # | Description (reference behaviour) | Fix | TB coverage |
|---|---|---|---|
| 1 | 16-bit (and any size ∉ {1,2,4,8 B}) accesses had no dispatch arm → FSM parked forever | one generic strobe-driven RMW path serves 1/2/4-byte writes; all reads stream full-width (lane-correct); sizes >8B → SLVERR | S3b (halfword RMW), S4b (halfword read) |
| 2 | full-width writes zero-filled un-strobed bytes (silent corruption) | contract + simulation assertion: full-width beats must have all strobes (cluster masters comply: per2axi uses narrow AxSIZE for sub-word stores) | assertion armed in all S1/S2/S6/S10 write beats |
| 3 | RMW merged against only the *last* auxiliary beat → multi-beat narrow writes corrupted | narrow requests are single-beat by contract; multi-beat narrow → SLVERR, never forwarded to the DMA | S3 (correct single-beat RMW), S8 (multi-beat narrow → SLVERR, DMA counter unchanged) |
| 4 | `byte_offset` captured once per transaction → multi-beat byte reads mis-masked | masked-read path removed entirely; reads return the full 64-bit word (AXI lane semantics) | S4a/b/c |
| 5 | simultaneous AW+AR with one free FIFO slot: both handshakes completed, **neither stored** | `ar_ready = (free>1) \|\| (free==1 && !aw_valid)` — AW priority, AR stalled; dual-push only when 2 slots free | S5 (concurrent write+read), S6 (saturation: all `FIFO_DEPTH+2` writes complete, DMA count checked) |
| 6 | `read_mask` latch (no `always_comb` default) | signal eliminated with the masked-read path | n/a (by construction) |
| 7 | `fifo_full/empty` registered one cycle stale | `count`-derived combinational `slots_free`; ready signals never overshoot | S6 |
| 8 | `logic [AXI_USER_WIDTH] user` off-by-one (WIDTH+1 bits) | `[AXI_USER_WIDTH-1:0]` | compile + S1-S10 id/user checks |
| 9 | burst type ignored (WRAP/FIXED treated as INCR) | WRAP (and multi-beat FIXED) → SLVERR drain, no DMA; below-window addresses (xbar default-route underflow) also → SLVERR | S7, S9, S9b (replays the two below-window i-cache prefetches observed in the passing rung-4 run — see the Step-8 SLVERR disposition in §3) |
| — | (new) BASE_ADDRESS hard-coded localparam | `BASE_ADDR` parameter, single-sourced from the wrapper (four-constant invariant R7) | all scenarios run against the parameter |

### cluster_control

| Plan fix # | Description | Fix | TB coverage |
|---|---|---|---|
| 1 | hard-coded `TARGET_ADDRESS`/8 cores | parameters `NUM_CORES, CLUSTER_BASE_ADDR, CLUSTER_PERIPH_OFFS, BOOT_REG_OFFS, L2_BASE_ADDR` | C1 |
| 2 | AR/R channel + `aw_id/aw_user/w_user` never driven (X into the CDC) | all AXI master outputs driven every cycle (`ar_valid=0`, `r_ready=1`, qualifiers zeroed); W data replicated on both 32-bit lanes with lane-select strobes (reference relied on all-ones strobes + low-lane data) | C6 (X-checks on every AW/W; `ar_valid` monitored for the whole sim) |
| 3 | fired-and-forgot on `w_ready`; B responses ignored | new `WRITE_RESP` state: next boot-address write only after B (B ordering asserted; `b_resp` checked by in-module assertion) | C2 (model fails on overlapping writes; randomized B delays) |
| 4 | boot address = `reg1 + 0x8080` with reg1 = host physical buffer pointer (allocator coincidence) | `boot = L2_BASE_ADDR + boot_offset_i`, offset from the dedicated ESP user register (default 0x8080 = pulp-runtime `_start`) | C1 (register values checked = L2BASE+offset), C5 (second invocation, different offset) |

**TB-development note (honesty):** the first TB run reported 56 errors that were all
testbench sampling bugs, not DUT bugs — combinational DUT outputs were sampled `#1` after the
handshake edge, when the FSM had already advanced (classic race: the last write beat sampled
the RESP-state default `'0`). Fixed by capturing all DUT outputs at the clock-edge event;
after the fix both TBs pass with zero errors. Recorded because the failure signature
(B-response IDs "wrong", last beats "zero") could be misread as DUT defects.

| (end of defect tables) |
|---|---|

---

## 5. Open-question resolutions

| OQ | Status | Resolution |
|---|---|---|
| 1 (Questa package coexistence) | ✅ resolved | Step 1 PASS on Questa 2022.3_1 (see §3) |
| 2 (ECC internal error root cause) | ✅ resolved (for 2022.3_1) | ECC probe PASS — no ICE on Questa 2022.3_1; ship ECC config; 2024.3 crash unreproducible here (D1) |
| 3 (cluster_control_unit register map) | ✅ resolved | read from `vendor/cluster_peripherals/cluster_control_unit/cluster_control_unit.sv:44-60,194-364`: EoC 0x000, fetch-en 0x008, boot addrs 0x040+4i (reset = BOOT_ADDR param), return 0x100 |
| 5 (0xA0103680 vs. cleaner base) | ✅ decided: **Option A, keep 0xA0103680** (user choice) | investigation: the base is cluster-virtual (per-acc TLB maps indices to the physical buffer — bare-metal bump allocator @0xa0100000, probe.c:28; Linux ACC_MEM pool @0xA0200000, socmap_gen.py:160); keeping it enables verbatim reuse of the reference's prebuilt program images |
| 6 (ctrl_data_user width) | ✅ resolved | generated `socketgen/allacc.vhd:23,29`: `data_user : out std_logic_vector(5 downto 0)` — 6 bits, wrapper matches |
| 8 (ATOP end-to-end) | ✅ resolved | no ATOP sources on the cluster's external AXI master: per2axi grep=0, core data_atop_o unconnected (`core_region.sv:202`), instr bus `aw_atop='0` (`pulp_cluster.sv:1437`), mchan atop-free |

---

## 6. Deviation log

| # | Where | Plan said | Reality | Consequence |
|---|---|---|---|---|
| D1 | Environment | plan §4 assumed thesis-era QuestaSim 2024.3 might be present | installed simulators are Questa 2022.3_1 and ModelSim DE 2023.2 | ECC experiment (Step 3) runs on 2022.3_1: a PASS is consistent with upstream IIS evidence and makes ECC usable *here*; the 2024.3 crash itself cannot be reproduced on this machine — OQ2 will be answered "for 2022.3_1" |
| D2 | Step 2 | plan: "run tools/accgen/accgen.sh (flow R)" | accgen.sh dies with exit 4 on RHEL: `set -e` + util-linux `rename` returning 4 on no-match (`accgen.sh:361-370`; verified with a standalone rename test) | skeleton hand-generated per the plan's alternative path; upstream-worthy fix: append `|| true` to the rename calls or test matches first — NOT applied locally (no-global-edits rule) |
| D3 | Step 2 | plan assumed accgen output is correct | `accgen.sh:374` has `s/cc_full_name/` (typo; old tree: `s/acc_full_name/`), which would generate module `apulp_cluster_rtl_basic_dma64` | hand-generation used the correct pattern; flagged for upstream |
| D4 | Step 3 | filelist via the reference's target set incl. `-t test` | `-t test` dropped to avoid dependency-TB bloat → lost `riscv_tracer.sv` (guarded by `any(test, cv32e40p_include_tracer)`, `vendor/riscv/Bender.yml:50`) | added `-t cv32e40p_include_tracer`; mock UARTs appended explicitly |
| D5 | Step 3 | plan: carry the reference's two synthesis-fix patches | with `-t mchan` neither patched file/branch is compiled at all | no patches carried from the reference; revisit at rung 6 (Vivado) |
| D7 | Step 8 gate | plan R2 focused on ECC elaboration ICEs | the ICE that actually bit is vlog's deprecated `-novopt` path (ini `VoptFlow=0`) on `id_queue.sv`; fixed via `ACC_MODELSIM_VLOGOPT += -vopt` | see Step 8 gate log; upstream-report candidate for Siemens |
| D8 | Step 8 gate | `-t cv32e40p_include_tracer` assumed self-contained | its `CV32E40P_TRACE_EXECUTION` define drags UVM into the CV32 tracer | define filtered in gen_vendor.sh; RISCY tracer retained |
| D9 | Step 8 gate | socketgen assumed correct for any XML | `desc` >31 chars hits a truncation off-by-one (`socketgen.py:188`, 30 vs 31) | desc shortened; upstream fix `[0:31]` |
| D10 | Step 8 gate | simlib cache assumed built with the PATH simulator | Vivado compile_simlib auto-detected ModelSim DE despite Questa-first PATH | cache rebuilt with explicit `-simulator questa -simulator_exec_path`; documented in README/report |
| D12 | Rung 3 | plan: reuse reference `stimuli.h` as printf test | sparse/unpadded artifact; cores jump through uninitialized data (never a validated test — the reference README's test was optmatmul) | dropped; replaced by generated `rung3_uart.h` (toolchain-free) |
| D13 | Rung 4 | plan/ECC-first policy: ship full-ECC config (probe passed) | **TCDM bank ECC corrupts data under DMA+core concurrency with HwpePresent=0** (upstream-untested combination); elaboration-clean ≠ functionally-clean. Root cause later pinned (see D14): `hci_ecc_interconnect`'s `no_hwpe_branch_gen` binds the ECC banks to the *un-encoded* memory interface | bank ECC off for bring-up (patches/pulp_cluster/0002); interconnect kept; re-evaluate at rung 5 with HWPEs on |
| D14 | Rung-4 re-exam (HCI warnings) | plan assumed a passing matmul + ECC probe = green rung 4 | 5060 `HCI RQ-4` warnings + ~144 `vsim-3837` double-drives in the transcript, from the **ungated `post_lic_encoding` ECC-encode chain** in `hci_ecc_interconnect` when `N_HWPE==0` — same deficiency as D13. Upstream never hits it (TB always `HwpePresent:1`); still ungated in `hci v2.6.0`; old integration avoided it entirely by using plain `hci_interconnect` (→ R2/OQ2). | `patches/hci/0001` gates the dead chain (warnings/double-drive → 0); `VSIMOPT -suppress 3837` **removed** (no longer needed, no assertion suppressed). Rung 4 transcript-clean & green |
| D15 | Phase 2 (multiOT comparison) | assumption: `make sim` compiles the accelerator RTL currently in `hw/src` | **it compiles the installed copy under `tech/<lib>/acc/`**, which only `make <acc>-hls` refreshes; the first two "comparison runs" had actually FAILED at VHDL binding (vcom-1484 against the stale entity), the failure was masked by a `\| tail` pipeline exit code, and the stale transcript read like a bit-identical null result | `make pulp_cluster_rtl-hls` after any `hw/src` edit; transcript **moved** (not copied) before every run; a run is believed only with 3 freshness proofs (new transcript timestamp, its own `a2d_trace.log`, real make exit code). Full account: §12.4 |
| D6 | Step 3 | plan: cluster elaborates as-is (upstream TB evidence) | upstream `no_hwpe_gen` branch is stale HCI-v1 code (`s_hci_hwpe[0].boffs/.lrdy` don't exist in pinned `hci_core_intf`); never elaborated upstream because their TB has HWPEs on | new local patch `patches/0001-…-no_hwpe_gen-…`, upstream-candidate |

---

## 7. How to reproduce from a fresh clone

*(HUMAN ACTION items marked)*

1. `git clone https://github.com/eugeniomuscinelli/esp.git && cd esp && git checkout pulp-cluster-clean-integration`
2. Submodules (all required for `make sim`):
   `git submodule update --init --recursive rtl/cores/ariane/ariane` **except `tb/dromajo`**
   (init per-path as in §3/Step 8, or accept the dromajo clone), plus
   `git submodule update --init rtl/caches/esp-caches soft/ariane/riscv-tests soft/ariane/riscv-pk`
   (`riscv-tests` is `--recursive` for its `env`).
3. `source /opt/cad/scripts/tools_env.sh` — answer `2` (questa); non-interactively the
   default is ModelSim, so `export PATH=/opt/cad/questa/bin:$PATH` after sourcing.
   **Questa 2022.3_1 is the only working simulator here** (ModelSim DE 2023.2 ICEs on
   PULP sources; see Step 8 gate).
4. `make -C accelerators/rtl/pulp_cluster_rtl vendor` — clones pulp_cluster @07988cd,
   applies `patches/{pulp_cluster,common_cells}/*`, checks out the 34 locked deps,
   regenerates `pulp_cluster_rtl.sverilog`/`.defines`. Then
   `make -C accelerators/rtl/pulp_cluster_rtl check` (four-constant invariant).
5. **Xilinx simlib cache (one-time, ~40 min):** ESP's own rule lets Vivado auto-pick
   ModelSim and seds `VoptFlow=0` — both wrong for this setup. Build it manually
   instead: run `compile_simlib -directory xilinx_lib -simulator questa
   -simulator_exec_path /opt/cad/questa/bin -library all` in
   `.cache/modelsim/`, then apply the ini post-edits of `utils/make/modelsim.mk:95-104`
   **except** the `VoptFlow` sed (the exact script is quoted in the Step 8 gate log;
   scratchpad `simlib_questa_vopt.sh`). SystemC library failures (sccom vs. g++ 8) are
   expected and harmless for this design.
6. `cd socs/xilinx-vc707-xc7vx485t && make pulp_cluster_rtl-hls`
7. **HUMAN ACTION** — `make esp-xconfig` (GUI): rows 2 / cols 2; coherence-NoC and
   DMA-NoC bitwidths **64/64**; tiles (0,0) mem, (0,1) cpu, (1,0) acc =
   **PULP_CLUSTER_RTL / basic_dma64** (no L2, no DVFS), (1,1) IO; Generate.
8. `make pulp_cluster_rtl-baremetal` (header selected by `HEADER_FILE` in
   `sw/baremetal/pulp_cluster.c`; default `rung2_smoke.h`).
9. `TEST_PROGRAM=./soft-build/ariane/baremetal/pulp_cluster_rtl.exe make sim` — the
   committed `vsim.tcl` runs in 1 ms chunks and quits on a verdict; expected transcript
   lines: rung 2 `RUNG2 PASS: buffer[0x9000] = expected magic`; rung 3 (rung3_uart.h)
   `[TB UART] RUNG3 OK`; rung 4 (optmatmul_M8_8x8.h) `== test: matrixMul -> success` +
   `==== SUMMARY: SUCCESS`. Delete `vsim.tcl` for an interactive session.

---

## 8. Risk register revisit

| Risk | Status |
|---|---|
| R1 (package coexistence) | **RETIRED** (Step 1 PASS, Questa 2022.3_1) |
| R2 (ECC elaboration error) | **RETIRED** as an *elaboration* risk (ECC probe PASS). Two related *functional/protocol* findings replaced it, both traced to one root cause — `hci_ecc_interconnect` only wires memory-side ECC + assertions correctly for `N_HWPE>0`: (D13) ECC-TCDM data corruption → bank ECC off; (D14) `HCI RQ-4` warning storm + double-drive → dangling-chain gated (`patches/hci/0001`). Directly connects to OQ2: the old integration's swap to plain `hci_interconnect` sidestepped *both* — its ECC removal was structurally correct on the memory side, not just a Questa-crash dodge |
| R4 (inherited vlog flags) | **MATERIALIZED as predicted, MITIGATED**: `-pedanticerrors` promotions (vlog-2986, vlog-2577) + `-svinputport=net` default → hook value `ACC_MODELSIM_VLOGOPT = -suppress 2986 -suppress 2577 -svinputport=relaxed`; final confirmation when the real make rule runs (Step 5) |
| R9 (vendor reproducibility) | addressed by design: flattened machine-independent vendor paths, self-checking regeneration script, no gitlinks, no absolute paths committed |
| R3 (translator corner cases) | RETIRED: directed TBs + in-system SLVERR path proved out (caught the stimuli.h wild fetches) |
| R5 (global ACC hooks) | open by design (single acc per design); documented |
| R6 (boot plumbing) | RETIRED: rungs 2–4 boot correctly via boot_offset register (`L2Base+0x8080` by construction) |
| R7 (four-constant invariant) | RETIRED: `make check` green; enforced by script |
| R8 (X-prop from undriven AXI) | RETIRED: cluster_control drives all outputs; TB checks for X |
| R10 (latent cluster bugs) | partially MATERIALIZED beyond prediction: no_hwpe_gen tie-off (D6), ECC-TCDM corruption (D13) — both patched/documented |
| R11 (make qsim habit) | documented in README; unchanged risk |
| R12 (window too small) | open, not hit (matmul fits comfortably) |

---

## 9. Evidence appendix

- Step 1 artifacts: `/tmp/claude-1000/-home-eugenio/bdaaa42d-ff18-4c88-b540-0a08f0a0e5ba/scratchpad/step1_smoke/{work_side.sv,lib_side.sv,smoke_top.sv}`; output transcript quoted verbatim in §3.
- Tool versions: `vsim -version` outputs quoted in §2 (both installs), `vivado -version`,
  `riscv64-unknown-elf-gcc --version`.
- Env script: `/opt/cad/scripts/tools_env.sh` (read; modelsim default + interactive questa
  choice + venv activation).

---

## 10. Authoring new cluster tests

**Plain language.** To run a *new* C program on the PULP-cluster-in-ESP you compile it in the
standalone cluster ecosystem (pulp-runtime + a RISC-V cross-compiler), convert the resulting
ELF into a C header of `{address, 64-bit word}` pairs, and drop that header into our host app.
The test is *valid* for the ESP-integrated cluster if — and only if — four things line up:
the program is linked at the addresses our wrapper actually decodes, its entry point is where
our boot register points, its `printf` writes to the address our mock UART listens on, and it
uses no hardware our configuration doesn't have (no HWPEs, no ECC-counter expectations, and —
with the currently installed compiler — no Xpulp-only instructions). The good news: a fully
working instance of this flow already exists on this machine in `/home/eugenio/cluster_generator`
(a pulp_cluster clone at the *same commit* our vendor tree pins, with an ESP-retargeted
pulp-runtime inside, a documented HOWTO, and two already-built ELFs to compare against), and
the required toolchain is installed and verified. The one fragile spot — the pulp-runtime
edits existed *only* as an uncommitted working tree — is now closed: they are recorded in this
repo as `patches/pulp-runtime/0001-esp-retarget-astral-cluster.patch` (verified to apply
cleanly on the pinned upstream commit). Everything below is code-grounded with file:line
evidence; nothing needs re-deriving.

### 10.1 Hardware-configuration parity — what actually constrains the software

The single source of truth for "the cluster the test must target" is the wrapper's
`PulpClusterCfg` literal
(`hw/src/pulp_cluster_rtl_basic_dma64/pulp_cluster_rtl_basic_dma64.sv:100-151`, struct type
`pulp_cluster_cfg_t` in `vendor/pulp_cluster/packages/pulp_cluster_package.sv:48-147`, passed
unconditionally at wrapper line 262 — unlike the standalone TB, no `USE_PULP_PARAMETERS`
guard).

**Software-relevant** (changes memory map / ISA / visible cores / boot / peripherals — a test
built for the wrong value is invalid):

| Cfg field (wrapper line) | our value | what software sees |
|---|---|---|
| `CoreType` (:101) | `RISCY` | RI5CY (`riscv_core`, `PULP_CLUSTER=1`): RV32IMC **+ Xpulp** cores (`core_region.sv:235-242`). Xpulp is *available in hardware*; whether the binary uses it is a toolchain choice (§10.3) |
| `NumCores` (:102) | 8 | 8 harts; 8 boot-address registers (periph +0x40..0x5F); `mhartid = {21'b0, cluster_id[5:0], 1'b0, core_id[3:0]}` (`core_region.sv:147`) with wrapper `ClustIdx='h1` (:87) → hart IDs **0x20-0x27** (this is why the trace files are named `trace_core_01_0000002x`) |
| `TcdmSize` (:112) | 128 KiB | L1 data = 0x50000000-0x5001FFFF. Linker `L1 LENGTH = 0x1FFFC` and the crt0 sync flag `0x5001FFF0` (= TCDM top − 0x10) must match — both are part of the recorded runtime patch |
| `L2BaseAddr`/`L2Size` (:91-92) | `0xA0103680` / 3 MiB | the cluster's *entire* view of main memory (ESP DMA window). Constants #1-4 of the four-constant invariant live here |
| `BootAddr` (:97) | `L2BaseAddr + 'h8080` | must equal the ELF entry (`_start`); our host app programs `boot_offset = 0x8080` |
| `ClusterAlias`/`Base` (:108-109) | 1 / 0 | low alias pages usable by the runtime: 0x00000000 TCDM, +0x100000 test&set, +0x200000 demux periphs (`data_periph_demux.sv:201-214`) |
| `HwpePresent` (:114) | **0** | tests must not program HWPEs; periph window +0x1000-0x1400 is dead, HCI-ECC counters (+0x2800) read zeros |
| `NumSlvPeriphs` (:107) | 12 | peripheral map at 0x50200000: EoC +0x0000, Timer +0x0400, EventUnit +0x0800, (HWPE +0x1000, dead), ICacheCtrl +0x1400, DMA-CL +0x1800, DMA-FC +0x1C00, HMR +0x2000, TCDM scrubber +0x2400, HWPE-HCI-ECC +0x2800 (`pulp_cluster_package.sv:156-168`) |
| wrapper xbar `UartBase` (:93) | `0x03002000` (4 KiB window) | where `printf` bytes must land (mock UART; §10.2) |

**Hardware-only** (invisible to correct software — no test-authoring impact): all CDC/sync
depths (`NumSyncStages/SyncStages/AxiCdcSyncStages/AxiCdcLogDepth`, :110,143-145), AXI ID/user
widths, `TcdmNumBank` 16 (performance only), `UseHci` 1 (interconnect topology; TCDM semantics
unchanged), DMA depths (`DmaNumPlugs/DmaNumOutstandingBursts/DmaBurstLength`, :103-105 —
mchan splits transfers transparently), ECC/HMR presence (with ECC off, the scrubber/ECC
registers read deterministic zeros — `tcdm_banks_wrap.sv:183-191`).

**Standalone-repo parity** (only needed if you also want to *simulate* the test standalone —
authoring does **not** require it, see 10.4): the clean repo's TB config
(`/home/eugenio/pulp_cluster/tb/pulp_cluster_tb.sv`) already matches our wrapper in CoreType/
NumCores/TCDM/ClustBase/periph offsets/UART window; the full delta is **three edit groups**:
`L2BaseAddr 'h78000000→'hA0103680` (tb:64), `L2Size 'h10000000→'h00300000` (tb:65) — BootAddr
then self-derives via the same `+ 'h8080` formula (tb:66) — and `HwpePresent 1→0, HwpeCfg
'{NumHwpes:3, HwpeList:{SOFTEX,NEUREKA,REDMULE}}→'{0,'0}, HwpeNumPorts 9→0` (tb:292-294). The
Cfg literal only takes effect because the Makefile passes `-D USE_PULP_PARAMETERS`
(`Makefile:34-49`). Note loudly: `cluster_generator`'s own TB was **never** retargeted (still
`0x78000000`, HWPEs on) — the original author authored tests without ever simulating them
standalone, and its `make build` is broken on ModelSim DE 2023.2 anyway
(`doc/ESP_HEADER_HOWTO.md` §8: "You do not need make build").

### 10.2 Memory map, linker script, boot, and stdout

The four-constant invariant, concrete: **(1)** wrapper `L2BaseAddr = 0xA0103680` (RTL single
source); **(2)** every header's `BASE_ADDRESS = 0xA0103680`; **(3)** translator
`BASE_ADDR = 0xA0103680` (parameterized from the wrapper); **(4)** pulp-runtime linker
`L2 ORIGIN = 0xA0103680` — plus the boot leg `BootAddr = L2Base + 0x8080` = header entry.
`make check` (`scripts/check_constants.sh`) verifies legs 1-3 always and leg 4 **only when**
`PULP_RUNTIME` is exported (else it prints "linker-script leg skipped") — so run it as shown
in 10.4.

The runtime side lives in **pulp-platform/pulp-runtime @ `3ba9a349`** (branch `astral` — the
submodule pin of the cluster repo) with exactly four modified files, recorded as
`patches/pulp-runtime/0001-esp-retarget-astral-cluster.patch` in this repo (captured from the
only existing copy, the dirty tree at `/home/eugenio/cluster_generator/pulp-runtime`; verified
`git apply --check`-clean on pristine 3ba9a349):

| file | edit | why |
|---|---|---|
| `include/archi/chips/astral-cluster/memory_map.h` | `ARCHI_L2_PRIV0/SHARED_ADDR 0x78000000→0xA0103680`, `PRIV1→0xA010B680`, `SHARED_SIZE 0x2F0000→0x300000` | runtime's view of L2 = our window |
| `kernel/chips/astral-cluster/link.ld` | `L2 ORIGIN 0x78000000→0xA0103680, LENGTH 0x20000→0x300000`; `L1 LENGTH 0x3FFFC→0x1FFFC` | link at the window; L1 sized to our 128 KiB TCDM (the file's own comment block documents the TcdmSize coupling) |
| `kernel/crt0.S` | PE sync flag `0x5003FFF0→0x5001FFF0` (both CHIP_CARFIELD and CHIP_ASTRAL branches, 2 code sites) | flag sits at TCDM top − 0x10; must exist in a 128 KiB TCDM |
| `kernel/hmr_synch.c` (:367,:398) | `p.elw` → `.insn i 0x0B, 0x6, x0, …` (identical encoding) | lets a non-PULP assembler build the runtime; behavioral no-op |

**Why the entry is `+0x8080`** (resolves the HOWTO's one error): `link.ld` places `.vectors`
at `MAX(ALIGN(256), ORIGIN(L2) + 0x8000)`; the FC data sections in "private bank 0" end well
below +0x8000 (readelf: `.bss` ends `0xA010712C`), so `.vectors` lands at `0xA010B680`
(= `ARCHI_L2_PRIV1_ADDR`). The vector table is 32 × 4-byte non-compressed jumps = 0x80 bytes,
and `crt0.S` puts `_start` at `.org 0x80` inside `.vectors` → ELF entry **`0xA010B700`**
= `L2Base + 0x8080` = wrapper `BootAddr`. (`doc/ESP_HEADER_HOWTO.md:200-201` says the cluster
"boots from 0xA010B680" — that is the *vectors base*, not the boot address; our wrapper
boots the cores directly at `_start`. The HOWTO also omits the crt0 sync-flag edit from its
patch list. Trust the recorded patch + this section over the HOWTO where they differ.)

**How `printf` reaches our transcript**: `ARCHI_STDOUT_ADDR = 0x03002000` is *upstream* in
this runtime (not part of the diff); `pos_libc_putc_stdout()` stores each byte to it
(`lib/libc/minimal/io.c:226`), the wrapper xbar window 0x03002000-0x03003000 routes it to
`mock_uart_axi`, which prints `[TB UART] …` lines. **Gotcha:** this path is only taken with
`CONFIG_IO_UART=0` (the default, `rules/pulpos/configs/default.mk:6`). Building with
`platform=fpga` or `io=uart` flips it to the UDMA UART driver — hardware our wrapper does not
have — and `printf` silently vanishes. Build tests with the plain `make clean all` of 10.4.

### 10.3 Toolchain — what is required, what is installed, what you give up

| | default (upstream flow) | **working recipe on this host** |
|---|---|---|
| compiler | `riscv32-unknown-elf-gcc` — the PULP fork `pulp-platform/pulp-riscv-gcc` (GCC 7.1.1) | **xPack `riscv-none-elf-gcc` 15.2.0-1** at `~/toolchains/xpack-riscv-none-elf-gcc-15.2.0-1` (verified present) |
| `-march`/`-mabi` | `rv32imcxgap9 / ilp32` (`pulp-runtime/rules/pulpos/targets/astral-cluster.mk:20-26`) | `rv32imc_zicsr_zifencei / ilp32` + `-DRV_ISA_RV32` (generic-RV32 runtime paths, no `__builtin_pulp_*`) |
| status on this host | **not installed** (no `riscv32-unknown-elf-gcc` anywhere; the IIS toolchain branch in `env/astral-env.sh:9-20` is inert — no `/etc/iis.version`) | installed, working; selected by `env/esp-toolchain.sh` (`PULPD_RISCV=riscv-none-elf` + PATH + flags) |

Ground truth from the ELFs already on disk
(`regression-tests/astral/{hello,parMatrixMul32_esp}/build/test/test`): `.comment` =
"GCC: (xPack GNU RISC-V Embedded GCC x86_64) 15.2.0", `Tag_RISCV_arch` =
`rv32i2p1_m2p0_c2p0_zicsr2p0_zifencei2p0_zmmul1p0_zca1p0` — exactly plain RV32IMC, soft-float,
**zero Xpulp instructions**. (Read attributes with the *xPack* readelf; the RHEL8 host
`readelf` 2.30 silently prints nothing for these ELFs.) `/opt/riscv` (vanilla riscv-gnu GCC
9.2.0, RV64-only: `-print-multi-lib` = `.;`) is **insufficient**: it compiles rv32 objects but
cannot link them (RV64-only libgcc; ld segfaults) — do not use it for cluster tests.
Implications of the xPack choice: the RI5CY cores *have* Xpulp (the prebuilt
`optmatmul_M8_8x8.h`, compiled with the PULP fork elsewhere, uses `pv.shuffle2.b` etc.), but
newly-built tests run generic RV32IMC — functionally complete (event unit, barriers, timers
all reachable via `RV_ISA_RV32` fallback paths; the `p.elw` patch covers the one inline-asm
use), just without SIMD/hw-loop performance. For performance studies install the PULP fork
and set `PULPD_RISCV=riscv32-unknown-elf` (HOWTO §8); everything else in the flow is
unchanged.

### 10.4 End-to-end recipe (copy-paste)

```sh
# ---- environment (every new shell) -------------------------------------------
source /opt/cad/scripts/tools_env.sh          # CAD tools + activates ~/venvs/esp311 (pyelftools)
cd /home/eugenio/cluster_generator
source env/esp-toolchain.sh                   # xPack gcc + rv32imc flags + runtime target
                                              # (prints the resolved gcc; errors out if missing)

# ---- write the test ----------------------------------------------------------
mkdir -p regression-tests/astral/mytest && cd regression-tests/astral/mytest
cat > mytest.c   # your code; printf() and the pulp-runtime API are available
cat > Makefile <<'MK'
PULP_APP = test
PULP_APP_SRCS = mytest.c
PULP_CFLAGS = -O3
include $(PULP_SDK_HOME)/install/rules/pulp.mk
MK

# ---- build + convert ---------------------------------------------------------
make clean all                                # -> build/test/test (RV32 ELF, entry 0xA010B700)
riscv-none-elf-readelf -h build/test/test | grep Entry     # must print 0xa010b700
$PULPRT_HOME/bin/stim_utils.py --binary=build/test/test --vectors=stim.txt
FIRST_A=$(grep -n '^A' stim.txt | head -1 | cut -d: -f1)   # drop the 0x5xxxxxxx L1 image:
sed -n "${FIRST_A},\$p" stim.txt > stim_trimmed.txt        # ESP loads only the L2 window
head -1 stim_trimmed.txt                                   # must start with A0103680_
python /home/eugenio/cluster_test_generator/generate_padded_stimuli.py stim_trimmed.txt
                                              # -> ./stimuli.h (dense, zero-padded)

# ---- into ESP ----------------------------------------------------------------
cp stimuli.h /home/eugenio/esp_clean_integration_target/accelerators/rtl/pulp_cluster_rtl/sw/baremetal/mytest.h
cd /home/eugenio/esp_clean_integration_target/accelerators/rtl/pulp_cluster_rtl
#   edit sw/baremetal/pulp_cluster.c: #define HEADER_FILE "mytest.h"      (one line)
PULP_RUNTIME=/home/eugenio/cluster_generator/pulp-runtime make check      # all 4 constant legs
cd ../../../socs/xilinx-vc707-xc7vx485t
make pulp_cluster_rtl-baremetal
TEST_PROGRAM=./soft-build/ariane/baremetal/pulp_cluster_rtl.exe make sim  # vsim.tcl auto-runs
```

Manual/fragile steps, flagged: **(a)** the L1 trim (`sed`) — `generate_padded_stimuli.py`
takes `BASE_ADDRESS = lowest address present` (`generate_padded_stimuli.py:18`), so an
untrimmed file silently produces a header based at 0x0/0x50000000 that the host app would
load wrong; the `head -1` check is the guard. No improved copy of the generator exists in our
tree yet (deliberate: `gen_rung2_stimuli.py` documents the same header contract; folding the
trim into a vendored copy of the generator is a small, worthwhile follow-up). **(b)** the
`HEADER_FILE` edit in `pulp_cluster.c` (the host app sizes its buffer from the header span
and checks `BASE_ADDRESS` at compile time). **(c)** dropped-L1 semantics: the trimmed
`0x5xxxxxxx` lines are the pre-loaded L1 image a JTAG loader would use; in ESP nothing
pre-loads TCDM — crt0/runtime initialize what they need, and `.data`-in-L1 relies on the
runtime's own copy path. The regression tests under `astral/` (incl. both matmuls and
`hello`) are built this way and work; a test that *statically* places initialized data in L1
outside the runtime's init path would silently lose it — keep initialized data in L2 (the
default) if in doubt.

### 10.5 Divergence check — clean repo vs. `cluster_generator` vs. our vendor tree

All three trees are pulp_cluster **`07988cd01c359a81804820135927bc04da3c25cd`** with
byte-identical `Bender.lock` pins (`gen_vendor.sh` clones that rev and runs `bender checkout`
against the cluster's own committed lock — no re-resolution). Cluster RTL proper
(`rtl/`, `packages/`, `include/`): `diff -rq` clean repo ↔ `cluster_generator` = **byte
identical**; our `vendor/pulp_cluster` = pristine 07988cd + exactly our two cluster patches
(git status inside the vendor checkout shows `rtl/pulp_cluster.sv` as the only modified file).
Differences and their test-validity impact:

| tree | deltas vs. upstream @07988cd | SW-visible for a test? |
|---|---|---|
| `/home/eugenio/pulp_cluster` (clean) | none | — (valid as-is) |
| `/home/eugenio/cluster_generator` | Makefile/start.tcl/tb: ModelSim-DE workarounds only; untracked `scripts/patches/{common_cells,axi,cv32e40p}.patch`: sim-tool/TB-side only; **pulp-runtime dirty tree = the ESP retarget** (now recorded here) | only the runtime edits — which are exactly what makes tests *valid* |
| our `vendor/` | `patches/pulp_cluster/0001` (no_hwpe elaboration fix), `0002` (bank ECC off), `patches/hci/0001` (dangling-chain gate), `patches/common_cells/0001` (syntax backport) | **none for ordinary programs**: elaboration-only, or data-transparent (ECC off ⇒ scrubber/ECC-manager registers at periph +0x2400/+0x2800 read zeros — only a test that deliberately reads ECC counters would notice) |

**Verdict:** build tests in `/home/eugenio/cluster_generator` (same RTL, plus it holds the
retargeted runtime and the test corpus); the clean repo needs *no* changes for test
*validity* — only the §10.1 TB edits if you additionally want standalone simulation. Two
configuration constraints carry over regardless of tree: no HWPE use, no dependence on ECC
correction/counters (both re-checked at rung 5).

---

## 11. Phase 1 — self-checking matmul baseline

**Plain language.** We now have a matrix-multiplication test that *proves its own results
are right* and reports cycle numbers we can trust. It works like a real accelerator
workload: the host CPU (Ariane) puts two input matrices into the shared buffer, starts the
cluster, and the cluster DMAs the inputs into its local memory, multiplies them on all
8 cores, and DMAs the result back. The host then recomputes the same product itself — a
completely independent processor, instruction set, and compiler — and compares every
element. The run prints an unambiguous verdict (`MATMUL PASS: N=8, 0/64 mismatches`) plus
four separate cycle counts that cleanly split "moving data" from "computing", because
Phase 2 will change only the data-moving part. Result: **PASS on the first run**, with the
baseline numbers recorded below. The one number to watch in Phase 2: **399 cycles of
DMA-in and 155 cycles of DMA-out** (the memory-path windows); compute (1217 cycles) should
not move.

### 11.1 How it checks itself (golden model)

The chosen golden model is **host-side recomputation on Ariane**, not an embedded constant
table. Justification: the host already owns the inputs (it writes them), so the reference
costs nothing to maintain, scales with the matrix size automatically, and is computed by a
different core (RV64 Ariane vs. RV32 RI5CY), different compiler (riscv64-unknown-elf-gcc
vs. xPack riscv-none-elf-gcc 15.2), and different arithmetic path — a common-mode error in
the cluster toolchain cannot silently agree with it.

Protocol (single source of truth: `sw/baremetal/matmul_selfcheck_proto.h`, included by
*both* sides; the host `_Static_assert`s its base against the header's `BASE_ADDRESS`):
fixed exchange region in the L2 window at +512 KiB — `A` @ +0x80000, `B` @ +0x84000 (host
writes both before start, deterministic pattern `MM_A_VAL/MM_B_VAL`, |values| ≤ 30),
`C` @ +0x88000 and an 8-word perf/status block @ +0x8C000 (cluster writes; the DONE magic
`0x4D4D4F4B` is written **last**, and the host refuses to judge a run whose magic or N
don't match — a stale image cannot fake a PASS). Datatype **int32**, row-major, N=8 today
(N=16/32 supported: edit `MM_N` in the proto header, re-run `gen_header.sh`, rebuild the
host app — the runtime check catches any half-rebuild). Region safety and the 1-of-4 TLB
chunks argument: §10.2 evidence plus the layout study (image+runtime end < +0x14000; the
runtime's shared-L2 heap has no consumers here; host buffer 576 KiB ends ~434 KiB before
the 2 MiB `axi_ram_sim` wrap).

### 11.2 What each cycle number means (load-bearing for Phase 2)

All four primary windows are **wall-clock cluster cycles** from the free-running cluster
timer (HI half, `timer_v2` at periph +0x400, started once and only *read* at snapshots).
This choice is deliberate: the RI5CY perf counters (PCCR*) sit on the **gated core clock**
and freeze whenever the event unit puts a core to sleep — which is exactly what
`plp_dma_wait()` and `synch_barrier()` do (`event_unit_core.sv:162` gates on any
sleep-address read; `pulp_cluster.sv:935` puts the whole core, counters included, on
`clk_core[i]`). A PCCR-based "DMA window" would therefore *hide* the DMA latency Phase 2
changes. The old test's numbers illustrate the trap: its "`Perf CYCLES: 606`" was PCCR0
(active cycles) over the *DMA-in* window while "`execution time: 573`" was the *timer*
over the *compute* window — two different counters over two different regions, not
comparable with each other (§ evidence: `bench.c:185-202`, `matrixMul.c:80-99,124-196`).

Windows, snapshotted on core 0 (`t0..t3`), definitions fixed in the proto header:

| field | window | includes | excludes |
|---|---|---|---|
| `DMA_IN` = t1−t0 | two `plp_dma_memcpy` (A then B, 256 B each at N=8), L2→TCDM, sequential with waits | mchan programming, transfer, both event-waits | everything else |
| `COMPUTE` = t2−t1 | barrier → 8-core row-split int32 MAC → barrier | both barrier crossings, per-core PCCR enable, cold i-cache refills of the loop | DMA, init, printing |
| `DMA_OUT` = t3−t2 | one `plp_dma_memcpy` C, TCDM→L2 | as DMA_IN | |
| `TOTAL` = t3−t0 | superset | | boot/crt0, host setup, checking, printf |
| `COMPUTE_ACT0` | core-0's own MAC slice | PCCR0 **active** cycles only (sleep frozen) | wall time in sleeps |
| `CAL` | one back-to-back timer-read pair | the per-snapshot read overhead | |

Systematic error: each boundary carries one timer read; the measured `CAL=64` cycles says
snapshot overhead is non-negligible at N=8 scale (~4% of TOTAL) and must be quoted with
the numbers. The counts are deterministic (bit-identical across repeated runs — see 11.4):
the whole SoC sim is deterministic and the test has no data-dependent control flow.

### 11.3 Files, build, and run (delta over the §10.4 recipe)

New in-tree (everything under the accelerator, per the no-global-edits rule):
`sw/baremetal/matmul_selfcheck_proto.h` (protocol + window definitions),
`sw/cluster_tests/matmul_selfcheck/{matmul_selfcheck.c, Makefile, gen_header.sh}`
(cluster test; builds **out-of-tree** against the read-only
`cluster_generator/pulp-runtime` — verified to leave that repo untouched), and the
`MATMUL_SELFCHECK` path in `sw/baremetal/pulp_cluster.c` (buffer growth to +0x90000,
input staging, golden compare, verdict + cycle print; the terminal `[pulp] done` line now
prints *after* all verdicts so the vsim.tcl watcher cannot truncate them).
`gen_header.sh` automates the §10.4 flow end-to-end and **de-manualizes the fragile
L1-trim** (hard guards: ELF entry must be 0xA010B700, trimmed stim must start at
`A0103680_`, no non-A rows may survive); it appends the proto include +
`#define MATMUL_SELFCHECK 1` to the generated header, so selecting
`HEADER_FILE "matmul_selfcheck_8x8.h"` is the only host-side switch.

Run: `source /opt/cad/scripts/tools_env.sh` → `./gen_header.sh` (in the test dir) →
`make pulp_cluster_rtl-baremetal` → `TEST_PROGRAM=./soft-build/ariane/baremetal/
pulp_cluster_rtl.exe make sim` — **with `PATH=/opt/cad/questa/bin:$PATH` prepended**: this
Phase re-confirmed the §2 simulator trap the hard way (a non-interactive shell gets
ModelSim DE from `tools_env.sh` even when asked for questa; DE then rebuilds the acc
library and dies on its documented `vgentd.c` codegen ICE at `axi_lite_dw_converter.sv` —
the failed attempt cost one acc-lib rebuild, nothing else). The old tree's
`pulp_reproducibility/README.md` was reconciled step-by-step against §7/§10 during this
phase: every step diverges (branch `bologna`, acc name `pulp_rtl`, `HEADER_NAME`,
`make qsim`, deleted `pulp-filelist-qcompile` flow, hand-edited `design.mk`) except the
xconfig tile layout; its one carry-over worth keeping is the stale-simlib failure
signature (remedy: delete and rebuild the `.cache/modelsim` simlib with Questa, §7).

### 11.4 Results and the golden baseline record

Run 1 (fresh acc-lib Questa build, 20 min wall): transcript-clean — **zero** HCI warnings,
**zero** SLVERR warnings (this image happens to contain no below-window JAL-lookalike
patterns, cf. the §3 SLVERR disposition), the only "errors" being ESP's normal
`** Failure: Program Completed!` end-of-sim assert (`top.vhd:203`, counted twice by vsim —
that is how every passing ESP baremetal sim terminates). Cluster print and host readback
of the perf block agree word-for-word, which also re-validates the sub-word RMW write path
through the translator.

```
[TB UART] [mm] N=8 dma_in=399 compute=1217 dma_out=155 total=1771 act0=1087 cal=64
[pulp] MATMUL PASS: N=8, 0/64 mismatches
[pulp] MATMUL cycles: dma_in=399 compute=1217 dma_out=155 total=1771 (compute_act0=1087, timer_read_cal=64)
```

**GOLDEN BASELINE (Phase-1 → Phase-2 comparison anchor)**

| item | value |
|---|---|
| tree | `esp_clean_integration_target`, branch `pulp-cluster-clean-integration`; **RTL state = commit `f776f8a8`** (the Phase-1 commit adds sw/verif/doc only — zero RTL change) |
| SoC | VC707 2×2, NoC 64/64: (0,0) mem, (0,1) cpu Ariane, (1,0) acc `PULP_CLUSTER_RTL/basic_dma64`, (1,1) IO (§7 xconfig record) |
| cluster Cfg | RI5CY ×8 @ hart 0x20-0x27, TCDM 128 KiB/16 banks, `HwpePresent=0`, ECC HCI interconnect with bank ECC off, patches `pulp_cluster/0001+0002`, `hci/0001`, `common_cells/0001` (§10.1/§10.5) |
| test | `matmul_selfcheck_8x8.h` (5149 stimuli, entry 0xA010B700), **N=8 int32**, inputs `MM_A_VAL/MM_B_VAL`, proto header as committed in the Phase-1 commit |
| cluster toolchain | xPack riscv-none-elf-gcc 15.2.0-1, `-O3 -march=rv32imc_zicsr_zifencei -mabi=ilp32 -DRV_ISA_RV32` (generic RV32IMC — no Xpulp) |
| host | `pulp_cluster.c` @ Phase-1 commit, `BOOT_OFFSET 0x8080`, buffer 576 KiB = 1 TLB chunk (of 4), `ACC_COH_NONE` |
| simulator | Questa 2022.3_1 (`PATH=/opt/cad/questa/bin` — NOT ModelSim DE), `VoptFlow=1`, vsim.tcl chunked-run hook |
| **cycles** | **DMA_IN 399 · COMPUTE 1217 · DMA_OUT 155 · TOTAL 1771** (COMPUTE_ACT0 1087, CAL 64) |
| verdict | `MATMUL PASS: N=8, 0/64 mismatches`; stability: **repeat run bit-identical** (every `[pulp]`/`[mm]` line byte-equal across runs 1 and 2) |

Phase-2 ground rules baked in here: the comparison re-runs *this exact header* with *this
exact host app* and *this measurement definition*; only the socket/DMA-path RTL may
differ. The sensitive metrics are DMA_IN and DMA_OUT (and TOTAL through them); COMPUTE and
COMPUTE_ACT0 are control values that must not move. Note the scale honestly: at N=8 each
DMA window moves only 2×256 B / 1×256 B in 2/1 serialized mchan transfers — if Phase 2
shows little effect here, N=16/32 (one proto-header edit) quadruples/sixteen-folds the
transfer sizes and is the designed escalation path.

---

## 12. Phase 2 — multiOT extension and performance comparison

**Plain language.** ESP's accelerator memory path normally allows only **one** memory
request in flight at a time: the accelerator asks for data, everything waits until that
data has fully returned, and only then can the next request start. The multiOT
("multiple outstanding transactions") extension — developed in the `esp_dma_axi` fork —
lets the socket accept a **second read request while the first is still being served**, so
the fixed cost of starting a request (address translation, packet headers, network hops)
hides under the previous request's data return. We studied that work in depth, judged it
sound, brought it into our tree unmodified, taught our own AXI-to-DMA translator to
actually *use* it (it was itself one-request-at-a-time), and re-ran the **exact** Phase-1
test — same image, same host app, same measurement. Result: **correctness intact
(`MATMUL PASS, 0/64`), DMA-in 399 → 300 cycles (−24.8%), total 1771 → 1670 (−5.7%)**;
compute unchanged (−0.2%) and DMA-out unchanged — both exactly as they should be, since
only the read path gained concurrency. One honest stumble on the way: the first
"comparison run" was an illusion caused by a stale build (§12.4) — it was caught, fixed,
and the guards that catch it are now part of the flow.

### 12.1 What the extension does (study: 3 commits + working tree of `esp_dma_axi`)

Base `a45f2bb8` — the *same* commit our tree builds on, so the diff ports verbatim. Four
cooperating pieces (all evidence file:line-verified by the study workflow, two independent
review passes):

- **NoC tagging**: a 4-bit `DMA_TRAN_ID` is packed into previously-unused DMA header bits
  [34:31] (`nocpackage.vhd:~55-58`); `esp_acc_dma` stamps it on every non-coherent DMA
  request, the memory tile echoes it in the response header — responses become
  self-identifying.
- **`esp_acc_tlb` becomes the dispatcher**: it no longer waits for a transaction to
  complete (`tlb_s5` falls straight through; the old design blocked there,
  stock `esp_acc_tlb.vhd:279-288`), keeps a 16-entry context table, and dispatches page
  fragments back-to-back.
- **`esp_acc_dma` tracks up to `MAX_DMA_READS=2` outstanding reads**: a 2-entry ID FIFO
  records dispatch order; a *decoupled response FSM* (`rsp_idle/passthru/buffer/drain`)
  consumes returns while the main FSM stays free to dispatch; a 256-flit reorder buffer
  absorbs the (at most one) non-head-of-line response; data is delivered to the
  accelerator **in issue order**, tagged (`bufdin_tag`) with a `bufdin_last` marker. The
  accelerator-facing protocol gains `dma_read_ctrl_data_tag` and may re-assert
  `rd_request` with reads outstanding (`esp_acc_dma.vhd:~1025`).
- **`noc2aximst` (memory tile) gets a 2-context table**: AR issued and FSM returns to
  header-accept immediately (`AR_ID={0,ctx}`), responses drained strictly in allocation
  order with `R_ID`-gated ready — a single memory tile never reorders; cross-tile
  reordering is what the ROB catches.

Reads/writes are **mutually fenced** (a new read never issues while a write is pending
and vice versa, `esp_acc_dma.vhd:~1011-1032`); writes themselves remain single-outstanding
and the write datapath is untouched.

### 12.2 Solidity assessment (vs. the mature `esp_nvdla_multiot` memory-side yardstick)

The NVDLA-path fork — architecturally different on the control side but the same
`noc2aximst` module family on the memory side — supplied a 10-rule audit checklist, and
critically its own post-hoc **RAW-ordering fix** (`5ac762b7`): with posted writes and
independent AW/AR paths, a younger read's AR can overtake an older same-address write.
Audit verdict for `esp_dma_axi`: **sound, and *more conservative* than the yardstick** —
because reads and writes are never simultaneously in flight (the mutual fence above), the
RAW/WAR hazard class is excluded *by construction* rather than patched. ID lifecycle,
allocation-order drain, backpressure-when-full and response matching all check out
against the rules. Remaining soft spots, dispositioned rather than "fixed" (the design is
FPGA-validated as committed — 9/9 correctness, 1.01-2.11× concurrent-vs-sequential on its
traffic generator, plus an engineered and a *natural* cross-memory-tile reorder test in
sim): (a) the ROB has no overflow backpressure, but overflow needs a >256-flit non-HOL
response, which needs a *second memory tile* — our SoC has one, so responses are always
head-of-line and the ROB is never even written; (b) 4-bit ID reuse after 16 wraps is safe
at depth 2; (c) depths are hard constants (`MAX_DMA_READS=2`), fine for this evaluation.
The *uncommitted* working tree (triage: coherent increment, not debris — debug register,
natural-reorder tests, an AXI-bridge prototype) was **deliberately not ported**: none of
it changes multiOT function, and the committed state is the validated one.

### 12.3 What was integrated, and what was held constant

Branch **`pulp-cluster-multiot`** (Phase-1 state untouched on
`pulp-cluster-clean-integration` — the baseline stays reproducible). Mechanism: literal
`git apply` of the committed `a45f2bb8..f04c1593` diff for exactly 7 files —
`rtl/noc/nocpackage.vhd`, `rtl/sockets/proxy/{esp_acc_dma,esp_acc_tlb,tile}.vhd`,
`rtl/sockets/proxy/noc2aximst.sv`, `tools/socketgen/{socketgen.py,
templates/noc_interface.vhd}` — applied clean (our socket area was pristine at the shared
base). Deliberately skipped: their `utils/make` simlib changes (our simulator setup is
working and documented), accgen changes, test-vehicle accelerators, and all uncommitted
hunks. `make socketgen` then regenerated `socketgen/noc_pulp_cluster_rtl.vhd` with the
tag wiring (no GUI step — same `.esp_config`).

**Our side of the extension** (this is *part of* the multiOT change, stated per the
ground rules): the wrapper gains the three generated ports, and `axi2dmafifo` gains a
**pipelined read-issue engine** — up to `MAX_RD_OT=2` clean reads at the head of its
request FIFO are issued to the socket before data drains; writes, sub-word RMWs and
error drains keep full serialization, and a read is never issued past an older queued
write (the engine only runs ahead over an unbroken head-run of clean reads). In-order
tagged return is checked by new simulation assertions. Directed-TB coverage added:
**S11** (two back-to-back bursts must overlap: the 2nd DMA ctrl is asserted-accepted
*before* the 1st transaction drains — this check fails on the old translator), **S12**
(a write breaks the pipeline; socket-side event order R-W-R verified), **S13** (a
below-window error read inside a pipeline drains locally, in order). All 13+3 scenarios
PASS. A permanent, zero-intrusion event trace (`a2d_trace.log`, simulation-only, own
file) records every AXI arrival, DMA issue and retirement for offline latency analysis.

Held constant, verified: the frozen `matmul_selfcheck_8x8.h` image (untouched), host app
(untouched), measurement definitions (§11.2), SoC config, cluster Cfg + patches,
Questa 2022.3_1 + `VoptFlow=1`. The *only* deltas are the 7 ported files + wrapper ports
+ translator engine + regenerated socket wrapper.

### 12.4 Deviation D15 — the stale-build mirage (how a false "null result" was caught)

The first two "comparison runs" reported cycle counts **bit-identical** to the baseline.
That was not a measurement: the accelerator RTL that simulates is the *installed copy*
under `tech/virtex7/acc/`, which `make sim` does **not** refresh from `hw/src` — and the
build had actually **failed** (vcom-1484: the regenerated socket VHDL binds
`dma_read_chnl_last` against the stale entity), but the failure was masked by a
`| tail` pipeline (tail's exit 0), and the *previous run's transcript was still in
place* to be misread as fresh results. Corrective actions, now standing practice:
`make <acc>-hls` after any `hw/src` edit; **move** (never copy) the transcript away
before a run; require three freshness proofs before believing any number — new
transcript timestamp, presence of the run's `a2d_trace.log`, and make's real exit code.
Recorded as deviation **D15**; the "reality wins, loudly" rule is the reason this report
contains a true result instead of a confident false null.

### 12.5 Results and analysis

Same test, same measurement, fresh verified build (Questa, 20 min wall):

| window | Phase-1 baseline | Phase-2 multiOT | Δ | expected? |
|---|---|---|---|---|
| **DMA_IN** | 399 | **300** | **−99 (−24.8%)** | ceiling analysis predicted best ~330-360 — met and slightly beaten |
| COMPUTE | 1217 | 1215 | −2 (−0.2%) | control value: unchanged ✓ |
| **DMA_OUT** | 155 | 155 | **0** | writes not pipelined (by design) ✓ |
| **TOTAL** | 1771 | **1670** | **−101 (−5.7%)** | = DMA_IN saving (+2) |
| COMPUTE_ACT0 | 1087 | 1085 | −2 | ✓ |
| CAL | 64 | 43 | −21 | see note |
| correctness | PASS 0/64 | **PASS 0/64** | — | golden model green ✓ |

**Why (mechanism, from `a2d_trace.log`).** Each 256 B mchan transfer is two 128 B AXI
bursts (§11 anatomy). In the baseline each burst's full round trip serialized
(~52 cycles apart). In the multiOT run the translator issues the second burst's DMA
request **while the first is in flight** — the trace shows A's halves issued 38 cycles
apart and B's halves **18 cycles** apart, each stamped `inflight=1` — hiding the
TLB/dispatch/NoC-header cost of every second transaction under its predecessor's data
return. That is worth ~50 cycles per transfer, ×2 transfers ≈ the measured −99.
DMA_OUT cannot move: the write path is deliberately untouched (single-outstanding,
fenced). COMPUTE barely moves because compute-phase icache misses are *demand* misses —
the core stalls on each one, so there is rarely a second read to overlap (the trace's
300 `inflight=1` events cluster in the boot phase, where refills stream back-to-back).
CAL (the back-to-back timer-read pair) shrank 64 → 43 because it is *not* a pure
constant: the pair straddles whatever stalls occur between the two reads — here an
icache refill that now completes sooner. Window deltas of ±~20 cycles of snapshot
overhead exist in both columns; the −99 DMA_IN delta dwarfs them.

**Honest scaling outlook (not measured here):** at N=16/32 each transfer becomes 5/17
bursts and mchan pipelines up to 8, so a larger *fraction* of DMA time becomes hideable —
but per-transaction savings stay capped by `MAX_DMA_READS=2` and, at the bandwidth floor,
by the 64-bit NoC's 1 flit/cycle. Raising the depth needs the design's own scaling work
(per-ID ROBs / multi-context drain — the same prescription the NVDLA evaluation
produced). The N=16/32 escalation runs on both branches are a ready follow-up: one
proto-header edit + `gen_header.sh` per branch.

**Status:** Phase 2 delivered — the extension is integrated, correct on the frozen
workload, and shows a real, mechanism-explained **24.8% DMA-in / 5.7% end-to-end**
improvement at the smallest matrix size. Rungs 1-4 remain green on the baseline branch;
the multiOT branch adds this comparison on top.

---

## 13. Uniformity and separability analysis (release-readiness study; no RTL changed)

**Plain language.** Two questions, two answers. *Uniformity:* the two accelerator flows
really do share one memory-side proxy (`noc2aximst`), and the two multiOT versions of it
are **the same design in two snapshots** — the NVDLA-path version is simply the newer
edition of the RTL-path one (same author, same context table, same FSMs, carried forward
a month later) plus three things the older edition lacks: the RAW-ordering write gate,
robustly *computed* tag-bit positions, and better packaging/documentation. Unifying for
the release means adopting the newer edition as the single shared file — nothing from the
two paths genuinely conflicts. *Separability:* the PULP integration and the multiOT
extension are cleanly independent at the file level — the baseline branch contains zero
shared-RTL changes, the ported multiOT files contain zero PULP references, and each works
without the other. The one entanglement is bookkeeping: a single commit currently holds
both the generic port and the PULP-side glue, and one genuine release gap exists —
the new socket interface is not backward-compatible with already-generated accelerator
wrappers (we proved that empirically when our own stale wrapper broke the build).

### 13.1 Q1 — the shared-proxy premise: TRUE

Both paths converge on the same RTL file and the same instance. In `rtl/tiles/
tile_mem.vhd`, the `no_cache_coherence` generate branch (CFG_LLC_ENABLE=0, line 742)
instantiates `noc2aximst_1` (line 744, `mst_index=0`) with the comment "Handle CPU
coherent requests and **accelerator non-coherent DMA**", wired to the DMA-plane queues
(`dma_rcv_*`/`dma_snd_*`); `noc2aximst_2` (line 823) serves JTAG/EDCL/ETH on the
`coherent_dma_*` queues; the `with_cache_coherence` branch (instances at 902/1134) is the
mutually-exclusive LLC variant of the same file. Both accelerator-side proxies speak the
same message types to it (`DMA_TO_DEV`/`DEV_TO_DMA`: 5 uses in `esp_acc_dma.vhd`, 2 in
`axislv2noc.vhd`). The paths diverge **only accelerator-side**: RTL flow =
`esp_acc_dma`+`esp_acc_tlb` instantiated by the generated socket
(`socketgen/noc_pulp_cluster_rtl.vhd:388` from `templates/noc_interface.vhd`);
third-party flow = `axislv2noc` (`retarget_for_dma=1`) from
`templates/noc2axi_interface.vhd`.

### 13.2 Q1 — three-way diff (A = `esp_nvdla_multiot`, B = `esp_dma_axi`, C = our port)

**C ≡ B, byte-for-byte** — verified for all 7 ported files against `esp_dma_axi` HEAD
(`diff -q` each: identical). The comparison reduces to A vs B. Lineage first, because it
reframes everything: A's `noc2aximst` machinery is **B's machinery carried forward**
(commits: B Apr 14-May 6, A Jun 1 + Jun 12, same author) — identical context-table
fields (`ctx_valid/ctx_rsp_header/ctx_ar_addr/len/size/prot/count/word_cnt/
ctx_noc_data`), identical `MAX_DMA_OT=2`, identical response-FSM states
(`DMA_RSP_IDLE/HEADER/DATA/CONT_AR`), identical order-FIFO/`active_ctx`/`dma_ar_id`
scheme. A 53-hunk file diff decomposes as:

| mechanism | A (nvdla, newer) | B = C (dma_axi → our tree) | verdict |
|---|---|---|---|
| context table, alloc/free, depth | identical fields & names | identical | **AGREE** (same lineage) |
| response FSM + allocation-order FIFO + `R_ID`-gated drain | same 4 states, same order FIFO | same | **AGREE** |
| continuation ARs (>256-beat), AR_ID={0,ctx} | same | same | **AGREE** (A's coherence-exclusion line-level detail TO BE VERIFIED; B's verified in §12) |
| **posted-write RAW gate** | **A only**: `pending_writes` AW++/B−− counter holds *newly dequeued* read ARs until older writes' B drain; continuation ARs exempt (WAR inversion avoided); debug stall counter; 94 lines, commit `5ac762b7`, **in this file** — the fix's enforcement point is memory-side, refining §12.2's framing | absent | **DIVERGE-functional.** Path-forced *today* (B's only client, `esp_acc_dma`, fences reads vs writes at the source, so the gate would be provably dormant: pending_writes=0 whenever a read dequeues). **Release-required** in a shared file: unfenced posted-write clients (NVDLA path) corrupt without it |
| WSTRB subword size-override (header reserved bits [6:4], `compute_axi_wstrb`) | present (from A's newer *base* efcc0db8) | absent (B's base a45f2bb8 predates it) | **DIVERGE — upstream base drift**, not multiOT; comes along automatically on a newer base |
| DMA_TRAN_ID definition | **computed anchor**: `FLIT_SIZE−PREAMBLE−4·YX_WIDTH−MSG_TYPE−RESERVED−1`, mirrored VHDL (`nocpackage.vhd:103-107`) ↔ SV (`noc2aximst-pkg.sv`, imports `esp_global_sv`); comment: elaboration fails if flit too narrow | **hardcoded [34:31] twice**: VHDL (`nocpackage.vhd:57-59`) and a local `` `define`` (`noc2aximst.sv:14-16`) | **DIVERGE-fragile-cosmetic.** Width 4 both. Positions **coincide exactly at our config** (YX_WIDTH=4, DMA_NOC=64 ⇒ A's formula = 34..31), but A's generator emits YX_WIDTH 3 *or* 4 per grid — at YX=3 A computes [38:35] while B still says [34:31]. Each tree is self-consistent (all agents use the shared constants/helpers), but B breaks silently on any width change. Adopt A's computed form |
| packaging | `noc2aximst-pkg.sv` (113 lines, typed msg enums) | constants inline | DIVERGE-cosmetic (A cleaner) |
| documentation | extensive design comments | sparse | DIVERGE-cosmetic |
| consumer cross-compatibility | A's proxy serves B's `esp_acc_dma` (needs only: opaque tag echo + per-tile allocation-order drain — both kept in A) | B's proxy serves A's `axislv2noc` **except** it lacks the RAW gate → unsafe for posted-write clients | **asymmetric: A is a strict superset** |

Accelerator-side (not the shared file, but relevant to policy): B/C's `esp_acc_dma` has
`MAX_DMA_READS=2` + read-ID FIFO + 256-flit ROB + **read/write mutual fence**; A's
`axislv2noc` has an 8-entry outstanding table, posted writes (B acked locally), and no
fence — the RAW burden moved to the memory-side gate.

### 13.3 Q1 — uniformity verdict and the fencing question

**Verdict: not yet uniform, but trivially unifiable — the release should ship A's
`noc2aximst` (+ its `noc2aximst-pkg.sv` + A's computed `nocpackage` constants) as the
single shared memory proxy.** Nothing in the RTL path requires a path-specific special
case memory-side: `esp_acc_dma` consumes exactly the guarantees A already provides (tag
echo, per-tile in-order drain), and the RAW gate is dormant for fenced clients. The only
mechanical work: rebase A's file onto the release base (it carries the WSTRB base feature
already), keep the tag constants in ONE place per language (kill B's local `` `define``
copy), and re-run our Phase-1/2 comparison as regression (expected: identical numbers,
since the gate never triggers for a fenced client — TO BE VERIFIED when authorized).

**Fence vs. gate — the case for each** (the accelerator-side policy question; decision
yours): *Converge on the gate (A's model, proxies unfenced/posted):* one enforcement
point in the one shared file protects **every** client, present and future, and permits
read/write overlap (real throughput for accelerators that interleave, e.g. NVDLA
streaming); cost: the WAR direction is documented-uncovered in A (younger AW overtaking
older AR below the port — unobserved, needs a per-address CAM for full closure), and
reasoning about ordering spreads across two modules. *Converge on the fence (B's model,
everywhere):* simplest possible correctness story (RAW **and** WAR excluded at the
source, nothing to verify downstream) and zero cost for phase-separated accelerators
(ESP's typical read-compute-write pattern — our matmul loses nothing); cost: every
acc-side proxy must implement it (N enforcement points, fails open if one forgets), and
it forfeits read/write overlap for streaming clients — measurably regressive for the
NVDLA path. *Layered recommendation:* ship the **gate in the shared memory proxy
unconditionally** (it is correctness infrastructure, dormant when redundant) and leave
the fence as the RTL-path proxy's local policy for now — mechanism uniformity where it
matters (one shared file), policy freedom where paths genuinely differ. Revisit the
fence only if an RTL-flow accelerator ever needs interleaved read/write streams.

### 13.4 Q2 — branch map and bucket classification

Branch facts (all verified by git): `pulp-cluster-clean-integration` @ `bc299ea5` =
PULP integration + Phase-1 test; `git diff a45f2bb8..bc299ea5 -- rtl/ tools/ utils/` is
**empty** — the entire PULP integration lives under `accelerators/rtl/pulp_cluster_rtl/`
+ the SoC design dir, zero shared-RTL edits. `pulp-cluster-multiot` @ `05bb7728` =
baseline + exactly one commit, 11 files:

| file | Δ | bucket |
|---|---|---|
| `rtl/noc/nocpackage.vhd` | +35 | **A** (generic: tag constants/helpers) |
| `rtl/sockets/proxy/esp_acc_dma.vhd` | +392 | **A** (generic socket) |
| `rtl/sockets/proxy/esp_acc_tlb.vhd` | +130 | **A** |
| `rtl/sockets/proxy/noc2aximst.sv` | +346 | **A** |
| `rtl/sockets/proxy/tile.vhd` | +11 | **A** |
| `tools/socketgen/socketgen.py` | +6 | **A** (emits tag ports for every acc) |
| `tools/socketgen/templates/noc_interface.vhd` | +6 | **A** |
| `hw/src/.../pulp_cluster_rtl_basic_dma64.sv` | +8 | **B1** (interface-forced glue: the 3 generated ports) |
| `hw/src/.../axi2dmafifo.sv` | +132 | **B1** (ports) + **B2** (optional exploitation: pipelined issue engine, tracer) |
| `verif/axi2dmafifo_tb.sv` | +172 | **B2** (TB) |
| `pulp_esp_integration_report.md` | +163 | doc |

No file mixes buckets A and B. Cross-reference greps: zero `pulp|cluster` identifiers in
any Bucket-A file; zero `tag|multiot|MAX_RD_OT` content in the baseline translator
(`git show bc299ea5:...`). **The entanglement is commit-granularity only**: `05bb7728`
holds both buckets in one commit.

### 13.5 Q2 — independence assessment and the one real release gap

- *PULP without multiOT:* **yes** — the baseline branch is the proof (rungs 1-4 +
  Phase 1 all green there, shared RTL pristine).
- *multiOT without PULP:* **yes** — Bucket A is a verbatim `git apply` of a diff
  developed and validated on a PULP-free tree (`esp_dma_axi`: traffic-generator
  accelerators, vcu118, FPGA 9/9 + sim reorder tests), applied cleanly here because our
  shared RTL was pristine at the same base; it contains no PULP references.
- *Bucket B decomposes:* **B1** (wrapper + translator *ports*) is **forced by the
  interface** — once socketgen emits the tag ports on every generated accelerator
  wrapper, each accelerator entity must declare them or elaboration fails; **B2** (the
  issue engine + TB + tracer) is **optional performance** — the socket explicitly
  supports never-overlapping legacy clients (`rd_handshaken` "legacy protocol still
  works"; `esp_dma_axi`'s sequential mode validated on FPGA), so a B1-only accelerator
  runs at baseline speed.
- **Release gap (backward compatibility):** the socketgen change emits the three tag
  ports **unconditionally for every accelerator interface**, but only *newly generated*
  accelerators get them (esp_dma_axi's accgen templates add them to new skeletons);
  every **existing** accelerator wrapper in the wild breaks at elaboration exactly the
  way our stale wrapper did — `vcom-1484: Unknown formal identifier "dma_read_chnl_last"`
  (D15, observed). For the release: either make socketgen's tag-port emission
  conditional/defaulted, or ship a migration note requiring every accelerator interface
  to be regenerated/extended. This is the single sharpest uniformity-blocking item found.

### 13.6 Q2 — organization recommendation (options; nothing restructured yet)

Nothing has been pushed, so history is still cheap to shape. Options: **(i) two-commit /
two-branch split** — replace `05bb7728` with commit 1 = Bucket A alone (also tagged as a
standalone `multiot-socket` branch off stock `a45f2bb8` for the release handoff) and
commit 2 = Bucket B glue on top; `pulp-cluster-multiot` becomes baseline ∘ A ∘ B.
**(ii) keep as-is, document** (this section is that documentation) — zero effort, but
the A/B mix in one commit makes cherry-picking A for the release awkward. **(iii)
patch-series directory** (like `patches/pulp-runtime/`) — poor fit: these are tree-wide
RTL changes, not vendored-dependency fixes. **Recommendation: (i)** — it costs minutes
now, gives the release a clean PULP-free branch to take Bucket A from, keeps Bucket B
rebased on top as the PULP-side exploit, and the natural drift-guard is that
`multiot-socket` tracks `esp_dma_axi`/the release while `pulp-cluster-multiot` is always
re-derivable as baseline + merge. Awaiting your go-ahead (history rewrite of one local,
unpushed commit).

### 13.7 Verdicts

1. **Uniformity:** not yet — same design, two snapshots. Concretely: adopt the NVDLA
   fork's `noc2aximst` + `noc2aximst-pkg.sv` + computed `nocpackage` tag constants as
   the single shared memory proxy (it is a strict superset: + RAW write gate, + robust
   tag anchoring, + newer-base WSTRB support); nothing RTL-path-specific needs to live
   memory-side; fix the socketgen backward-compatibility gap (conditional tag-port
   emission or mandated regeneration) before release.
2. **Separability:** clean at file level today — baseline has zero shared-RTL changes,
   Bucket A has zero PULP content, each side works without the other; the only coupling
   is one mixed commit (`05bb7728`) and the interface-forced 11-line B1 glue, both
   dissolved by the two-commit split of 13.6 when you approve it.

> **Correction (2026-07, see §14.1):** the three "dormant gate" statements in §13.2/13.3
> above are too strong. The RTL-path fence orders packet *injection*, not memory
> *commit* — `pending_dma_write` clears on a local FIFO push, so a fenced client's read
> can reach the memory tile while its own write's B is still outstanding, and the gate
> then does real, necessary work. §14 has the verified end-to-end picture.

---

## 14. RAW ordering under concurrency, and a multiOT/classic switch (analysis; no RTL changed)

**Plain language.** Three answers. *(1)* Your reading of the asymmetry is right for the
NVDLA path and *almost* right for ours — with one important correction that changes the
picture: on our path the ordering rules live in **two** places (our translator and the
socket's fence), but **both only order how request packets are created and injected into
the network. Nothing on any source anywhere in ESP ever learns that a write actually
reached memory — no such acknowledgment message even exists.** The only logic in the
whole system that observes true write completion is the `pending_writes` gate the NVDLA
fork added inside the memory proxy. That means the gate is not redundant belt-and-braces
for fenced clients (as §13 claimed): it is the *only* end-to-end closure, on every path —
and classic single-outstanding ESP has quietly lived with this same (narrow) window
forever. *(2)* Under concurrent accelerators the gate composes correctly for everything
that has arrived at the memory tile, because buffers are disjoint by construction, an
address maps to exactly one tile, and per-source arrival order is preserved; its costs
are cross-accelerator over-serialization (everyone's new read waits for anyone's
in-flight writes), which a feasible per-source refinement removes. *(3)* A design-time
multiOT/classic switch is feasible and cheap — not by dialing depths to 1 (that breaks or
only approximates), but by re-routing reads down the **legacy blocking path that still
lives inside `esp_acc_dma`** (page-table, P2P and coherent traffic use it today): two
gated conditions. As a bonus, that same edit fixes a latent hang we found in the multiOT
socket for coherent configurations, and the switch pairs naturally with conditional
tag-port emission — solving §13's backward-compatibility gap and the switch with one knob.

### 14.1 Q1 — the corrected enforcement map (all claims file:line-verified, 2-pass)

Layer by layer, what each mechanism guarantees — and, crucially, what it does not:

| layer | guarantees | does NOT guarantee | evidence |
|---|---|---|---|
| SW / mchan | its own descriptor order via AXI B | B ≠ memory commit | see translator row |
| our `axi2dmafifo` | total request order; a read is never issued past an older *queued* write; writes/RMW serialized | its B to mchan = "all beats accepted by the socket" only | `cand_ok` excludes writes ([axi2dmafifo.sv:229-233](…)); `WR_DATA→RESP` B raised on last-beat accept (:312-354) |
| `esp_acc_dma` fence (RTL path) | no read *dispatched* while a write pending & vice versa; acc_done held for both | **`pending_dma_write` clears when the tail flit enters the tile's local NoC send FIFO** — `dma_tran_done` at `request_data` burst end (:1246-1274); TLB counts that local event (esp_acc_tlb :393-399, :455-457) | fence: :1025 (`rd_request` needs `pending_dma_write='0'`), :1031-1032 (write vs reads), :995-998 (SG stall at `MAX_DMA_READS`) |
| NoC | per-source, per-plane, per-(src,dst) in-order delivery (deterministic X-first wormhole; no reordering) | nothing across sources | `lookahead_routing.sv:7` |
| **write acknowledgment** | — | **does not exist**: DMA-plane message inventory has no write-ack type (`nocpackage.vhd:168-176`); `noc2aximst` sends on `dma_snd` **only** from its read-response FSM (:763-791); even the coherent-DMA write variant is posted (`DMA_WRITE_DATA_COH` → `RECEIVE_HEADER` on tail, :699-730) | fire-and-forget past the proxy, all paths |
| `noc2aximst` (stock **and** B/C) | serial FSM (stock) narrows windows | **never waits for B on DMA writes** (stock: straight to `RECEIVE_HEADER` after last W; "B_VALID not used", `B_READY` tied 1); B/C additionally decouples reads → windows *wider* than stock | verified in `a45f2bb8` and our tree |
| **A's gate** (NVDLA fork only) | holds each *newly dequeued* DMA read AR until `pending_writes==0`; counter = every AW/B on the module port (all accelerators' DMA + CPU writes in no-LLC configs; ETH/JTAG and LLC are other instances); continuation ARs and coherence reads exempt; can't wedge (`B_READY=1`, saturating); invariant is SVA-checked | per-address precision (it is global-count); writes still not held vs older reads (WAR) | gate :664-682, counter :1105-1121, SVA :1123-1129 |

**Answers to your Q1 as posed:** *NVDLA path* — correct: ordering enforced only in
`noc2aximst` (the gate). *RTL path* — refined: enforced **at the source twice**
(translator request-ordering + `esp_acc_dma` fence), and both matter — the translator
guarantees cluster-visible AXI ordering into the socket, the fence guarantees the write
*packet* fully precedes any younger read *packet* — but neither observes commit, so
end-to-end RAW closure on our path exists **only if the shared gate ships**. Corollary
worth stating plainly: **classic ESP's single-outstanding design has the same formal
window** (write posted into fabric, read AR issued after a serial-FSM delay, AW/AR
independent below the port) — it was narrow enough never to bite until multiOT widened
it, which is exactly how the NVDLA fork's corruption surfaced.

**Latent bug found during this analysis (coherent configs only):** in the multiOT
`esp_acc_dma`, an LLC/recall-mode read (`msg_type = REQ_DMA_READ`, :626-627) passes the
:1230 routing into `running`, but `inc_ot_read` fires only for `DMA_TO_DEV` (:1186) and
the response FSM acts only when `ot_read_count > 0` (:1367) — **no FSM ever drains the
response: hang.** Unreachable in our `ACC_COH_NONE` bring-up; real for any coherent user
of the multiOT socket. Adversarially re-verified. The §14.3 route-to-legacy edit fixes it
as a side effect; flag for the release either way.

### 14.2 Q2 — ordering under concurrent accelerators

**Where ordering must hold.** Accelerator DMA buffers are **disjoint by construction**:
each device gets its own buffer and private page table (baremetal: per-device
`aligned_malloc` + `PT_ADDRESS` per device; Linux: `contig_alloc` chunks belong to
exactly one descriptor). The sanctioned sharing pattern is Linux accelerator *chaining*
(same `hw_buf` bound to several devices) — and note `esp_run()` runs non-P2P accelerators
in **concurrent pthreads** (`libesp.c:199-210`), so chained stages are ordered by
app-level waits on DONE, not by the framework. P2P streaming never touches memory
(`REQ_P2P/RSP_P2P` tile-to-tile). So RAW is fundamentally a **per-accelerator(-buffer)
concern**; cross-accelerator same-address hazards arise only under explicit buffer
sharing. One address maps to exactly **one** memory tile (`addr[31:20]` decoded against
disjoint DDR slices; striping is at chunk granularity — same address, same tile), so
**per-tile gating covers per-address RAW**.

**Does the gate compose?** For traffic that has *arrived* at the tile: yes, and provably
so for same-source hazards — deterministic per-(src,dst) NoC order + the tile's FIFO +
the strictly serial packet FSM mean a source's write AW must complete before its younger
read can even be dequeued, and the gate then holds that read until every counted write's
B returns. Its two costs: **(a) over-serialization** — the count is global per tile, so
any accelerator's new read waits for *any* source's in-flight writes, including CPU
writes in no-LLC configs (they share the same AXI port); **(b) a residual cross-source
window** — a *different* source's aliasing write still traveling in the NoC is invisible
to the gate. That window only matters for shared-buffer chaining, where the producer's
DONE fires at last-flit-*pushed* (see 14.1) — it is closed in practice by the
milliseconds-scale software round trip between producer-DONE and consumer-start versus
tens-of-cycles NoC transit, but it is a **software contract** (DONE ≠ commit), not a
hardware guarantee, and it predates multiOT. Worth one sentence in the release notes.

**Redundant vs conflicting (fence + gate together).** Redundant-but-harmless, verified
structurally: the fence acts upstream (delays read *creation* until write *injection*),
the gate downstream (delays read *AR* until write *commit*); no cyclic wait is possible
(the gate holds only reads; writes are never held, so B always drains the counter — no
deadlock), and the costs compose benignly: for phase-separated workloads (ours) both are
≈zero; in the worst interleaved case the fence's serialization largely *overlaps* the
window the gate would otherwise enforce, so latency is not double-counted — the gate adds
only the B-latency remainder the fence cannot see.

**Options for the release (your decision):**
- **(a) Gate only — drop the RTL-side fence.** One enforcement point, the only true
  end-to-end closure, maximal read/write overlap on both paths. Costs: an RTL change to
  the validated socket; and the fence's *WAR-by-construction* protection on our path
  disappears (the gate covers RAW only; WAR remains documented-uncovered on the NVDLA
  path today).
- **(b) Gate unconditional + fence stays as RTL-path local policy** (§13.3 layered
  proposal, restated *under concurrency*): the gate is the correctness baseline for every
  client incl. future unfenced ones; the fence additionally closes WAR per-source on our
  path, costs nothing for phase-separated accelerators, and requires zero code churn.
- **(c) (b) + per-source gate refinement**: the DMA header at the gate point carries the
  origin YX (and the 4-bit tran ID); `AW_ID` is static so Bs return in order → an
  origin-FIFO (push at `aw_hs`, pop at `b_hs`) feeding per-origin counters removes the
  cross-accelerator over-serialization cleanly. Medium effort; the natural
  release-quality evolution once multi-accelerator benchmarks matter.
- **(d) Per-address CAM**: precise RAW *and* WAR; the A comment's own stated endgame;
  highest cost; not justified by current traffic.

Recommendation: **(b) now, (c) as the planned follow-up**, with the DONE≠commit software
note documented. (a) buys overlap our accelerators don't use yet at the price of opening
WAR on the RTL path; (d) is over-engineering today.

### 14.3 Q3 — multiOT/classic switch: feasible, cheap, and it solves the §13 gap

**Depth-1 is not the answer.** `noc2aximst` does not elaborate at `MAX_DMA_OT=1`
(hardcoded two-entry logic: `ctx_valid[0] | ctx_valid[1]`, `rsp_fifo[1]`, 1-bit toggle
pointers; :155-193). `esp_acc_dma` at `MAX_DMA_READS=1` elaborates but is only
*near*-classic (pulse-grant handshake and response-FSM overlap remain) and the ungated
256-flit ROB (~1 BRAM18) plus context tables still synthesize. The TLB keeps its 16
contexts. So depth-1 = approximate behavior, non-zero cost.

**Route-to-legacy is the answer.** The complete classic blocking path is alive inside
the multiOT `esp_acc_dma` — page-table fetches, P2P and coherent traffic use
`reply_header/reply_data` today. **Two gated conditions** (:1186 `inc_ot_read`, :1230
the `running`-vs-`reply_header` routing) send ordinary reads down it too, restoring
exact transaction-level classic behavior (not cycle-identical — the pulse-grant timing
differs slightly; honest caveat). `noc2aximst` needs **no switch at all**: with a serial
source its second context is simply never allocated (the NVDLA fork proves the pairing),
and its legacy `DMA_SEND_*` states are unreachable stubs (proven exhaustively — no
`next_state` assignment targets them). And the same :1230 edit **fixes the latent
coherent-read hang** of §14.1.

**Where the knob lives, by ESP precedent:** RTL behavior → a global `esp_global`
constant generated from `.esp_config` by `socmap_gen.py` (exactly how `DMA_NOC_WIDTH` /
`CONFIG_*` flow), consumed as a generic by `esp_acc_dma` via the socketgen template —
uniform across both paths since the memory proxy needs no switch. Interface → a
**per-accelerator XML attribute** controlling tag-port emission (precedent: `data_size`
→ `tlb_entries` through socketgen). **Interaction with the §13 release gap:** in classic
mode the three tag ports are functionally unnecessary (`bufdin_tag/last` are driven only
by the response FSM, `rd_tag_in` only latched by the TLB) — so *conditional emission
keyed on the same switch* keeps every existing pre-multiOT wrapper elaborating
unchanged, while multiOT-enabled designs opt in and migrate once. One knob resolves both
questions. (The alternative — emit-always with a one-time fleet migration — keeps the
interface uniform across configs at the price of touching every wrapper; both options
are viable, conditional emission is the smaller-blast-radius default.)

**Effort estimate:** small — two gated conditions in `esp_acc_dma`, one config constant
plumbed through `socmap_gen.py`/template generics, conditional port emission in
`socketgen.py`; verification = Phase-1/2 reruns in both modes (baseline numbers expected
to reproduce in classic mode).

### 14.4 Takeaways

1. **RAW enforcement, corrected:** NVDLA path = memory-side gate only. RTL path =
   translator request-ordering **and** socket fence, both source-side, both ordering
   packet injection only; **no source ever observes write commit (no ack message
   exists), so A's gate is the only end-to-end RAW closure on any path — classic ESP
   included.** §13's "dormant gate" claim is corrected accordingly. Plus one latent
   coherent-mode hang in the multiOT socket, now documented.
2. **Ordering under concurrency:** buffers are disjoint, one address = one tile, so the
   per-tile global-count gate is *correct* for all arrived traffic and conservative
   across sources; recommended: gate unconditional + RTL fence as local policy now,
   per-source counters as the scaling refinement, DONE≠commit noted as software
   contract for shared-buffer chaining.
3. **Switch:** feasible and cheap via route-to-legacy in `esp_acc_dma` (2 gated
   conditions; `noc2aximst` untouched; fixes the coherent hang), knob = global
   `esp_global` constant + per-acc XML attribute gating tag-port emission — which
   simultaneously resolves the §13 socketgen backward-compatibility gap. Depth-1 is
   explicitly *not* the mechanism.

---

## 15. Release punch-list, depth-knob map, ID-width study, switch design (non-coherent scope; analysis only)

**Plain language.** Four questions, four answers. *(1)* Between today's multiOT extension
and "release-solid" stand **five real fixes** — three silent-corruption/overflow paths
that legal non-coherent SoCs can reach (a reorder buffer that wraps silently on long
transfers, a bypass that lets non-scatter-gather accelerators exceed the outstanding
limit unnoticed, and memory responders that never echo the transaction tag), plus the
missing write-completion gate from §14 and the wrapper-compatibility packaging fix. The
rest is hardening or documentation. *(2)* There is **no single depth knob**: "2
outstanding reads" is enforced by three independently hardcoded constants that happen to
agree, a tag width written out six times across three languages, and a reorder buffer
whose slot count exists only implicitly — the map below is the honest list of what you'd
touch. *(3)* The AXI ID/tag widths are hardcoded about a dozen times but *consistently*;
the real ceilings are 2 reads per socket, 2 per memory tile, 16 tags — and ESP already
has the right mechanism (one config generating matched VHDL+SV packages) to give all of
it a single source of truth. *(4)* The classic/multiOT switch design is firmed up:
route-to-legacy inside `esp_acc_dma`, one global constant + one per-accelerator XML
attribute, generate-guards making classic mode cost-free.

### 15.1 Item 1 — punch-list (non-coherent scope)

| # | gap (plain) | where | reachable in non-coherent? | class | fix sketch |
|---|---|---|---|---|---|
| P1 | **ROB silent wrap**: a >256-flit response that arrives out of order overruns the one reorder-buffer slot; the 8-bit pointer wraps, the transaction "completes" with short/corrupt data, no error | `esp_acc_dma.vhd:324-329` (ROB_DEPTH=256, no full-check `:1405-1420`, wrap `:1544-1546`, drain terminates on ptr-equality `:1431-1441`); fragment length bounded only by chunk remainder (`esp_acc_tlb.vhd:223,239,253`); the mem tile streams a whole fragment as ONE packet (`noc2aximst.sv:517-527,760-806`) | **YES**: ≥2 mem tiles + striped buffer + fragment >2 KiB (a 4 KiB chunk = 512 flits) | **MUST-FIX** | clamp per-fragment dispatch length in the TLB to ROB capacity (~10-15 lines); do NOT backpressure `rsp_buffer` (deadlocks the plane) |
| P2 | **non-SG limiter bypass**: with `scatter_gather=0` the outstanding-read stall does not exist and every read carries tag 0 — a pipelining non-SG accelerator silently overflows the 2-entry ID FIFO | `esp_acc_dma.vhd` non-SG generate: `dma_tran_id` tied 0, no `ot_read_count>=MAX_DMA_READS` guard outside the SG branch | YES for any non-SG accelerator that re-requests before data returns (our cluster uses SG — unreachable for us) | **MUST-FIX** | replicate the stall guard in the non-SG branch + stamp real IDs (~10 lines) |
| P3 | **non-echoing responders**: `noc2ahbmst` builds DMA read responses **without** the tag echo, while the multiOT response FSM interprets header bits [34:31] unconditionally whenever reads are outstanding → mis-matched tag → wrong buffering/hang | `noc2ahbmst.vhd:274-295` (`create_header`, no `set_dma_tran_id`); consumer `esp_acc_dma.vhd:1366-1376` | YES in any SoC whose DMA can target an AHB-backed responder | **MUST-FIX** (or formally restrict multiOT to AXI-mem-only SoCs) | add the echo to `noc2ahbmst` (~3 lines) — or a socgen restriction |
| P4 | **RAW gate absent** in our/B's `noc2aximst` (§14: the only end-to-end write-completion closure) | gate exists only in A (`noc2aximst.sv:664-682,1105-1121`) | YES (multiOT widened the classic window) | **MUST-FIX** | adopt A's file (§13 verdict) |
| P5 | **tag-port emission breaks existing wrappers** (build-time-loud: vcom-1484/D15); component inputs have no defaults (`tile.vhd` +11 lines are clean wiring otherwise) | `socketgen.py:704,727`; `tile.vhd:~828-833,903-910` | YES at first regeneration of any pre-multiOT design | **MUST-FIX (packaging)** | conditional emission keyed on the §15.4 switch |
| P6 | origin-coordinate truncation: response routing YX sliced to 3 bits — tiles at X/Y ≥ 8 get misrouted DMA responses | `noc2aximst.sv` (`origin_*_dma [2:0]` hardcoded slices) — **pre-existing in stock `a45f2bb8`**, not multiOT's | only on >8-wide grids | upstream bug — report; fix alongside (few lines) | widen to `GLOB_YX_WIDTH` |
| P7 | multicast field overlap with tag bits: positional only at the legal extreme (M=4, YX=4, 64-bit NoC → dest fields reach bit 32) — **no functional collision** (fields never coexist on one packet; router reads dests only behind valid bits that unicast headers zero; verified incl. the router's explicit backward-compat val[0] logic) | `nocpackage.vhd:892-942`; `NoCConfiguration.py:945-949` | no legal-config failure found | nice-to-have hardening | socgen check or tag relocation (~5 lines) |
| P8 | tag constants hardcoded-vs-computed (§13): B [34:31] literal ×2 languages; A computed — and at A's own default (YX=3) A's tag sits at **[38:35]**, so the forks actively differ in practice; also `get_unused_msb_field` (`nocpackage.vhd:708-716`) reads exactly the tag's top bit — its consumers TO BE VERIFIED (believed coherence-plane, out of scope) | §15.3 inventory | latent | nice-to-have (Option A of §15.3 — do it with P4) | unify on computed constants |
| P9 | per-source vs global write gate (§14.2): cross-accelerator over-serialization | A `noc2aximst.sv:1105-1121` | perf only | nice-to-have | per-origin counters (§14.2 option c) |
| P10 | 4-bit ID wrap: **non-issue at depth 2** (in-flight IDs always k, k+1 mod 16; collision needs 16 concurrent); first thing to break when raising depth is the single-slot ROB at depth 3 | `esp_acc_tlb.vhd:164,430-458` | no | non-issue — document legal range `MAX_DMA_READS ∈ {1,2}` | — |
| — | verified non-issues: response-FSM double-buffer leak (impossible at depth 2), P2P/multicast vs multiOT (dedicated queues; `ot>0` implies mem-read runs), `rd_handshaken` phantom grants (one pulse per transaction by construction), skipped uncommitted hunks (observability only). Out-of-scope notes: coherent-read hang (§14.1), coherence-plane starvation at the mem tile under DMA load (new, liveness, coherent configs) | | | | |

**Verdict — minimum set for a release-solid non-coherent multiOT: P1 + P2 + P3 + P4 + P5** (with P6 reported upstream and P8 folded into P4's file adoption). Everything else is hardening, performance, or documentation.

### 15.2 Item 2 — the depth-knob map

**Plain version:** to change "how many reads can be in flight," there is no one dial.
Three separate constants — one in our bridge (SystemVerilog), one in the socket (VHDL),
one in the memory proxy (SystemVerilog) — must be changed *together*; the 4-bit tag that
names transactions is declared **six times across three languages** (VHDL package, SV
`define block, A's SV package, socketgen's Python literals, the bridge's port widths, the
generated wrapper); and beyond depth 2 the code shape itself gives out (a one-slot
reorder buffer and a written-out-longhand two-entry allocator). Raising N is a design
task, not a constant bump.

Flow-ordered (RTL path; third-party differs only at the first hop — `axislv2noc`'s
8-entry table in A instead of our bridge+socket pair):

| knob | file:line | value | must agree with | if violated |
|---|---|---|---|---|
| `Cfg.DmaNumOutstandingBursts` (cluster-side capacity) | wrapper `:109` → `pulp_cluster.sv:692` → `mchan_wrap` | 8 | ≥ MAX_RD_OT (perf only) | perf loss, safe |
| `MAX_RD_OT` (bridge) | `axi2dmafifo.sv:88` (+ `issued_q [1:0]` `:203`, slice `:233`) | 2 | ≤ MAX_DMA_READS; >3 needs counter widening | stall-only if too big; width overflow stops issue |
| bridge tag ports/counters `[3:0]` | `axi2dmafifo.sv:59,64,204-205,222-223` | 4 | == DMA_TRAN_ID_WIDTH == socketgen literals | elab error or tag-compare assertion |
| `MAX_DMA_READS` (socket) | `esp_acc_dma.vhd:310` (+ `read_id_fifo(0 to 1)` `:316` — same constant, auto) | 2 | ROB slots ≥ MAX_DMA_READS−1; ≤ 2^tag | ROB deficit = data loss/deadlock |
| **ROB slots** (implicit!) | single `rob_complete/rob_tran_id` `:330-331` | **1** | = MAX_DMA_READS−1 | the depth-3 breaker |
| `ROB_DEPTH` (flit *capacity*, different kind of depth) | `:324` | 256 | ≥ max fragment flits (**violated today** = P1) | silent wrap |
| `DMA_TRAN_ID_WIDTH` | `nocpackage.vhd:57-59` (VHDL), `noc2aximst.sv:14-16` (SV defines), A's `noc2aximst-pkg.sv`, `socketgen.py:704,727` (Python literals!), template + wrapper (symbolic) | 4 | one logical value, six declarations, three languages — **hand-synced** | elab error at best, mis-sliced tag at worst |
| TLB contexts | `esp_acc_tlb.vhd:164` (`2**DMA_TRAN_ID_WIDTH`) | 16 | ≥ in-flight fragments (auto-scales) | — |
| `MAX_DMA_OT` (mem tile) | `noc2aximst.sv:155` + **hardcoded 2-entry logic** `:170-174,269` (`ctx_valid[0]|[1]`, 1-bit `ctx_alloc_idx`, `rsp_fifo` ptrs) | 2 | dequeue-gated (excess acc-side depth stalls benignly) | >2 needs rewrite; =1 doesn't elaborate |
| mem-port AXI ID | `[1:0]` literals: `noc2aximst` ports, `tile_mem.vhd` port-map slices (`:1150,:1160` + mem-ctrl `r_id` `:468,:514,:560`), crossbar `AXI_ID_WIDTH=2` | 2 | {1'b0,ctx} scheme: contexts ≤ 2^(width−1) | see §15.3 |
| tile DMA queue depths (capacity) | `mem_tile_q/acc_tile_q` | 18 flits | none (backpressure) | perf only |

Note for the future: `scripts/check_constants.sh` covers only the L2/base constants — a
tag/depth consistency leg would be a natural addition once the constants are unified.

### 15.3 Item 3 — the ID/tag width study

**Plain version:** the "ID" exists at two levels. The 4-bit *NoC tag* names a socket's
outstanding transactions (16 names, only 2 used); the 2-bit *AXI ID* at the memory port
distinguishes in-flight reads there (its top bit is conventionally kept 0, leaving 1 bit
→ the 2-context ceiling). Nothing is inconsistent today, but every one of these widths is
a literal someone must keep aligned by hand. The costs of the caps: 2 reads per socket, 2
DMA reads per memory tile *for all accelerators combined* (the sharper multi-accelerator
ceiling), 16-deep tag space (8× headroom). Header budget at our config: **30 unused bits**
— the tag could grow to ~8 bits trivially; but at the minimum legal NoC (32-bit, YX=3)
even 4 bits don't fit — practical floor: 64-bit DMA NoC (B's hardcode fails elaboration
there; A's computed anchor would silently overlap routing bits, contra its own comment —
one more reason for an explicit elaboration guard).

Options (effort-honest): **(A) unify constants at width 4** — adopt A's computed
`nocpackage` anchor + A's SV package, delete our `define block, make `socketgen.py` emit
`DMA_TRAN_ID_WIDTH-1 downto 0`, add a window-budget elaboration check; ~1-2 days, and it
*is* the §13 convergence step (do together with P4). **(B) config-driven width** — add
`DMA_TRAN_ID_WIDTH`/`DMA_MAX_READS` to `socmap_gen.py`'s dual `esp_global.vhd`+
`esp_global_sv.sv` emission (the proven `DMA_NOC_WIDTH`/`GLOB_YX_WIDTH` pattern); VHDL
consumers scale automatically; ~1 week. **(C) memory-side OT scaling** — parameterize
`MAX_DMA_OT`, generalize the 2-entry allocator, widen the whole AXI-ID chain (three
stacked layers + `tile_mem` slices + crossbar generics), real `{is_dma, ctx}` ID
partition; multi-week; only worth it if depth-2 is *measured* as the bottleneck.
**Recommendation: A now, B when the switch lands, C deferred.**

### 15.4 Item 4 — the switch, firmed up

**Plain version:** one configuration flag chooses the socket's behavior at build time.
"Classic" sends every read down the old blocking path that still lives in the socket
(exact old transaction behavior, no reorder buffer built, no new ports on old
accelerators). "MultiOT" is today's depth-2 pipeline. A user flips one line in the SoC
config; per-accelerator, an XML attribute says whether that accelerator's interface has
the tag ports at all.

Design (what I'd implement on approval): **(1) knob** — `CFG_DMA_MAX_READS ∈ {1,2}` in
`.esp_config` → `socmap_gen.py` emits it into `esp_global.vhd` + `esp_global_sv.sv`
(Item 3 Option B's first constant); 1 = classic. **(2) socket** — generic on
`esp_acc_dma`; `=1` routes non-coherent reads to the legacy `reply_header` path (the two
gated conditions at `:1186`/`:1230`, §14.3 — also fixes the coherent hang) and a
`generate` excludes the ROB + response FSM + `read_id_fifo` (classic is
resource-free); `esp_acc_tlb` keeps its blocking `tlb_s5` under the same generic.
`noc2aximst` needs **no switch** (serial sources never allocate the second context;
`DMA_SEND_*` stubs stay dead). **(3) interface** — per-accelerator XML attribute
(`multiot="true|false"`, default false) gates socketgen's tag-port emission (resolves P5;
pre-multiOT wrappers elaborate untouched); the accelerator-side generic defaults keep a
tag-less accelerator legal under a multiOT socket (tag tied 0 = sequential legacy
protocol, proven). **Relation to Items 2/3:** the switch *subsumes* the depth question at
release scope (legal depths are exactly {1, 2} until P10/§15.2's structural work is
done), and it *depends* on Item 3 Option A only for cleanliness, not correctness — A
first, then the switch, is the natural order. Honest caveat kept: classic-via-routing is
transaction-level identical, not cycle-identical (pulse-grant timing differs).

### 15.5 Summary — decisions awaiting approval

- **Must-fix list (Item 1):** P1 ROB clamp · P2 non-SG limiter · P3 responder tag echo
  (or restriction) · P4 adopt A's gated `noc2aximst` · P5 conditional tag-port emission.
- **Depth parameters (Item 2):** unify under the Item-3 constants + the switch; document
  legal depth {1,2}; optional `check_constants.sh` leg.
- **ID width (Item 3):** Option A now (computed constants, one source per language,
  elaboration guard), Option B with the switch, Option C deferred until measured.
- **Switch (Item 4):** `CFG_DMA_MAX_READS` global constant + per-acc `multiot` XML
  attribute + generate-guarded classic path as specified above.

---

## 16. Is the reorder buffer necessary? And is the AHB path really dead? (analysis only)

**Gist.** Two answers. First: the reorder buffer is **not** there for AXI — it is there
because ESP's accelerator interface makes a simple promise: *"read data comes back in the
order you asked for it."* Every accelerator ever generated counts on that promise by
counting positions; the buffer is what keeps the promise when two memories at different
distances answer out of turn. Removing it means breaking the promise for every existing
accelerator; keeping it safe costs about fifteen lines (cap how much data one request can
carry). Second: the old-style AHB memory connector is **not** dead — main DRAM did move
off it, but scratchpad memories and the frame buffer still use it, and non-coherent
accelerator DMA is *exactly* the traffic that can reach them — so the missing-tag fix
stays on the release list, and the failure is worse than we had catalogued: not
corruption but a clean hang.

### 16.1 Scope correction — AHB is alive; P3 stays (premise refuted, plainly)

*Gist:* main memory no longer uses the AHB connector, but two kinds of tiles still do —
scratchpad memories and the video/boot region — and the documentation ESP generates says
in so many words that **non-coherent DMA is how accelerators reach them**. Our own SoC
has neither, so we can never hit the bug; a release can.

*Technical:* `noc2ahbmst` is instantiated on the DMA plane in `tile_slm.vhd:469-504`
("Handle CPU requests accelerator DMA") and `tile_io.vhd:1179-1216` (frame buffer / boot
ROM); maintained through the 2026 release (commits Oct 2024–Mar 2026). The accelerator
socket's address decode spans DDR + SLM + SLMDDR + frame buffer
(`esp_acc_dma.vhd:52,634-644`; `socketgen.py:2608-2611`; `socmap_gen.py:2136-2141`, whose
generated comment reads "accelerators can only access the frame buffer and SLM if
**non-coherent DMA** is selected"). The tag is stamped unconditionally on every non-P2P
request (`esp_acc_dma.vhd:666-667`) and checked on every response (`:1371`), but
`noc2ahbmst.make_dma_packet` zero-fills the header and never echoes it
(`noc2ahbmst.vhd:276-296`). **Corrected severity: even ONE outstanding read to an
SLM/frame-buffer tile hangs** once the rolling tag has advanced past zero (untagged
response ≠ expected → classified out-of-order → buffered → the "real" response never
arrives). Unreachable in this tree's only configured SoC (vc707: no SLM/FB tiles,
`mem_num=1` short-circuit). **P3 verdict: keep as release must-fix (~3-line echo), mark
N/A for our SoC; the "obsolete" premise is refuted.**

### 16.2 What the buffer actually does

*Gist:* it restores the **global order in which requests were issued** — a much stronger
promise than anything AXI asks for — and only ever has work to do when two *different*
memory tiles answer at different speeds; a single memory can never get out of order.

*Technical:* delivery to the accelerator is strictly `read_id_fifo` dispatch order
(`rsp_idle` head-match → `rsp_passthru`; non-head → whole response into the ROB, drained
after the head completes — `esp_acc_dma.vhd:1366-1444`). Within one memory tile,
`noc2aximst` drains responses in context-*allocation* order (`rsp_fifo` + `R_READY`
gated on `R_ID == active_ctx`) — a **design choice**, not a wormhole necessity (the
response header carries the tag; packets could depart in R-arrival order). So the only
physical source of reordering is cross-tile routing asymmetry, exactly what the
`esp_dma_axi` N1 test demonstrated.

### 16.3 Who requires issue order — the true reason (answer: the stream protocol)

*Gist:* nobody on the AXI side needs this. The requirement comes from ESP's own
accelerator interface: it is a conveyor belt with no labels — every consumer identifies
data by *where it stands in line*, not by any name on it. The tag the extension added is
a *seal* used to check the line is intact, not an address label used to sort. One
component in our cluster could genuinely sort by label (its DMA engine keeps a table per
transfer), but the instruction cache, every classic accelerator, and our bridge cannot.

*Technical, per consumer:* classic pre-multiOT accelerators have **no tag port at all**
— positional attribution is the only possible semantics (the multiOT socket interface
added `tag/last` as annotations); the `esp_dma_axi` traffic generator *asserts*
`tag == expected issue index` (an in-order check, not a demux); our `axi2dmafifo`
attributes beats to its issued-window head (r_id/r_user from the head entry; the tag
assertion is a checker); the snitch icache refill is single-ID with a positional queue.
The exception: **mchan can demux R data by AXI RID at whole-burst granularity** (per-tid
table holds the TCDM landing state) — so the cluster's DMA engine alone could tolerate
out-of-order. On the AXI framing: the memory port already uses **distinct** AR_IDs per
context (AXI would happily return them out of order — the proxy *chooses* stricter), and
the cluster port returns everything in order (same-ID rule trivially met). Verdict on
the four hypotheses: **(c) the ESP stream contract requires it**, with a strand of (b)
explaining *why* the contract is positional (pre-multiOT heritage: the classic stream
had no tag, so position was the only identity). Not (a), not (d).

**P2 sharpened:** in the `scatter_gather=0` path *all* reads carry tag 0, so the
head-match **always succeeds** — cross-tile reordering is streamed to the accelerator
attributed to the *wrong request*, silently, with the ROB bypassed exactly when it would
be needed, even inside the 2-outstanding limit. P2 is a mis-attribution bug, not merely
a FIFO overflow.

### 16.4 Could it be simpler or eliminated?

*Gist:* four ways were costed. Capping each request's data at the buffer's capacity is
~15 lines, costs under 1% in extra packet overhead, and keeps everything else exactly as
validated — that's the recommendation. Sizing the buffer "big enough" is impossible
(requests can be gigabytes). Deleting the buffer by sorting-on-labels doesn't work as
imagined — pieces of one request all carry the *same* label, so labels cannot restore
order within a request, and every old accelerator breaks. Deleting the buffer by *never
letting two memories race* also works and is honest about its price: it gives up the one
kind of overlap only multi-memory systems add (all of our measured 24.8% win survives —
it was measured with one memory). And the "widen the AXI IDs, let the master sort it
out" idea dissolves on a topology fact: the two memory tiles sit on **disjoint AXI
fabrics** — no AXI master anywhere ever sees both response streams; they merge on the
NoC at the socket, which is not an AXI master. The only real "master" that could sort is
the cluster's DMA engine, reached through weeks of bridge rework — that *is* the
label-sorting option, at its true price.

*Technical option table:*

| option | soundness | perf | blast radius | effort |
|---|---|---|---|---|
| **A — TLB clamp** to ROB capacity (2 KiB/fragment) | sound, fixes P1 fully, contract intact | +4 flits per extra fragment ≈ +0.78% on a 4 KiB read; zero when fragments ≤2 KiB; all overlap preserved (dispatch pipelining hides ~8-cycle re-translation) | `esp_acc_tlb.vhd` only + ROB capacity becomes a shared constant (new §15.2 row) + optionally gated under the multiOT generic so classic stays bit-identical | **~10-20 lines. RECOMMENDED** |
| B — ROB sized to max fragment | infeasible standalone (fragment ≤ min(request, chunk) — software-controlled, unbounded); with the clamp it degenerates to today's design | — | — | defer to depth≥3 work (§15.3 C) |
| C — drop ROB, tag-demuxed delivery | **unsound as specified**: fragments of one request share one tag — tags cannot restore intra-request order; needs a new response protocol; breaks classic accelerators, the traffic-gen contract, the translator; icache needs per-ID order anyway | — | every consumer + socketgen + protocol docs | weeks |
| D — per-destination serialization (never two fragments to *different* tiles in flight) | sound; deletes the ROB and the P1 class entirely | loses only cross-tile overlap; preserves 100% of the measured single-tile win | `esp_acc_tlb`/`esp_acc_dma` dispatch guard; *removes* the rsp_buffer/drain machinery | moderate; the "minimal-logic" alternative |

### 16.5 Implications for the pending recommendations

- **Must-fix list shape: unchanged**, content sharpened. P1 stays with the clamp as the
  right fix (Option A; D noted as the honest minimal-logic alternative — one to pick,
  not both). P2 upgraded in description (silent mis-attribution). P3 retained with
  refuted-premise note and corrected severity (hang). P4/P5 untouched.
- **ID-width study (§15.3): unchanged.** Widening IDs does not obviate the ROB (16.4);
  Options A/B/C stand as stated.
- **Switch design (§14.3/§15.4): one addition** — the clamp goes under the same multiOT
  generic, so classic mode remains bit-identical to legacy.
- **Depth map (§15.2): one new must-agree row** — ROB flit capacity ↔ TLB clamp bound.

### 16.6 Takeaways

1. **The ROB is a genuine necessity of ESP's positional stream contract** — not an AXI
   requirement (distinct IDs already exist and AXI would allow reordering), not
   over-engineering (remove it and every existing consumer silently corrupts on
   cross-tile reordering), though its *untagged-heritage* origin explains the design.
   Keep it; clamp it (P1, ~15 lines); the label-sorting alternative is weeks of
   consumer rework the release doesn't need.
2. **AHB is NOT droppable**: alive for SLM/SLMDDR and frame-buffer tiles, reachable by
   exactly our scope (non-coherent accelerator DMA), failure = clean hang; P3 stays a
   release must-fix (3 lines), N/A only for our specific SoC.

---

## 17. Release work log — unification, must-fix closure, and the classic/multiOT switch

**Gist.** After the history was rebuilt into two clean commits, three engineering rounds
turned the multiOT extension from "works on our SoC" into "release-shaped": the shared
memory proxy was unified on the newer reference edition, **all five must-fix items from
§15 are now implemented and validated**, and a one-line configuration switch selects
classic or multiOT behavior per SoC — with old accelerators regenerating untouched.
Building the switch also flushed out a genuine latent bug that had been hiding in the
multiOT design all along: the socket could send a request to memory *without ever
completing the accelerator's handshake* — a guaranteed deadlock in classic mode, a
timing-dependent hazard in multiOT. It is fixed at the root, and the honest price of
that fix (a few cycles per transaction) is quantified below.

### 17.1 Step 1 — memory-proxy unification (§13 verdict executed)

Adopted verbatim from the NVDLA fork: `noc2aximst.sv` + `noc2aximst-pkg.sv` (bringing
the RAW `pending_writes` gate, the valid-bit-gated WSTRB subword support, and
package-based tag constants — the local `` `define`` block is gone), plus the computed
`DMA_TRAN_ID` anchor in `nocpackage.vhd` (moved below the flit-size constants it now
derives from; evaluates to the same bit 34 in this SoC). Closes **P4** and **P8**.
Validation: full rebuild + frozen N=8 matmul — **bit-identical** to the Phase-2 numbers
(`300/1215/155/1670`, PASS 0/64); the gate is dormant single-tile, as predicted.
Discovery en route: the SV package file existed upstream all along (§13's "A-only" note
corrected); the adoption was smaller than planned.

### 17.2 Step 2 — must-fix hardening (P1, P2, P3)

- **P1 ROB clamp**: new shared constant `DMA_ROB_DEPTH` (nocpackage) sizes both the
  socket ROB and a new TLB fragment clamp (`esp_acc_tlb`, P2P exempt; oversized
  fragments split by the pre-existing remainder loop).
- **P2 non-SG limiter**: the scatter-gather-less dispatch arm now stalls at one
  outstanding read (its all-zero tagging cannot distinguish more).
- **P3 tag echo**: `noc2ahbmst` **and** `mem2ext` now echo the transaction tag
  (3 lines each), so SLM/frame-buffer/external-memory reads cannot hang a multiOT
  socket.

Validation, two-pronged because our SoC structurally cannot reach any of these paths:
the frozen N=8 regression re-ran **bit-identical** (proving inertness), and a new
directed unit TB for the TLB fragmenter (`rtl/sockets/proxy/sim/esp_acc_tlb_tb.vhd` +
runner; compiles into the SoC's existing work library) proves the clamp against a
mirrored dispatch model — five scenarios: aligned 8 KiB → 4×2 KiB, misaligned
chunk-crossing (model-checked mixed lengths), P2P exemption, below-cap no-op, write
path; all PASS, including last-fragment flags and pending-flag clears.

### 17.3 Step 3 — the switch, and the race it exposed

**The switch (closes P5):** `CONFIG_DMA_MAX_READS ∈ {1,2}` — an *optional trailing*
line in `.esp_config` (positionally-safe: the parser reads old files unchanged;
`soc.py` read/write + `socmap_gen.py` dual emission into `esp_global.vhd`/`_sv.sv`).
The socket consumes it directly (`esp_acc_dma`, `MAX_DMA_READS := CFG_DMA_MAX_READS`):
`=1` routes non-coherent reads down the legacy blocking path (which also sidesteps the
out-of-scope coherent-read hang of §14.1), constant-folds the response FSM and ID FIFO
away, generate-excludes the ROB BRAM, un-clamps fragments (legacy sizes), and still
echoes the tag through the legacy path (one TLB lookup). Interface side: a
per-accelerator `multiot` XML attribute (default off) gates socketgen's emission of the
three tag ports; tag-less accelerators get the request-tag input tied to zero — **every
pre-multiOT wrapper regenerates untouched**. Our XML sets `multiot="1"`.

**The latent race (found deterministically by classic mode, fixed for both):** the
multiOT TLB eagerly pre-translates the accelerator's *next* request the moment the
request lines are high — before any grant. The `running` state's fragment-dispatch
priority then ships it to memory **without the ctrl handshake ever completing**: the
accelerator waits for a grant that never comes while the socket waits for data-channel
ready that never comes. In classic mode the slow blocking reply guarantees the TLB wins
that race every time (hard deadlock, reproduced and probed at the state level); in
multiOT mode the timing had always happened to let the grant win — with any
valid/ready-style accelerator it was one unlucky cycle away. **Fix:** the TLB now sees
a request only inside its granted window (`rd/wr_handshaken`) and reads index/length/
tag from grant-time latches (valid/ready masters deassert their lines one cycle after
the handshake — the latches are what make post-grant sampling safe). A config-parser
off-by-one (the DVFS skip swallowing the first trailing knob line) was found and fixed
the same way — by refusing to trust a "passing" run whose numbers hadn't moved.

**The numbers of record (frozen N=8 matmul, all PASS 0/64):**

| window | Phase-1 original | multiOT pre-fix (racy) | **multiOT fixed** | **classic via switch** |
|---|---|---|---|---|
| DMA_IN | 399 | 300 | **310** | 417 |
| COMPUTE | 1217 | 1215 | **1293** | 1318 |
| DMA_OUT | 155 | 155 | **163** | 167 |
| TOTAL | 1771 | 1670 | **1766** | 1902 |

Honest analysis: the race fix costs ~5-6 cycles per DMA transaction (grant →
handshaken → TLB sample → translate, serialized where the racy design overlapped
illegally). The multiOT DMA advantage is intact (**−25.7% DMA-in vs classic**), but at
N=8 the *end-to-end* total is nearly back at baseline because this workload is
dominated by compute-phase icache refills, each paying the per-transaction cost.
Recovery path (future, optional): start the TLB translation in parallel with the
previous reply *after* the grant — legal overlap, restores most of the loss. Classic
mode is transaction-level-faithful to the original, ~4-8% slower per transaction for
the same correctness reason.

### 17.4 Build-flow traps, codified (the D15 family, now four members)

1. The sim compiles the **installed** accelerator RTL — `make <acc>-hls` after any
   `hw/` edit (D15).
2. socketgen reads the **installed** accelerator XML — same rule covers XML edits
   (found when `multiot="1"` silently didn't take).
3. **Never `make <target> -B`** in the SoC dir: the `.esp_config` rule
   (`utils/make/esp.mk:16-18`) is `cp $(ESP_DEFCONFIG) $@` — a forced rebuild
   **overwrites the SoC configuration with the default** (accelerator tile silently
   vanishes; recovered from `.esp_config.bak`). Regenerate via `touch` + ordinary
   targets only.
4. Never launch builds through `| tail` — it swallows both the exit code and, for long
   diagnostics, the error text; capture full logs to a file.

**Status:** §15 must-fix list **fully closed** (P1-P5). Remaining on the release plan:
the third-party-side `axislv2noc` port (step 4) and the fold into the single multiOT
commit (step 5).
