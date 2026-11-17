# hello_cluster - pulp-sdk (PulpOS 2 / PMSIS) cluster test for ESP.
#
# Build (or just run ./gen_header.sh, which does all of this):
#   source /opt/cad/scripts/tools_env.sh                      # pyelftools
#   source /home/eugenio/pulp_sdk_fix/configs/pulp_cluster_esp.sh
#   make clean all
#
# Note the include below differs from sw/cluster_tests/*/Makefile: pulp-runtime
# apps use $(PULP_SDK_HOME)/install/rules/pulp.mk, while pulp-sdk apps use
# $(RULES_DIR)/pmsis_rules.mk. The two runtimes are not interchangeable and
# their configs must never be sourced into the same shell - both export
# PULP_SDK_HOME, pointing at different trees.

APP           = test
APP_SRCS      = test.c

# Reach the shared host<->cluster protocol headers in sw/baremetal.
APP_CFLAGS   += -O3 -g -I$(CURDIR)/../../baremetal
APP_LDFLAGS  += -O3 -g

include $(RULES_DIR)/pmsis_rules.mk
