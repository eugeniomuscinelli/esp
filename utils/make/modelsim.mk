# Copyright (c) 2011-2024 Columbia University, System Level Design Group
# SPDX-License-Identifier: Apache-2.0


INCDIR_MODELSIM = $(foreach dir, $(INCDIR), +incdir+$(dir))

VCOMOPT +=
VCOMOPT += -suppress vcom-1491
VLOGOPT += -suppress 2275
VLOGOPT += -suppress 2583
VLOGOPT += -suppress 2892
ifneq ($(filter $(TECHLIB),$(FPGALIBS)),)
VLOGOPT += +define+XILINX_FPGA
endif
VLOGOPT += $(INCDIR_MODELSIM)

VSIMOPT += -suppress 3812
VSIMOPT += -suppress 2697
VSIMOPT += -suppress 8617
VSIMOPT += -suppress 151
VSIMOPT += -suppress 143
VSIMOPT += -suppress 8386
#VSIMOPT += -suppress 3584

ifneq ($(filter $(TECHLIB),$(FPGALIBS)),)
VSIMOPT += -L secureip_ver -L unisims_ver
endif
VSIMOPT += -uvmcontrol=disable -suppress 3009,2685,2718 -t fs
VSIMOPT += +notimingchecks
VSIMOPT += $(SIMTOP) $(EXTRA_SIMTOP)

VLIB = vlib
VCOM = vcom -quiet -93 $(VCOMOPT)
VLOG = vlog -sv -quiet $(VLOGOPT)
VSIM = VSIMOPT='$(VSIMOPT)' TECHLIB=$(TECHLIB) ESP_ROOT=$(ESP_ROOT) vsim $(VSIMOPT)


### PULP DEFS & INCLUDE DIRECTORIES ###

USE_PULP_FILELIST ?= 0    ##### COMMENT IF YOU WANT TO USE FILE BY FILE COMPILATION #####

PULP_DIR += $(ESP_ROOT)/accelerators/rtl/pulp_cluster_esp/.bender/git/checkouts/apb-4e7aa3f8a7b1b68f/include
PULP_DIR += $(ESP_ROOT)/accelerators/rtl/pulp_cluster_esp/.bender/git/checkouts/axi-e270de8338bba799/include
PULP_DIR += $(ESP_ROOT)/accelerators/rtl/pulp_cluster_esp/.bender/git/checkouts/cluster_interconnect-96546316444b5901/rtl/low_latency_interco
PULP_DIR += $(ESP_ROOT)/accelerators/rtl/pulp_cluster_esp/.bender/git/checkouts/cluster_interconnect-96546316444b5901/rtl/peripheral_interco
PULP_DIR += $(ESP_ROOT)/accelerators/rtl/pulp_cluster_esp/.bender/git/checkouts/cluster_peripherals-f275c871e6365834/event_unit/include
PULP_DIR += $(ESP_ROOT)/accelerators/rtl/pulp_cluster_esp/.bender/git/checkouts/common_cells-30347ea5f486aa0d/include
PULP_DIR += $(ESP_ROOT)/accelerators/rtl/pulp_cluster_esp/.bender/git/checkouts/cv32e40p-cd5a1b85b1da2f0e/bhv
PULP_DIR += $(ESP_ROOT)/accelerators/rtl/pulp_cluster_esp/.bender/git/checkouts/cv32e40p-cd5a1b85b1da2f0e/rtl/include
PULP_DIR += $(ESP_ROOT)/accelerators/rtl/pulp_cluster_esp/.bender/git/checkouts/event_unit_flex-63ab1d2cb73b994f/rtl
PULP_DIR += $(ESP_ROOT)/accelerators/rtl/pulp_cluster_esp/.bender/git/checkouts/hci-c7bfd3f79f665c2d/rtl/common
PULP_DIR += $(ESP_ROOT)/accelerators/rtl/pulp_cluster_esp/.bender/git/checkouts/hwpe-ctrl-332abdaed7127058/rtl
PULP_DIR += $(ESP_ROOT)/accelerators/rtl/pulp_cluster_esp/.bender/git/checkouts/hwpe-stream-827cb06c6f52871f/rtl
PULP_DIR += $(ESP_ROOT)/accelerators/rtl/pulp_cluster_esp/.bender/git/checkouts/ibex-89acaeb83a75b808/rtl
PULP_DIR += $(ESP_ROOT)/accelerators/rtl/pulp_cluster_esp/.bender/git/checkouts/ibex-89acaeb83a75b808/vendor/lowrisc_ip/ip/prim/rtl
PULP_DIR += $(ESP_ROOT)/accelerators/rtl/pulp_cluster_esp/.bender/git/checkouts/idma-ae67a849b031601a/src/include
PULP_DIR += $(ESP_ROOT)/accelerators/rtl/pulp_cluster_esp/.bender/git/checkouts/idma-ae67a849b031601a/test
PULP_DIR += $(ESP_ROOT)/accelerators/rtl/pulp_cluster_esp/.bender/git/checkouts/mchan-a11d5d570094a5a6/rtl/include
PULP_DIR += $(ESP_ROOT)/accelerators/rtl/pulp_cluster_esp/.bender/git/checkouts/pulp_cluster-dc712f19ddf3a3f8/include
PULP_DIR += $(ESP_ROOT)/accelerators/rtl/pulp_cluster_esp/.bender/git/checkouts/redundancy_cells-31d31bf617698052/rtl/ODRG_unit
PULP_DIR += $(ESP_ROOT)/accelerators/rtl/pulp_cluster_esp/.bender/git/checkouts/redundancy_cells-31d31bf617698052/rtl/pulpissimo_tcls
PULP_DIR += $(ESP_ROOT)/accelerators/rtl/pulp_cluster_esp/.bender/git/checkouts/register_interface-ace22e9551edd94b/include
PULP_DIR += $(ESP_ROOT)/accelerators/rtl/pulp_cluster_esp/.bender/git/checkouts/riscv-06ab84b364571676/rtl/include
PULP_DIR += $(ESP_ROOT)/accelerators/rtl/pulp_cluster_esp/.bender/git/checkouts/zeroriscy-800654d35f8c7c99/include/
PULP_DIR += $(ESP_ROOT)/accelerators/rtl/pulp_cluster_esp/.bender/git/checkouts/pulp_cluster-dc712f19ddf3a3f8/packages
INCDIR_PULP = $(foreach dir, $(PULP_DIR), +incdir+$(dir))


### PULP VLOG ###

VLOGOPT_PULP += -suppress 2275
VLOGOPT_PULP += -suppress 2583
VLOGOPT_PULP += -suppress 2892
VLOGOPT_PULP += -suppress 13314
VLOGOPT_PULP += -suppress 13233

VLOG_PULP = vlog -sv -quiet 


### PULP SRCS & OPT ###

#PULP_TARGS += +define+rtl
#PULP_TARGS += +define+test
#PULP_TARGS += +define+mchan
#PULP_TARGS += +define+cluster_standalone
#PULP_TARGS += +define+scm_use_fpga_scm
#PULP_TARGS += +define+cv32e40p_use_ff_regfile
#PULP_TARGS += +define+simulation

PULP_TARGS += +define+CV32E40P_TRACE_EXECUTION
PULP_TARGS += +define+RVFI=true
PULP_TARGS += +define+TARGET_SIMULATION
PULP_TARGS += +define+TARGET_CLUSTER_STANDALONE
PULP_TARGS += +define+TARGET_CV32E40P_USE_FF_REGFILE
PULP_TARGS += +define+TARGET_FLIST
PULP_TARGS += +define+TARGET_MCHAN
PULP_TARGS += +define+TARGET_RTL
PULP_TARGS += +define+TARGET_SCM_USE_FPGA_SCM
PULP_TARGS += +define+TARGET_TEST

PULP_DEFS += +define+FEATURE_ICACHE_STAT
PULP_DEFS += +define+PRIVATE_ICACHE
PULP_DEFS += +define+HIERARCHY_ICACHE_32BIT
PULP_DEFS += +define+ICAHE_USE_FF
PULP_DEFS += +define+NO_FPU
PULP_DEFS += +define+TRACE_EXECUTION
PULP_DEFS += +define+CLUSTER_ALIAS
PULP_DEFS += +define+USE_PULP_PARAMETERS
PULP_DEFS += +define+SNITCH_ICACHE

PULP_FILELIST = $(ESP_ROOT)/accelerators/rtl/pulp_cluster_esp/sim/sim.f
PULP_SRCS += $(shell grep -E "\.sv$$" $(PULP_FILELIST)) #$(foreach f, $(shell cat $(PULP_FILELIST)), $(if $(findstring .sv, $(f)), $(f)))


### Xilinx Simulation libs targets ###
$(ESP_ROOT)/.cache/modelsim/xilinx_lib:
	$(QUIET_MKDIR)mkdir -p $@
	@echo "compile_simlib -directory xilinx_lib -simulator modelsim -library all" > $@/simlib.tcl; \
	cd $(ESP_ROOT)/.cache/modelsim; \
	if ! vivado $(VIVADO_BATCH_OPT) -source xilinx_lib/simlib.tcl; then \
		echo "$(SPACES)ERROR: Xilinx library compilation failed!"; rm -rf xilinx_lib modelsim.ini; exit 1; \
	fi; \
	lib_path=$$(cat modelsim.ini | grep secureip | cut -d " " -f 3); \
	sed -i "/secureip =/a secureip_ver = "$$lib_path"" modelsim.ini; \
	sed -i 's/; Show_source = 1/Show_source = 1/g' modelsim.ini; \
	sed -i 's/; Show_Warning3 = 0/Show_Warning3 = 0/g' modelsim.ini; \
	sed -i 's/; Show_Warning5 = 0/Show_Warning5 = 0/g' modelsim.ini; \
	sed -i 's/; StdArithNoWarnings = 1/StdArithNoWarnings = 1/g' modelsim.ini; \
	sed -i 's/; NumericStdNoWarnings = 1/NumericStdNoWarnings = 1/g' modelsim.ini; \
	sed -i 's/VoptFlow = 1/VoptFlow = 0/g' modelsim.ini; \
	sed -i '/suppress = [0-9]\+/d' modelsim.ini; \
	sed -i '/\[msg_system\]/a suppress = 8780,8891,1491,12110\nwarning = 8891' modelsim.ini; \
	cd ../;

modelsim/modelsim.ini: $(ESP_ROOT)/.cache/modelsim/xilinx_lib
	$(QUIET_MAKE)mkdir -p modelsim
	@cp $(ESP_ROOT)/.cache/modelsim/modelsim.ini $@


### Compile simulation source files ###
# Note that vmake fails to find unisim.vcomponents, however produces the correct
# makefile for future compilation and all components are properly bound in simulation.
# Please keep 2> /dev/null until the bug is fixed with a newer Modelsim release.
modelsim/vsim.mk: modelsim/modelsim.ini $(RTL_CFG_BUILD)/check_all_srcs.old $(PKG_LIST)

#ifdef USE_PULP_FILELIST 
#	@cd modelsim; \
#	if ! test -e pulp_cluster_lib; then \
#		vlib -type directory pulp_cluster_lib; \
#		$(SPACING)vmap pulp_cluster_lib pulp_cluster_lib; \
#	fi; \
#	echo $(SPACES)"### Compile PULP_CLUSTER systemverilog files from PULP_FILELIST ###"; \
#	$(VLOG_PULP) -work pulp_cluster_lib -f $(PULP_FILELIST) $(VLOGOPT_PULP) || exit;
#else
#	@cd modelsim || (echo "Error: modelsim directory does not exist"; exit 1)
#	@if ! test -e modelsim/pulp_cluster_lib; then \
#		( \
#			cd modelsim && \
#			vlib -type directory pulp_cluster_lib || (echo "Error: Failed to create library"; exit 1); \
#			vmap pulp_cluster_lib pulp_cluster_lib || (echo "Error: Failed to map library"; exit 1) \
#		); \
#	fi
#	echo "### Compile PULP source files ###"
#	@for rtl in $(PULP_SRCS); do \
#		echo "Compiling: $$rtl"; \
#		echo "$(VLOG_PULP) -work pulp_cluster_lib $$rtl"; \
#		echo "Included PULP directories:"; \
#		echo $(INCDIR_PULP) | tr ' ' '\n' | grep "^+incdir" | sed 's/^/    /'; \
#		( \
#			cd modelsim && \
#			$(VLOG_PULP) -work pulp_cluster_lib $(PULP_DEFS) $(PULP_TARGS) $$rtl $(VLOGOPT_PULP) $(INCDIR_PULP) || exit 1 \
#		); \
#	done
#
#endif
	@cd modelsim; \
	if ! test -e profpga; then \
		vlib -type directory profpga; \
		$(SPACING)vmap profpga profpga; \
	fi;
ifneq ($(findstring profpga, $(BOARD)),)
	@cd modelsim; \
	echo $(SPACES)"### Compile proFPGA source files ###"; \
	for vhd in $(VHDL_PROFPGA); do \
		rtl=$(PROFPGA)/hdl/$$vhd; \
		echo $(SPACES)"$(VCOM) -work profpga $$rtl"; \
		$(VCOM) -work profpga $$rtl || exit; \
	done; \
	for ver in $(VERILOG_PROFPGA); do \
		rtl=$(PROFPGA)/hdl/$$ver; \
		echo $(SPACES)"$(VLOG) -work profpga"; \
		$(VLOG) -work profpga $$rtl || exit; \
	done;
endif
	@cd modelsim; \
	if ! test -e work; then \
		vlib -type directory work; \
		$(SPACING)vmap work work; \
	fi; \
	echo $(SPACES)"### Compile VHDL packages ###"; \
	for rtl in $(SIM_VHDL_PKGS); do \
		echo $(SPACES)"$(VCOM) -work work $$rtl"; \
		$(VCOM) -work work $$rtl || exit; \
	done; \
	echo $(SPACES)"### Compile VHDL source files ###"; \
		for rtl in $(SIM_VHDL_SRCS); do \
			echo $(SPACES)"$(VCOM) -work work $$rtl"; \
			$(VCOM) -work work $$rtl || exit; \
		done; \
	echo $(SPACES)"### Compile Verilog source files ###"; \
		for rtl in $(SIM_VLOG_SRCS); do \
			echo $(SPACES)"$(VLOG) -work work $$rtl "; \
			$(VLOG) -work work $$rtl || exit; \
		done;
		
ifneq ("$(wildcard $(ESP_ROOT)/rtl/peripherals/bsg/.git)", "")
	@echo $(SPACES)"### Compile BSG Verilog source files ###";
	@$(MAKE) bsg-sim-compile
endif
	@cd modelsim; \
	echo $(SPACES)"vmake > vsim.mk"; \
	vmake 2> /dev/null > vsim.mk; \
	cd ../;

sim-compile: socketgen check_all_srcs modelsim/vsim.mk soft iolink-txt-files
	@for dat in $(DAT_SRCS); do \
		cp $$dat modelsim; \
	done;
	$(QUIET_MAKE)make -C modelsim -f vsim.mk
	@cd modelsim; \
	rm -f prom.srec ram.srec; \
	ln -s $(SOFT_BUILD)/prom.srec; \
	ln -s $(SOFT_BUILD)/ram.srec;

sim: sim-compile
	$(QUIET_RUN)cd modelsim; \
	if test -e $(DESIGN_PATH)/vsim.tcl; then \
		$(VSIM) $(PULP_TARGS) $(PULP_DEFS) -c -L pulp_cluster_lib -do "do $(DESIGN_PATH)/vsim.tcl"; \
	else \
		$(VSIM) $(PULP_TARGS) $(PULP_DEFS) -c -L pulp_cluster_lib; \
	fi;

sim-gui: sim-compile
	$(QUIET_RUN)cd modelsim; \
	if test -e $(DESIGN_PATH)/vsim.tcl; then \
		$(VSIM) $(PULP_TARGS) $(PULP_DEFS) -L pulp_cluster_lib -do "do $(DESIGN_PATH)/vsim.tcl"; \
	else \
		$(VSIM) $(PULP_TARGS) $(PULP_DEFS) -L pulp_cluster_lib; \
	fi;

sim-clean:
	$(QUIET_CLEAN)rm -rf transcript *.wlf

sim-distclean: sim-clean
	$(QUIET_CLEAN)rm -rf modelsim

.PHONY: sim sim-gui sim-compile sim-clean sim-distclean



### JTAG trace-based simulation (Modelsim only)
JTAG_TEST_SCRIPTS_DIR = $(ESP_ROOT)/utils/scripts/jtag_test
JTAG_TEST_TILE ?= 0

jtag-trace: sim-compile
	$(QUIET_RUN)cd modelsim; \
	mkdir -p jtag; \
	if test -e $(DESIGN_PATH)/vsim.tcl; then \
		VSIMOPT='$(VSIMOPT) -do "do $(JTAG_TEST_SCRIPTS_DIR)/jtag_test_gettrace.tcl"' TECHLIB=$(TECHLIB) ESP_ROOT=$(ESP_ROOT) vsim $(VSIMOPT) -do "do $(DESIGN_PATH)/vsim.tcl"; \
	else \
		$(VSIM) -do "do $(JTAG_TEST_SCRIPTS_DIR)/jtag_test_gettrace.tcl"; \
	fi; \
	cd jtag; \
	$(JTAG_TEST_SCRIPTS_DIR)/jtag_test_format.sh; \
	LD_LIBRARY_PATH="" $(JTAG_TEST_SCRIPTS_DIR)/jtag_test_stim.py $(JTAG_TEST_TILE)

sim-jtag: sim-compile
	$(QUIET_RUN)if test -e $(DESIGN_PATH)/modelsim/jtag/stim.txt; then \
	cd modelsim; \
		if test -e $(DESIGN_PATH)/vsim.tcl; then \
			VSIMOPT='$(VSIMOPT) -g JTAG_TRACE=$(JTAG_TEST_TILE)' TECHLIB=$(TECHLIB) ESP_ROOT=$(ESP_ROOT) vsim $(VSIMOPT) -do "do $(DESIGN_PATH)/vsim.tcl"; \
		else \
			$(VSIM) -g JTAG_TRACE=$(JTAG_TEST_TILE); \
		fi; \
	else \
		echo "Run make jtag-trace to generate stimulus file"; \
	fi;

jtag-clean:
	$(QUIET_CLEAN)$(RM) \
		modelsim/jtag/stim*_*.txt \
		modelsim/jtag/*.lst

jtag-distclean: jtag-clean
	$(QUIET_CLEAN)$(RM) modelsim/jtag

.PHONY: jtag-trace jtag-trace-pretty jtag-stim jtag-clean jtag-distclean
