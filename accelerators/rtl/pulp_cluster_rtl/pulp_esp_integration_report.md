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
