"""pd_emu.py — UPF-like power-state emulation of PD_DP for the adapter (cocotb, Icarus).

No power tool and no UPF semantics: this emulates what lp/adapter.upf would do in a
power-aware simulator, driven by the DV-only PMU (lp/adapter_pmu.sv) outputs, all on
ucie_clk:

  dp_pwr_en = 0   corrupt: every ucie_clk, all state registers of the PD_DP instances get
                  random values (a powered-off domain holds nothing; random rather than X
                  so Icarus keeps running)
  dp_save pulse   retention save: snapshot the *retained* state groups
  dp_restore      retention restore: write the snapshot back (same cycle as the restore pulse)
  dp_iso_en = 1   isolation: the PD_DP outputs the always-on logic reads are FORCED to their
                  clamp values (lp/adapter.upf ISO_DP_1 / ISO_DP_0); the PD_DP outputs on the
                  DUT ports are ignored by the models via PdEmu.iso (clamp 0 = no handshake)

State groups = per PD_DP instance `<inst>/ctl` (registers narrower than WIDE_BITS), `<inst>/wide`
(registers of WIDE_BITS or more: flit buffers, accumulators) and `<inst>/mem` (register arrays,
i.e. the two CDC FIFO memories).  `retain` selects which groups are saved/restored; the rest stay
corrupt after power-up.  Limits: registers that are really combinational (always_comb targets) are
included too (harmless: recomputed); X-propagation / power-up glitches are not modelled.  With the
datapath-local reset ON (D18, default) the FSM re-drains PD_DP on low-power exit, so retaining
nothing must still pass; the -DDP_RESET_DISABLE build needs retention (see test_pd.py t2).
"""
import random

import cocotb
from cocotb.handle import Force, Release
from cocotb.triggers import RisingEdge

DP_INST = ["u_tx_gate", "u_tx_cdc", "u_tx_framer", "u_tx_egress",
           "u_rx_ingress", "u_rx_deframer", "u_rx_cdc", "u_pcie_egress"]
# PD_DP outputs read by the always-on logic / the remote die (net in pcie_ucie3d_adapter) ->
# clamp value (lp/adapter.upf ISO_DP_1 / ISO_DP_0).  Clamp to 1 (datapath looks drained/idle):
# the Tx FIFO empty flag, the framer idle, the Rx ingress idle, the ingress-gate stopped flag.
# Clamp to 0: the UCIe-3D Tx bus (so the isolation-unaware remote-die model sees no garbage Tx
# from a corrupted-off datapath, as the UPF ISO would guarantee), egress busy, the four Rx
# counters.
WIDE_BITS = 64
ISO_NETS = {"tx_fifo_empty": 1, "framer_idle": 1, "rx_ing_idle": 1, "ingress_stopped_pcie": 1,
            "ucie_tx_valid": 0, "ucie_tx_data": 0, "ucie_tx_start_flit": 0,
            "egress_busy": 0, "rx_dropped_flits": 0, "rx_lock_errors": 0, "rx_bad_flits": 0,
            "rx_aborted_frames": 0}


def _regs(h, out, arrays):
    """Collect (handle, width) of every register below h; arrays (register memories) apart."""
    for c in h:
        t = c._type
        if t == "GPI_REGISTER":
            out.append((c, len(c)))
        elif t == "GPI_ARRAY":
            for i in range(len(c)):
                arrays.append((c[i], len(c[i])))
        elif t == "GPI_MODULE":
            _regs(c, out, arrays)


class PdEmu:
    def __init__(self, dut, retain=(), seed=1):
        self.dut = dut
        self.adapter = dut.dut                        # pd_top -> the adapter instance
        self.rng = random.Random(seed)
        self.retain = set(retain)                     # group names, e.g. "u_tx_cdc/mem"; "all" = every group
        self.groups = {}
        for inst in DP_INST:
            regs, mem = [], []
            _regs(getattr(self.adapter, inst), regs, mem)
            self.groups[inst + "/ctl"] = [r for r in regs if r[1] < WIDE_BITS]
            self.groups[inst + "/wide"] = [r for r in regs if r[1] >= WIDE_BITS]
            if mem:
                self.groups[inst + "/mem"] = mem
        self.iso = False                              # DP outputs on the DUT ports are clamped (models read this)
        self.off = False
        self.n_corrupt = 0
        self.snap = {}
        self.forced = False

    def retained(self, g):
        return "all" in self.retain or g in self.retain

    def _corrupt_all(self):
        for regs in self.groups.values():
            for h, w in regs:
                h.value = self.rng.getrandbits(w)
        self.n_corrupt += 1

    def _save(self):
        self.snap = {g: [int(h.value) if h.value.is_resolvable else 0 for h, _ in regs]
                     for g, regs in self.groups.items() if self.retained(g)}

    def _restore(self):
        for g, vals in self.snap.items():
            for (h, _), v in zip(self.groups[g], vals):
                h.value = v

    def _force(self):
        for n, v in ISO_NETS.items():
            getattr(self.adapter, n).value = Force(v)
        self.forced = True

    def _release(self):
        for n in ISO_NETS:
            getattr(self.adapter, n).value = Release()
        self.forced = False

    async def run(self):
        d = self.dut
        while True:
            await RisingEdge(d.ucie_clk)
            if not int(d.ucie_rst_n.value):
                if self.forced:
                    self._release()
                self.iso = self.off = False
                continue
            pwr, iso = int(d.dp_pwr_en.value), int(d.dp_iso_en.value)
            if int(d.dp_save.value):
                self._save()
            self.off = not pwr
            if self.off:
                self._corrupt_all()
            if int(d.dp_restore.value):
                self._restore()
            if iso and not self.forced:
                self._force()
            if not iso and self.forced:
                self._release()
            self.iso = bool(iso)
