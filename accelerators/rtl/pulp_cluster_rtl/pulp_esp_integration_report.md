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
| 2. Accelerator skeleton | 🔜 in progress | |
| 3. Cluster RTL import + ECC experiment | ⏳ pending | |
| 4. Bridge modules (fix + directed TBs) | ⏳ pending | |
| 5. Wrapper + build wiring | ⏳ pending | |
| 6. SoC configuration | ⏳ pending (HUMAN ACTION: esp-xconfig) | |
| 7. Software flow | ⏳ pending | PULP-extended GCC not yet located on this machine (see §2 note) |
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

### Step 2 — Accelerator skeleton (in progress)

*(to be filled at step boundary)*

---

## 4. Bridge-module changes (defect table)

*(populated at Step 4)*

| Plan defect # | Description | Fix | TB coverage |
|---|---|---|---|

---

## 5. Open-question resolutions

| OQ | Status | Resolution |
|---|---|---|
| 1 (Questa package coexistence) | ✅ resolved | Step 1 PASS on Questa 2022.3_1 (see §3) |
| 2 (ECC internal error root cause) | ⏳ | Step 3 experiment pending |
| 3 (cluster_control_unit register map) | ⏳ | after `bender checkout` in Step 3 |
| 5 (0xA0103680 vs. cleaner base) | ⏳ | investigate at Step 5/6; STOP-AND-ASK before deciding |
| 6 (ctrl_data_user width) | ⏳ | after first `make socketgen` |
| 8 (ATOP end-to-end) | ⏳ | after per2axi checkout in Step 3 |

---

## 6. Deviation log

| # | Where | Plan said | Reality | Consequence |
|---|---|---|---|---|
| D1 | Environment | plan §4 assumed thesis-era QuestaSim 2024.3 might be present | installed simulators are Questa 2022.3_1 and ModelSim DE 2023.2 | ECC experiment (Step 3) runs on 2022.3_1: a PASS is consistent with upstream IIS evidence and makes ECC usable *here*; the 2024.3 crash itself cannot be reproduced on this machine — OQ2 will be answered "for 2022.3_1" |

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
| R2 (ECC elaboration error) | open — Step 3 experiment |
| R3–R12 | open / not yet reached |

---

## 9. Evidence appendix

- Step 1 artifacts: `/tmp/claude-1000/-home-eugenio/bdaaa42d-ff18-4c88-b540-0a08f0a0e5ba/scratchpad/step1_smoke/{work_side.sv,lib_side.sv,smoke_top.sv}`; output transcript quoted verbatim in §3.
- Tool versions: `vsim -version` outputs quoted in §2 (both installs), `vivado -version`,
  `riscv64-unknown-elf-gcc --version`.
- Env script: `/opt/cad/scripts/tools_env.sh` (read; modelsim default + interactive questa
  choice + venv activation).
