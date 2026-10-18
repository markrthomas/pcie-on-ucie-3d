// ============================================================================
// pcie_sink_model.sv — DV-only PCIe controller sink BFM (AXI4-Stream slave) +
// checker.  ready_pct (0..100) randomly throttles tready.  Checks tkeep legality
// (full keep on non-last beats; contiguous low-aligned nonzero keep on the last
// beat), reassembles frames into wbuf[], copied to fbuf[] at tlast; frame_done
// pulses one pcie_clk with done_len and done_err (pcie_rx_tuser[0] on the tlast
// beat = frame aborted by the adapter).
// ============================================================================
`timescale 1ns/1ps
`include "pcie_ucie3d_pkg.sv"

module pcie_sink_model
  import pcie_ucie3d_pkg::*;
#(
  parameter int unsigned MAX_FRAME = 16384
) (
  input  logic                     pcie_clk,
  input  logic                     pcie_rst_n,
  input  logic                     pcie_rx_tvalid,
  output logic                     pcie_rx_tready,
  input  logic [PCIE_DATA_W-1:0]   pcie_rx_tdata,
  input  logic [PCIE_KEEP_W-1:0]   pcie_rx_tkeep,
  input  logic                     pcie_rx_tlast,
  input  logic                     pcie_rx_err      // pcie_rx_tuser[0]: frame aborted by the adapter
);
  logic [7:0] fbuf [0:MAX_FRAME-1];   // last completed frame (stable until the next tlast)
  logic [7:0] wbuf [0:MAX_FRAME-1];   // frame being assembled
  int          ready_pct  = 100;
  int          fpos       = 0;
  int unsigned frames     = 0;
  int unsigned errors     = 0;
  logic        frame_done = 1'b0;
  int          done_len   = 0;
  logic        done_err   = 1'b0;   // valid with frame_done
  int unsigned err_frames = 0;
  int          nb;
  logic        kbad;

  // throttle: drive tready after the clock edge from a random draw
  always @(posedge pcie_clk or negedge pcie_rst_n) begin
    if (!pcie_rst_n) pcie_rx_tready <= 1'b0;
    else             pcie_rx_tready <= ($urandom_range(99, 0) < ready_pct);
  end

  always @(posedge pcie_clk or negedge pcie_rst_n) begin
    if (!pcie_rst_n) begin
      fpos <= 0; frame_done <= 1'b0;
    end else begin
      frame_done <= 1'b0;
      if (pcie_rx_tvalid && pcie_rx_tready) begin
        nb = 0;
        kbad = 1'b0;
        for (int i = 0; i < PCIE_KEEP_W; i++) begin
          if (pcie_rx_tkeep[i]) begin
            nb++;
            if (i > 0 && !pcie_rx_tkeep[i-1]) kbad = 1'b1;   // non-contiguous
          end
        end
        if (nb == 0) kbad = 1'b1;
        if (!pcie_rx_tlast && nb != PCIE_KEEP_W) kbad = 1'b1;  // partial beat mid-frame
        if (kbad) begin errors++; $display("[%0t] SINK ERROR: bad tkeep %h (last=%b)", $time, pcie_rx_tkeep, pcie_rx_tlast); end
        for (int i = 0; i < PCIE_KEEP_W; i++)
          if (pcie_rx_tkeep[i] && fpos + i < MAX_FRAME) wbuf[fpos + i] = pcie_rx_tdata[8*i +: 8];
        if (!pcie_rx_tlast && pcie_rx_err) begin errors++; $display("[%0t] SINK ERROR: tuser err on a non-last beat", $time); end
        if (pcie_rx_tlast) begin
          for (int i = 0; i < fpos + nb && i < MAX_FRAME; i++) fbuf[i] <= wbuf[i];   // NBA: lands after the scoreboard read of the previous frame
          frames++;
          if (pcie_rx_err) err_frames++;
          done_err   <= pcie_rx_err;
          done_len   <= fpos + nb;
          frame_done <= 1'b1;
          fpos       = 0;
        end else begin
          fpos = fpos + nb;
        end
      end
    end
  end
endmodule
