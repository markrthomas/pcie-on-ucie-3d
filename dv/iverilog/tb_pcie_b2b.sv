// ============================================================================
// dv/iverilog/tb_pcie_b2b.sv — Config-2: PCIe back-to-back (PCIe FLIT layer in
// isolation).  Two PCIe endpoints are wired directly — a pcie_mac_model source
// straight into a pcie_sink_model — with no adapter and no UCIe-3D link.  This is
// the PCIe-side AXI4-Stream FLIT interface / BFM contract baseline: frame
// framing, tkeep legality, and the shared byte pattern end-to-end, independent of
// the tunnelling datapath exercised by C1 (tb_loop/tb_scen) and C3 (tb_ucie_b2b).
// ============================================================================
`timescale 1ns/1ps
`include "pcie_ucie3d_pkg.sv"

module tb_pcie_b2b;
  import pcie_ucie3d_pkg::*;
  `include "pcie_pat.svh"

  logic pcie_clk = 1'b0;
  logic rst_n;
  always #2.5 pcie_clk = ~pcie_clk;

  wire                   tv, tr, tl;
  wire [PCIE_DATA_W-1:0] td;
  wire [PCIE_KEEP_W-1:0] tk;
  wire [PCIE_USER_W-1:0] tu;

  pcie_mac_model mac (
    .pcie_clk(pcie_clk), .pcie_tvalid(tv), .pcie_tready(tr), .pcie_tdata(td),
    .pcie_tkeep(tk), .pcie_tlast(tl), .pcie_tuser(tu)
  );
  pcie_sink_model sink (
    .pcie_clk(pcie_clk), .pcie_rst_n(rst_n), .pcie_rx_tvalid(tv), .pcie_rx_tready(tr),
    .pcie_rx_tdata(td), .pcie_rx_tkeep(tk), .pcie_rx_tlast(tl), .pcie_rx_err(tu[0])
  );

  int errors = 0, checked = 0;
  localparam int NFR = 60;
  int exp_len [0:NFR-1];

  always @(posedge pcie_clk) begin
    if (sink.frame_done) begin
      if (checked >= NFR || sink.done_err || sink.done_len != exp_len[checked]) begin
        $display("FAIL: frame %0d len %0d/%0d err %b", checked, sink.done_len,
                 (checked < NFR) ? exp_len[checked] : -1, sink.done_err);
        errors++;
      end else begin
        for (int i = 0; i < sink.done_len; i++)
          if (sink.fbuf[i] !== pat(checked, i)) begin
            $display("FAIL: frame %0d byte %0d = %02x exp %02x", checked, i, sink.fbuf[i], pat(checked, i));
            errors++;
          end
      end
      checked++;
    end
  end

  initial begin
    rst_n = 1'b0;
    repeat (5) @(posedge pcie_clk);
    rst_n = 1'b1;
    repeat (5) @(posedge pcie_clk);
    mac.gap_pct = 15; sink.ready_pct = 85;
    for (int i = 0; i < NFR; i++) begin
      exp_len[i] = (i < 5) ? (i + 1) : $urandom_range(2000, 1);  // small corners then random
    end
    for (int i = 0; i < NFR; i++) mac.send_frame(i, exp_len[i]);
    fork
      begin wait (checked == NFR); end
      begin repeat (200000) @(posedge pcie_clk); end
    join_any
    repeat (50) @(posedge pcie_clk);
    if (checked != NFR) begin errors++; $display("FAIL: got %0d/%0d frames", checked, NFR); end
    if (sink.errors || sink.err_frames) begin errors++; $display("FAIL: sink errors=%0d err_frames=%0d", sink.errors, sink.err_frames); end
    if (errors == 0) $display("PCIE_B2B PASS: %0d frames endpoint-to-endpoint byte-exact", NFR);
    else             $display("PCIE_B2B FAIL: %0d error(s)", errors);
    $finish;
  end

  initial begin
    #4000000;
    $display("PCIE_B2B FAIL: global timeout (%0d/%0d)", checked, NFR);
    $finish;
  end
endmodule
