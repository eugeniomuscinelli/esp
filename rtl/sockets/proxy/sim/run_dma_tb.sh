#!/bin/bash -e
# Run the esp_acc_dma directed TB inside an existing SoC modelsim workspace
# (all ESP packages are already compiled into its work library). The TB runs
# twice: with and without scatter-gather.
#
#   put Questa/ModelSim on PATH, then
#   ./run_dma_tb.sh [path-to-soc-modelsim-dir]
#
# Default workspace: socs/xilinx-vc707-xc7vx485t/modelsim

ESP_ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
WS="${1:-$ESP_ROOT/socs/xilinx-vc707-xc7vx485t/modelsim}"
TB_SRC="$ESP_ROOT/rtl/sockets/proxy/sim/esp_acc_dma_tb.vhd"

[ -f "$WS/modelsim.ini" ] || { echo "ERROR: $WS is not a compiled SoC modelsim workspace" >&2; exit 1; }

cd "$WS"
vcom -quiet -93 -work work "$TB_SRC"
for sg in 1 0; do
  vsim -c -quiet -gSG=$sg work.esp_acc_dma_tb -do "run -all; quit -f" | tee dma_tb_transcript_sg$sg.log
done
grep -q "TB PASSED" dma_tb_transcript_sg1.log
grep -q "TB PASSED" dma_tb_transcript_sg0.log
