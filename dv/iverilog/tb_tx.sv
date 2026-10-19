// ============================================================================
// dv/iverilog/tb_tx.sv — directed Tx test: PCIe frames -> UCIe-3D raw flits.
// Directed length corners (1/31/32/33/239/240/241/480/...), then random lengths,
// first back-to-back (FIFO backpressure), then with random gaps.  Every frame is
// reassembled from the UCIe Tx flits by ucie_phy_model and compared byte-for-byte;
// the flit count is checked against ceil(len/240).  The control plane (M3) brings
// the link up (one preset sideband write) before any frame is accepted; the UCIe
// Rx bus is left idle (Tx path only — the loopback is tb_loop).
// ============================================================================
`timescale 1ns/1ps
`include "pcie_ucie3d_pkg.sv"

module tb_tx;
  import pcie_ucie3d_pkg::*;
  `include "pcie_pat.svh"

  localparam int N_DIRECTED = 15;
  localparam int N_RANDOM   = 100;
  localparam int N          = N_DIRECTED + N_RANDOM;

  logic pcie_clk = 1'b0, ucie_clk = 1'b0;
  logic pcie_rst_n, ucie_rst_n;

  wire                     pcie_tvalid, pcie_tready, pcie_tlast;
  wire [PCIE_DATA_W-1:0]   pcie_tdata;
  wire [PCIE_KEEP_W-1:0]   pcie_tkeep;
  wire [PCIE_USER_W-1:0]   pcie_tuser;
  wire [UCIE_BUS_W-1:0]    ucie_tx_data;
  wire                     ucie_tx_valid, ucie_tx_start_flit;
  ucie_pwr_e               ucie_powerdown;
  ucie_speed_e             ucie_speed;
  wire [1:0]               ucie_width;
  wire [SB_W-1:0]          sb_m2s, sb_s2m;
  wire                     link_status, rx_active, rx_elec_idle;

  pcie_ucie3d_adapter dut (
    .pcie_clk(pcie_clk), .pcie_rst_n(pcie_rst_n),
    .pcie_tvalid(pcie_tvalid), .pcie_tready(pcie_tready), .pcie_tdata(pcie_tdata),
    .pcie_tkeep(pcie_tkeep), .pcie_tlast(pcie_tlast), .pcie_tuser(pcie_tuser),
    .pcie_rx_tvalid(), .pcie_rx_tready(1'b1), .pcie_rx_tdata(), .pcie_rx_tkeep(),
    .pcie_rx_tlast(), .pcie_rx_tuser(),
    .ucie_clk(ucie_clk), .ucie_rst_n(ucie_rst_n),
    .ucie_tx_data(ucie_tx_data), .ucie_tx_valid(ucie_tx_valid), .ucie_tx_start_flit(ucie_tx_start_flit),
    .ucie_rx_data('0), .ucie_rx_valid(1'b0), .ucie_rx_start_flit(1'b0),
    .ucie_speed(ucie_speed), .ucie_width(ucie_width), .ucie_powerdown(ucie_powerdown),
    .ucie_link_status(link_status), .ucie_rx_active(rx_active), .ucie_rx_elec_idle(rx_elec_idle),
    .ucie_sb_m2s(sb_m2s), .ucie_sb_s2m(sb_s2m),
    .csr_valid(1'b0), .csr_write(1'b0), .csr_addr('0), .csr_wdata('0), .csr_rdata()
  );

  ucie_sb_model phyc (
    .ucie_clk(ucie_clk), .ucie_rst_n(ucie_rst_n),
    .powerdown(ucie_powerdown), .speed(ucie_speed), .width(ucie_width),
    .ucie_tx_valid(ucie_tx_valid), .sb_m2s(sb_m2s),
    .ucie_link_status(link_status), .ucie_rx_active(rx_active),
    .ucie_rx_elec_idle(rx_elec_idle), .sb_s2m(sb_s2m)
  );

  pcie_mac_model mac (
    .pcie_clk(pcie_clk), .pcie_tvalid(pcie_tvalid), .pcie_tready(pcie_tready),
    .pcie_tdata(pcie_tdata), .pcie_tkeep(pcie_tkeep), .pcie_tlast(pcie_tlast),
    .pcie_tuser(pcie_tuser)
  );

  ucie_phy_model phy (
    .ucie_clk(ucie_clk), .ucie_rst_n(ucie_rst_n), .ucie_tx_data(ucie_tx_data),
    .ucie_tx_valid(ucie_tx_valid), .ucie_tx_start_flit(ucie_tx_start_flit)
  );

  always #2.5 pcie_clk = ~pcie_clk;   // 200 MHz
  always #1.0 ucie_clk = ~ucie_clk;   // 500 MHz

  // ---- scoreboard ----------------------------------------------------------
  int exp_len [0:N-1];
  int unsigned exp_flits = 0;
  int errors = 0;
  int checked = 0;
  int bad;

  always @(posedge ucie_clk) begin
    if (phy.frame_done) begin
      if (checked >= N) begin
        $display("FAIL: unexpected extra frame"); errors++;
      end else begin
        if (phy.done_len != exp_len[checked]) begin
          $display("FAIL: frame %0d length %0d, expected %0d", checked, phy.done_len, exp_len[checked]);
          errors++;
        end else begin
          bad = -1;
          for (int i = 0; i < phy.done_len; i++)
            if (bad < 0 && phy.fbuf[i] !== pat(checked, i)) bad = i;
          if (bad >= 0) begin
            $display("FAIL: frame %0d byte %0d = %02x, expected %02x",
                     checked, bad, phy.fbuf[bad], pat(checked, bad));
            errors++;
          end
        end
        checked++;
      end
    end
  end

  // ---- stimulus ------------------------------------------------------------
  int dl [0:N_DIRECTED-1];
  initial begin
    dl[0]=256; dl[1]=1;    dl[2]=31;   dl[3]=32;  dl[4]=33;
    dl[5]=239; dl[6]=240;  dl[7]=241;  dl[8]=480; dl[9]=481;
    dl[10]=1500; dl[11]=4096; dl[12]=240; dl[13]=720; dl[14]=7;
  end

  initial begin
    #0;
    for (int i = 0; i < N; i++) begin
      exp_len[i] = (i < N_DIRECTED) ? dl[i] : $urandom_range(2000, 1);
      exp_flits += (exp_len[i] + FLIT_PAYLOAD_B - 1) / FLIT_PAYLOAD_B;
    end

    pcie_rst_n = 1'b0; ucie_rst_n = 1'b0;
    repeat (10) @(posedge ucie_clk);
    pcie_rst_n = 1'b1; ucie_rst_n = 1'b1;
    wait (dut.ctrl_state == ST_ACTIVE);          // link up before any frame is accepted
    repeat (20) @(posedge pcie_clk);

    for (int i = 0; i < N; i++) begin
      mac.gap_pct = (i < N/2) ? 0 : 40;
      mac.send_frame(i, exp_len[i]);
    end

    // drain
    fork
      begin wait (checked == N); end
      begin repeat (400000) @(posedge ucie_clk); end
    join_any
    repeat (200) @(posedge ucie_clk);

    if (checked != N)           begin $display("FAIL: %0d/%0d frames received", checked, N); errors++; end
    if (phy.flits != exp_flits) begin $display("FAIL: %0d flits, expected %0d", phy.flits, exp_flits); errors++; end
    if (phy.errors != 0)        begin $display("FAIL: %0d PHY-model error(s)", phy.errors); errors++; end
    if (phyc.errors != 0)       begin $display("FAIL: %0d control-model error(s)", phyc.errors); errors++; end

    if (errors == 0)
      $display("TX PASS: %0d frames, %0d flits, all payloads match", N, phy.flits);
    else
      $display("TX FAIL: %0d error(s)", errors);
    $finish;
  end

  initial begin
    #20000000;
    $display("TX FAIL: global timeout (%0d/%0d frames)", checked, N);
    $finish;
  end
endmodule
