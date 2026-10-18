"""dv/cocotb — cocotb smoke (DV env 5).

M0: reset the stub DUT and check the reset/defaults contract.  M1+ adds the
PyUVM Config-1 loopback env (bridge_env.py), the shared scenarios (scenarios.py)
and PyVSC functional coverage (fcov.json), writing results.json.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

PWR_L1 = 2
SPEED_64 = 7


@cocotb.test()
async def smoke(dut):
    cocotb.start_soon(Clock(dut.pcie_clk, 5, units="ns").start())
    cocotb.start_soon(Clock(dut.ucie_clk, 2, units="ns").start())

    # tie off inputs
    for sig, val in [("pcie_tvalid", 0), ("pcie_tlast", 0), ("pcie_rx_tready", 1),
                     ("ucie_rx_valid", 0), ("ucie_rx_start_flit", 0),
                     ("ucie_link_status", 0), ("ucie_rx_active", 0), ("ucie_rx_elec_idle", 1),
                     ("ucie_sb_s2m", 0), ("csr_valid", 0), ("csr_write", 0), ("csr_addr", 0)]:
        getattr(dut, sig).value = val

    dut.pcie_rst_n.value = 0
    dut.ucie_rst_n.value = 0
    for _ in range(10):
        await RisingEdge(dut.ucie_clk)
    dut.pcie_rst_n.value = 1
    dut.ucie_rst_n.value = 1
    for _ in range(5):
        await RisingEdge(dut.ucie_clk)
    await Timer(1, units="ns")

    errors = []

    def chk(cond, msg):
        if not cond:
            errors.append(msg)

    chk(int(dut.ucie_powerdown.value) == PWR_L1, "powerdown should be L1 out of reset")
    chk(int(dut.ucie_speed.value) == SPEED_64, "speed should be SPEED_64")
    chk(int(dut.ucie_tx_valid.value) == 0, "no Tx traffic out of reset")
    chk(int(dut.pcie_tready.value) == 0, "PCIe ingress closed before link-up")

    # CSR_CTRL reset value
    dut.csr_addr.value = 0x00
    await Timer(1, units="ns")
    chk(int(dut.csr_rdata.value) == ((SPEED_64 << 2) | 0), "CTRL reset value")

    assert not errors, "COCOTB SMOKE FAIL: " + "; ".join(errors)
    dut._log.info("COCOTB SMOKE PASS: reset defaults OK")
