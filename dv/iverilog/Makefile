# dv/iverilog — directed Icarus Verilog environment (DV env 1).
# M0: smoke (reset/defaults contract, tb_smoke.sv).  M1+ adds tx / loop / pm /
# rxovf / scen (shared scenarios) and the C2/C3 back-to-back tops.
IVERILOG ?= iverilog
VVP      ?= vvp
RTL_DIR  := ../../rtl
COMMON   := ../common
# DV BFMs shared by the directed tests (source, flit monitor, sink, remote-die control).
BFMS     := $(COMMON)/pcie_mac_model.sv $(COMMON)/ucie_phy_model.sv \
            $(COMMON)/pcie_sink_model.sv $(COMMON)/ucie_sb_model.sv
RTL_SRCS := $(RTL_DIR)/async_fifo.sv $(RTL_DIR)/tx_framer.sv $(RTL_DIR)/tx_egress.sv \
            $(RTL_DIR)/rx_ingress.sv $(RTL_DIR)/rx_deframer.sv $(RTL_DIR)/pcie_egress.sv \
            $(RTL_DIR)/fc_ctl.sv $(RTL_DIR)/adapter_rf.sv $(RTL_DIR)/adapter_ctrl_fsm.sv $(RTL_DIR)/ucie_sb_master.sv $(RTL_DIR)/tx_ingress_gate.sv \
            $(RTL_DIR)/pcie_ucie3d_adapter.sv
BUILD    := sim_build
# The RTL / TBs need Icarus >= 12 (CI uses 12.0).  Fail early with a readable
# message; IVERILOG_MIN_MAJOR=0 skips the check.
IVERILOG_MIN_MAJOR ?= 12
IV_MAJOR := $(shell $(IVERILOG) -V 2>&1 | sed -n '1s/.*version \([0-9][0-9]*\)\..*/\1/p')
ifneq ($(filter-out clean,$(MAKECMDGOALS)),)
ifneq ($(IVERILOG_MIN_MAJOR),0)
ifeq ($(shell [ "$(or $(IV_MAJOR),0)" -ge $(IVERILOG_MIN_MAJOR) ] && echo ok),)
$(error iverilog >= $(IVERILOG_MIN_MAJOR) required, found "$(or $(IV_MAJOR),none / not runnable)" ($(shell command -v $(IVERILOG))); install Icarus 12 (apt iverilog on Ubuntu 24.04, or build from source))
endif
endif
endif
IVEXTRA ?=

.PHONY: smoke tx loop pm rxovf scen pcie_b2b ucie_b2b clean
# M3 smoke: reset/defaults + link-up (needs the remote-die control model)
smoke:
	@mkdir -p $(BUILD)
	$(IVERILOG) -g2012 $(IVEXTRA) -I $(RTL_DIR) -I $(COMMON) -o $(BUILD)/smoke.vvp tb_smoke.sv \
	  $(COMMON)/ucie_sb_model.sv $(RTL_SRCS)
	$(VVP) $(BUILD)/smoke.vvp | tee $(BUILD)/smoke.log
	@grep -q "SMOKE PASS" $(BUILD)/smoke.log

# M1 directed Tx test: PCIe frames -> UCIe-3D raw flits (pcie_mac_model source, ucie_phy_model sink)
tx:
	@mkdir -p $(BUILD)
	$(IVERILOG) -g2012 $(IVEXTRA) -I $(RTL_DIR) -I $(COMMON) -o $(BUILD)/tx.vvp tb_tx.sv $(BFMS) $(RTL_SRCS)
	$(VVP) $(BUILD)/tx.vvp | tee $(BUILD)/tx.log
	@grep -q "TX PASS" $(BUILD)/tx.log

# M2 Config-1 loopback: PCIe -> adapter Tx -> UCIe (looped) -> adapter Rx -> PCIe
loop:
	@mkdir -p $(BUILD)
	$(IVERILOG) -g2012 $(IVEXTRA) -I $(RTL_DIR) -I $(COMMON) -o $(BUILD)/loop.vvp tb_loop.sv $(BFMS) $(RTL_SRCS)
	$(VVP) $(BUILD)/loop.vvp | tee $(BUILD)/loop.log
	@grep -q "LOOP PASS" $(BUILD)/loop.log

# M3 control-plane test: power / speed / width / preset changes under live loopback traffic
pm:
	@mkdir -p $(BUILD)
	$(IVERILOG) -g2012 $(IVEXTRA) -I $(RTL_DIR) -I $(COMMON) -o $(BUILD)/pm.vvp tb_pm.sv $(BFMS) $(RTL_SRCS)
	$(VVP) $(BUILD)/pm.vvp | tee $(BUILD)/pm.log
	@grep -q "PM PASS" $(BUILD)/pm.log

# M3 Rx overload policy: no-backpressure drop/abort + recovery (D9)
rxovf:
	@mkdir -p $(BUILD)
	$(IVERILOG) -g2012 $(IVEXTRA) -I $(RTL_DIR) -I $(COMMON) -o $(BUILD)/rxovf.vvp tb_rxovf.sv $(BFMS) $(RTL_SRCS)
	$(VVP) $(BUILD)/rxovf.vvp | tee $(BUILD)/rxovf.log
	@grep -q "RXOVF PASS" $(BUILD)/rxovf.log

# M4 Config-2: PCIe back-to-back (PCIe FLIT layer / BFM baseline, no adapter)
pcie_b2b:
	@mkdir -p $(BUILD)
	$(IVERILOG) -g2012 $(IVEXTRA) -I $(RTL_DIR) -I $(COMMON) -o $(BUILD)/pcie_b2b.vvp tb_pcie_b2b.sv \
	  $(COMMON)/pcie_mac_model.sv $(COMMON)/pcie_sink_model.sv
	$(VVP) $(BUILD)/pcie_b2b.vvp | tee $(BUILD)/pcie_b2b.log
	@grep -q "PCIE_B2B PASS" $(BUILD)/pcie_b2b.log

# M4 Config-3: UCIe-3D back-to-back (two adapters joined at the bump interface)
ucie_b2b:
	@mkdir -p $(BUILD)
	$(IVERILOG) -g2012 $(IVEXTRA) -I $(RTL_DIR) -I $(COMMON) -o $(BUILD)/ucie_b2b.vvp tb_ucie_b2b.sv $(BFMS) $(RTL_SRCS)
	$(VVP) $(BUILD)/ucie_b2b.vvp | tee $(BUILD)/ucie_b2b.log
	@grep -q "UCIE_B2B PASS" $(BUILD)/ucie_b2b.log

# M4 shared scenario set (dv/common/scenarios.py): 5 scenarios -> results.json
scen:
	@mkdir -p $(BUILD)
	$(IVERILOG) -g2012 $(IVEXTRA) -I $(RTL_DIR) -I $(COMMON) -o $(BUILD)/scen.vvp tb_scen.sv $(BFMS) $(RTL_SRCS)
	$(VVP) $(BUILD)/scen.vvp | tee $(BUILD)/scen.log
	@grep -q "SCEN PASS" $(BUILD)/scen.log
	python3 $(COMMON)/crosscheck.py --require iverilog $(BUILD)/results.json

clean:
	rm -rf $(BUILD)
