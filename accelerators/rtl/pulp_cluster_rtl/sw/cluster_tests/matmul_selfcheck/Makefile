# Self-checking matmul cluster test (Phase 1). Build per report section 10.4:
#   source /opt/cad/scripts/tools_env.sh
#   source /home/eugenio/cluster_generator/env/esp-toolchain.sh
#   source /home/eugenio/cluster_generator/pulp-runtime/configs/astral-cluster.sh
#   make clean all          (or just run ./gen_header.sh, which does everything)
PULP_APP = test
PULP_APP_SRCS = matmul_selfcheck.c
PULP_CFLAGS = -O3 -I$(CURDIR)/../../baremetal

include $(PULP_SDK_HOME)/install/rules/pulp.mk
