//TOP Module
//ebustamante

module top (
    input        ref_clk,
    input        rst_n,
    output       led
);
assign led = busy;
wire [31:0] reg_dta_out;
wire busy;
wire error;
wire interrupt;
wire watchdog_rst;

wire [7:0] r;
wire [7:0] g;
wire [7:0] b;
wire [7:0] y;
wire [7:0] u;
wire [7:0] v;

wire pixel_en;
wire h_sync;
wire v_sync;
wire c_sync;

wire [1:0]  mem_req_rd_cmd;
wire [21:0] mem_req_rd_addr;
wire [63:0] mem_req_rd_dta;
wire        mem_req_rd_valid;

wire        mem_res_wr_almost_full;

wire [33:0] testpoint;    

mpeg2video u_mpeg2 (
    .ref_clk(ref_clk),
    .rst(rst_n),

    .stream_data(8'h00),
    .stream_valid(1'b0),

    .reg_addr(4'h0),
    .reg_wr_en(1'b0),
    .reg_dta_in(32'h0),
    .reg_rd_en(1'b0),
    .reg_dta_out(reg_dta_out),

    .busy(busy),
    .error(error),
    .interrupt(interrupt),
    .watchdog_rst(watchdog_rst),

    .r(r),
    .g(g),
    .b(b),
    .y(y),
    .u(u),
    .v(v),
    .pixel_en(pixel_en),
    .h_sync(h_sync),
    .v_sync(v_sync),
    .c_sync(c_sync),

    .mem_req_rd_cmd(mem_req_rd_cmd),
    .mem_req_rd_addr(mem_req_rd_addr),
    .mem_req_rd_dta(mem_req_rd_dta),
    .mem_req_rd_en(1'b0),
    .mem_req_rd_valid(mem_req_rd_valid),

    .mem_res_wr_dta(64'h0),
    .mem_res_wr_en(1'b0),
    .mem_res_wr_almost_full(mem_res_wr_almost_full),

    .testpoint_dip(4'h0),
    .testpoint_dip_en(1'b0),
    .testpoint(testpoint)
);

endmodule