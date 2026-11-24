#!/usr/bin/env bash
# Copyright (c) 2011-2026 Columbia University, System Level Design Group
# SPDX-License-Identifier: Apache-2.0
#
# Standalone regression of the memory-tile proxy (noc2aximst_tb.sv).
# It compiles into a temporary directory and does not touch any SoC folder.
#
#   bash rtl/sockets/proxy/tests/run_noc2aximst.sh            # all configurations
#   MEM_AXIDW=128 CONFIGS="acc" SEEDS="1 2 3" bash .../run_noc2aximst.sh
#
# Environment:
#   ESP_GLOBAL_SV  generated constants package to start from
#                  (default: socs/profpga-xcvu19p/socgen/esp/esp_global_sv.sv)
#   MEM_AXIDW      widths to test, default "64 128"; the package's MEM_AXIDW
#                  line is rewritten for each
#   CONFIGS        acc (CPU + accelerator DMA instance, multi-outstanding reads on),
#                  acc_classic (same, multi-outstanding reads off),
#                  eth (debug-link / Ethernet instance), fast (acc, no back-pressure)
#   SEEDS          default "1 2"
#   REF_SV         optional: an older noc2aximst.sv. With MEM_AXIDW=64 it is
#                  compiled as noc2aximst_ref and compared cycle by cycle.
#   MIG_AXI_DIR    optional: the rtl/axi directory of a generated Xilinx DDR4 MIG
#                  (ddr4_v2_2). The proxy then talks to the MIG's own AXI front
#                  end, configured for each MEM_AXIDW, in front of a model of
#                  the MIG native interface. Needs the Xilinx simulation
#                  libraries: MODELSIM_INI (default <repo>/.cache/modelsim/modelsim.ini)
#                  and XILINX_VIVADO for glbl.v.
#   VSIM_BIN       directory of vlog/vsim (default: from PATH)
# Success prints NOC2AXIMST_TB_PASS for every run and exits 0.
set -euo pipefail
test_dir=$(cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(cd -- "$test_dir/../../../.." && pwd)
global_sv=${ESP_GLOBAL_SV:-$repo_root/socs/profpga-xcvu19p/socgen/esp/esp_global_sv.sv}
widths=${MEM_AXIDW:-"64 128"}
configs=${CONFIGS:-"acc acc_classic eth fast"}
seeds=${SEEDS:-"1 2"}
bin=${VSIM_BIN:+$VSIM_BIN/}
work=$(mktemp -d "${TMPDIR:-/tmp}/esp-noc2aximst-tb-XXXXXX")
echo "noc2aximst testbench work directory: $work"
cd "$work"
status=0
for w in $widths; do
  d=w$w; mkdir -p "$d"; cd "$d"
  sed -E "s/(localparam integer MEM_AXIDW[[:space:]]*=)[[:space:]]*[0-9]+;/\1 $w;/" "$global_sv" > esp_global_sv.sv
  grep -q "MEM_AXIDW" esp_global_sv.sv || { echo "ERROR: $global_sv has no MEM_AXIDW"; exit 1; }
  defs="+define+ESP_SVA"
  srcs=(esp_global_sv.sv "$repo_root/rtl/sockets/proxy/noc2aximst-pkg.sv" "$repo_root/rtl/sockets/proxy/noc2aximst.sv")
  if [ -n "${REF_SV:-}" ] && [ "$w" = 64 ]; then
    sed -E 's/^module noc2aximst\b/module noc2aximst_ref/' "$REF_SV" > noc2aximst_ref.sv
    srcs+=(noc2aximst_ref.sv); defs="$defs +define+WITH_REF"
  fi
  ini=(); tops=(work.noc2aximst_tb)
  if [ -n "${MIG_AXI_DIR:-}" ]; then
    ini=(-modelsimini "${MODELSIM_INI:-$repo_root/.cache/modelsim/modelsim.ini}")
    defs="$defs +define+WITH_MIG_AXI"
    srcs+=("$MIG_AXI_DIR"/*.sv "$XILINX_VIVADO/data/verilog/src/glbl.v")
    tops+=(work.glbl); VSIM_EXTRA="${VSIM_EXTRA:-} -L unisims_ver"
  fi
  "${bin}vlib" work > /dev/null
  "${bin}vlog" "${ini[@]}" -sv -quiet $defs "${srcs[@]}" "$test_dir/noc2aximst_tb.sv" > compile.log 2>&1 || { cat compile.log; exit 1; }
  for c in $configs; do
    case $c in
      acc)         g="-gMULTI_OT=1 -gETH=0 -gSTALLS=1" ;;
      acc_classic) g="-gMULTI_OT=0 -gETH=0 -gSTALLS=1" ;;
      eth)         g="-gMULTI_OT=1 -gETH=1 -gSTALLS=1" ;;
      fast)        g="-gMULTI_OT=1 -gETH=0 -gSTALLS=0" ;;
      *) echo "unknown configuration $c"; exit 1 ;;
    esac
    for s in $seeds; do
      log=sim_${c}_s$s.log
      "${bin}vsim" "${ini[@]}" -c -quiet -sv_seed "$s" $g ${VSIM_EXTRA:-} "${tops[@]}" -do "run -all; quit -f" > "$log" 2>&1 || true
      if grep -q NOC2AXIMST_TB_PASS "$log" && ! grep -q -E 'TB_ERROR|\*\* Error|\*\* Fatal' "$log"; then
        printf 'PASS  MEM_AXIDW=%-3s %-11s seed %s  %s\n' "$w" "$c" "$s" "$(grep -m1 'long aligned read' "$log" | sed 's/^ *//' || true)"
      else
        printf 'FAIL  MEM_AXIDW=%-3s %-11s seed %s  (%s/%s/%s)\n' "$w" "$c" "$s" "$work" "$d" "$log"
        grep -m5 -E 'TB_ERROR|\*\* Error|\*\* Fatal|TB_FAIL' "$log" || tail -5 "$log"
        status=1
      fi
    done
  done
  cd ..
done
exit $status
