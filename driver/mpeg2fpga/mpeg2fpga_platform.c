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
#include <linux/spinlock.h>
#include <linux/sysfs.h>

#include "mpeg2fpga_core.h"
#include "mpeg2fpga_regs.h"

struct mpeg2fpga_platform {
	void __iomem *base;
	struct mpeg2fpga_regops ops;
	struct mpeg2fpga_core core;
	/* Serialises the core against the IRQ handler, which also touches the
	 * status sticky word and the write-mode shadow.
	 */
	spinlock_t lock;
	/* DMA address and length are write-only in hardware, so sysfs has to
	 * remember what it staged before the start bit is written.
	 */
	u32 dma_addr;
	u32 dma_len;
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
	 * acknowledges the interrupt, not just a diagnostic. It is also the
	 * only chance anyone gets to see these bits, so accumulate them for
	 * userspace instead of only logging them.
	 */
	spin_lock(&priv->lock);
	mpeg2fpga_core_poll_status(&priv->core, &status);
	spin_unlock(&priv->lock);

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


/*
 * sysfs interface.
 *
 * Everything here was previously done by writing straight into the UIO
 * mapping from Python, with the register offsets copied between a dozen
 * diagnostic scripts. Exposing it from the driver means one definition of the
 * register map, the DMA start ordering enforced in one place, and the sticky
 * status accumulated by the IRQ handler instead of by whoever remembers to
 * poll.
 */

static ssize_t version_show(struct device *dev, struct device_attribute *attr,
			    char *buf)
{
	struct mpeg2fpga_platform *priv = dev_get_drvdata(dev);
	unsigned long flags;
	u16 version;

	spin_lock_irqsave(&priv->lock, flags);
	version = mpeg2fpga_core_get_version(&priv->core);
	spin_unlock_irqrestore(&priv->lock, flags);

	return sysfs_emit(buf, "0x%04x\n", version);
}
static DEVICE_ATTR_RO(version);

static ssize_t enable_show(struct device *dev, struct device_attribute *attr,
			   char *buf)
{
	struct mpeg2fpga_platform *priv = dev_get_drvdata(dev);
	unsigned long flags;
	bool enabled;

	spin_lock_irqsave(&priv->lock, flags);
	enabled = mpeg2fpga_core_is_enabled(&priv->core);
	spin_unlock_irqrestore(&priv->lock, flags);

	return sysfs_emit(buf, "%d\n", enabled);
}

static ssize_t enable_store(struct device *dev, struct device_attribute *attr,
			    const char *buf, size_t count)
{
	struct mpeg2fpga_platform *priv = dev_get_drvdata(dev);
	unsigned long flags;
	bool enable;
	int ret;

	ret = kstrtobool(buf, &enable);
	if (ret)
		return ret;

	spin_lock_irqsave(&priv->lock, flags);
	mpeg2fpga_core_set_enable(&priv->core, enable);
	spin_unlock_irqrestore(&priv->lock, flags);

	return count;
}
static DEVICE_ATTR_RW(enable);

static ssize_t geometry_show(struct device *dev, struct device_attribute *attr,
			     char *buf)
{
	struct mpeg2fpga_platform *priv = dev_get_drvdata(dev);
	struct mpeg2fpga_geometry geom;
	unsigned long flags;

	spin_lock_irqsave(&priv->lock, flags);
	mpeg2fpga_core_get_geometry(&priv->core, &geom);
	spin_unlock_irqrestore(&priv->lock, flags);

	/* display_size is whatever the stream's sequence_display_extension
	 * declared, which need not match size and is 0 when there is none.
	 */
	return sysfs_emit(buf,
		"size %ux%u\ndisplay_size %ux%u\nmacroblocks %ux%u\nframe_rate_code %u\nframe_rate_millihz %u\n",
		geom.width, geom.height,
		geom.display_width, geom.display_height,
		geom.macroblocks_wide, geom.macroblocks_high,
		geom.frame_rate_code, geom.frame_rate_millihz);
}
static DEVICE_ATTR_RO(geometry);

static ssize_t status_show(struct device *dev, struct device_attribute *attr,
			   char *buf)
{
	struct mpeg2fpga_platform *priv = dev_get_drvdata(dev);
	struct mpeg2fpga_status status;
	unsigned long flags;
	u32 sticky;

	/* Poll as well as report: with interrupts masked off, or between
	 * them, this is what collects the bits.
	 */
	spin_lock_irqsave(&priv->lock, flags);
	mpeg2fpga_core_poll_status(&priv->core, &status);
	sticky = mpeg2fpga_core_get_sticky(&priv->core);
	spin_unlock_irqrestore(&priv->lock, flags);

	return sysfs_emit(buf,
		"sticky 0x%04x\nerror %d\nvideo_ch %d\nframe_end %d\npicture_hdr %d\nwatchdog %d\nmatrix_coefficients %u\n",
		sticky,
		!!(sticky & MPEG2FPGA_STATUS_ERROR),
		!!(sticky & MPEG2FPGA_STATUS_VIDEO_CH),
		!!(sticky & MPEG2FPGA_STATUS_FRAME_END),
		!!(sticky & MPEG2FPGA_STATUS_PICTURE_HDR),
		!!(sticky & MPEG2FPGA_STATUS_WATCHDOG_STATUS),
		status.matrix_coefficients);
}

static ssize_t status_store(struct device *dev, struct device_attribute *attr,
			    const char *buf, size_t count)
{
	struct mpeg2fpga_platform *priv = dev_get_drvdata(dev);
	unsigned long flags;

	/* Any write clears the accumulation, so a client can bracket a push. */
	spin_lock_irqsave(&priv->lock, flags);
	mpeg2fpga_core_clear_sticky(&priv->core);
	spin_unlock_irqrestore(&priv->lock, flags);

	return count;
}
static DEVICE_ATTR_RW(status);

static ssize_t dma_addr_show(struct device *dev, struct device_attribute *attr,
			     char *buf)
{
	struct mpeg2fpga_platform *priv = dev_get_drvdata(dev);

	return sysfs_emit(buf, "0x%08x\n", priv->dma_addr);
}

static ssize_t dma_addr_store(struct device *dev, struct device_attribute *attr,
			      const char *buf, size_t count)
{
	struct mpeg2fpga_platform *priv = dev_get_drvdata(dev);
	u32 val;
	int ret;

	ret = kstrtou32(buf, 0, &val);
	if (ret)
		return ret;
	priv->dma_addr = val;

	return count;
}
static DEVICE_ATTR_RW(dma_addr);

static ssize_t dma_len_show(struct device *dev, struct device_attribute *attr,
			    char *buf)
{
	struct mpeg2fpga_platform *priv = dev_get_drvdata(dev);

	return sysfs_emit(buf, "%u\n", priv->dma_len);
}

static ssize_t dma_len_store(struct device *dev, struct device_attribute *attr,
			     const char *buf, size_t count)
{
	struct mpeg2fpga_platform *priv = dev_get_drvdata(dev);
	u32 val;
	int ret;

	ret = kstrtou32(buf, 0, &val);
	if (ret)
		return ret;
	priv->dma_len = val;

	return count;
}
static DEVICE_ATTR_RW(dma_len);

static ssize_t dma_status_show(struct device *dev,
			       struct device_attribute *attr, char *buf)
{
	struct mpeg2fpga_platform *priv = dev_get_drvdata(dev);
	struct mpeg2fpga_dma_status status;
	unsigned long flags;

	spin_lock_irqsave(&priv->lock, flags);
	mpeg2fpga_core_dma_get_status(&priv->core, &status);
	spin_unlock_irqrestore(&priv->lock, flags);

	/* bytes_done includes the 32-byte sequence_end_code stream_dma.v
	 * appends to every transfer, so it reads 32 more than was asked for.
	 */
	return sysfs_emit(buf, "busy %d\ndone %d\nbytes_done %u\n",
			  status.busy, status.done, status.bytes_done);
}
static DEVICE_ATTR_RO(dma_status);

static ssize_t dma_start_store(struct device *dev,
			       struct device_attribute *attr,
			       const char *buf, size_t count)
{
	struct mpeg2fpga_platform *priv = dev_get_drvdata(dev);
	struct mpeg2fpga_dma_status status;
	unsigned long flags;
	bool start;
	int ret;

	ret = kstrtobool(buf, &start);
	if (ret)
		return ret;
	if (!start)
		return count;
	if (!priv->dma_len)
		return -EINVAL;

	spin_lock_irqsave(&priv->lock, flags);
	mpeg2fpga_core_dma_get_status(&priv->core, &status);
	if (status.busy) {
		spin_unlock_irqrestore(&priv->lock, flags);
		return -EBUSY;
	}
	mpeg2fpga_core_dma_start(&priv->core, priv->dma_addr, priv->dma_len);
	spin_unlock_irqrestore(&priv->lock, flags);

	return count;
}
static DEVICE_ATTR_WO(dma_start);

static struct attribute *mpeg2fpga_attrs[] = {
	&dev_attr_version.attr,
	&dev_attr_enable.attr,
	&dev_attr_geometry.attr,
	&dev_attr_status.attr,
	&dev_attr_dma_addr.attr,
	&dev_attr_dma_len.attr,
	&dev_attr_dma_status.attr,
	&dev_attr_dma_start.attr,
	NULL,
};
ATTRIBUTE_GROUPS(mpeg2fpga);

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

	spin_lock_init(&priv->lock);

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
		.dev_groups = mpeg2fpga_groups,
	},
};
module_platform_driver(mpeg2fpga_platform_driver);

MODULE_AUTHOR("Esteban Bustamante");
MODULE_DESCRIPTION("mpeg2fpga MPEG-2 decoder platform driver");
MODULE_LICENSE("GPL");
