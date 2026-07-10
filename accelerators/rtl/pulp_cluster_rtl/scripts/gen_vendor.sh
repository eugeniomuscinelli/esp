#!/bin/bash
# Regenerate the vendored PULP-cluster source tree and the ESP per-accelerator
# filelist (pulp_cluster_rtl.sverilog + pulp_cluster_rtl.defines).
#
# Mechanism (see pulp_esp_integration_report.md, Step 3):
#   1. clone pulp-platform/pulp_cluster at the pinned revision into vendor/pulp_cluster
#   2. `bender checkout` inside it -> its committed Bender.lock pins every one of the
#      34 dependencies to an exact commit (this is the upstream-blessed resolution;
#      we deliberately do NOT re-resolve)
#   3. flatten .bender/git/checkouts/<pkg>-<hash>/ -> vendor/<pkg>/ (machine-independent paths)
#   4. `bender script flist-plus` with the known-good target set -> split into
#      pulp_cluster_rtl.sverilog (paths relative to vendor/, +incdir+ lines kept)
#      and pulp_cluster_rtl.defines (+define+ lines; consumed via ACC_MODELSIM_DEFS)
#   5. append the simulation-only mock UART sources (printf sink) explicitly
#
# Everything under vendor/ and scripts/bin/ is regenerable and gitignored.
# No absolute paths and no machine-specific data end up in committed files.

set -euo pipefail

ACC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ACC_DIR/vendor"
BIN="$ACC_DIR/scripts/bin"

PULP_CLUSTER_URL="https://github.com/pulp-platform/pulp_cluster.git"
PULP_CLUSTER_REV="07988cd01c359a81804820135927bc04da3c25cd"  # branch astral, "fix Bender.lock"
BENDER_VERSION="0.24.0"                                      # same version pulp_cluster's Makefile bootstraps

# Known-good bender target set (mirrors pulp_cluster/Makefile bender_targs minus
# -t test: instead of pulling every dependency's testbenches we append only the
# two mock-UART files we actually need, see step 5).
BENDER_TARGS=(-t rtl -t mchan -t cluster_standalone -t scm_use_fpga_scm -t cv32e40p_use_ff_regfile -t cv32e40p_include_tracer -t simulation)
# Known-good define set (mirrors pulp_cluster/Makefile bender_defs).
BENDER_DEFS=(-D FEATURE_ICACHE_STAT -D PRIVATE_ICACHE -D HIERARCHY_ICACHE_32BIT -D ICAHE_USE_FF \
             -D NO_FPU -D TRACE_EXECUTION -D CLUSTER_ALIAS -D USE_PULP_PARAMETERS -D SNITCH_ICACHE)

# Files never wanted in the ESP accelerator library:
#  - iDMA testbenches (target-test leakage seen in the reference integration)
#  - deprecated common_cells pulp_sync (module name clash with tech-specific cells)
#  - the standalone cluster testbench and its DPI loader (ESP replaces them)
EXCLUDE_RE='(/iDMA/test/|/common_cells/src/deprecated/pulp_sync\.sv|/tb/pulp_cluster_tb\.sv|/tb/dpi/|elfloader)'

mkdir -p "$BIN" "$VENDOR"

# --- 1. bender ---------------------------------------------------------------
if ! "$BIN/bender" --version >/dev/null 2>&1; then
    echo ">> bootstrapping bender $BENDER_VERSION into scripts/bin"
    (cd "$BIN" && curl --proto '=https' --tlsv1.2 https://pulp-platform.github.io/bender/init -sSf \
        | sh -s -- "$BENDER_VERSION")
fi
BENDER="$BIN/bender"
"$BENDER" --version

# --- 2. pulp_cluster checkout ------------------------------------------------
if [ ! -d "$VENDOR/pulp_cluster/.git" ]; then
    echo ">> cloning pulp_cluster @ $PULP_CLUSTER_REV"
    git clone "$PULP_CLUSTER_URL" "$VENDOR/pulp_cluster"
fi
git -C "$VENDOR/pulp_cluster" checkout --quiet -f "$PULP_CLUSTER_REV"

# Local patches (each is upstream-candidate; see patches/*.patch headers and the
# integration report). Applied on a clean checkout, so re-runs are idempotent.
for p in "$ACC_DIR"/patches/*.patch; do
    [ -e "$p" ] || continue
    echo ">> applying $(basename "$p")"
    git -C "$VENDOR/pulp_cluster" apply "$p"
done

echo ">> bender checkout (obeys pulp_cluster's committed Bender.lock)"
(cd "$VENDOR/pulp_cluster" && "$BENDER" checkout >/dev/null)

# --- 3. flatten dependency checkouts into vendor/<pkg> ------------------------
echo ">> flattening .bender checkouts into vendor/"
CHECKOUTS="$VENDOR/pulp_cluster/.bender/git/checkouts"
for d in "$CHECKOUTS"/*/; do
    base="$(basename "$d")"
    pkg="${base%-*}"                       # strip trailing -<16-hex-hash>
    rm -rf "$VENDOR/$pkg"
    cp -a "$d" "$VENDOR/$pkg"
done

# --- 4. filelist -------------------------------------------------------------
echo ">> generating filelist (bender script flist-plus)"
RAW="$VENDOR/.flist_raw"
(cd "$VENDOR/pulp_cluster" && "$BENDER" script flist-plus "${BENDER_TARGS[@]}" "${BENDER_DEFS[@]}") > "$RAW"

SVLOG="$ACC_DIR/pulp_cluster_rtl.sverilog"
DEFS="$ACC_DIR/pulp_cluster_rtl.defines"

grep '^+define+' "$RAW" | sort -u > "$DEFS"

# Rewrite absolute paths to vendor/-relative ones (ESP's modelsim.mk/vivado.mk
# rebase relative entries onto accelerators/rtl/<acc>/vendor/):
#   .../vendor/pulp_cluster/.bender/git/checkouts/<pkg>-<hash>/  ->  <pkg>/
#   .../vendor/pulp_cluster/                                     ->  pulp_cluster/
grep -v '^+define+' "$RAW" \
  | sed -E "s#^\+incdir\+#+incdir+#; \
            s#$CHECKOUTS/([^/]+)-[0-9a-f]{16}/#\1/#g; \
            s#$VENDOR/pulp_cluster/#pulp_cluster/#g" \
  | grep -Ev "$EXCLUDE_RE" \
  | grep -v '^[[:space:]]*$' > "$SVLOG"

# --- 5. simulation-only printf sink (mock UART) -------------------------------
cat >> "$SVLOG" <<'EOF'
# simulation-only mock UART (printf sink), appended explicitly instead of -t test
pulp_cluster/tb/mock_uart.sv
pulp_cluster/tb/mock_uart_axi.sv
EOF

# --- sanity: every referenced file must exist under vendor/ -------------------
echo ">> verifying filelist"
missing=0
while IFS= read -r line; do
    case "$line" in
        \#*|"") continue ;;
        +incdir+*) f="${line#+incdir+}" ;;
        *) f="$line" ;;
    esac
    case "$f" in /*) continue ;; esac   # absolute entries (none expected)
    if [ ! -e "$VENDOR/$f" ]; then echo "MISSING: $f"; missing=1; fi
done < "$SVLOG"
[ "$missing" -eq 0 ] || { echo "ERROR: filelist references missing files"; exit 1; }

echo ">> OK: $(grep -cv '^\s*$\|^#' "$SVLOG") filelist entries, $(wc -l < "$DEFS") defines"
