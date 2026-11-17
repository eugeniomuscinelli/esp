#!/bin/bash
# Standalone ECC elaboration probe (plan Step 3.4). Requires vlib/vlog/vopt on PATH
# (source /opt/cad/scripts/tools_env.sh and put the questa bin dir first).
#
# Compiles the vendored cluster filelist into a scratch library with THE SAME vlog
# options ESP's per-accelerator rule will use (utils/make/modelsim.mk MODELSIM_ACC_LIB_RULE
# with VLOGOPT from modelsim.mk/ariane.mk, global +incdir+ stripped), then vopts the
# probe top. Exit 0 = ECC configuration elaborates on this simulator.
set -uo pipefail

ACC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${1:-$ACC_DIR/verif/ecc_probe_work}"
mkdir -p "$WORK" && cd "$WORK"

# ESP's VLOGOPT as seen by the acc-lib rule on an FPGA techlib (incdirs stripped):
#   modelsim.mk:9-14  -suppress 2275 -suppress 2583 -suppress 2892 +define+XILINX_FPGA
#   ariane.mk:200-208 -incr -nologo -suppress 13262 -suppress 2286 -permissive
#                     +define+WT_DCACHE -pedanticerrors -suppress 2583
ESP_VLOGOPT="-suppress 2275 -suppress 2583 -suppress 2892 +define+XILINX_FPGA -incr -nologo -suppress 13262 -suppress 2286 -permissive +define+WT_DCACHE -pedanticerrors"

# Extra options the integration passes via the ACC_MODELSIM_VLOGOPT hook (Step 5):
#  -suppress 2577,2986   : vlog-2986 (hier ref in constant ctx, axi_test.sv) is a plain
#                          warning normally; -pedanticerrors promotes it - demote again.
#  -svinputport=relaxed  : Questa 2022.3 defaults to -svinputport=net, which rejects
#                          typed input ports ("Net data types must be 4-state", e.g.
#                          neureka_ctrl_fsm.sv:39 'input flags_engine_t'); 'relaxed'
#                          treats explicitly-typed inputs as variables (VCS-compatible).
EXTRA_VLOGOPT="-suppress 2986 -suppress 2577 -svinputport=relaxed"

# Rebase the committed filelist onto the vendor tree (same transform ESP's awk does).
awk -v base="$ACC_DIR/vendor/" '
  /^[[:space:]]*$/ || /^[[:space:]]*#/ {next}
  /^[[:space:]]*\+incdir\+/ {sub(/^[[:space:]]*\+incdir\+/,""); if(/^\//) print "+incdir+" $0; else print "+incdir+" base $0; next}
  /^[[:space:]]*\// {sub(/^[[:space:]]*/,""); print; next}
  {sub(/^[[:space:]]*/,""); print base $0}
' "$ACC_DIR/pulp_cluster_rtl.sverilog" > probe.rtl.f

DEFS="$(tr '\n' ' ' < "$ACC_DIR/pulp_cluster_rtl.defines")"

rm -rf work_probe
vlib work_probe >/dev/null
vmap work_probe "$PWD/work_probe" >/dev/null

echo ">> vlog (ESP-equivalent flags + PULP defines)"
vlog -sv -quiet $ESP_VLOGOPT $EXTRA_VLOGOPT $DEFS -work work_probe -f probe.rtl.f \
    "$ACC_DIR/verif/ecc_probe_top.sv" |& tee vlog.log
vlog_rc=${PIPESTATUS[0]}
[ "$vlog_rc" -eq 0 ] || { echo "PROBE: vlog FAILED (rc=$vlog_rc)"; exit 1; }

echo ">> vopt ecc_probe_top"
vopt -quiet -work work_probe ecc_probe_top -o ecc_probe_top_opt |& tee vopt.log
vopt_rc=${PIPESTATUS[0]}
if [ "$vopt_rc" -eq 0 ]; then
    echo "PROBE: PASS - unmodified ECC cluster elaborates on $(vsim -version 2>/dev/null | head -1)"
else
    echo "PROBE: vopt FAILED (rc=$vopt_rc) - see vopt.log; apply disable-ecc fallback per plan Step 3.4"
fi
exit "$vopt_rc"
