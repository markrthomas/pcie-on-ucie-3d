# dv/iverilog — directed Icarus Verilog environment (DV env 1).
# M0: smoke (reset/defaults contract, tb_smoke.sv).  M1+ adds tx / loop / pm /
# rxovf / scen (shared scenarios) and the C2/C3 back-to-back tops.
IVERILOG ?= iverilog
VVP      ?= vvp
RTL_DIR  := ../../rtl
COMMON   := ../common
RTL_SRCS := $(RTL_DIR)/pcie_ucie3d_adapter.sv
BUILD    := sim_build
# The RTL / TBs need Icarus >= 12 (CI uses 12.0).  Fail early with a readable
# message; IVERILOG_MIN_MAJOR=0 skips the check.
IVERILOG_MIN_MAJOR ?= 12
IV_MAJOR := $(shell $(IVERILOG) -V 2>&1 | sed -n '1s/.*version \([0-9][0-9]*\)\..*/\1/p')
ifneq ($(filter-out clean,$(MAKECMDGOALS)),)
ifneq ($(IVERILOG_MIN_MAJOR),0)
ifeq ($(shell [ "$(or $(IV_MAJOR),0)" -ge $(IVERILOG_MIN_MAJOR) ] && echo ok),)
$(error iverilog >= $(IVERILOG_MIN_MAJOR) required, found "$(or $(IV_MAJOR),none / not runnable)" ($(shell command -v $(IVERILOG))); install Icarus 12 (apt iverilog on Ubuntu 24.04, or build from source))
endif
endif
endif
IVEXTRA ?=

.PHONY: smoke clean
smoke:
	@mkdir -p $(BUILD)
	$(IVERILOG) -g2012 $(IVEXTRA) -I $(RTL_DIR) -I $(COMMON) -o $(BUILD)/smoke.vvp tb_smoke.sv $(RTL_SRCS)
	$(VVP) $(BUILD)/smoke.vvp | tee $(BUILD)/smoke.log
	@grep -q "SMOKE PASS" $(BUILD)/smoke.log

clean:
	rm -rf $(BUILD)
