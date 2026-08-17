/*
 * fake_axi_ddr_ro.v - read-only test double for the staging-buffer AXI4
 * target stream_dma.v talks to (FIC_2 side).
 *
 * Unlike bench/mem_axi_bridge/fake_axi_ddr.v (Fase 6a, single-beat only --
 * every AR always yields exactly one RDATA beat with RLAST tied high), this
 * one actually honors ARLEN: it replays ARLEN+1 beats per accepted AR
 * request, incrementing the read address by 8 bytes each beat, and only
 * asserts RLAST on the final one -- stream_dma.v's multi-beat bursts would
 * be untested against a slave that can't distinguish a 1-beat burst from a
 * 16-beat one.
 *
 * Backing store is byte-addressable (not word-addressable like
 * fake_axi_ddr.v's) so the testbench can preload an arbitrary byte pattern
 * and compare stream_dma's output against it byte-for-byte without an
 * endianness translation step. Only the low 20 bits of the address are used
 * to index it (1 MB) -- plenty for directed tests, and independent of
 * whatever STAGING_BASE the DUT is instantiated with.
 */

`include "timescale.v"

module fake_axi_ddr_ro (
    clk, rst,
    m_axi_araddr, m_axi_arlen, m_axi_arvalid, m_axi_arready,
    m_axi_rdata, m_axi_rresp, m_axi_rlast, m_axi_rvalid, m_axi_rready
);

  input        clk;
  input        rst;

  input [37:0] m_axi_araddr;
  input  [7:0] m_axi_arlen;
  input        m_axi_arvalid;
  output reg   m_axi_arready;

  output reg [63:0] m_axi_rdata;
  output reg  [1:0] m_axi_rresp;
  output reg        m_axi_rlast;
  output reg        m_axi_rvalid;
  input             m_axi_rready;

  reg [7:0] mem [0:1048575];

  localparam [2:0] AR_LATENCY = 3'd4;
  localparam [2:0] R_LATENCY  = 3'd2;   /* per-beat latency */

  localparam [1:0] ARS_IDLE = 2'd0, ARS_WAIT = 2'd1, ARS_DRAIN = 2'd2;
  reg  [1:0]  ar_state;
  reg  [2:0]  ar_cnt;

  localparam [1:0] RS_IDLE = 2'd0, RS_DELAY = 2'd1, RS_RVALID = 2'd2;
  reg  [1:0]  r_state;
  reg  [2:0]  r_cnt;
  reg  [19:0] cur_addr;
  reg  [7:0]  beats_left;   /* beats remaining in this burst, incl. the one being sent */

  always @(posedge clk)
    if (~rst) begin
      ar_state <= ARS_IDLE;
      m_axi_arready <= 1'b0;
      r_state <= RS_IDLE;
      m_axi_rvalid <= 1'b0;
      m_axi_rdata  <= 64'b0;
      m_axi_rresp  <= 2'b00;
      m_axi_rlast  <= 1'b0;
      cur_addr     <= 20'b0;
      beats_left   <= 8'b0;
    end else begin
      m_axi_arready <= 1'b0;

      case (ar_state)
        ARS_IDLE: if (m_axi_arvalid && (r_state == RS_IDLE)) begin
          ar_cnt   <= AR_LATENCY;
          ar_state <= ARS_WAIT;
        end
        ARS_WAIT: if (ar_cnt == 0) begin
          m_axi_arready <= 1'b1;
          cur_addr      <= m_axi_araddr[19:0];
          beats_left    <= m_axi_arlen + 8'd1;
          ar_state      <= ARS_DRAIN;
        end else ar_cnt <= ar_cnt - 3'd1;
        ARS_DRAIN: if (~m_axi_arvalid) ar_state <= ARS_IDLE;
      endcase

      case (r_state)
        RS_IDLE: if (m_axi_arready) begin
          r_cnt   <= R_LATENCY;
          r_state <= RS_DELAY;
        end
        RS_DELAY: if (r_cnt == 0) begin
          m_axi_rdata  <= {mem[cur_addr+20'd7], mem[cur_addr+20'd6], mem[cur_addr+20'd5], mem[cur_addr+20'd4],
                            mem[cur_addr+20'd3], mem[cur_addr+20'd2], mem[cur_addr+20'd1], mem[cur_addr+20'd0]};
          m_axi_rresp  <= 2'b00;
          m_axi_rlast  <= (beats_left == 8'd1);
          m_axi_rvalid <= 1'b1;
          r_state      <= RS_RVALID;
        end else r_cnt <= r_cnt - 3'd1;
        RS_RVALID: if (m_axi_rvalid && m_axi_rready) begin
          m_axi_rvalid <= 1'b0;
          if (beats_left == 8'd1) begin
            r_state <= RS_IDLE;
          end else begin
            cur_addr   <= cur_addr + 20'd8;
            beats_left <= beats_left - 8'd1;
            r_cnt      <= R_LATENCY;
            r_state    <= RS_DELAY;
          end
        end
      endcase
    end

  task preload_byte;
    input [19:0] addr;
    input [7:0]  data;
    begin
      mem[addr] = data;
    end
  endtask

endmodule
/* not truncated */
