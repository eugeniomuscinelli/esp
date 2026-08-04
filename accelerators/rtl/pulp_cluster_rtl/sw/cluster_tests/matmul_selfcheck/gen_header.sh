#!/bin/bash -e
# Build the matmul_selfcheck cluster ELF and regenerate the ESP stimuli header
# sw/baremetal/matmul_selfcheck_<N>x<N>.h (report section 10.4 flow, with the
# manual L1-trim step automated and guarded).
#
# Prereq (once per shell): source /opt/cad/scripts/tools_env.sh
# Everything else (toolchain, runtime target) is sourced here.
#
# The generated header ends with '#include "matmul_selfcheck_proto.h"' and
# '#define MATMUL_SELFCHECK 1' so the host app (pulp_cluster.c) enables the
# golden-model check automatically when this header is selected.

CG=/home/eugenio/cluster_generator
cd "$(dirname "$0")"

python3 -c 'import elftools' 2>/dev/null || {
  echo "ERROR: pyelftools missing - source /opt/cad/scripts/tools_env.sh first" >&2; exit 1; }
source "$CG/env/esp-toolchain.sh"
source "$CG/pulp-runtime/configs/astral-cluster.sh"

make clean all

ENTRY=$(riscv-none-elf-readelf -h build/test/test | awk '/Entry point/{print $NF}')
if [ "$ENTRY" != "0xa010b700" ]; then
  echo "ERROR: ELF entry $ENTRY != 0xa010b700 (wrapper BootAddr) - wrong runtime/link.ld?" >&2
  exit 1
fi

"$PULPRT_HOME/bin/stim_utils.py" --binary=build/test/test --vectors=stim.txt

# drop the L1/TCDM (0x5xxxxxxx) rows: ESP loads only the L2 window image.
# generate_padded_stimuli.py takes BASE_ADDRESS = lowest address present, so
# this trim is load-bearing - both guards below are mandatory.
FIRST_A=$(grep -n '^A' stim.txt | head -1 | cut -d: -f1)
[ -n "$FIRST_A" ] || { echo "ERROR: no A-range rows in stim.txt" >&2; exit 1; }
sed -n "${FIRST_A},\$p" stim.txt > stim_trimmed.txt
head -1 stim_trimmed.txt | grep -q '^A0103680_' || {
  echo "ERROR: trimmed stim does not start at A0103680" >&2; exit 1; }
[ "$(cut -c1 stim_trimmed.txt | sort -u)" = "A" ] || {
  echo "ERROR: non-A rows survived the trim" >&2; exit 1; }

python3 /home/eugenio/cluster_test_generator/generate_padded_stimuli.py stim_trimmed.txt

MMN=$(grep -oE '#define MM_N [0-9]+' ../../baremetal/matmul_selfcheck_proto.h | awk '{print $3}')
OUT=../../baremetal/matmul_selfcheck_${MMN}x${MMN}.h
{
  cat stimuli.h
  echo ''
  echo '/* appended by gen_header.sh: enable the host-side golden check */'
  echo '#include "matmul_selfcheck_proto.h"'
  echo '#define MATMUL_SELFCHECK 1'
} > "$OUT"
rm -f stimuli.h

echo "OK: $OUT ($(grep -c '{0x' "$OUT") stimuli, N=$MMN, entry $ENTRY)"
echo "Select it in sw/baremetal/pulp_cluster.c:  #define HEADER_FILE \"matmul_selfcheck_${MMN}x${MMN}.h\""
