//
// Renode model of the mpeg2fpga MPEG-2 decoder register interface.
//
// Source: trunk/mpeg2fpga/doc/mpeg2fpga.txt, chapter 1 (hardware_development
// branch of the tandem repo). Bit layout mirrors driver/mpeg2fpga/mpeg2fpga_regs.h
// on firmware_development, kept in sync by hand -- there is no shared source of
// truth between the C driver and this C# model.
//
// Modeled after extras/workspace.examples/mpfs-mustein/renode/models/MusteinGenericGPU.cs
// (register-field pattern) and Peripherals/I2C/MPFS_I2C.cs (GPIO IRQ pattern),
// both bundled with this SoftConsole install.
//
// This is a test double for driver development (Fase 4b/4c), not a functional
// MPEG-2 decoder: RaisePictureHeader()/RaiseFrameEnd()/RaiseVideoChange()/
// RaiseError() let a Renode monitor script or integration test simulate decoder
// events without a real video stream.
//
using Antmicro.Renode.Core;
using Antmicro.Renode.Core.Structure.Registers;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals.Bus;

namespace Antmicro.Renode.Peripherals.Miscellaneous
{
    public class MPEG2FPGARegisters : IDoubleWordPeripheral, IKnownSize
    {
        public MPEG2FPGARegisters(Machine machine)
        {
            IRQ = new GPIO();
            Reset();
        }

        public long Size => 0x40; // 16 registers x 4 bytes, read-bank and write-bank share this address range

        public GPIO IRQ { get; private set; }

        public void Reset()
        {
            version = 0x0001;
            matrixCoefficients = 0;
            watchdogStatus = false;
            osdWrEn = false;
            osdWrAck = false;
            osdWrFull = false;
            pictureHdr = false;
            frameEnd = false;
            videoCh = false;
            error = false;

            horizontalSize = 0;
            verticalSize = 0;
            displayHorizontalSize = 0;
            displayVerticalSize = 0;
            aspectRatioInformation = 0;
            progressiveSequence = false;
            frameRateExtensionD = 0;
            frameRateExtensionN = 0;
            frameRateCode = 0;
            testpoint = 0;

            // Matches hardware power-up/reset state (doc sec. 1.9): all
            // *_intr_en low, watchdog at its documented default interval.
            watchdogInterval = WatchdogDefaultInterval;
            osdEnable = false;
            pictureHdrIntrEn = false;
            frameEndIntrEn = false;
            videoChIntrEn = false;

            IRQ.Unset();
        }

        public uint ReadDoubleWord(long offset)
        {
            switch((ReadRegister)(offset / 4))
            {
                case ReadRegister.Version:
                    return version;
                case ReadRegister.Status:
                    return ReadAndClearStatus();
                case ReadRegister.Size:
                    return Pack(horizontalSize, SizeFieldMask, SizeHorizontalShift, verticalSize, SizeFieldMask, 0);
                case ReadRegister.DisplaySize:
                    return Pack(displayHorizontalSize, SizeFieldMask, SizeHorizontalShift, displayVerticalSize, SizeFieldMask, 0);
                case ReadRegister.FrameRate:
                    return (uint)(((aspectRatioInformation & 0xfu) << 12)
                        | (progressiveSequence ? (1u << 11) : 0)
                        | ((frameRateExtensionD & 0x1fu) << 6)
                        | ((frameRateExtensionN & 0x3u) << 4)
                        | (frameRateCode & 0xfu));
                case ReadRegister.Testpoint:
                    return testpoint;
                default:
                    this.Log(LogLevel.Warning, "Unhandled read from read-bank offset 0x{0:X}", offset);
                    return 0;
            }
        }

        public void WriteDoubleWord(long offset, uint value)
        {
            switch((WriteRegister)(offset / 4))
            {
                case WriteRegister.Stream:
                    WriteStream(value);
                    break;
                default:
                    // Video timing / OSD / trick-mode registers: not needed to
                    // exercise driver probe()/IRQ plumbing, stored but inert.
                    this.Log(LogLevel.Debug, "Write 0x{0:X} to inert write-bank offset 0x{1:X}", value, offset);
                    break;
            }
        }

        /// <summary>Simulate a picture-header event (Fase 4c integration test / monitor command).</summary>
        public void RaisePictureHeader()
        {
            if(pictureHdrIntrEn)
            {
                pictureHdr = true;
                UpdateInterrupt();
            }
        }

        /// <summary>Simulate a frame-display-end event.</summary>
        public void RaiseFrameEnd()
        {
            if(frameEndIntrEn)
            {
                frameEnd = true;
                UpdateInterrupt();
            }
        }

        /// <summary>Simulate a video resolution/frame-rate change event.</summary>
        public void RaiseVideoChange()
        {
            if(videoChIntrEn)
            {
                videoCh = true;
                UpdateInterrupt();
            }
        }

        /// <summary>
        /// Simulate a bitstream parse error. The doc does not define an enable
        /// bit for this source (unlike the other three), so it is modeled as
        /// always asserting the interrupt line.
        /// </summary>
        public void RaiseError()
        {
            error = true;
            UpdateInterrupt();
        }

        /// <summary>Simulate the watchdog timer expiring (doc sec. 1.10).</summary>
        public void ExpireWatchdog()
        {
            watchdogStatus = true;
            // Real hardware also pulses the separate watchdog_rst pin and
            // zeroes framestore/OSD/vbuf; not modeled, out of scope for
            // driver register/IRQ tests.
        }

        private uint ReadAndClearStatus()
        {
            uint value = (uint)(((matrixCoefficients & 0xffu) << 8)
                | (watchdogStatus ? (1u << 7) : 0)
                | (osdWrEn ? (1u << 6) : 0)
                | (osdWrAck ? (1u << 5) : 0)
                | (osdWrFull ? (1u << 4) : 0)
                | (pictureHdr ? (1u << 3) : 0)
                | (frameEnd ? (1u << 2) : 0)
                | (videoCh ? (1u << 1) : 0)
                | (error ? 1u : 0));

            // Doc sec. 1.5/1.9: all of the above (except matrix_coefficients,
            // which is not read-to-clear) are cleared whenever status is read.
            watchdogStatus = false;
            osdWrEn = false;
            osdWrAck = false;
            osdWrFull = false;
            pictureHdr = false;
            frameEnd = false;
            videoCh = false;
            error = false;
            UpdateInterrupt();

            return value;
        }

        private void WriteStream(uint value)
        {
            watchdogInterval = (byte)((value & WatchdogIntervalMask) >> WatchdogIntervalShift);
            osdEnable = (value & OsdEnableBit) != 0;
            pictureHdrIntrEn = (value & PictureHdrIntrEnBit) != 0;
            frameEndIntrEn = (value & FrameEndIntrEnBit) != 0;
            videoChIntrEn = (value & VideoChIntrEnBit) != 0;
        }

        private void UpdateInterrupt()
        {
            IRQ.Set(pictureHdr || frameEnd || videoCh || error);
        }

        private static uint Pack(ushort high, uint highMask, int highShift, ushort low, uint lowMask, int lowShift)
        {
            return (uint)(((high & highMask) << highShift) | ((low & lowMask) << lowShift));
        }

        private enum ReadRegister : long
        {
            Version = 0x0,
            Status = 0x1,
            Size = 0x2,
            DisplaySize = 0x3,
            FrameRate = 0x4,
            Testpoint = 0xf,
        }

        private enum WriteRegister : long
        {
            Stream = 0x0,
            Horizontal = 0x1,
            HorizontalSync = 0x2,
            Vertical = 0x3,
            VerticalSync = 0x4,
            VideoMode = 0x5,
            OsdCltYuvm = 0x6,
            OsdCltAddr = 0x7,
            OsdDtaHigh = 0x8,
            OsdDtaLow = 0x9,
            OsdAddr = 0xa,
            TrickMode = 0xb,
            Testpoint = 0xf,
        }

        // Stream (write-bank reg 0) bit layout -- mirrors mpeg2fpga_regs.h MPEG2FPGA_STREAM_*
        private const int WatchdogIntervalShift = 8;
        private const uint WatchdogIntervalMask = 0xff00;
        private const uint OsdEnableBit = 1u << 3;
        private const uint PictureHdrIntrEnBit = 1u << 2;
        private const uint FrameEndIntrEnBit = 1u << 1;
        private const uint VideoChIntrEnBit = 1u << 0;
        private const byte WatchdogDefaultInterval = 127;

        private const uint SizeFieldMask = 0x3fff;
        private const int SizeHorizontalShift = 16;

        // Read-bank state
        private ushort version;
        private byte matrixCoefficients;
        private bool watchdogStatus;
        private bool osdWrEn;
        private bool osdWrAck;
        private bool osdWrFull;
        private bool pictureHdr;
        private bool frameEnd;
        private bool videoCh;
        private bool error;
        private ushort horizontalSize;
        private ushort verticalSize;
        private ushort displayHorizontalSize;
        private ushort displayVerticalSize;
        private byte aspectRatioInformation;
        private bool progressiveSequence;
        private byte frameRateExtensionD;
        private byte frameRateExtensionN;
        private byte frameRateCode;
        private uint testpoint;

        // Write-bank shadow state (write-only on real hardware)
        private byte watchdogInterval;
        private bool osdEnable;
        private bool pictureHdrIntrEn;
        private bool frameEndIntrEn;
        private bool videoChIntrEn;
    }
}
