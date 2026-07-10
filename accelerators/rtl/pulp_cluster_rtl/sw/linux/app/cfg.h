// Copyright (c) 2011-2026 Columbia University, System Level Design Group
// SPDX-License-Identifier: Apache-2.0
#ifndef __ESP_CFG_000_H__
#define __ESP_CFG_000_H__

#include "libesp.h"
#include "pulp_cluster_rtl.h"

typedef int64_t token_t;

/* <<--params-def-->> */
#define BOOT_OFFSET 0x8080
#define SPARE0 1
#define SPARE1 1

/* <<--params-->> */
const int32_t boot_offset = BOOT_OFFSET;
const int32_t spare0 = SPARE0;
const int32_t spare1 = SPARE1;

#define NACC 1

struct pulp_cluster_rtl_access pulp_cluster_cfg_000[] = {{
    /* <<--descriptor-->> */
		.boot_offset = BOOT_OFFSET,
		.spare0 = SPARE0,
		.spare1 = SPARE1,
    .src_offset    = 0,
    .dst_offset    = 0,
    .esp.coherence = ACC_COH_NONE,
    .esp.p2p_store = 0,
    .esp.p2p_nsrcs = 0,
    .esp.p2p_srcs  = {"", "", "", ""},
}};

esp_thread_info_t cfg_000[] = {{
    .run       = true,
    .devname   = "pulp_cluster_rtl.0",
    .ioctl_req = PULP_CLUSTER_RTL_IOC_ACCESS,
    .esp_desc  = &(pulp_cluster_cfg_000[0].esp),
}};

#endif /* __ESP_CFG_000_H__ */
