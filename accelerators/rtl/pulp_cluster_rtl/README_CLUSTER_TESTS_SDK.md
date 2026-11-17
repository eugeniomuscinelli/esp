# Cluster tests with pulp-sdk

How to write, build and run **cluster-side software** for the PULP cluster
integrated in this ESP SoC, using **pulp-sdk** (the PulpOS 2 / PMSIS stack).

This is the counterpart of [`README_CLUSTER_TESTS.md`](README_CLUSTER_TESTS.md),
which documents the same thing for **pulp-runtime**. Both flows work, target the
same hardware and share the same host application; they differ in compiler,
runtime and build rules. See [Running both flows](#running-both-flows).

Use pulp-sdk when you want the PMSIS API (`pi_*`), the PulpOS 2 runtime, Xpulp
code generation, or to run code produced by tools that target pulp-sdk.
Use pulp-runtime for the existing self-checking tests.

---

## 1. Prerequisites

### 1.1 PULP-fork GCC

pulp-sdk needs the PULP fork of GCC — a stock RISC-V compiler will not do. It
provides the `rv32imcxgap9` multilib and the `-mPE` / `-mFC` chip flags that the
build passes unconditionally.

| | |
|---|---|
| Installed at | `~/toolchains/v1.0.16-pulp-riscv-gcc-ubuntu-18` |
| Version | `riscv32-unknown-elf-gcc (GCC) 7.1.1 20170509` |
| Target triple | `riscv32-unknown-elf` |
| Upstream | <https://github.com/pulp-platform/pulp-riscv-gnu-toolchain> |
| Obtained from | release **v1.0.16**, prebuilt tarball `v1.0.16-pulp-riscv-gcc-ubuntu-18.tar.bz2` |

It was installed by unpacking the prebuilt tarball — the same artifact the SDK's
own (now disabled) CI used:

```bash
cd ~/toolchains
wget https://github.com/pulp-platform/pulp-riscv-gnu-toolchain/releases/download/v1.0.16/v1.0.16-pulp-riscv-gcc-ubuntu-18.tar.bz2
tar -xf v1.0.16-pulp-riscv-gcc-ubuntu-18.tar.bz2
```

**One local fix-up was required.** This toolchain's `cc1` links against
`libmpfr.so.6`, which RHEL 8 does not ship (it has `libmpfr.so.4` only). A copy
of `libmpfr.so.6` was placed in the toolchain's own `lib/` directory, and
`configs/pulp_cluster_esp.sh` puts that directory on `LD_LIBRARY_PATH`. That
file is **not** part of the upstream tarball — if you reinstall the toolchain
from scratch you must restore it, or `cc1` will fail to start.

### 1.2 pulp-sdk

| | |
|---|---|
| Location | `/home/eugenio/pulp_sdk_fix` |
| Origin | `https://github.com/FondazioneChipsIT/pulp-sdk.git`, branch `rg/proper_cluster_sdk_fix` |
| ESP chip target | `pulp_esp` (added locally; recorded in this tree as `patches/pulp-sdk/0001-esp-chip-target-pulp_esp.patch`) |
| Config script | `configs/pulp_cluster_esp.sh` |

The path is **hard-coded** as `SDK=/home/eugenio/pulp_sdk_fix` in `gen_header.sh`.
If you move the SDK, edit that line.

You do **not** need to run `make` in the SDK itself. The application build path
never touches `install/`.

### 1.3 ESP tree state

These are generated and must exist before a simulation will run. All are
present in this tree; the table says what produces each if you start clean.

| Artifact | Produced by |
|---|---|
| `accelerators/rtl/pulp_cluster_rtl/vendor/` (35 packages) | `make -C accelerators/rtl/pulp_cluster_rtl vendor` — **needs network** |
| `tech/virtex7/acc/pulp_cluster_rtl/` | `make pulp_cluster_rtl-hls` from the SoC directory |
| `socs/xilinx-vc707-xc7vx485t/socgen/esp/.esp_config` | `make esp-xconfig` (see the warning in §4.3) |
| `.cache/modelsim/xilinx_lib/` (~2.2 GB) | Xilinx `compile_simlib`, one-off, ~40 min |

Git submodules must be initialised — including **Ariane's own nested
submodules** (18 of them; `tb/dromajo` is not needed):

```bash
cd /home/eugenio/esp_multiot_pulp
git submodule update --init rtl/cores/ariane/ariane rtl/caches/esp-caches soft/ariane/riscv-pk
git submodule update --init --recursive soft/ariane/riscv-tests
cd rtl/cores/ariane/ariane
git submodule update --init --recursive $(git submodule status | awk '{print $2}' | grep -v '^tb/dromajo$')
```

### 1.4 Environment

Order matters. **CAD environment first, pulp-sdk config last.**
`mentor_env.sh` *assigns* `LD_LIBRARY_PATH` rather than appending, so sourcing
it after the SDK config erases the toolchain library path and `cc1` stops
working.

```bash
# 1. CAD tools. INTERACTIVE: answer 2 (questa) at the prompt.
#    On a non-tty it silently selects ModelSim DE, which does NOT work for this
#    design — so make the Questa choice explicit either way:
source /opt/cad/scripts/tools_env.sh
export PATH=/opt/cad/questa/bin:$PATH

# 2. Questa licence (set by mentor_env.sh; shown here in case you bypass it)
export LM_LICENSE_FILE=1720@bioeelincad.ee.columbia.edu
export MGLS_LICENSE_FILE=1720@bioeelincad.ee.columbia.edu

# 3. Vivado (needed by every make target run from a SoC directory)
source /opt/Xilinx/Vivado/2023.2/settings64.sh
```

The pulp-sdk config is sourced **by `gen_header.sh` itself** — do not source it
by hand before running that script.

### 1.5 Verifying your setup

```bash
# Compiler runs, correct version and triple
~/toolchains/v1.0.16-pulp-riscv-gcc-ubuntu-18/bin/riscv32-unknown-elf-gcc --version
~/toolchains/v1.0.16-pulp-riscv-gcc-ubuntu-18/bin/riscv32-unknown-elf-gcc -dumpmachine
# -> riscv32-unknown-elf-gcc (GCC) 7.1.1 20170509
# -> riscv32-unknown-elf

# The multilib the build actually selects
~/toolchains/v1.0.16-pulp-riscv-gcc-ubuntu-18/bin/riscv32-unknown-elf-gcc -print-multi-lib | grep xgap9
# -> rv32imcxgap9/ilp32;@march=rv32imcxgap9@mabi=ilp32

# cc1 can load its libraries (must print 0)
LD_LIBRARY_PATH=~/toolchains/v1.0.16-pulp-riscv-gcc-ubuntu-18/lib \
  ldd ~/toolchains/v1.0.16-pulp-riscv-gcc-ubuntu-18/libexec/gcc/riscv32-unknown-elf/7.1.1/cc1 \
  | grep -c 'not found'

# Simulator is Questa, not ModelSim
which vsim && vsim -version
# -> /opt/cad/questa/bin/vsim ... Questa Sim-64 vsim 2022.3_1

# pyelftools (needed by stim_utils.py)
python3 -c 'import elftools; print("pyelftools OK")'

# Hardware/software constants agree
cd /home/eugenio/esp_multiot_pulp/accelerators/rtl/pulp_cluster_rtl
PULP_SDK=/home/eugenio/pulp_sdk_fix make check
```

`make check` should end with `CHECK PASS: all constants consistent` and include:

```
pulp-sdk link.ld L2      : 0xA0103680 OK
pulp-sdk link.ld L1      : 0x50000000 OK
pulp-sdk crt0 sync flag  : 0x5001FFF0 OK
```

---

## 2. How the flow works

The cluster has **no fabric controller** and no loader. It cannot open a file, and
nothing preloads its memories. Software reaches it like this:

```
  test.c                     cluster-side C, PMSIS API
    |  riscv32-unknown-elf-gcc + PulpOS 2 (chip target: pulp_esp)
    v
  ELF                        entry 0xA010B700, all sections in the L2 window
    |  stim_utils.py           -> address/data text rows
    |  generate_padded_stimuli.py -> dense C array
    v
  sdk_hello_cluster.h        { address, data } table + BASE_ADDRESS
    |  #include'd into the ESP host application
    v
  pulp_cluster_rtl.exe       host program running on Ariane
    |  at run time: copies the table into a DMA buffer it allocated
    v
  DMA buffer in host DRAM  ==  what the cluster sees as its 3 MiB "L2" window
    |  ESP accelerator socket + TLB translate window offsets to physical DRAM
    v
  cluster fetches instructions on demand through the socket, runs, and
  raises end-of-computation -> acc_done -> host STATUS bit
```

Key addresses (all cross-checked by `make check`):

| What | Address |
|---|---|
| L2 window base (the cluster's whole view of main memory, 3 MiB) | `0xA0103680` |
| ELF entry (`window + 0x8080`) | `0xA010B700` |
| Cluster base / TCDM (128 KiB) | `0x50000000` |
| Cluster peripherals (EoC at +0x0) | `0x50200000` |
| `printf` sink (simulation mock UART) | `0x03002000` |
| PE release flag (TCDM top − 0x10) | `0x5001FFF0` |

Two consequences worth internalising:

* **The cluster's "L2" is a host buffer.** Only what the host writes exists.
* **Nothing preloads TCDM.** Initialised cluster-local data is kept in L2 by the
  linker and copied into TCDM by the runtime at startup.

---

## 3. Quick start: run the existing test

With the environment of §1.4 set up:

```bash
# 1. Build the cluster ELF and regenerate the stimuli header
cd /home/eugenio/esp_multiot_pulp/accelerators/rtl/pulp_cluster_rtl/sw/cluster_tests_sdk/hello_cluster
./gen_header.sh

# 2. Build the ESP host application
cd /home/eugenio/esp_multiot_pulp/socs/xilinx-vc707-xc7vx485t
make pulp_cluster_rtl-baremetal

# 3. Simulate
TEST_PROGRAM=./soft-build/ariane/baremetal/pulp_cluster_rtl.exe make sim
```

Step 1 ends with:

```
OK: ../../baremetal/sdk_hello_cluster.h (8200 stimuli, entry 0xa010b700, check offset 0xABC0)
Select it in sw/baremetal/pulp_cluster.c:  #define HEADER_FILE "sdk_hello_cluster.h"
```

`sw/baremetal/pulp_cluster.c` line 23 selects the pulp-runtime baseline
(`matmul_selfcheck_8x8.h`) by default in this tree, so for this test **edit that
one line** before step 2, then verify:

```bash
grep -n 'define HEADER_FILE' /home/eugenio/esp_multiot_pulp/accelerators/rtl/pulp_cluster_rtl/sw/baremetal/pulp_cluster.c
# -> 23:#define HEADER_FILE "sdk_hello_cluster.h"
```

Step 3 takes roughly **11 minutes** wall clock.

---

## 4. Step-by-step, with what each step does

### 4.1 One-time: vendor the cluster RTL

```bash
make -C /home/eugenio/esp_multiot_pulp/accelerators/rtl/pulp_cluster_rtl vendor
```

Clones `pulp-platform/pulp_cluster` at the pinned revision
`07988cd01c359a81804820135927bc04da3c25cd`, resolves its 34 dependencies with
bender, flattens them into `vendor/`, applies the local RTL patches and
regenerates `pulp_cluster_rtl.sverilog` (800 entries) and
`pulp_cluster_rtl.defines` (17 defines).

**Needs network access.** Only re-run after changing the pin or `patches/`.

### 4.2 One-time: install the accelerator into the tech tree

```bash
cd /home/eugenio/esp_multiot_pulp/socs/xilinx-vc707-xc7vx485t
make pulp_cluster_rtl-hls
```

For an `hls_tool="rtl"` accelerator this performs no synthesis — it copies
`hw/src/*` and `hw/pulp_cluster.xml` into `tech/virtex7/acc/pulp_cluster_rtl/`.

Two things follow from this:

* **The SoC configuration GUI only lists accelerators found under
  `tech/<techlib>/acc/`.** If `PULP_CLUSTER_RTL` does not appear in the GUI, this
  step has not been run.
* **The simulator compiles the installed copy, not `hw/src/`.** After editing
  anything under `hw/src/`, re-run this target or the simulation silently uses
  the previous version.

### 4.3 One-time: SoC configuration

The tile layout lives in `socs/xilinx-vc707-xc7vx485t/socgen/esp/.esp_config`.
In this tree it is already correct, so **you can skip this step**.

> **Do not run `make esp-defconfig`.** The shipped defconfig has
> `TILE_1_0 = 2 empty empty`, and `esp-defconfig` copies it over `.esp_config` —
> deleting the accelerator tile.

To configure from scratch, use the GUI (needs a real `DISPLAY`):

```bash
cd /home/eugenio/esp_multiot_pulp/socs/xilinx-vc707-xc7vx485t
make esp-xconfig
```

Required settings — a 2×2 mesh, 64-bit NoC, PULP in tile (1,0):

```
CONFIG_NOC_ROWS = 2 / CONFIG_NOC_COLS = 2
CONFIG_COH_NOC_WIDTH = 64 / CONFIG_DMA_NOC_WIDTH = 64
TILE_0_0 = 0 mem mem
TILE_0_1 = 1 cpu cpu
TILE_1_0 = 2 acc PULP_CLUSTER_RTL basic_dma64 0 0 sld
TILE_1_1 = 3 misc IO
```

**Choose the `basic_dma64` design point.** `basic_dma32` is a stub with no
cluster inside that asserts done immediately. (socketgen also skips it
automatically when the system DMA width is 64, logging
`skipping pulp_cluster_rtl_basic_dma32`.)

### 4.4 Per test: build the ELF and generate the header

```bash
cd .../sw/cluster_tests_sdk/<your_test>
./gen_header.sh
```

The script sources the SDK config itself, runs `make clean` then
`make build platform=rtl`, and converts the resulting ELF into a stimuli header
in `sw/baremetal/`. It enforces two guards:

1. **ELF entry must be `0xa010b700`** — otherwise the wrong chip target or
   linker script was used.
2. **The first stimulus row must start at `A0103680`** — otherwise the image
   would be based at the wrong address.

Intermediates (`BUILD/`, `stim.txt`, `stim_trimmed.txt`) are left in the test
directory and are gitignored.

### 4.5 Per test: build the host application and simulate

```bash
cd /home/eugenio/esp_multiot_pulp/socs/xilinx-vc707-xc7vx485t
make pulp_cluster_rtl-baremetal
TEST_PROGRAM=./soft-build/ariane/baremetal/pulp_cluster_rtl.exe make sim
```

If you generated a header with a different name, point `HEADER_FILE` at it
(line 23 of `sw/baremetal/pulp_cluster.c`) before `make pulp_cluster_rtl-baremetal`.

---

## 5. Reading the results

A passing run prints these four lines, in this order:

```
[pulp] start (boot = window base + 0x8080)
[TB UART] [sdk] hello from cluster 0, 8/8 cores reported
[pulp] RUNG2 PASS: buffer[0xabc0] = expected magic
[pulp] done (cluster raised eoc)
```

`[TB UART]` lines come from the cluster; `[pulp]` lines from the host
application. The `[TB UART]` line is padded with ~210 trailing spaces by the
mock UART model.

> ### `Errors: 2` is the PASS signal — read this before debugging
>
> A **successful** run ends like this:
>
> ```
> ** Failure: Program Completed!
>    Time: 32298620 ns  ...  File: .../top.vhd
> Break in Process line__200 at .../top.vhd line 203
> End time: ... Elapsed time: 0:11:26
> Errors: 2, Warnings: 0
> ```
>
> ESP signals normal termination with a VHDL assertion at
> [`top.vhd:203`](../../../socs/xilinx-vc707-xc7vx485t/top.vhd):
>
> ```vhdl
> assert cpuerr = '0' report "Program Completed!" severity failure;
> ```
>
> `severity failure` is how the testbench stops the simulation, and Questa
> counts it in the summary. **`Errors: 2` with no `** Error` lines in the
> transcript is a pass.**
>
> A real failure looks different: `Errors: 3` or more, **and** actual
> `** Error` lines. Check with:
>
> ```bash
> grep -c '\*\* Error' socs/xilinx-vc707-xc7vx485t/modelsim/transcript   # 0 on a good run
> ```

The check offset (`0xabc0` above) is **derived per build** from the
`esp_check_word` symbol — it changes whenever your test changes. Compare it
against the `RUNG2_CHECK_OFFSET` in your generated header, not against this
document.

Note `[pulp] buffer @0x...` is the host's malloc pointer, **not** the window
base. Never compute addresses from it.

---

## 6. Writing your own test

Copy `sw/cluster_tests_sdk/hello_cluster/` and modify it. A test directory
needs three files:

```
sw/cluster_tests_sdk/<name>/
├── test.c          cluster-side program
├── Makefile        3 lines of substance
└── gen_header.sh   copy, adjust MAGIC32 and the output filename
```

### Makefile

```make
APP           = test
APP_SRCS      = test.c
APP_CFLAGS   += -O3 -g -I$(CURDIR)/../../baremetal
APP_LDFLAGS  += -O3 -g

include $(RULES_DIR)/pmsis_rules.mk
```

The `-I.../baremetal` lets you include headers shared with the host application.

> **This include differs from the pulp-runtime tests**, which use
> `include $(PULP_SDK_HOME)/install/rules/pulp.mk`. The two runtimes are not
> interchangeable.

### Host-side contract

The host application enables a check automatically when your generated header
defines the right macros. `gen_header.sh` appends:

```c
#define RUNG2_CHECK_OFFSET 0x0000ABC0
#define RUNG2_MAGIC64      0x5DC0FFEE5DC0FFEEULL
```

The host then compares the 64-bit word at that buffer offset against the magic
and prints `RUNG2 PASS` or `RUNG2 FAIL`. No host-side code change is needed.

The mechanism in `test.c`:

```c
#define ESP_SENTINEL64  0xDEADBEEFDEADBEEFULL
#define ESP_MAGIC32     0x5DC0FFEEu

volatile uint64_t esp_check_word = ESP_SENTINEL64;   /* initialised L2 global */
```

Making it an **initialised global** matters: it lives inside the program image,
so the stimuli — and therefore the host's DMA buffer — cover it automatically.
`gen_header.sh` finds its address with `nm` and computes the offset. The
sentinel distinguishes *"never ran"* from *"ran and failed"*.

### Constraints you must respect

**`printf` from core 0 only.** The mock UART decodes `(addr >> 2) & 0x7`, and
PulpOS's stdout address is `ARCHI_STDOUT_ADDR + (core_id << 3)`. So cores
1, 2, 3, 5, 6 and 7 land on FIFO/modem-control registers and are **silently
discarded** (also corrupting that model's state), while cores 0 and 4 both hit
the transmit register and interleave into one line. Guard your prints:

```c
if (pi_core_id() == 0)
    printf(...);
```

**Keep the entry address at `0xA010B700`.** `gen_header.sh` enforces this.

**All 8 cores run `main()`.** This is SPMD, not fork-join: there is no fabric
controller dispatching work. Use `pi_core_id()` to divide it.

**Which PMSIS APIs work.** In no-FC mode there is no scheduler and no
fabric-controller interrupt controller. Everything below compiles and links —
the unusable ones fail **at run time**:

| Usable | Not usable in no-FC mode |
|---|---|
| `pi_core_id()`, `pi_cluster_id()` | `pi_task_*` (no scheduler) |
| `pi_cl_team_barrier()` | `pi_time_wait_us()` (waits on an FC timer IRQ that never fires) |
| `pi_cl_team_fork()` *(see §9)* | `pi_cluster_send_task*()` (FC-side API) |
| `pi_cl_team_critical_enter/exit()` | async completion callbacks |
| `pi_cl_l1_malloc()`, `pi_l2_malloc()` | |
| `printf()` (core 0) | |

---

## 7. Running both flows

| | pulp-runtime | pulp-sdk |
|---|---|---|
| Tests in | `sw/cluster_tests/` | `sw/cluster_tests_sdk/` |
| Compiler | xPack `riscv-none-elf-gcc` 15.2 | PULP-fork `riscv32-unknown-elf-gcc` 7.1.1 |
| Runtime | pulp-runtime | PulpOS 2 / PMSIS |
| Makefile include | `$(PULP_SDK_HOME)/install/rules/pulp.mk` | `$(RULES_DIR)/pmsis_rules.mk` |
| Config | `cluster_generator/pulp-runtime/configs/astral-cluster.sh` | `pulp_sdk_fix/configs/pulp_cluster_esp.sh` |

To run the pulp-runtime baseline instead, point `HEADER_FILE` at one of its
headers (e.g. `matmul_selfcheck_8x8.h`) and rebuild the host application. Both
share the same host application, header pipeline and simulation.

> ### One flow per shell
>
> **Both frameworks export `PULP_SDK_HOME`, pointing at different trees.**
> Whichever is sourced last wins, and the other's build then fails.
>
> Worse and quieter: the pulp-runtime environment exports `PULP_ARCH_CFLAGS`
> and `PULP_APP_CFLAGS`, which pulp-sdk assigns with `?=`. Those exported values
> **silently win**, stripping the `xgap9` architecture flag — you get a build
> that looks fine but has no Xpulp code and the wrong ISA.
>
> Always start a **fresh shell** when switching flows. Do not "just source the
> other one".

---

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `cc1: error while loading shared libraries: libmpfr.so.6` | RHEL 8 ships `libmpfr.so.4`; the toolchain needs `.so.6` | Ensure `<toolchain>/lib/libmpfr.so.6` exists and is on `LD_LIBRARY_PATH`. Sourcing `mentor_env.sh` *after* the SDK config also causes this — it overwrites `LD_LIBRARY_PATH` |
| `ERROR: ELF entry 0x1c008080 != 0xa010b700` | Built with the classic `pulp` chip target | Check `PULPOS_TARGET=pulp_esp`; make sure `gen_header.sh` sourced `pulp_cluster_esp.sh` |
| `ERROR: pyelftools missing` | `stim_utils.py` needs it | `source /opt/cad/scripts/tools_env.sh` (activates the venv) |
| `XILINX_VIVADO path not specified` | Vivado not in the environment | `source /opt/Xilinx/Vivado/2023.2/settings64.sh`. Blocks **every** target run from a SoC directory |
| `Failed to initialize licensing environment` (vsim) | Questa licence vars unset | See §1.4 |
| `PULP_CLUSTER_RTL` absent from the xconfig GUI | `tech/virtex7/acc/` is empty | Run `make pulp_cluster_rtl-hls` **before** `make esp-xconfig` |
| `fatal: cannot change to '.../vendor/pulp-runtime'` during `make vendor` | Bug in `gen_vendor.sh`: the dependency-patch loop tried to apply the *software* pulp-runtime patch to a nonexistent RTL package | Fixed (skip added in `gen_vendor.sh`) — verify the skip is present if you hit this |
| `RUNG2 FAIL`, value `0xDEADBEEFDEADBEEF` | Sentinel intact: the cluster booted but never reached the completion write | Failure is inside your test, after start |
| `RUNG2 FAIL`, value `0x0` | The image never landed, or the offset is wrong | Check `BASE_ADDRESS` and `RUNG2_CHECK_OFFSET` in the header |
| No `[TB UART]` line but the check passes | Compute path fine, print path not | You are printing from a non-zero core — see §6 |
| Fewer than `8/8` cores reported | Not all PEs left the sync loop | Check the `POS_PE_SYNC_FLAG` value; `make check` validates it |
| `vsim.tcl: max_chunks reached without verdict` | 120 × 1 ms of simulated time elapsed with no verdict string | Usually a hang before end-of-computation |
| Internal compiler error on `id_queue.sv` during RTL compile | `modelsim.ini` has `VoptFlow = 0` | It must be `VoptFlow = 1`. ESP's makefile sets it to 0; the cache here keeps 1 |

### RTL warning canaries

The integration report tracks three signatures. Counts are image-dependent —
**a handful is benign, a flood is not**:

```bash
T=socs/xilinx-vc707-xc7vx485t/modelsim/transcript
grep -c SLVERR    "$T"    # bus errors: speculative i-cache prefetch below the window is benign
grep -c 'RQ-4'    "$T"    # HCI protocol warnings: should be 0 (patched)
grep -c 3837      "$T"    # double-driven signals: should be 0 (patched)
```

The `hello_cluster` run shows `0` for all three.

---

## 9. Known limitations / not yet tested

**Exercised by the passing run:** boot and release of all 8 PEs; the hardware
barrier; `printf`; a cluster write to the L2 window read back by the host;
end-of-computation; the header pipeline.

**Compiled and wired, but not yet meaningfully exercised:**

* **`pi_cl_team_fork()` and the event-unit dispatch FIFO.** The register offsets
  were verified against the event-unit RTL and match, but no test has executed
  this path. It is the highest-value next test.
* **The L1 preload copy.** `hello_cluster` has almost no initialised
  cluster-local data, so the copy ran over ~4 bytes. A test with real TCDM
  arrays would be its first genuine proof.
* **The iDMA driver** shipped by the SDK fork.
* **`pi_time_*`.** Repointed at the cluster timer; never called.

**Deliberately disabled:**

* **Interrupts.** The core derives its trap vector from the boot-address
  register in a way that does not reproduce the vector table's address for this
  window base, so a trap would jump into unmapped memory. Nothing in this model
  needs interrupts. Re-enabling them requires resolving that first.
* **HWPEs.** `HwpePresent=0` in the wrapper configuration.

**Structural:** anything requiring the scheduler or a fabric controller
(`pi_task_*`, async callbacks, `pi_cluster_send_task*`) cannot work in
standalone mode — see §6.

**Not re-run in this setup:** the Xilinx simulation-library build
(`compile_simlib`) is quoted from the integration report, not re-verified. Note
that `compile_simlib` exits non-zero after failing ~26 SystemC/AI-Engine
libraries that this design does not use; ESP's own make rule deletes the whole
cache on that non-zero exit, which is why it was built manually with
`-simulator questa -simulator_exec_path /opt/cad/questa/bin`.
