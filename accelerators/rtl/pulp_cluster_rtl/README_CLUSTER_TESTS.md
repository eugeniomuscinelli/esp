# How to write and run a test for the PULP cluster in ESP

This is the short version. Full detail and evidence: `pulp_esp_integration_report.md`,
section 10.

**The idea in one paragraph.** The cluster cannot see the host's memory directly —
it sees a 3 MiB *window* starting at address `0xA0103680`, which ESP maps onto a
buffer the host app allocates. You write a small C program, compile it with a
RISC-V cross-compiler against the `pulp-runtime` library (which has already been
retargeted to that window), convert the resulting ELF into a C header full of
`{address, data}` pairs, and hand that header to the host app. The host loads it
into the buffer, points the cluster's boot register at the entry point, and starts
it. Your program's `printf` comes out on the simulation console.

## What must always line up (the four constants)

| what | value | where it lives |
|---|---|---|
| L2 window base | `0xA0103680` | wrapper `L2BaseAddr`, header `BASE_ADDRESS`, translator `BASE_ADDR`, linker `L2 ORIGIN` |
| entry point | base + `0x8080` = `0xA010B700` | ELF entry (`_start`); host `BOOT_OFFSET` register |
| `printf` output address | `0x03002000` | pulp-runtime `ARCHI_STDOUT_ADDR`; wrapper mock-UART window |
| TCDM (cluster L1) size | 128 KiB | linker `L1 LENGTH 0x1FFFC`; crt0 sync flag `0x5001FFF0` |

You never edit these — the retargeted runtime and the scripts below carry them.
`make check` (with `PULP_RUNTIME` set, see below) verifies all of them.

## 1. Toolchain (already installed)

xPack `riscv-none-elf-gcc` 15.2 at `~/toolchains/xpack-riscv-none-elf-gcc-15.2.0-1`,
building plain `rv32imc` (no PULP SIMD extensions — fine for functional tests).
The retargeted runtime lives in `/home/eugenio/cluster_generator/pulp-runtime`
(pin `3ba9a349` + the 4-file patch recorded in `patches/pulp-runtime/`).

## 2. Write the test

```sh
cd /home/eugenio/esp_clean_integration_target/accelerators/rtl/pulp_cluster_rtl/sw/cluster_tests
mkdir mytest && cd mytest
# mytest.c: normal C. printf() works. 8 cores run main(); use rt_core_id(),
# synch_barrier(), plp_dma_memcpy()/plp_dma_wait() as in matmul_selfcheck/.
cat > Makefile <<'MK'
PULP_APP = test
PULP_APP_SRCS = mytest.c
PULP_CFLAGS = -O3
include $(PULP_SDK_HOME)/install/rules/pulp.mk
MK
```

Pitfall: build exactly as below — never with `platform=fpga` or `io=uart`, or
`printf` silently reroutes to a UART this design doesn't have.

## 3. Build the ELF and generate the header

```sh
source /opt/cad/scripts/tools_env.sh          # CAD tools + python venv (pyelftools)
cd /home/eugenio/cluster_generator && source env/esp-toolchain.sh
source pulp-runtime/configs/astral-cluster.sh
cd /home/eugenio/esp_clean_integration_target/accelerators/rtl/pulp_cluster_rtl/sw/cluster_tests/mytest
make clean all                                 # -> build/test/test (entry must be 0xa010b700)
```

Easiest header path: copy `../matmul_selfcheck/gen_header.sh` into your test dir and
run it — it builds, converts, **auto-trims** and guards everything. If you do it by
hand instead, the one dangerous step is the trim: `stim_utils.py` emits both the
cluster-internal `5xxxxxxx` lines and the `A01xxxxx` window lines, and the padding
script takes *the lowest address present* as the base — you must delete every line
before the first `A0103680_` row, or the header is silently wrong:

```sh
$PULPRT_HOME/bin/stim_utils.py --binary=build/test/test --vectors=stim.txt
sed -n "$(grep -n '^A' stim.txt | head -1 | cut -d: -f1),\$p" stim.txt > stim_trimmed.txt
head -1 stim_trimmed.txt                       # MUST start with A0103680_
python3 /home/eugenio/cluster_test_generator/generate_padded_stimuli.py stim_trimmed.txt
cp stimuli.h ../../baremetal/mytest.h
```

## 4. Select it and run the simulation

```sh
cd /home/eugenio/esp_clean_integration_target/accelerators/rtl/pulp_cluster_rtl
#  edit sw/baremetal/pulp_cluster.c:  #define HEADER_FILE "mytest.h"
PULP_RUNTIME=/home/eugenio/cluster_generator/pulp-runtime make check   # four constants OK?

cd ../../../socs/xilinx-vc707-xc7vx485t
export PATH=/opt/cad/questa/bin:$PATH          # MUST be Questa, not ModelSim DE
make pulp_cluster_rtl-baremetal
TEST_PROGRAM=./soft-build/ariane/baremetal/pulp_cluster_rtl.exe make sim
```

The run stops by itself (`vsim.tcl` watches the console). Your `printf` lines appear
as `[TB UART] ...` in `modelsim/transcript`; the host app prints `[pulp] done` last.
A run takes ~15-20 minutes wall-clock.

Two rules that save hours: after editing anything under `hw/src/`, run
`make pulp_cluster_rtl-hls` first (the sim compiles the *installed* copy under
`tech/`, not your edit), and check the transcript's timestamp before believing it —
a failed build leaves the previous transcript in place.
