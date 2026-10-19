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
`include "pcie_ucie3d_pkg.sv"

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
