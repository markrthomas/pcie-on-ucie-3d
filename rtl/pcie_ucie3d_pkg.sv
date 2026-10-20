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
  localparam logic [7:0] CSR_STATUS   = 8'h08;  // RO  [1:0] pwr [4:2] speed [6:5] width [10:7] state [11] busy [12] active [13] rx_active [14] rx_elec_idle
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
