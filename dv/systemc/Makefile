# dv/systemc — Verilator -> SystemC environment (DV env 4).
# M0: smoke (reset/defaults).  Needs SystemC 2.3.x (apt libsystemc-dev, or the
# CI image); SYSTEMC_INCLUDE / SYSTEMC_LIBDIR override the install location.
VERILATOR ?= verilator
RTL_DIR   := ../../rtl
COMMON    := ../common
TOP       := pcie_ucie3d_adapter
RTL_SRCS  := $(RTL_DIR)/async_fifo.sv $(RTL_DIR)/tx_framer.sv $(RTL_DIR)/tx_egress.sv \
             $(RTL_DIR)/rx_ingress.sv $(RTL_DIR)/rx_deframer.sv $(RTL_DIR)/pcie_egress.sv \
             $(RTL_DIR)/fc_ctl.sv $(RTL_DIR)/adapter_rf.sv $(RTL_DIR)/adapter_ctrl_fsm.sv $(RTL_DIR)/ucie_sb_master.sv $(RTL_DIR)/tx_ingress_gate.sv \
             $(RTL_DIR)/$(TOP).sv
# bind-based SVA (dv/sva): on by default; SVA=0 builds without it
SVA       ?= 1
SVA_SRCS  := $(if $(filter 1,$(SVA)),../sva/async_fifo_sva.sv ../sva/adapter_sva.sv)
SVA_FLAGS := $(if $(filter 1,$(SVA)),--assert)
CFLAGS_INC := -CFLAGS "-I$(abspath $(COMMON)/cpp)"
VFLAGS    := --sc --exe --build -j 0 -Wall -Wno-fatal --top-module $(TOP) -I$(RTL_DIR) $(CFLAGS_INC) $(SVA_FLAGS)
VDEFS     ?=

SYSTEMC_INCLUDE ?= /usr/include
SYSTEMC_LIBDIR  ?= /usr/lib/x86_64-linux-gnu

.PHONY: smoke scen fc clean

smoke:
	@if [ ! -f $(SYSTEMC_INCLUDE)/systemc.h ]; then \
	  echo "[systemc] SystemC not found at $(SYSTEMC_INCLUDE); install libsystemc-dev (or use the CI image)"; exit 0; fi
	SYSTEMC_INCLUDE=$(SYSTEMC_INCLUDE) SYSTEMC_LIBDIR=$(SYSTEMC_LIBDIR) \
	  $(VERILATOR) $(VFLAGS) $(VDEFS) --Mdir obj_dir -o sc_smoke sc_main.cpp $(RTL_SRCS) $(SVA_SRCS)
	LD_LIBRARY_PATH=$(SYSTEMC_LIBDIR):$$LD_LIBRARY_PATH ./obj_dir/sc_smoke

# M4 shared scenario set -> logs/results.json -> crosscheck
scen:
	@if [ ! -f $(SYSTEMC_INCLUDE)/systemc.h ]; then \
	  echo "[systemc] SystemC not found at $(SYSTEMC_INCLUDE); install libsystemc-dev (or use the CI image)"; exit 0; fi
	@mkdir -p logs
	SYSTEMC_INCLUDE=$(SYSTEMC_INCLUDE) SYSTEMC_LIBDIR=$(SYSTEMC_LIBDIR) \
	  $(VERILATOR) $(VFLAGS) $(VDEFS) --Mdir obj_dir_scen -o sc_scen sc_main.cpp $(RTL_SRCS) $(SVA_SRCS)
	LD_LIBRARY_PATH=$(SYSTEMC_LIBDIR):$$LD_LIBRARY_PATH ./obj_dir_scen/sc_scen +scen | tee logs/systemc.log
	@grep -q "SYSTEMC PASS" logs/systemc.log
	python3 $(COMMON)/crosscheck.py --require systemc logs/results.json

fc:
	$(MAKE) scen VDEFS=+define+FLOW_CTRL_OVERRIDE \
	  CFLAGS_INC='-CFLAGS "-I$(abspath $(COMMON)/cpp) -DFLOW_CTRL_OVERRIDE"'

clean:
	rm -rf obj_dir obj_dir_scen logs
