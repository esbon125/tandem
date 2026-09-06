open_project -project {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/top/top.pro}
set_programming_file \
    -name {MPFS095T} \
    -file {/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/top/MPFS095T/top.ppd} 
enable_device \
    -name {MPFS095T} \
    -enable {1} 
set_programming_action \
    -name {MPFS095T} \
    -action {PROGRAM} 
run_selected_actions -prog_spi_flash 0 -disable_prog_design 0
save_project
close_project
