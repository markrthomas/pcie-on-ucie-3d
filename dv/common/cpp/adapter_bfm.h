// dv/common/cpp/adapter_bfm.h — C++ mirror of dv/common/scenarios.py, shared by
// the Verilator (dv/vlt) and SystemC (dv/systemc) harnesses.  Same pat()/LCG
// constants so both compute the golden expectations the Python model does.
// M0: the frame-pattern + length helpers; the scenario sequencer and the
// Config-1 loopback driver land with the datapath (M1+).
#ifndef ADAPTER_BFM_H
#define ADAPTER_BFM_H
#include <cstdint>
#include <vector>

namespace adapter_bfm {

constexpr int FLIT_PAYLOAD_B = 240;

// Frame byte pattern — must equal scenarios.pat().
inline uint8_t pat(int frame_id, int idx) {
    return static_cast<uint8_t>((frame_id * 37 + idx * 13 + (idx >> 8) + 5) & 0xFF);
}

// LCG length stream — must equal scenarios.lcg_lengths().
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
