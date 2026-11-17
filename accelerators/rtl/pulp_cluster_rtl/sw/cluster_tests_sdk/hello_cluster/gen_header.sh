#!/bin/bash -e
# Build the pulp-sdk hello_cluster ELF and regenerate the ESP stimuli header
# sw/baremetal/sdk_hello_cluster.h.
#
# Twin of sw/cluster_tests/matmul_selfcheck/gen_header.sh. The pipeline is
# identical - ELF -> stim_utils.py -> drop L1 rows -> generate_padded_stimuli.py
# -> C header - and both guards (entry address, first stimulus row) are kept
# verbatim, because the retarget deliberately preserved those two constants.
# Only the environment and the tool paths differ:
#
#   pulp-runtime twin                     this script
#   -----------------                     -----------
#   cluster_generator/env/esp-toolchain.sh  pulp_sdk_fix/configs/pulp_cluster_esp.sh
#   + pulp-runtime/configs/astral-cluster.sh
#   riscv-none-elf-readelf   (xPack)      riscv32-unknown-elf-readelf (PULP fork)
#   $PULPRT_HOME/bin/stim_utils.py        $PULP_SDK_HOME/bin/stim_utils.py
#   build/test/test                       BUILD/$TARGET_CHIP/GCC_RISCV/test/test
#
# Prereq (once per shell): source /opt/cad/scripts/tools_env.sh   (pyelftools)
# Do NOT also source a pulp-runtime config in the same shell: both define
# PULP_SDK_HOME and whichever is sourced last wins.

SDK=/home/eugenio/pulp_sdk_fix
WINDOW_BASE=0xA0103680          # wrapper L2BaseAddr
ENTRY_EXPECTED=0xa010b700       # wrapper BootAddr = L2BaseAddr + 0x8080
MAGIC32=0x5DC0FFEE              # must match ESP_MAGIC32 in test.c

cd "$(dirname "$0")"

python3 -c 'import elftools' 2>/dev/null || {
  echo "ERROR: pyelftools missing - source /opt/cad/scripts/tools_env.sh first" >&2; exit 1; }

source "$SDK/configs/pulp_cluster_esp.sh"

make clean >/dev/null
make build platform=rtl

ELF="BUILD/$TARGET_CHIP/GCC_RISCV/test/test"
[ -f "$ELF" ] || { echo "ERROR: $ELF not produced" >&2; exit 1; }

ENTRY=$(riscv32-unknown-elf-readelf -h "$ELF" | awk '/Entry point/{print $NF}')
if [ "$ENTRY" != "$ENTRY_EXPECTED" ]; then
  echo "ERROR: ELF entry $ENTRY != $ENTRY_EXPECTED (wrapper BootAddr) - wrong chip target/link.ld?" >&2
  exit 1
fi

"$PULP_SDK_HOME/bin/stim_utils.py" --binary="$ELF" --vectors=stim.txt

# Drop any L1/TCDM (0x5xxxxxxx) rows: ESP loads only the L2 window image.
# generate_padded_stimuli.py takes BASE_ADDRESS = lowest address present, so
# this trim is load-bearing - both guards below are mandatory.
#
# With this chip target the trim is normally a no-op: the linker gives the L1
# sections load addresses in L2 (AT> L2) and stim_utils emits p_paddr, so no
# 0x5xxxxxxx rows appear. It is kept because that is a property of the linker
# script, not something this script can assume.
FIRST_A=$(grep -n '^A' stim.txt | head -1 | cut -d: -f1)
[ -n "$FIRST_A" ] || { echo "ERROR: no A-range rows in stim.txt" >&2; exit 1; }
sed -n "${FIRST_A},\$p" stim.txt > stim_trimmed.txt
head -1 stim_trimmed.txt | grep -q '^A0103680_' || {
  echo "ERROR: trimmed stim does not start at A0103680" >&2; exit 1; }
[ "$(cut -c1 stim_trimmed.txt | sort -u)" = "A" ] || {
  echo "ERROR: non-A rows survived the trim" >&2; exit 1; }

python3 /home/eugenio/cluster_test_generator/generate_padded_stimuli.py stim_trimmed.txt

# Locate the completion word in the ELF rather than hard-coding a window offset.
# Because it is an initialised L2 global it sits inside the program image, so
# the stimuli - and therefore the host's DMA buffer - cover it by construction.
SYM=$(riscv32-unknown-elf-nm "$ELF" | awk '/ [BbDd] esp_check_word$/{print $1}')
[ -n "$SYM" ] || { echo "ERROR: symbol esp_check_word not found in $ELF" >&2; exit 1; }
CHECK_OFFS=$(( 0x$SYM - WINDOW_BASE ))
if [ "$CHECK_OFFS" -lt 0 ]; then
  echo "ERROR: esp_check_word at 0x$SYM is below the window base $WINDOW_BASE" >&2; exit 1; fi

OUT=../../baremetal/sdk_hello_cluster.h
{
  cat stimuli.h
  echo ''
  echo '/* appended by gen_header.sh: enable the host-side rung-2 check in'
  echo ' * sw/baremetal/pulp_cluster.c. Offset derived from the ELF symbol'
  echo " * esp_check_word (0x$SYM) relative to the window base $WINDOW_BASE. */"
  printf '#define RUNG2_CHECK_OFFSET 0x%08X\n' "$CHECK_OFFS"
  printf '#define RUNG2_MAGIC64      0x%08X%08XULL\n' "$MAGIC32" "$MAGIC32"
} > "$OUT"
rm -f stimuli.h

echo "OK: $OUT ($(grep -c '{0x' "$OUT") stimuli, entry $ENTRY, check offset $(printf '0x%X' "$CHECK_OFFS"))"
echo "Select it in sw/baremetal/pulp_cluster.c:  #define HEADER_FILE \"sdk_hello_cluster.h\""
