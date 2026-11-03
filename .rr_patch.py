p='dv/common/cpp/adapter_bfm.h'
s=open(p).read()
def r(a,b):
    global s
    assert s.count(a)==1,a
    s=s.replace(a,b)
r('''  static const char* scen_name_(int s) {
    static const char* n[] = {"single", "corners", "random", "pm_cycle", "speed_change"};
    return n[s];
  }
  static int scen_nframes_(int s) {
    static const int n[] = {1, 11, 40, 16, 16};
    return n[s];
  }
  static int scen_ctrl_(int s) { return s == 3 ? 1 : s == 4 ? 2 : 0; }
  static int scen_len_(int s, int i) {
''','''  // rand_mode (random regression, dv/random/rr.py): one scenario "rand" = `rand_frames`
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
''')
r('''  int sink_ready_pct = 90;
''','''  int sink_ready_pct = 90;
  bool rand_mode = false;           // run only the `rand` scenario (see scen_name_)
  uint32_t rand_seed = 1;
  int rand_frames = 24, rand_maxlen = 2000;
''')
r('if (sc_ >= 5) { finish_(); break; }','if (sc_ >= (rand_mode ? 1 : 5)) { finish_(); break; }')
r('''    fprintf(f, "}}\\n");''','''    if (rand_mode)
      fprintf(f, "}, \\"rand\\": {\\"seed\\": %u, \\"frames\\": %d, \\"maxlen\\": %d, \\"ctl\\": 0}}\\n",
              rand_seed, rand_frames, rand_maxlen);
    else
      fprintf(f, "}}\\n");''')
open(p,'w').write(s)

p='dv/vlt/sim_main.cpp'
s=open(p).read()
r('static int run_scen() {\n    Harness h;','''// +rand knobs (random regression): +seed=N +frames=N +maxlen=N +gap=PCT +ready=PCT
static bool rand_mode = false;
static uint32_t k_seed = 1;
static int k_frames = 24, k_maxlen = 2000, k_gap = -1, k_ready = -1;

static int run_scen() {
    Harness h(rand_mode ? k_seed * 2654435761u + 1 : 12345);
    if (rand_mode) {
        h.rand_mode = true; h.rand_seed = k_seed; h.rand_frames = k_frames; h.rand_maxlen = k_maxlen;
    }
    if (k_gap >= 0) h.mac_gap_pct = k_gap;
    if (k_ready >= 0) h.sink_ready_pct = k_ready;''')
r('h.results.size() == 5;','h.results.size() == (rand_mode ? 1u : 5u);')
r('''    for (int i = 1; i < argc; i++) if (!strcmp(argv[i], "+scen")) scen = true;''','''    for (int i = 1; i < argc; i++) {
        const char* a = argv[i];
        if (!strcmp(a, "+scen")) scen = true;
        else if (!strcmp(a, "+rand")) { scen = true; rand_mode = true; }
        else if (!strncmp(a, "+seed=", 6)) k_seed = uint32_t(strtoul(a + 6, 0, 0));
        else if (!strncmp(a, "+frames=", 8)) k_frames = atoi(a + 8);
        else if (!strncmp(a, "+maxlen=", 8)) k_maxlen = atoi(a + 8);
        else if (!strncmp(a, "+gap=", 5)) k_gap = atoi(a + 5);
        else if (!strncmp(a, "+ready=", 7)) k_ready = atoi(a + 7);
    }''')
open(p,'w').write(s)
