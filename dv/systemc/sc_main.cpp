// dv/systemc/sc_main.cpp — Verilator->SystemC environment (DV env 4).
//   default / smoke : build the DUT as a verilated SystemC model, pulse reset,
//                     check the reset/defaults contract.
//   +scen           : a Tb SC_MODULE runs the shared Config-1 loopback scenarios
//                     (dv/common/scenarios.py via dv/common/cpp/adapter_bfm.h) and
//                     writes logs/results.json.  One merged clock drives both DUT
//                     clock inputs (same semantics as dv/vlt).
#include <systemc.h>
#include <cstring>
#include "Vpcie_ucie3d_adapter.h"
#include "adapter_bfm.h"

using namespace adapter_bfm;
enum { PWR_L1_ = 2, SPEED_64_ = 7, PWR_L0_ = 0 };

// ---- scenario testbench ----------------------------------------------------
SC_MODULE(Tb) {
  sc_in<bool>  clk;
  sc_out<bool> pcie_rst_n, ucie_rst_n;
  sc_out<bool> pcie_tvalid, pcie_tlast; sc_in<bool> pcie_tready;
  sc_out<sc_bv<256>> pcie_tdata; sc_out<uint32_t> pcie_tkeep, pcie_tuser;
  sc_in<bool>  pcie_rx_tvalid, pcie_rx_tlast; sc_out<bool> pcie_rx_tready;
  sc_in<sc_bv<256>> pcie_rx_tdata; sc_in<uint32_t> pcie_rx_tkeep, pcie_rx_tuser;
  sc_in<uint64_t> ucie_tx_data; sc_in<bool> ucie_tx_valid, ucie_tx_start_flit;
  sc_out<uint64_t> ucie_rx_data; sc_out<bool> ucie_rx_valid, ucie_rx_start_flit;
  sc_in<uint32_t> ucie_speed, ucie_width, ucie_powerdown, ucie_sb_m2s;
  sc_out<bool> ucie_link_status, ucie_rx_active, ucie_rx_elec_idle;
  sc_out<uint32_t> ucie_sb_s2m;
  sc_out<bool> csr_valid, csr_write; sc_out<uint32_t> csr_addr, csr_wdata;
  sc_in<uint32_t> csr_rdata;

  Harness h;

  void on_edge() {
    PcieOut po; UcieOut uo;
    po.tready = pcie_tready.read();
    po.rx_tvalid = pcie_rx_tvalid.read(); po.rx_tlast = pcie_rx_tlast.read();
    po.rx_keep = pcie_rx_tkeep.read(); po.rx_tuser = pcie_rx_tuser.read();
    sc_bv<256> rx = pcie_rx_tdata.read();
    for (int i = 0; i < 32; i++) po.rx_data[i] = (uint8_t)rx.range(8 * i + 7, 8 * i).to_uint();
    uo.tx_valid = ucie_tx_valid.read(); uo.tx_start_flit = ucie_tx_start_flit.read();
    uo.tx_data = ucie_tx_data.read();
    uo.powerdown = ucie_powerdown.read(); uo.speed = ucie_speed.read(); uo.width = ucie_width.read();
    uo.sb_m2s = ucie_sb_m2s.read(); uo.csr_rdata = csr_rdata.read();

    h.step(po, uo);

    const PcieIn& pin = h.pcie_in();
    const UcieIn& uin = h.ucie_in();
    pcie_rst_n.write(pin.rst_n); ucie_rst_n.write(uin.rst_n);
    pcie_tvalid.write(pin.tvalid); pcie_tlast.write(pin.tlast);
    pcie_tkeep.write(pin.keep); pcie_tuser.write(pin.tuser);
    pcie_rx_tready.write(pin.rx_tready);
    sc_bv<256> td;
    for (int i = 0; i < 32; i++) td.range(8 * i + 7, 8 * i) = pin.data[i];
    pcie_tdata.write(td);
    ucie_link_status.write(uin.link_status); ucie_rx_active.write(uin.rx_active);
    ucie_rx_elec_idle.write(uin.rx_elec_idle);
    ucie_rx_data.write(uin.rx_data); ucie_rx_valid.write(uin.rx_valid);
    ucie_rx_start_flit.write(uin.rx_start_flit);
    ucie_sb_s2m.write(uin.sb_s2m);
    csr_valid.write(uin.csr_valid); csr_write.write(uin.csr_write);
    csr_addr.write(uin.csr_addr); csr_wdata.write(uin.csr_wdata);

    if (h.done) sc_stop();
  }

  SC_CTOR(Tb) {
    SC_METHOD(on_edge);
    sensitive << clk.pos();
    dont_initialize();
  }
};

static int run_scen(int argc, char* argv[]) {
  sc_clock clk("clk", 2, SC_NS, 0.5, 0, SC_NS, true);
  sc_signal<bool> pcie_rst_n, ucie_rst_n, pcie_tvalid, pcie_tready, pcie_tlast;
  sc_signal<uint32_t> pcie_tkeep, pcie_tuser;
  sc_signal<sc_bv<256>> pcie_tdata, pcie_rx_tdata;
  sc_signal<bool> pcie_rx_tvalid, pcie_rx_tready, pcie_rx_tlast;
  sc_signal<uint32_t> pcie_rx_tkeep, pcie_rx_tuser;
  sc_signal<uint64_t> ucie_tx_data, ucie_rx_data;
  sc_signal<bool> ucie_tx_valid, ucie_tx_start_flit, ucie_rx_valid, ucie_rx_start_flit;
  sc_signal<uint32_t> ucie_speed, ucie_width, ucie_powerdown, ucie_sb_m2s, ucie_sb_s2m;
  sc_signal<bool> ucie_link_status, ucie_rx_active, ucie_rx_elec_idle;
  sc_signal<bool> csr_valid, csr_write;
  sc_signal<uint32_t> csr_addr, csr_wdata, csr_rdata;

  Vpcie_ucie3d_adapter dut("dut");
  dut.pcie_clk(clk); dut.pcie_rst_n(pcie_rst_n);
  dut.pcie_tvalid(pcie_tvalid); dut.pcie_tready(pcie_tready); dut.pcie_tdata(pcie_tdata);
  dut.pcie_tkeep(pcie_tkeep); dut.pcie_tlast(pcie_tlast); dut.pcie_tuser(pcie_tuser);
  dut.pcie_rx_tvalid(pcie_rx_tvalid); dut.pcie_rx_tready(pcie_rx_tready); dut.pcie_rx_tdata(pcie_rx_tdata);
  dut.pcie_rx_tkeep(pcie_rx_tkeep); dut.pcie_rx_tlast(pcie_rx_tlast); dut.pcie_rx_tuser(pcie_rx_tuser);
  dut.ucie_clk(clk); dut.ucie_rst_n(ucie_rst_n);
  dut.ucie_tx_data(ucie_tx_data); dut.ucie_tx_valid(ucie_tx_valid); dut.ucie_tx_start_flit(ucie_tx_start_flit);
  dut.ucie_rx_data(ucie_rx_data); dut.ucie_rx_valid(ucie_rx_valid); dut.ucie_rx_start_flit(ucie_rx_start_flit);
  dut.ucie_speed(ucie_speed); dut.ucie_width(ucie_width); dut.ucie_powerdown(ucie_powerdown);
  dut.ucie_link_status(ucie_link_status); dut.ucie_rx_active(ucie_rx_active); dut.ucie_rx_elec_idle(ucie_rx_elec_idle);
  dut.ucie_sb_m2s(ucie_sb_m2s); dut.ucie_sb_s2m(ucie_sb_s2m);
  dut.csr_valid(csr_valid); dut.csr_write(csr_write); dut.csr_addr(csr_addr);
  dut.csr_wdata(csr_wdata); dut.csr_rdata(csr_rdata);

  Tb tb("tb");
  tb.clk(clk);
  tb.pcie_rst_n(pcie_rst_n); tb.ucie_rst_n(ucie_rst_n);
  tb.pcie_tvalid(pcie_tvalid); tb.pcie_tready(pcie_tready); tb.pcie_tlast(pcie_tlast);
  tb.pcie_tdata(pcie_tdata); tb.pcie_tkeep(pcie_tkeep); tb.pcie_tuser(pcie_tuser);
  tb.pcie_rx_tvalid(pcie_rx_tvalid); tb.pcie_rx_tready(pcie_rx_tready); tb.pcie_rx_tlast(pcie_rx_tlast);
  tb.pcie_rx_tdata(pcie_rx_tdata); tb.pcie_rx_tkeep(pcie_rx_tkeep); tb.pcie_rx_tuser(pcie_rx_tuser);
  tb.ucie_tx_data(ucie_tx_data); tb.ucie_tx_valid(ucie_tx_valid); tb.ucie_tx_start_flit(ucie_tx_start_flit);
  tb.ucie_rx_data(ucie_rx_data); tb.ucie_rx_valid(ucie_rx_valid); tb.ucie_rx_start_flit(ucie_rx_start_flit);
  tb.ucie_speed(ucie_speed); tb.ucie_width(ucie_width); tb.ucie_powerdown(ucie_powerdown);
  tb.ucie_link_status(ucie_link_status); tb.ucie_rx_active(ucie_rx_active); tb.ucie_rx_elec_idle(ucie_rx_elec_idle);
  tb.ucie_sb_m2s(ucie_sb_m2s); tb.ucie_sb_s2m(ucie_sb_s2m);
  tb.csr_valid(csr_valid); tb.csr_write(csr_write); tb.csr_addr(csr_addr);
  tb.csr_wdata(csr_wdata); tb.csr_rdata(csr_rdata);

  sc_start(200, SC_MS);                 // guard; the Tb calls sc_stop() when done
  tb.h.fc_summary();
  tb.h.write_json("logs/results.json", "systemc");
  bool ok = tb.h.done && tb.h.total_errors == 0 && tb.h.results.size() == 5;
  printf("%s: %zu scenarios, %d error(s)\n", ok ? "SYSTEMC PASS" : "SYSTEMC FAIL",
         tb.h.results.size(), tb.h.total_errors);
  return ok ? 0 : 1;
}

static int run_smoke() {
  sc_clock pclk("pclk", 5, SC_NS);
  sc_clock uclk("uclk", 2, SC_NS);
  sc_signal<bool> pcie_rst_n, ucie_rst_n;
  sc_signal<bool> pcie_tvalid, pcie_tready, pcie_tlast;
  sc_signal<uint32_t> pcie_tkeep, pcie_tuser;
  sc_signal<sc_bv<256>> pcie_tdata, pcie_rx_tdata;
  sc_signal<bool> pcie_rx_tvalid, pcie_rx_tready, pcie_rx_tlast;
  sc_signal<uint32_t> pcie_rx_tkeep, pcie_rx_tuser;
  sc_signal<uint64_t> ucie_tx_data, ucie_rx_data;
  sc_signal<bool> ucie_tx_valid, ucie_tx_start_flit, ucie_rx_valid, ucie_rx_start_flit;
  sc_signal<uint32_t> ucie_speed, ucie_width, ucie_powerdown, ucie_sb_m2s, ucie_sb_s2m;
  sc_signal<bool> ucie_link_status, ucie_rx_active, ucie_rx_elec_idle;
  sc_signal<bool> csr_valid, csr_write;
  sc_signal<uint32_t> csr_addr, csr_wdata, csr_rdata;

  Vpcie_ucie3d_adapter dut("dut");
  dut.pcie_clk(pclk); dut.pcie_rst_n(pcie_rst_n);
  dut.pcie_tvalid(pcie_tvalid); dut.pcie_tready(pcie_tready); dut.pcie_tdata(pcie_tdata);
  dut.pcie_tkeep(pcie_tkeep); dut.pcie_tlast(pcie_tlast); dut.pcie_tuser(pcie_tuser);
  dut.pcie_rx_tvalid(pcie_rx_tvalid); dut.pcie_rx_tready(pcie_rx_tready); dut.pcie_rx_tdata(pcie_rx_tdata);
  dut.pcie_rx_tkeep(pcie_rx_tkeep); dut.pcie_rx_tlast(pcie_rx_tlast); dut.pcie_rx_tuser(pcie_rx_tuser);
  dut.ucie_clk(uclk); dut.ucie_rst_n(ucie_rst_n);
  dut.ucie_tx_data(ucie_tx_data); dut.ucie_tx_valid(ucie_tx_valid); dut.ucie_tx_start_flit(ucie_tx_start_flit);
  dut.ucie_rx_data(ucie_rx_data); dut.ucie_rx_valid(ucie_rx_valid); dut.ucie_rx_start_flit(ucie_rx_start_flit);
  dut.ucie_speed(ucie_speed); dut.ucie_width(ucie_width); dut.ucie_powerdown(ucie_powerdown);
  dut.ucie_link_status(ucie_link_status); dut.ucie_rx_active(ucie_rx_active); dut.ucie_rx_elec_idle(ucie_rx_elec_idle);
  dut.ucie_sb_m2s(ucie_sb_m2s); dut.ucie_sb_s2m(ucie_sb_s2m);
  dut.csr_valid(csr_valid); dut.csr_write(csr_write); dut.csr_addr(csr_addr);
  dut.csr_wdata(csr_wdata); dut.csr_rdata(csr_rdata);

  pcie_rx_tready.write(true); ucie_rx_elec_idle.write(true);
  pcie_rst_n.write(false); ucie_rst_n.write(false);
  sc_start(40, SC_NS);
  pcie_rst_n.write(true); ucie_rst_n.write(true);
  sc_start(20, SC_NS);

  int errors = 0;
  auto chk = [&](bool c, const char* m) { if (!c) { printf("FAIL: %s\n", m); errors++; } };
  chk(ucie_powerdown.read() == PWR_L1_, "powerdown should be L1 out of reset");
  chk(ucie_speed.read() == SPEED_64_,   "speed should be SPEED_64");
  chk(ucie_tx_valid.read() == false,    "no Tx traffic out of reset (nothing queued)");
  chk(pcie_tready.read() == false,      "PCIe ingress closed before link-up (M3 gating)");
  if (errors == 0) { printf("SYSTEMC SMOKE PASS: reset defaults OK\n"); return 0; }
  printf("SYSTEMC SMOKE FAIL: %d error(s)\n", errors); return 1;
}

int sc_main(int argc, char* argv[]) {
  Verilated::commandArgs(argc, argv);
  bool scen = false;
  for (int i = 1; i < argc; i++) if (!strcmp(argv[i], "+scen")) scen = true;
  return scen ? run_scen(argc, argv) : run_smoke();
}
