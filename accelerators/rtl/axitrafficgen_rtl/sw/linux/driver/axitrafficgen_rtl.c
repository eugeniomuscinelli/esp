// Copyright (c) 2011-2024 Columbia University, System Level Design Group
// SPDX-License-Identifier: Apache-2.0
#include <linux/of_device.h>
#include <linux/mm.h>

#include <asm/io.h>

#include <esp_accelerator.h>
#include <esp.h>

#include "axitrafficgen_rtl.h"

#define DRV_NAME	"axitrafficgen_rtl"

/* <<--regs-->> */
#define AXITRAFFICGEN_REG1_REG 0x44
#define AXITRAFFICGEN_REG2_REG 0x40

struct axitrafficgen_rtl_device {
	struct esp_device esp;
};

static struct esp_driver axitrafficgen_driver;

static struct of_device_id axitrafficgen_device_ids[] = {
	{
		.name = "SLD_AXITRAFFICGEN_RTL",
	},
	{
		.name = "eb_0ac",
	},
	{
		.compatible = "sld,axitrafficgen_rtl",
	},
	{ },
};

static int axitrafficgen_devs;

static inline struct axitrafficgen_rtl_device *to_axitrafficgen(struct esp_device *esp)
{
	return container_of(esp, struct axitrafficgen_rtl_device, esp);
}

static void axitrafficgen_prep_xfer(struct esp_device *esp, void *arg)
{
	struct axitrafficgen_rtl_access *a = arg;

	/* <<--regs-config-->> */
	iowrite32be(a->reg1, esp->iomem + AXITRAFFICGEN_REG1_REG);
	iowrite32be(a->reg2, esp->iomem + AXITRAFFICGEN_REG2_REG);
	iowrite32be(a->src_offset, esp->iomem + SRC_OFFSET_REG);
	iowrite32be(a->dst_offset, esp->iomem + DST_OFFSET_REG);

}

static bool axitrafficgen_xfer_input_ok(struct esp_device *esp, void *arg)
{
	/* struct axitrafficgen_rtl_device *axitrafficgen = to_axitrafficgen(esp); */
	/* struct axitrafficgen_rtl_access *a = arg; */

	return true;
}

static int axitrafficgen_probe(struct platform_device *pdev)
{
	struct axitrafficgen_rtl_device *axitrafficgen;
	struct esp_device *esp;
	int rc;

	axitrafficgen = kzalloc(sizeof(*axitrafficgen), GFP_KERNEL);
	if (axitrafficgen == NULL)
		return -ENOMEM;
	esp = &axitrafficgen->esp;
	esp->module = THIS_MODULE;
	esp->number = axitrafficgen_devs;
	esp->driver = &axitrafficgen_driver;
	rc = esp_device_register(esp, pdev);
	if (rc)
		goto err;

	axitrafficgen_devs++;
	return 0;
 err:
	kfree(axitrafficgen);
	return rc;
}

static int __exit axitrafficgen_remove(struct platform_device *pdev)
{
	struct esp_device *esp = platform_get_drvdata(pdev);
	struct axitrafficgen_rtl_device *axitrafficgen = to_axitrafficgen(esp);

	esp_device_unregister(esp);
	kfree(axitrafficgen);
	return 0;
}

static struct esp_driver axitrafficgen_driver = {
	.plat = {
		.probe		= axitrafficgen_probe,
		.remove		= axitrafficgen_remove,
		.driver		= {
			.name = DRV_NAME,
			.owner = THIS_MODULE,
			.of_match_table = axitrafficgen_device_ids,
		},
	},
	.xfer_input_ok	= axitrafficgen_xfer_input_ok,
	.prep_xfer	= axitrafficgen_prep_xfer,
	.ioctl_cm	= AXITRAFFICGEN_RTL_IOC_ACCESS,
	.arg_size	= sizeof(struct axitrafficgen_rtl_access),
};

static int __init axitrafficgen_init(void)
{
	return esp_driver_register(&axitrafficgen_driver);
}

static void __exit axitrafficgen_exit(void)
{
	esp_driver_unregister(&axitrafficgen_driver);
}

module_init(axitrafficgen_init)
module_exit(axitrafficgen_exit)

MODULE_DEVICE_TABLE(of, axitrafficgen_device_ids);

MODULE_AUTHOR("Emilio G. Cota <cota@braap.org>");
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("axitrafficgen_rtl driver");
