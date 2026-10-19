// ============================================================================
// formal/ingress_gate_fv.sv — PCIe ingress drain gate (tx_ingress_gate),
// black-box, pcie_clk domain.  stop_req / fifo_full / pcie_tvalid / pcie_tlast
// are free (the PCIe source is constrained to AXI4-S: a beat is held until
// accepted).  stop_s1/stop_s2 and in_frame are shadow-rebuilt from ports exactly
// as the gate builds them, so the proof needs no hierarchical reference.
//   F-IG1  never accept a beat while the CDC FIFO is full
//   F-IG2  a frame that has started is never blocked except by fifo_full
//   F-IG3  once stop has propagated (stop_s2) and we are between frames, no new
//          beat is accepted
//   F-IG4  `stopped` is only reported between frames, and only while stopping
// ============================================================================
module ingress_gate_fv (
  input logic clk, rst_n, stop_req, fifo_full, pcie_tvalid, pcie_tlast
);
  logic pcie_tready, stopped;
  tx_ingress_gate dut (
    .pcie_clk(clk), .pcie_rst_n(rst_n), .stop_req(stop_req), .fifo_full(fifo_full),
    .pcie_tvalid(pcie_tvalid), .pcie_tlast(pcie_tlast), .pcie_tready(pcie_tready), .stopped(stopped));

  logic f_past = 1'b0;
  always @(posedge clk) f_past <= 1'b1;

  // shadow frame state + stop synchroniser (from ports only; identical to the gate)
  logic       in_frame, vld_q, rdy_q, last_q;
  logic       stop_s1, stop_s2;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      in_frame <= 1'b0; {stop_s2, stop_s1} <= 2'b11; vld_q <= 1'b0; rdy_q <= 1'b0; last_q <= 1'b0;
    end else begin
      if (pcie_tvalid && pcie_tready) in_frame <= !pcie_tlast;
      {stop_s2, stop_s1} <= {stop_s1, stop_req};
      vld_q <= pcie_tvalid; rdy_q <= pcie_tready; last_q <= pcie_tlast;
    end
  end

  always @(*) begin
    if (!f_past) assume (!rst_n); else assume (rst_n);
    // AXI4-S source: a presented beat stays until accepted (tlast stable too)
    if (f_past && vld_q && !rdy_q) assume (pcie_tvalid && pcie_tlast == last_q);
  end

  always @(*) if (f_past && rst_n) begin
    a_fig1_no_accept_full: assert (!(pcie_tready && fifo_full));
    a_fig2_frame_finishes: assert (!(in_frame && !fifo_full) || pcie_tready);
    a_fig3_no_new_frame:   assert (!(stop_s2 && !in_frame) || !pcie_tready);
  end
  always @(posedge clk) if (f_past && rst_n && $past(rst_n)) begin
    a_fig4_stopped_between: assert (!stopped || ($past(!in_frame) && $past(stop_s2)));
  end

  always @(posedge clk) if (f_past && rst_n) begin
    c_stop_after_frame: cover (stopped && $past(in_frame, 2));
    c_accept_mid_stop:  cover (stop_s2 && in_frame && pcie_tvalid && pcie_tready);
  end
endmodule
