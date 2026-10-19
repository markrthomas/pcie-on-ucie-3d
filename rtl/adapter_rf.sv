// ============================================================================
// adapter_rf.sv — ucie_clk domain.  Config/status register file behind a minimal
// always-ready CSR port (write on csr_valid && csr_write; csr_rdata is the
// combinational read of csr_addr).  Map: pcie_ucie3d_pkg CSR_* and
// docs/OPEN_DECISIONS.md D7.
//
//   CTRL     RW  [1:0] pwr_req (rst L0)  [4:2] speed_req (rst SPEED_64)  [6:5] width_req (rst 0)
//   SPEEDCFG RW  [5:0] Tx preset index (rst SPEEDCFG_RST); [7:6] read 0 / write ignored;
//                    a write re-sends the preset to the remote die over the sideband
//   STATUS   RO  [1:0] powerdown [4:2] speed [6:5] width [10:7] ctrl state
//                [11] busy (op in flight) [12] link active (ST_ACTIVE)
//                [13] ucie_rx_active [14] ucie_rx_elec_idle
//   ERR      W1C [0] sideband timeout [1] link-status timeout [2] L0s requested
//                (unsupported, flagged per CTRL write) [3] CTRL write ignored: reserved width (3)
//   RXCNT0   RO  [15:0] Rx flits dropped (overflow) [31:16] Rx lock errors
//   RXCNT1   RO  [15:0] Rx bad/orphan flits [31:16] Rx frames aborted (tuser[0] err)
//   PMCNT    RO  [15:0] completed control operations (saturating)
// Unmapped addresses read 0; writes to RO/unmapped addresses are ignored.
// ============================================================================
`include "pcie_ucie3d_pkg.sv"

module adapter_rf
  import pcie_ucie3d_pkg::*;
(
  input  logic                   clk,
  input  logic                   rst_n,

  input  logic                   csr_valid,
  input  logic                   csr_write,
  input  logic [CSR_ADDR_W-1:0]  csr_addr,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0]            csr_wdata,     // [31:8] reserved
  /* verilator lint_on UNUSEDSIGNAL */
  output logic [31:0]            csr_rdata,

  // config out (requested state)
  output logic [1:0]             pwr_req,
  output logic [2:0]             speed_req,
  output logic [1:0]             width_req,
  output logic [7:0]             speedcfg,
  output logic                   cfg_wr,        // SPEEDCFG written (re-send the preset)

  // status in
  input  logic [1:0]             st_powerdown,
  input  logic [2:0]             st_speed,
  input  logic [1:0]             st_width,
  input  logic [3:0]             st_state,
  input  logic                   st_rx_active,
  input  logic                   st_rx_elec_idle,
  input  logic                   ev_op_done,
  input  logic                   ev_link_timeout,
  input  logic                   ev_sb_timeout,
  input  logic [15:0]            rx_dropped_flits,
  input  logic [15:0]            rx_lock_errors,
  input  logic [15:0]            rx_bad_flits,
  input  logic [15:0]            rx_aborted_frames
);
  logic [3:0]  err_q;
  logic [15:0] opcnt_q;

  wire wr = csr_valid && csr_write;

  assign cfg_wr = wr && (csr_addr == CSR_SPEEDCFG);

  // CTRL write checks: width 3 is reserved (x1/x2/x4 only, D1) -> the whole write is
  // ignored and flagged in ERR[3]; a P0s/L0s request (unsupported, treated as L0 by
  // the FSM) is flagged in ERR[2] once per CTRL write.  Every speed code (0..7) is valid.
  wire ctrl_wr    = wr && (csr_addr == CSR_CTRL);
  wire ctrl_bad   = ctrl_wr && (csr_wdata[6:5] == 2'd3);
  wire ev_bad_l0s = ctrl_wr && !ctrl_bad && (csr_wdata[1:0] == PWR_L0S);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pwr_req   <= PWR_L0;
      speed_req <= SPEED_64;
      width_req <= 2'b00;
      speedcfg  <= SPEEDCFG_RST;
      err_q     <= '0;
      opcnt_q   <= '0;
    end else begin
      if (ctrl_wr && !ctrl_bad) begin
        pwr_req   <= csr_wdata[1:0];
        speed_req <= csr_wdata[4:2];
        width_req <= csr_wdata[6:5];
      end
      if (cfg_wr) speedcfg <= {2'b00, csr_wdata[5:0]};
      // W1C, with set taking priority over a same-cycle clear
      err_q <= (err_q & ~((wr && csr_addr == CSR_ERR) ? csr_wdata[3:0] : 4'b0000))
             | {ctrl_bad, ev_bad_l0s, ev_link_timeout, ev_sb_timeout};
      if (ev_op_done && opcnt_q != 16'hFFFF) opcnt_q <= opcnt_q + 16'd1;
    end
  end

  wire busy = !(st_state == ST_ACTIVE || st_state == ST_LOWPWR);

  always_comb begin
    csr_rdata = '0;
    case (csr_addr)
      CSR_CTRL:     csr_rdata = {25'b0, width_req, speed_req, pwr_req};
      CSR_SPEEDCFG: csr_rdata = {24'b0, speedcfg};
      CSR_STATUS:   csr_rdata = {17'b0, st_rx_elec_idle, st_rx_active,
                                 (st_state == ST_ACTIVE), busy, st_state,
                                 st_width, st_speed, st_powerdown};
      CSR_ERR:      csr_rdata = {28'b0, err_q};
      CSR_RXCNT0:   csr_rdata = {rx_lock_errors, rx_dropped_flits};
      CSR_RXCNT1:   csr_rdata = {rx_aborted_frames, rx_bad_flits};
      CSR_PMCNT:    csr_rdata = {16'b0, opcnt_q};
      default:      csr_rdata = '0;
    endcase
  end

endmodule : adapter_rf
