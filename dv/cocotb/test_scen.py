"""dv/cocotb — shared-scenario runner (DV env 5).

Runs the five cross-check scenarios (dv/common/scenarios.py) on the Config-1
loopback: Python BFMs model the PCIe AXI-S source/sink, the UCIe-3D Tx->Rx
loopback, the UCIe-3D Tx flit monitor, and the remote-die control model
(mirror of dv/common/ucie_sb_model.sv).  Writes results.json for crosscheck.py.
"""
import os
import sys
import zlib

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "common"))
import scenarios  # noqa: E402

# constants (mirror rtl/pcie_ucie3d_pkg.sv)
PWR_L0, PWR_L1, PWR_L2 = 0, 2, 3
SPEED_32, SPEED_64 = 5, 7
SB_WR, SB_WR_ACK = 0x1, 0x3
CSR_CTRL, CSR_STATUS, CSR_PMCNT = 0x00, 0x08, 0x18
PCIE_BYTES = 32
FLIT_PAYLOAD_B = 240


def pat(fid, idx):
    return (fid * 37 + idx * 13 + (idx >> 8) + 5) & 0xFF


class Sink:
    """PCIe AXI-S slave + in-order byte/length scoreboard + CRC."""

    def __init__(self, dut, ready_pct):
        self.dut = dut
        self.ready_pct = ready_pct
        self.rng = 0x1234_5678
        self.frames = 0
        self.rx_bytes = 0
        self.crc = 0
        self.errors = 0
        self.exp_len = lambda i: 0
        self.running = False
        self._buf = bytearray()

    def _rand(self):
        self.rng = (1103515245 * self.rng + 12345) & 0x7FFFFFFF
        return self.rng

    async def run(self):
        dut = self.dut
        while True:
            await RisingEdge(dut.pcie_clk)
            if not dut.pcie_rst_n.value:
                self._buf = bytearray()
                dut.pcie_rx_tready.value = 0
                continue
            rdy = int(dut.pcie_rx_tready.value)
            if rdy and int(dut.pcie_rx_tvalid.value):
                keep = int(dut.pcie_rx_tkeep.value)
                data = int(dut.pcie_rx_tdata.value)
                last = int(dut.pcie_rx_tlast.value)
                err = int(dut.pcie_rx_tuser.value) & 1
                nb = 0
                for i in range(PCIE_BYTES):
                    if (keep >> i) & 1:
                        self._buf.append((data >> (8 * i)) & 0xFF)
                        nb += 1
                if last:
                    if self.running:
                        self._finish(err)
                    self._buf = bytearray()
            dut.pcie_rx_tready.value = 1 if (self._rand() % 100) < self.ready_pct else 0

    def _finish(self, err):
        fid = self.frames
        buf = self._buf
        if err:
            self.errors += 1
        elif len(buf) != self.exp_len(fid):
            self.errors += 1
        else:
            for i, b in enumerate(buf):
                if b != pat(fid, i):
                    self.errors += 1
                    break
        self.crc = zlib.crc32(bytes(buf), self.crc)
        self.rx_bytes += len(buf)
        self.frames += 1


class FlitMon:
    """UCIe-3D Tx flit monitor: counts data flits (start_flit beats)."""

    def __init__(self, dut):
        self.dut = dut
        self.flits = 0

    async def run(self):
        dut = self.dut
        while True:
            await RisingEdge(dut.ucie_clk)
            if int(dut.ucie_tx_valid.value) and int(dut.ucie_tx_start_flit.value):
                self.flits += 1


async def loopback(dut):
    """UCIe-3D Tx bus looped back to the Rx bus (registered, 1 ucie_clk)."""
    while True:
        await RisingEdge(dut.ucie_clk)
        dut.ucie_rx_data.value = int(dut.ucie_tx_data.value)
        dut.ucie_rx_valid.value = int(dut.ucie_tx_valid.value)
        dut.ucie_rx_start_flit.value = int(dut.ucie_tx_start_flit.value)


class RemoteDie:
    """Remote-die control model — mirror of dv/common/ucie_sb_model.sv."""

    LAT = 8
    RST_CYCLES = 16
    SB_LAT = 8
    MB_LAT = 8

    def __init__(self, dut):
        self.dut = dut
        self.sb_writes = 0
        self.errors = 0

    async def run(self):
        dut = self.dut
        phase = rst_cnt = sb_cnt = mb_cnt = st_cnt = ack_cnt = sb_ph = sb_addr = 0
        pd_q, sp_q, wd_q = PWR_L1, SPEED_64, 0
        while True:
            await RisingEdge(dut.ucie_clk)
            if not dut.ucie_rst_n.value:
                dut.ucie_link_status.value = 1
                dut.ucie_rx_active.value = 0
                dut.ucie_rx_elec_idle.value = 1
                dut.ucie_sb_s2m.value = 0
                phase = rst_cnt = sb_cnt = mb_cnt = st_cnt = ack_cnt = sb_ph = sb_addr = 0
                pd_q, sp_q, wd_q = PWR_L1, SPEED_64, 0
                continue
            ls = 0
            s2m = 0
            if phase == 0:
                ls = 1
                if rst_cnt < self.RST_CYCLES:
                    rst_cnt += 1
                else:
                    ls = 0
                    phase = 1
                    sb_cnt = 0
            elif phase == 1:
                if sb_cnt < self.SB_LAT:
                    sb_cnt += 1
                else:
                    dut.ucie_rx_elec_idle.value = 0
                    phase = 2
                    mb_cnt = 0
            elif phase == 2:
                if mb_cnt < self.MB_LAT:
                    mb_cnt += 1
                else:
                    dut.ucie_rx_active.value = 1
                    phase = 3
            pd = int(dut.ucie_powerdown.value)
            sp = int(dut.ucie_speed.value)
            wd = int(dut.ucie_width.value)
            change = pd != pd_q or sp != sp_q or wd != wd_q
            if phase == 3:
                if change:
                    st_cnt = self.LAT
                elif st_cnt == 1:
                    st_cnt = 0
                    ls = 1
                elif st_cnt > 1:
                    st_cnt -= 1
            txv = int(dut.ucie_tx_valid.value)
            if txv and pd != PWR_L0:
                self.errors += 1
            if txv and (st_cnt != 0 or change):
                self.errors += 1
            pd_q, sp_q, wd_q = pd, sp, wd
            # sideband target (byte-serial write + ack)
            m2s = int(dut.ucie_sb_m2s.value) & 0xFF
            if sb_ph == 1:
                sb_addr = (sb_addr & 0xFF) | (m2s << 8)
                sb_ph = 2
            elif sb_ph == 2:
                sb_addr = (sb_addr & 0xFF00) | m2s
                sb_ph = 3
            elif sb_ph == 3:
                self.sb_writes += 1
                sb_ph = 0
                ack_cnt = self.LAT
            elif m2s != 0:
                if (m2s >> 4) & 0xF == SB_WR:
                    sb_ph = 1
                else:
                    self.errors += 1
            if ack_cnt == 1:
                ack_cnt = 0
                s2m = SB_WR_ACK << 4
            elif ack_cnt > 1:
                ack_cnt -= 1
            dut.ucie_link_status.value = ls
            dut.ucie_sb_s2m.value = s2m


async def csr_wr(dut, addr, data):
    await RisingEdge(dut.ucie_clk)
    dut.csr_valid.value = 1
    dut.csr_write.value = 1
    dut.csr_addr.value = addr
    dut.csr_wdata.value = data
    await RisingEdge(dut.ucie_clk)
    dut.csr_valid.value = 0
    dut.csr_write.value = 0


async def csr_rd(dut, addr):
    dut.csr_addr.value = addr
    await RisingEdge(dut.ucie_clk)
    await Timer(1, units="ns")
    return int(dut.csr_rdata.value)


def _next_rng(rng):
    rng[0] = (1103515245 * rng[0] + 12345) & 0x7FFFFFFF
    return rng[0]


async def send_frame(dut, fid, length, gap_pct, rng):
    off = 0
    while off < length:
        while gap_pct > 0 and _next_rng(rng) % 100 < gap_pct:
            dut.pcie_tvalid.value = 0
            await RisingEdge(dut.pcie_clk)
        n = min(length - off, PCIE_BYTES)
        data = 0
        keep = 0
        for i in range(n):
            data |= pat(fid, off + i) << (8 * i)
            keep |= 1 << i
        dut.pcie_tvalid.value = 1
        dut.pcie_tdata.value = data
        dut.pcie_tkeep.value = keep
        dut.pcie_tlast.value = 1 if off + n == length else 0
        await RisingEdge(dut.pcie_clk)
        while not int(dut.pcie_tready.value):
            await RisingEdge(dut.pcie_clk)
        off += n
    dut.pcie_tvalid.value = 0
    dut.pcie_tlast.value = 0


async def wait_rx(dut, sink, n):
    t = 0
    while sink.frames < n and t < 400000:
        await RisingEdge(dut.pcie_clk)
        t += 1


async def set_wait(dut, pd, sp, wd):
    await csr_wr(dut, CSR_CTRL, pd | (sp << 2) | (wd << 5))
    t = 0
    while t < 40000:
        d = await csr_rd(dut, CSR_STATUS)
        if (d & 3) == pd and ((d >> 2) & 7) == sp and ((d >> 5) & 3) == wd and not (d >> 11) & 1:
            return
        t += 1


async def do_reset(dut):
    dut.pcie_rst_n.value = 0
    dut.ucie_rst_n.value = 0
    for _ in range(10):
        await RisingEdge(dut.ucie_clk)
    dut.pcie_rst_n.value = 1
    dut.ucie_rst_n.value = 1


@cocotb.test()
async def scen(dut):
    cocotb.start_soon(Clock(dut.pcie_clk, 5, units="ns").start())
    cocotb.start_soon(Clock(dut.ucie_clk, 2, units="ns").start())
    for sig, v in [("pcie_tvalid", 0), ("pcie_tlast", 0), ("pcie_tkeep", 0), ("pcie_tuser", 0),
                   ("pcie_tdata", 0), ("pcie_rx_tready", 0), ("ucie_rx_valid", 0),
                   ("ucie_rx_start_flit", 0), ("ucie_rx_data", 0), ("csr_valid", 0),
                   ("csr_write", 0), ("csr_addr", 0), ("csr_wdata", 0)]:
        getattr(dut, sig).value = v

    sink = Sink(dut, ready_pct=90)
    mon = FlitMon(dut)
    die = RemoteDie(dut)
    cocotb.start_soon(loopback(dut))
    cocotb.start_soon(die.run())
    cocotb.start_soon(sink.run())
    cocotb.start_soon(mon.run())

    gap = [0x0BADF00D]
    results = {}
    tot_err = 0
    for name in scenarios.ORDER:
        lens = scenarios.lengths(name)
        ctrl = scenarios.SCENARIOS[name][1]
        nfr = len(lens)
        sink.exp_len = lambda i, L=lens: L[i] if i < len(L) else -1
        await do_reset(dut)
        while True:
            await RisingEdge(dut.ucie_clk)
            d = await csr_rd(dut, CSR_STATUS)
            if (d >> 12) & 1:
                break
        sink.frames = 0
        sink.rx_bytes = 0
        sink.crc = 0
        sink.errors = 0
        base_flits = mon.flits
        sink.running = True

        if ctrl == "none":
            for i in range(nfr):
                await send_frame(dut, i, lens[i], 10, gap)
        else:
            for i in range(nfr // 2):
                await send_frame(dut, i, lens[i], 10, gap)
            await wait_rx(dut, sink, nfr // 2)
            if ctrl == "pm_cycle":
                await set_wait(dut, PWR_L1, SPEED_64, 0)
                for _ in range(200):
                    await RisingEdge(dut.ucie_clk)
                await set_wait(dut, PWR_L0, SPEED_64, 0)
            else:  # speed_change
                await set_wait(dut, PWR_L0, SPEED_32, 0)
                for _ in range(200):
                    await RisingEdge(dut.ucie_clk)
                await set_wait(dut, PWR_L0, SPEED_64, 0)
            for i in range(nfr // 2, nfr):
                await send_frame(dut, i, lens[i], 10, gap)

        await wait_rx(dut, sink, nfr)
        for _ in range(400):
            await RisingEdge(dut.pcie_clk)
        sink.running = False
        pmcnt = await csr_rd(dut, CSR_PMCNT) & 0xFFFF
        errors = sink.errors + die.errors
        tot_err += errors
        crc = sink.crc & 0xFFFFFFFF   # zlib.crc32 applies init/final (matches scenarios.py)
        results[name] = {
            "frames": sink.frames, "bytes": sink.rx_bytes, "flits": mon.flits - base_flits,
            "crc32": f"{crc:08x}", "pmcnt": pmcnt, "errors": errors,
        }
        dut._log.info("SCEN %-12s frames=%d bytes=%d flits=%d crc32=%08x pmcnt=%d errors=%d" % (
            name, sink.frames, sink.rx_bytes, mon.flits - base_flits, crc, pmcnt, errors))

    import json
    with open("results.json", "w") as f:
        json.dump({"env": "cocotb", "scenarios": results}, f)
    assert tot_err == 0, f"COCOTB SCEN FAIL: {tot_err} error(s)"
    dut._log.info("COCOTB SCEN PASS: 5 scenarios, results in results.json")
