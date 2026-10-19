// ============================================================================
// pcie_ucie3d_playground.sv — GENERATED single-file bundle for EDA Playground.
// Do not edit by hand: regenerate with `python3 playground/assemble.py`.
//
// EDA Playground setup: Tools = "Aldec Riviera-PRO" (or any UVM-capable sim),
// UVM/OVM = "UVM 1.2"; top = tb_uvm_top.  Run the reset/link-up demo with
//   +UVM_TESTNAME=smoke_test
// or the full Config-1 loopback scenario cross-check (5 scenarios, ~40 KB of
// looped-back traffic, byte-exact) with
//   +UVM_TESTNAME=scen_test
// The DUT is the real pcie_ucie3d_adapter + control plane; see docs/PLAN.md §5.
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

// ---- rtl/async_fifo.sv -----------------------------------------------------
// ============================================================================
// async_fifo.sv — dual-clock FIFO, Gray-coded pointers, first-word-fall-through.
// DEPTH must be a power of two.  Each side has its own active-low reset.
// ============================================================================
module async_fifo #(
  parameter int unsigned W     = 8,
  parameter int unsigned DEPTH = 32
) (
  input  logic         wclk,
  input  logic         wrst_n,
  input  logic         winc,
  input  logic [W-1:0] wdata,
  output logic         wfull,
  output logic [$clog2(DEPTH):0] wfree,   // free entries, conservative (read pointer is synchronised)

  input  logic         rclk,
  input  logic         rrst_n,
  input  logic         rinc,
  output logic [W-1:0] rdata,
  output logic         rempty
);
  localparam int unsigned AW = $clog2(DEPTH);

  logic [W-1:0] mem [0:DEPTH-1];

  // ---- write side ----------------------------------------------------------
  // All pointer/synchroniser nets declared up front (declare-before-use for
  // strict simulators).
  logic [AW:0] wbin, wgray, wbin_n, wgray_n;
  logic [AW:0] rbin, rgray, rbin_n, rgray_n;
  logic [AW:0] rgray_w1, rgray_w2;          // rptr synchronised into wclk
  logic [AW:0] wgray_r1, wgray_r2;          // wptr synchronised into rclk

  // free space, write-clock domain: DEPTH - (wbin - binary(synchronised read pointer)).  The
  // synchronised pointer lags the real one, so this never over-reports free space.
  function automatic logic [$clog2(DEPTH):0] gray2bin(input logic [$clog2(DEPTH):0] g);
    logic [$clog2(DEPTH):0] b;
    begin
      b[$clog2(DEPTH)] = g[$clog2(DEPTH)];
      for (int i = $clog2(DEPTH) - 1; i >= 0; i--) b[i] = b[i+1] ^ g[i];
      gray2bin = b;
    end
  endfunction
  assign wfree = ($clog2(DEPTH)+1)'(DEPTH) - (wbin - gray2bin(rgray_w2));

  assign wbin_n  = wbin + (AW+1)'(winc && !wfull);
  assign wgray_n = (wbin_n >> 1) ^ wbin_n;

  always_ff @(posedge wclk or negedge wrst_n) begin
    if (!wrst_n) begin
      wbin  <= '0;
      wgray <= '0;
      wfull <= 1'b0;
    end else begin
      wbin  <= wbin_n;
      wgray <= wgray_n;
      // full: next write Gray pointer equals read pointer with top 2 bits inverted
      wfull <= (wgray_n == {~rgray_w2[AW:AW-1], rgray_w2[AW-2:0]});
    end
  end

  always_ff @(posedge wclk) begin
    if (winc && !wfull) mem[wbin[AW-1:0]] <= wdata;
  end

  always_ff @(posedge wclk or negedge wrst_n) begin
    if (!wrst_n) {rgray_w2, rgray_w1} <= '0;
    else         {rgray_w2, rgray_w1} <= {rgray_w1, rgray};
  end

  // ---- read side -----------------------------------------------------------

  assign rbin_n  = rbin + (AW+1)'(rinc && !rempty);
  assign rgray_n = (rbin_n >> 1) ^ rbin_n;

  always_ff @(posedge rclk or negedge rrst_n) begin
    if (!rrst_n) begin
      rbin   <= '0;
      rgray  <= '0;
      rempty <= 1'b1;
    end else begin
      rbin   <= rbin_n;
      rgray  <= rgray_n;
      rempty <= (rgray_n == wgray_r2);
    end
  end

  assign rdata = mem[rbin[AW-1:0]];

  always_ff @(posedge rclk or negedge rrst_n) begin
    if (!rrst_n) {wgray_r2, wgray_r1} <= '0;
    else         {wgray_r2, wgray_r1} <= {wgray_r1, wgray};
  end

endmodule : async_fifo

// ---- rtl/tx_framer.sv ------------------------------------------------------
// ============================================================================
// tx_framer.sv — ucie_clk domain.  Packs PCIe beats (from the CDC FIFO) into
// 256B UCIe-3D raw-mode flits (format: pcie_ucie3d_pkg, docs/OPEN_DECISIONS.md D2).
//
// FIFO word = {tlast, tkeep[PCIE_KEEP_W-1:0], tdata[PCIE_DATA_W-1:0]}.  tkeep is
// assumed contiguous low-aligned (only the last beat may be partial).  A null beat
// (tkeep = 0) is tolerated: without tlast it is ignored; with tlast it ends the
// frame (the flit holding the frame's last bytes gets eof) — an empty frame (only a
// null tlast beat) is dropped, no flit is emitted.  To make that possible a flit
// exactly full at the end of a non-last beat is held open until the next beat shows
// whether it is a null tlast beat (D19); every other flit closes as soon as it is
// full.  One flit buffer: while a completed flit is serialised (flit_valid=1) the
// framer stalls.  Throughput is intentionally simple for M1.
// ============================================================================

module tx_framer
  import pcie_ucie3d_pkg::*;
(
  input  logic                                clk,
  input  logic                                rst_n,

  input  logic [PCIE_DATA_W+PCIE_KEEP_W:0]    fifo_rdata,
  input  logic                                fifo_empty,
  output logic                                fifo_rinc,

  output logic                                flit_valid,
  output logic [FLIT_BYTES*8-1:0]             flit,
  input  logic                                flit_taken,
  output logic                                idle        // no partial or completed flit held
);
  localparam int unsigned OFFW  = $clog2(PCIE_KEEP_W + 1);
  localparam int unsigned FILLW = $clog2(FLIT_PAYLOAD_B + 1);

  wire [PCIE_DATA_W-1:0] beat_data = fifo_rdata[PCIE_DATA_W-1:0];
  wire [PCIE_KEEP_W-1:0] beat_keep = fifo_rdata[PCIE_DATA_W +: PCIE_KEEP_W];
  wire                   beat_last = fifo_rdata[PCIE_DATA_W+PCIE_KEEP_W];

  logic [FILLW-1:0] fill_q;        // payload bytes already in the flit buffer
  logic [OFFW-1:0]  in_off_q;      // bytes of the current FIFO beat already consumed
  logic             sof_q;         // next flit starts a frame
  logic             valid_q;
  logic [FLIT_BYTES*8-1:0] flit_q;

  // ---- combinational: consume as much of the head beat as fits -------------
  logic [FLIT_BYTES*8-1:0] flit_n;
  logic [FILLW-1:0]        fill_n;
  logic [OFFW-1:0]         off_n;
  logic                    beat_done, eof, close, full, hold, empty_eof;
  logic [OFFW-1:0]         nbytes;
  int                      space, avail, ncopy;

  always_comb begin
    flit_n    = flit_q;
    fill_n    = fill_q;
    off_n     = in_off_q;
    beat_done = 1'b0;
    eof       = 1'b0;
    close     = 1'b0;
    full      = 1'b0;
    hold      = 1'b0;
    empty_eof = 1'b0;
    nbytes    = '0;
    space     = 0;
    avail     = 0;
    ncopy     = 0;
    fifo_rinc = 1'b0;

    if (!valid_q && !fifo_empty) begin
      for (int i = 0; i < PCIE_KEEP_W; i++) nbytes = nbytes + OFFW'(beat_keep[i]);
      space = int'(FLIT_PAYLOAD_B) - int'(fill_q);
      avail = int'(nbytes) - int'(in_off_q);
      ncopy = (avail < space) ? avail : space;

      for (int j = 0; j < PCIE_KEEP_W; j++) begin
        if (j < ncopy)
          flit_n[8*(FLIT_HDR_B + int'(fill_q) + j) +: 8] = beat_data[8*(int'(in_off_q) + j) +: 8];
      end

      fill_n    = FILLW'(int'(fill_q) + ncopy);
      off_n     = OFFW'(int'(in_off_q) + ncopy);
      beat_done = (int'(off_n) == int'(nbytes));
      eof       = beat_done && beat_last;
      full      = (int'(fill_n) == FLIT_PAYLOAD_B);
      hold      = full && beat_done && !beat_last;      // exactly full: wait for the next beat
      empty_eof = eof && (fill_n == '0);                // empty frame (null tlast beat only)
      close     = ((full && !hold) || eof) && !empty_eof;
      fifo_rinc = beat_done;

      if (close) begin
        flit_n[7:0]  = {5'b0, eof, sof_q, 1'b1};
        flit_n[15:8] = 8'(fill_n);
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fill_q   <= '0;
      in_off_q <= '0;
      sof_q    <= 1'b1;
      valid_q  <= 1'b0;
      flit_q   <= '0;
    end else if (valid_q) begin
      if (flit_taken) begin
        valid_q <= 1'b0;
        flit_q  <= '0;
      end
    end else if (!fifo_empty) begin
      flit_q   <= flit_n;
      in_off_q <= beat_done ? '0 : off_n;
      if (close) begin
        valid_q <= 1'b1;
        fill_q  <= '0;
        sof_q   <= eof;
      end else begin
        fill_q  <= fill_n;
      end
    end
  end

  assign flit_valid = valid_q;
  assign idle       = !valid_q && (fill_q == '0) && (in_off_q == '0);
  assign flit       = flit_q;

endmodule : tx_framer

// ---- rtl/tx_egress.sv ------------------------------------------------------
// ============================================================================
// tx_egress.sv — ucie_clk domain.  Serialises a completed flit onto the UCIe-3D
// raw-mode Tx bus, UCIE_BUS_W bits per beat (LSB byte first), FLIT_BEATS beats,
// with ucie_tx_start_flit on the first beat.  A flit is only started while the
// link is active (tx_en); once started it always completes.
//
// Link flow control (FLOW_CTRL, docs/OPEN_DECISIONS.md D16): a data flit only starts
// while credit_ok; every flit gets its seq / cl fields overlaid (latched at flit
// start) at FLIT_FC_OFF; and when a credit update is wanted (cr_req) and no data
// flit can go, a credit-only flit (valid, count 0) is generated here.  With
// FLOW_CTRL = 0 all of this elaborates away and the module is unchanged.
// ============================================================================

module tx_egress
  import pcie_ucie3d_pkg::*;
(
  input  logic                        clk,
  input  logic                        rst_n,
  input  logic                        tx_en,

  input  logic                        flit_valid,
  input  logic [FLIT_BYTES*8-1:0]     flit,
  output logic                        flit_taken,

  input  logic                        credit_ok,
  input  logic                        cr_req,
  input  logic [15:0]                 seq_now,
  input  logic [15:0]                 cl_now,
  output logic                        st_any,
  output logic                        st_data,

  output logic [UCIE_BUS_W-1:0]       ucie_tx_data,
  output logic                        ucie_tx_valid,
  output logic                        ucie_tx_start_flit,
  output logic                        busy
);
  localparam int unsigned CW = $clog2(FLIT_BEATS);

  logic          busy_q;
  logic [CW-1:0] cnt_q;
  logic          cr_q;               // current flit is a credit-only flit
  logic [15:0]   seq_q, cl_q;        // fields latched at flit start

  wire start_data = !busy_q && flit_valid && tx_en && (!FLOW_CTRL || credit_ok);
  wire start_cr   = FLOW_CTRL && !busy_q && tx_en && cr_req && !start_data;
  wire start      = start_data || start_cr;

  assign busy    = busy_q;
  assign st_any  = start;
  assign st_data = start_data;

  wire last_beat = busy_q && (int'(cnt_q) == FLIT_BEATS - 1);
  assign flit_taken = last_beat && !cr_q;

  // fields in effect this cycle (live at the start cycle, latched afterwards)
  wire          use_cr = start ? start_cr : cr_q;
  wire [15:0]   seq_e  = start ? seq_now  : seq_q;
  wire [15:0]   cl_e   = start ? cl_now   : cl_q;

  logic [FLIT_BYTES*8-1:0] eff;
  always_comb begin
    eff = flit;
    if (FLOW_CTRL) begin
      if (use_cr) begin
        eff       = '0;
        eff[7:0]  = 8'h01;                          // valid, sof = eof = 0, count = 0
      end
      eff[8*FLIT_FC_OFF +: 16]       = seq_e;
      eff[8*(FLIT_FC_OFF+2) +: 16]   = cl_e;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy_q             <= 1'b0;
      cnt_q              <= '0;
      cr_q               <= 1'b0;
      seq_q              <= '0;
      cl_q               <= '0;
      ucie_tx_data       <= '0;
      ucie_tx_valid      <= 1'b0;
      ucie_tx_start_flit <= 1'b0;
    end else if (start) begin
      busy_q             <= 1'b1;
      cnt_q              <= CW'(1);
      cr_q               <= start_cr;
      seq_q              <= seq_now;
      cl_q               <= cl_now;
      ucie_tx_data       <= eff[UCIE_BUS_W-1:0];
      ucie_tx_valid      <= 1'b1;
      ucie_tx_start_flit <= 1'b1;
    end else if (busy_q) begin
      ucie_tx_data       <= eff[int'(cnt_q)*UCIE_BUS_W +: UCIE_BUS_W];
      ucie_tx_valid      <= 1'b1;
      ucie_tx_start_flit <= 1'b0;
      if (last_beat) busy_q <= 1'b0;
      cnt_q              <= cnt_q + CW'(1);
    end else begin
      ucie_tx_valid      <= 1'b0;
      ucie_tx_start_flit <= 1'b0;
    end
  end

endmodule : tx_egress

// ---- rtl/rx_ingress.sv -----------------------------------------------------
// ============================================================================
// rx_ingress.sv — ucie_clk domain.  Captures UCIe-3D Rx beats into a 256B flit
// and FLIT-locks on ucie_rx_start_flit: beats are ignored until a start_flit, and
// a start_flit mid-flit restarts capture.  A completed flit is held (flit_valid)
// until the deframer takes it.
//
// The UCIe-3D raw-mode Rx bus has no backpressure (docs/OPEN_DECISIONS.md D9): a
// flit completing while the previous one is still held is DROPPED and counted.
// Any lost flit (overflow drop or a lock error) sets a gap marker that travels
// with the next flit handed to the deframer (flit_gap), so the deframer can abort
// the frame that lost data instead of splicing it onto later bytes.
//
// Link flow control (FLOW_CTRL, docs/OPEN_DECISIONS.md D16).  Each flit is examined the
// cycle it finishes arriving, independent of whether the previous flit is still held:
//  * its seq field is compared with the number of data flits expected; a gap means flits
//    were lost (counted in fc_lost_cnt, and the next stored flit gets flit_gap);
//  * its cl field (the remote's cumulative credit limit) is merged into fc_cl_remote;
//  * a credit-only flit (count 0, sof = eof = 0) is consumed here and never stored, so it
//    cannot be dropped for lack of a slot;
//  * a data flit dropped because the slot is busy is added to fc_lost_cnt (it will never
//    be deframed, so its credit must be given back).
// ============================================================================

module rx_ingress
  import pcie_ucie3d_pkg::*;
(
  input  logic                        clk,
  input  logic                        rst_n,
  input  logic [UCIE_BUS_W-1:0]       ucie_rx_data,
  input  logic                        ucie_rx_valid,
  input  logic                        ucie_rx_start_flit,

  output logic                        flit_valid,
  output logic [FLIT_BYTES*8-1:0]     flit,
  output logic                        flit_gap,        // >=1 flit lost before this one
  input  logic                        flit_taken,

  output logic                        idle,            // not mid-flit, nothing held
  output logic [15:0]                 dropped_flits,   // DV visibility (sticky count)
  output logic [15:0]                 lock_errors,     // beats/start_flit protocol slips
  output logic [15:0]                 fc_cl_remote,    // remote credit limit (FLOW_CTRL)
  output logic [15:0]                 fc_lost_cnt      // cumulative data flits lost or dropped (FLOW_CTRL)
);
  localparam int unsigned CW = $clog2(FLIT_BEATS);

  logic [FLIT_BYTES*8-1:0] cap_q, flit_q;
  logic [CW-1:0]           cnt_q;
  logic                    locked_q, full_q, gap_q, lost_q;
  logic [15:0]             exp_q;                 // data flits expected so far (FLOW_CTRL)

  // ---- flow-control view of the flit completing this cycle -----------------------------
  /* verilator lint_off UNUSEDSIGNAL */
  logic [FLIT_BYTES*8-1:0] arr_flit;      // only header + flow-control bytes are examined
  /* verilator lint_on UNUSEDSIGNAL */
  always_comb begin
    arr_flit = cap_q;
    arr_flit[(FLIT_BEATS-1)*UCIE_BUS_W +: UCIE_BUS_W] = ucie_rx_data;
  end
  wire        arr_last  = ucie_rx_valid && !ucie_rx_start_flit && locked_q &&
                          (int'(cnt_q) == FLIT_BEATS - 1);
  wire [7:0]  arr_plen  = arr_flit[15:8];
  wire        arr_data  = (arr_plen != 8'd0);
  wire        arr_cr    = (arr_plen == 8'd0) && !arr_flit[1] && !arr_flit[2];
  wire        arr_ok    = FLOW_CTRL && arr_last && arr_flit[0] &&
                          ((arr_data && int'(arr_plen) <= FLIT_PAYLOAD_B) || arr_cr);
  wire [15:0] arr_seq   = arr_flit[8*FLIT_FC_OFF +: 16];
  wire [15:0] arr_cl    = arr_flit[8*(FLIT_FC_OFF+2) +: 16];
  wire [15:0] seq_gapn  = arr_seq - exp_q;                       // flits missing before this one
  wire        seq_back  = seq_gapn[15];                          // "behind" expected: resync, no loss
  wire        seq_gap   = arr_ok && (seq_gapn != 16'd0);
  wire        drop_now  = arr_last && !(arr_ok && arr_cr) && full_q && !flit_taken;
  wire [15:0] lost_add  = arr_ok ? ((seq_back ? 16'd0 : seq_gapn) + ((arr_data && drop_now) ? 16'd1 : 16'd0))
                                 : 16'd0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cap_q         <= '0;
      flit_q        <= '0;
      cnt_q         <= '0;
      locked_q      <= 1'b0;
      full_q        <= 1'b0;
      gap_q         <= 1'b0;
      lost_q        <= 1'b0;
      dropped_flits <= '0;
      lock_errors   <= '0;
      exp_q         <= '0;
      fc_cl_remote  <= '0;
      fc_lost_cnt   <= '0;
    end else begin
      if (full_q && flit_taken) full_q <= 1'b0;

      if (arr_ok) begin
        exp_q       <= arr_seq + (arr_data ? 16'd1 : 16'd0);
        fc_lost_cnt <= fc_lost_cnt + lost_add;
        if (!(arr_cl - fc_cl_remote > 16'h7FFF)) fc_cl_remote <= arr_cl;   // keep the newest (modular)
      end

      if (ucie_rx_valid) begin
        if (ucie_rx_start_flit) begin
          if (locked_q) begin
            lock_errors <= (&lock_errors) ? lock_errors : lock_errors + 16'd1;   // start_flit mid-flit
            lost_q      <= 1'b1;
          end
          cap_q[UCIE_BUS_W-1:0] <= ucie_rx_data;
          cnt_q    <= CW'(1);
          locked_q <= 1'b1;
        end else if (locked_q) begin
          cap_q[int'(cnt_q)*UCIE_BUS_W +: UCIE_BUS_W] <= ucie_rx_data;
          if (int'(cnt_q) == FLIT_BEATS - 1) begin
            locked_q <= 1'b0;
            cnt_q    <= '0;
            if (arr_ok && arr_cr) begin
              if (seq_gap) lost_q <= 1'b1;         // credit-only: consumed, never stored
            end else if (full_q && !flit_taken) begin
              dropped_flits <= (&dropped_flits) ? dropped_flits : dropped_flits + 16'd1;
              lost_q        <= 1'b1;
            end else begin
              flit_q <= cap_q;
              flit_q[(FLIT_BEATS-1)*UCIE_BUS_W +: UCIE_BUS_W] <= ucie_rx_data;
              full_q <= 1'b1;
              gap_q  <= lost_q | seq_gap;
              lost_q <= 1'b0;
            end
          end else begin
            cnt_q <= cnt_q + CW'(1);
          end
        end else begin
          lock_errors <= (&lock_errors) ? lock_errors : lock_errors + 16'd1;     // data outside a flit
          lost_q      <= 1'b1;
        end
      end else if (locked_q) begin
        locked_q    <= 1'b0;                      // valid dropped mid-flit
        cnt_q       <= '0;
        lock_errors <= (&lock_errors) ? lock_errors : lock_errors + 16'd1;
        lost_q      <= 1'b1;
      end
    end
  end

  assign flit_valid = full_q;
  assign flit       = flit_q;
  assign flit_gap   = gap_q;
  assign idle       = !locked_q && !full_q;

endmodule : rx_ingress

// ---- rtl/rx_deframer.sv ----------------------------------------------------
// ============================================================================
// rx_deframer.sv — ucie_clk domain.  Unpacks a received flit's payload bytes into
// PCIE_DATA_W-wide PCIe beats {err, tlast, tkeep, tdata} for the Rx CDC FIFO.
// Full beats are emitted as they fill; the eof flit closes the frame with a
// partial low-aligned tkeep and tlast.
//
// Frame integrity (docs/OPEN_DECISIONS.md D9).  At the start of each flit:
//  * in a frame, and the flit follows a lost flit (flit_gap), has sof set, or has
//    a bad header  -> ABORT: emit the bytes accumulated so far as a tlast beat
//    with err=1 (pcie_rx_tuser[0]); if nothing is accumulated a single 0x00 byte
//    is emitted so the tlast beat has a legal nonzero tkeep.  The flit is then
//    re-examined out-of-frame on the next cycle.
//  * bad header (valid clear, count 0 or > FLIT_PAYLOAD_B)  -> dropped, bad_flits++
//  * out of frame and sof clear (orphan continuation)       -> dropped, bad_flits++
// ============================================================================

module rx_deframer
  import pcie_ucie3d_pkg::*;
(
  input  logic                                clk,
  input  logic                                rst_n,

  input  logic                                flit_valid,
  input  logic [FLIT_BYTES*8-1:0]             flit,
  input  logic                                flit_gap,
  output logic                                flit_taken,
  output logic                                data_done,    // a valid-header data flit was consumed (credit accounting)

  output logic [PCIE_DATA_W+PCIE_KEEP_W+1:0]  fifo_wdata,   // {err, last, keep, data}
  output logic                                fifo_winc,
  input  logic                                fifo_full,

  output logic                                idle,         // no frame in progress
  output logic [15:0]                         bad_flits,
  output logic [15:0]                         aborted_frames
);
  localparam int unsigned OFFW = $clog2(FLIT_PAYLOAD_B + 1);
  localparam int unsigned ACCW = $clog2(PCIE_KEEP_W + 1);

  logic [OFFW-1:0]          rd_off_q;
  logic [PCIE_DATA_W-1:0]   acc_q;
  logic [ACCW-1:0]          acc_n_q;
  logic                     in_frame_q;

  wire        hv    = flit[0];
  wire        hsof  = flit[1];
  wire        heof  = flit[2];
  wire [7:0]  plen8 = flit[15:8];
  wire        bad   = !hv || (plen8 == 8'd0) || (int'(plen8) > FLIT_PAYLOAD_B);
  wire        fstart = (rd_off_q == '0);
  wire        abort  = flit_valid && fstart && in_frame_q && (flit_gap || hsof || bad);
  wire        drop   = flit_valid && fstart && !in_frame_q && (bad || !hsof);

  logic [PCIE_DATA_W-1:0] acc_n;
  logic [PCIE_KEEP_W-1:0] keep_n;
  int                     plen, take, room, left, cnt_n, off_n;
  logic                   done, emit, last, advance;

  always_comb begin
    acc_n      = acc_q;
    keep_n     = '0;
    plen       = int'(plen8);
    left       = plen - int'(rd_off_q);
    room       = PCIE_KEEP_W - int'(acc_n_q);
    take       = (left < room) ? left : room;
    cnt_n      = int'(acc_n_q) + take;
    off_n      = int'(rd_off_q) + take;
    done       = (off_n == plen);
    last       = done && heof;
    emit       = (cnt_n == PCIE_KEEP_W) || last;
    advance    = 1'b0;
    flit_taken = 1'b0;
    fifo_winc  = 1'b0;

    if (abort) begin
      last = 1'b1;
      for (int k = 0; k < PCIE_KEEP_W; k++)
        keep_n[k] = (k < int'(acc_n_q)) || (k == 0);
      fifo_winc = !fifo_full;
    end else if (drop) begin
      flit_taken = 1'b1;
    end else if (flit_valid) begin
      if (!(emit && fifo_full)) begin
        advance = 1'b1;
        for (int j = 0; j < PCIE_KEEP_W; j++)
          if (j < take)
            acc_n[8*(int'(acc_n_q) + j) +: 8] = flit[8*(FLIT_HDR_B + int'(rd_off_q) + j) +: 8];
        for (int k = 0; k < PCIE_KEEP_W; k++)
          keep_n[k] = (k < cnt_n);
        fifo_winc  = emit;
        flit_taken = done;
      end
    end
  end

  assign fifo_wdata = {abort, last, keep_n, abort ? acc_q : acc_n};
  assign idle       = !in_frame_q;
  assign data_done  = flit_taken && !bad;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_off_q       <= '0;
      acc_q          <= '0;
      acc_n_q        <= '0;
      in_frame_q     <= 1'b0;
      bad_flits      <= '0;
      aborted_frames <= '0;
    end else if (abort) begin
      if (!fifo_full) begin
        acc_q          <= '0;
        acc_n_q        <= '0;
        in_frame_q     <= 1'b0;
        aborted_frames <= (&aborted_frames) ? aborted_frames : aborted_frames + 16'd1;
      end
    end else if (drop) begin
      bad_flits <= (&bad_flits) ? bad_flits : bad_flits + 16'd1;
    end else if (advance) begin
      acc_q      <= emit ? '0 : acc_n;
      acc_n_q    <= emit ? '0 : ACCW'(cnt_n);
      rd_off_q   <= done ? '0 : OFFW'(off_n);
      in_frame_q <= !last;
    end
  end

endmodule : rx_deframer

// ---- rtl/pcie_egress.sv ----------------------------------------------------
// ============================================================================
// pcie_egress.sv — pcie_clk domain.  Presents the Rx CDC FIFO head (FWFT) as the
// pcie_rx_* AXI4-Stream master.  FIFO word = {err, last, keep, data};
// pcie_rx_tuser[0] = err on the tlast beat of an aborted frame (D9), other bits 0.
// ============================================================================

module pcie_egress
  import pcie_ucie3d_pkg::*;
(
  input  logic [PCIE_DATA_W+PCIE_KEEP_W+1:0] fifo_rdata,
  input  logic                               fifo_empty,
  output logic                               fifo_rinc,

  output logic                               pcie_rx_tvalid,
  input  logic                               pcie_rx_tready,
  output logic [PCIE_DATA_W-1:0]             pcie_rx_tdata,
  output logic [PCIE_KEEP_W-1:0]             pcie_rx_tkeep,
  output logic                               pcie_rx_tlast,
  output logic [PCIE_USER_W-1:0]             pcie_rx_tuser
);
  assign pcie_rx_tvalid = !fifo_empty;
  assign pcie_rx_tdata  = fifo_rdata[PCIE_DATA_W-1:0];
  assign pcie_rx_tkeep  = fifo_rdata[PCIE_DATA_W +: PCIE_KEEP_W];
  assign pcie_rx_tlast  = fifo_rdata[PCIE_DATA_W+PCIE_KEEP_W];
  assign pcie_rx_tuser  = {{(PCIE_USER_W-1){1'b0}}, fifo_rdata[PCIE_DATA_W+PCIE_KEEP_W+1]};
  assign fifo_rinc      = pcie_rx_tvalid && pcie_rx_tready;
endmodule : pcie_egress

// ---- rtl/adapter_rf.sv -----------------------------------------------------
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

// ---- rtl/adapter_ctrl_fsm.sv -----------------------------------------------
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

// ---- rtl/ucie_sb_master.sv -------------------------------------------------
// ============================================================================
// ucie_sb_master.sv — ucie_clk domain.  UCIe-3D sideband master.
//
// Issues one committed register write at a time on the 8-bit M2S byte bus
// (idle 8'h00; pcie_ucie3d_pkg SB_* opcodes, docs/OPEN_DECISIONS.md D8):
//   cycle 0: m2s = {SB_WR, 4'h0}
//   cycle 1: m2s = addr[15:8]
//   cycle 2: m2s = addr[7:0]
//   cycle 3: m2s = wdata[7:0]      (then idle 8'h00)
//   then waits for an S2M byte with s2m[7:4] == SB_WR_ACK, or SB_TIMEOUT cycles.
// `done` pulses on the ack, `timeout` pulses instead if no ack arrives.  In raw
// mode the adapter is the only sideband master, so there is no inbound traffic to
// arbitrate against: the ack is the only non-idle S2M byte expected while waiting.
// ============================================================================

module ucie_sb_master
  import pcie_ucie3d_pkg::*;
(
  input  logic                     clk,
  input  logic                     rst_n,

  input  logic                     req,        // start a write (ignored while busy)
  input  logic [SB_ADDR_W-1:0]     addr,
  input  logic [7:0]               wdata,
  output logic                     busy,
  output logic                     done,       // 1-cycle pulse: write_ack received
  output logic                     timeout,    // 1-cycle pulse: no write_ack

  output logic [SB_W-1:0]          m2s,
  input  logic [SB_W-1:0]          s2m         // remote die -> adapter sideband byte
);
  localparam int unsigned TW = $clog2(SB_TIMEOUT + 1);
  localparam logic [2:0] S_IDLE = 3'd0, S_AHI = 3'd1, S_ALO = 3'd2, S_DATA = 3'd3, S_WAIT = 3'd4;

  logic [2:0]          st_q;
  logic [SB_ADDR_W-1:0] addr_q;
  logic [7:0]          wdata_q;
  logic [TW-1:0]       tmr_q;

  wire s2m_ack = (s2m != 8'h00) && (s2m[7:4] == SB_WR_ACK);

  assign busy = (st_q != S_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st_q    <= S_IDLE;
      addr_q  <= '0;
      wdata_q <= '0;
      tmr_q   <= '0;
      m2s     <= 8'h00;
      done    <= 1'b0;
      timeout <= 1'b0;
    end else begin
      done    <= 1'b0;
      timeout <= 1'b0;
      case (st_q)
        S_IDLE: begin
          m2s <= 8'h00;
          if (req) begin
            m2s     <= {SB_WR, 4'h0};        // byte 0
            addr_q  <= addr;
            wdata_q <= wdata;
            st_q    <= S_AHI;
          end
        end
        S_AHI: begin
          m2s  <= addr_q[SB_ADDR_W-1:8];     // byte 1
          st_q <= S_ALO;
        end
        S_ALO: begin
          m2s  <= addr_q[7:0];               // byte 2
          st_q <= S_DATA;
        end
        S_DATA: begin
          m2s   <= wdata_q;                  // byte 3
          tmr_q <= '0;
          st_q  <= S_WAIT;
        end
        default: begin // S_WAIT
          m2s <= 8'h00;
          if (s2m_ack) begin
            done <= 1'b1;
            st_q <= S_IDLE;
          end else if (int'(tmr_q) == SB_TIMEOUT - 1) begin
            timeout <= 1'b1;
            st_q    <= S_IDLE;
          end else begin
            tmr_q <= tmr_q + TW'(1);
          end
        end
      endcase
    end
  end

endmodule : ucie_sb_master

// ---- rtl/tx_ingress_gate.sv ------------------------------------------------
// ============================================================================
// tx_ingress_gate.sv — pcie_clk domain.  Closes the PCIe ingress at a frame
// boundary when the control FSM asks to drain (stop_req, from ucie_clk).
//
// pcie_tready = !fifo_full && !(stop && !in_frame): a frame already started is
// always allowed to finish; a new frame is not accepted while stopped.
// `stopped` is registered from the PREVIOUS in_frame value so it rises one
// pcie_clk after the last accepted beat was written to the CDC FIFO; the FSM
// synchronises it into ucie_clk (3 flops) so the FIFO's own empty flag has
// settled by the time it sees `stopped`.  Out of reset the gate is closed (stop=1).
// ============================================================================
module tx_ingress_gate (
  input  logic pcie_clk,
  input  logic pcie_rst_n,
  input  logic stop_req,       // async (ucie_clk domain), synchronised here
  input  logic fifo_full,
  input  logic pcie_tvalid,
  input  logic pcie_tlast,
  output logic pcie_tready,
  output logic stopped         // pcie_clk domain; synchronise before use in ucie_clk
);
  logic stop_s1, stop_s2, in_frame_q;

  always_ff @(posedge pcie_clk or negedge pcie_rst_n) begin
    if (!pcie_rst_n) {stop_s2, stop_s1} <= 2'b11;
    else             {stop_s2, stop_s1} <= {stop_s1, stop_req};
  end

  assign pcie_tready = !fifo_full && !(stop_s2 && !in_frame_q);

  always_ff @(posedge pcie_clk or negedge pcie_rst_n) begin
    if (!pcie_rst_n) begin
      in_frame_q <= 1'b0;
      stopped    <= 1'b1;
    end else begin
      if (pcie_tvalid && pcie_tready) in_frame_q <= !pcie_tlast;
      stopped <= stop_s2 && !in_frame_q;
    end
  end

endmodule : tx_ingress_gate

// ---- rtl/pcie_ucie3d_adapter.sv --------------------------------------------
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

  assign tx_idle = tx_fifo_empty && framer_idle && !egress_busy;
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

  tx_egress u_tx_egress (
    .clk (ucie_clk), .rst_n (`DP_UCIE_RST), .tx_en (tx_en),
    .flit_valid (flit_valid), .flit (flit), .flit_taken (flit_taken),
    .credit_ok (1'b1), .cr_req (1'b0), .seq_now ('0), .cl_now ('0),
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
  /* verilator lint_off UNUSEDSIGNAL */
  wire unused_obs = (^tx_wfree_unused) ^ tx_st_any ^ tx_st_data ^ sb_busy ^ rx_dfr_idle
                  ^ rx_data_done ^ (^rx_cl_remote) ^ (^rx_fc_lost) ^ (^pcie_tuser)
                  ^ rx_out_idle ^ (^rx_wfree);   // used only in the DP-reset-on config
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
// ============================================================================
// dv/uvm/adapter_uvm_pkg.sv — UVM environment for pcie_ucie3d_adapter (DV env 3).
//
//   smoke_test      : reset/defaults + link-up contract (tie-off, no env)
//   frame_seq -> pcie_sequencer -> pcie_tx_driver  (PCIe AXI4-S source)
//   pcie_rx_monitor : tready responder + frame reassembly -> analysis port
//   ucie_phy_driver : remote die — bring-up (link_status/rx_active/rx_elec_idle),
//                     UCIe-3D Tx->Rx loopback, Tx flit monitor, 8-bit sideband
//                     target + ack, Tx-legality checker (mirror ucie_sb_model.sv)
//   csr_agent       : CSR read/write/poll tasks (ucie_clk)
//   adapter_sb      : in-order byte check + CRC-32 per scenario
//   scen_test       : runs the shared five-scenario set, writes results.json
// Drive with NBAs after @(posedge clk); sample right after @(posedge clk).
// ============================================================================
`include "uvm_macros.svh"

package adapter_uvm_pkg;
  import uvm_pkg::*;
  import pcie_ucie3d_pkg::*;

// (inlined pcie_pat.svh)

// ---- dv/common/pcie_pat.svh ------------------------------------------------
// dv/common/pcie_pat.svh — deterministic frame byte pattern.
// Must equal scenarios.pat() in dv/common/scenarios.py (and scen_pat in scenarios.svh):
//   pat(id, idx) = (id*37 + idx*13 + (idx>>8) + 5) & 0xFF
`ifndef PCIE_PAT_SVH
`define PCIE_PAT_SVH
function automatic logic [7:0] pat(input int frame_id, input int idx);
  return 8'((frame_id * 37 + idx * 13 + (idx >> 8) + 5) & 'hFF);
endfunction
`endif
// (inlined scenarios.svh)

// ---- dv/common/scenarios.svh -----------------------------------------------
// dv/common/scenarios.svh — SystemVerilog mirror of dv/common/scenarios.py.
// Same pat()/LCG constants so the Icarus and UVM envs compute the golden
// expectations the Python model does.  The frame byte pattern lives in
// pcie_pat.svh (pat()); this file holds the scenario-driver helpers used by
// tb_scen / the UVM scen test to run the shared set and emit results.json.
`ifndef SCENARIOS_SVH
`define SCENARIOS_SVH

localparam int FLIT_PAYLOAD_B_MIRROR = 240;

// ---------------------------------------------------------------------------
// Scenario-driver view of scenarios.py (the golden definition — keep in sync).
//   index : 0 single, 1 corners, 2 random, 3 pm_cycle, 4 speed_change
//   ctrl  : 0 none, 1 pm_cycle (L0->L1->L0), 2 speed_change (64->32->64)
// `include inside a module scope that also includes pcie_pat.svh.
// ---------------------------------------------------------------------------
localparam int SCEN_N = 5;

function automatic string scen_name(input int s);
  case (s)
    0: scen_name = "single";
    1: scen_name = "corners";
    2: scen_name = "random";
    3: scen_name = "pm_cycle";
    default: scen_name = "speed_change";
  endcase
endfunction

function automatic int scen_ctrl(input int s);
  scen_ctrl = (s == 3) ? 1 : (s == 4) ? 2 : 0;
endfunction

function automatic int scen_nframes(input int s);
  case (s)
    0: scen_nframes = 1;
    1: scen_nframes = 11;
    2: scen_nframes = 40;
    default: scen_nframes = 16;      // pm_cycle, speed_change
  endcase
endfunction

function automatic longint unsigned scen_seed(input int s);
  scen_seed = (s == 2) ? 64'hC0FFEE : (s == 3) ? 64'd7 : 64'd11;
endfunction

// Length of frame i of scenario s — mirrors scenarios.lengths()/lcg_lengths().
// LCG: x0 = seed & 0x7FFFFFFF; x = (1103515245*x + 12345) & 0x7FFFFFFF;
//      len = 1 + ((x >> 8) % 2000), replayed (i+1) steps from the seed.
function automatic int scen_len(input int s, input int i);
  longint unsigned x;
  int r;
  begin
    r = 0;
    if (s == 0) r = 256;
    else if (s == 1) begin
      case (i)
        0: r = 1;    1: r = 31;   2: r = 32;   3: r = 33;   4: r = 239; 5: r = 240;
        6: r = 241;  7: r = 480;  8: r = 481;  9: r = 1500; default: r = 4096;
      endcase
    end else begin
      x = scen_seed(s) & 64'h7FFF_FFFF;
      for (int k = 0; k <= i; k++) x = (64'd1103515245 * x + 64'd12345) & 64'h7FFF_FFFF;
      r = 1 + int'((x >> 8) % 64'd2000);
    end
    scen_len = r;
  end
endfunction

// CRC-32 (IEEE, reflected) running state: start 32'hFFFF_FFFF, final = ~state.
function automatic logic [31:0] crc32_byte(input logic [31:0] c, input logic [7:0] b);
  logic [31:0] r;
  begin
    r = c ^ {24'h0, b};
    for (int k = 0; k < 8; k++) r = r[0] ? ((r >> 1) ^ 32'hEDB8_8320) : (r >> 1);
    crc32_byte = r;
  end
endfunction

`endif // SCENARIOS_SVH

  // ------------------------------------------------------------------ items
  class pcie_frame_item extends uvm_sequence_item;
    int fid;
    int len;
    `uvm_object_utils(pcie_frame_item)
    function new(string name = "pcie_frame_item"); super.new(name); endfunction
  endclass

  class rx_frame extends uvm_object;
    byte unsigned data[$];
    bit err;
    `uvm_object_utils(rx_frame)
    function new(string name = "rx_frame"); super.new(name); endfunction
  endclass

  typedef uvm_sequencer #(pcie_frame_item) pcie_sequencer;

  class frame_seq extends uvm_sequence #(pcie_frame_item);
    int scen, lo, hi;
    `uvm_object_utils(frame_seq)
    function new(string name = "frame_seq"); super.new(name); endfunction
    task body();
      for (int i = lo; i < hi; i++) begin
        pcie_frame_item it = pcie_frame_item::type_id::create($sformatf("f%0d", i));
        start_item(it);
        it.fid = i;
        it.len = scen_len(scen, i);
        finish_item(it);
      end
    endtask
  endclass

  // ------------------------------------------------------------ PCIe tx driver
  class pcie_tx_driver extends uvm_driver #(pcie_frame_item);
    virtual adapter_if vif;
    int gap_pct = 10;
    `uvm_component_utils(pcie_tx_driver)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(virtual adapter_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "vif not set")
    endfunction
    task run_phase(uvm_phase phase);
      pcie_frame_item it;
      logic [PCIE_DATA_W-1:0] d;
      logic [PCIE_KEEP_W-1:0] k;
      int off, n;
      vif.pcie_tvalid <= 1'b0;
      vif.pcie_tlast  <= 1'b0;
      @(posedge vif.pcie_clk);
      forever begin
        seq_item_port.get_next_item(it);
        off = 0;
        while (off < it.len) begin
          if (gap_pct > 0 && $urandom_range(99, 0) < gap_pct) begin
            vif.pcie_tvalid <= 1'b0;
            @(posedge vif.pcie_clk);
            continue;
          end
          n = it.len - off;
          if (n > PCIE_KEEP_W) n = PCIE_KEEP_W;
          d = '0; k = '0;
          for (int i = 0; i < n; i++) begin
            d[8*i +: 8] = pat(it.fid, off + i);
            k[i] = 1'b1;
          end
          vif.pcie_tvalid <= 1'b1;
          vif.pcie_tdata  <= d;
          vif.pcie_tkeep  <= k;
          vif.pcie_tuser  <= '0;
          vif.pcie_tlast  <= (off + n == it.len);
          do @(posedge vif.pcie_clk); while (!(vif.pcie_tvalid && vif.pcie_tready));
          off += n;
        end
        vif.pcie_tvalid <= 1'b0;
        vif.pcie_tlast  <= 1'b0;
        seq_item_port.item_done();
        @(posedge vif.pcie_clk);
      end
    endtask
  endclass

  // ------------------------------------------------------------ PCIe rx monitor
  class pcie_rx_monitor extends uvm_component;
    virtual adapter_if vif;
    uvm_analysis_port #(rx_frame) ap;
    int ready_pct = 90;
    int errors = 0;
    `uvm_component_utils(pcie_rx_monitor)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      ap = new("ap", this);
      if (!uvm_config_db#(virtual adapter_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "vif not set")
    endfunction
    task run_phase(uvm_phase phase);
      rx_frame fr = rx_frame::type_id::create("fr");
      int nb;
      vif.pcie_rx_tready <= 1'b0;
      forever begin
        @(posedge vif.pcie_clk);
        if (vif.pcie_rst_n && vif.pcie_rx_tvalid && vif.pcie_rx_tready) begin
          nb = 0;
          for (int i = 0; i < PCIE_KEEP_W; i++) nb += int'(vif.pcie_rx_tkeep[i]);
          if (nb == 0 || vif.pcie_rx_tkeep != PCIE_KEEP_W'((64'd1 << nb) - 1) ||
              (!vif.pcie_rx_tlast && nb != PCIE_KEEP_W) || (vif.pcie_rx_tuser[0] && !vif.pcie_rx_tlast)) begin
            errors++;
            `uvm_error("RXMON", $sformatf("illegal tkeep %h last %b", vif.pcie_rx_tkeep, vif.pcie_rx_tlast))
          end
          for (int i = 0; i < nb; i++) fr.data.push_back(vif.pcie_rx_tdata[8*i +: 8]);
          if (vif.pcie_rx_tlast) begin
            fr.err = vif.pcie_rx_tuser[0];
            ap.write(fr);
            fr = rx_frame::type_id::create("fr");
          end
        end
        vif.pcie_rx_tready <= vif.pcie_rst_n && ($urandom_range(99, 0) < ready_pct);
      end
    endtask
  endclass

  // ------------------------------------------------------------ UCIe remote die
  class ucie_phy_driver extends uvm_component;
    virtual adapter_if vif;
    int unsigned flits = 0;
    int unsigned cr_flits = 0;   // credit-only flits (FLOW_CTRL, D16)
    int unsigned fc_sent = 0;    // data flits since the last DUT reset (expected seq field)
    int unsigned sb_writes = 0;
    logic        in_frame = 1'b0;
    logic [FLIT_BYTES*8-1:0] fl;
    int errors = 0;
    `uvm_component_utils(ucie_phy_driver)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(virtual adapter_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "vif not set")
    endfunction

    // Flit legality + classification (mirror of ucie_phy_model.sv).
    function void check_flit();
      int plen;
      bit hv, hsof, heof, crflit, padbad;
      hv = fl[0]; hsof = fl[1]; heof = fl[2]; plen = int'(fl[15:8]);
      if (!hv) begin errors++; `uvm_error("PHY", "header valid bit clear") end
      if (fl[7:3] != 5'b0) begin errors++; `uvm_error("PHY", "header reserved bits nonzero") end
      if (plen > FLIT_PAYLOAD_B) begin errors++; `uvm_error("PHY", "payload length > 240") end
      crflit = FLOW_CTRL && plen == 0 && !hsof && !heof;
      if (plen == 0 && !crflit) begin errors++; `uvm_error("PHY", "empty flit emitted") end
      if (!crflit && hsof !== !in_frame) begin errors++; `uvm_error("PHY", "sof/frame state mismatch") end
      padbad = 1'b0;
      for (int b = FLIT_HDR_B + plen; b < FLIT_BYTES; b++)
        if (!(FLOW_CTRL && b >= FLIT_FC_OFF && b < FLIT_FC_OFF + 4) && fl[8*b +: 8] !== 8'h00) padbad = 1'b1;
      if (padbad) begin errors++; `uvm_error("PHY", "nonzero padding/DLP/FEC byte") end
      if (FLOW_CTRL && fl[8*FLIT_FC_OFF +: 16] !== 16'(fc_sent)) begin
        errors++; `uvm_error("PHY", "flow-control seq field != data flits sent before")
      end
      if (crflit) cr_flits++;
      else begin flits++; fc_sent++; in_frame = !heof; end
    endfunction

    task run_phase(uvm_phase phase);
      logic [1:0] pd, pd_q, wd, wd_q;
      logic [2:0] sp, sp_q;
      int rd_phase, rst_cnt, sb_cnt, mb_cnt, st_cnt, ack_cnt, beat, sb_ph;
      logic [SB_ADDR_W-1:0] sb_addr;
      logic [SB_W-1:0] m2s;
      bit change;
      localparam int LAT = 8, RST_CYCLES = 16, SB_LAT = 8, MB_LAT = 8;
      vif.ucie_link_status  <= 1'b1;
      vif.ucie_rx_active    <= 1'b0;
      vif.ucie_rx_elec_idle <= 1'b1;
      vif.ucie_sb_s2m       <= '0;
      vif.ucie_rx_data <= '0; vif.ucie_rx_valid <= 1'b0; vif.ucie_rx_start_flit <= 1'b0;
      rd_phase = 0; rst_cnt = 0; sb_cnt = 0; mb_cnt = 0; st_cnt = 0; ack_cnt = 0; beat = 0; sb_ph = 0;
      sb_addr = '0; pd_q = '0; sp_q = '0; wd_q = '0;
      forever begin
        @(posedge vif.ucie_clk);
        // registered UCIe-3D Tx -> Rx loopback
        vif.ucie_rx_data       <= vif.ucie_tx_data;
        vif.ucie_rx_valid      <= vif.ucie_tx_valid;
        vif.ucie_rx_start_flit <= vif.ucie_tx_start_flit;
        if (!vif.ucie_rst_n) begin
          vif.ucie_link_status  <= 1'b1;
          vif.ucie_rx_active    <= 1'b0;
          vif.ucie_rx_elec_idle <= 1'b1;
          vif.ucie_sb_s2m       <= '0;
          rd_phase = 0; rst_cnt = 0; sb_cnt = 0; mb_cnt = 0; st_cnt = 0; ack_cnt = 0;
          beat = 0; sb_ph = 0; fc_sent = 0; in_frame = 1'b0;
          pd_q = logic'(vif.ucie_powerdown); sp_q = logic'(vif.ucie_speed); wd_q = vif.ucie_width;
          continue;
        end
        // flit monitor (Tx side)
        if (vif.ucie_tx_valid) begin
          if (vif.ucie_tx_start_flit != (beat == 0)) begin errors++; `uvm_error("PHY", "start_flit misplaced") end
          fl[beat*UCIE_BUS_W +: UCIE_BUS_W] = vif.ucie_tx_data;
          if (beat == FLIT_BEATS - 1) check_flit();
          beat = (beat + 1) % FLIT_BEATS;
        end else if (beat != 0) begin
          errors++; `uvm_error("PHY", "tx_valid dropped mid-flit") beat = 0;
        end
        // bring-up sequencer + op-complete link_status pulse
        pd = logic'(vif.ucie_powerdown); sp = logic'(vif.ucie_speed); wd = vif.ucie_width;
        change = (pd != pd_q) || (sp != sp_q) || (wd != wd_q);
        vif.ucie_link_status <= 1'b0;
        if (rd_phase == 0) begin
          vif.ucie_link_status <= 1'b1;
          if (rst_cnt < RST_CYCLES) rst_cnt++;
          else begin vif.ucie_link_status <= 1'b0; rd_phase = 1; sb_cnt = 0; end
        end else if (rd_phase == 1) begin
          if (sb_cnt < SB_LAT) sb_cnt++;
          else begin vif.ucie_rx_elec_idle <= 1'b0; rd_phase = 2; mb_cnt = 0; end
        end else if (rd_phase == 2) begin
          if (mb_cnt < MB_LAT) mb_cnt++;
          else begin vif.ucie_rx_active <= 1'b1; rd_phase = 3; end
        end else begin
          if (change) st_cnt = LAT;
          else if (st_cnt == 1) begin st_cnt = 0; vif.ucie_link_status <= 1'b1; end
          else if (st_cnt > 1) st_cnt--;
        end
        // Tx legality
        if (vif.ucie_tx_valid && pd != PWR_L0) begin errors++; `uvm_error("PHY", "Tx valid while powerdown != L0") end
        if (vif.ucie_tx_valid && (st_cnt != 0 || change)) begin errors++; `uvm_error("PHY", "Tx valid during a change") end
        pd_q = pd; sp_q = sp; wd_q = wd;
        // sideband target (byte-serial write + ack)
        m2s = vif.ucie_sb_m2s;
        vif.ucie_sb_s2m <= '0;
        if (sb_ph == 1) begin sb_addr[SB_ADDR_W-1:8] = m2s; sb_ph = 2; end
        else if (sb_ph == 2) begin sb_addr[7:0] = m2s; sb_ph = 3; end
        else if (sb_ph == 3) begin sb_writes++; sb_ph = 0; ack_cnt = LAT; end
        else if (m2s != 8'h00) begin
          if (m2s[7:4] == SB_WR) sb_ph = 1;
          else begin errors++; `uvm_error("PHY", "unsupported M2S sideband command") end
        end
        if (ack_cnt == 1) begin ack_cnt = 0; vif.ucie_sb_s2m <= {SB_WR_ACK, 4'h0}; end
        else if (ack_cnt > 1) ack_cnt--;
      end
    endtask
  endclass

  // ------------------------------------------------------------ CSR agent
  class csr_agent extends uvm_component;
    virtual adapter_if vif;
    `uvm_component_utils(csr_agent)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(virtual adapter_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "vif not set")
    endfunction
    task run_phase(uvm_phase phase);
      vif.csr_valid <= 1'b0; vif.csr_write <= 1'b0; vif.csr_addr <= '0; vif.csr_wdata <= '0;
    endtask
    task write(logic [7:0] a, logic [31:0] d);
      @(posedge vif.ucie_clk);
      vif.csr_valid <= 1'b1; vif.csr_write <= 1'b1; vif.csr_addr <= a; vif.csr_wdata <= d;
      @(posedge vif.ucie_clk);
      vif.csr_valid <= 1'b0; vif.csr_write <= 1'b0;
    endtask
    task read(logic [7:0] a, output logic [31:0] d);
      @(posedge vif.ucie_clk);
      vif.csr_addr <= a;
      @(posedge vif.ucie_clk);
      d = vif.csr_rdata;
    endtask
    task set_state(logic [1:0] pd, logic [2:0] sp, output bit ok);
      logic [31:0] s;
      write(CSR_CTRL, {25'b0, 2'b00, sp, pd});
      ok = 0;
      for (int t = 0; t < 40000 && !ok; t++) begin
        read(CSR_STATUS, s);
        ok = (s[1:0] == pd) && (s[4:2] == sp) && !s[11];
      end
    endtask
  endclass

  // ------------------------------------------------------------ scoreboard
  class adapter_sb extends uvm_subscriber #(rx_frame);
    int scen;
    int frames, errors;
    longint nbytes;
    logic [31:0] crc;
    `uvm_component_utils(adapter_sb)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void start(int s);
      scen = s; frames = 0; errors = 0; nbytes = 0; crc = 32'hFFFF_FFFF;
    endfunction
    function void write(rx_frame t);
      if (t.err || frames >= scen_nframes(scen) || t.data.size() != scen_len(scen, frames)) begin
        errors++;
        `uvm_error("SB", $sformatf("%s frame %0d len %0d err %b", scen_name(scen), frames, t.data.size(), t.err))
      end else begin
        foreach (t.data[i])
          if (t.data[i] != pat(frames, i)) begin
            errors++;
            `uvm_error("SB", $sformatf("%s frame %0d byte %0d", scen_name(scen), frames, i))
            break;
          end
      end
      foreach (t.data[i]) crc = crc32_byte(crc, t.data[i]);
      nbytes += t.data.size();
      frames++;
    endfunction
  endclass

  // ------------------------------------------------------------ env
  class adapter_env extends uvm_env;
    pcie_sequencer  seqr;
    pcie_tx_driver  drv;
    pcie_rx_monitor rxm;
    ucie_phy_driver phy;
    csr_agent       csr;
    adapter_sb      sb;
    `uvm_component_utils(adapter_env)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      seqr = pcie_sequencer::type_id::create("seqr", this);
      drv  = pcie_tx_driver::type_id::create("drv", this);
      rxm  = pcie_rx_monitor::type_id::create("rxm", this);
      phy  = ucie_phy_driver::type_id::create("phy", this);
      csr  = csr_agent::type_id::create("csr", this);
      sb   = adapter_sb::type_id::create("sb", this);
    endfunction
    function void connect_phase(uvm_phase phase);
      drv.seq_item_port.connect(seqr.seq_item_export);
      rxm.ap.connect(sb.analysis_export);
    endfunction
  endclass

  // ------------------------------------------------------------ smoke test
  class smoke_test extends uvm_test;
    `uvm_component_utils(smoke_test)
    virtual adapter_if vif;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(virtual adapter_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "adapter_if not set in config db")
    endfunction
    task run_phase(uvm_phase phase);
      int errors = 0;
      phase.raise_objection(this);
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
      if (vif.pcie_tready !== 1'b0)      begin errors++; `uvm_error("SMOKE", "ingress not closed before link-up (M3)") end
      if (errors == 0) `uvm_info("SMOKE", "UVM SMOKE PASS: reset defaults OK", UVM_NONE)
      else             `uvm_error("SMOKE", "UVM SMOKE FAIL")
      phase.drop_objection(this);
    endtask
  endclass

  // ------------------------------------------------------------ scenario test
  class scen_test extends uvm_test;
    adapter_env env;
    virtual adapter_if vif;
    int total_errors = 0;
    `uvm_component_utils(scen_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      env = adapter_env::type_id::create("env", this);
      void'(uvm_config_db#(virtual adapter_if)::get(this, "", "vif", vif));
    endfunction

    task do_reset(output bit ok);
      logic [31:0] s;
      vif.pcie_rst_n <= 1'b0;
      vif.ucie_rst_n <= 1'b0;
      repeat (10) @(posedge vif.ucie_clk);
      vif.pcie_rst_n <= 1'b1;
      vif.ucie_rst_n <= 1'b1;
      ok = 0;
      for (int t = 0; t < 40000 && !ok; t++) begin
        env.csr.read(CSR_STATUS, s);
        ok = s[12];                 // link active
      end
    endtask

    task wait_frames(int n, output bit ok);
      int t = 0;
      while (env.sb.frames < n && t < 400000) begin @(posedge vif.pcie_clk); t++; end
      ok = env.sb.frames >= n;
    endtask

    task run_phase(uvm_phase phase);
      int fd, nfr, f0, e0, errs;
      string rpath;
      bit ok, o;
      logic [31:0] pm;
      frame_seq seq;
      phase.raise_objection(this);
      rpath = "logs/results.json";
      void'($value$plusargs("results=%s", rpath));
      fd = $fopen(rpath, "w");
      $fwrite(fd, "{\"env\": \"uvm\", \"scenarios\": {");
      for (int sc = 0; sc < SCEN_N; sc++) begin
        nfr = scen_nframes(sc);
        env.sb.start(sc);
        do_reset(ok);
        f0 = env.phy.flits;
        e0 = env.phy.errors + env.rxm.errors;
        seq = frame_seq::type_id::create("seq");
        seq.scen = sc;
        if (scen_ctrl(sc) == 0) begin
          seq.lo = 0; seq.hi = nfr; seq.start(env.seqr);
        end else begin
          seq.lo = 0; seq.hi = nfr / 2; seq.start(env.seqr);
          wait_frames(nfr / 2, o); ok &= o;
          if (scen_ctrl(sc) == 1) begin
            env.csr.set_state(PWR_L1, SPEED_64, o); ok &= o;
            repeat (200) @(posedge vif.ucie_clk);
            env.csr.set_state(PWR_L0, SPEED_64, o); ok &= o;
          end else begin
            env.csr.set_state(PWR_L0, SPEED_32, o); ok &= o;
            repeat (200) @(posedge vif.ucie_clk);
            env.csr.set_state(PWR_L0, SPEED_64, o); ok &= o;
          end
          seq = frame_seq::type_id::create("seq_b");
          seq.scen = sc; seq.lo = nfr / 2; seq.hi = nfr; seq.start(env.seqr);
        end
        wait_frames(nfr, o); ok &= o;
        repeat (200) @(posedge vif.pcie_clk);
        env.csr.read(CSR_PMCNT, pm);
        errs = env.sb.errors + (env.phy.errors + env.rxm.errors - e0) + (ok ? 0 : 1);
        total_errors += errs;
        `uvm_info("SCEN", $sformatf("%-12s frames=%0d bytes=%0d flits=%0d crc32=%08x pmcnt=%0d errors=%0d",
                  scen_name(sc), env.sb.frames, env.sb.nbytes, env.phy.flits - f0, ~env.sb.crc, pm[15:0], errs), UVM_LOW)
        $fwrite(fd, "%s\"%s\": {\"frames\": %0d, \"bytes\": %0d, \"flits\": %0d, \"crc32\": \"%08x\", \"pmcnt\": %0d, \"errors\": %0d}",
                (sc == 0) ? "" : ", ", scen_name(sc), env.sb.frames, env.sb.nbytes, env.phy.flits - f0,
                ~env.sb.crc, pm[15:0], errs);
      end
      $fwrite(fd, "}}\n");
      $fclose(fd);
      if (FLOW_CTRL) begin
        `uvm_info("FC", $sformatf("credit-only flits=%0d", env.phy.cr_flits), UVM_LOW)
        if (env.phy.cr_flits == 0) begin
          total_errors++; `uvm_error("FC", "flow control on but no credit-only flit seen (FC not exercised)")
        end
      end
      phase.drop_objection(this);
    endtask

    function void report_phase(uvm_phase phase);
      if (total_errors == 0) `uvm_info("RESULT", "UVM SCEN PASS: 5 scenarios", UVM_NONE)
      else `uvm_error("RESULT", $sformatf("UVM SCEN FAIL: %0d error(s)", total_errors))
    endfunction
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

  // UVM_NO_DPI disables the DPI +UVM_TESTNAME path, so read it explicitly here.
  string tn;
  initial begin
    uvm_config_db#(virtual adapter_if)::set(null, "*", "vif", vif);
    if (!$value$plusargs("UVM_TESTNAME=%s", tn)) tn = "smoke_test";
    run_test(tn);
  end
endmodule
