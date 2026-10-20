# =============================================================================
# pcie-on-ucie-3d — root DV gate.
#
# Standard targets per ~/proj/DV_STANDARDS.md.  Toolchain: Verilator + Icarus +
# Yosys(+slang)/SBY/yices, built from source or from apt/pip — NO OSS CAD Suite.
# The Dockerfile pins the versions and CI runs the jobs in that image.  Do NOT
# set VERILATOR_ROOT (breaks the UVM-on-Verilator flow).
#
# STATUS: M0 scaffold — `lint` and `sim` (Icarus smoke) are real and green; the
# other envs ship a smoke `make <env>`; coverage/formal/upf keep their target and
# print an "authored, not run" / "stub" notice where the M1+ content is not in yet.
# See docs/PLAN.md §8 and §11.
# =============================================================================

# pin cocotb etc. from the workspace (soft include; ok if absent)
-include ../dv_env.mk

VERILATOR ?= verilator
SBY       ?= sby
IVERILOG  ?= iverilog

RTL_DIR := rtl
TOP     := pcie_ucie3d_adapter
RTL_TOP := $(RTL_DIR)/$(TOP).sv
RTL_SRCS := $(RTL_DIR)/async_fifo.sv $(RTL_DIR)/tx_framer.sv $(RTL_DIR)/tx_egress.sv \
            $(RTL_DIR)/rx_ingress.sv $(RTL_DIR)/rx_deframer.sv $(RTL_DIR)/pcie_egress.sv \
            $(RTL_DIR)/fc_ctl.sv $(RTL_DIR)/adapter_rf.sv $(RTL_DIR)/adapter_ctrl_fsm.sv $(RTL_DIR)/ucie_sb_master.sv \
            $(RTL_DIR)/tx_ingress_gate.sv $(RTL_TOP)

.PHONY: default help lint sim regress coverage formal ci envs crosscheck \
        iverilog vlt uvm systemc cocotb \
        config1 config2 config3 \
        vlt-fc systemc-fc uvm-fc cocotb-fc envs-fc \
        waves wave-check-all upf upf-tb pd-emu pd-emu-ret metrics dashboard stress clean

default: help

help:
	@echo "pcie-on-ucie-3d — targets:"
	@echo "  lint       Verilator --lint-only -Wall on rtl/ (default + FLOW_CTRL + DP_RESET_DISABLE; x8 refused)"
	@echo "  sim        Icarus directed tests (M0: smoke)"
	@echo "  regress    lint + sim  — the fast CI gate"
	@echo "  coverage   Verilator C++ env with --coverage -> coverage.info (floor 99%)"
	@echo "  formal     SymbiYosys prove + cover on formal/*.sby"
	@echo "  iverilog|vlt|uvm|systemc|cocotb   run one DV environment smoke"
	@echo "  crosscheck all five envs agree with dv/common/scenarios.py (M4+)"
	@echo "  ci         regress coverage formal envs crosscheck ..."
	@echo "  config1|config2|config3   the three TB configs (C1 integrated / C2 PCIe-b2b / C3 UCIe-b2b)"
	@echo "  upf        UPF TB on a commercial PA simulator if on PATH, else a notice, exit 0"
	@echo "  upf-tb     functional Icarus run of the power-aware TB (PMU sequencing, no UPF)"
	@echo "  pd-emu     UPF-like PD_DP power-state emulation (cocotb, default build: retain nothing)"
	@echo "  pd-emu-ret power-state emulation, -DDP_RESET_DISABLE (retention matrix + negative control)"
	@echo "  metrics|dashboard   collect run data -> metrics.db -> dashboard.html"
	@echo "  stress     multi-seed Verilator run of all scenarios"
	@echo "  clean      remove build artifacts"
	@echo "  note: uvm needs a UVM-capable Verilator (>= 5.03x, e.g. the from-source Verilator in the CI image)"

# ---- M0 real targets --------------------------------------------------------
lint:
	$(VERILATOR) --lint-only -Wall -I$(RTL_DIR) --top-module $(TOP) $(RTL_SRCS)
	$(VERILATOR) --lint-only -Wall -DFLOW_CTRL_OVERRIDE -I$(RTL_DIR) --top-module $(TOP) $(RTL_SRCS)
	$(VERILATOR) --lint-only -Wall -DDP_RESET_DISABLE -I$(RTL_DIR) --top-module $(TOP) $(RTL_SRCS)
	@if $(VERILATOR) --lint-only -Wall -DUCIE_NLANES_OVERRIDE=8 -I$(RTL_DIR) --top-module $(TOP) $(RTL_SRCS) >/dev/null 2>&1; then \
	  echo "lint: x8 must be refused at elaboration (UCIE_BUS_W > PCIE_DATA_W, D1)"; exit 1; fi
	@echo "lint: OK (default + FLOW_CTRL_OVERRIDE + DP_RESET_DISABLE; x8 correctly refused)"

sim: iverilog

iverilog:
	$(MAKE) -C dv/iverilog smoke tx loop pm rxovf scen pcie_b2b ucie_b2b

regress: lint sim
	@echo "regress: OK"

# ---- the three TB configs (docs/PLAN.md §5) ---------------------------------
# C1 integrated adapter loopback (the shared-scenario harness, all 5 envs).
config1:
	$(MAKE) -C dv/iverilog loop scen
# C2 PCIe-only back-to-back / C3 UCIe-3D-only back-to-back baselines.
config2:
	$(MAKE) -C dv/iverilog pcie_b2b
config3:
	$(MAKE) -C dv/iverilog ucie_b2b

# ---- environments -----------------------------------------------------------
vlt:
	$(MAKE) -C dv/vlt smoke
uvm:
	$(MAKE) -C dv/uvm smoke
systemc:
	$(MAKE) -C dv/systemc smoke
cocotb:
	$(MAKE) -C dv/cocotb smoke
envs: iverilog vlt uvm systemc cocotb

vlt-fc:
	$(MAKE) -C dv/vlt fc
systemc-fc:
	$(MAKE) -C dv/systemc fc
uvm-fc:
	$(MAKE) -C dv/uvm fc
cocotb-fc:
	$(MAKE) -C dv/cocotb fc
envs-fc: vlt-fc systemc-fc uvm-fc cocotb-fc

ENV_RESULTS := dv/iverilog/sim_build/results.json dv/vlt/logs/results.json dv/uvm/logs/results.json \
               dv/systemc/logs/results.json dv/cocotb/results.json

# Run each env's shared-scenario pass (each writes results.json + self-crosschecks),
# then require all five to agree with dv/common/scenarios.py.
.PHONY: scen-iverilog scen-vlt scen-systemc scen-cocotb scen-uvm scen-all
scen-iverilog:
	$(MAKE) -C dv/iverilog scen
scen-vlt:
	$(MAKE) -C dv/vlt scen
scen-systemc:
	$(MAKE) -C dv/systemc scen
scen-cocotb:
	$(MAKE) -C dv/cocotb scen
scen-uvm:
	$(MAKE) -C dv/uvm scen
scen-all: scen-iverilog scen-vlt scen-systemc scen-cocotb scen-uvm

crosscheck: scen-all
	python3 dv/common/crosscheck.py --require iverilog,vlt,uvm,systemc,cocotb $(ENV_RESULTS)

# ---- coverage / formal ------------------------------------------------------
coverage:
	$(MAKE) -C dv/vlt coverage

formal:
	@if command -v $(SBY) >/dev/null 2>&1; then \
		$(MAKE) -C formal; \
	else \
		echo "[FORMAL] $(SBY) not found; install SymbiYosys + a slang-capable Yosys (see Dockerfile) to run formal"; \
	fi

# ---- power ------------------------------------------------------------------
upf:
	$(MAKE) -C lp upf-pa
upf-tb:
	$(MAKE) -C lp upf-tb
# UPF-like power-state emulation (OSS, cocotb on Icarus).  pd-emu: the default build
# (datapath-local reset ON, D18) must survive a PD_DP power cycle with NO retention.
# pd-emu-ret: the -DDP_RESET_DISABLE build needs retention (retain-nothing is the negative
# control, must fail) and writes the minimal retained set to lp/cocotb/retention_min.txt.
pd-emu:
	$(MAKE) -C lp/cocotb pd
pd-emu-ret:
	$(MAKE) -C lp/cocotb pd-ret

# ---- metrics ----------------------------------------------------------------
# run + time these flows, then collect their real artifacts into metrics/metrics.db.
# crosscheck runs every env's scenario pass (incl. uvm); drop it from METRICS_FLOWS to
# skip the UVM build on a box without a UVM-capable Verilator.
METRICS_FLOWS ?= regress,crosscheck,coverage,formal,upf-tb
metrics:
	python3 metrics/collect.py --run $(METRICS_FLOWS) --note "$(METRICS_NOTE)"
dashboard:
	python3 metrics/dashboard.py

# ---- waves / stress ---------------------------------------------------------
# per-test waves: run a test with a VCD dump, check the GTKWave session against it,
# and open it if gtkwave + a display are available.  `make waves` = loop.
WAVE_TESTS := smoke tx loop pm rxovf scen upf
waves: wave-loop
wave-%:
	@if [ "$*" = "upf" ]; then $(MAKE) -C lp upf-tb WAVES=1; else $(MAKE) -C dv/iverilog $* WAVES=1; fi
	python3 dv/waves/wave_check.py check $* $$(if [ "$*" = "upf" ]; then echo lp/sim_build/upf_tb.vcd; else echo dv/iverilog/sim_build/$*.vcd; fi)
	@if command -v gtkwave >/dev/null 2>&1 && [ -n "$$DISPLAY" ]; then \
	  gtkwave -a dv/waves/$*.gtkw $$(if [ "$*" = "upf" ]; then echo lp/sim_build/upf_tb.vcd; else echo dv/iverilog/sim_build/$*.vcd; fi) & \
	else echo "wave-$*: gtkwave/DISPLAY not available; open with: gtkwave -a dv/waves/$*.gtkw <dump>"; fi
# check every test's .gtkw against a fresh dump, no GUI (CI)
wave-check-all:
	@for t in $(WAVE_TESTS); do $(MAKE) --no-print-directory wave-$$t DISPLAY= || exit 1; done
stress:
	$(MAKE) -C dv/vlt stress STRESS_SEEDS=$(or $(STRESS_SEEDS),20)

# ---- random regression ------------------------------------------------------
N ?= 30
JOBS ?= 4
.PHONY: rr-build rr rr-triage rr-replay
rr-build:
	python3 dv/random/rr.py build
rr:
	python3 dv/random/rr.py run --n $(N) --jobs $(JOBS) $(if $(SEED),--seed-base $(SEED))
rr-triage:
	python3 dv/random/rr.py triage $(RUN)
rr-replay:
	python3 dv/random/rr.py replay --jobs $(JOBS)

# ---- full local CI mirror ---------------------------------------------------
ci: regress coverage formal crosscheck
	@echo "ci: OK"

clean:
	rm -rf dv/*/sim_build dv/*/sim_build_* dv/*/obj_dir* dv/*/logs dv/*/logs_* dv/*/fc_run obj_dir \
	       coverage.info coverage.dat formal/*_prove formal/*_cover metrics/_capture
	rm -f dv/cocotb/results.xml dv/cocotb/results.json dv/cocotb/fcov.json dv/uvm/build.log
	find . -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
	@echo "clean: OK"
