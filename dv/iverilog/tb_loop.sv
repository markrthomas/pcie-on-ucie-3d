// ============================================================================
// dv/iverilog/tb_loop.sv — Config-1 loopback: PCIe -> adapter Tx -> UCIe-3D
// (Tx looped to Rx of the same DUT) -> adapter Rx -> PCIe.  Directed length
// corners (1/31/32/33/239/240/241/480/...), then random lengths, first
// back-to-back, then with random source gaps and a throttled sink (90% ready).
// ucie_phy_model passively checks the UCIe Tx flit stream; pcie_sink_model
// reassembles the looped-back PCIe frames, which must equal the frames sent
// (in order, byte-for-byte).  The control plane (M3) brings the link up — one
// preset sideband write — before any frame is accepted.
// ============================================================================
`timescale 1ns/1ps
`include "pcie_ucie3d_pkg.sv"

module tb_loop;
  import pcie_ucie3d_pkg::*;
  `include "pcie_pat.svh"
  `include "loop_harness.svh"

  localparam int N_DIRECTED = 15;
  localparam int N_RANDOM   = 100;
  localparam int N          = N_DIRECTED + N_RANDOM;

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

    do_reset();
    wait (dut.ctrl_state == ST_ACTIVE);          // link up before any frame is accepted
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
    if (phyc.errors != 0)       begin $display("FAIL: %0d control-model error(s)", phyc.errors); errors++; end
    if (phyc.sb_writes != 1)    begin $display("FAIL: expected one preset sideband write at link-up, saw %0d", phyc.sb_writes); errors++; end
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
