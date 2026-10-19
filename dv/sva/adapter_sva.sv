// ============================================================================
// dv/sva/adapter_sva.sv — bind-based assertions for pcie_ucie3d_adapter (PLAN §7).
// rtl/ stays assertion-free; this checker is bound into the top from here.
// Property IDs match ASSERTIONS.md.  Verilator (--assert) evaluates these in the
// dv/vlt, dv/systemc and dv/uvm environments; Icarus-12 has no concurrent-SVA
// support, so dv/iverilog and dv/cocotb do not bind them.
// Only simple implication forms + $past/$stable/$changed plus auxiliary counters
// are used, so a stock Verilator 5.0xx handles them.
// ============================================================================
`include "pcie_ucie3d_pkg.sv"

module adapter_sva
  import pcie_ucie3d_pkg::*;
(
  input logic                    pcie_clk,
  input logic                    pcie_rst_n,
  input logic                    ucie_clk,
  input logic                    ucie_rst_n,
  // PCIe ingress (source stream, pcie_clk)
  input logic                    pcie_tvalid,
  input logic                    pcie_tready,
  input logic [PCIE_DATA_W-1:0]  pcie_tdata,
  input logic [PCIE_KEEP_W-1:0]  pcie_tkeep,
  input logic                    pcie_tlast,
  // PCIe egress (adapter -> controller, pcie_clk)
  input logic                    pcie_rx_tvalid,
  input logic                    pcie_rx_tready,
  input logic [PCIE_DATA_W-1:0]  pcie_rx_tdata,
  input logic [PCIE_KEEP_W-1:0]  pcie_rx_tkeep,
  input logic                    pcie_rx_tlast,
  input logic [PCIE_USER_W-1:0]  pcie_rx_tuser,
  // UCIe-3D Tx (ucie_clk)
  input logic                    ucie_tx_valid,
  input logic                    ucie_tx_start_flit,
  // control plane (ucie_clk)
  input logic [3:0]              ctrl_state,
  input logic [1:0]              pd_v,
  input logic [SB_W-1:0]         ucie_sb_m2s,
  input logic                    sb_req,
  input logic                    sb_busy,
  input logic                    sb_done,
  input logic                    sb_timeout,
  // CDC FIFO push/pop observation
  input logic                    tx_fifo_full,
  input logic                    tx_fifo_empty,
  input logic                    tx_fifo_rinc,
  input logic                    rx_fifo_winc,
  input logic                    rx_fifo_full,
  input logic                    rx_fifo_empty,
  input logic                    rx_fifo_rinc,
  input logic [15:0]             rx_dropped_flits
);
  localparam int unsigned BW = $clog2(FLIT_BEATS) + 1;

  wire in_active = (ctrl_state == ST_ACTIVE) || (ctrl_state == ST_DRAIN);

  // ---- auxiliary state (ucie_clk) ------------------------------------------
  logic [BW-1:0] beat_q;     // position inside the current Tx flit (0 = between flits)
  logic [3:0]    sb_cnt_q;   // cycles the sideband master has been busy (0 = first busy cycle)

  always_ff @(posedge ucie_clk or negedge ucie_rst_n) begin
    if (!ucie_rst_n) begin
      beat_q   <= '0;
      sb_cnt_q <= '0;
    end else begin
      if (ucie_tx_start_flit)   beat_q <= BW'(1);
      else if (ucie_tx_valid)   beat_q <= (int'(beat_q) == FLIT_BEATS - 1) ? '0 : beat_q + BW'(1);
      sb_cnt_q <= !sb_busy ? 4'd0 : (sb_cnt_q == 4'd15 ? sb_cnt_q : sb_cnt_q + 4'd1);
    end
  end

  // ============================= pcie_clk domain ==============================
  // A1: egress beat held (valid + payload) until the sink accepts it
  a_a1_rx_stable: assert property (@(posedge pcie_clk) disable iff (!pcie_rst_n)
    pcie_rx_tvalid && !pcie_rx_tready |=> pcie_rx_tvalid &&
      $stable(pcie_rx_tdata) && $stable(pcie_rx_tkeep) && $stable(pcie_rx_tlast) && $stable(pcie_rx_tuser));
  // A1b (environment check): the PCIe source holds its beat until accepted
  a_a1_tx_src_stable: assert property (@(posedge pcie_clk) disable iff (!pcie_rst_n)
    pcie_tvalid && !pcie_tready |=> pcie_tvalid &&
      $stable(pcie_tdata) && $stable(pcie_tkeep) && $stable(pcie_tlast));
  // A2: egress tkeep nonzero, contiguous from byte 0, all-ones except on tlast
  a_a2_rx_keep: assert property (@(posedge pcie_clk) disable iff (!pcie_rst_n)
    pcie_rx_tvalid |-> (pcie_rx_tkeep != '0) && ((pcie_rx_tkeep & (pcie_rx_tkeep + 1'b1)) == '0) &&
                       (pcie_rx_tlast || (&pcie_rx_tkeep)));
  // A2b: tuser[0] (abort/err, D9) only on a tlast beat; the rest of tuser is zero
  a_a2_rx_tuser: assert property (@(posedge pcie_clk) disable iff (!pcie_rst_n)
    pcie_rx_tvalid |-> (pcie_rx_tuser[PCIE_USER_W-1:1] == '0) && (!pcie_rx_tuser[0] || pcie_rx_tlast));
  // A6 (pcie side): ingress never accepts into a full Tx CDC FIFO; egress never pops an empty Rx CDC FIFO
  a_a6_tx_no_overflow: assert property (@(posedge pcie_clk) disable iff (!pcie_rst_n)
    pcie_tvalid && pcie_tready |-> !tx_fifo_full);
  a_a6_rx_no_underflow: assert property (@(posedge pcie_clk) disable iff (!pcie_rst_n)
    rx_fifo_rinc |-> !rx_fifo_empty);

  // ============================= ucie_clk domain ==============================
  // A3: Tx beats only in L0 and only while the link is ACTIVE/DRAIN (no Tx in low power / mid-change)
  a_a3_tx_only_l0: assert property (@(posedge ucie_clk) disable iff (!ucie_rst_n)
    ucie_tx_valid |-> (pd_v == PWR_L0) && in_active);
  // A4: start_flit only on a valid beat at a flit boundary; a flit is FLIT_BEATS contiguous valid beats
  a_a4_sf_boundary: assert property (@(posedge ucie_clk) disable iff (!ucie_rst_n)
    ucie_tx_start_flit |-> ucie_tx_valid && (beat_q == '0));
  a_a4_flit_contiguous: assert property (@(posedge ucie_clk) disable iff (!ucie_rst_n)
    (beat_q != '0) |-> ucie_tx_valid && !ucie_tx_start_flit);
  a_a4_no_headless: assert property (@(posedge ucie_clk) disable iff (!ucie_rst_n)
    ucie_tx_valid && !ucie_tx_start_flit |-> (beat_q != '0));
  // A5: sideband — one transaction outstanding; done/timeout follow a busy wait and never coincide
  a_a5_one_outstanding: assert property (@(posedge ucie_clk) disable iff (!ucie_rst_n)
    sb_req |-> !sb_busy);
  a_a5_done_excl: assert property (@(posedge ucie_clk) disable iff (!ucie_rst_n)
    !(sb_done && sb_timeout));
  a_a5_done_after_busy: assert property (@(posedge ucie_clk) disable iff (!ucie_rst_n)
    (sb_done || sb_timeout) |-> $past(sb_busy));
  // A5b: m2s byte framing — idle 8'h00 when not busy; {SB_WR,0}, addr[hi], addr[lo] on the first
  //   three busy cycles (the data byte is dynamic, so it is checked in formal/ctrl.sby).
  a_a5_m2s_idle: assert property (@(posedge ucie_clk) disable iff (!ucie_rst_n)
    !sb_busy |-> ucie_sb_m2s == 8'h00);
  a_a5_m2s_byte0: assert property (@(posedge ucie_clk) disable iff (!ucie_rst_n)
    sb_busy && (sb_cnt_q == 4'd0) |-> ucie_sb_m2s == {SB_WR, 4'h0});
  a_a5_m2s_byte1: assert property (@(posedge ucie_clk) disable iff (!ucie_rst_n)
    sb_busy && (sb_cnt_q == 4'd1) |-> ucie_sb_m2s == SB_ADDR_TX_PRESET[SB_ADDR_W-1:8]);
  a_a5_m2s_byte2: assert property (@(posedge ucie_clk) disable iff (!ucie_rst_n)
    sb_busy && (sb_cnt_q == 4'd2) |-> ucie_sb_m2s == SB_ADDR_TX_PRESET[7:0]);
  // A6 (ucie side): deframer never writes a full Rx CDC FIFO; framer never pops an empty Tx CDC FIFO
  a_a6_rx_no_overflow: assert property (@(posedge ucie_clk) disable iff (!ucie_rst_n)
    rx_fifo_winc |-> !rx_fifo_full);
  a_a6_tx_no_underflow: assert property (@(posedge ucie_clk) disable iff (!ucie_rst_n)
    tx_fifo_rinc |-> !tx_fifo_empty);

  // ================================== covers ==================================
  c_link_active:  cover property (@(posedge ucie_clk) disable iff (!ucie_rst_n) ctrl_state == ST_ACTIVE);
  c_tx_flit:      cover property (@(posedge ucie_clk) disable iff (!ucie_rst_n) ucie_tx_start_flit);
  c_rx_flit:      cover property (@(posedge pcie_clk) disable iff (!pcie_rst_n)
                    pcie_rx_tvalid && pcie_rx_tready && pcie_rx_tlast);
  c_lowpwr_l1:    cover property (@(posedge ucie_clk) disable iff (!ucie_rst_n)
                    (ctrl_state == ST_LOWPWR) && (pd_v == PWR_L1));
  c_lowpwr_l2:    cover property (@(posedge ucie_clk) disable iff (!ucie_rst_n) pd_v == PWR_L2);
  c_speed_chg:    cover property (@(posedge ucie_clk) disable iff (!ucie_rst_n) ctrl_state == ST_SPEED_CHG);
  c_width_chg:    cover property (@(posedge ucie_clk) disable iff (!ucie_rst_n) ctrl_state == ST_WIDTH_CHG);
  c_sb_ack:       cover property (@(posedge ucie_clk) disable iff (!ucie_rst_n) sb_done);
  c_sb_timeout:   cover property (@(posedge ucie_clk) disable iff (!ucie_rst_n) sb_timeout);
  c_rx_drop:      cover property (@(posedge ucie_clk) disable iff (!ucie_rst_n) $changed(rx_dropped_flits));
  c_tx_fifo_full: cover property (@(posedge pcie_clk) disable iff (!pcie_rst_n) tx_fifo_full);
  c_rx_fifo_full: cover property (@(posedge ucie_clk) disable iff (!ucie_rst_n) rx_fifo_full);
endmodule : adapter_sva

bind pcie_ucie3d_adapter adapter_sva u_adapter_sva (
  .pcie_clk (pcie_clk), .pcie_rst_n (pcie_rst_n), .ucie_clk (ucie_clk), .ucie_rst_n (ucie_rst_n),
  .pcie_tvalid (pcie_tvalid), .pcie_tready (pcie_tready), .pcie_tdata (pcie_tdata),
  .pcie_tkeep (pcie_tkeep), .pcie_tlast (pcie_tlast),
  .pcie_rx_tvalid (pcie_rx_tvalid), .pcie_rx_tready (pcie_rx_tready), .pcie_rx_tdata (pcie_rx_tdata),
  .pcie_rx_tkeep (pcie_rx_tkeep), .pcie_rx_tlast (pcie_rx_tlast), .pcie_rx_tuser (pcie_rx_tuser),
  .ucie_tx_valid (ucie_tx_valid), .ucie_tx_start_flit (ucie_tx_start_flit),
  .ctrl_state (ctrl_state), .pd_v (pd_v), .ucie_sb_m2s (ucie_sb_m2s),
  .sb_req (sb_req), .sb_busy (sb_busy), .sb_done (sb_done), .sb_timeout (sb_timeout),
  .tx_fifo_full (tx_fifo_full), .tx_fifo_empty (tx_fifo_empty), .tx_fifo_rinc (tx_fifo_rinc),
  .rx_fifo_winc (rx_fifo_winc), .rx_fifo_full (rx_fifo_full), .rx_fifo_empty (rx_fifo_empty),
  .rx_fifo_rinc (rx_fifo_rinc), .rx_dropped_flits (rx_dropped_flits)
);
