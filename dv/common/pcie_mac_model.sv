// ============================================================================
// pcie_mac_model.sv — DV-only PCIe controller source BFM (AXI4-Stream master).
// send_frame(id, len) streams a frame of pattern bytes (pcie_pat.svh), honouring
// tready.  gap_pct (0..100) randomly inserts idle cycles between beats.
// null_last = 1: the frame's last data beat is sent WITHOUT tlast and the frame
// is ended by a null beat (tkeep = 0, tlast = 1); send_null_beat() sends a lone
// null tlast beat (an empty frame).  Drives with nonblocking assignments after
// posedge pcie_clk (no races).
// ============================================================================
`timescale 1ns/1ps
`include "pcie_ucie3d_pkg.sv"

module pcie_mac_model
  import pcie_ucie3d_pkg::*;
(
  input  logic                     pcie_clk,
  output logic                     pcie_tvalid,
  input  logic                     pcie_tready,
  output logic [PCIE_DATA_W-1:0]   pcie_tdata,
  output logic [PCIE_DATA_W/8-1:0] pcie_tkeep,
  output logic                     pcie_tlast,
  output logic [PCIE_USER_W-1:0]   pcie_tuser
);
  `include "pcie_pat.svh"

  int gap_pct   = 0;
  int null_last = 0;
  int beats_sent = 0;

  initial begin
    pcie_tvalid = 1'b0;
    pcie_tdata  = '0;
    pcie_tkeep  = '0;
    pcie_tlast  = 1'b0;
    pcie_tuser  = '0;
  end

  task automatic send_frame(input int id, input int len);
    int off, n;
    logic [PCIE_DATA_W-1:0]   d;
    logic [PCIE_DATA_W/8-1:0] k;
    begin
      off = 0;
      while (off < len) begin
        while (gap_pct > 0 && $urandom_range(99, 0) < gap_pct) begin
          pcie_tvalid <= 1'b0;
          @(posedge pcie_clk);
        end
        n = len - off;
        if (n > PCIE_KEEP_W) n = PCIE_KEEP_W;
        d = '0;
        k = '0;
        for (int i = 0; i < n; i++) begin
          d[8*i +: 8] = pat(id, off + i);
          k[i]        = 1'b1;
        end
        pcie_tvalid <= 1'b1;
        pcie_tdata  <= d;
        pcie_tkeep  <= k;
        pcie_tlast  <= (off + n == len) && !null_last;
        @(posedge pcie_clk);
        while (!pcie_tready) @(posedge pcie_clk);
        beats_sent++;
        off += n;
      end
      if (null_last && len > 0) send_null_beat();
      pcie_tvalid <= 1'b0;
      pcie_tlast  <= 1'b0;
    end
  endtask

  task automatic send_null_beat();
    begin
      pcie_tvalid <= 1'b1;
      pcie_tdata  <= '0;
      pcie_tkeep  <= '0;
      pcie_tlast  <= 1'b1;
      @(posedge pcie_clk);
      while (!pcie_tready) @(posedge pcie_clk);
      pcie_tvalid <= 1'b0;
      pcie_tlast  <= 1'b0;
    end
  endtask
endmodule
