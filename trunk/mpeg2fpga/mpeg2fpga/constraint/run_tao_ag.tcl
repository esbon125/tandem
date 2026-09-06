set_device -family {PolarFireSoC} -die {MPFS095T} -speed {-1} -range {EXT}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/component/work/PF_CCC_C0/PF_CCC_C0_0/PF_CCC_C0_PF_CCC_C0_0_PF_CCC.v}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/component/work/PF_CCC_C0/PF_CCC_C0.v}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2/xfifo_sc.v}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2/xilinx_fifo144.v}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2/xilinx_fifo216.v}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2/xilinx_fifo.v}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2/xilinx_fifo_sc.v}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2/wrappers.v}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2/read_write.v}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2/synchronizer.v}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/component/work/fifo_mem_req_dc_88x64/fifo_mem_req_dc_88x64_0/rtl/vlog/core/corefifo_graytobinconv.v}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/component/work/fifo_mem_req_dc_88x64/fifo_mem_req_dc_88x64_0/rtl/vlog/core/corefifo_nstagessync.v}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/component/work/fifo_mem_req_dc_88x64/fifo_mem_req_dc_88x64_0/rtl/vlog/core/corefifo_async.v}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/component/work/fifo_mem_req_dc_88x64/fifo_mem_req_dc_88x64_0/rtl/vlog/core/corefifo_fwft.v}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/component/work/fifo_mem_req_dc_88x64/fifo_mem_req_dc_88x64_0/rtl/vlog/core/fifo_mem_req_dc_88x64_fifo_mem_req_dc_88x64_0_LSRAM_top.v}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/component/work/fifo_mem_req_dc_88x64/fifo_mem_req_dc_88x64_0/rtl/vlog/core/fifo_mem_req_dc_88x64_fifo_mem_req_dc_88x64_0_ram_wrapper.v}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/component/work/fifo_mem_req_dc_88x64/fifo_mem_req_dc_88x64_0/rtl/vlog/core/corefifo_sync_scntr.v}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/component/work/fifo_mem_req_dc_88x64/fifo_mem_req_dc_88x64_0/rtl/vlog/core/corefifo_sync.v}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/component/work/fifo_mem_req_dc_88x64/fifo_mem_req_dc_88x64_0/rtl/vlog/core/COREFIFO.v}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/component/work/fifo_mem_req_dc_88x64/fifo_mem_req_dc_88x64.v}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/component/work/fifo_mem_rsp_dc_64x128/fifo_mem_rsp_dc_64x128_0/rtl/vlog/core/corefifo_graytobinconv.v}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/component/work/fifo_mem_rsp_dc_64x128/fifo_mem_rsp_dc_64x128_0/rtl/vlog/core/corefifo_nstagessync.v}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/component/work/fifo_mem_rsp_dc_64x128/fifo_mem_rsp_dc_64x128_0/rtl/vlog/core/corefifo_async.v}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/component/work/fifo_mem_rsp_dc_64x128/fifo_mem_rsp_dc_64x128_0/rtl/vlog/core/corefifo_fwft.v}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/component/work/fifo_mem_rsp_dc_64x128/fifo_mem_rsp_dc_64x128_0/rtl/vlog/core/fifo_mem_rsp_dc_64x128_fifo_mem_rsp_dc_64x128_0_LSRAM_top.v}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/component/work/fifo_mem_rsp_dc_64x128/fifo_mem_rsp_dc_64x128_0/rtl/vlog/core/fifo_mem_rsp_dc_64x128_fifo_mem_rsp_dc_64x128_0_ram_wrapper.v}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/component/work/fifo_mem_rsp_dc_64x128/fifo_mem_rsp_dc_64x128_0/rtl/vlog/core/corefifo_sync_scntr.v}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/component/work/fifo_mem_rsp_dc_64x128/fifo_mem_rsp_dc_64x128_0/rtl/vlog/core/corefifo_sync.v}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/component/work/fifo_mem_rsp_dc_64x128/fifo_mem_rsp_dc_64x128_0/rtl/vlog/core/COREFIFO.v}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/component/work/fifo_mem_rsp_dc_64x128/fifo_mem_rsp_dc_64x128.v}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/component/work/fifo_pixel_stream_dc_35x1024/fifo_pixel_stream_dc_35x1024_0/rtl/vlog/core/corefifo_graytobinconv.v}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/component/work/fifo_pixel_stream_dc_35x1024/fifo_pixel_stream_dc_35x1024_0/rtl/vlog/core/corefifo_nstagessync.v}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/component/work/fifo_pixel_stream_dc_35x1024/fifo_pixel_stream_dc_35x1024_0/rtl/vlog/core/corefifo_async.v}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/component/work/fifo_pixel_stream_dc_35x1024/fifo_pixel_stream_dc_35x1024_0/rtl/vlog/core/corefifo_fwft.v}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/component/work/fifo_pixel_stream_dc_35x1024/fifo_pixel_stream_dc_35x1024_0/rtl/vlog/core/fifo_pixel_stream_dc_35x1024_fifo_pixel_stream_dc_35x1024_0_LSRAM_top.v}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/component/work/fifo_pixel_stream_dc_35x1024/fifo_pixel_stream_dc_35x1024_0/rtl/vlog/core/fifo_pixel_stream_dc_35x1024_fifo_pixel_stream_dc_35x1024_0_ram_wrapper.v}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/component/work/fifo_pixel_stream_dc_35x1024/fifo_pixel_stream_dc_35x1024_0/rtl/vlog/core/corefifo_sync_scntr.v}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/component/work/fifo_pixel_stream_dc_35x1024/fifo_pixel_stream_dc_35x1024_0/rtl/vlog/core/corefifo_sync.v}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/component/work/fifo_pixel_stream_dc_35x1024/fifo_pixel_stream_dc_35x1024_0/rtl/vlog/core/COREFIFO.v}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/component/work/fifo_pixel_stream_dc_35x1024/fifo_pixel_stream_dc_35x1024.v}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/hdl/generic_dpram.v}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/hdl/generic_fifo_dc.v}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2/xfifo_dc.v}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2/xilinx_fifo_dc.v}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2/framestore_request.v}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2/framestore_response.v}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2/framestore.v}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2/getbits.v}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2/idct.v}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2/iquant.v}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2/mixer.v}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2/fwft.v}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2/mem_addr.v}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2/motcomp_motvec.v}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2/motcomp_picbuf.v}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2/motcomp_addrgen.v}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2/motcomp_dcttype.v}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2/motcomp_recon.v}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2/motcomp.v}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2/osd.v}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2/pixel_queue.v}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2/probe.v}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2/regfile.v}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2/resample_addrgen.v}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2/resample_bilinear.v}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2/resample_dta.v}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2/resample.v}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2/reset.v}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2/rld.v}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2/syncgen.v}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2/syncgen_intf.v}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2/vbuf.v}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2/vld.v}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2/watchdog.v}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2/yuv2rgb.v}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
 add_include_path  {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/rtl/mpeg2/mpeg2video.v}
read_verilog -mode system_verilog {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/hdl/top.v}
set_top_level {top}
read_sdc -component {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/component/work/PF_CCC_C0/PF_CCC_C0_0/PF_CCC_C0_PF_CCC_C0_0_PF_CCC.sdc}
read_sdc -component {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/component/work/fifo_mem_req_dc_88x64/fifo_mem_req_dc_88x64_0/fifo_mem_req_dc_88x64_fifo_mem_req_dc_88x64_0_COREFIFO.sdc}
read_sdc -component {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/component/work/fifo_mem_rsp_dc_64x128/fifo_mem_rsp_dc_64x128_0/fifo_mem_rsp_dc_64x128_fifo_mem_rsp_dc_64x128_0_COREFIFO.sdc}
read_sdc -component {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/component/work/fifo_pixel_stream_dc_35x1024/fifo_pixel_stream_dc_35x1024_0/fifo_pixel_stream_dc_35x1024_fifo_pixel_stream_dc_35x1024_0_COREFIFO.sdc}
derive_constraints
write_sdc {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/constraint/top_derived_constraints.sdc}
write_ndc {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/constraint/top_derived_constraints.ndc}
write_pdc {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/constraint/fp/top_derived_constraints.pdc}
