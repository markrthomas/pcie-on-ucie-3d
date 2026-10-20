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
COV_FLOOR ?= 99

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

# M7 coverage vehicle: three --coverage runs whose coverage.dat files are merged
# into one coverage.info (lcov) and gated against COV_FLOOR over rtl/.  All built
# without the SVA bind (--assert + --coverage hits a Verilator 5.0xx V3Localize
# internal error on the checker's property body; the assertions run in scen/fc):
#   (1) sim_main +scen        — the clean Config-1 loopback datapath;
#   (2) cov_main              — the directed control-plane + Rx-error battery
#                               (dv/vlt/cov_main.cpp), mirroring tb_pm / tb_rxovf;
#   (3) sim_main +scen FC     — the FLOW_CTRL build, for the credit-flow lines.
# verilator_coverage emits one DA per source line, so merging across the default
# and FLOW_CTRL builds does not inflate the found count.
coverage:
	@mkdir -p logs
	$(VERILATOR) $(VFLAGS) $(VDEFS) --coverage --Mdir obj_dir_cov -o vlt_cov sim_main.cpp $(RTL_SRCS)
	cd obj_dir_cov && mkdir -p logs && ./vlt_cov +scen | tee ../logs/vlt_cov.log
	@grep -q "VLT PASS" logs/vlt_cov.log
	@cp -f obj_dir_cov/logs/results.json logs/results.json   # CI's coverage job is the vlt-scen producer: crosscheck + results-vlt upload read dv/vlt/logs/results.json
	$(VERILATOR) $(VFLAGS) $(VDEFS) --coverage --Mdir obj_dir_covb -o vlt_covb cov_main.cpp $(RTL_SRCS)
	cd obj_dir_covb && ./vlt_covb | tee ../logs/vlt_covb.log
	@grep -q "VLT COV PASS" logs/vlt_covb.log
	$(VERILATOR) $(VFLAGS) +define+FLOW_CTRL_OVERRIDE \
	  -CFLAGS "-I$(abspath $(COMMON)/cpp) -O1 -DFLOW_CTRL_OVERRIDE" \
	  --coverage --Mdir obj_dir_covfc -o vlt_covfc sim_main.cpp $(RTL_SRCS)
	cd obj_dir_covfc && mkdir -p logs && ./vlt_covfc +scen | tee ../logs/vlt_covfc.log
	@grep -q "VLT PASS" logs/vlt_covfc.log
	@test -f obj_dir_cov/coverage.dat -a -f obj_dir_covb/coverage.dat -a -f obj_dir_covfc/coverage.dat \
	  || { echo "coverage: a coverage.dat is missing"; exit 1; }
	$(VERILATOR_COV) --write-info coverage.info \
	  obj_dir_cov/coverage.dat obj_dir_covb/coverage.dat obj_dir_covfc/coverage.dat >/dev/null 2>&1 || true
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
	rm -rf obj_dir obj_dir_cov obj_dir_covb obj_dir_covfc logs coverage.dat coverage.info
