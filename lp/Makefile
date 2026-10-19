# lp — power intent.  `make -C lp upf-tb`: functional (NON power-aware) Icarus run
# of the power-aware TB: PMU sequencing + the no-handshake timing assumption +
# traffic across L1/L2 episodes.  The UPF itself needs a commercial power-aware
# simulator: `make -C lp upf-pa` runs it if one is on PATH, else prints a notice
# and exits 0 (no OSS power-aware simulator models UPF supplies/isolation/retention).
IVERILOG ?= iverilog
VVP      ?= vvp
RTL_DIR  := ../rtl
COMMON   := ../dv/common
IVDIR    := ../dv/iverilog
RTL_SRCS := $(RTL_DIR)/async_fifo.sv $(RTL_DIR)/tx_ingress_gate.sv $(RTL_DIR)/tx_framer.sv \
            $(RTL_DIR)/tx_egress.sv $(RTL_DIR)/rx_ingress.sv $(RTL_DIR)/rx_deframer.sv \
            $(RTL_DIR)/pcie_egress.sv $(RTL_DIR)/ucie_sb_master.sv $(RTL_DIR)/fc_ctl.sv \
            $(RTL_DIR)/adapter_ctrl_fsm.sv $(RTL_DIR)/adapter_rf.sv $(RTL_DIR)/pcie_ucie3d_adapter.sv
TB_DEPS  := $(COMMON)/pcie_mac_model.sv $(COMMON)/ucie_phy_model.sv \
            $(COMMON)/ucie_sb_model.sv $(COMMON)/pcie_sink_model.sv
BUILD    := sim_build
PA_SRCS  := tb_adapter_upf_power.sv adapter_pmu.sv $(TB_DEPS) $(RTL_SRCS)
INCS     := -I $(RTL_DIR) -I $(COMMON) -I $(IVDIR)
# WAVES=1: dump the upf TB to sim_build/upf_tb.vcd for dv/waves/upf.gtkw (make wave-upf).
WAVES    ?= 0
WFLAGS    = $(if $(filter 1,$(WAVES)),-DDUMP_TOP=tb_adapter_upf_power ../dv/waves/wave_dump.sv)
WRUN      = $(if $(filter 1,$(WAVES)),+dumpfile=$(BUILD)/upf_tb.vcd)

# ---- UPF on a commercial power-aware simulator (optional) -------------------------------------
# Picks the first of vcs (VCS-NLP), xrun (Xcelium), vsim (Questa-PA) found on PATH.  With none of
# them it prints a notice and exits 0: the tool is not available in the OSS environment, so the UPF
# stays authored-not-run there.  The per-tool command lines below are UNTESTED (no licence has ever
# been available here); adjust the flags to your tool version.  Pass/fail = "UPF-TB PASS" in the log.
PA_TOOL := $(firstword $(foreach t,vcs xrun vsim,$(if $(shell command -v $(t) 2>/dev/null),$(t))))
.PHONY: upf-pa
upf-pa:
ifeq ($(PA_TOOL),)
	@echo "upf: no commercial power-aware simulator on PATH (looked for vcs, xrun, vsim) - skipping."
	@echo "     lp/adapter.upf stays AUTHORED, NOT RUN here (no OSS tool models UPF supplies /"
	@echo "     isolation / retention).  'make upf-tb' runs the same TB functionally (no power semantics)."
else
	@mkdir -p $(BUILD)/pa
	@echo "upf: using $(PA_TOOL) (command line untested - see lp/Makefile)"
ifeq ($(PA_TOOL),vcs)
	cd $(BUILD)/pa && vcs -full64 -sverilog -timescale=1ns/1ps +define+UPF_SIM -debug_access+all \
	  -upf $(abspath adapter.upf) -top tb_adapter_upf_power -I $(abspath $(RTL_DIR)) -I $(abspath $(COMMON)) -I $(abspath $(IVDIR)) \
	  $(addprefix $(CURDIR)/,$(PA_SRCS)) -o simv && ./simv | tee ../upf_pa.log
endif
ifeq ($(PA_TOOL),xrun)
	cd $(BUILD)/pa && xrun -64bit -sv -timescale 1ns/1ps +define+UPF_SIM -lps_1801 -upf $(abspath adapter.upf) \
	  -top tb_adapter_upf_power -incdir $(abspath $(RTL_DIR)) -incdir $(abspath $(COMMON)) -incdir $(abspath $(IVDIR)) \
	  $(addprefix $(CURDIR)/,$(PA_SRCS)) | tee ../upf_pa.log
endif
ifeq ($(PA_TOOL),vsim)
	cd $(BUILD)/pa && vlog -sv +define+UPF_SIM +incdir+$(abspath $(RTL_DIR)) +incdir+$(abspath $(COMMON)) +incdir+$(abspath $(IVDIR)) \
	  $(addprefix $(CURDIR)/,$(PA_SRCS)) && vopt -pa -pa_upf $(abspath adapter.upf) tb_adapter_upf_power -o tb_pa_opt \
	  && vsim -c -pa tb_pa_opt -do "run -all; quit" | tee ../upf_pa.log
endif
	@grep -q "UPF-TB PASS" $(BUILD)/upf_pa.log
endif

.PHONY: upf-tb clean
upf-tb:
	@mkdir -p $(BUILD)
	$(IVERILOG) -g2012 $(INCS) $(WFLAGS) -o $(BUILD)/upf_tb.vvp \
	  tb_adapter_upf_power.sv adapter_pmu.sv $(TB_DEPS) $(RTL_SRCS)
	$(VVP) $(BUILD)/upf_tb.vvp $(WRUN) | tee $(BUILD)/upf_tb.log
	@grep -q "UPF-TB PASS" $(BUILD)/upf_tb.log

clean:
	rm -rf $(BUILD)
