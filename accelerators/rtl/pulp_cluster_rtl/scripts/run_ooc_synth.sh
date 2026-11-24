#!/bin/bash
# Run the out-of-context synthesis of the PULP cluster with guard rails.
#
# Usage: scripts/run_ooc_synth.sh <probe|synth> [part] [period_ns]
#
# A runaway Vivado process once exhausted the memory of the build machine, so
# this runner caps the address space of every Vivado process, stops the run if
# the machine gets short on memory, and enforces a wall-clock limit.
set -u
MODE=${1:?probe or synth}
PART=${2:-xcvu9p-flga2104-2L-e}
PERIOD=${3:-12.8}
MEM_CAP_GB=${MEM_CAP_GB:-72}
MIN_AVAIL_GB=${MIN_AVAIL_GB:-24}
TIME_LIMIT=${TIME_LIMIT:-8h}
XILINX_VIVADO=${XILINX_VIVADO:-/opt/Xilinx/Vivado/2023.2}
XILINXD_LICENSE_FILE=${XILINXD_LICENSE_FILE:-2177@espdev.cs.columbia.edu}

ACC_ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$ACC_ROOT/syn/$PART
mkdir -p "$OUT/run_$MODE"
cd "$OUT/run_$MODE" || exit 1

python3 "$ACC_ROOT/scripts/gen_syn_flist.py" "$ACC_ROOT" pulp_cluster_rtl_basic_dma64 "$OUT/syn_flist.f" \
  > "$OUT/syn_flist.log" || { cat "$OUT/syn_flist.log"; exit 1; }
head -1 "$OUT/syn_flist.log"

ulimit -v $((MEM_CAP_GB * 1024 * 1024))
setsid env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" SHELL=/bin/bash \
  PATH="$XILINX_VIVADO/bin:/usr/local/bin:/usr/bin:/bin" \
  XILINXD_LICENSE_FILE="$XILINXD_LICENSE_FILE" \
  timeout --signal=TERM --kill-after=60 "$TIME_LIMIT" \
  vivado -mode batch -nojournal -log "$OUT/$MODE.log" \
    -source "$ACC_ROOT/scripts/ooc_synth.tcl" \
    -tclargs "$ACC_ROOT" "$PART" "$PERIOD" "$OUT" "$MODE" > "$OUT/$MODE.console" 2>&1 &
VPID=$!

(
  while kill -0 "$VPID" 2>/dev/null; do
    avail=$(awk '/MemAvailable/ {print int($2 / 1048576)}' /proc/meminfo)
    if [ "$avail" -lt "$MIN_AVAIL_GB" ]; then
      echo "WATCHDOG: only ${avail} GB available, stopping Vivado" | tee -a "$OUT/$MODE.console"
      kill -KILL -- "-$VPID" 2>/dev/null
      break
    fi
    sleep 15
  done
) &

wait "$VPID"
RC=$?
echo "vivado exit code $RC"
grep -E "^OOC:|^ERROR|WATCHDOG" "$OUT/$MODE.log" "$OUT/$MODE.console" 2>/dev/null | cut -c1-300 | sort -u | head -40
exit $RC
