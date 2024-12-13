BENDER := ./bender
OUTPUT_DIR := sim
OUTPUT_FILE := $(OUTPUT_DIR)/sim.f

bender_targs += -t rtl
bender_targs += -t test
bender_targs += -t mchan
bender_targs += -t cluster_standalone
bender_targs += -t scm_use_fpga_scm
bender_targs += -t cv32e40p_use_ff_regfile
bender_targs += -t simulation

bender_defs += -D FEATURE_ICACHE_STAT
bender_defs += -D PRIVATE_ICACHE
bender_defs += -D HIERARCHY_ICACHE_32BIT
bender_defs += -D ICAHE_USE_FF
bender_defs += -D NO_FPU
bender_defs += -D TRACE_EXECUTION
bender_defs += -D CLUSTER_ALIAS
bender_defs += -D USE_PULP_PARAMETERS
bender_defs += -D SNITCH_ICACHE


filelist: $(OUTPUT_DIR)
	$(BENDER) script flist-plus $(bender_defs) $(bender_targs) > $(OUTPUT_FILE)
	@echo "Filelist generated at $(OUTPUT_FILE)"

$(OUTPUT_DIR):
	mkdir -p $(OUTPUT_DIR)


clean:
	rm -rf $(OUTPUT_FILE)


.PHONY: all filelist cleanq