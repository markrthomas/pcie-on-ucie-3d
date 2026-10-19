# dv/uvm — Accellera UVM on Verilator (DV env 3).
# M0: smoke_test (reset/defaults).  Needs a UVM-capable Verilator (>= 5.03x; the
# from-source 5.050 in the CI image — apt 5.020 cannot compile uvm-core).  Do NOT
# set VERILATOR_ROOT.  uvm-core is git-cloned at a pinned ref (git-ignored).
VERILATOR ?= verilator
RTL_DIR   := ../../rtl
COMMON    := ../common
TOP       := tb_uvm_top
RTL_SRCS  := $(RTL_DIR)/async_fifo.sv $(RTL_DIR)/tx_framer.sv $(RTL_DIR)/tx_egress.sv \
             $(RTL_DIR)/rx_ingress.sv $(RTL_DIR)/rx_deframer.sv $(RTL_DIR)/pcie_egress.sv \
             $(RTL_DIR)/fc_ctl.sv $(RTL_DIR)/adapter_rf.sv $(RTL_DIR)/adapter_ctrl_fsm.sv $(RTL_DIR)/ucie_sb_master.sv $(RTL_DIR)/tx_ingress_gate.sv \
             $(RTL_DIR)/pcie_ucie3d_adapter.sv

UVM_REPO := https://github.com/accellera-official/uvm-core
UVM_REF  := 78c06547a2a0a29b3dc9dcafae62b75b2ff61544
UVM_DIR  := uvm-core

VDEFS  ?=
# bind-based SVA (dv/sva): on by default; SVA=0 builds without it
SVA      ?= 1
SVA_SRCS := $(if $(filter 1,$(SVA)),../sva/async_fifo_sva.sv ../sva/adapter_sva.sv)
VFLAGS := --binary --timing -Wall -Wno-fatal --top-module $(TOP) \
          +define+UVM_NO_DPI $(if $(filter 1,$(SVA)),--assert) -I$(RTL_DIR) -I$(COMMON) -I$(UVM_DIR)/src $(VDEFS) $(UVM_DIR)/src/uvm_pkg.sv

.PHONY: smoke scen fc uvm-core clean

uvm-core:
	@if [ ! -d $(UVM_DIR) ]; then \
	  echo "cloning uvm-core @ $(UVM_REF)"; \
	  git clone -q $(UVM_REPO) $(UVM_DIR) && git -C $(UVM_DIR) checkout -q $(UVM_REF) || \
	  { echo "[uvm] clone failed (no network?); uvm-core is cloned in the CI image. Skipping."; rm -rf $(UVM_DIR); } ; \
	fi

smoke: uvm-core
	@if [ ! -d $(UVM_DIR) ]; then echo "[uvm] uvm-core unavailable; skipping local run (runs in the CI image)"; exit 0; fi
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir -o uvm_smoke \
	  $(RTL_DIR)/pcie_ucie3d_pkg.sv adapter_if.sv adapter_uvm_pkg.sv tb_uvm_top.sv $(RTL_SRCS) $(SVA_SRCS) 2>&1 | tee build.log
	./obj_dir/uvm_smoke +UVM_TESTNAME=smoke_test 2>&1 | tee run.log
	@grep -q "UVM SMOKE PASS" run.log

# M4 shared scenario set -> logs/results.json -> crosscheck
scen: uvm-core
	@if [ ! -d $(UVM_DIR) ]; then echo "[uvm] uvm-core unavailable; skipping local run (runs in the CI image)"; exit 0; fi
	@mkdir -p logs
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir_scen -o uvm_scen \
	  $(RTL_DIR)/pcie_ucie3d_pkg.sv adapter_if.sv adapter_uvm_pkg.sv tb_uvm_top.sv $(RTL_SRCS) $(SVA_SRCS) 2>&1 | tee build.log
	./obj_dir_scen/uvm_scen +UVM_TESTNAME=scen_test 2>&1 | tee run.log
	@grep -q "UVM SCEN PASS" run.log
	python3 $(COMMON)/crosscheck.py --require uvm logs/results.json

fc:
	$(MAKE) scen VDEFS=+define+FLOW_CTRL_OVERRIDE

clean:
	rm -rf obj_dir obj_dir_scen build.log run.log logs
