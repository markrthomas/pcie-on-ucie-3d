// ============================================================================
// ucie_sb_model.sv — DV-only UCIe-3D remote-die control-plane BFM (sideband
// target + link bring-up / status driver).
//
// * Bring-up handshake (drives the adapter's status inputs):
//     - ucie_link_status held high through reset and for rst_cycles after
//       ucie_rst_n rises (link reset handshake), then low;
//     - sb_lat cycles later ucie_rx_elec_idle falls (sideband / receiver awake);
//     - mb_lat cycles after that ucie_rx_active rises (mainband up).
//   Once up, every change of powerdown / speed / width is completed with a
//   single-cycle ucie_link_status pulse `lat` cycles later.
// * Sideband target (8-bit M2S/S2M, idle 8'h00): a committed write
//   (byte0 {SB_WR, x}, byte1 addr[15:8], byte2 addr[7:0], byte3 data) is stored
//   in regs[addr] and acknowledged `lat` cycles later with one S2M byte
//   {SB_WR_ACK, 4'h0}.
// * Checker: ucie_tx_valid while powerdown != L0, or while a pin change is
//   waiting for its link_status, is an error (the adapter must drain first).
// Knobs: lat, rst_cycles, sb_lat, mb_lat, mute_status (never pulse link_status),
// mute_ack (never ack a sideband write).
// ============================================================================
`timescale 1ns/1ps
`include "pcie_ucie3d_pkg.sv"

module ucie_sb_model
  import pcie_ucie3d_pkg::*;
(
  input  logic                   ucie_clk,
  input  logic                   ucie_rst_n,
  input  logic [1:0]             powerdown,
  input  logic [2:0]             speed,
  input  logic [1:0]             width,
  input  logic                   ucie_tx_valid,
  input  logic [SB_W-1:0]        sb_m2s,
  output logic                   ucie_link_status,
  output logic                   ucie_rx_active,
  output logic                   ucie_rx_elec_idle,
  output logic [SB_W-1:0]        sb_s2m
);
  int   lat        = 8;
  int   rst_cycles = 16;
  int   sb_lat     = 8;
  int   mb_lat     = 8;
  logic mute_status = 1'b0;
  logic mute_ack    = 1'b0;

  logic [7:0]  regs [0:65535];
  int unsigned errors        = 0;
  int unsigned pd_changes    = 0, speed_changes = 0, width_changes = 0, sb_writes = 0;
  logic [SB_ADDR_W-1:0] last_sb_addr = '0;
  logic [7:0]  last_sb_data = 8'h00;
  logic [1:0]  pd_hist [0:255];
  int          pd_hist_n = 0;

  logic [1:0]  pd_q;
  logic [2:0]  speed_q;
  logic [1:0]  width_q;
  int          phase;          // 0 reset handshake, 1 sbinit, 2 mbinit, 3 up
  int          rst_cnt, sb_cnt, mb_cnt;
  int          st_cnt;         // >0: a link_status pulse is pending
  int          ack_cnt;        // >0: a sideband write_ack is pending
  int          sb_ph;          // 0 idle, 1 addr_hi, 2 addr_lo, 3 data
  logic [SB_ADDR_W-1:0] sb_addr;

  task automatic err(input string msg);
    begin
      errors++;
      $display("[%0t] SB-MODEL ERROR: %s", $time, msg);
    end
  endtask

  always @(posedge ucie_clk or negedge ucie_rst_n) begin
    if (!ucie_rst_n) begin
      ucie_link_status  <= 1'b1;
      ucie_rx_active    <= 1'b0;
      ucie_rx_elec_idle <= 1'b1;
      sb_s2m            <= 8'h00;
      pd_q <= powerdown; speed_q <= speed; width_q <= width;
      phase <= 0; rst_cnt <= 0; sb_cnt <= 0; mb_cnt <= 0;
      st_cnt <= 0; ack_cnt <= 0; sb_ph <= 0; sb_addr <= '0;
    end else begin
      ucie_link_status <= 1'b0;   // default low; raised by the reset handshake or an op pulse
      sb_s2m           <= 8'h00;

      // ---- bring-up sequencer -------------------------------------------------
      case (phase)
        0: begin
          ucie_link_status <= 1'b1;
          if (rst_cnt < rst_cycles) rst_cnt <= rst_cnt + 1;
          else begin ucie_link_status <= 1'b0; phase <= 1; sb_cnt <= 0; end
        end
        1: begin
          if (sb_cnt < sb_lat) sb_cnt <= sb_cnt + 1;
          else begin ucie_rx_elec_idle <= 1'b0; phase <= 2; mb_cnt <= 0; end
        end
        2: begin
          if (mb_cnt < mb_lat) mb_cnt <= mb_cnt + 1;
          else begin ucie_rx_active <= 1'b1; phase <= 3; end
        end
        default: ;   // up
      endcase

      // ---- pin changes -> link_status pulse (once up) -------------------------
      if (phase == 3) begin
        if (powerdown != pd_q || speed != speed_q || width != width_q) begin
          if (st_cnt != 0 && !mute_status) err("new UCIe pin change before link_status completed the previous one");
          if (powerdown != pd_q) begin
            pd_changes++;
            if (pd_hist_n < 256) begin pd_hist[pd_hist_n] = powerdown; pd_hist_n++; end
          end
          if (speed != speed_q) speed_changes++;
          if (width != width_q) width_changes++;
          st_cnt <= lat;
        end else if (st_cnt == 1) begin
          st_cnt <= 0;
          if (!mute_status) ucie_link_status <= 1'b1;
        end else if (st_cnt > 1) begin
          st_cnt <= st_cnt - 1;
        end
      end
      pd_q <= powerdown; speed_q <= speed; width_q <= width;

      // ---- Tx legality checker ------------------------------------------------
      if (ucie_tx_valid && powerdown != PWR_L0) err("Tx valid while powerdown != L0");
      if (ucie_tx_valid && (st_cnt != 0 || powerdown != pd_q || speed != speed_q || width != width_q))
        err("Tx valid during a speed/width/power change");

      // ---- sideband target (byte-serial write + ack) --------------------------
      if (sb_ph == 1) begin
        sb_addr[SB_ADDR_W-1:8] <= sb_m2s;
        sb_ph <= 2;
      end else if (sb_ph == 2) begin
        sb_addr[7:0] <= sb_m2s;
        sb_ph <= 3;
      end else if (sb_ph == 3) begin
        regs[sb_addr] = sb_m2s;
        last_sb_addr <= sb_addr;
        last_sb_data <= sb_m2s;
        sb_writes++;
        sb_ph   <= 0;
        ack_cnt <= lat;
      end else if (sb_m2s != 8'h00) begin        // idle->non-idle starts a transaction
        if (sb_m2s[7:4] == SB_WR) begin
          if (ack_cnt != 0 && !mute_ack) err("sideband write issued before the previous write_ack");
          sb_ph <= 1;
        end else begin
          err("unsupported M2S sideband command");
        end
      end
      if (ack_cnt == 1) begin
        ack_cnt <= 0;
        if (!mute_ack) sb_s2m <= {SB_WR_ACK, 4'h0};
      end else if (ack_cnt > 1) begin
        ack_cnt <= ack_cnt - 1;
      end
    end
  end
endmodule
