# dv/uvm — Accellera UVM on Verilator (DV env 3).
# M0: smoke_test (reset/defaults).  Needs a UVM-capable Verilator (>= 5.03x; the
# from-source 5.050 in the CI image — apt 5.020 cannot compile uvm-core).  Do NOT
# set VERILATOR_ROOT.  uvm-core is git-cloned at a pinned ref (git-ignored).
VERILATOR ?= verilator
RTL_DIR   := ../../rtl
TOP       := tb_uvm_top
RTL_SRCS  := $(RTL_DIR)/pcie_ucie3d_adapter.sv

UVM_REPO := https://github.com/accellera-official/uvm-core
UVM_REF  := 78c06547a2a0a29b3dc9dcafae62b75b2ff61544
UVM_DIR  := uvm-core

VFLAGS := --binary --timing -Wall -Wno-fatal --top-module $(TOP) \
          +define+UVM_NO_DPI -I$(RTL_DIR) -I$(UVM_DIR)/src $(UVM_DIR)/src/uvm_pkg.sv

.PHONY: smoke fc uvm-core clean

uvm-core:
	@if [ ! -d $(UVM_DIR) ]; then \
	  echo "cloning uvm-core @ $(UVM_REF)"; \
	  git clone -q $(UVM_REPO) $(UVM_DIR) && git -C $(UVM_DIR) checkout -q $(UVM_REF) || \
	  { echo "[uvm] clone failed (no network?); uvm-core is cloned in the CI image. Skipping."; rm -rf $(UVM_DIR); } ; \
	fi

smoke: uvm-core
	@if [ ! -d $(UVM_DIR) ]; then echo "[uvm] uvm-core unavailable; skipping local run (runs in the CI image)"; exit 0; fi
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir -o uvm_smoke \
	  $(RTL_DIR)/pcie_ucie3d_pkg.sv adapter_if.sv adapter_uvm_pkg.sv tb_uvm_top.sv $(RTL_SRCS) 2>&1 | tee build.log
	./obj_dir/uvm_smoke +UVM_TESTNAME=smoke_test 2>&1 | tee run.log
	@grep -q "UVM SMOKE PASS" run.log

fc:
	@echo "[uvm fc] flow-control scenario run lands in M4 (docs/PLAN.md §11)"

clean:
	rm -rf obj_dir build.log run.log
