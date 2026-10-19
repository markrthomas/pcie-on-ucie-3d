# dv/cocotb — cocotb + PyUVM + PyVSC environment (DV env 5).
# M0: smoke (reset/defaults, test_adapter.py) on Icarus.  M1+ adds the PyUVM
# Config-1 loopback env + shared scenarios + PyVSC fcov -> results.json / fcov.json.
# Needs Icarus >= 12 on PATH (ICARUS_BIN_DIR to pin a specific install).
SIM           ?= icarus
TOPLEVEL_LANG ?= verilog
RTL_DIR       := ../../rtl
TOPLEVEL      := pcie_ucie3d_adapter
MODULE        := test_adapter

VERILOG_SOURCES := $(RTL_DIR)/async_fifo.sv $(RTL_DIR)/tx_framer.sv $(RTL_DIR)/tx_egress.sv \
                   $(RTL_DIR)/rx_ingress.sv $(RTL_DIR)/rx_deframer.sv $(RTL_DIR)/pcie_egress.sv \
                   $(RTL_DIR)/fc_ctl.sv $(RTL_DIR)/adapter_rf.sv $(RTL_DIR)/adapter_ctrl_fsm.sv $(RTL_DIR)/ucie_sb_master.sv $(RTL_DIR)/tx_ingress_gate.sv \
                   $(RTL_DIR)/pcie_ucie3d_adapter.sv
COMPILE_ARGS    += -g2012 -I $(RTL_DIR)

ifneq ($(ICARUS_BIN_DIR),)
export PATH := $(ICARUS_BIN_DIR):$(PATH)
endif

COMMON := ../common

.PHONY: smoke scen fc
smoke: sim

# M4 shared scenario set -> results.json -> crosscheck.  X resolves to 0 (the
# loopback/BFMs sample 2-state nets, matching the Verilator envs).
scen:
	COCOTB_RESOLVE_X=ZEROS $(MAKE) sim MODULE=test_scen
	python3 $(COMMON)/crosscheck.py --require cocotb results.json

fc:
	@echo "[cocotb fc] flow-control scenario run uses the SV envs in M4 (cocotb FC in M7)"

include $(shell cocotb-config --makefiles)/Makefile.sim
