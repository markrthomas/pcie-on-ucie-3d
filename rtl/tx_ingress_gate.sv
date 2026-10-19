// ============================================================================
// tx_ingress_gate.sv — pcie_clk domain.  Closes the PCIe ingress at a frame
// boundary when the control FSM asks to drain (stop_req, from ucie_clk).
//
// pcie_tready = !fifo_full && !(stop && !in_frame): a frame already started is
// always allowed to finish; a new frame is not accepted while stopped.
// `stopped` is registered from the PREVIOUS in_frame value so it rises one
// pcie_clk after the last accepted beat was written to the CDC FIFO; the FSM
// synchronises it into ucie_clk (3 flops) so the FIFO's own empty flag has
// settled by the time it sees `stopped`.  Out of reset the gate is closed (stop=1).
// ============================================================================
module tx_ingress_gate (
  input  logic pcie_clk,
  input  logic pcie_rst_n,
  input  logic stop_req,       // async (ucie_clk domain), synchronised here
  input  logic fifo_full,
  input  logic pcie_tvalid,
  input  logic pcie_tlast,
  output logic pcie_tready,
  output logic stopped         // pcie_clk domain; synchronise before use in ucie_clk
);
  logic stop_s1, stop_s2, in_frame_q;

  always_ff @(posedge pcie_clk or negedge pcie_rst_n) begin
    if (!pcie_rst_n) {stop_s2, stop_s1} <= 2'b11;
    else             {stop_s2, stop_s1} <= {stop_s1, stop_req};
  end

  assign pcie_tready = !fifo_full && !(stop_s2 && !in_frame_q);

  always_ff @(posedge pcie_clk or negedge pcie_rst_n) begin
    if (!pcie_rst_n) begin
      in_frame_q <= 1'b0;
      stopped    <= 1'b1;
    end else begin
      if (pcie_tvalid && pcie_tready) in_frame_q <= !pcie_tlast;
      stopped <= stop_s2 && !in_frame_q;
    end
  end

endmodule : tx_ingress_gate
