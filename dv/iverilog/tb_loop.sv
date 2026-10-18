// ============================================================================
// dv/iverilog/tb_loop.sv — M2 Config-1 loopback: PCIe -> adapter Tx -> UCIe-3D
// (Tx looped to Rx of the same DUT) -> adapter Rx -> PCIe.  Directed length
// corners (1/31/32/33/239/240/241/480/...), then random lengths, first
// back-to-back, then with random source gaps and a throttled sink (90% ready).
// ucie_phy_model passively checks the UCIe Tx flit stream; pcie_sink_model
// reassembles the looped-back PCIe frames, which must equal the frames sent
// (in order, byte-for-byte).  M2 has no control plane, so the datapath is always
// enabled and the UCIe loop is permanently "up".
// ============================================================================
`timescale 1ns/1ps
`include "pcie_ucie3d_pkg.sv"

module tb_loop;
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

  wire                     pcie_rx_tvalid, pcie_rx_tready, pcie_rx_tlast;
  wire [PCIE_DATA_W-1:0]   pcie_rx_tdata;
  wire [PCIE_KEEP_W-1:0]   pcie_rx_tkeep;
  wire [PCIE_USER_W-1:0]   pcie_rx_tuser;

  wire [UCIE_BUS_W-1:0]    ucie_tx_data;
  wire                     ucie_tx_valid, ucie_tx_start_flit;
  ucie_pwr_e               ucie_powerdown;
  ucie_speed_e             ucie_speed;
  wire [1:0]               ucie_width;
  wire [SB_W-1:0]          sb_m2s;

  // C1 loopback: the UCIe-3D Tx bus is wired straight back to the Rx bus.
  pcie_ucie3d_adapter dut (
    .pcie_clk(pcie_clk), .pcie_rst_n(pcie_rst_n),
    .pcie_tvalid(pcie_tvalid), .pcie_tready(pcie_tready), .pcie_tdata(pcie_tdata),
    .pcie_tkeep(pcie_tkeep), .pcie_tlast(pcie_tlast), .pcie_tuser(pcie_tuser),
    .pcie_rx_tvalid(pcie_rx_tvalid), .pcie_rx_tready(pcie_rx_tready), .pcie_rx_tdata(pcie_rx_tdata),
    .pcie_rx_tkeep(pcie_rx_tkeep), .pcie_rx_tlast(pcie_rx_tlast), .pcie_rx_tuser(pcie_rx_tuser),
    .ucie_clk(ucie_clk), .ucie_rst_n(ucie_rst_n),
    .ucie_tx_data(ucie_tx_data), .ucie_tx_valid(ucie_tx_valid), .ucie_tx_start_flit(ucie_tx_start_flit),
    .ucie_rx_data(ucie_tx_data), .ucie_rx_valid(ucie_tx_valid), .ucie_rx_start_flit(ucie_tx_start_flit),
    .ucie_speed(ucie_speed), .ucie_width(ucie_width), .ucie_powerdown(ucie_powerdown),
    .ucie_link_status(1'b1), .ucie_rx_active(1'b1), .ucie_rx_elec_idle(1'b0),
    .ucie_sb_m2s(sb_m2s), .ucie_sb_s2m(8'h00),
    .csr_valid(1'b0), .csr_write(1'b0), .csr_addr('0), .csr_wdata('0), .csr_rdata()
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

  pcie_sink_model sink (
    .pcie_clk(pcie_clk), .pcie_rst_n(pcie_rst_n), .pcie_rx_tvalid(pcie_rx_tvalid),
    .pcie_rx_tready(pcie_rx_tready), .pcie_rx_tdata(pcie_rx_tdata),
    .pcie_rx_tkeep(pcie_rx_tkeep), .pcie_rx_tlast(pcie_rx_tlast), .pcie_rx_err(pcie_rx_tuser[0])
  );

  always #2.5 pcie_clk = ~pcie_clk;   // 200 MHz
  always #1.0 ucie_clk = ~ucie_clk;   // 500 MHz

  // ---- scoreboard ----------------------------------------------------------
  int exp_len [0:N-1];
  int unsigned exp_flits = 0;
  int errors = 0;
  int checked = 0;
  int bad;

  always @(posedge pcie_clk) begin
    if (sink.frame_done) begin
      if (checked >= N) begin
        $display("FAIL: unexpected extra frame"); errors++;
      end else begin
        if (sink.done_err) begin
          $display("FAIL: frame %0d flagged err (aborted)", checked); errors++;
        end
        if (sink.done_len != exp_len[checked]) begin
          $display("FAIL: frame %0d length %0d, expected %0d", checked, sink.done_len, exp_len[checked]);
          errors++;
        end else begin
          bad = -1;
          for (int i = 0; i < sink.done_len; i++)
            if (bad < 0 && sink.fbuf[i] !== pat(checked, i)) bad = i;
          if (bad >= 0) begin
            $display("FAIL: frame %0d byte %0d = %02x, expected %02x",
                     checked, bad, sink.fbuf[bad], pat(checked, bad));
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
    repeat (20) @(posedge pcie_clk);

    for (int i = 0; i < N; i++) begin
      mac.gap_pct    = (i < N/2) ? 0   : 40;
      sink.ready_pct = (i < N/2) ? 100 : 90;
      mac.send_frame(i, exp_len[i]);
    end

    // drain
    fork
      begin wait (checked == N); end
      begin repeat (400000) @(posedge ucie_clk); end
    join_any
    repeat (400) @(posedge pcie_clk);

    $display("RX counters (end of run): dropped=%0d lock_err=%0d bad=%0d aborted=%0d",
             dut.rx_dropped_flits, dut.rx_lock_errors, dut.rx_bad_flits, dut.rx_aborted_frames);
    if (checked != N)           begin $display("FAIL: %0d/%0d frames received", checked, N); errors++; end
    if (phy.flits != exp_flits) begin $display("FAIL: %0d flits, expected %0d", phy.flits, exp_flits); errors++; end
    if (phy.frames != N)        begin $display("FAIL: PHY saw %0d frames, expected %0d", phy.frames, N); errors++; end
    if (phy.errors != 0)        begin $display("FAIL: %0d PHY-model error(s)", phy.errors); errors++; end
    if (sink.errors != 0)       begin $display("FAIL: %0d sink error(s)", sink.errors); errors++; end
    if (sink.err_frames != 0)   begin $display("FAIL: %0d frame(s) flagged err", sink.err_frames); errors++; end
    if (dut.rx_dropped_flits != 0 || dut.rx_lock_errors != 0 || dut.rx_bad_flits != 0 || dut.rx_aborted_frames != 0)
      begin $display("FAIL: rx dropped=%0d lock_err=%0d bad=%0d aborted=%0d", dut.rx_dropped_flits,
                     dut.rx_lock_errors, dut.rx_bad_flits, dut.rx_aborted_frames); errors++; end

    if (errors == 0)
      $display("LOOP PASS: %0d frames, %0d flits, all payloads match", N, phy.flits);
    else
      $display("LOOP FAIL: %0d error(s)", errors);
    $finish;
  end

  initial begin
    #20000000;
    $display("LOOP FAIL: global timeout (%0d/%0d frames)", checked, N);
    $finish;
  end
endmodule
