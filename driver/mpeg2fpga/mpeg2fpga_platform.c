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
#include <linux/kfifo.h>
#include <linux/miscdevice.h>
#include <linux/poll.h>
#include <linux/timekeeping.h>
#include <linux/uaccess.h>
#include <linux/wait.h>
#include <linux/io.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/spinlock.h>
#include <linux/sysfs.h>

#include "mpeg2fpga_core.h"
#include "mpeg2fpga_regs.h"
#include "mpeg2fpga_uapi.h"

/* Picture events queued between the IRQ handler and read(). The decoder makes
 * ~25 pictures a second, so 64 is over two seconds of a reader not reading.
 */
#define MPEG2FPGA_EVENT_QUEUE	64

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

	/* /dev/mpeg2fpga, see mpeg2fpga_uapi.h. events/event_seq/event_lost
	 * are protected by @lock like the rest.
	 */
	struct miscdevice misc;
	unsigned long open_bit;
	wait_queue_head_t event_wait;
	DECLARE_KFIFO(events, struct mpeg2fpga_event, MPEG2FPGA_EVENT_QUEUE);
	u32 event_seq;
	bool event_lost;
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
	struct mpeg2fpga_picture_event pic;
	bool picture;

	/* Reading the status register also clears it in hardware (doc sec.
	 * 1.5/1.9), which deasserts the IRQ line -- this read is what
	 * acknowledges the interrupt, not just a diagnostic. It is also the
	 * only chance anyone gets to see these bits, so accumulate them for
	 * userspace instead of only logging them.
	 */
	spin_lock(&priv->lock);
	mpeg2fpga_core_poll_status(&priv->core, &status);
	/* the picture interrupt shares the line; acking it is the other half
	 * of deasserting it
	 */
	picture = mpeg2fpga_core_picture_ack(&priv->core, &pic);
	if (picture) {
		struct mpeg2fpga_event ev = {
			.timestamp_ns = ktime_get_ns(),
			.seq = priv->event_seq++,
			.hw_count = pic.count,
			.frame = pic.frame,
			.flags = (pic.overrun ? MPEG2FPGA_EVENT_OVERRUN : 0) |
				 (priv->event_lost ? MPEG2FPGA_EVENT_LOST : 0),
		};

		/* a full queue drops the new event and flags the next one
		 * that fits, rather than overwriting what the reader has not
		 * seen yet
		 */
		priv->event_lost = !kfifo_put(&priv->events, ev);
	}
	spin_unlock(&priv->lock);

	if (picture)
		wake_up_interruptible(&priv->event_wait);

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
 * /dev/mpeg2fpga: picture-ready events. See mpeg2fpga_uapi.h for the contract.
 */
static struct mpeg2fpga_platform *mpeg2fpga_from_file(struct file *file)
{
	return container_of(file->private_data, struct mpeg2fpga_platform, misc);
}

static int mpeg2fpga_open(struct inode *inode, struct file *file)
{
	struct mpeg2fpga_platform *priv = mpeg2fpga_from_file(file);
	unsigned long flags;

	if (test_and_set_bit(0, &priv->open_bit))
		return -EBUSY;

	spin_lock_irqsave(&priv->lock, flags);
	kfifo_reset(&priv->events);
	priv->event_seq = 0;
	priv->event_lost = false;
	mpeg2fpga_core_set_picture_irq(&priv->core, true);
	spin_unlock_irqrestore(&priv->lock, flags);

	return stream_open(inode, file);
}

static int mpeg2fpga_release(struct inode *inode, struct file *file)
{
	struct mpeg2fpga_platform *priv = mpeg2fpga_from_file(file);
	unsigned long flags;

	spin_lock_irqsave(&priv->lock, flags);
	mpeg2fpga_core_set_picture_irq(&priv->core, false);
	spin_unlock_irqrestore(&priv->lock, flags);

	clear_bit(0, &priv->open_bit);
	return 0;
}

static ssize_t mpeg2fpga_read(struct file *file, char __user *buf,
			      size_t count, loff_t *ppos)
{
	struct mpeg2fpga_platform *priv = mpeg2fpga_from_file(file);
	struct mpeg2fpga_event ev[8];
	unsigned long flags;
	unsigned int n;
	int ret;

	if (count < sizeof(ev[0]))
		return -EINVAL;

	for (;;) {
		spin_lock_irqsave(&priv->lock, flags);
		n = kfifo_out(&priv->events, ev,
			      min_t(size_t, ARRAY_SIZE(ev), count / sizeof(ev[0])));
		spin_unlock_irqrestore(&priv->lock, flags);
		if (n)
			break;
		if (file->f_flags & O_NONBLOCK)
			return -EAGAIN;
		ret = wait_event_interruptible(priv->event_wait,
					       !kfifo_is_empty(&priv->events));
		if (ret)
			return ret;
	}

	if (copy_to_user(buf, ev, n * sizeof(ev[0])))
		return -EFAULT;
	return n * sizeof(ev[0]);
}

static __poll_t mpeg2fpga_poll(struct file *file, poll_table *wait)
{
	struct mpeg2fpga_platform *priv = mpeg2fpga_from_file(file);

	poll_wait(file, &priv->event_wait, wait);
	return kfifo_is_empty(&priv->events) ? 0 : EPOLLIN | EPOLLRDNORM;
}

static const struct file_operations mpeg2fpga_fops = {
	.owner = THIS_MODULE,
	.open = mpeg2fpga_open,
	.release = mpeg2fpga_release,
	.read = mpeg2fpga_read,
	.poll = mpeg2fpga_poll,
};


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

/* "major.minor.patch+hash[-dirty]", from our own BUILD_* registers -- the
 * version attribute above is upstream mpeg2fpga's, the same for every build
 */
static ssize_t build_show(struct device *dev, struct device_attribute *attr,
			  char *buf)
{
	struct mpeg2fpga_platform *priv = dev_get_drvdata(dev);
	struct mpeg2fpga_build build;
	unsigned long flags;

	spin_lock_irqsave(&priv->lock, flags);
	mpeg2fpga_core_get_build(&priv->core, &build);
	spin_unlock_irqrestore(&priv->lock, flags);

	return sysfs_emit(buf, "%u.%u.%u+%07x%s\n", build.major, build.minor,
			  build.patch, build.git_hash, build.dirty ? "-dirty" : "");
}
static DEVICE_ATTR_RO(build);

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
	/* stream_dma needs 8-byte aligned starts, see mpeg2fpga_core.c;
	 * refuse here so the error lands on the write that caused it
	 */
	if (val & 7)
		return -EINVAL;
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
	bool start, last = true;
	int ret;

	/* "chunk": more chunks of this stream follow, so no sequence_end
	 * padding after this one. Anything kstrtobool takes as true starts
	 * the last (or only) chunk, as before.
	 */
	if (sysfs_streq(buf, "chunk")) {
		start = true;
		last = false;
	} else {
		ret = kstrtobool(buf, &start);
		if (ret)
			return ret;
	}
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
	ret = mpeg2fpga_core_dma_start_chunk(&priv->core, priv->dma_addr,
					     priv->dma_len, last);
	spin_unlock_irqrestore(&priv->lock, flags);

	return ret ? ret : count;
}
static DEVICE_ATTR_WO(dma_start);


/*
 * Trick mode. These are what let a client drive the decoder continuously --
 * stream after stream, paused and resumed -- instead of resetting the core for
 * every push. doc/mpeg2fpga.txt sec 1.11.
 */

static ssize_t freeze_show(struct device *dev, struct device_attribute *attr,
			   char *buf)
{
	struct mpeg2fpga_platform *priv = dev_get_drvdata(dev);
	unsigned long flags;
	bool frozen;

	spin_lock_irqsave(&priv->lock, flags);
	frozen = mpeg2fpga_core_is_frozen(&priv->core);
	spin_unlock_irqrestore(&priv->lock, flags);

	return sysfs_emit(buf, "%d\n", frozen);
}

static ssize_t freeze_store(struct device *dev, struct device_attribute *attr,
			    const char *buf, size_t count)
{
	struct mpeg2fpga_platform *priv = dev_get_drvdata(dev);
	unsigned long flags;
	bool freeze;
	int ret;

	ret = kstrtobool(buf, &freeze);
	if (ret)
		return ret;

	/* repeat_frame=31 holds the current picture; the decoder stalls behind
	 * it for want of anywhere to put the next one, and the watchdog is
	 * held off in this state so a pause cannot trip a reset.
	 */
	spin_lock_irqsave(&priv->lock, flags);
	mpeg2fpga_core_set_freeze(&priv->core, freeze);
	spin_unlock_irqrestore(&priv->lock, flags);

	return count;
}
static DEVICE_ATTR_RW(freeze);

static ssize_t source_select_show(struct device *dev,
				  struct device_attribute *attr, char *buf)
{
	struct mpeg2fpga_platform *priv = dev_get_drvdata(dev);
	unsigned long flags;
	u8 source;

	spin_lock_irqsave(&priv->lock, flags);
	source = mpeg2fpga_core_get_source_select(&priv->core);
	spin_unlock_irqrestore(&priv->lock, flags);

	return sysfs_emit(buf, "%u\n", source);
}

static ssize_t source_select_store(struct device *dev,
				   struct device_attribute *attr,
				   const char *buf, size_t count)
{
	struct mpeg2fpga_platform *priv = dev_get_drvdata(dev);
	unsigned long flags;
	u8 source;
	int ret;

	/* 0 last decoded, 1 blank, 4-7 framestore frame 0-3 (doc table 1.9);
	 * 2 and 3 are not defined.
	 */
	ret = kstrtou8(buf, 0, &source);
	if (ret)
		return ret;
	if (source == 2 || source == 3 || source > 7)
		return -EINVAL;

	spin_lock_irqsave(&priv->lock, flags);
	mpeg2fpga_core_set_source_select(&priv->core, source);
	spin_unlock_irqrestore(&priv->lock, flags);

	return count;
}
static DEVICE_ATTR_RW(source_select);

static ssize_t persistence_show(struct device *dev,
				struct device_attribute *attr, char *buf)
{
	struct mpeg2fpga_platform *priv = dev_get_drvdata(dev);
	unsigned long flags;
	bool on;

	spin_lock_irqsave(&priv->lock, flags);
	on = !!(priv->core.trick_shadow & MPEG2FPGA_TRICK_MODE_PERSISTENCE);
	spin_unlock_irqrestore(&priv->lock, flags);

	return sysfs_emit(buf, "%d\n", on);
}

static ssize_t persistence_store(struct device *dev,
				 struct device_attribute *attr,
				 const char *buf, size_t count)
{
	struct mpeg2fpga_platform *priv = dev_get_drvdata(dev);
	unsigned long flags;
	bool on;
	int ret;

	ret = kstrtobool(buf, &on);
	if (ret)
		return ret;

	spin_lock_irqsave(&priv->lock, flags);
	mpeg2fpga_core_set_persistence(&priv->core, on);
	spin_unlock_irqrestore(&priv->lock, flags);

	return count;
}
static DEVICE_ATTR_RW(persistence);

static ssize_t flush_vbuf_store(struct device *dev,
				struct device_attribute *attr,
				const char *buf, size_t count)
{
	struct mpeg2fpga_platform *priv = dev_get_drvdata(dev);
	unsigned long flags;
	bool flush;
	int ret;

	ret = kstrtobool(buf, &flush);
	if (ret)
		return ret;
	if (!flush)
		return count;

	/* Clears whatever is left of the previous stream in the input buffer.
	 * This is what makes "push another stream" work without resetting the
	 * core: verified on hardware going from 704x480 to 720x576 with
	 * video_ch raised and no error.
	 */
	spin_lock_irqsave(&priv->lock, flags);
	mpeg2fpga_core_flush_vbuf(&priv->core);
	spin_unlock_irqrestore(&priv->lock, flags);

	return count;
}
static DEVICE_ATTR_WO(flush_vbuf);

static ssize_t perf_counters_show(struct device *dev,
				   struct device_attribute *attr, char *buf)
{
	struct mpeg2fpga_platform *priv = dev_get_drvdata(dev);
	struct mpeg2fpga_perf_counters perf;
	unsigned long flags;

	spin_lock_irqsave(&priv->lock, flags);
	mpeg2fpga_core_get_perf_counters(&priv->core, &perf);
	spin_unlock_irqrestore(&priv->lock, flags);

	/* Free-running, never reset by reading -- see the struct's own doc
	 * comment in mpeg2fpga_core.h. A caller wanting the activity during
	 * one decode reads this twice and takes the delta.
	 */
	return sysfs_emit(buf,
		"disp_service_cnt %u\nvbr_service_cnt %u\nvbr_starved_cnt %u\nmem_res_valid_cnt %u\nwrite_service_cnt %u\nfwd_service_cnt %u\nbwd_service_cnt %u\nidle_cnt %u\nvld_en_cnt %u\nvld_stall_rld_cnt %u\nvld_stall_motcomp_cnt %u\nfwd_addr_empty_cnt %u\nfwd_dta_stall_cnt %u\nbwd_addr_empty_cnt %u\nbwd_dta_stall_cnt %u\nmem_req_almost_full_cnt %u\ntag_almost_full_cnt %u\npredict_err_almost_full_cnt %u\nrld_stall_predict_err_cnt %u\n",
		perf.disp_service_cnt, perf.vbr_service_cnt,
		perf.vbr_starved_cnt, perf.mem_res_valid_cnt,
		perf.write_service_cnt, perf.fwd_service_cnt,
		perf.bwd_service_cnt, perf.idle_cnt,
		perf.vld_en_cnt, perf.vld_stall_rld_cnt,
		perf.vld_stall_motcomp_cnt, perf.fwd_addr_empty_cnt,
		perf.fwd_dta_stall_cnt, perf.bwd_addr_empty_cnt,
		perf.bwd_dta_stall_cnt, perf.mem_req_almost_full_cnt,
		perf.tag_almost_full_cnt, perf.predict_err_almost_full_cnt,
		perf.rld_stall_predict_err_cnt);
}
static DEVICE_ATTR_RO(perf_counters);

static struct attribute *mpeg2fpga_attrs[] = {
	&dev_attr_version.attr,
	&dev_attr_build.attr,
	&dev_attr_enable.attr,
	&dev_attr_geometry.attr,
	&dev_attr_status.attr,
	&dev_attr_dma_addr.attr,
	&dev_attr_dma_len.attr,
	&dev_attr_dma_status.attr,
	&dev_attr_dma_start.attr,
	&dev_attr_freeze.attr,
	&dev_attr_source_select.attr,
	&dev_attr_persistence.attr,
	&dev_attr_flush_vbuf.attr,
	&dev_attr_perf_counters.attr,
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
	init_waitqueue_head(&priv->event_wait);
	INIT_KFIFO(priv->events);

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
	/* a previous load of this module may have left it on */
	mpeg2fpga_core_set_picture_irq(&priv->core, false);

	priv->misc.minor = MISC_DYNAMIC_MINOR;
	priv->misc.name = "mpeg2fpga";
	priv->misc.fops = &mpeg2fpga_fops;
	priv->misc.parent = &pdev->dev;
	ret = misc_register(&priv->misc);
	if (ret)
		return ret;

	{
		struct mpeg2fpga_build build;

		mpeg2fpga_core_get_build(&priv->core, &build);
		dev_info(&pdev->dev,
			 "mpeg2fpga build %u.%u.%u+%07x%s (core 0x%04x), irq %d\n",
			 build.major, build.minor, build.patch, build.git_hash,
			 build.dirty ? "-dirty" : "",
			 mpeg2fpga_core_get_version(&priv->core), irq);
	}

	return 0;
}

static void mpeg2fpga_platform_remove(struct platform_device *pdev)
{
	struct mpeg2fpga_platform *priv = platform_get_drvdata(pdev);

	misc_deregister(&priv->misc);
	mpeg2fpga_core_set_picture_irq(&priv->core, false);
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
