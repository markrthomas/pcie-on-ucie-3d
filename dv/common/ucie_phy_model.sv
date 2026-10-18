// ============================================================================
// ucie_phy_model.sv — DV-only UCIe-3D PHY sink BFM + raw-mode flit monitor (Tx).
// Checks on every flit: FLIT_BEATS contiguous valid beats, start_flit only on
// beat 0, header valid bit, sof/eof sequencing, payload length <= 240, and zeroed
// padding/DLP/FEC bytes (flit format, pcie_ucie3d_pkg).  Reassembles frames into
// fbuf[]; frame_done pulses for one ucie_clk with done_len valid.
//
// With FLOW_CTRL (docs/OPEN_DECISIONS.md D16) bytes FLIT_FC_OFF..+3 carry seq/cl and
// are exempt from the zero check; a flit with count 0, sof = eof = 0 is a legal
// credit-only flit (counted in cr_flits, not flits/frames); its seq field must
// equal the number of data flits seen before it (fc_seq_err otherwise).
// ============================================================================
`timescale 1ns/1ps
`include "pcie_ucie3d_pkg.sv"

module ucie_phy_model
  import pcie_ucie3d_pkg::*;
#(
  parameter int unsigned MAX_FRAME = 16384
) (
  input  logic                   ucie_clk,
  input  logic                   ucie_rst_n,
  input  logic [UCIE_BUS_W-1:0]  ucie_tx_data,
  input  logic                   ucie_tx_valid,
  input  logic                   ucie_tx_start_flit
);
  logic [7:0] fbuf [0:MAX_FRAME-1];
  logic [FLIT_BYTES*8-1:0] fl;

  int          beat      = 0;      // beats received in the current flit
  int          fpos      = 0;      // bytes of the current frame received
  logic        in_frame  = 1'b0;
  int unsigned flits     = 0;
  int unsigned frames    = 0;
  int unsigned errors    = 0;
  int unsigned cr_flits  = 0;      // credit-only flits (FLOW_CTRL)
  int unsigned fc_sent   = 0;      // data flits since the last DUT reset (expected seq field)
  int unsigned fc_seq_err = 0;     // seq field != data flits sent before it
  logic [15:0] last_seq = '0, last_cl = '0;
  logic        frame_done = 1'b0;
  int          done_len   = 0;

  task automatic err(input string msg);
    begin
      errors++;
      $display("[%0t] PHY-MODEL ERROR: %s", $time, msg);
    end
  endtask

  int plen;
  logic hv, hsof, heof, padbad, crflit;

  always @(posedge ucie_clk or negedge ucie_rst_n) begin
    if (!ucie_rst_n) begin
      beat <= 0; fpos <= 0; in_frame <= 1'b0; frame_done <= 1'b0; fc_sent = 0;
    end else begin
      frame_done <= 1'b0;
      if (ucie_tx_start_flit && !ucie_tx_valid) err("start_flit without tx_valid");
      if (ucie_tx_valid) begin
        if (ucie_tx_start_flit && beat != 0) err("start_flit mid-flit");
        if (!ucie_tx_start_flit && beat == 0) err("flit beat 0 without start_flit");
        fl[(beat % FLIT_BEATS)*UCIE_BUS_W +: UCIE_BUS_W] = ucie_tx_data;
        if (beat == FLIT_BEATS - 1) begin
          // ---- complete flit: check + reassemble -----------------------------
          beat  <= 0;
          hv   = fl[0];
          hsof = fl[1];
          heof = fl[2];
          plen = int'(fl[15:8]);
          if (!hv) err("header valid bit clear");
          if (fl[7:3] != 5'b0) err("header reserved bits nonzero");
          if (plen > FLIT_PAYLOAD_B) err("payload length > 240");
          crflit = FLOW_CTRL && (plen == 0) && !hsof && !heof;
          if (plen == 0 && !crflit) err("empty flit emitted");
          if (!crflit && hsof !== !in_frame) err("sof/frame state mismatch");
          padbad = 1'b0;
          for (int b = FLIT_HDR_B + plen; b < FLIT_BYTES; b++)
            if (!(FLOW_CTRL && b >= FLIT_FC_OFF && b < FLIT_FC_OFF + 4) && fl[8*b +: 8] !== 8'h00) padbad = 1'b1;
          if (padbad) err("nonzero padding/DLP/FEC byte");
          if (FLOW_CTRL) begin
            last_seq = fl[8*FLIT_FC_OFF +: 16];
            last_cl  = fl[8*(FLIT_FC_OFF+2) +: 16];
            if (last_seq !== 16'(fc_sent)) begin fc_seq_err++; err("flow-control seq field != data flits sent before"); end
          end
          if (crflit) cr_flits++; else begin flits++; fc_sent++; end
          for (int b = 0; b < plen; b++)
            if (fpos + b < MAX_FRAME) fbuf[fpos + b] = fl[8*(FLIT_HDR_B + b) +: 8];
          fpos = fpos + plen;
          if (crflit) begin
            // credit-only: no frame state change
          end else if (heof) begin
            frames++;
            done_len   <= fpos;
            frame_done <= 1'b1;
            fpos       = 0;
            in_frame  <= 1'b0;
          end else begin
            in_frame  <= 1'b1;
          end
        end else begin
          beat <= beat + 1;
        end
      end else if (beat != 0) begin
        err("tx_valid dropped mid-flit");
        beat <= 0;
      end
    end
  end
endmodule
