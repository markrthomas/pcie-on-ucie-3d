# lp/cocotb — UPF-like power-state emulation of PD_DP with cocotb on Icarus (no power tool):
# the PMU (lp/adapter_pmu.sv) sequences power-down/up; lp/cocotb/pd_emu.py corrupts PD_DP state
# while "off", clamps the PD_DP outputs the always-on logic reads while isolated, and
# saves/restores the retained state.  `make -C lp/cocotb pd` runs the matrix and writes
# pd_results.json.  Same tool gotchas as dv/cocotb (apt Icarus; cocotb python3 first on PATH).
SIM             ?= icarus
TOPLEVEL_LANG   ?= verilog
# Needs Icarus >= 12 on PATH (ICARUS_BIN_DIR to pin a specific install).
ifneq ($(ICARUS_BIN_DIR),)
export PATH := $(ICARUS_BIN_DIR):$(PATH)
endif
RTL_DIR         := $(abspath ../../rtl)
LP_DIR          := $(abspath ..)
COMMON          := $(abspath ../../dv/common)
VERILOG_SOURCES := $(RTL_DIR)/async_fifo.sv $(RTL_DIR)/tx_ingress_gate.sv $(RTL_DIR)/tx_framer.sv \
                   $(RTL_DIR)/tx_egress.sv $(RTL_DIR)/rx_ingress.sv $(RTL_DIR)/rx_deframer.sv \
                   $(RTL_DIR)/pcie_egress.sv $(RTL_DIR)/ucie_sb_master.sv $(RTL_DIR)/fc_ctl.sv \
                   $(RTL_DIR)/adapter_ctrl_fsm.sv $(RTL_DIR)/adapter_rf.sv \
                   $(RTL_DIR)/pcie_ucie3d_adapter.sv $(COMMON)/ucie_sb_model.sv \
                   $(LP_DIR)/adapter_pmu.sv $(abspath pd_top.sv)
TOPLEVEL        := pd_top
MODULE          ?= test_pd
COMPILE_ARGS    += -g2012 -I $(RTL_DIR) -I $(COMMON)
export PYTHONPATH := $(abspath .):$(COMMON):$(PYTHONPATH)
COCOTB_SCRIPTS := $(shell python3 -c "import cocotb,os,sys,shutil;print(os.path.dirname(shutil.which('cocotb-config',path=os.path.dirname(sys.executable)+os.pathsep+os.environ['PATH'])))")
export PATH := $(COCOTB_SCRIPTS):$(PATH)

.PHONY: pd pd-ret
# default build (datapath-local reset ON, D18): retaining NOTHING must pass
pd:
	rm -f results.xml pd_results.json
	$(MAKE) sim PD_DP_RESET=1 PD_RESULTS=$(abspath pd_results.json)
	python3 check_pd.py results.xml pd_results.json

# -DDP_RESET_DISABLE build (pre-D18 behaviour, state survives L1/L2): retention is REQUIRED -
# retain-nothing is the negative control (must fail) and the greedy minimal retained set is written
# to retention_min.txt
pd-ret:
	rm -rf results_ret.xml pd_results_ret.json
	$(MAKE) sim SIM_BUILD=sim_build_ret COMPILE_ARGS="-g2012 -I $(RTL_DIR) -I $(COMMON) -DDP_RESET_DISABLE" \
	  COCOTB_RESULTS_FILE=results_ret.xml PD_DP_RESET=0 PD_RESULTS=$(abspath pd_results_ret.json)
	python3 check_pd.py results_ret.xml pd_results_ret.json

include $(shell python3 -m cocotb.config --makefiles)/Makefile.sim

clean::
	rm -rf sim_build sim_build_ret __pycache__ results.xml pd_results.json results_ret.xml pd_results_ret.json
