// ============================================================================
// pcie_ucie3d_adapter.sv — TOP of the PCIe <-> UCIe-3D raw-mode adapter.
//
// STATUS: M3 — datapaths + control plane complete.
//   Tx: pcie ingress (tx_ingress_gate) -> tx_cdc (async FIFO) -> tx_framer (256B
//       flit assembly) -> tx_egress (serialise raw beats) -> ucie_tx_*.
//   Rx: ucie_rx_* -> rx_ingress (flit-lock on start_flit) -> rx_deframer ->
//       rx_cdc (async FIFO) -> pcie_egress -> pcie_rx_*.
//   Control (ucie_clk): adapter_rf (CSRs) + adapter_ctrl_fsm (link bring-up
//       SBINIT/MBINIT/PARAM, L1/L2, speed/width, drain) + ucie_sb_master (8-bit
//       sideband).  Out of reset the link is in L1; with the reset CSR values the
//       FSM trains the link, sends the Tx preset over the sideband, brings power
//       to L0, and then opens the PCIe ingress.  Datapath-local reset (D18,
//       default on) holds the datapath in reset while in L1/L2.
// Ports per docs/PLAN.md §2 plus the CSR port (now ucie_clk domain, D7).
// ============================================================================
`include "pcie_ucie3d_pkg.sv"

module pcie_ucie3d_adapter
  import pcie_ucie3d_pkg::*;
(
  // ---- PCIe / FDI side (PCIe 6 256-byte FLIT mode) --------------------------
  input  logic                     pcie_clk,
  input  logic                     pcie_rst_n,
  // ingress: PCIe controller -> adapter (AXI4-Stream-like flit stream)
  input  logic                     pcie_tvalid,
  output logic                     pcie_tready,
  input  logic [PCIE_DATA_W-1:0]   pcie_tdata,
  input  logic [PCIE_KEEP_W-1:0]   pcie_tkeep,
  input  logic                     pcie_tlast,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [PCIE_USER_W-1:0]   pcie_tuser,    // not carried (raw-mode tunnel)
  /* verilator lint_on UNUSEDSIGNAL */
  // egress: adapter -> PCIe controller
  output logic                     pcie_rx_tvalid,
  input  logic                     pcie_rx_tready,
  output logic [PCIE_DATA_W-1:0]   pcie_rx_tdata,
  output logic [PCIE_KEEP_W-1:0]   pcie_rx_tkeep,
  output logic                     pcie_rx_tlast,
  output logic [PCIE_USER_W-1:0]   pcie_rx_tuser,

  // ---- UCIe-3D physical side (raw-mode parallel bump bus) -------------------
  input  logic                     ucie_clk,
  input  logic                     ucie_rst_n,
  // Tx datapath: adapter -> remote die
  output logic [UCIE_BUS_W-1:0]    ucie_tx_data,
  output logic                     ucie_tx_valid,
  output logic                     ucie_tx_start_flit,
  // Rx datapath: remote die -> adapter
  input  logic [UCIE_BUS_W-1:0]    ucie_rx_data,
  input  logic                     ucie_rx_valid,
  input  logic                     ucie_rx_start_flit,
  // per-link control/status
  output ucie_speed_e              ucie_speed,
  output logic [1:0]               ucie_width,
  output ucie_pwr_e                ucie_powerdown,
  input  logic                     ucie_link_status,
  input  logic                     ucie_rx_active,
  input  logic                     ucie_rx_elec_idle,
  // 8-bit UCIe sideband (M2S / S2M byte channels)
  output logic [SB_W-1:0]          ucie_sb_m2s,
  input  logic [SB_W-1:0]          ucie_sb_s2m,

  // ---- CSR port (ucie_clk domain, always ready; D7) -------------------------
  input  logic                     csr_valid,
  input  logic                     csr_write,
  input  logic [CSR_ADDR_W-1:0]    csr_addr,
  input  logic [31:0]              csr_wdata,
  output logic [31:0]              csr_rdata
);

  // ---- supported lane counts: x1, x2, x4 (D1) -------------------------------
  if (UCIE_BUS_W > PCIE_DATA_W) begin : g_unsupported_lane_count
    $error("UCIE_NLANES=%0d is not supported: UCIE_BUS_W (%0d) exceeds PCIE_DATA_W (%0d); x1, x2, x4 only (D1)",
           UCIE_NLANES, UCIE_BUS_W, PCIE_DATA_W);
  end

  // ==== control-plane nets (ucie_clk) ========================================
  logic [1:0]  pwr_req, width_req, pd_v, width_v;
  logic [2:0]  speed_req, speed_v;
  logic [3:0]  ctrl_state;
  logic [7:0]  speedcfg;
  logic        cfg_wr, tx_en, ingress_stop, ingress_stopped_pcie;
  logic        stp_s1, stp_s2, stp_s3;
  logic        tx_idle, rx_idle, framer_idle, egress_busy;
  logic        rx_ing_idle, rx_dfr_idle, rx_data_done;
  logic        rx_out_idle;
  logic        sb_req, sb_busy, sb_done, sb_timeout;
  logic        ev_op_done, ev_link_timeout;
  logic        tx_st_any, tx_st_data;
  logic        tx_credit_ok, tx_cr_req;
  logic [15:0] tx_seq_now, tx_cl_now;

  // ==== Tx datapath nets ======================================================
  logic                             tx_fifo_full, tx_fifo_empty, tx_fifo_rinc;
  logic [PCIE_DATA_W+PCIE_KEEP_W:0] tx_fifo_rdata;
  logic [$clog2(FIFO_DEPTH):0]      tx_wfree_unused;
  logic                             flit_valid, flit_taken;
  logic [FLIT_BYTES*8-1:0]          flit;

  // ==== Rx datapath nets ======================================================
  logic                               rx_flit_valid, rx_flit_taken, rx_flit_gap;
  logic [FLIT_BYTES*8-1:0]            rx_flit;
  logic [PCIE_DATA_W+PCIE_KEEP_W+1:0] rx_fifo_wdata, rx_fifo_rdata;
  logic                               rx_fifo_winc, rx_fifo_full, rx_fifo_empty, rx_fifo_rinc;
  logic [15:0]                        rx_cl_remote, rx_fc_lost;
  logic [$clog2(FIFO_DEPTH):0]        rx_wfree;
  // DV-visible Rx error counters (read back via CSR_RXCNT0/1).
  logic [15:0]                        rx_dropped_flits, rx_lock_errors, rx_bad_flits, rx_aborted_frames;

  // ==== register file (CSRs) ==================================================
  adapter_rf u_rf (
    .clk (ucie_clk), .rst_n (ucie_rst_n),
    .csr_valid (csr_valid), .csr_write (csr_write), .csr_addr (csr_addr),
    .csr_wdata (csr_wdata), .csr_rdata (csr_rdata),
    .pwr_req (pwr_req), .speed_req (speed_req), .width_req (width_req),
    .speedcfg (speedcfg), .cfg_wr (cfg_wr),
    .st_powerdown (pd_v), .st_speed (speed_v), .st_width (width_v), .st_state (ctrl_state),
    .st_rx_active (ucie_rx_active), .st_rx_elec_idle (ucie_rx_elec_idle),
    .ev_op_done (ev_op_done), .ev_link_timeout (ev_link_timeout), .ev_sb_timeout (sb_timeout),
    .rx_dropped_flits (rx_dropped_flits), .rx_lock_errors (rx_lock_errors),
    .rx_bad_flits (rx_bad_flits), .rx_aborted_frames (rx_aborted_frames)
  );

  // ingress `stopped` (pcie_clk) -> ucie_clk: 3 flops so the Tx FIFO empty flag has
  // settled before the FSM sees it (see tx_ingress_gate.sv).
  always_ff @(posedge ucie_clk or negedge ucie_rst_n) begin
    if (!ucie_rst_n) {stp_s3, stp_s2, stp_s1} <= 3'b111;
    else             {stp_s3, stp_s2, stp_s1} <= {stp_s2, stp_s1, ingress_stopped_pcie};
  end

  // A drain must not be declared complete in the same cycle tx_egress would launch
  // a credit-only flit (D25): otherwise the FSM leaves ST_DRAIN and that flit is
  // transmitted in a change / config state (bound SVA a_a3_tx_only_l0 / formal
  // F-PP1).  tx_cr_req is constant 0 without FLOW_CTRL, so this is a no-op there.
  assign tx_idle = tx_fifo_empty && framer_idle && !egress_busy && !tx_cr_req;
  // With the datapath reset (default) the Rx path must also be empty before a drain
  // completes, or the reset would cut a frame on its way to the PCIe sink (D18/D11).
`ifndef DP_RESET_OFF
  assign rx_idle = rx_ing_idle && rx_out_idle;
`else
  assign rx_idle = rx_ing_idle;
`endif

  adapter_ctrl_fsm u_ctrl (
    .clk (ucie_clk), .rst_n (ucie_rst_n),
    .pwr_req (pwr_req), .speed_req (speed_req), .width_req (width_req), .cfg_wr (cfg_wr),
    .link_status (ucie_link_status), .rx_active (ucie_rx_active), .rx_elec_idle (ucie_rx_elec_idle),
    .powerdown (pd_v), .speed (speed_v), .width (width_v),
    .tx_en (tx_en), .ingress_stop (ingress_stop), .ingress_stopped (stp_s3),
    .tx_idle (tx_idle), .rx_idle (rx_idle),
    .sb_req (sb_req), .sb_done (sb_done), .sb_timeout (sb_timeout),
    .state (ctrl_state), .ev_op_done (ev_op_done), .ev_link_timeout (ev_link_timeout)
  );

  // Local copy of the pkg constant: Icarus turns a bare imported name used directly
  // in a port connection into an implicit 1-bit net.
  wire [SB_ADDR_W-1:0] sb_addr = SB_ADDR_TX_PRESET;

  ucie_sb_master u_sb (
    .clk (ucie_clk), .rst_n (ucie_rst_n),
    .req (sb_req), .addr (sb_addr), .wdata (speedcfg),
    .busy (sb_busy), .done (sb_done), .timeout (sb_timeout),
    .m2s (ucie_sb_m2s), .s2m (ucie_sb_s2m)
  );

  assign ucie_speed     = ucie_speed_e'(speed_v);
  assign ucie_width     = width_v;
  assign ucie_powerdown = ucie_pwr_e'(pd_v);

  // ---- datapath-local reset (D18; DEFAULT ON, see pcie_ucie3d_pkg.sv for switches) ---
  // From ST_LOWPWR until the next ST_DRAIN/ST_ACTIVE the datapath is held in reset; the
  // pcie_clk copy is a reset synchroniser (async assert, 2-flop release), so a power-gated
  // datapath needs no retention.  With the reset off (-DDP_RESET_DISABLE, or flow control)
  // the datapath uses ucie_rst_n / pcie_rst_n directly (textually, via the macros below).
`ifndef DP_RESET_OFF
  logic dp_low_q, dp_pcie_s1, dp_pcie_s2;
  wire  dp_ucie_rst_n = ucie_rst_n && !dp_low_q;
  wire  dp_pcie_rst_n = pcie_rst_n && dp_pcie_s2;
  always_ff @(posedge ucie_clk or negedge ucie_rst_n) begin
    if (!ucie_rst_n)                                              dp_low_q <= 1'b0;
    else if (ctrl_state == ST_LOWPWR)                            dp_low_q <= 1'b1;
    else if (ctrl_state == ST_DRAIN || ctrl_state == ST_ACTIVE)  dp_low_q <= 1'b0;
  end
  always_ff @(posedge pcie_clk or negedge dp_ucie_rst_n) begin
    if (!dp_ucie_rst_n) {dp_pcie_s2, dp_pcie_s1} <= 2'b00;
    else                {dp_pcie_s2, dp_pcie_s1} <= {dp_pcie_s1, 1'b1};
  end
`undef DP_UCIE_RST
`undef DP_PCIE_RST
`define DP_UCIE_RST dp_ucie_rst_n
`define DP_PCIE_RST dp_pcie_rst_n
`else
`undef DP_UCIE_RST
`undef DP_PCIE_RST
`define DP_UCIE_RST ucie_rst_n
`define DP_PCIE_RST pcie_rst_n
`endif

  // ==== Tx datapath: PCIe AXI-S -> gate -> CDC FIFO -> flit framer -> UCIe Tx ==
  tx_ingress_gate u_tx_gate (
    .pcie_clk (pcie_clk), .pcie_rst_n (`DP_PCIE_RST),
    .stop_req (ingress_stop), .fifo_full (tx_fifo_full),
    .pcie_tvalid (pcie_tvalid), .pcie_tlast (pcie_tlast),
    .pcie_tready (pcie_tready), .stopped (ingress_stopped_pcie)
  );

  async_fifo #(.W(PCIE_DATA_W+PCIE_KEEP_W+1), .DEPTH(FIFO_DEPTH)) u_tx_cdc (
    .wclk   (pcie_clk), .wrst_n (`DP_PCIE_RST),
    .winc   (pcie_tvalid && pcie_tready),
    .wdata  ({pcie_tlast, pcie_tkeep, pcie_tdata}),
    .wfull  (tx_fifo_full), .wfree (tx_wfree_unused),
    .rclk   (ucie_clk), .rrst_n (`DP_UCIE_RST),
    .rinc   (tx_fifo_rinc), .rdata (tx_fifo_rdata), .rempty (tx_fifo_empty)
  );

  tx_framer u_tx_framer (
    .clk (ucie_clk), .rst_n (`DP_UCIE_RST),
    .fifo_rdata (tx_fifo_rdata), .fifo_empty (tx_fifo_empty), .fifo_rinc (tx_fifo_rinc),
    .flit_valid (flit_valid), .flit (flit), .flit_taken (flit_taken), .idle (framer_idle)
  );

  // Link flow-control controller (D16): credit accounting between the Rx FIFO
  // free space / deframe progress (receive side) and the Tx flit launch (transmit
  // side).  With FLOW_CTRL = 0 it elaborates to credit_ok = 1 / cr_req = 0, so the
  // datapath is unchanged; with -DFLOW_CTRL_OVERRIDE it gates data flits on remote
  // credit and emits credit-only flits carrying the advertised limit.
  fc_ctl u_fc_ctl (
    .clk (ucie_clk), .rst_n (ucie_rst_n),
    .dfr_data_done (rx_data_done), .lost_cnt (rx_fc_lost),
    .rx_wfree (rx_wfree), .cl_remote (rx_cl_remote),
    .st_any (tx_st_any), .st_data (tx_st_data),
    .credit_ok (tx_credit_ok), .cr_req (tx_cr_req),
    .seq_now (tx_seq_now), .cl_now (tx_cl_now)
  );

  tx_egress u_tx_egress (
    .clk (ucie_clk), .rst_n (`DP_UCIE_RST), .tx_en (tx_en),
    .flit_valid (flit_valid), .flit (flit), .flit_taken (flit_taken),
    .credit_ok (tx_credit_ok), .cr_req (tx_cr_req), .seq_now (tx_seq_now), .cl_now (tx_cl_now),
    .st_any (tx_st_any), .st_data (tx_st_data),
    .ucie_tx_data (ucie_tx_data), .ucie_tx_valid (ucie_tx_valid),
    .ucie_tx_start_flit (ucie_tx_start_flit), .busy (egress_busy)
  );

  // ==== Rx datapath: UCIe Rx -> flit capture -> deframer -> CDC FIFO -> PCIe AXI-S =
  rx_ingress u_rx_ingress (
    .clk (ucie_clk), .rst_n (`DP_UCIE_RST),
    .ucie_rx_data (ucie_rx_data), .ucie_rx_valid (ucie_rx_valid),
    .ucie_rx_start_flit (ucie_rx_start_flit),
    .flit_valid (rx_flit_valid), .flit (rx_flit), .flit_gap (rx_flit_gap),
    .flit_taken (rx_flit_taken), .idle (rx_ing_idle),
    .dropped_flits (rx_dropped_flits), .lock_errors (rx_lock_errors),
    .fc_cl_remote (rx_cl_remote), .fc_lost_cnt (rx_fc_lost)
  );

  rx_deframer u_rx_deframer (
    .clk (ucie_clk), .rst_n (`DP_UCIE_RST),
    .flit_valid (rx_flit_valid), .flit (rx_flit), .flit_gap (rx_flit_gap),
    .flit_taken (rx_flit_taken), .data_done (rx_data_done),
    .fifo_wdata (rx_fifo_wdata), .fifo_winc (rx_fifo_winc), .fifo_full (rx_fifo_full),
    .idle (rx_dfr_idle), .bad_flits (rx_bad_flits), .aborted_frames (rx_aborted_frames)
  );

  async_fifo #(.W(PCIE_DATA_W+PCIE_KEEP_W+2), .DEPTH(FIFO_DEPTH)) u_rx_cdc (
    .wclk   (ucie_clk), .wrst_n (`DP_UCIE_RST),
    .winc   (rx_fifo_winc), .wdata (rx_fifo_wdata),
    .wfull  (rx_fifo_full), .wfree (rx_wfree),
    .rclk   (pcie_clk), .rrst_n (`DP_PCIE_RST),
    .rinc   (rx_fifo_rinc), .rdata (rx_fifo_rdata), .rempty (rx_fifo_empty)
  );

  pcie_egress u_pcie_egress (
    .fifo_rdata (rx_fifo_rdata), .fifo_empty (rx_fifo_empty), .fifo_rinc (rx_fifo_rinc),
    .pcie_rx_tvalid (pcie_rx_tvalid), .pcie_rx_tready (pcie_rx_tready),
    .pcie_rx_tdata (pcie_rx_tdata), .pcie_rx_tkeep (pcie_rx_tkeep),
    .pcie_rx_tlast (pcie_rx_tlast), .pcie_rx_tuser (pcie_rx_tuser)
  );

`ifndef DP_RESET_OFF
  // Rx path empty: deframer between frames, Rx CDC FIFO empty (write-side view,
  // conservative) and pcie_egress not presenting a beat (pcie_clk -> ucie_clk, 2 flops),
  // held for 4 ucie_clk cycles so the pointer / valid synchroniser skew cannot show a
  // false idle.
  logic [1:0] rx_val_s;
  logic [2:0] rx_out_cnt;
  always_ff @(posedge ucie_clk or negedge ucie_rst_n) begin
    if (!ucie_rst_n) begin
      rx_val_s <= 2'b11; rx_out_cnt <= '0;
    end else begin
      rx_val_s <= {rx_val_s[0], pcie_rx_tvalid};
      if (rx_dfr_idle && rx_wfree == ($clog2(FIFO_DEPTH)+1)'(FIFO_DEPTH) && !rx_val_s[1])
        rx_out_cnt <= (rx_out_cnt == 3'd4) ? rx_out_cnt : rx_out_cnt + 3'd1;
      else rx_out_cnt <= '0;
    end
  end
  assign rx_out_idle = (rx_out_cnt == 3'd4);
`else
  assign rx_out_idle = 1'b1;
`endif

  // ---- observation points / still-unused signals ----------------------------
  // tx_st_*/rx_data_done/rx_cl_remote/rx_fc_lost/rx_wfree are now consumed by the
  // flow-control controller; the rest below are observation-only or config-gated.
  /* verilator lint_off UNUSEDSIGNAL */
  wire unused_obs = (^tx_wfree_unused) ^ sb_busy ^ rx_dfr_idle ^ (^pcie_tuser)
                  ^ rx_out_idle;   // rx_out_idle used only in the DP-reset-on config
  /* verilator lint_on UNUSEDSIGNAL */

endmodule : pcie_ucie3d_adapter
