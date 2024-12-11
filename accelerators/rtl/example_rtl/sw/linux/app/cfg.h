// Copyright (c) 2011-2024 Columbia University, System Level Design Group
// SPDX-License-Identifier: Apache-2.0
#ifndef __ESP_CFG_000_H__
#define __ESP_CFG_000_H__

#include "libesp.h"
#include "example_rtl.h"

typedef int32_t token_t;

/* <<--params-def-->> */
#define REG1 8
#define REG3 8
#define REG2 8

/* <<--params-->> */
const int32_t reg1 = REG1;
const int32_t reg3 = REG3;
const int32_t reg2 = REG2;

#define NACC 1

struct example_rtl_access example_cfg_000[] = {
	{
		/* <<--descriptor-->> */
		.reg1 = REG1,
		.reg3 = REG3,
		.reg2 = REG2,
		.src_offset = 0,
		.dst_offset = 0,
		.esp.coherence = ACC_COH_NONE,
		.esp.p2p_store = 0,
		.esp.p2p_nsrcs = 0,
		.esp.p2p_srcs = {"", "", "", ""},
	}
};

esp_thread_info_t cfg_000[] = {
	{
		.run = true,
		.devname = "example_rtl.0",
		.ioctl_req = EXAMPLE_RTL_IOC_ACCESS,
		.esp_desc = &(example_cfg_000[0].esp),
	}
};

#endif /* __ESP_CFG_000_H__ */
