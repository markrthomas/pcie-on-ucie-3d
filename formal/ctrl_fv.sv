// ============================================================================
// formal/ctrl_fv.sv — control-plane / Tx safety (ASSERTIONS.md F-*).  Composes
// the real adapter_ctrl_fsm + ucie_sb_master + tx_egress (ucie_clk domain).  Run
// twice: default and -DFLOW_CTRL_OVERRIDE (ctrl.sby tasks *_fc), where credit_ok /
// cr_req are free inputs so a credit-only flit may start any time tx_en allows (D16).
// Everything else is a free input: CSR requests, link bring-up status, sideband
// responses, the ingress-stopped handshake, Rx idle and the framer's flit_valid.
// The only environment constraint mirrors the top-level wiring:
//   tx_idle = !egress_busy && !flit_valid && <free>   (framer holds no flit)
// Properties (prove, PDR):
//   F-PP1  Tx valid only in L0 and only in ST_ACTIVE / ST_DRAIN
//   F-PP3  flits are FLIT_BEATS contiguous beats; start_flit only at a boundary
//   F-PP4  speed / width / powerdown pins change only in their change state
//   F-PP5  a pin-change state is left within SB_TIMEOUT cycles
//   F-MB1  no sideband request while one is outstanding
//   F-MB3  m2s byte framing: {SB_WR,0}, addr[hi], addr[lo], data, then idle 8'h00
//   F-MB4  no UCIe pin change while a sideband write is outstanding
//   F-MB5  the sideband master is busy for at most SB_TIMEOUT + 3 cycles
// The h_* helper invariants (also proven) tie the shadow counters to the RTL
// timers / sideband-master state so PDR converges in seconds; yosys-slang resolves
// their hierarchical reads and they are read-only.
// ============================================================================
`include "pcie_ucie3d_pkg.sv"

module ctrl_fv
  import pcie_ucie3d_pkg::*;
(
  input logic       clk,
  input logic       rst_n,
  input logic [1:0] pwr_req,
  input logic [2:0] speed_req,
  input logic [1:0] width_req,
  input logic       cfg_wr,
  input logic       link_status,
  input logic       rx_active,
  input logic       rx_elec_idle,
  input logic       ingress_stopped,
  input logic       rx_idle,
  input logic       other_idle,
  input logic       flit_valid,
  input logic       fc_credit_ok,   // FLOW_CTRL builds only: free (credit / credit-only-flit requests)
  input logic       fc_cr_req,
  input logic [7:0] s2m             // remote -> adapter sideband byte (free)
);
  localparam int BW = $clog2(FLIT_BEATS) + 1;
  localparam logic [2:0] S_IDLE = 3'd0, S_AHI = 3'd1, S_ALO = 3'd2, S_DATA = 3'd3, S_WAIT = 3'd4;

  logic [1:0] pd, width;
  logic [2:0] speed;
  logic [3:0] state;
  logic       tx_en, ingress_stop, sb_req, sb_busy, sb_done, sb_timeout;
  logic       ev_op_done, ev_link_timeout;
  logic       flit_taken, egress_busy, tx_valid, tx_sf;
  logic [UCIE_BUS_W-1:0] tx_data;
  logic [7:0] m2s;
  wire  [SB_ADDR_W-1:0] sb_addr  = SB_ADDR_TX_PRESET;
  wire  [7:0]           sb_wdata = 8'h21;
  // tx_idle mirrors the top: Tx CDC FIFO empty + framer idle + egress idle; with FLOW_CTRL a
  // wanted credit-only flit still counts as Tx activity (pcie_ucie3d_adapter tx_idle).
  wire        tx_idle = !egress_busy && !flit_valid && other_idle && !(FLOW_CTRL && fc_cr_req);

  adapter_ctrl_fsm u_ctrl (
    .clk(clk), .rst_n(rst_n), .pwr_req(pwr_req), .speed_req(speed_req), .width_req(width_req),
    .cfg_wr(cfg_wr), .link_status(link_status), .rx_active(rx_active), .rx_elec_idle(rx_elec_idle),
    .powerdown(pd), .speed(speed), .width(width),
    .tx_en(tx_en), .ingress_stop(ingress_stop), .ingress_stopped(ingress_stopped),
    .tx_idle(tx_idle), .rx_idle(rx_idle), .sb_req(sb_req), .sb_done(sb_done), .sb_timeout(sb_timeout),
    .state(state), .ev_op_done(ev_op_done), .ev_link_timeout(ev_link_timeout));

  ucie_sb_master u_sb (
    .clk(clk), .rst_n(rst_n), .req(sb_req), .addr(sb_addr), .wdata(sb_wdata),
    .busy(sb_busy), .done(sb_done), .timeout(sb_timeout), .m2s(m2s), .s2m(s2m));

  tx_egress u_eg (
    .clk(clk), .rst_n(rst_n), .tx_en(tx_en), .flit_valid(flit_valid),
    .flit({FLIT_BYTES*8{1'b0}}), .flit_taken(flit_taken),
    .credit_ok(fc_credit_ok), .cr_req(fc_cr_req), .seq_now(16'd0), .cl_now(16'd0), .st_any(), .st_data(),
    .ucie_tx_data(tx_data), .ucie_tx_valid(tx_valid), .ucie_tx_start_flit(tx_sf), .busy(egress_busy));

  // ---- environment ---------------------------------------------------------
  logic f_past = 1'b0;
  always @(posedge clk) f_past <= 1'b1;
  always @(*) if (!f_past) assume (!rst_n); else assume (rst_n);

  // ---- auxiliary state ------------------------------------------------------
  wire in_chg = (state == ST_SPEED_CHG) || (state == ST_WIDTH_CHG) || (state == ST_PWR_CHG);
  logic [BW-1:0] beat_q;
  logic [11:0]   chg_cnt_q, busy_cnt_q;
  logic [1:0]    pd_q, width_q;
  logic [2:0]    speed_q;
  always @(posedge clk) begin
    if (!rst_n) begin
      beat_q <= '0; chg_cnt_q <= '0; busy_cnt_q <= '0;
    end else begin
      if (tx_sf)         beat_q <= BW'(1);
      else if (tx_valid) beat_q <= (int'(beat_q) == FLIT_BEATS - 1) ? '0 : beat_q + BW'(1);
      chg_cnt_q  <= in_chg  ? chg_cnt_q + 12'd1  : 12'd0;
      busy_cnt_q <= sb_busy ? busy_cnt_q + 12'd1 : 12'd0;
    end
    pd_q <= pd; speed_q <= speed; width_q <= width;
  end

  // ---- properties -----------------------------------------------------------
  always @(*) if (f_past && rst_n) begin
    a_fpp1_tx_only_l0:   assert (!tx_valid || (pd == PWR_L0 && (state == ST_ACTIVE || state == ST_DRAIN)));
    a_fpp3_sf_boundary:  assert (!tx_sf || (tx_valid && beat_q == '0));
    a_fpp3_contiguous:   assert (beat_q == '0 || (tx_valid && !tx_sf));
    a_fpp3_no_headless:  assert (!(tx_valid && !tx_sf) || beat_q != '0);
    a_fpp5_chg_bound:    assert (chg_cnt_q <= SB_TIMEOUT);
    a_fmb1_one_outst:    assert (!(sb_req && sb_busy));
    a_fmb4_no_chg_in_sb: assert (!(in_chg && sb_busy));
    a_fmb5_busy_bound:   assert (busy_cnt_q <= SB_TIMEOUT + 3);
    // byte-bus framing, keyed off the busy counter
    a_fmb3_byte0: assert (!(sb_busy && busy_cnt_q == 12'd0) || m2s == {SB_WR, 4'h0});
    a_fmb3_byte1: assert (!(sb_busy && busy_cnt_q == 12'd1) || m2s == sb_addr[SB_ADDR_W-1:8]);
    a_fmb3_byte2: assert (!(sb_busy && busy_cnt_q == 12'd2) || m2s == sb_addr[7:0]);
    a_fmb3_byte3: assert (!(sb_busy && busy_cnt_q == 12'd3) || m2s == sb_wdata);
    a_fmb3_idle:  assert (sb_busy || m2s == 8'h00);
    // helper invariants (also proven): tie shadow counters to the RTL timers / sb-master state
    h_pd_active: assert (!(state == ST_ACTIVE || state == ST_DRAIN) || pd == PWR_L0);
    h_chg_tmr:   assert (!in_chg || (chg_cnt_q == 12'(u_ctrl.tmr_q) && int'(u_ctrl.tmr_q) < SB_TIMEOUT));
    h_sb_ahi:    assert (u_sb.st_q != S_AHI  || busy_cnt_q == 12'd0);
    h_sb_alo:    assert (u_sb.st_q != S_ALO  || busy_cnt_q == 12'd1);
    h_sb_data:   assert (u_sb.st_q != S_DATA || busy_cnt_q == 12'd2);
    h_sb_wait:   assert (u_sb.st_q != S_WAIT || (busy_cnt_q == 12'(u_sb.tmr_q) + 12'd3 &&
                                                  int'(u_sb.tmr_q) < SB_TIMEOUT));
  end
  always @(posedge clk) if (f_past && rst_n && $past(rst_n)) begin
    a_fpp4_speed_pin: assert (speed == speed_q || state == ST_SPEED_CHG);
    a_fpp4_width_pin: assert (width == width_q || state == ST_WIDTH_CHG);
    a_fpp4_pd_pin:    assert (pd    == pd_q    || state == ST_PWR_CHG);
  end

  // ---- covers ---------------------------------------------------------------
  always @(*) if (f_past && rst_n) begin
    c_tx_flit:    cover (tx_sf && state == ST_ACTIVE);
    c_lowpwr:     cover (state == ST_LOWPWR);
    c_speed_chg:  cover (state == ST_SPEED_CHG);
    c_param_ack:  cover (sb_done);
    c_drain_flit: cover (state == ST_DRAIN && tx_valid);
  end
endmodule
