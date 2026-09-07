#!/usr/bin/env python3
"""Bracket one full decode (the same decode_stream.decode() call server.py's
/decode uses, so capture_seconds/fps here are directly comparable to every
other measurement in this session) with two reads of perf_counters, and
report what fraction of the core_clk cycles in that window each counter
accounts for.

Core clock is fixed at 108 MHz (see decode_rate_bottleneck memory) and there
is no software-readable free-running cycle counter (mpeg2video.v's cnt_clk
is SmartDebug-probe-only), so total cycles is estimated from wall clock --
see mpeg2fpga_core.h's struct mpeg2fpga_perf_counters doc comment. dma_status
"done" alone was tried first and rejected: it fires once the *push* is no
longer backpressured, which decode_stream.py's own docstring notes returns
before the last few pictures actually finish -- decode_stream.decode()'s
settle-based capture loop is what genuinely waits for the last expected
picture.

Run on the board: python3 profile_decode.py <stream>
"""
import sys
import time

sys.path.insert(0, "/root/webserver")

import decode_stream
import decoder_control

CORE_CLK_HZ = 108_000_000


def main():
    stream_path = sys.argv[1] if len(sys.argv) > 1 else "/root/webserver/tek60.bits"
    data = open(stream_path, "rb").read()
    print("stream: %s (%d bytes)" % (stream_path, len(data)))

    control = decoder_control.open_control()
    print("backend:", control.backend)

    before = control.perf_counters()
    report = decode_stream.decode(data, on_frame=lambda cap: None,
                                   control=control, reset=False)
    after = control.perf_counters()

    print("report:", report)
    elapsed = report["capture_seconds"]
    total_cycles = CORE_CLK_HZ * elapsed
    fps = report["captured"] / elapsed if elapsed else 0.0

    print()
    print("capture_seconds: %.3f s  (%.2f fps, %d pictures)" %
          (elapsed, fps, report["captured"]))
    print("estimated core_clk cycles in window: %d (@%d MHz)" %
          (total_cycles, CORE_CLK_HZ // 1_000_000))
    print()
    print("%-20s %12s %10s" % ("counter", "delta", "% of window"))
    for key in ("disp_service_cnt", "vbr_service_cnt", "vbr_starved_cnt",
                "mem_res_valid_cnt", "write_service_cnt"):
        # 32-bit free-running counters: handle a wraparound between reads.
        delta = (after[key] - before[key]) & 0xFFFFFFFF
        pct = 100.0 * delta / total_cycles if total_cycles else 0.0
        print("%-20s %12d %9.1f%%" % (key, delta, pct))


if __name__ == "__main__":
    main()
