// dv/vlt/cov_main.cpp — directed coverage battery (DV env 2, coverage vehicle B).
//
// The shared scenario run (sim_main.cpp +scen) exercises the clean Config-1
// loopback datapath.  This companion vehicle drives the control-plane and
// error-handling corners that a clean loopback never reaches, so the two
// coverage.dat files merge to a near-complete line coverage of rtl/.  It mirrors
// the stimulus AND the checks of the directed Icarus tests dv/iverilog/tb_pm.sv
// (power / speed / width / CSR / sideband) and tb_rxovf.sv (Rx overload), plus
// raw Rx protocol-slip injection that tb_rxovf does not reach under loopback:
//   * control battery : L0<->L1<->L2 power cycle, width x1<->x2, speed 64<->32,
//                       SPEEDCFG re-send, L0s request (ERR[2]), reserved width
//                       (ERR[3]), W1C clear, and a read of every CSR address;
//   * sideband timeout : a SPEEDCFG re-send with the remote ack muted -> the
//                       ucie_sb_master S_WAIT timeout path;
//   * Rx injection     : start_flit mid-flit, a data beat out of a flit, tx_valid
//                       dropped mid-flit (lock_errors); a multi-flit frame aborted
//                       by a mid-frame sof (aborted_frames, pcie_rx_tuser err); an
//                       out-of-frame orphan flit (bad_flits); and an overflow drop
//                       with the PCIe sink stalled (dropped_flits).
// Every corner is checked against the DUT's own CSR counters / status, so this is
// a self-checking test, not a line-touching pass.  The clocks are the merged
// single clock used by sim_main.cpp; FLOW_CTRL stays off here (its lines are
// covered by the separate FLOW_CTRL build that `make coverage` also merges).
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include "Vpcie_ucie3d_adapter.h"
#include "verilated.h"
#if VM_COVERAGE
#include "verilated_cov.h"
#endif

// ---- constants (mirror rtl/pcie_ucie3d_pkg.sv) -----------------------------
enum { PWR_L0 = 0, PWR_L0S = 1, PWR_L1 = 2, PWR_L2 = 3 };
enum { SPEED_32 = 5, SPEED_64 = 7 };
enum { CSR_CTRL = 0x00, CSR_SPEEDCFG = 0x04, CSR_STATUS = 0x08, CSR_ERR = 0x0C,
       CSR_RXCNT0 = 0x10, CSR_RXCNT1 = 0x14, CSR_PMCNT = 0x18 };
static const int SB_WR = 0x1, SB_WR_ACK = 0x3;
static const int FLIT_BEATS = 32, FLIT_HDR_B = 2, FLIT_PAYLOAD_B = 240, FLIT_BYTES = 256;
static const int ST_ACTIVE = 4;

static Vpcie_ucie3d_adapter* dut = nullptr;
static int errors = 0;
static long long cyc = 0;
static void chk(bool c, const char* m) { if (!c) { printf("[cyc %lld] COV FAIL: %s\n", cyc, m); errors++; } }

// ---- persistent DUT input state --------------------------------------------
struct In {
  bool pcie_rst_n = false, ucie_rst_n = false;
  bool tvalid = false, tlast = false, rx_tready = false;
  uint32_t tkeep = 0, tuser = 0;
  uint8_t tdata[32] = {};
  bool link_status = true, rx_active = false, rx_elec_idle = true;
  uint64_t rx_data = 0;
  bool rx_valid = false, rx_start_flit = false;
  uint32_t sb_s2m = 0;
  bool csr_valid = false, csr_write = false;
  uint32_t csr_addr = 0, csr_wdata = 0;
} in;

struct Out {
  bool tx_valid, tx_start_flit;
  uint64_t tx_data;
  int powerdown, speed, width;
  uint32_t sb_m2s, csr_rdata;
  bool rx_tvalid, rx_tlast;
  uint32_t rx_tuser;
} out;

// ---- Rx source control: loopback (Tx->Rx) or raw injection -----------------
static bool loopback_on = false;        // this vehicle never needs real Tx->Rx
static bool rx_override = false;         // drive rx_* from the injector instead
static uint64_t rx_ov_data = 0; static bool rx_ov_valid = false, rx_ov_start = false;

// ---- remote-die control model (port of adapter_bfm.h remote_die_) ----------
struct RemoteDie {
  int phase = 0, rst_cnt = 0, sb_cnt = 0, mb_cnt = 0, st_cnt = 0, ack_cnt = 0;
  int sb_ph = 0, pd_q = PWR_L1, speed_q = SPEED_64, width_q = 0, sb_addr = 0;
  bool mute_sb_ack = false;
  bool mute_link = false;             // suppress the op-complete link_status pulse
  static const int LAT = 8, RST_CYCLES = 16, SB_LAT = 8, MB_LAT = 8;
  int last_sb_addr = 0, last_sb_data = 0, sb_writes = 0;
  void reset() { *this = RemoteDie(); }
  void update(const Out& o) {
    in.link_status = false; in.sb_s2m = 0;
    switch (phase) {
      case 0:
        in.link_status = true;
        if (rst_cnt < RST_CYCLES) rst_cnt++;
        else { in.link_status = false; phase = 1; sb_cnt = 0; }
        break;
      case 1:
        if (sb_cnt < SB_LAT) sb_cnt++;
        else { in.rx_elec_idle = false; phase = 2; mb_cnt = 0; }
        break;
      case 2:
        if (mb_cnt < MB_LAT) mb_cnt++;
        else { in.rx_active = true; phase = 3; }
        break;
      default: break;
    }
    bool change = o.powerdown != pd_q || o.speed != speed_q || o.width != width_q;
    if (phase == 3) {
      if (change) st_cnt = LAT;
      else if (st_cnt == 1) { st_cnt = 0; if (!mute_link) in.link_status = true; }
      else if (st_cnt > 1) st_cnt--;
    }
    pd_q = o.powerdown; speed_q = o.speed; width_q = o.width;
    // byte-serial sideband write target + ack
    int m2s = o.sb_m2s & 0xFF;
    if (sb_ph == 1) { sb_addr = (sb_addr & 0xFF) | (m2s << 8); sb_ph = 2; }
    else if (sb_ph == 2) { sb_addr = (sb_addr & 0xFF00) | m2s; sb_ph = 3; }
    else if (sb_ph == 3) { last_sb_addr = sb_addr; last_sb_data = m2s; sb_writes++; sb_ph = 0; ack_cnt = LAT; }
    else if (m2s != 0) { if (((m2s >> 4) & 0xF) == SB_WR) sb_ph = 1; }
    if (!mute_sb_ack) {
      if (ack_cnt == 1) { ack_cnt = 0; in.sb_s2m = (SB_WR_ACK << 4); }
      else if (ack_cnt > 1) ack_cnt--;
    }
  }
} rd;

// ---- drive / sample --------------------------------------------------------
static void drive() {
  dut->pcie_rst_n = in.pcie_rst_n; dut->ucie_rst_n = in.ucie_rst_n;
  dut->pcie_tvalid = in.tvalid; dut->pcie_tlast = in.tlast; dut->pcie_rx_tready = in.rx_tready;
  dut->pcie_tkeep = in.tkeep; dut->pcie_tuser = in.tuser;
  for (int w = 0; w < 8; w++) {
    uint32_t word = 0;
    for (int b = 0; b < 4; b++) word |= uint32_t(in.tdata[w * 4 + b]) << (8 * b);
    dut->pcie_tdata[w] = word;
  }
  dut->ucie_link_status = in.link_status; dut->ucie_rx_active = in.rx_active;
  dut->ucie_rx_elec_idle = in.rx_elec_idle;
  dut->ucie_rx_data = in.rx_data; dut->ucie_rx_valid = in.rx_valid;
  dut->ucie_rx_start_flit = in.rx_start_flit;
  dut->ucie_sb_s2m = in.sb_s2m;
  dut->csr_valid = in.csr_valid; dut->csr_write = in.csr_write;
  dut->csr_addr = in.csr_addr; dut->csr_wdata = in.csr_wdata;
}
static void sample() {
  out.tx_valid = dut->ucie_tx_valid; out.tx_start_flit = dut->ucie_tx_start_flit;
  out.tx_data = dut->ucie_tx_data;
  out.powerdown = dut->ucie_powerdown; out.speed = dut->ucie_speed; out.width = dut->ucie_width;
  out.sb_m2s = dut->ucie_sb_m2s; out.csr_rdata = dut->csr_rdata;
  out.rx_tvalid = dut->pcie_rx_tvalid; out.rx_tlast = dut->pcie_rx_tlast;
  out.rx_tuser = dut->pcie_rx_tuser;
}

// One merged clock cycle, mirroring sim_main.cpp's edge ordering.
static void cycle() {
  sample();
  dut->pcie_clk = 1; dut->ucie_clk = 1; dut->eval();   // rising edge
  rd.update(out);                                      // remote die computes next inputs
  if (rx_override)   { in.rx_data = rx_ov_data; in.rx_valid = rx_ov_valid; in.rx_start_flit = rx_ov_start; }
  else if (loopback_on) { in.rx_data = out.tx_data; in.rx_valid = out.tx_valid; in.rx_start_flit = out.tx_start_flit; }
  else               { in.rx_valid = false; in.rx_start_flit = false; }
  drive();
  dut->eval();                                          // settle
  dut->pcie_clk = 0; dut->ucie_clk = 0; dut->eval();    // falling edge
  cyc++;
}
static void run(int n) { for (int i = 0; i < n; i++) cycle(); }

// ---- CSR helpers -----------------------------------------------------------
static void csr_wr(int addr, uint32_t data) {
  in.csr_valid = true; in.csr_write = true; in.csr_addr = addr; in.csr_wdata = data;
  cycle();
  in.csr_valid = false; in.csr_write = false;
  cycle();
}
static uint32_t csr_rd(int addr) {
  in.csr_addr = addr; cycle(); sample();     // rdata is combinational on addr
  return out.csr_rdata;
}
static uint32_t ctrl_word(int pd, int sp, int wd) { return uint32_t(pd | (sp << 2) | (wd << 5)); }

// Issue a CTRL change and wait until STATUS shows it settled (not busy).
static void set_ctrl(int pd, int sp, int wd, const char* what) {
  csr_wr(CSR_CTRL, ctrl_word(pd, sp, wd));
  uint32_t target = ctrl_word(pd, sp, wd);
  int n = 0;
  for (; n < 60000; n++) {
    uint32_t d = csr_rd(CSR_STATUS);
    if ((d & 0x7F) == target && (d & (1u << 11)) == 0) break;
  }
  chk(n < 60000, what);
  chk(dut->ucie_powerdown == pd && dut->ucie_speed == sp && dut->ucie_width == wd, what);
}

static void bring_up() {
  in = In();                       // all inputs idle/low
  in.rx_tready = true;
  in.pcie_rst_n = false; in.ucie_rst_n = false;
  rd.reset();
  for (int i = 0; i < 12; i++) cycle();
  in.pcie_rst_n = true; in.ucie_rst_n = true;
  int n = 0;
  for (; n < 60000; n++) { if (csr_rd(CSR_STATUS) & (1u << 12)) break; }   // bit12 = link active (L0)
  chk(n < 60000, "link reached ST_ACTIVE/L0");
}

// ---- Rx flit injection -----------------------------------------------------
// Drive one raw flit (32 beats) onto the Rx bus.  hv/sof/eof set the header
// bits; plen the payload length; the payload bytes are pat-filled.  If
// drop_last_valid is set, the final beat is driven with rx_valid=0 (tx_valid
// dropped mid-flit) instead of completing the flit.
static void inject_flit(bool hv, bool sof, bool eof, int plen, int base, bool corrupt_mid_start) {
  uint8_t fl[FLIT_BYTES] = {};
  fl[0] = uint8_t((hv ? 1 : 0) | (sof ? 2 : 0) | (eof ? 4 : 0));
  fl[1] = uint8_t(plen);
  for (int i = 0; i < plen; i++) fl[FLIT_HDR_B + i] = uint8_t(base + i);
  rx_override = true;
  for (int beat = 0; beat < FLIT_BEATS; beat++) {
    uint64_t w = 0;
    for (int b = 0; b < 8; b++) w |= uint64_t(fl[beat * 8 + b]) << (8 * b);
    rx_ov_data = w;
    rx_ov_valid = true;
    rx_ov_start = (beat == 0);
    if (corrupt_mid_start && beat == 5) rx_ov_start = true;   // start_flit mid-flit
    cycle();
    if (corrupt_mid_start && beat == 5) break;                // injector restarts capture
  }
  rx_ov_valid = false; rx_ov_start = false;
  cycle();
  rx_override = false;
}

static void control_battery() {
  // --- power cycle L0 -> L1 -> L2 -> L1 -> L0 (L2 path: ctrl_fsm ST_LOWPWR) ---
  set_ctrl(PWR_L1, SPEED_64, 0, "L0->L1");
  chk(dut->pcie_tready == 0, "PCIe ingress closed in L1");
  chk(dut->ucie_tx_valid == 0, "no Tx in L1");
  set_ctrl(PWR_L2, SPEED_64, 0, "L1->L2");
  set_ctrl(PWR_L1, SPEED_64, 0, "L2->L1");
  set_ctrl(PWR_L0, SPEED_64, 0, "L2/L1->L0");

  // --- width change x1 -> x2 -> x1 (ctrl_fsm ST_WIDTH_CHG) -------------------
  set_ctrl(PWR_L0, SPEED_64, 1, "width x1->x2");
  set_ctrl(PWR_L0, SPEED_64, 0, "width x2->x1");

  // --- speed change 64 -> 32 -> 64 (ST_SPEED_CHG + preset re-send) -----------
  set_ctrl(PWR_L0, SPEED_32, 0, "speed 64->32");
  set_ctrl(PWR_L0, SPEED_64, 0, "speed 32->64");

  // --- SPEEDCFG re-send (cfg_wr -> ST_PARAM sideband write) ------------------
  int sb0 = rd.sb_writes;
  csr_wr(CSR_SPEEDCFG, 0xF5);               // [7:6] reserved, masked to 0x35
  for (int n = 0; n < 4000 && rd.sb_writes <= sb0; n++) run(1);
  chk(rd.sb_writes > sb0, "SPEEDCFG write reached the remote die over the sideband");
  chk(rd.last_sb_data == 0x35, "SPEEDCFG value at the remote die (reserved bits masked)");
  chk(csr_rd(CSR_SPEEDCFG) == 0x35, "SPEEDCFG reads back with [7:6]=0");
  run(200);

  // --- L0s unsupported -> ERR[2], link stays L0 ------------------------------
  csr_wr(CSR_CTRL, ctrl_word(PWR_L0S, SPEED_64, 0));
  run(40);
  chk((csr_rd(CSR_ERR) & (1u << 2)) != 0, "ERR[2] set on an L0s request");
  chk(dut->ucie_powerdown == PWR_L0, "L0s request keeps the link in L0");
  csr_wr(CSR_CTRL, ctrl_word(PWR_L0, SPEED_64, 0));

  // --- reserved width 3 -> whole CTRL write ignored, ERR[3] ------------------
  csr_wr(CSR_CTRL, ctrl_word(PWR_L0, SPEED_32, 3));   // width 3 reserved
  run(20);
  chk((csr_rd(CSR_ERR) & (1u << 3)) != 0, "ERR[3] set on a reserved-width CTRL write");
  chk(dut->ucie_speed == SPEED_64, "reserved-width write ignored (speed unchanged)");

  // --- W1C: clear ERR[2] and ERR[3] ------------------------------------------
  csr_wr(CSR_ERR, (1u << 2) | (1u << 3));
  chk((csr_rd(CSR_ERR) & ((1u << 2) | (1u << 3))) == 0, "ERR W1C clears");

  // --- read every CSR address, incl. an unmapped one (adapter_rf read mux) ---
  chk((csr_rd(CSR_CTRL) & 0x7F) == ctrl_word(PWR_L0, SPEED_64, 0), "CSR_CTRL readback");
  (void)csr_rd(CSR_STATUS);
  (void)csr_rd(CSR_RXCNT0);
  (void)csr_rd(CSR_RXCNT1);
  (void)csr_rd(CSR_PMCNT);
  chk(csr_rd(0xFC) == 0, "unmapped CSR reads 0 (default arm)");
}

static void link_timeout() {
  // Mute the op-complete link_status pulse during a speed change: the FSM's
  // ST_SPEED_CHG timer must reach SB_TIMEOUT (tmo) and raise ev_link_timeout,
  // which adapter_rf latches into ERR[1].  The transition is then treated as
  // complete (D10) and the link recovers.
  rd.mute_link = true;
  set_ctrl(PWR_L0, SPEED_32, 0, "muted speed change recovers via timeout");
  rd.mute_link = false;
  chk((csr_rd(CSR_ERR) & (1u << 1)) != 0, "ERR[1] set on a link-status timeout");
  csr_wr(CSR_ERR, 1u << 1);
  set_ctrl(PWR_L0, SPEED_64, 0, "speed restored after timeout");
  chk((csr_rd(CSR_ERR) & (1u << 1)) == 0, "no further link-status errors after recovery");
}

static void sideband_timeout() {
  // Mute the remote ack so a committed SPEEDCFG sideband write never completes:
  // ucie_sb_master S_WAIT must hit SB_TIMEOUT and pulse timeout.
  rd.mute_sb_ack = true;
  csr_wr(CSR_SPEEDCFG, 0x12);
  run(1024 + 64);                      // SB_TIMEOUT = 1024
  rd.mute_sb_ack = false;
  chk((csr_rd(CSR_ERR) & (1u << 0)) != 0, "ERR[0] set on a sideband-write timeout");
  csr_wr(CSR_ERR, 1u << 0);
  // the FSM recovers; let it re-send cleanly
  run(2000);
}

static void rx_injection() {
  uint32_t r0 = csr_rd(CSR_RXCNT0), r1 = csr_rd(CSR_RXCNT1);
  int lock0 = (r0 >> 16) & 0xFFFF, drop0 = r0 & 0xFFFF;
  int abrt0 = (r1 >> 16) & 0xFFFF, bad0 = r1 & 0xFFFF;

  in.rx_tready = true;

  // (1) data beat out of a flit (not locked): lock_errors++
  rx_override = true; rx_ov_data = 0xDEAD; rx_ov_valid = true; rx_ov_start = false;
  cycle();
  rx_ov_valid = false; rx_override = false; cycle();

  // (2) start_flit mid-flit: restart + lock_errors++
  inject_flit(true, true, false, 240, 0x10, /*corrupt_mid_start=*/true);

  // (3) tx_valid dropped mid-flit: lock_errors++
  rx_override = true;
  for (int beat = 0; beat < 6; beat++) {
    rx_ov_data = (beat == 0) ? 0x7 : 0; rx_ov_valid = true; rx_ov_start = (beat == 0); cycle();
  }
  rx_ov_valid = false; rx_ov_start = false; cycle(); cycle();   // valid dropped while locked
  rx_override = false; cycle();

  // (4) out-of-frame orphan flit (sof clear): dropped as bad/orphan -> bad_flits++
  inject_flit(true, /*sof=*/false, /*eof=*/true, 32, 0x20, false);
  run(20);

  // (5) multi-flit frame then a mid-frame sof: ABORT -> aborted_frames++, tuser err
  in.rx_tready = true;
  inject_flit(true, /*sof=*/true, /*eof=*/false, 240, 0x30, false);   // opens a frame (no eof)
  run(10);
  bool saw_err = false;
  inject_flit(true, /*sof=*/true, /*eof=*/true, 240, 0x40, false);    // sof mid-frame -> abort
  for (int n = 0; n < 200; n++) { run(1); sample(); if (out.rx_tvalid && (out.rx_tuser & 1)) saw_err = true; }
  chk(saw_err, "aborted frame surfaces pcie_rx_tuser[0] on the PCIe egress");

  // (6) overflow: stall the PCIe sink so the Rx path fills, then complete flits
  //     back to back -> a held flit is dropped (dropped_flits++).
  in.rx_tready = false;
  for (int k = 0; k < 6; k++) inject_flit(true, true, true, 240, 0x50 + k, false);
  in.rx_tready = true; run(400);

  uint32_t R0 = csr_rd(CSR_RXCNT0), R1 = csr_rd(CSR_RXCNT1);
  int lock1 = (R0 >> 16) & 0xFFFF, drop1 = R0 & 0xFFFF;
  int abrt1 = (R1 >> 16) & 0xFFFF, bad1 = R1 & 0xFFFF;
  chk(lock1 > lock0, "Rx lock_errors incremented by protocol-slip injection");
  chk(bad1 > bad0,   "Rx bad/orphan flits incremented");
  chk(abrt1 > abrt0, "Rx aborted_frames incremented");
  chk(drop1 > drop0, "Rx dropped_flits incremented by overflow");
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  dut = new Vpcie_ucie3d_adapter;
  dut->pcie_clk = 0; dut->ucie_clk = 0;
  drive(); dut->eval();

  bring_up();
  control_battery();
  link_timeout();
  sideband_timeout();
  rx_injection();

  dut->final();
#if VM_COVERAGE
  Verilated::threadContextp()->coveragep()->write("coverage.dat");
#endif
  delete dut;
  if (errors == 0) { printf("VLT COV PASS: directed control + Rx-injection battery, 0 errors (%lld cycles)\n", cyc); return 0; }
  printf("VLT COV FAIL: %d error(s)\n", errors);
  return 1;
}
