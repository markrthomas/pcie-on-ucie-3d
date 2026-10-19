// ============================================================================
// dv/iverilog/tb_ucie_b2b.sv — Config-3: UCIe-3D back-to-back (raw-mode link in
// isolation).  Two adapters are joined at the UCIe-3D bump interface — A's Tx
// mainband drives B's Rx and vice versa — so a PCIe frame entering adapter A's
// PCIe side crosses the raw-mode link and leaves adapter B's PCIe side (and the
// reverse direction concurrently).  Each adapter still brings up against its own
// local remote-die model (phycA/phycB): the sideband is point-to-point to the
// local PHY, not carried across the link.
// ============================================================================
`timescale 1ns/1ps
`include "pcie_ucie3d_pkg.sv"

module tb_ucie_b2b;
  import pcie_ucie3d_pkg::*;
  `include "pcie_pat.svh"

  logic pcie_clk = 1'b0, ucie_clk = 1'b0;
  logic rst_n;
  always #2.5 pcie_clk = ~pcie_clk;
  always #1.0 ucie_clk = ~ucie_clk;

  // --- adapter A PCIe source / B PCIe sink (A -> B direction) ----------------
  wire                   a_tv, a_tr, a_tl;  wire [PCIE_DATA_W-1:0] a_td;
  wire [PCIE_KEEP_W-1:0] a_tk;               wire [PCIE_USER_W-1:0] a_tu;
  wire                   b_rv, b_rr, b_rl;  wire [PCIE_DATA_W-1:0] b_rd;
  wire [PCIE_KEEP_W-1:0] b_rk;               wire [PCIE_USER_W-1:0] b_ru;
  // --- adapter B PCIe source / A PCIe sink (B -> A direction) ----------------
  wire                   b_tv, b_tr, b_tl;  wire [PCIE_DATA_W-1:0] b_td;
  wire [PCIE_KEEP_W-1:0] b_tk;               wire [PCIE_USER_W-1:0] b_tu;
  wire                   a_rv, a_rr, a_rl;  wire [PCIE_DATA_W-1:0] a_rd;
  wire [PCIE_KEEP_W-1:0] a_rk;               wire [PCIE_USER_W-1:0] a_ru;

  // --- UCIe-3D mainband cross-connect ----------------------------------------
  wire [UCIE_BUS_W-1:0] a2b_data, b2a_data;
  wire                  a2b_valid, a2b_sof, b2a_valid, b2a_sof;
  // --- per-adapter local sideband / status -----------------------------------
  ucie_pwr_e   a_pd, b_pd;  ucie_speed_e a_sp, b_sp;
  wire [1:0]   a_wd, b_wd;
  wire [SB_W-1:0] a_m2s, a_s2m, b_m2s, b_s2m;
  wire a_ls, a_ra, a_ei, b_ls, b_ra, b_ei;

  // tie-off unused CSR ports
  wire [31:0] a_rdata, b_rdata;

  pcie_ucie3d_adapter a (
    .pcie_clk(pcie_clk), .pcie_rst_n(rst_n),
    .pcie_tvalid(a_tv), .pcie_tready(a_tr), .pcie_tdata(a_td), .pcie_tkeep(a_tk), .pcie_tlast(a_tl), .pcie_tuser(a_tu),
    .pcie_rx_tvalid(a_rv), .pcie_rx_tready(a_rr), .pcie_rx_tdata(a_rd), .pcie_rx_tkeep(a_rk), .pcie_rx_tlast(a_rl), .pcie_rx_tuser(a_ru),
    .ucie_clk(ucie_clk), .ucie_rst_n(rst_n),
    .ucie_tx_data(a2b_data), .ucie_tx_valid(a2b_valid), .ucie_tx_start_flit(a2b_sof),
    .ucie_rx_data(b2a_data), .ucie_rx_valid(b2a_valid), .ucie_rx_start_flit(b2a_sof),
    .ucie_speed(a_sp), .ucie_width(a_wd), .ucie_powerdown(a_pd),
    .ucie_link_status(a_ls), .ucie_rx_active(a_ra), .ucie_rx_elec_idle(a_ei),
    .ucie_sb_m2s(a_m2s), .ucie_sb_s2m(a_s2m),
    .csr_valid(1'b0), .csr_write(1'b0), .csr_addr(8'h0), .csr_wdata(32'h0), .csr_rdata(a_rdata)
  );

  pcie_ucie3d_adapter b (
    .pcie_clk(pcie_clk), .pcie_rst_n(rst_n),
    .pcie_tvalid(b_tv), .pcie_tready(b_tr), .pcie_tdata(b_td), .pcie_tkeep(b_tk), .pcie_tlast(b_tl), .pcie_tuser(b_tu),
    .pcie_rx_tvalid(b_rv), .pcie_rx_tready(b_rr), .pcie_rx_tdata(b_rd), .pcie_rx_tkeep(b_rk), .pcie_rx_tlast(b_rl), .pcie_rx_tuser(b_ru),
    .ucie_clk(ucie_clk), .ucie_rst_n(rst_n),
    .ucie_tx_data(b2a_data), .ucie_tx_valid(b2a_valid), .ucie_tx_start_flit(b2a_sof),
    .ucie_rx_data(a2b_data), .ucie_rx_valid(a2b_valid), .ucie_rx_start_flit(a2b_sof),
    .ucie_speed(b_sp), .ucie_width(b_wd), .ucie_powerdown(b_pd),
    .ucie_link_status(b_ls), .ucie_rx_active(b_ra), .ucie_rx_elec_idle(b_ei),
    .ucie_sb_m2s(b_m2s), .ucie_sb_s2m(b_s2m),
    .csr_valid(1'b0), .csr_write(1'b0), .csr_addr(8'h0), .csr_wdata(32'h0), .csr_rdata(b_rdata)
  );

  ucie_sb_model phycA (
    .ucie_clk(ucie_clk), .ucie_rst_n(rst_n), .powerdown(a_pd), .speed(a_sp), .width(a_wd),
    .ucie_tx_valid(a2b_valid), .sb_m2s(a_m2s),
    .ucie_link_status(a_ls), .ucie_rx_active(a_ra), .ucie_rx_elec_idle(a_ei), .sb_s2m(a_s2m)
  );
  ucie_sb_model phycB (
    .ucie_clk(ucie_clk), .ucie_rst_n(rst_n), .powerdown(b_pd), .speed(b_sp), .width(b_wd),
    .ucie_tx_valid(b2a_valid), .sb_m2s(b_m2s),
    .ucie_link_status(b_ls), .ucie_rx_active(b_ra), .ucie_rx_elec_idle(b_ei), .sb_s2m(b_s2m)
  );

  // A -> B direction: MAC on A, sink on B
  pcie_mac_model macA (
    .pcie_clk(pcie_clk), .pcie_tvalid(a_tv), .pcie_tready(a_tr), .pcie_tdata(a_td),
    .pcie_tkeep(a_tk), .pcie_tlast(a_tl), .pcie_tuser(a_tu)
  );
  pcie_sink_model sinkB (
    .pcie_clk(pcie_clk), .pcie_rst_n(rst_n), .pcie_rx_tvalid(b_rv), .pcie_rx_tready(b_rr),
    .pcie_rx_tdata(b_rd), .pcie_rx_tkeep(b_rk), .pcie_rx_tlast(b_rl), .pcie_rx_err(b_ru[0])
  );
  // B -> A direction: MAC on B, sink on A
  pcie_mac_model macB (
    .pcie_clk(pcie_clk), .pcie_tvalid(b_tv), .pcie_tready(b_tr), .pcie_tdata(b_td),
    .pcie_tkeep(b_tk), .pcie_tlast(b_tl), .pcie_tuser(b_tu)
  );
  pcie_sink_model sinkA (
    .pcie_clk(pcie_clk), .pcie_rst_n(rst_n), .pcie_rx_tvalid(a_rv), .pcie_rx_tready(a_rr),
    .pcie_rx_tdata(a_rd), .pcie_rx_tkeep(a_rk), .pcie_rx_tlast(a_rl), .pcie_rx_err(a_ru[0])
  );

  int errors = 0, chkA = 0, chkB = 0;
  localparam int NFR = 40;
  int lenA [0:NFR-1], lenB [0:NFR-1];

  task automatic scbd(input int id, input int dir);  // dir 0=A->B (sinkB), 1=B->A (sinkA)
    int exp; int bad;
    begin
      exp = (dir == 0) ? lenA[id] : lenB[id];
      if (dir == 0) begin
        if (sinkB.done_err || sinkB.done_len != exp) begin errors++; $display("FAIL A->B frame %0d len %0d/%0d err %b", id, sinkB.done_len, exp, sinkB.done_err); end
        else begin bad=-1; for (int i=0;i<exp;i++) if (bad<0 && sinkB.fbuf[i]!==pat(id,i)) bad=i; if (bad>=0) begin errors++; $display("FAIL A->B frame %0d byte %0d", id, bad); end end
      end else begin
        if (sinkA.done_err || sinkA.done_len != exp) begin errors++; $display("FAIL B->A frame %0d len %0d/%0d err %b", id, sinkA.done_len, exp, sinkA.done_err); end
        else begin bad=-1; for (int i=0;i<exp;i++) if (bad<0 && sinkA.fbuf[i]!==pat(id,i)) bad=i; if (bad>=0) begin errors++; $display("FAIL B->A frame %0d byte %0d", id, bad); end end
      end
    end
  endtask

  always @(posedge pcie_clk) if (sinkB.frame_done) begin scbd(chkB, 0); chkB++; end
  always @(posedge pcie_clk) if (sinkA.frame_done) begin scbd(chkA, 1); chkA++; end

  initial begin
    rst_n = 1'b0;
    repeat (10) @(posedge ucie_clk);
    rst_n = 1'b1;
    wait (a.ctrl_state == ST_ACTIVE && b.ctrl_state == ST_ACTIVE);
    repeat (20) @(posedge pcie_clk);
    macA.gap_pct = 10; macB.gap_pct = 10;
    sinkA.ready_pct = 90; sinkB.ready_pct = 90;
    for (int i = 0; i < NFR; i++) begin lenA[i] = $urandom_range(1500, 1); lenB[i] = $urandom_range(1500, 1); end
    fork
      for (int i = 0; i < NFR; i++) macA.send_frame(i, lenA[i]);
      for (int i = 0; i < NFR; i++) macB.send_frame(i, lenB[i]);
    join
    fork
      begin wait (chkA == NFR && chkB == NFR); end
      begin repeat (400000) @(posedge ucie_clk); end
    join_any
    repeat (200) @(posedge pcie_clk);
    if (chkA != NFR || chkB != NFR) begin errors++; $display("FAIL: A got %0d/%0d, B got %0d/%0d", chkA, NFR, chkB, NFR); end
    if (sinkA.errors || sinkB.errors || phycA.errors || phycB.errors) begin errors++; $display("FAIL: sink/phy errors A(%0d/%0d) B(%0d/%0d)", sinkA.errors, phycA.errors, sinkB.errors, phycB.errors); end
    if (a.rx_dropped_flits || b.rx_dropped_flits || a.rx_bad_flits || b.rx_bad_flits) begin errors++; $display("FAIL: Rx drop/bad A(%0d/%0d) B(%0d/%0d)", a.rx_dropped_flits, a.rx_bad_flits, b.rx_dropped_flits, b.rx_bad_flits); end
    if (errors == 0) $display("UCIE_B2B PASS: %0d frames each way across the raw-mode link byte-exact", NFR);
    else             $display("UCIE_B2B FAIL: %0d error(s)", errors);
    $finish;
  end

  initial begin
    #6000000;
    $display("UCIE_B2B FAIL: global timeout (A %0d/%0d B %0d/%0d)", chkA, NFR, chkB, NFR);
    $finish;
  end
endmodule
