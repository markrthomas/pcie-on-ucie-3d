// ============================================================================
// dv/iverilog/tb_pm.sv — M3 directed control-plane test under live loopback traffic.
//
// A MAC thread streams random frames (1..1500 B, 20% source gaps, 95%-ready sink)
// the whole time, while a CSR thread walks the control plane:
//   power cycle  L0 -> L1 -> L2 -> (L2 -> L1 -> L0)
//   speed change 64 GT/s -> 32 GT/s -> 64 GT/s (preset re-sent each time, raw mode)
//   width change x1 -> x2 -> x1
//   SPEEDCFG rewrite -> new preset reaches the remote die over the sideband
//   cancelled request: L1 requested, then L0 again while the drain is in flight
//   L0s request -> ERR[2], link stays up; W1C clear
//   link-status timeout: status muted during a speed change -> ERR[1], FSM recovers
// Checks: every frame looped back in order and byte-exact, none aborted, no Rx
// drops; the control model sees no Tx outside L0 / during a pin change; the
// powerdown history and CSR STATUS/ERR/PMCNT match the expected sequence.
// ============================================================================
`timescale 1ns/1ps
`include "pcie_ucie3d_pkg.sv"

module tb_pm;
  import pcie_ucie3d_pkg::*;
  `include "pcie_pat.svh"
  `include "loop_harness.svh"

  localparam int MAXF = 4096;

  int exp_len [0:MAXF-1];
  int sent = 0, checked = 0, errors = 0, bad;
  logic ctl_done = 1'b0;
  logic [31:0] d;

  task automatic chk(input logic c, input string msg);
    if (!c) begin $display("[%0t] FAIL: %s", $time, msg); errors++; end
  endtask

  // ---- scoreboard ----------------------------------------------------------
  always @(posedge pcie_clk) begin
    if (sink.frame_done) begin
      if (checked >= sent) begin
        $display("FAIL: unexpected extra frame"); errors++;
      end else if (sink.done_err) begin
        $display("FAIL: frame %0d aborted (tuser err)", checked); errors++;
        checked++;
      end else begin
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

  // ---- wait for the control plane to settle on a target ---------------------
  task automatic wait_state(input logic [1:0] pd, input logic [2:0] sp, input logic [1:0] wd,
                            input string what);
    int n;
    begin
      n = 0;
      d = '0;
      while (n < 40000) begin
        csr_rd(CSR_STATUS, d);
        if (d[1:0] == pd && d[4:2] == sp && d[6:5] == wd && d[11] == 1'b0) n = 1000000;
        else n++;
      end
      chk(n == 1000000, {"timeout waiting for ", what});
      chk(ucie_powerdown == pd && ucie_speed == sp && ucie_width == wd, {"UCIe pins after ", what});
    end
  endtask

  task automatic wait_sb(input int unsigned n_writes, input string what);
    int n;
    begin
      n = 0;
      while (phyc.sb_writes < n_writes && n < 40000) begin @(posedge ucie_clk); n++; end
      chk(phyc.sb_writes == n_writes, {"sideband write count after ", what});
    end
  endtask

  function automatic logic [31:0] ctrl(input logic [1:0] pd, input logic [2:0] sp, input logic [1:0] wd);
    ctrl = {25'b0, wd, sp, pd};
  endfunction

  // ---- traffic ---------------------------------------------------------------
  initial begin
    do_reset();
    wait (dut.ctrl_state == ST_ACTIVE);
    repeat (20) @(posedge pcie_clk);
    mac.gap_pct    = 20;
    sink.ready_pct = 95;
    while (!ctl_done && sent < MAXF) begin
      exp_len[sent] = $urandom_range(1500, 1);
      sent++;                               // count before send: scoreboard may see it early
      mac.send_frame(sent - 1, exp_len[sent - 1]);
    end
  end

  // ---- control sequence ---------------------------------------------------------
  initial begin
    #1;
    wait (dut.ctrl_state == ST_ACTIVE);
    wait_state(PWR_L0, SPEED_64, 2'd0, "link-up");
    wait_sb(1, "link-up");                  // one preset write at bring-up
    repeat (3000) @(posedge ucie_clk);

    // power cycle L0 -> L1 -> L2 -> L0
    csr_wr(CSR_CTRL, ctrl(PWR_L1, SPEED_64, 2'd0));
    wait_state(PWR_L1, SPEED_64, 2'd0, "L0->L1");
    repeat (50) @(posedge pcie_clk);
    chk(pcie_tready === 1'b0, "ingress closed in L1");
    chk(ucie_tx_valid === 1'b0, "no Tx in L1");
    csr_wr(CSR_CTRL, ctrl(PWR_L2, SPEED_64, 2'd0));
    wait_state(PWR_L2, SPEED_64, 2'd0, "L1->L2");
    repeat (1000) @(posedge ucie_clk);
    csr_wr(CSR_CTRL, ctrl(PWR_L0, SPEED_64, 2'd0));
    wait_state(PWR_L0, SPEED_64, 2'd0, "L2->L0");
    chk(phyc.pd_hist_n == 5 && phyc.pd_hist[1] == PWR_L1 && phyc.pd_hist[2] == PWR_L2 &&
        phyc.pd_hist[3] == PWR_L1 && phyc.pd_hist[4] == PWR_L0,
        "powerdown sequence L0,L1,L2,L1,L0");
    chk(phyc.sb_writes == 1, "no preset re-send on a power cycle");
    repeat (3000) @(posedge ucie_clk);

    // speed change 64 -> 32 -> 64 (preset re-sent each time in raw mode)
    csr_wr(CSR_CTRL, ctrl(PWR_L0, SPEED_32, 2'd0));
    wait_state(PWR_L0, SPEED_32, 2'd0, "speed 64->32");
    wait_sb(2, "speed 64->32");
    csr_wr(CSR_CTRL, ctrl(PWR_L0, SPEED_64, 2'd0));
    wait_state(PWR_L0, SPEED_64, 2'd0, "speed 32->64");
    wait_sb(3, "speed 32->64");
    chk(phyc.speed_changes == 2, "two speed changes seen by the remote die");
    repeat (2000) @(posedge ucie_clk);

    // width change x1 -> x2 -> x1
    csr_wr(CSR_CTRL, ctrl(PWR_L0, SPEED_64, 2'd1));
    wait_state(PWR_L0, SPEED_64, 2'd1, "width 0->1");
    repeat (2000) @(posedge ucie_clk);
    csr_wr(CSR_CTRL, ctrl(PWR_L0, SPEED_64, 2'd0));
    wait_state(PWR_L0, SPEED_64, 2'd0, "width 1->0");
    chk(phyc.width_changes == 2, "two width changes seen by the remote die");
    chk(phyc.sb_writes == 3, "no preset re-send on a width change");

    // SPEEDCFG rewrite (bits [7:6] masked off)
    csr_wr(CSR_SPEEDCFG, 32'hF5);
    wait_sb(4, "SPEEDCFG write");
    repeat (4) @(posedge ucie_clk);
    chk(phyc.last_sb_addr == SB_ADDR_TX_PRESET && phyc.last_sb_data == 8'h35,
        "SPEEDCFG value at the remote die (reserved bits masked)");
    csr_rd(CSR_SPEEDCFG, d);
    chk(d === 32'h35, "SPEEDCFG reads back with [7:6] = 0");
    wait_state(PWR_L0, SPEED_64, 2'd0, "SPEEDCFG write");
    repeat (2000) @(posedge ucie_clk);

    // cancelled request: L1 requested, then L0 again before the drain completes
    wait (dut.u_tx_egress.busy === 1'b1);   // a flit is in flight, so the drain takes time
    csr_wr(CSR_CTRL, ctrl(PWR_L1, SPEED_64, 2'd0));
    wait (dut.ctrl_state == ST_DRAIN);
    csr_wr(CSR_CTRL, ctrl(PWR_L0, SPEED_64, 2'd0));
    wait_state(PWR_L0, SPEED_64, 2'd0, "cancelled L1 request");
    chk(phyc.pd_hist_n == 5, "cancelled L1 request caused no powerdown change");
    repeat (2000) @(posedge ucie_clk);

    // L0s is unsupported
    csr_wr(CSR_CTRL, ctrl(PWR_L0S, SPEED_64, 2'd0));
    repeat (20) @(posedge ucie_clk);
    csr_rd(CSR_ERR, d);
    chk(d[2] == 1'b1, "ERR[2] set on an L0s request");
    chk(ucie_powerdown == PWR_L0 && dut.ctrl_state == ST_ACTIVE, "L0s request keeps the link in L0");
    csr_wr(CSR_CTRL, ctrl(PWR_L0, SPEED_64, 2'd0));
    repeat (5) @(posedge ucie_clk);
    csr_wr(CSR_ERR, 32'h4);
    csr_rd(CSR_ERR, d);
    chk(d == 32'h0, "ERR W1C clears");

    // link-status timeout during a speed change
    phyc.mute_status = 1'b1;
    csr_wr(CSR_CTRL, ctrl(PWR_L0, SPEED_32, 2'd0));
    wait_state(PWR_L0, SPEED_32, 2'd0, "muted speed change");
    phyc.mute_status = 1'b0;
    csr_rd(CSR_ERR, d);
    chk(d[1] == 1'b1, "ERR[1] link-status timeout flagged");
    csr_wr(CSR_ERR, 32'h2);
    csr_wr(CSR_CTRL, ctrl(PWR_L0, SPEED_64, 2'd0));
    wait_state(PWR_L0, SPEED_64, 2'd0, "speed restore after timeout");
    wait_sb(6, "speed restore");
    csr_rd(CSR_ERR, d);
    chk(d == 32'h0, "no further errors after recovery");

    // ops: link-up 2, L1/L2/L1/L0 4, speed x2 + preset x2 4, width x2 2, preset 1,
    //      timeout speed + preset 2, restore speed + preset 2 = 17
    csr_rd(CSR_PMCNT, d);
    chk(d == 32'd17, "PMCNT == 17 completed control operations");
    chk(phyc.sb_writes == 6, "six preset sideband writes total");
    repeat (2000) @(posedge ucie_clk);
    ctl_done = 1'b1;
  end

  // ---- end of test ---------------------------------------------------------------
  initial begin
    wait (ctl_done === 1'b1);
    fork
      begin wait (checked == sent && !pcie_tvalid); end
      begin repeat (400000) @(posedge ucie_clk); end
    join_any
    repeat (500) @(posedge ucie_clk);
    chk(checked == sent, "all frames looped back");
    chk(sink.errors == 0 && sink.err_frames == 0, "sink clean");
    chk(phy.errors == 0, "UCIe flit monitor clean");
    chk(phyc.errors == 0, "control model clean (no Tx outside L0 or during a change)");
    chk(dut.rx_dropped_flits == 0 && dut.rx_lock_errors == 0 && dut.rx_bad_flits == 0 &&
        dut.rx_aborted_frames == 0, "Rx counters zero");
    if (errors == 0)
      $display("PM PASS: %0d frames across power/speed/width/cfg changes, %0d flits, %0d UCIe pin changes",
               sent, phy.flits, phyc.pd_changes + phyc.speed_changes + phyc.width_changes);
    else
      $display("PM FAIL: %0d error(s)", errors);
    $finish;
  end

  initial begin
    #8000000;
    $display("PM FAIL: global timeout (%0d/%0d frames, state %0d)", checked, sent, dut.ctrl_state);
    $finish;
  end
endmodule
