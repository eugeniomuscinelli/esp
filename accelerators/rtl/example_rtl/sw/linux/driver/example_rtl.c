// Copyright (c) 2011-2024 Columbia University, System Level Design Group
// SPDX-License-Identifier: Apache-2.0
#include <linux/of_device.h>
#include <linux/mm.h>

#include <asm/io.h>

#include <esp_accelerator.h>
#include <esp.h>

#include "example_rtl.h"

#define DRV_NAME	"example_rtl"

/* <<--regs-->> */
#define EXAMPLE_REG1_REG 0x48
#define EXAMPLE_REG3_REG 0x44
#define EXAMPLE_REG2_REG 0x40

struct example_rtl_device {
	struct esp_device esp;
};

static struct esp_driver example_driver;

static struct of_device_id example_device_ids[] = {
	{
		.name = "SLD_EXAMPLE_RTL",
	},
	{
		.name = "eb_075",
	},
	{
		.compatible = "sld,example_rtl",
	},
	{ },
};

static int example_devs;

static inline struct example_rtl_device *to_example(struct esp_device *esp)
{
	return container_of(esp, struct example_rtl_device, esp);
}

static void example_prep_xfer(struct esp_device *esp, void *arg)
{
	struct example_rtl_access *a = arg;

	/* <<--regs-config-->> */
	iowrite32be(a->reg1, esp->iomem + EXAMPLE_REG1_REG);
	iowrite32be(a->reg3, esp->iomem + EXAMPLE_REG3_REG);
	iowrite32be(a->reg2, esp->iomem + EXAMPLE_REG2_REG);
	iowrite32be(a->src_offset, esp->iomem + SRC_OFFSET_REG);
	iowrite32be(a->dst_offset, esp->iomem + DST_OFFSET_REG);

}

static bool example_xfer_input_ok(struct esp_device *esp, void *arg)
{
	/* struct example_rtl_device *example = to_example(esp); */
	/* struct example_rtl_access *a = arg; */

	return true;
}

static int example_probe(struct platform_device *pdev)
{
	struct example_rtl_device *example;
	struct esp_device *esp;
	int rc;

	example = kzalloc(sizeof(*example), GFP_KERNEL);
	if (example == NULL)
		return -ENOMEM;
	esp = &example->esp;
	esp->module = THIS_MODULE;
	esp->number = example_devs;
	esp->driver = &example_driver;
	rc = esp_device_register(esp, pdev);
	if (rc)
		goto err;

	example_devs++;
	return 0;
 err:
	kfree(example);
	return rc;
}

static int __exit example_remove(struct platform_device *pdev)
{
	struct esp_device *esp = platform_get_drvdata(pdev);
	struct example_rtl_device *example = to_example(esp);

	esp_device_unregister(esp);
	kfree(example);
	return 0;
}

static struct esp_driver example_driver = {
	.plat = {
		.probe		= example_probe,
		.remove		= example_remove,
		.driver		= {
			.name = DRV_NAME,
			.owner = THIS_MODULE,
			.of_match_table = example_device_ids,
		},
	},
	.xfer_input_ok	= example_xfer_input_ok,
	.prep_xfer	= example_prep_xfer,
	.ioctl_cm	= EXAMPLE_RTL_IOC_ACCESS,
	.arg_size	= sizeof(struct example_rtl_access),
};

static int __init example_init(void)
{
	return esp_driver_register(&example_driver);
}

static void __exit example_exit(void)
{
	esp_driver_unregister(&example_driver);
}

module_init(example_init)
module_exit(example_exit)

MODULE_DEVICE_TABLE(of, example_device_ids);

MODULE_AUTHOR("Emilio G. Cota <cota@braap.org>");
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("example_rtl driver");
