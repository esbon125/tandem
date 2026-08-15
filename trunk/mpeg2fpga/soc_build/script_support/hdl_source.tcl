#Importing and Linking all the HDL source files used in the design
import_files -library work -hdl_source hdl/apb_arbiter.v
import_files -library work -hdl_source hdl/APB_PASS_THROUGH.v
import_files -library work -sdc hdl/apb3_mpeg2fpga_bridge_cdc.sdc

# mpeg2fpga core RTL + APB bridge (Fase 5b, see docs/bringup/05_mss_apb_bridge_tdd.md)
#
# `include`-only files (no module of their own -- textual includes pulled in
# by mpeg2video.v and friends). Synplify has no include search path into
# rtl/mpeg2/ on its own; these have to be imported as project sources too,
# or `include "timescale.v"` (etc.) fails to resolve during synthesis.
import_files -library work -hdl_source ../../rtl/mpeg2/timescale.v
import_files -library work -hdl_source ../../rtl/mpeg2/fifo_size.v
import_files -library work -hdl_source ../../rtl/mpeg2/mem_codes.v
import_files -library work -hdl_source ../../rtl/mpeg2/modeline.v
import_files -library work -hdl_source ../../rtl/mpeg2/motcomp_dctcodes.v
import_files -library work -hdl_source ../../rtl/mpeg2/regfile_codes.v
import_files -library work -hdl_source ../../rtl/mpeg2/resample_codes.v
import_files -library work -hdl_source ../../rtl/mpeg2/vlc_tables.v
import_files -library work -hdl_source ../../rtl/mpeg2/vld_codes.v
import_files -library work -hdl_source ../../rtl/mpeg2/zigzag_table.v

import_files -library work -hdl_source ../../rtl/mpeg2/mpeg2video.v
import_files -library work -hdl_source ../../rtl/mpeg2/vbuf.v
import_files -library work -hdl_source ../../rtl/mpeg2/getbits.v
import_files -library work -hdl_source ../../rtl/mpeg2/vld.v
import_files -library work -hdl_source ../../rtl/mpeg2/rld.v
import_files -library work -hdl_source ../../rtl/mpeg2/iquant.v
import_files -library work -hdl_source ../../rtl/mpeg2/idct.v
import_files -library work -hdl_source ../../rtl/mpeg2/motcomp.v
import_files -library work -hdl_source ../../rtl/mpeg2/motcomp_motvec.v
import_files -library work -hdl_source ../../rtl/mpeg2/motcomp_addrgen.v
import_files -library work -hdl_source ../../rtl/mpeg2/motcomp_picbuf.v
import_files -library work -hdl_source ../../rtl/mpeg2/motcomp_dcttype.v
import_files -library work -hdl_source ../../rtl/mpeg2/motcomp_recon.v
import_files -library work -hdl_source ../../rtl/mpeg2/fwft.v
import_files -library work -hdl_source ../../rtl/mpeg2/resample.v
import_files -library work -hdl_source ../../rtl/mpeg2/resample_addrgen.v
import_files -library work -hdl_source ../../rtl/mpeg2/resample_dta.v
import_files -library work -hdl_source ../../rtl/mpeg2/resample_bilinear.v
import_files -library work -hdl_source ../../rtl/mpeg2/pixel_queue.v
import_files -library work -hdl_source ../../rtl/mpeg2/mixer.v
import_files -library work -hdl_source ../../rtl/mpeg2/syncgen.v
import_files -library work -hdl_source ../../rtl/mpeg2/syncgen_intf.v
import_files -library work -hdl_source ../../rtl/mpeg2/yuv2rgb.v
import_files -library work -hdl_source ../../rtl/mpeg2/osd.v
import_files -library work -hdl_source ../../rtl/mpeg2/regfile.v
import_files -library work -hdl_source ../../rtl/mpeg2/reset.v
import_files -library work -hdl_source ../../rtl/mpeg2/watchdog.v
import_files -library work -hdl_source ../../rtl/mpeg2/framestore.v
import_files -library work -hdl_source ../../rtl/mpeg2/framestore_request.v
import_files -library work -hdl_source ../../rtl/mpeg2/framestore_response.v
import_files -library work -hdl_source ../../rtl/mpeg2/read_write.v
import_files -library work -hdl_source ../../rtl/mpeg2/mem_addr.v
import_files -library work -hdl_source ../../rtl/mpeg2/synchronizer.v
import_files -library work -hdl_source ../../rtl/mpeg2/probe.v
import_files -library work -hdl_source ../../rtl/mpeg2/xfifo_sc.v
import_files -library work -hdl_source ../../rtl/mpeg2/xfifo_dc.v
import_files -library work -hdl_source ../../rtl/mpeg2/wrappers.v
import_files -library work -hdl_source ../../rtl/mpeg2/apb3_mpeg2fpga_bridge.v
import_files -library work -hdl_source ../../rtl/mpeg2/mpeg2fpga_apb_peripheral.v
