// dv/common/scenarios.svh — SystemVerilog mirror of dv/common/scenarios.py.
// Same pat()/LCG constants so the Icarus and UVM envs compute the golden
// expectations the Python model does.  M0: the frame-pattern + length helpers;
// the per-scenario driver that emits results.json lands with the datapath (M1+).
`ifndef SCENARIOS_SVH
`define SCENARIOS_SVH

localparam int FLIT_PAYLOAD_B_MIRROR = 240;

// Frame byte pattern — must equal scenarios.pat() in the Python/C++ mirrors.
function automatic byte unsigned scen_pat(int frame_id, int idx);
  return byte'((frame_id * 37 + idx * 13 + (idx >> 8) + 5) & 'hFF);
endfunction

// LCG length stream — must equal scenarios.lcg_lengths().
function automatic int scen_lcg_next(inout longint unsigned x);
  x = (1103515245 * x + 12345) & 32'h7FFFFFFF;
  return int'(x >> 8);
endfunction

`endif // SCENARIOS_SVH
