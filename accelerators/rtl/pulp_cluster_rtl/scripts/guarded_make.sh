#!/bin/bash
# Run an ESP make target (typically vivado-setup or vivado-syn) with guard rails.
#
# Usage, from the SoC directory: <path>/guarded_make.sh <make args...>
#        or, for any other command: <path>/guarded_make.sh -- <command> <args...>
#
# Same protections as run_ooc_synth.sh: a cap on the address space of every
# process, a watchdog that stops the whole run when the machine gets short on
# memory, and a wall-clock limit. The environment is minimal on purpose.
set -u
MEM_CAP_GB=${MEM_CAP_GB:-96}
MIN_AVAIL_GB=${MIN_AVAIL_GB:-16}
TIME_LIMIT=${TIME_LIMIT:-30h}
XILINX_VIVADO=${XILINX_VIVADO:-/opt/Xilinx/Vivado/2023.2}
XILINXD_LICENSE_FILE=${XILINXD_LICENSE_FILE:-2177@espdev.cs.columbia.edu}
RISCV=${RISCV:-/opt/riscv}
EXTRA_PATH=${EXTRA_PATH:-/opt/cad/questa/bin:$HOME/venvs/esp311/bin}

# ESP asks "overwrite existing Vivado project? [y|n]" when the project exists
# and loops forever without an answer. Default: keep the project.
PROMPT_ANSWER=${PROMPT_ANSWER:-n}

if [ "${1:-}" = "--" ]; then shift; CMD=("$@"); else CMD=(make "$@"); fi

ulimit -v $((MEM_CAP_GB * 1024 * 1024))
yes "$PROMPT_ANSWER" | setsid env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" SHELL=/bin/bash PWD="$PWD" \
  PATH="$XILINX_VIVADO/bin:$RISCV/bin:$EXTRA_PATH:/usr/local/bin:/usr/bin:/bin" \
  LM_LICENSE_FILE="${LM_LICENSE_FILE:-1720@bioeelincad.ee.columbia.edu}" \
  MGLS_LICENSE_FILE="${MGLS_LICENSE_FILE:-1720@bioeelincad.ee.columbia.edu}" \
  XILINXD_LICENSE_FILE="$XILINXD_LICENSE_FILE" XILINX_VIVADO="$XILINX_VIVADO" RISCV="$RISCV" \
  timeout --signal=TERM --kill-after=60 "$TIME_LIMIT" "${CMD[@]}" &
MPID=$!

# The command runs in its own session, so Ctrl-C in the terminal does not reach
# it. Forward the interrupt to the whole group.
trap 'kill -TERM -- "-$MPID" 2>/dev/null' INT TERM

(
  while kill -0 "$MPID" 2>/dev/null; do
    avail=$(awk '/MemAvailable/ {print int($2 / 1048576)}' /proc/meminfo)
    if [ "$avail" -lt "$MIN_AVAIL_GB" ]; then
      echo "WATCHDOG: only ${avail} GB available, stopping the run"
      kill -KILL -- "-$MPID" 2>/dev/null
      break
    fi
    sleep 15
  done
) &

wait "$MPID"
RC=$?
echo "exit code $RC"
exit $RC
