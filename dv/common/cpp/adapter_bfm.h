// ============================================================================
// dv/common/cpp/adapter_bfm.h — C++ Config-1 loopback harness + shared scenario
// runner, used by dv/vlt (plain Verilator C++) and dv/systemc (Verilator->SystemC).
//
// The harness never touches the DUT directly: the env main() samples the DUT
// outputs into PcieOut/UcieOut, calls Harness::step() to compute the next cycle's
// inputs into PcieIn/UcieIn, drives those, and ticks the (single, merged) clock.
// step() runs the PCIe MAC source + sink/scoreboard, the UCIe-3D Tx flit monitor,
// the remote-die control model (mirror of dv/common/ucie_sb_model.sv), the
// UCIe-3D Tx->Rx loopback, and the scenario sequencer, and writes results.json.
//
// pat()/LCG/CRC/scenario constants mirror dv/common/scenarios.py exactly.
// ============================================================================
#ifndef ADAPTER_BFM_H
#define ADAPTER_BFM_H
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <string>
#include <vector>

namespace adapter_bfm {

// ---- parameters (mirror rtl/pcie_ucie3d_pkg.sv) ----------------------------
constexpr int PCIE_BYTES = 32;         // PCIE_DATA_W / 8
constexpr int FLIT_PAYLOAD_B = 240;
constexpr int FLIT_BYTES = 256, FLIT_BEATS = 32, FLIT_HDR_B = 2, FLIT_FC_OFF = 242;
#ifdef FLOW_CTRL_OVERRIDE
constexpr bool FLOW_CTRL = true;
#else
constexpr bool FLOW_CTRL = false;
#endif
constexpr int PWR_L0 = 0, PWR_L0S = 1, PWR_L1 = 2, PWR_L2 = 3;
constexpr int SPEED_32 = 5, SPEED_64 = 7;
constexpr int SB_WR = 0x1, SB_WR_ACK = 0x3;
constexpr int SB_ADDR_TX_PRESET = 0x0405;
constexpr int CSR_CTRL = 0x00, CSR_SPEEDCFG = 0x04, CSR_STATUS = 0x08, CSR_ERR = 0x0C,
              CSR_RXCNT0 = 0x10, CSR_RXCNT1 = 0x14, CSR_PMCNT = 0x18;

inline uint8_t pat(int id, int idx) { return uint8_t(id * 37 + idx * 13 + (idx >> 8) + 5); }
inline uint32_t crc32_byte(uint32_t c, uint8_t b) {
  c ^= b;
  for (int k = 0; k < 8; k++) c = (c & 1) ? ((c >> 1) ^ 0xEDB88320u) : (c >> 1);
  return c;
}
struct Rng {
  uint32_t s;
  explicit Rng(uint32_t seed) : s(seed ? seed : 1) {}
  uint32_t next() { s ^= s << 13; s ^= s >> 17; s ^= s << 5; return s; }
  bool pct(int p) { return int(next() % 100) < p; }
};

// ---- DUT I/O (POD; the env main samples/drives these) ----------------------
struct PcieOut {               // pcie_clk-domain DUT outputs
  bool tready = false;
  bool rx_tvalid = false, rx_tlast = false;
  uint8_t rx_data[PCIE_BYTES] = {};
  uint32_t rx_keep = 0;
  uint32_t rx_tuser = 0;
};
struct PcieIn {                // pcie_clk-domain DUT inputs
  bool rst_n = false, tvalid = false, tlast = false, rx_tready = false;
  uint8_t data[PCIE_BYTES] = {};
  uint32_t keep = 0, tuser = 0;
};
struct UcieOut {               // ucie_clk-domain DUT outputs
  bool tx_valid = false, tx_start_flit = false;
  uint64_t tx_data = 0;
  int powerdown = 0, speed = 0, width = 0;
  uint32_t sb_m2s = 0;
  uint32_t csr_rdata = 0;
};
struct UcieIn {                // ucie_clk-domain DUT inputs
  bool rst_n = false;
  bool link_status = true, rx_active = false, rx_elec_idle = true;
  uint64_t rx_data = 0;
  bool rx_valid = false, rx_start_flit = false;
  uint32_t sb_s2m = 0;
  bool csr_valid = false, csr_write = false;
  uint32_t csr_addr = 0, csr_wdata = 0;
};

struct ScenResult {
  std::string name;
  int frames = 0;
  long bytes = 0;
  int flits = 0;
  uint32_t crc = 0xFFFFFFFFu;
  uint32_t pmcnt = 0;
  uint32_t rx0 = 0, rx1 = 0;        // rand mode: RXCNT0/1 read back at the end
  int errors = 0;
};

class Harness {
 public:
  explicit Harness(uint32_t seed = 12345) : rng_(seed) {}

  int mac_gap_pct = 10;
  int sink_ready_pct = 90;
  bool rand_mode = false;           // run only the `rand` scenario (see scen_name_)
  uint32_t rand_seed = 1;
  int rand_frames = 24, rand_maxlen = 2000;
  // B1/B2 stimulus (rand mode only; all 0 = the original no-control, no-CSR, no-injection scenario)
  int rand_ctl = 0, rand_nctl = 0;   // control ops: 0 none, 1 pm_cycle, 2 speed_change, 3 mix; count
  int rand_mid = 0;                  // 1: ops fire while later frames are already queued/in flight
  int rand_csr = 0, rand_ncfg = 0;   // CSR traffic activity %/cycle; exact # of SPEEDCFG writes
  int rand_nrx = 0;                  // # of Rx-side error injections (at the quiescent end of the run)
  bool done = false;
  int total_errors = 0;
  std::vector<ScenResult> results;
  int cr_flits = 0;                 // credit-only flits seen (FLOW_CTRL)
  unsigned last_cl = 0;

  const PcieIn& pcie_in() const { return pin_; }
  const UcieIn& ucie_in() const { return uin_; }

  // Called once per merged clock cycle, AFTER sampling the DUT outputs.
  // Updates pin_/uin_ for the next drive.
  void step(const PcieOut& po, const UcieOut& uo) {
    // ----- UCIe-3D Tx->Rx loopback (held outputs -> next-cycle Rx inputs) ----
    uin_.rx_data = uo.tx_data;
    uin_.rx_valid = uo.tx_valid;
    uin_.rx_start_flit = uo.tx_start_flit;

    if (rst_n_) { flit_beat_(uo); } else { flit_reset_(); }
    remote_die_(uo);                       // link_status / rx_active / sideband ack
    mac_source_(po);                       // PCIe AXI-S source
    sink_(po);                             // PCIe sink + scoreboard
    sequencer_(uo);                        // scenario driver (uses CSR)

    if (!inj_q_.empty()) {                 // B2: Rx-side error injection overrides the loopback
      const InjBeat b = inj_q_.front(); inj_q_.pop_front();
      uin_.rx_data = b.d; uin_.rx_valid = b.v; uin_.rx_start_flit = b.s;
      inj_hold_ = true;
    } else if (inj_hold_) {                // keep the loopback cut until a Tx flit (e.g. FC credit-only)
      if (fbeat_ == 0 && !uo.tx_valid) inj_hold_ = false;       // that started meanwhile has ended, so
      else { uin_.rx_valid = false; uin_.rx_start_flit = false; }   // Rx never sees a flit tail
    }

    pin_.rst_n = rst_n_;
    uin_.rst_n = rst_n_;
  }

  void write_json(const char* path, const char* env) {
    FILE* f = fopen(path, "w");
    if (!f) { printf("adapter_bfm: cannot open %s\n", path); return; }
    fprintf(f, "{\"env\": \"%s\", \"scenarios\": {", env);
    for (size_t i = 0; i < results.size(); i++) {
      const ScenResult& r = results[i];
      fprintf(f,
              "%s\"%s\": {\"frames\": %d, \"bytes\": %ld, \"flits\": %d, "
              "\"crc32\": \"%08x\", \"pmcnt\": %u, \"errors\": %d%s",
              i ? ", " : "", r.name.c_str(), r.frames, r.bytes, r.flits,
              r.crc ^ 0xFFFFFFFFu, r.pmcnt, r.errors, rand_mode ? "" : "}");
      if (rand_mode) fprintf(f, ", \"rxcnt0\": %u, \"rxcnt1\": %u}", r.rx0, r.rx1);
    }
    if (rand_mode)
      fprintf(f, "}, \"rand\": {\"seed\": %u, \"frames\": %d, \"maxlen\": %d, \"ctl\": %d, \"nctl\": %d, "
                 "\"mid\": %d, \"csr\": %d, \"ncfg\": %d, \"nrx\": %d}}\n",
              rand_seed, rand_frames, rand_maxlen, rand_ctl, rand_nctl, rand_mid, rand_csr, rand_ncfg, rand_nrx);
    else
      fprintf(f, "}}\n");
    fclose(f);
  }

  void fc_summary() {
    if (!FLOW_CTRL) return;
    printf("FC credit-only flits=%d last_cl=%u\n", cr_flits, last_cl);
    if (cr_flits == 0) err_("flow control on but no credit-only flit seen (FC not exercised)");
  }

 private:
  Rng rng_;
  PcieIn pin_;
  UcieIn uin_;
  bool rst_n_ = false;

  void err_(const char* m) {
    total_errors++;
    if (sc_ >= 0 && sc_ < int(results.size())) results[sc_].errors++;
    printf("[cyc %lld] BFM ERROR: %s\n", cyc_, m);
  }
  long long cyc_ = 0;

  // ---- scenario table (mirror of dv/common/scenarios.py) --------------------
  // rand_mode (random regression, dv/random/rr.py): one scenario "rand" = `rand_frames`
  // LCG-length frames, no control op; golden = scenarios.expected_rand().  Off by default,
  // so the five fixed scenarios are unchanged.
  const char* scen_name_(int s) const {
    static const char* n[] = {"single", "corners", "random", "pm_cycle", "speed_change"};
    return rand_mode ? "rand" : n[s];
  }
  int scen_nframes_(int s) const {
    static const int n[] = {1, 11, 40, 16, 16};
    return rand_mode ? rand_frames : n[s];
  }
  int scen_ctrl_(int s) const { return rand_mode ? 0 : s == 3 ? 1 : s == 4 ? 2 : 0; }
  int scen_len_(int s, int i) const {
    if (rand_mode) {
      uint64_t x = uint64_t(rand_seed) & 0x7FFFFFFF;
      for (int k = 0; k <= i; k++) x = (1103515245ull * x + 12345ull) & 0x7FFFFFFF;
      return 1 + int((x >> 8) % uint64_t(rand_maxlen));
    }
    static const int corners[] = {1, 31, 32, 33, 239, 240, 241, 480, 481, 1500, 4096};
    if (s == 0) return 256;
    if (s == 1) return corners[i];
    uint64_t seed = (s == 2) ? 0xC0FFEE : (s == 3) ? 7 : 11;
    uint64_t x = seed & 0x7FFFFFFF;
    for (int k = 0; k <= i; k++) x = (1103515245ull * x + 12345ull) & 0x7FFFFFFF;
    return 1 + int((x >> 8) % 2000);
  }

  // ---- UCIe-3D Tx flit monitor (mirror of ucie_phy_model.sv) ----------------
  void flit_reset_() { fbeat_ = 0; fc_sent_ = 0; fin_frame_ = false; }
  void flit_beat_(const UcieOut& o) {
    if (o.tx_start_flit && !o.tx_valid) err_("start_flit without tx_valid");
    if (o.tx_valid) {
      if (o.tx_start_flit && fbeat_ != 0) err_("start_flit mid-flit");
      if (!o.tx_start_flit && fbeat_ == 0) err_("flit beat 0 without start_flit");
      for (int b = 0; b < 8; b++) fl_[fbeat_ * 8 + b] = uint8_t(o.tx_data >> (8 * b));
      if (fbeat_ == FLIT_BEATS - 1) { fbeat_ = 0; flit_done_(); } else fbeat_++;
    } else if (fbeat_ != 0) { err_("tx_valid dropped mid-flit"); fbeat_ = 0; }
  }
  void flit_done_() {
    bool hv = fl_[0] & 1, hsof = (fl_[0] >> 1) & 1, heof = (fl_[0] >> 2) & 1;
    int plen = fl_[1];
    if (!hv) err_("header valid bit clear");
    if (fl_[0] >> 3) err_("header reserved bits nonzero");
    if (plen > FLIT_PAYLOAD_B) err_("payload length > 240");
    bool cr = FLOW_CTRL && plen == 0 && !hsof && !heof;
    if (plen == 0 && !cr) err_("empty flit emitted");
    bool padbad = false;
    for (int b = FLIT_HDR_B + plen; b < FLIT_BYTES; b++)
      if (!(FLOW_CTRL && b >= FLIT_FC_OFF && b < FLIT_FC_OFF + 4) && fl_[b] != 0) padbad = true;
    if (padbad) err_("nonzero padding/DLP/FEC byte");
    if (FLOW_CTRL) {
      unsigned seq = fl_[FLIT_FC_OFF] | (fl_[FLIT_FC_OFF + 1] << 8);
      last_cl = fl_[FLIT_FC_OFF + 2] | (fl_[FLIT_FC_OFF + 3] << 8);
      if (seq != (fc_sent_ & 0xFFFFu)) err_("flow-control seq field != data flits sent before");
    }
    if (cr) cr_flits++; else { flits_++; fc_sent_++; fin_frame_ = !heof; }
  }
  uint8_t fl_[FLIT_BYTES] = {};
  int fbeat_ = 0;
  unsigned fc_sent_ = 0;
  bool fin_frame_ = false;
  int flits_ = 0;

  // ---- remote-die control model (mirror of ucie_sb_model.sv) ----------------
  int rd_phase_ = 0, rst_cnt_ = 0, sb_cnt_ = 0, mb_cnt_ = 0, st_cnt_ = 0, ack_cnt_ = 0;
  int sb_ph_ = 0, pd_q_ = PWR_L1, speed_q_ = SPEED_64, width_q_ = 0;
  int sb_addr_ = 0;
  static constexpr int LAT = 8, RST_CYCLES = 16, SB_LAT = 8, MB_LAT = 8;
  void remote_reset_() {
    uin_.link_status = true; uin_.rx_active = false; uin_.rx_elec_idle = true; uin_.sb_s2m = 0;
    rd_phase_ = rst_cnt_ = sb_cnt_ = mb_cnt_ = st_cnt_ = ack_cnt_ = sb_ph_ = sb_addr_ = 0;
    pd_q_ = PWR_L1; speed_q_ = SPEED_64; width_q_ = 0;
  }
  void remote_die_(const UcieOut& o) {
    if (!rst_n_) { remote_reset_(); return; }
    uin_.link_status = false;
    uin_.sb_s2m = 0;
    switch (rd_phase_) {
      case 0:
        uin_.link_status = true;
        if (rst_cnt_ < RST_CYCLES) rst_cnt_++;
        else { uin_.link_status = false; rd_phase_ = 1; sb_cnt_ = 0; }
        break;
      case 1:
        if (sb_cnt_ < SB_LAT) sb_cnt_++;
        else { uin_.rx_elec_idle = false; rd_phase_ = 2; mb_cnt_ = 0; }
        break;
      case 2:
        if (mb_cnt_ < MB_LAT) mb_cnt_++;
        else { uin_.rx_active = true; rd_phase_ = 3; }
        break;
      default: break;
    }
    bool change = o.powerdown != pd_q_ || o.speed != speed_q_ || o.width != width_q_;
    if (rd_phase_ == 3) {
      if (change) { st_cnt_ = LAT; }
      else if (st_cnt_ == 1) { st_cnt_ = 0; uin_.link_status = true; }
      else if (st_cnt_ > 1) { st_cnt_--; }
    }
    // Tx legality
    if (o.tx_valid && o.powerdown != PWR_L0) err_("Tx valid while powerdown != L0");
    if (o.tx_valid && (st_cnt_ != 0 || change)) err_("Tx valid during a speed/width/power change");
    pd_q_ = o.powerdown; speed_q_ = o.speed; width_q_ = o.width;

    // sideband target (byte-serial write + ack)
    int m2s = o.sb_m2s & 0xFF;
    if (sb_ph_ == 1) { sb_addr_ = (sb_addr_ & 0xFF) | (m2s << 8); sb_ph_ = 2; }
    else if (sb_ph_ == 2) { sb_addr_ = (sb_addr_ & 0xFF00) | m2s; sb_ph_ = 3; }
    else if (sb_ph_ == 3) { last_sb_addr = sb_addr_; last_sb_data = m2s; sb_writes++; sb_ph_ = 0; ack_cnt_ = LAT; }
    else if (m2s != 0) {
      if (((m2s >> 4) & 0xF) == SB_WR) sb_ph_ = 1;
      else err_("unsupported M2S sideband command");
    }
    if (ack_cnt_ == 1) { ack_cnt_ = 0; uin_.sb_s2m = (SB_WR_ACK << 4); }
    else if (ack_cnt_ > 1) ack_cnt_--;
  }
 public:
  int sb_writes = 0, last_sb_addr = 0, last_sb_data = 0;
 private:

  // ---- PCIe AXI-S MAC source ------------------------------------------------
  std::deque<int> mac_q_;
  int mac_off_ = 0, mac_n_ = 0, cur_len_ = 0, cur_scen_ = 0;
  bool mac_valid_ = false;
  void mac_source_(const PcieOut& po) {
    if (!rst_n_) { mac_q_.clear(); mac_off_ = 0; mac_valid_ = false; pin_.tvalid = false; return; }
    if (mac_valid_ && po.tready) {
      mac_off_ += mac_n_;
      mac_valid_ = false;
      if (mac_off_ >= cur_len_) { mac_q_.pop_front(); mac_off_ = 0; }
    }
    if (!mac_valid_ && !mac_q_.empty() && !rng_.pct(mac_gap_pct)) {
      int id = mac_q_.front();
      cur_len_ = scen_len_(cur_scen_, id);
      int n = cur_len_ - mac_off_;
      if (n > PCIE_BYTES) n = PCIE_BYTES;
      memset(pin_.data, 0, sizeof pin_.data);
      for (int i = 0; i < n; i++) pin_.data[i] = pat(id, mac_off_ + i);
      pin_.keep = (n == PCIE_BYTES) ? 0xFFFFFFFFu : ((1u << n) - 1);
      pin_.tlast = (mac_off_ + n == cur_len_);
      pin_.tuser = 0;
      mac_n_ = n;
      mac_valid_ = true;
    }
    pin_.tvalid = mac_valid_;
  }
  void send_frame_(int id) { mac_q_.push_back(id); }
  bool mac_idle_() const { return mac_q_.empty() && !mac_valid_; }

  // ---- PCIe sink + scoreboard ----------------------------------------------
  std::vector<uint8_t> fbuf_;
  int abort_pending_ = 0, abort_seen_ = 0;      // injected aborts still expected / seen at the sink
  std::deque<std::vector<uint8_t>> inj_exp_;    // injected good frames still expected at the sink
  bool probe_ = false;               // debug prints (+probe), off in normal runs
 public:
  void set_probe(bool p) { probe_ = p; }
 private:
  struct InjBeat { uint64_t d; bool v, s; };
  std::deque<InjBeat> inj_q_;
  bool inj_hold_ = false;
  int rx_frames_ = 0;
  void sink_(const PcieOut& po) {
    if (!rst_n_) { fbuf_.clear(); rx_frames_ = 0; pin_.rx_tready = false; return; }
    if (po.rx_tvalid && pin_.rx_tready) {
      int nb = 0; bool kbad = false;
      for (int i = 0; i < PCIE_BYTES; i++) {
        if ((po.rx_keep >> i) & 1) { nb++; if (i > 0 && !((po.rx_keep >> (i - 1)) & 1)) kbad = true; }
      }
      if (nb == 0 || (!po.rx_tlast && nb != PCIE_BYTES)) kbad = true;
      if ((po.rx_tuser & 1) && !po.rx_tlast) kbad = true;
      if (kbad) err_("sink: illegal tkeep/tuser");
      for (int i = 0; i < nb; i++) fbuf_.push_back(po.rx_data[i]);
      if (po.rx_tlast) {
        bool aborted = po.rx_tuser & 1;
        int id = rx_frames_;
        if (aborted && abort_pending_ > 0) {           // injected abort (B2): expected, not a data frame
          abort_pending_--; abort_seen_++;
          if (probe_) printf("[cyc %lld] PROBE sink abort frame bytes=%zu\n", cyc_, fbuf_.size());
          fbuf_.clear(); pin_.rx_tready = rng_.pct(sink_ready_pct); return;
        }
        if (!aborted && !inj_exp_.empty()) {           // injected good frame (B2): compare, not a data frame
          if (fbuf_ != inj_exp_.front()) err_("injected frame payload");
          inj_exp_.pop_front(); fbuf_.clear(); pin_.rx_tready = rng_.pct(sink_ready_pct); return;
        }
        if (aborted) err_("frame aborted");
        else if (id >= scen_nframes_(cur_scen_) || int(fbuf_.size()) != scen_len_(cur_scen_, id))
          err_("frame length");
        else
          for (size_t i = 0; i < fbuf_.size(); i++)
            if (fbuf_[i] != pat(id, int(i))) { err_("frame payload"); break; }
        if (sc_ >= 0 && sc_ < int(results.size())) {
          for (uint8_t b : fbuf_) results[sc_].crc = crc32_byte(results[sc_].crc, b);
          results[sc_].bytes += long(fbuf_.size());
        }
        rx_frames_++;
        fbuf_.clear();
      }
    }
    pin_.rx_tready = rng_.pct(sink_ready_pct);
  }

  // ---- scenario sequencer ---------------------------------------------------
  enum Phase { P_RESET, P_WAIT_UP, P_SEND1, P_CTRL, P_SEND2, P_DRAIN, P_RECORD, P_NEXT, P_DONE,
               P_RWAIT, P_INJ };
  int sc_ = -1;                     // active scenario index into results
  Phase phase_ = P_RESET;
  int rst_hold_ = 0, settle_cnt_ = 0, drain_cnt_ = 0;
  int ctrl_step_ = 0;               // sub-step of the control op
  // CSR micro-op engine ------------------------------------------------------
  int csr_stage_ = 0;               // 0 idle, 1 drive write, 2 deassert, 3 read-addr settle
  void csr_wr_begin_(int addr, uint32_t data) {
    uin_.csr_valid = true; uin_.csr_write = true; uin_.csr_addr = addr; uin_.csr_wdata = data;
    csr_stage_ = 1;
  }
  bool csr_wr_tick_() {             // returns true when the write has been applied+deasserted
    if (csr_stage_ == 1) { uin_.csr_valid = false; uin_.csr_write = false; csr_stage_ = 0; return true; }
    return false;
  }
  uint32_t status_val(const UcieOut& uo) { return uo.csr_rdata; }

  // Read a CSR by holding the address; the combinational rdata is sampled next cycle.
  int rd_addr_ = -1, rd_wait_ = 0;

  void sequencer_(const UcieOut& uo) {
    cyc_++;
    switch (phase_) {
      case P_RESET:
        rst_n_ = false;
        if (++rst_hold_ >= 12) { rst_n_ = true; phase_ = P_WAIT_UP; }
        break;
      case P_WAIT_UP: {
        rst_n_ = true;
        uin_.csr_addr = CSR_STATUS;           // poll link-active
        if ((uo.csr_rdata & (1u << 12)) != 0) {
          // new scenario
          sc_++;
          if (sc_ >= (rand_mode ? 1 : 5)) { finish_(); break; }
          ScenResult r; r.name = scen_name_(sc_); results.push_back(r);
          cur_scen_ = sc_; rx_frames_ = 0; fbuf_.clear();
          flits_at_scen_ = flits_;
          if (rand_mode) { rnd_begin_(); phase_ = P_RWAIT; break; }
          // enqueue first half (or all, for ctrl==0)
          int nfr = scen_nframes_(sc_);
          send_lo_ = 0; send_hi_ = (scen_ctrl_(sc_) == 0) ? nfr : nfr / 2;
          for (int i = send_lo_; i < send_hi_; i++) send_frame_(i);
          phase_ = (scen_ctrl_(sc_) == 0) ? P_DRAIN : P_SEND1;
          wait_target_ = (scen_ctrl_(sc_) == 0) ? nfr : nfr / 2;
        }
        break;
      }
      case P_SEND1:
        uin_.csr_addr = CSR_STATUS;
        if (rx_frames_ >= wait_target_) { phase_ = P_CTRL; ctrl_step_ = 0; }
        break;
      case P_CTRL:
        run_ctrl_(uo);
        break;
      case P_SEND2: {
        int nfr = scen_nframes_(sc_);
        for (int i = nfr / 2; i < nfr; i++) send_frame_(i);
        wait_target_ = nfr;
        phase_ = P_DRAIN;
        break;
      }
      case P_DRAIN:
        uin_.csr_addr = CSR_STATUS;
        if (rx_frames_ >= wait_target_ && mac_idle_()) {
          if (++drain_cnt_ >= 400) { drain_cnt_ = 0; phase_ = P_RECORD; rd_addr_ = CSR_PMCNT; rd_wait_ = 0; uin_.csr_addr = CSR_PMCNT; }
        } else drain_cnt_ = 0;
        break;
      case P_RWAIT: rnd_wait_(uo); break;
      case P_INJ: rnd_inj_(uo); break;
      case P_RECORD:
        uin_.csr_addr = CSR_PMCNT;
        if (++rd_wait_ >= 2) {
          results[sc_].pmcnt = uo.csr_rdata & 0xFFFF;
          if (rand_mode && results[sc_].pmcnt != uint32_t(pm_model_)) err_("PMCNT != model at end of run");
          results[sc_].frames = rx_frames_;
          results[sc_].flits = flits_ - flits_at_scen_;
          printf("SCEN %-12s frames=%d bytes=%ld flits=%d crc32=%08x pmcnt=%u errors=%d\n",
                 results[sc_].name.c_str(), results[sc_].frames, results[sc_].bytes,
                 results[sc_].flits, results[sc_].crc ^ 0xFFFFFFFFu, results[sc_].pmcnt,
                 results[sc_].errors);
          phase_ = P_NEXT;
        }
        break;
      case P_NEXT:
        rst_n_ = false; rst_hold_ = 0; phase_ = P_RESET;
        break;
      case P_DONE:
        done = true;
        break;
    }
  }

  int send_lo_ = 0, send_hi_ = 0, wait_target_ = 0, flits_at_scen_ = 0;

  // Control-op sub-sequencer: pm_cycle (L0->L1->L0) or speed_change (64->32->64).
  // Uses CSR writes to CTRL and polls STATUS until the op is not in flight (d[11]==0)
  // and the requested fields match.
  int ctrl_phase_ = 0, ctrl_wait_ = 0;
  uint32_t ctrl_target_ = 0;         // expected STATUS low bits {width,speed,pwr}
  void ctrl_issue_(int pd, int sp, int wd) {
    csr_wr_begin_(CSR_CTRL, uint32_t(pd | (sp << 2) | (wd << 5)));
    ctrl_target_ = uint32_t(pd | (sp << 2) | (wd << 5));
    ctrl_phase_ = 1;
  }
  bool ctrl_settled_(const UcieOut& uo) {
    uint32_t d = uo.csr_rdata;
    return (d & 0x7F) == ctrl_target_ && (d & (1u << 11)) == 0;
  }
  void run_ctrl_(const UcieOut& uo) {
    // ctrl_step_ : 0 first op, 1 gap, 2 second op
    switch (ctrl_step_) {
      case 0:
        if (ctrl_phase_ == 0) {
          if ((rand_mode ? cur_op_ : scen_ctrl_(sc_)) == 1) ctrl_issue_(PWR_L1, SPEED_64, 0);
          else ctrl_issue_(PWR_L0, SPEED_32, 0);
        } else if (ctrl_phase_ == 1) {
          csr_wr_tick_(); ctrl_phase_ = 2; uin_.csr_addr = CSR_STATUS;
        } else {
          uin_.csr_addr = CSR_STATUS;
          if (ctrl_settled_(uo)) { ctrl_phase_ = 0; ctrl_step_ = 1; ctrl_wait_ = 0; }
        }
        break;
      case 1:
        if (++ctrl_wait_ >= 200) ctrl_step_ = 2;
        break;
      case 2:
        if (ctrl_phase_ == 0) {
          ctrl_issue_(PWR_L0, SPEED_64, 0);
        } else if (ctrl_phase_ == 1) {
          csr_wr_tick_(); ctrl_phase_ = 2; uin_.csr_addr = CSR_STATUS;
        } else {
          uin_.csr_addr = CSR_STATUS;
          if (ctrl_settled_(uo)) {
            ctrl_phase_ = 0;
            if (rand_mode) rnd_ctrl_done_(); else phase_ = P_SEND2;
          }
        }
        break;
    }
  }

  // ===========================================================================
  // Random-regression stimulus (rand_mode only; mirrored by scenarios.expected_rand()).
  //   B1: `rand_nctl` control ops (pm_cycle: +2 pmcnt, speed_change: +4) at frame boundaries
  //       b_i = nfr*(i+1)/(nctl+1).  Drained mode: segment sent, drained, op, next segment.
  //       Mid mode (rand_mid): all frames queued up front, the op fires as soon as b_i frames
  //       were received, i.e. with later frames in flight (the DUT gates/holds them).
  //   B2: CSR traffic while the link is up (reads of every register + unmapped addresses, W1C ERR
  //       writes, reserved-width CTRL writes, writes to RO/unmapped addresses, `rand_ncfg`
  //       SPEEDCFG writes), each read checked against a register model; Rx-side error injection
  //       at the quiescent end of the run (`rand_nrx` injections), RXCNT0/1 + sink checked.
  // ===========================================================================
 public:
  static int rnd_op_(uint32_t seed, int ctl, int i) {   // 1 pm_cycle, 2 speed_change (== scenarios.rand_ops)
    return ctl == 3 ? (((seed >> (i % 31)) & 1) ? 2 : 1) : ctl;
  }
  static int rnd_inj_type_(uint32_t seed, int i) { return int((seed + 7u * unsigned(i)) % 5u); }
 private:
  std::vector<int> r_ops_, r_b_;
  int r_i_ = 0, r_enq_ = 0, cur_op_ = 0;
  int pm_model_ = 0, err_model_ = 0, spd_model_ = 0x21, cfg_done_ = 0, csr_block_ = 0;
  int sb_chk_ = 0, sb_chk_n_ = 0, sb_wait_ = 0;   // SPEEDCFG sideband check: 0 idle, 1 op pending, 2 done
  int rd_pend_ = -1, inj_i_ = 0, inj_st_ = 0, inj_wait_ = 0;
  uint32_t rx_exp_[4] = {0, 0, 0, 0};   // lock_errors, dropped_flits, aborted_frames, bad_flits

  bool csr_idle_() const { return rd_pend_ < 0 && csr_stage_ == 0; }
  bool tx_quiet_(const UcieOut& uo) const { return fbeat_ == 0 && !uo.tx_valid; }

  void rnd_begin_() {
    r_ops_.clear(); r_b_.clear();
    int nops = rand_ctl ? rand_nctl : 0;
    for (int i = 0; i < nops; i++) {
      r_ops_.push_back(rnd_op_(rand_seed, rand_ctl, i));
      r_b_.push_back(rand_frames * (i + 1) / (nops + 1));
    }
    r_i_ = 0; r_enq_ = 0;
    int upto = (nops > 0 && !rand_mid) ? r_b_[0] : rand_frames;
    for (; r_enq_ < upto; r_enq_++) send_frame_(r_enq_);
    wait_target_ = rand_frames;
    pm_model_ = LINKUP_OPS_; csr_block_ = 300; spd_model_ = 0x21; err_model_ = 0; cfg_done_ = 0;
    rd_pend_ = -1; inj_i_ = 0; inj_st_ = 0; sb_chk_ = 0; drain_cnt_ = 0;
    for (int i = 0; i < 4; i++) rx_exp_[i] = 0;
    abort_pending_ = abort_seen_ = 0; inj_exp_.clear(); inj_q_.clear();
  }
  static constexpr int LINKUP_OPS_ = 2;

  void rnd_ctrl_done_() {
    pm_model_ += (cur_op_ == 1) ? 2 : 4;
    csr_block_ = 40;
    r_i_++;
    if (!rand_mid) {
      int upto = (r_i_ < int(r_ops_.size())) ? r_b_[r_i_] : rand_frames;
      for (; r_enq_ < upto; r_enq_++) send_frame_(r_enq_);
    }
    phase_ = P_RWAIT;
  }

  void rnd_check_read_(int addr, uint32_t d) {
    char m[96];
    uint32_t exp = 0; bool chk = true;
    switch (addr) {
      case CSR_CTRL: exp = (SPEED_64 << 2); break;     // L0 / 64 GT/s / x1: every op returns here
      case CSR_SPEEDCFG: exp = uint32_t(spd_model_); break;
      case CSR_STATUS:   // settled link: L0, 64 GT/s, x1, state ACTIVE(4), active, !busy, rx_active, !elec_idle
        // An op (or a cfg send) ends in ST_DRAIN(5), which only returns to ACTIVE once the datapath is
        // idle (FC credit flits / traffic can hold it there): both are legal; every other field is fixed.
        exp = (1u << 13) | (1u << 12) | (4u << 7) | (SPEED_64 << 2);
        if (d == ((1u << 13) | (1u << 11) | (5u << 7) | (SPEED_64 << 2))) exp = d;   // ST_DRAIN: busy, !active
        chk = csr_block_ == 0; break;
      case CSR_ERR: exp = uint32_t(err_model_); break;
      case CSR_RXCNT0: exp = (rx_exp_[0] << 16) | rx_exp_[1]; break;
      case CSR_RXCNT1: exp = (rx_exp_[2] << 16) | rx_exp_[3]; break;
      case CSR_PMCNT:
        exp = uint32_t(pm_model_); chk = csr_block_ == 0;
        if (sb_chk_ == 1) {                    // SPEEDCFG in flight: PMCNT is pm_model_-1 until it completes
          chk = false;
          if (d == uint32_t(pm_model_)) { sb_chk_ = 2; csr_block_ = 20; }
          else if (d != uint32_t(pm_model_ - 1)) err_("PMCNT while SPEEDCFG pending is neither old nor new value");
        }
        break;
      default: exp = 0; break;                            // unmapped reads 0
    }
    if (chk && d != exp) {
      snprintf(m, sizeof m, "CSR read 0x%02x = 0x%x, model 0x%x", addr, d, exp);
      err_(m);
    }
  }

  void rnd_csr_op_(bool force_cfg) {
    int r = int(rng_.next() % 100);
    static const int regs[] = {CSR_CTRL, CSR_SPEEDCFG, CSR_STATUS, CSR_ERR, CSR_RXCNT0, CSR_RXCNT1, CSR_PMCNT};
    auto unmapped = [&]() {
      for (;;) {
        int a = int(rng_.next() & 0xFF);
        bool mapped = false;
        for (int x : regs) mapped |= (x == a);
        if (!mapped) return a;
      }
    };
    if (force_cfg || (r >= 85 && cfg_done_ < rand_ncfg && csr_block_ == 0)) {
      if (csr_block_ != 0 || cfg_done_ >= rand_ncfg) return;
      uint32_t v = rng_.next() & 0xFF;
      csr_wr_begin_(CSR_SPEEDCFG, v);
      if (probe_) printf("[cyc %lld] PROBE cfg write %u\n", cyc_, v);
      spd_model_ = int(v & 0x3F); pm_model_++; cfg_done_++; csr_block_ = 1 << 30;
      sb_chk_ = 1; sb_chk_n_ = sb_writes; sb_wait_ = 0;
    } else if (r < 50 || r >= 85) {
      int a = (rng_.next() % 10 < 7) ? regs[rng_.next() % 7] : ((rng_.next() & 1) ? unmapped() : int(rng_.next() & 0xFF));
      uin_.csr_addr = a; rd_pend_ = a;
    } else if (r < 65) {
      uint32_t mask = rng_.next() & 0xF;
      csr_wr_begin_(CSR_ERR, mask);
      err_model_ &= ~int(mask);
    } else if (r < 75) {
      csr_wr_begin_(CSR_CTRL, (3u << 5) | ((rng_.next() & 7) << 2) | (rng_.next() & 3));   // reserved width: ignored
      err_model_ |= 8;
    } else {
      static const int ro[] = {CSR_STATUS, CSR_RXCNT0, CSR_RXCNT1, CSR_PMCNT};
      int a = (rng_.next() & 1) ? ro[rng_.next() % 4] : unmapped();
      csr_wr_begin_(a, rng_.next());                  // writes to RO / unmapped: no effect
    }
  }

  // one cycle of CSR-engine housekeeping + (optionally) a new random op
  void rnd_csr_cycle_(const UcieOut& uo, bool allow_new, bool force_cfg) {
    if (rd_pend_ >= 0) { rnd_check_read_(rd_pend_, uo.csr_rdata); rd_pend_ = -1; uin_.csr_addr = CSR_STATUS; return; }
    if (csr_stage_ == 1) { csr_wr_tick_(); uin_.csr_addr = CSR_STATUS; return; }
    // A SPEEDCFG write is only executed once the datapath has drained (long frames in flight can
    // take thousands of cycles): poll PMCNT until it shows the model value, then check the sideband.
    if (sb_chk_ == 1) {
      if (++sb_wait_ > 200000) { err_("SPEEDCFG operation never completed (PMCNT)"); sb_chk_ = 0; csr_block_ = 0; return; }
      if (rng_.pct(25)) { uin_.csr_addr = CSR_PMCNT; rd_pend_ = CSR_PMCNT; return; }
    }
    if (csr_block_ > 0 && sb_chk_ != 1) { csr_block_--; if (csr_block_ == 0 && sb_chk_ == 2) {
        sb_chk_ = 0;
        if (probe_) printf("[cyc %lld] PROBE sb_writes=%d at_write=%d\n", cyc_, sb_writes, sb_chk_n_);
        if (sb_writes != sb_chk_n_ + 1) err_("SPEEDCFG write did not produce exactly one sideband write");
        else if (last_sb_addr != SB_ADDR_TX_PRESET || last_sb_data != spd_model_) err_("SPEEDCFG sideband write addr/data");
    } }
    if (allow_new && (force_cfg || rng_.pct(rand_csr))) rnd_csr_op_(force_cfg);
  }

  void rnd_wait_(const UcieOut& uo) {
    int nops = int(r_ops_.size());
    if (probe_ && (cyc_ % 20000) == 0)
      printf("PROBE cyc=%lld rxf=%d macidle=%d txq=%d blk=%d stage=%d pend=%d tready=%d\n", cyc_, rx_frames_,
             mac_idle_(), tx_quiet_(uo), csr_block_, csr_stage_, rd_pend_, 0);
    bool all_in = rx_frames_ >= rand_frames && mac_idle_() && tx_quiet_(uo);
    bool force = r_i_ >= nops && all_in && cfg_done_ < rand_ncfg;
    // random CSR traffic runs while data/ctrl is in progress; at the quiescent end only the forced
    // SPEEDCFG writes (to reach exactly rand_ncfg) are issued, so the end-of-run drain can complete
    rnd_csr_cycle_(uo, (rand_csr > 0 && !(r_i_ >= nops && all_in)) || force, force);
    bool qd = csr_idle_() && csr_block_ == 0;
    if (r_i_ < nops) {
      if (rx_frames_ >= r_b_[r_i_] && qd && (rand_mid || (mac_idle_() && tx_quiet_(uo)))) {
        cur_op_ = r_ops_[r_i_]; phase_ = P_CTRL; ctrl_step_ = 0; ctrl_phase_ = 0;
      }
    } else if (all_in && qd && cfg_done_ >= rand_ncfg) {
      if (++drain_cnt_ >= 300) { drain_cnt_ = 0; phase_ = P_INJ; inj_st_ = 0; }
    } else drain_cnt_ = 0;
  }

  // ---- Rx-side error injection ------------------------------------------------
  void inj_flit_(bool hv, bool sof, bool eof, int plen, int base, bool corrupt_mid_start) {
    uint8_t fl[FLIT_BYTES] = {};
    fl[0] = uint8_t((hv ? 1 : 0) | (sof ? 2 : 0) | (eof ? 4 : 0));
    fl[1] = uint8_t(plen);
    for (int i = 0; i < plen; i++) fl[FLIT_HDR_B + i] = uint8_t(base + i);
    for (int beat = 0; beat < FLIT_BEATS; beat++) {
      uint64_t w = 0;
      for (int b = 0; b < 8; b++) w |= uint64_t(fl[beat * 8 + b]) << (8 * b);
      bool st = (beat == 0) || (corrupt_mid_start && beat == 5);
      inj_q_.push_back({w, true, st});
      if (corrupt_mid_start && beat == 5) break;
    }
  }
  void inj_idle_(int n) { for (int i = 0; i < n; i++) inj_q_.push_back({0, false, false}); }
  // measured deltas {lock, dropped, aborted, bad} per injection type (see dv/random/README.md B2)
  static const int* inj_delta_(int t) {
    static const int d[5][4] = {{1, 0, 0, 0}, {2, 0, 0, 0}, {1, 0, 0, 0}, {0, 0, 0, 1}, {0, 0, 1, 0}};
    return d[t];
  }
  void inj_build_(int t) {
    switch (t) {
      case 0: inj_q_.push_back({0xDEAD, true, false}); inj_idle_(4); break;          // stray data beat
      case 1: inj_flit_(true, true, false, 240, 0x10, true); inj_idle_(4); break;    // start_flit mid-flit
      case 2:                                                                         // valid dropped mid-flit
        for (int b = 0; b < 6; b++) inj_q_.push_back({b == 0 ? 7u : 0u, true, b == 0});
        inj_idle_(4); break;
      case 3: inj_flit_(true, false, true, 32, 0x20, false); inj_idle_(4); break;    // orphan (no sof)
      case 4:                                                                         // sof mid-frame: abort
        inj_flit_(true, true, false, 240, 0x30, false); inj_idle_(10);
        inj_flit_(true, true, true, 240, 0x40, false); inj_idle_(4);
        abort_pending_++;
        { std::vector<uint8_t> v; for (int i = 0; i < 240; i++) v.push_back(uint8_t(0x40 + i)); inj_exp_.push_back(v); }
        break;
    }
    const int* d = inj_delta_(t);
    for (int i = 0; i < 4; i++) rx_exp_[i] += uint32_t(d[i]);
  }

  // P_INJ: for each injection: build, wait for drain + 150 idle cycles, read RXCNT0/1 and compare to
  // the model; after the last one: final RXCNT0/1 + ERR read-back (also runs when nrx == 0: a clean run
  // must show all-zero Rx error counters), recorded in the result for the golden model.
  void rnd_inj_(const UcieOut& uo) {
    switch (inj_st_) {
      case 0:
        if (inj_i_ < rand_nrx && !tx_quiet_(uo)) break;      // never start in the middle of a Tx flit
        if (inj_i_ < rand_nrx) { inj_build_(rnd_inj_type_(rand_seed, inj_i_)); inj_wait_ = 0; inj_st_ = 1; }
        else inj_st_ = 4;
        break;
      case 1:
        if (inj_q_.empty() && ++inj_wait_ >= 150) {
          if (abort_pending_ != 0 || !inj_exp_.empty()) err_("injected abort/frame not observed at the sink");
          uin_.csr_addr = CSR_RXCNT0; inj_st_ = 2;
        }
        break;
      case 2: inj_chk_(CSR_RXCNT0, uo.csr_rdata); uin_.csr_addr = CSR_RXCNT1; inj_st_ = 3; break;
      case 3: inj_chk_(CSR_RXCNT1, uo.csr_rdata); inj_i_++; inj_st_ = 0; break;
      case 4: uin_.csr_addr = CSR_RXCNT0; inj_st_ = 5; break;
      case 5: inj_chk_(CSR_RXCNT0, uo.csr_rdata); results[sc_].rx0 = uo.csr_rdata;
              uin_.csr_addr = CSR_RXCNT1; inj_st_ = 6; break;
      case 6: inj_chk_(CSR_RXCNT1, uo.csr_rdata); results[sc_].rx1 = uo.csr_rdata;
              uin_.csr_addr = CSR_ERR; inj_st_ = 7; break;
      case 7: rnd_check_read_(CSR_ERR, uo.csr_rdata);
              phase_ = P_DRAIN; drain_cnt_ = 0; break;      // P_DRAIN -> P_RECORD (PMCNT) as usual
    }
  }
  void inj_chk_(int addr, uint32_t d) { rnd_check_read_(addr, d); }

  void finish_() {
    // trim the extra pushed result (sc_ == 5 path not reached) — handled by guard
    phase_ = P_DONE;
    done = true;
  }
};

// ---- legacy helpers kept for any direct users ------------------------------
inline std::vector<int> lcg_lengths(uint32_t seed, int n, int max_len = 2000) {
  uint32_t x = seed & 0x7FFFFFFFu;
  std::vector<int> out;
  out.reserve(n);
  for (int i = 0; i < n; i++) {
    x = (1103515245u * x + 12345u) & 0x7FFFFFFFu;
    out.push_back(1 + static_cast<int>((x >> 8) % static_cast<uint32_t>(max_len)));
  }
  return out;
}

}  // namespace adapter_bfm
#endif  // ADAPTER_BFM_H
