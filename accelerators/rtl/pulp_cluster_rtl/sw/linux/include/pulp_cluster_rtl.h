// Copyright (c) 2011-2026 Columbia University, System Level Design Group
// SPDX-License-Identifier: Apache-2.0
#ifndef _PULP_CLUSTER_RTL_H_
#define _PULP_CLUSTER_RTL_H_

#ifdef __KERNEL__
    #include <linux/ioctl.h>
    #include <linux/types.h>
#else
    #include <sys/ioctl.h>
    #include <stdint.h>
    #ifndef __user
        #define __user
    #endif
#endif /* __KERNEL__ */

#include <esp.h>
#include <esp_accelerator.h>

struct pulp_cluster_rtl_access {
    struct esp_access esp;
    /* <<--regs-->> */
	unsigned boot_offset;
	unsigned spare0;
	unsigned spare1;
    unsigned src_offset;
    unsigned dst_offset;
};

#define PULP_CLUSTER_RTL_IOC_ACCESS _IOW('S', 0, struct pulp_cluster_rtl_access)

#endif /* _PULP_CLUSTER_RTL_H_ */
