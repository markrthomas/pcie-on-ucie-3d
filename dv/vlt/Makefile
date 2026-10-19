# dv/vlt — Verilator C++ environment (DV env 2) + the coverage vehicle.
# M0: smoke (reset/defaults).  coverage builds with --coverage and reports the
# line number (the 80% floor is enforced from M4, once the datapath exists).
# M1+ runs the shared scenarios on the Config-1 loopback -> logs/results.json.
VERILATOR ?= verilator
VERILATOR_COV ?= verilator_coverage
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
CFLAGS_INC := -CFLAGS "-I$(abspath $(COMMON)/cpp) -O1"
VFLAGS    := --cc --exe --build -j 0 -Wall -Wno-fatal --top-module $(TOP) -I$(RTL_DIR) $(CFLAGS_INC)
VDEFS     ?=
COV_FLOOR ?= 80

.PHONY: smoke scen coverage fc stress clean

smoke:
	$(VERILATOR) $(VFLAGS) $(SVA_FLAGS) $(VDEFS) --Mdir obj_dir -o vlt_smoke sim_main.cpp $(RTL_SRCS) $(SVA_SRCS)
	./obj_dir/vlt_smoke

# M4 shared scenario set -> logs/results.json -> crosscheck
scen:
	@mkdir -p logs
	$(VERILATOR) $(VFLAGS) $(SVA_FLAGS) $(VDEFS) --Mdir obj_dir -o vlt_scen sim_main.cpp $(RTL_SRCS) $(SVA_SRCS)
	./obj_dir/vlt_scen +scen | tee logs/vlt.log
	@grep -q "VLT PASS" logs/vlt.log
	python3 $(COMMON)/crosscheck.py --require vlt logs/results.json

# M4 coverage vehicle: the scenario run under --coverage -> coverage.info (lcov);
# line coverage over rtl/ is enforced against COV_FLOOR.  Built without the SVA
# bind (--assert + --coverage hits a Verilator 5.0xx V3Localize internal error on
# the checker's property body); the assertions are exercised in `scen`/`fc`.
coverage:
	@mkdir -p logs
	$(VERILATOR) $(VFLAGS) $(VDEFS) --coverage --Mdir obj_dir_cov -o vlt_cov sim_main.cpp $(RTL_SRCS)
	./obj_dir_cov/vlt_cov +scen | tee logs/vlt_cov.log
	@test -f coverage.dat || { echo "coverage: no coverage.dat produced"; exit 1; }
	$(VERILATOR_COV) --write-info coverage.info coverage.dat >/dev/null 2>&1 || true
	@cp -f coverage.info ../../coverage.info 2>/dev/null || true
	@python3 ../common/covcheck.py coverage.info $(COV_FLOOR)

# link flow control ON: rebuild with the define reaching BOTH the RTL (+define+)
# and the C++ harness (-D) so the flit monitor expects credit-only flits.
fc:
	$(MAKE) scen VDEFS=+define+FLOW_CTRL_OVERRIDE \
	  CFLAGS_INC='-CFLAGS "-I$(abspath $(COMMON)/cpp) -O1 -DFLOW_CTRL_OVERRIDE"'

stress:
	@echo "[vlt stress] multi-seed scenario run lands in M7 (docs/PLAN.md §11)"

clean:
	rm -rf obj_dir obj_dir_cov logs coverage.dat coverage.info
