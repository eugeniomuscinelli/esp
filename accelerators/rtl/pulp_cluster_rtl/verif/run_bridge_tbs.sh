#!/bin/bash
# Run the two directed bridge-module testbenches (plan Step 4, mandatory gate).
# Requires vlib/vlog/vsim on PATH (source /opt/cad/scripts/tools_env.sh, questa first).
#
# The TBs need only the AXI_BUS interface definition from the vendored axi package
# (plus its axi_pkg dependency) - not the full cluster filelist.
set -uo pipefail

ACC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${1:-$ACC_DIR/verif/bridge_tb_work}"
SRC="$ACC_DIR/hw/src/pulp_cluster_rtl_basic_dma64"
mkdir -p "$WORK" && cd "$WORK"

rm -rf work_tb
vlib work_tb >/dev/null
vmap work_tb "$PWD/work_tb" >/dev/null

vlog -sv -quiet -work work_tb \
    "+incdir+$ACC_DIR/vendor/axi/include" \
    "+incdir+$ACC_DIR/vendor/common_cells/include" \
    "$ACC_DIR/vendor/axi/src/axi_pkg.sv" \
    "$ACC_DIR/vendor/axi/src/axi_intf.sv" \
    "$SRC/axi2dmafifo.sv" \
    "$SRC/cluster_control.sv" \
    "$ACC_DIR/verif/axi2dmafifo_tb.sv" \
    "$ACC_DIR/verif/cluster_control_tb.sv" || { echo "BRIDGE TB: vlog FAILED"; exit 1; }

rc=0
for tb in axi2dmafifo_tb cluster_control_tb; do
    echo ">> vsim $tb"
    vsim -c -quiet -work work_tb "$tb" -do "run -all; quit -f" | tee "$tb.log" \
        | grep -E "TB PASSED|TB FAILED|Error|Fatal"
    if ! grep -q "TB PASSED" "$tb.log"; then
        echo ">> $tb: FAILED"
        rc=1
    fi
done
exit $rc
