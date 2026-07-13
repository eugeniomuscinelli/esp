# Copyright (c) 2011-2026 Columbia University, System Level Design Group
# SPDX-License-Identifier: Apache-2.0
##########################
### ESP Local Makefile ###
##########################

all: help

### Global design variables ###
DESIGN_PATH = $(PWD)
ESP_ROOT = $(realpath ../../)
TECHLIB  = virtex7
BOARD    = xilinx-vc707-xc7vx485t
DESIGN   = esp-$(BOARD)
SMP = 0
BASE_FREQ_MHZ ?= 50
LEON3_STACK ?= 0x5bfffff0
USE_OPENSBI ?= 1

### Design top level and testbench ###
TOP    = top
SIMTOP = testbench


### Modelsim Simulation Options ###

# Compile flags
VCOMOPT +=
VLOGOPT +=

# PULP cluster accelerator library hooks (see
# accelerators/rtl/pulp_cluster_rtl/pulp_esp_integration_report.md, Step 5):
# the +define+ set is single-sourced from the Bender-generated defines file;
# the extra vlog options compensate Questa 2022.3 strictness on PULP sources.
ACC_MODELSIM_DEFS   := $(shell cat $(ESP_ROOT)/accelerators/rtl/pulp_cluster_rtl/pulp_cluster_rtl.defines 2>/dev/null)
ACC_MODELSIM_VLOGOPT := -suppress 2986 -suppress 2577 -svinputport=relaxed
# vsim-3837 ("written by more than one continuous assignment") fires on the HCI
# interconnect's interface-member assigns; upstream pulp_cluster's own run flow
# tolerates this via `vsim +permissive` (pulp_cluster/Makefile run target). The
# narrow suppression is preferred over -permissive.
VSIMOPT += -suppress 3837

XCOMOPT +=
XLOGOPT +=

VSIMOPT +=


### Additional design files ###
TOP_VHDL_RTL_PKGS +=
TOP_VHDL_RTL_SRCS +=
TOP_VLOG_RTL_SRCS +=
TOP_VHDL_SIM_PKGS +=
TOP_VHDL_SIM_SRCS +=
TOP_VLOG_SIM_SRCS +=


### Xilinx Vivado hw_server ###
FPGA_HOST ?= localhost
XIL_HW_SERVER_PORT ?= 3121


### Network configuration ###

# IP address or host name of the host connected to the FPGA
UART_IP ?=
UART_PORT ?=

# SSH IP address or host name of the ESP Linux instance or gateway
SSH_IP ?=
SSH_PORT ?= 22

# ESPLink IP address or gateway (DO NOT USE HOST NAME)
ESPLINK_IP ?=
ESPLINK_PORT ?= 46392

# MAC address for Linux if using IP address reservation (e.g. 00aabb33cc77)
# LINUX_MAC ?=


### Include global Makefile ###
include $(ESP_ROOT)/utils/Makefile
