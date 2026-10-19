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
