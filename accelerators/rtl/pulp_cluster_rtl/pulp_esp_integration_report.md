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
| 8. Validation ladder rungs 1–4 | ⏳ pending | |
| 9. Hygiene / final report | ⏳ pending | |

Validation ladder: rung 1 (compile/elab) ⏳ · rung 2 (memory write) ⏳ · rung 3 (printf) ⏳ ·
rung 4 (matmul) ⏳ · rungs 5–6 stretch, not started.

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
| 9 | burst type ignored (WRAP/FIXED treated as INCR) | WRAP (and multi-beat FIXED) → SLVERR drain, no DMA; below-window addresses (xbar default-route underflow) also → SLVERR | S7, S9 |
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
| D6 | Step 3 | plan: cluster elaborates as-is (upstream TB evidence) | upstream `no_hwpe_gen` branch is stale HCI-v1 code (`s_hci_hwpe[0].boffs/.lrdy` don't exist in pinned `hci_core_intf`); never elaborated upstream because their TB has HWPEs on | new local patch `patches/0001-…-no_hwpe_gen-…`, upstream-candidate |

---

## 7. How to reproduce from a fresh clone

*(maintained as steps complete; HUMAN ACTION items marked)*

1. `git clone https://github.com/eugeniomuscinelli/esp.git && cd esp && git checkout pulp-cluster-clean-integration`
2. `git submodule update --init rtl/cores/ariane/ariane`
3. `source /opt/cad/scripts/tools_env.sh` (answer `2` = questa, or non-interactively:
   `export PATH=/opt/cad/questa/bin:$PATH` after sourcing)
4. *(further steps added as they are implemented)*

---

## 8. Risk register revisit

| Risk | Status |
|---|---|
| R1 (package coexistence) | **RETIRED** (Step 1 PASS, Questa 2022.3_1) |
| R2 (ECC elaboration error) | **RETIRED** on Questa 2022.3_1 (ECC probe PASS; fallback patch not carried) |
| R4 (inherited vlog flags) | **MATERIALIZED as predicted, MITIGATED**: `-pedanticerrors` promotions (vlog-2986, vlog-2577) + `-svinputport=net` default → hook value `ACC_MODELSIM_VLOGOPT = -suppress 2986 -suppress 2577 -svinputport=relaxed`; final confirmation when the real make rule runs (Step 5) |
| R9 (vendor reproducibility) | addressed by design: flattened machine-independent vendor paths, self-checking regeneration script, no gitlinks, no absolute paths committed |
| R3, R5–R8, R10–R12 | open / not yet reached |

---

## 9. Evidence appendix

- Step 1 artifacts: `/tmp/claude-1000/-home-eugenio/bdaaa42d-ff18-4c88-b540-0a08f0a0e5ba/scratchpad/step1_smoke/{work_side.sv,lib_side.sv,smoke_top.sv}`; output transcript quoted verbatim in §3.
- Tool versions: `vsim -version` outputs quoted in §2 (both installs), `vivado -version`,
  `riscv64-unknown-elf-gcc --version`.
- Env script: `/opt/cad/scripts/tools_env.sh` (read; modelsim default + interactive questa
  choice + venv activation).
