#!/bin/bash -e
# Run the esp_acc_tlb directed TB inside an existing SoC modelsim workspace
# (all ESP packages are already compiled into its work library).
#
#   source /opt/cad/scripts/tools_env.sh        # then put Questa first:
#   export PATH=/opt/cad/questa/bin:$PATH
#   ./run_tlb_tb.sh [path-to-soc-modelsim-dir]
#
# Default workspace: socs/xilinx-vc707-xc7vx485t/modelsim

ESP_ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
WS="${1:-$ESP_ROOT/socs/xilinx-vc707-xc7vx485t/modelsim}"
TB_SRC="$ESP_ROOT/rtl/sockets/proxy/sim/esp_acc_tlb_tb.vhd"

[ -f "$WS/modelsim.ini" ] || { echo "ERROR: $WS is not a compiled SoC modelsim workspace" >&2; exit 1; }

cd "$WS"
vcom -quiet -work work "$TB_SRC"
vsim -c -quiet work.esp_acc_tlb_tb -do "run -all; quit -f" | tee tlb_tb_transcript.log
grep -q "TB PASSED" tlb_tb_transcript.log
