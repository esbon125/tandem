// SPDX-License-Identifier: GPL-2.0
/*
 * Platform driver for the mpeg2fpga MPEG-2 decoder core.
 *
 * Thin glue between the Linux platform_device/IRQ infrastructure and the
 * hardware-independent logic in mpeg2fpga_core.c: maps the register window
 * described by the fabric device tree overlay (see
 * docs/device_tree_overlays_guia.md, compatible = "esbon,mpeg2fpga"), wires
 * the single IRQ line, and reports decoder events via dev_dbg() until a real
 * consumer (video subsystem) exists.
 */

#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>

#include "mpeg2fpga_core.h"
#include "mpeg2fpga_regs.h"

struct mpeg2fpga_platform {
	void __iomem *base;
	struct mpeg2fpga_regops ops;
	struct mpeg2fpga_core core;
};

static u32 mpeg2fpga_platform_read(void *ctx, unsigned int reg)
{
	struct mpeg2fpga_platform *priv = ctx;

	return readl(priv->base + (reg * 4));
}

static void mpeg2fpga_platform_write(void *ctx, unsigned int reg, u32 val)
{
	struct mpeg2fpga_platform *priv = ctx;

	writel(val, priv->base + (reg * 4));
}

static irqreturn_t mpeg2fpga_platform_irq(int irq, void *dev_id)
{
	struct platform_device *pdev = dev_id;
	struct mpeg2fpga_platform *priv = platform_get_drvdata(pdev);
	struct mpeg2fpga_status status;

	/* Reading the status register also clears it in hardware (doc sec.
	 * 1.5/1.9), which deasserts the IRQ line -- this read is what
	 * acknowledges the interrupt, not just a diagnostic.
	 */
	mpeg2fpga_core_read_status(&priv->core, &status);

	if (status.error)
		dev_warn(&pdev->dev, "bitstream parse error\n");
	if (status.watchdog_status)
		dev_warn(&pdev->dev, "watchdog expired\n");
	if (status.picture_hdr)
		dev_dbg(&pdev->dev, "picture header\n");
	if (status.frame_end)
		dev_dbg(&pdev->dev, "frame end\n");
	if (status.video_ch)
		dev_dbg(&pdev->dev, "video resolution/frame rate changed\n");

	return IRQ_HANDLED;
}

static int mpeg2fpga_platform_probe(struct platform_device *pdev)
{
	struct mpeg2fpga_platform *priv;
	int irq;
	int ret;

	priv = devm_kzalloc(&pdev->dev, sizeof(*priv), GFP_KERNEL);
	if (!priv)
		return -ENOMEM;

	priv->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(priv->base))
		return PTR_ERR(priv->base);

	irq = platform_get_irq(pdev, 0);
	if (irq < 0)
		return irq;

	priv->ops.read = mpeg2fpga_platform_read;
	priv->ops.write = mpeg2fpga_platform_write;
	priv->ops.ctx = priv;
	mpeg2fpga_core_init(&priv->core, &priv->ops);

	platform_set_drvdata(pdev, priv);

	ret = devm_request_irq(&pdev->dev, irq, mpeg2fpga_platform_irq,
				0, dev_name(&pdev->dev), pdev);
	if (ret)
		return ret;

	mpeg2fpga_core_set_irq_mask(&priv->core, MPEG2FPGA_IRQ_ALL);

	dev_info(&pdev->dev, "mpeg2fpga hw version 0x%04x, irq %d\n",
		 mpeg2fpga_core_get_version(&priv->core), irq);

	return 0;
}

static void mpeg2fpga_platform_remove(struct platform_device *pdev)
{
	struct mpeg2fpga_platform *priv = platform_get_drvdata(pdev);

	mpeg2fpga_core_set_irq_mask(&priv->core, 0);
}

static const struct of_device_id mpeg2fpga_platform_of_match[] = {
	{ .compatible = "esbon,mpeg2fpga" },
	{ }
};
MODULE_DEVICE_TABLE(of, mpeg2fpga_platform_of_match);

static struct platform_driver mpeg2fpga_platform_driver = {
	.probe = mpeg2fpga_platform_probe,
	.remove = mpeg2fpga_platform_remove,
	.driver = {
		.name = "mpeg2fpga",
		.of_match_table = mpeg2fpga_platform_of_match,
	},
};
module_platform_driver(mpeg2fpga_platform_driver);

MODULE_AUTHOR("Esteban Bustamante");
MODULE_DESCRIPTION("mpeg2fpga MPEG-2 decoder platform driver");
MODULE_LICENSE("GPL");
