# dv/vlt — Verilator C++ environment (DV env 2) + the coverage vehicle.
# M0: smoke (reset/defaults).  coverage builds with --coverage and reports the
# line number (the 80% floor is enforced from M4, once the datapath exists).
# M1+ runs the shared scenarios on the Config-1 loopback -> logs/results.json.
VERILATOR ?= verilator
RTL_DIR   := ../../rtl
TOP       := pcie_ucie3d_adapter
RTL_SRCS  := $(RTL_DIR)/async_fifo.sv $(RTL_DIR)/tx_framer.sv $(RTL_DIR)/tx_egress.sv \
             $(RTL_DIR)/$(TOP).sv
VFLAGS    := --cc --exe --build -j 0 -Wall -Wno-fatal --top-module $(TOP) -I$(RTL_DIR)
COV_FLOOR ?= 80

.PHONY: smoke coverage fc stress clean

smoke:
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir -o vlt_smoke sim_main.cpp $(RTL_SRCS)
	./obj_dir/vlt_smoke

coverage:
	$(VERILATOR) $(VFLAGS) --coverage --Mdir obj_dir_cov -o vlt_cov sim_main.cpp $(RTL_SRCS)
	./obj_dir_cov/vlt_cov
	@if [ -f coverage.dat ]; then \
	  verilator_coverage --write-info coverage.info coverage.dat >/dev/null 2>&1 || true; \
	  echo "coverage: wrote coverage.info (floor $(COV_FLOOR)% enforced from M4 — stub DUT, see docs/PLAN.md §6)"; \
	else echo "coverage: no coverage.dat produced (M0 stub)"; fi

# link flow control ON (M4+)
fc:
	@echo "[vlt fc] flow-control scenario run lands in M4 (docs/PLAN.md §11)"

stress:
	@echo "[vlt stress] multi-seed scenario run lands in M4 (docs/PLAN.md §11)"

clean:
	rm -rf obj_dir obj_dir_cov logs coverage.dat coverage.info
