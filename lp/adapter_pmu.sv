// ============================================================================
// lp/adapter_pmu.sv — DV-only power sequencer for PD_DP (docs/power_intent.md).
// NOT part of the DUT.  The adapter has no power ports; this model watches the
// UCIe powerdown pins and the CSR port (both ucie_clk) and drives the UPF control
// signals that lp/adapter.upf binds to (dp_pwr_en, dp_iso_en, dp_save, dp_restore).
//
//   power-down (armed by a CSR CTRL write requesting L1/L2 — never during the
//   post-reset link-up, which also starts in L1 — then the link parked in L1/L2
//   for DOWN_DELAY ucie_clk, i.e. the datapath has been drained):
//     iso_en=1 -> save pulse -> pwr_en=0                               (OFF)
//   power-up (CSR write of CTRL requesting L0/L0s while OFF or going OFF):
//     pwr_en=1 -> PWR_UP_CYC wait -> restore pulse -> iso_en=0          (ON)
//
// There is no handshake with adapter_ctrl_fsm: the power-up sequence (~4 ucie_clk)
// must finish before the FSM leaves ST_PWR_CHG, i.e. within the remote die's
// link-status latency for the L1->L0 change.  tb_adapter_upf_power checks that.
// Icarus-safe SV (no break, no array literals).
// ============================================================================
`include "pcie_ucie3d_pkg.sv"

module adapter_pmu
  import pcie_ucie3d_pkg::*;
#(
  parameter int DOWN_DELAY = 16,
  parameter int PWR_UP_CYC = 2
) (
  input  logic        clk,          // ucie_clk (control / CSR / powerdown domain)
  input  logic        rst_n,
  input  logic [1:0]  powerdown,
  input  logic        csr_valid,
  input  logic        csr_write,
  input  logic [7:0]  csr_addr,
  input  logic [31:0] csr_wdata,
  output logic        dp_pwr_en,    // 1 = PD_DP switched on
  output logic        dp_iso_en,    // 1 = PD_DP outputs clamped
  output logic        dp_save,      // retention save pulse
  output logic        dp_restore,   // retention restore pulse
  output logic        dp_off,       // observability: PD_DP is powered off
  output int          n_down,
  output int          n_up
);
  localparam logic [2:0] S_ON = 3'd0, S_ISO = 3'd1, S_SAVE = 3'd2, S_OFF = 3'd3,
                         S_PWRUP = 3'd4, S_RESTORE = 3'd5, S_DEISO = 3'd6;

  logic [2:0] st;
  int         cnt, lp_cnt;
  logic       wake_req, sleep_req;

  // wake request: CSR CTRL write whose pwr_req field is L0 or L0s
  wire wake_wr = csr_valid && csr_write && (csr_addr == CSR_CTRL) &&
                 ((csr_wdata[1:0] == PWR_L0) || (csr_wdata[1:0] == PWR_L0S));
  wire sleep_wr = csr_valid && csr_write && (csr_addr == CSR_CTRL) &&
                  ((csr_wdata[1:0] == PWR_L1) || (csr_wdata[1:0] == PWR_L2));
  wire low_pwr = (powerdown == PWR_L1) || (powerdown == PWR_L2);

  assign dp_off = (st == S_OFF);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_ON; cnt <= 0; lp_cnt <= 0; wake_req <= 1'b0; sleep_req <= 1'b0;
      dp_pwr_en <= 1'b1; dp_iso_en <= 1'b0; dp_save <= 1'b0; dp_restore <= 1'b0;
      n_down <= 0; n_up <= 0;
    end else begin
      dp_save    <= 1'b0;
      dp_restore <= 1'b0;
      if (wake_wr) begin wake_req <= 1'b1; sleep_req <= 1'b0; end
      else if (sleep_wr) sleep_req <= 1'b1;
      lp_cnt <= low_pwr ? lp_cnt + 1 : 0;
      case (st)
        S_ON: begin
          wake_req <= 1'b0;
          // only power down a link parked in low power with no wake pending
          if (sleep_req && low_pwr && lp_cnt >= DOWN_DELAY && !wake_wr) begin
            dp_iso_en <= 1'b1; st <= S_ISO;
          end
        end
        S_ISO:  begin dp_save <= 1'b1; st <= S_SAVE; end
        S_SAVE: begin dp_pwr_en <= 1'b0; st <= S_OFF; n_down <= n_down + 1; sleep_req <= 1'b0; end
        S_OFF: begin
          if (wake_req || wake_wr) begin dp_pwr_en <= 1'b1; cnt <= 0; st <= S_PWRUP; end
        end
        S_PWRUP: begin
          if (cnt >= PWR_UP_CYC - 1) begin dp_restore <= 1'b1; st <= S_RESTORE; end
          else cnt <= cnt + 1;
        end
        S_RESTORE: begin st <= S_DEISO; end
        default: begin // S_DEISO
          dp_iso_en <= 1'b0; st <= S_ON; wake_req <= 1'b0; n_up <= n_up + 1;
        end
      endcase
    end
  end
endmodule : adapter_pmu
