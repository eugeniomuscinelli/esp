#!/bin/bash
# Four-constant consistency check (plan risk R7).
#
# The cluster-visible L2 window base must be identical in four places or the
# program image the host writes and the addresses the cluster fetches silently
# diverge:
#   1. wrapper localparam L2BaseAddr   (hw/src/.../pulp_cluster_rtl_basic_dma64.sv)
#      - feeds the xbar rule, the translator BASE_ADDR and cluster_control
#        L2_BASE_ADDR, so inside the RTL it is single-sourced by construction;
#        this script guards the RTL<->software contract;
#   2. every program-image header's BASE_ADDRESS (sw/baremetal/*.h);
#   3. the default boot offset: wrapper BootAddr = L2BaseAddr + 0x8080 vs. the
#      host app's BOOT_OFFSET;
#   4. (optional) the pulp-runtime linker script L2 ORIGIN - checked only when
#      PULP_RUNTIME points at a pulp-runtime checkout (needed when compiling new
#      cluster programs; prebuilt headers embed their link base already).
set -u

ACC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="$ACC_DIR/hw/src/pulp_cluster_rtl_basic_dma64/pulp_cluster_rtl_basic_dma64.sv"
APP="$ACC_DIR/sw/baremetal/pulp_cluster.c"
fail=0

norm() { echo "$1" | tr -d "_" | tr 'a-f' 'A-F'; }

wrap_base_raw=$(grep -oE "L2BaseAddr *= *'h[0-9a-fA-F_]+" "$WRAPPER" | grep -oE "'h[0-9a-fA-F_]+" | head -1 | sed "s/'h//")
wrap_base=$(norm "$wrap_base_raw")
[ -n "$wrap_base" ] || { echo "FAIL: cannot extract L2BaseAddr from wrapper"; exit 1; }
echo "wrapper L2BaseAddr       : 0x$wrap_base"

wrap_boot=$(grep -oE "BootAddr *= *L2BaseAddr *\+ *'h[0-9a-fA-F_]+" "$WRAPPER" | grep -oE "\+ *'h[0-9a-fA-F_]+" | sed "s/[+ ']//g;s/^h//")
wrap_boot=$(norm "$wrap_boot")
echo "wrapper boot offset      : 0x$wrap_boot"

app_boot=$(grep -oE "#define BOOT_OFFSET 0x[0-9a-fA-F]+" "$APP" | grep -oE "0x[0-9a-fA-F]+" | sed 's/0x//')
app_boot=$(norm "$app_boot")
echo "host app BOOT_OFFSET     : 0x$app_boot"
if [ "$(norm "$wrap_boot")" != "$app_boot" ]; then
    echo "FAIL: wrapper boot offset != host BOOT_OFFSET"; fail=1
fi

for h in "$ACC_DIR"/sw/baremetal/*.h; do
    hb=$(grep -oE "#define BASE_ADDRESS 0x[0-9a-fA-F]+" "$h" | grep -oE "0x[0-9a-fA-F]+" | sed 's/0x//')
    [ -n "$hb" ] || continue
    hb=$(norm "$hb")
    if [ "$hb" != "$wrap_base" ]; then
        echo "FAIL: $(basename "$h") BASE_ADDRESS 0x$hb != wrapper L2BaseAddr 0x$wrap_base"
        fail=1
    else
        echo "header $(basename "$h") : 0x$hb OK"
    fi
done

if [ -n "${PULP_RUNTIME:-}" ]; then
    ld="$PULP_RUNTIME/kernel/chips/astral-cluster/link.ld"
    if [ -f "$ld" ]; then
        org=$(grep -oE "L2 *: *ORIGIN *= *0x[0-9a-fA-F]+" "$ld" | grep -oE "0x[0-9a-fA-F]+" | sed 's/0x//')
        org=$(norm "$org")
        if [ "$org" != "$wrap_base" ]; then
            echo "FAIL: pulp-runtime link.ld L2 ORIGIN 0x$org != 0x$wrap_base"; fail=1
        else
            echo "pulp-runtime link.ld     : 0x$org OK"
        fi
    else
        echo "WARN: PULP_RUNTIME set but $ld not found"
    fi
else
    echo "note: PULP_RUNTIME not set - linker-script leg skipped (only needed when compiling new cluster programs)"
fi

if [ $fail -eq 0 ]; then echo "CHECK PASS: all constants consistent"; else echo "CHECK FAIL"; fi
exit $fail
