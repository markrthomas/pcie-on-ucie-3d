// dv/common/pcie_pat.svh — deterministic frame byte pattern.
// Must equal scenarios.pat() in dv/common/scenarios.py (and scen_pat in scenarios.svh):
//   pat(id, idx) = (id*37 + idx*13 + (idx>>8) + 5) & 0xFF
`ifndef PCIE_PAT_SVH
`define PCIE_PAT_SVH
function automatic logic [7:0] pat(input int frame_id, input int idx);
  return 8'((frame_id * 37 + idx * 13 + (idx >> 8) + 5) & 'hFF);
endfunction
`endif
