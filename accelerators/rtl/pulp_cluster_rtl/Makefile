# Convenience targets for the PULP cluster accelerator (not used by ESP's flow;
# ESP drives this accelerator through the generic RTL_ACC targets in
# utils/make/accelerators.mk and the per-accelerator library rules in
# utils/make/modelsim.mk / vivado.mk).

.PHONY: vendor check bridge-tbs ecc-probe rung2-header

# fetch/regenerate the vendored cluster tree + filelist (see scripts/gen_vendor.sh)
vendor:
	./scripts/gen_vendor.sh

# four-constant consistency check (risk R7); set PULP_RUNTIME to also check link.ld
check:
	./scripts/check_constants.sh

# directed bridge-module testbenches (requires questa on PATH)
bridge-tbs:
	./verif/run_bridge_tbs.sh

# ECC elaboration probe (requires questa on PATH + vendor tree)
ecc-probe:
	./verif/run_ecc_probe.sh

# regenerate the toolchain-free rung-2 program image
rung2-header:
	cd sw/baremetal && python3 gen_rung2_stimuli.py > rung2_smoke.h
