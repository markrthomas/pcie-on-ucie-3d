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
`include "pcie_ucie3d_pkg.sv"

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
