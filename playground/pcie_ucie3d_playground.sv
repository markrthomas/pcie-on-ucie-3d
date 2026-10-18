// ============================================================================
// pcie_ucie3d_playground.sv — GENERATED single-file bundle for EDA Playground.
// Do not edit by hand: regenerate with `python3 playground/assemble.py`.
//
// EDA Playground setup: Tools = "Aldec Riviera-PRO" (or any UVM-capable sim),
// UVM/OVM = "UVM 1.2"; top = tb_uvm_top; run with +UVM_TESTNAME=smoke_test.
// M0 carries the stub DUT + the UVM smoke test; M4 swaps in the Config-1
// loopback scenario TB.  See docs/PLAN.md §5.
// ============================================================================

// ---- rtl/pcie_ucie3d_pkg.sv ------------------------------------------------
// ============================================================================
// pcie_ucie3d_pkg.sv — parameters, typedefs, and enums for the
// PCIe <-> UCIe-3D raw-mode adapter.
//
// BASELINE: UCIe 3.0 (Aug 2025) UCIe-3D variant — vertical die stacking,
// hybrid-bonding bump pitch, NO D2D adapter: the PCIe protocol layer connects
// to the UCIe-3D physical layer directly, in RAW MODE (the protocol fills every
// flit byte; the link inserts no CRC/retry).  PCIe side = PCIe 6 256-byte FLIT
// mode.  See docs/PLAN.md and docs/ucie3d_notes.md.
//
// STATUS: M0 scaffold — these are the adopted first-cut parameters; the datapath
// and control modules that consume them land in M1+ (see docs/OPEN_DECISIONS.md).
// ============================================================================
`ifndef PCIE_UCIE3D_PKG_SV
`define PCIE_UCIE3D_PKG_SV

package pcie_ucie3d_pkg;

  // Several params below are frozen now for the interface/microarch but are not
  // consumed until the datapath/control modules land (M1+); waive the "unused
  // parameter" lint until then.
  /* verilator lint_off UNUSEDPARAM */

  // ---- PCIe / FDI side (PCIe 6 256-byte FLIT mode), FLIT-aware stream --------
  // A PCIe controller presents 256-byte flits to the adapter as an AXI4-Stream-
  // like packet interface (keeps the adapter protocol-stack-agnostic).  The
  // adapter tunnels the flit payload opaquely over the UCIe-3D raw-mode link.
  localparam int unsigned PCIE_DATA_W = 256;             // [OPEN] §2.3
  localparam int unsigned PCIE_KEEP_W = PCIE_DATA_W / 8;
  localparam int unsigned PCIE_USER_W = 8;               // SOF/err/tc tag

  // ---- UCIe-3D physical side (raw-mode parallel bump bus) --------------------
  // UCIe-3D is a very wide, low-speed-per-pin vertical interface (hybrid bonding,
  // bump pitch < 10um).  Modeled here as a parallel raw-mode bus; lane count is a
  // compile-time parameter so x2/x4 modules are a bump later (OPEN_DECISIONS D1).
`ifdef UCIE_NLANES_OVERRIDE
  localparam int unsigned UCIE_NLANES = `UCIE_NLANES_OVERRIDE;
`else
  localparam int unsigned UCIE_NLANES = 1;               // default x1
`endif
  localparam int unsigned UCIE_DATA_W = 64;              // per-lane parallel bus
  localparam int unsigned UCIE_BUS_W  = UCIE_DATA_W * UCIE_NLANES;

  // ---- Flit format tunnelled over the raw-mode link (OPEN_DECISIONS D2) -------
  // PCIe 6 flit = 256 bytes.  The adapter carries the PCIe frame bytes opaquely
  // in the flit payload area (raw mode: no link-inserted CRC/retry):
  //   byte 0        : {5'b0, eof, sof, valid}   (valid=1 for every emitted flit)
  //   byte 1        : payload byte count in this flit (0..FLIT_PAYLOAD_B)
  //   bytes 2..241  : frame bytes (FLIT_PAYLOAD_B = 240), zero padded
  //   bytes 242..247: DLP placeholder (zero, except 242..245 = seq / cl with FLOW_CTRL)
  //   bytes 248..255: FEC/CRC placeholder (zero; raw mode = protocol owns these)
  // UCIe Tx serialises the flit LSB-byte first, UCIE_BUS_W bits per ucie_clk beat.
  localparam int unsigned FLIT_BYTES     = 256;
  localparam int unsigned FLIT_HDR_B     = 2;
  localparam int unsigned FLIT_PAYLOAD_B = 240;
  localparam int unsigned FLIT_BEATS     = FLIT_BYTES * 8 / UCIE_BUS_W;

  // ---- UCIe sideband (OPEN_DECISIONS D8) -------------------------------------
  // One 8-bit M2S (adapter->remote) and one 8-bit S2M (remote->adapter) byte
  // channel, ucie_clk-synchronous, idle = 8'h00; any non-idle byte starts a
  // sideband transaction (link bring-up / parameter exchange / register access).
  // This is the UCIe-3D analog of a PIPE message bus.
  localparam int unsigned SB_W      = 8;
  localparam int unsigned SB_ADDR_W = 16;
  localparam logic [3:0] SB_NOP    = 4'h0;
  localparam logic [3:0] SB_WR     = 4'h1;
  localparam logic [3:0] SB_RD     = 4'h2;
  localparam logic [3:0] SB_WR_ACK = 4'h3;
  localparam logic [3:0] SB_RD_CPL = 4'h4;
  // Register written at link bring-up to select the Tx preset / raw-mode config.
  localparam logic [SB_ADDR_W-1:0] SB_ADDR_TX_PRESET = 16'h0405;

  // Cycles the control plane waits for a sideband ack / link status before it
  // flags a timeout (OPEN_DECISIONS D10).
  localparam int unsigned SB_TIMEOUT = 1024;

  // ---- adapter_rf CSR map (pcie_clk domain, OPEN_DECISIONS D7) ----------------
  localparam int unsigned CSR_ADDR_W = 8;
  localparam logic [7:0] CSR_CTRL     = 8'h00;  // RW  [1:0] pwr_req [4:2] speed_req [6:5] width_req
  localparam logic [7:0] CSR_SPEEDCFG = 8'h04;  // RW  [5:0] Tx preset index; a write is sent over the sideband
  localparam logic [7:0] CSR_STATUS   = 8'h08;  // RO  [1:0] pwr [4:2] speed [6:5] width [10:7] state [11] active
  localparam logic [7:0] CSR_ERR      = 8'h0C;  // W1C [0] sb timeout [1] link timeout [2] L0s requested [3] reserved write ignored
  localparam logic [7:0] CSR_RXCNT0   = 8'h10;  // RO  [15:0] dropped flits [31:16] lock errors
  localparam logic [7:0] CSR_RXCNT1   = 8'h14;  // RO  [15:0] bad/orphan flits [31:16] aborted frames
  localparam logic [7:0] CSR_PMCNT    = 8'h18;  // RO  [15:0] completed power/speed/width/cfg operations
  localparam logic [7:0] SPEEDCFG_RST = 8'h21;  // reset preset index

  // ---- Elastic / CDC buffering -----------------------------------------------
  localparam int unsigned FIFO_DEPTH = 32;              // [OPEN] size vs burst

  // ---- Link flow control (OPEN_DECISIONS D16) --------------------------------
  // Opt-in, compile-time (both ends must agree): -DFLOW_CTRL_OVERRIDE.  In raw
  // mode the link has no built-in retry, so a credit scheme is carried in the
  // flit DLP area (bytes FLIT_FC_OFF..+3) when enabled.
`ifdef FLOW_CTRL_OVERRIDE
  localparam bit FLOW_CTRL = 1'b1;
`else
  localparam bit FLOW_CTRL = 1'b0;
`endif
  // ---- Datapath-local reset on low-power exit (OPEN_DECISIONS D18) ------------
  // DEFAULT ON.  The PD_DP instances (everything but the control plane) are held
  // in reset from the control FSM's ST_LOWPWR until ST_DRAIN, so a power-gated
  // datapath needs no retention.  Switched OFF by -DDP_RESET_DISABLE, and
  // automatically by -DFLOW_CTRL_OVERRIDE (the Rx credit/sequence state must
  // survive across low-power episodes).
`ifdef FLOW_CTRL_OVERRIDE
`define DP_RESET_OFF
`endif
`ifdef DP_RESET_DISABLE
`define DP_RESET_OFF
`endif
`ifdef DP_RESET_OFF
  localparam bit DP_RESET = 1'b0;
`else
  localparam bit DP_RESET = 1'b1;
`endif

  localparam int unsigned FLIT_FC_OFF = 242;
  localparam int unsigned CREDIT_BEATS_PER_FLIT = 9;
  localparam int unsigned INIT_CREDITS = FIFO_DEPTH / CREDIT_BEATS_PER_FLIT;

  // ---- UCIe link speed (speed[2:0] on the UCIe interface) --------------------
  typedef enum logic [2:0] {
    SPEED_4   = 3'd0,   //  4 GT/s
    SPEED_8   = 3'd1,   //  8 GT/s
    SPEED_12  = 3'd2,   // 12 GT/s
    SPEED_16  = 3'd3,   // 16 GT/s
    SPEED_24  = 3'd4,   // 24 GT/s
    SPEED_32  = 3'd5,   // 32 GT/s
    SPEED_48  = 3'd6,   // 48 GT/s  (UCIe 3.0)
    SPEED_64  = 3'd7    // 64 GT/s  (UCIe 3.0)  <-- baseline
  } ucie_speed_e;

  // ---- UCIe power state (powerdown[1:0]) -------------------------------------
  typedef enum logic [1:0] {
    PWR_L0  = 2'd0,     // active
    PWR_L0S = 2'd1,     // active standby
    PWR_L1  = 2'd2,     // low power
    PWR_L2  = 2'd3      // lowest power
  } ucie_pwr_e;

  // ---- adapter control FSM ---------------------------------------------------
  typedef enum logic [3:0] {
    ST_RESET     = 4'd0,
    ST_SBINIT    = 4'd1,   // sideband bring-up
    ST_MBINIT    = 4'd2,   // mainband (data lane) bring-up
    ST_PARAM     = 4'd3,   // exchange raw-mode / preset parameters over sideband
    ST_ACTIVE    = 4'd4,   // L0, datapath running
    ST_DRAIN     = 4'd5,   // flush datapath before a PM / speed / width change
    ST_SPEED_CHG = 4'd6,
    ST_WIDTH_CHG = 4'd7,
    ST_LOWPWR    = 4'd8,   // L1/L2
    ST_PWR_CHG   = 4'd9    // powerdown change in flight (waiting for link status)
  } adapter_state_e;

  /* verilator lint_on UNUSEDPARAM */

endpackage : pcie_ucie3d_pkg

`endif // PCIE_UCIE3D_PKG_SV

// ---- rtl/pcie_ucie3d_adapter.sv --------------------------------------------
// ============================================================================
// pcie_ucie3d_adapter.sv — TOP of the PCIe <-> UCIe-3D raw-mode adapter.
//
// STATUS: M0 SCAFFOLD — interface frozen, body is a stub.  Ports per docs/PLAN.md
// §2 plus the CSR port (docs/OPEN_DECISIONS.md D7).  Out of reset the adapter
// holds the UCIe link in L1 at the Gen (64 GT/s) baseline, drives no Tx traffic,
// and keeps the PCIe ingress closed; CSRs read their reset values.  The datapath
// (ingress/CDC/framer/egress, reverse path) and the control plane (sideband
// master, control FSM, register file) land in M1+.
// ============================================================================

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
  input  logic [PCIE_USER_W-1:0]   pcie_tuser,
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

  // ---- CSR port (pcie_clk domain, always ready; D7) -------------------------
  input  logic                     csr_valid,
  input  logic                     csr_write,
  input  logic [CSR_ADDR_W-1:0]    csr_addr,
  input  logic [31:0]              csr_wdata,
  output logic [31:0]              csr_rdata
);

  // ---- supported lane counts: x1, x2, x4 ------------------------------------
  // The datapath moves one PCIe beat (PCIE_DATA_W bits) per clock, so a UCIe bus
  // wider than that (x8 and up) cannot be kept fed / drained; refuse to elaborate
  // (OPEN_DECISIONS D1), mirroring the sibling eth-dj bridge.
  if (UCIE_BUS_W > PCIE_DATA_W) begin : g_unsupported_lane_count
    $error("UCIE_NLANES=%0d is not supported: UCIE_BUS_W (%0d) exceeds PCIE_DATA_W (%0d); x1, x2, x4 only (D1)",
           UCIE_NLANES, UCIE_BUS_W, PCIE_DATA_W);
  end

  // ---- M0 stub: static reset-value drives (no datapath / FSM yet) -----------
  assign pcie_tready        = 1'b0;                 // ingress closed until link-up (M3)
  assign pcie_rx_tvalid     = 1'b0;
  assign pcie_rx_tdata      = '0;
  assign pcie_rx_tkeep      = '0;
  assign pcie_rx_tlast      = 1'b0;
  assign pcie_rx_tuser      = '0;

  assign ucie_tx_data       = '0;
  assign ucie_tx_valid      = 1'b0;                 // no Tx traffic out of reset
  assign ucie_tx_start_flit = 1'b0;
  assign ucie_speed         = SPEED_64;             // 64 GT/s baseline (UCIe 3.0)
  assign ucie_width         = 2'b00;                // x1
  assign ucie_powerdown     = PWR_L1;               // low power out of reset
  assign ucie_sb_m2s        = '0;                   // sideband idle

  // ---- CSR read: reset-value constants (stub register file) -----------------
  always_comb begin
    unique case (csr_addr)
      CSR_CTRL:     csr_rdata = {25'b0, 2'b00, 3'(SPEED_64), 2'(PWR_L0)};
      CSR_SPEEDCFG: csr_rdata = {24'b0, SPEEDCFG_RST};
      CSR_STATUS:   csr_rdata = {19'b0, 1'b0, 1'b0, 4'(ST_RESET), 2'b00, 3'(SPEED_64), 2'(PWR_L1)};
      default:      csr_rdata = 32'h0;              // ERR / RXCNT0 / RXCNT1 / PMCNT / unmapped
    endcase
  end

  // ---- unused inputs in the M0 stub (driven in M1+) -------------------------
  /* verilator lint_off UNUSEDSIGNAL */
  wire unused_in = pcie_clk ^ ucie_clk
                 ^ pcie_rst_n ^ pcie_tvalid ^ (^pcie_tdata) ^ (^pcie_tkeep) ^ pcie_tlast
                 ^ (^pcie_tuser) ^ pcie_rx_tready
                 ^ ucie_rst_n ^ (^ucie_rx_data) ^ ucie_rx_valid ^ ucie_rx_start_flit
                 ^ ucie_link_status ^ ucie_rx_active ^ ucie_rx_elec_idle ^ (^ucie_sb_s2m)
                 ^ csr_valid ^ csr_write ^ (^csr_wdata);
  /* verilator lint_on UNUSEDSIGNAL */

endmodule : pcie_ucie3d_adapter

// ---- dv/uvm/adapter_if.sv --------------------------------------------------
// dv/uvm/adapter_if.sv — DUT pin interface for the UVM env (DV env 3).
// M0: carries the full port set; the M1+ agents/sequencers drive/monitor it.
interface adapter_if import pcie_ucie3d_pkg::*; (input logic pcie_clk, input logic ucie_clk);
  logic                   pcie_rst_n, ucie_rst_n;
  // PCIe / FDI side
  logic                   pcie_tvalid, pcie_tready, pcie_tlast;
  logic [PCIE_DATA_W-1:0] pcie_tdata;
  logic [PCIE_KEEP_W-1:0] pcie_tkeep;
  logic [PCIE_USER_W-1:0] pcie_tuser;
  logic                   pcie_rx_tvalid, pcie_rx_tready, pcie_rx_tlast;
  logic [PCIE_DATA_W-1:0] pcie_rx_tdata;
  logic [PCIE_KEEP_W-1:0] pcie_rx_tkeep;
  logic [PCIE_USER_W-1:0] pcie_rx_tuser;
  // UCIe-3D side
  logic [UCIE_BUS_W-1:0]  ucie_tx_data, ucie_rx_data;
  logic                   ucie_tx_valid, ucie_tx_start_flit, ucie_rx_valid, ucie_rx_start_flit;
  ucie_speed_e            ucie_speed;
  logic [1:0]             ucie_width;
  ucie_pwr_e              ucie_powerdown;
  logic                   ucie_link_status, ucie_rx_active, ucie_rx_elec_idle;
  logic [SB_W-1:0]        ucie_sb_m2s, ucie_sb_s2m;
  // CSR
  logic                   csr_valid, csr_write;
  logic [CSR_ADDR_W-1:0]  csr_addr;
  logic [31:0]            csr_wdata, csr_rdata;
endinterface

// ---- dv/uvm/adapter_uvm_pkg.sv ---------------------------------------------
// dv/uvm/adapter_uvm_pkg.sv — UVM environment (DV env 3).
// M0: a single smoke_test that resets the stub DUT and checks the reset/defaults
// contract.  M1+ grows this into the full env (flit sequencer/driver, UCIe PHY
// driver, CSR agent, scoreboard, scen_test running dv/common/scenarios.py).
package adapter_uvm_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import pcie_ucie3d_pkg::*;

  class smoke_test extends uvm_test;
    `uvm_component_utils(smoke_test)
    virtual adapter_if vif;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(virtual adapter_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "adapter_if not set in config db")
    endfunction

    task run_phase(uvm_phase phase);
      int errors = 0;
      phase.raise_objection(this);

      // tie off DUT inputs
      vif.pcie_tvalid = 1'b0; vif.pcie_tlast = 1'b0; vif.pcie_tdata = '0;
      vif.pcie_tkeep = '0; vif.pcie_tuser = '0; vif.pcie_rx_tready = 1'b1;
      vif.ucie_rx_data = '0; vif.ucie_rx_valid = 1'b0; vif.ucie_rx_start_flit = 1'b0;
      vif.ucie_link_status = 1'b0; vif.ucie_rx_active = 1'b0; vif.ucie_rx_elec_idle = 1'b1;
      vif.ucie_sb_s2m = '0;
      vif.csr_valid = 1'b0; vif.csr_write = 1'b0; vif.csr_addr = '0; vif.csr_wdata = '0;

      vif.pcie_rst_n = 1'b0; vif.ucie_rst_n = 1'b0;
      repeat (10) @(posedge vif.ucie_clk);
      vif.pcie_rst_n = 1'b1; vif.ucie_rst_n = 1'b1;
      repeat (5) @(posedge vif.ucie_clk);

      if (vif.ucie_powerdown !== PWR_L1) begin errors++; `uvm_error("SMOKE", "powerdown != L1") end
      if (vif.ucie_speed !== SPEED_64)   begin errors++; `uvm_error("SMOKE", "speed != SPEED_64") end
      if (vif.ucie_tx_valid !== 1'b0)    begin errors++; `uvm_error("SMOKE", "Tx active out of reset") end
      if (vif.pcie_tready !== 1'b0)      begin errors++; `uvm_error("SMOKE", "ingress open before link-up") end

      if (errors == 0) `uvm_info("SMOKE", "UVM SMOKE PASS: reset defaults OK", UVM_NONE)
      else             `uvm_error("SMOKE", "UVM SMOKE FAIL")
      phase.drop_objection(this);
    endtask
  endclass
endpackage

// ---- dv/uvm/tb_uvm_top.sv --------------------------------------------------
// dv/uvm/tb_uvm_top.sv — UVM testbench top (DV env 3).
// M0: clocks + interface + stub DUT + run_test("smoke_test").  M1+ wires the
// Config-1 loopback (UCIe Tx -> Rx) here.
`timescale 1ns/1ps

module tb_uvm_top;
  import uvm_pkg::*;
  import pcie_ucie3d_pkg::*;
  import adapter_uvm_pkg::*;

  logic pcie_clk = 1'b0;
  logic ucie_clk = 1'b0;
  always #2.5 pcie_clk = ~pcie_clk;
  always #1.0 ucie_clk = ~ucie_clk;

  adapter_if vif(.pcie_clk(pcie_clk), .ucie_clk(ucie_clk));

  pcie_ucie3d_adapter dut (
    .pcie_clk (pcie_clk), .pcie_rst_n (vif.pcie_rst_n),
    .pcie_tvalid (vif.pcie_tvalid), .pcie_tready (vif.pcie_tready), .pcie_tdata (vif.pcie_tdata),
    .pcie_tkeep (vif.pcie_tkeep), .pcie_tlast (vif.pcie_tlast), .pcie_tuser (vif.pcie_tuser),
    .pcie_rx_tvalid (vif.pcie_rx_tvalid), .pcie_rx_tready (vif.pcie_rx_tready), .pcie_rx_tdata (vif.pcie_rx_tdata),
    .pcie_rx_tkeep (vif.pcie_rx_tkeep), .pcie_rx_tlast (vif.pcie_rx_tlast), .pcie_rx_tuser (vif.pcie_rx_tuser),
    .ucie_clk (ucie_clk), .ucie_rst_n (vif.ucie_rst_n),
    .ucie_tx_data (vif.ucie_tx_data), .ucie_tx_valid (vif.ucie_tx_valid), .ucie_tx_start_flit (vif.ucie_tx_start_flit),
    .ucie_rx_data (vif.ucie_rx_data), .ucie_rx_valid (vif.ucie_rx_valid), .ucie_rx_start_flit (vif.ucie_rx_start_flit),
    .ucie_speed (vif.ucie_speed), .ucie_width (vif.ucie_width), .ucie_powerdown (vif.ucie_powerdown),
    .ucie_link_status (vif.ucie_link_status), .ucie_rx_active (vif.ucie_rx_active), .ucie_rx_elec_idle (vif.ucie_rx_elec_idle),
    .ucie_sb_m2s (vif.ucie_sb_m2s), .ucie_sb_s2m (vif.ucie_sb_s2m),
    .csr_valid (vif.csr_valid), .csr_write (vif.csr_write), .csr_addr (vif.csr_addr),
    .csr_wdata (vif.csr_wdata), .csr_rdata (vif.csr_rdata)
  );

  initial begin
    uvm_config_db#(virtual adapter_if)::set(null, "*", "vif", vif);
    run_test("smoke_test");
  end
endmodule
