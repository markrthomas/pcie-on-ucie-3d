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
                   $(RTL_DIR)/adapter_rf.sv $(RTL_DIR)/adapter_ctrl_fsm.sv $(RTL_DIR)/ucie_sb_master.sv $(RTL_DIR)/tx_ingress_gate.sv \
                   $(RTL_DIR)/pcie_ucie3d_adapter.sv
COMPILE_ARGS    += -g2012 -I $(RTL_DIR)

ifneq ($(ICARUS_BIN_DIR),)
export PATH := $(ICARUS_BIN_DIR):$(PATH)
endif

.PHONY: smoke fc
smoke: sim
fc:
	@echo "[cocotb fc] flow-control scenario run lands in M4 (docs/PLAN.md §11)"

include $(shell cocotb-config --makefiles)/Makefile.sim
