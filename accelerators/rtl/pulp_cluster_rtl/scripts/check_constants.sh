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

# Optional pulp-sdk leg. Same idea as the pulp-runtime leg above, for the
# retargeted PulpOS 2 chip target (pulp_esp). Checked only when PULP_SDK points
# at a pulp-sdk checkout. Three constants, because the SDK derives more of the
# map from the linker script than pulp-runtime does:
#   a. L2 ORIGIN            vs wrapper L2BaseAddr
#   b. L1 ORIGIN            vs wrapper ClustBase
#   c. crt0 PE sync flag    vs ORIGIN(L1) + LENGTH(L1) - 0xC  (TCDM top - 0x10)
# (c) is the one most likely to rot: it is an assembly literal in a file shared
# with every other chip, so a change to the TCDM size in link.ld would not
# otherwise be reflected there, and the PEs would spin forever on a flag core 0
# never sets.
if [ -n "${PULP_SDK:-}" ]; then
    sdk_ld="$PULP_SDK/rtos/pulpos/pulp/kernel/chips/pulp_esp/link.ld"
    sdk_crt0="$PULP_SDK/rtos/pulpos/common/kernel/crt0.S"
    if [ -f "$sdk_ld" ]; then
        l2org=$(grep -oE "L2 *: *ORIGIN *= *0x[0-9a-fA-F]+" "$sdk_ld" | grep -oE "0x[0-9a-fA-F]+" | sed 's/0x//')
        l2org=$(norm "$l2org")
        if [ "$l2org" != "$wrap_base" ]; then
            echo "FAIL: pulp-sdk link.ld L2 ORIGIN 0x$l2org != 0x$wrap_base"; fail=1
        else
            echo "pulp-sdk link.ld L2      : 0x$l2org OK"
        fi

        clust_base=$(grep -oE "ClustBase *= *'h[0-9a-fA-F_]+" "$WRAPPER" | grep -oE "'h[0-9a-fA-F_]+" | head -1 | sed "s/'h//")
        clust_base=$(norm "$clust_base")
        l1org_raw=$(grep -oE "^ *L1 *: *ORIGIN *= *0x[0-9a-fA-F]+" "$sdk_ld" | grep -oE "0x[0-9a-fA-F]+" | head -1)
        l1len_raw=$(grep -oE "^ *L1 *: *ORIGIN *= *0x[0-9a-fA-F]+, *LENGTH *= *0x[0-9a-fA-F]+" "$sdk_ld" | grep -oE "0x[0-9a-fA-F]+" | tail -1)
        l1org=$(norm "$(echo "$l1org_raw" | sed 's/0x//')")
        if [ -n "$clust_base" ] && [ "$l1org" != "$clust_base" ]; then
            echo "FAIL: pulp-sdk link.ld L1 ORIGIN 0x$l1org != wrapper ClustBase 0x$clust_base"; fail=1
        else
            echo "pulp-sdk link.ld L1      : 0x$l1org OK"
        fi

        if [ -n "$l1org_raw" ] && [ -n "$l1len_raw" ]; then
            expect_flag=$(printf '%X' $(( l1org_raw + l1len_raw - 0xC )))
            crt0_flag=$(grep -oE "define +POS_PE_SYNC_FLAG +0x[0-9a-fA-F]+" "$sdk_crt0" 2>/dev/null \
                        | grep -oE "0x[0-9a-fA-F]+" | sed 's/0x//' | while read -r v; do norm "$v"; done \
                        | grep -x "$expect_flag" | head -1)
            if [ -n "$crt0_flag" ]; then
                echo "pulp-sdk crt0 sync flag  : 0x$expect_flag OK"
            else
                echo "FAIL: no POS_PE_SYNC_FLAG = 0x$expect_flag in $sdk_crt0 (TCDM top - 0x10)"; fail=1
            fi
        fi
    else
        echo "WARN: PULP_SDK set but $sdk_ld not found"
    fi
else
    echo "note: PULP_SDK not set - pulp-sdk leg skipped (only needed when compiling cluster programs with pulp-sdk)"
fi

if [ $fail -eq 0 ]; then echo "CHECK PASS: all constants consistent"; else echo "CHECK FAIL"; fi
exit $fail
