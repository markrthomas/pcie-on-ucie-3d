// ============================================================================
// adapter_ctrl_fsm.sv — ucie_clk domain.  Adapter control plane: brings the
// UCIe-3D link up, then converges the link state (powerdown / speed / width /
// Tx preset) onto the requested state held in adapter_rf, one operation at a
// time, draining the datapath first.
//
// Bring-up (uses the observable PHY-status inputs driven by the remote die):
//   ST_RESET  : hold until ucie_link_status falls (link reset handshake done)
//   ST_SBINIT : sideband bring-up — wait for ucie_rx_elec_idle to fall
//   ST_MBINIT : mainband (data-lane) bring-up — wait for ucie_rx_active
//            -> ST_LOWPWR (link trained; powerdown still L1 from reset)
//
// Steady state:
//   ST_ACTIVE : L0, tx_en=1, PCIe ingress open.  Any pending change -> ST_DRAIN.
//   ST_DRAIN  : ingress closes at the next frame boundary (tx_ingress_gate), the
//               Tx pipeline runs until empty and the Rx capture is idle
//               ("drained").  Then ONE operation is chosen, in priority order:
//               speed change, width change, preset (SPEEDCFG) sideband write,
//               power down to L1; with nothing pending it returns to ST_ACTIVE.
//   ST_SPEED_CHG / ST_WIDTH_CHG / ST_PWR_CHG : drive the new value on the UCIe
//               pins and wait for a ucie_link_status pulse (or SB_TIMEOUT -> sticky
//               error, the transition is treated as complete; D10).
//   ST_PARAM  : committed sideband write of the Tx preset (SPEEDCFG) to
//               SB_ADDR_TX_PRESET via ucie_sb_master.
//   ST_LOWPWR : L1/L2, datapath gated.  Steps L1<->L2 and L1->L0 on request
//               (L2->L0 goes via L1).  Speed/width changes wait until back in L0.
// L0s is not supported: an L0s request is flagged (in adapter_rf) and treated as L0.
// ============================================================================
`include "pcie_ucie3d_pkg.sv"

module adapter_ctrl_fsm
  import pcie_ucie3d_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,

  // requested state (adapter_rf)
  input  logic [1:0]  pwr_req,
  input  logic [2:0]  speed_req,
  input  logic [1:0]  width_req,
  input  logic        cfg_wr,           // SPEEDCFG written (re-send the preset)

  // link bring-up / status inputs (remote die, via the UCIe-3D PHY)
  input  logic        link_status,      // op-complete handshake; high through reset
  input  logic        rx_active,
  input  logic        rx_elec_idle,

  // UCIe link pins (as logic vectors; the top casts to the pkg enums)
  output logic [1:0]  powerdown,
  output logic [2:0]  speed,
  output logic [1:0]  width,

  // datapath drain handshake
  output logic        tx_en,            // tx_egress may start flits
  output logic        ingress_stop,     // to tx_ingress_gate (pcie_clk, synchronised there)
  input  logic        ingress_stopped,  // from tx_ingress_gate, already synchronised to clk
  input  logic        tx_idle,          // Tx CDC FIFO empty, framer + egress idle
  input  logic        rx_idle,          // rx_ingress not mid-flit and holding nothing

  // sideband master
  output logic        sb_req,
  input  logic        sb_done,
  input  logic        sb_timeout,

  // status / events
  output logic [3:0]  state,
  output logic        ev_op_done,        // pulse: one power/speed/width/cfg op completed
  output logic        ev_link_timeout    // pulse
);
  localparam int unsigned TW = $clog2(SB_TIMEOUT + 1);

  logic [3:0]    st_q;
  logic [1:0]    pd_q;
  logic [2:0]    speed_q;
  logic [1:0]    width_q;
  logic          cfg_dirty_q;
  logic [TW-1:0] tmr_q;

  wire [1:0] pwr_eff   = (pwr_req == PWR_L0S) ? PWR_L0 : pwr_req;
  wire       need_spd  = (speed_req != speed_q);
  wire       need_wid  = (width_req != width_q);
  wire       need_cfg  = cfg_dirty_q;
  wire       need_pwr  = (pwr_eff != PWR_L0);
  wire       drained   = ingress_stopped && tx_idle && rx_idle;
  wire       tmo       = (int'(tmr_q) == SB_TIMEOUT - 1);

  assign powerdown    = pd_q;
  assign speed        = speed_q;
  assign width        = width_q;
  assign state        = st_q;
  assign tx_en        = (st_q == ST_ACTIVE) || (st_q == ST_DRAIN);
  assign ingress_stop = (st_q != ST_ACTIVE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st_q            <= ST_RESET;
      pd_q            <= PWR_L1;
      speed_q         <= SPEED_64;
      width_q         <= 2'b00;
      cfg_dirty_q     <= 1'b1;            // send the preset once at bring-up
      tmr_q           <= '0;
      sb_req          <= 1'b0;
      ev_op_done      <= 1'b0;
      ev_link_timeout <= 1'b0;
    end else begin
      sb_req          <= 1'b0;
      ev_op_done      <= 1'b0;
      ev_link_timeout <= 1'b0;
      if (cfg_wr) cfg_dirty_q <= 1'b1;

      case (st_q)
        ST_RESET:  if (!link_status)   st_q <= ST_SBINIT;   // link reset handshake done
        ST_SBINIT: if (!rx_elec_idle)  st_q <= ST_MBINIT;   // sideband / receiver awake
        ST_MBINIT: if (rx_active)      st_q <= ST_LOWPWR;    // mainband up (power still L1)

        ST_LOWPWR: begin
          tmr_q <= '0;
          if (pwr_eff == PWR_L0 || (pwr_eff == PWR_L1 && pd_q == PWR_L2)) begin
            pd_q <= (pd_q == PWR_L2) ? PWR_L1 : PWR_L0;
            st_q <= ST_PWR_CHG;
          end else if (pwr_eff == PWR_L2 && pd_q == PWR_L1) begin
            pd_q <= PWR_L2;
            st_q <= ST_PWR_CHG;
          end
        end

        ST_ACTIVE: begin
          // 4-phase with tx_ingress_gate: leave ACTIVE only once the gate has been
          // seen open, so the `stopped` seen in ST_DRAIN is never stale.
          if ((need_spd || need_wid || need_cfg || need_pwr) && !ingress_stopped)
            st_q <= ST_DRAIN;
        end

        ST_DRAIN: begin
          tmr_q <= '0;
          if (drained) begin
            if (need_spd) begin
              speed_q <= speed_req;
              st_q    <= ST_SPEED_CHG;
            end else if (need_wid) begin
              width_q <= width_req;
              st_q    <= ST_WIDTH_CHG;
            end else if (need_cfg) begin
              sb_req <= 1'b1;
              st_q   <= ST_PARAM;
            end else if (need_pwr) begin
              pd_q <= PWR_L1;
              st_q <= ST_PWR_CHG;
            end else begin
              st_q <= ST_ACTIVE;
            end
          end
        end

        ST_SPEED_CHG, ST_WIDTH_CHG, ST_PWR_CHG: begin
          if (link_status || tmo) begin
            ev_op_done      <= 1'b1;
            ev_link_timeout <= !link_status;
            if (st_q == ST_SPEED_CHG) cfg_dirty_q <= 1'b1;        // re-send preset at the new speed
            if (st_q == ST_PWR_CHG && pd_q != PWR_L0) st_q <= ST_LOWPWR;
            else                                           st_q <= ST_DRAIN;
          end else begin
            tmr_q <= tmr_q + TW'(1);
          end
        end

        default: begin // ST_PARAM (committed preset sideband write)
          if (sb_done || sb_timeout) begin
            ev_op_done <= 1'b1;
            if (!cfg_wr) cfg_dirty_q <= 1'b0;   // a write racing the send keeps it dirty
            st_q       <= ST_DRAIN;
          end
        end
      endcase
    end
  end

endmodule : adapter_ctrl_fsm
