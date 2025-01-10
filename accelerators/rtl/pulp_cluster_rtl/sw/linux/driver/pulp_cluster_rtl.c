// Copyright (c) 2011-2024 Columbia University, System Level Design Group
// SPDX-License-Identifier: Apache-2.0
#include <linux/of_device.h>
#include <linux/mm.h>

#include <asm/io.h>

#include <esp_accelerator.h>
#include <esp.h>

#include "pulp_cluster_rtl.h"

#define DRV_NAME "pulp_cluster_rtl"

/* <<--regs-->> */
#define PULP_CLUSTER_REG1_REG 0x48
#define PULP_CLUSTER_REG3_REG 0x44
#define PULP_CLUSTER_REG2_REG 0x40

structpulp_cluster_rtl _device {
    struct esp_device esp;
};

static struct esp_driverpulp_cluster _driver;

static struct of_device_idpulp_cluster _device_ids[] = {
    {
        .name = "SLD_PULP_CLUSTER_RTL",
    },
        {
            .name = "eb_075",
        },
        {
            .compatible = "sld,pulp_cluster_rtl",
        },
        {},
};

static intpulp_cluster _devs;

static inline structpulp_cluster_rtl _device *to_pulp_cluster(struct esp_device *esp) {
    return container_of(esp, structpulp_cluster_rtl _device, esp);
}

static voidpulp_cluster
    _prep_xfer(struct esp_device *esp, void *arg)
{
    structpulp_cluster_rtl _access *a = arg;

    /* <<--regs-config-->> */
	iowrite32be(a->reg1, esp->iomem + PULP_CLUSTER_REG1_REG);
	iowrite32be(a->reg3, esp->iomem + PULP_CLUSTER_REG3_REG);
	iowrite32be(a->reg2, esp->iomem + PULP_CLUSTER_REG2_REG);
    iowrite32be(a->src_offset, esp->iomem + SRC_OFFSET_REG);
    iowrite32be(a->dst_offset, esp->iomem + DST_OFFSET_REG);
}

static boolpulp_cluster _xfer_input_ok(struct esp_device *esp, void *arg)
{
    /* struct pulp_cluster_rtl_device *pulp_cluster = to_pulp_cluster(esp); */
    /* struct pulp_cluster_rtl_access *a = arg; */

    return true;
}

static intpulp_cluster _probe(struct platform_device *pdev)
{
    structpulp_cluster_rtl _device *pulp_cluster;
    struct esp_device *esp;
    int rc;

    pulp_cluster = kzalloc(sizeof(*pulp_cluster), GFP_KERNEL);
    if (pulp_cluster == NULL) return -ENOMEM;
    esp         = &pulp_cluster->esp;
    esp->module = THIS_MODULE;
    esp->number = pulp_cluster _devs;
    esp->driver = &pulp_cluster _driver;
    rc          = esp_device_register(esp, pdev);
    if (rc) goto err;

    pulp_cluster _devs++;
    return 0;
err:
    kfree(pulp_cluster);
    return rc;
}

static int __exitpulp_cluster _remove(struct platform_device *pdev)
{
    struct esp_device *esp                            = platform_get_drvdata(pdev);
    structpulp_cluster_rtl _device *pulp_cluster = to_pulp_cluster(esp);

    esp_device_unregister(esp);
    kfree(pulp_cluster);
    return 0;
}

static struct esp_driverpulp_cluster _driver = {
    .plat =
        {
            .probe  = pulp_cluster _probe,
            .remove = pulp_cluster _remove,
            .driver =
                {
                    .name           = DRV_NAME,
                    .owner          = THIS_MODULE,
                    .of_match_table = pulp_cluster _device_ids,
                },
        },
    .xfer_input_ok = pulp_cluster _xfer_input_ok, .prep_xfer = pulp_cluster _prep_xfer,
    .ioctl_cm = PULP_CLUSTER_RTL _IOC_ACCESS, .arg_size = sizeof(structpulp_cluster_rtl _access),
};

static int __initpulp_cluster _init(void)
{
    return esp_driver_register(&pulp_cluster _driver);
}

static void __exitpulp_cluster _exit(void)
{
    esp_driver_unregister(&pulp_cluster _driver);
}

module_init(pulp_cluster _init) module_exit(pulp_cluster _exit)

    MODULE_DEVICE_TABLE(of, pulp_cluster _device_ids);

MODULE_AUTHOR("Emilio G. Cota <cota@braap.org>");
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("pulp_cluster_rtl driver");
