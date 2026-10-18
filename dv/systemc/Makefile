# dv/systemc — Verilator -> SystemC environment (DV env 4).
# M0: smoke (reset/defaults).  Needs SystemC 2.3.x (apt libsystemc-dev, or the
# CI image); SYSTEMC_INCLUDE / SYSTEMC_LIBDIR override the install location.
VERILATOR ?= verilator
RTL_DIR   := ../../rtl
TOP       := pcie_ucie3d_adapter
RTL_SRCS  := $(RTL_DIR)/$(TOP).sv
VFLAGS    := --sc --exe --build -j 0 -Wall -Wno-fatal --top-module $(TOP) -I$(RTL_DIR)

SYSTEMC_INCLUDE ?= /usr/include
SYSTEMC_LIBDIR  ?= /usr/lib/x86_64-linux-gnu

.PHONY: smoke fc clean

smoke:
	@if [ ! -f $(SYSTEMC_INCLUDE)/systemc.h ]; then \
	  echo "[systemc] SystemC not found at $(SYSTEMC_INCLUDE); install libsystemc-dev (or use the CI image)"; exit 0; fi
	SYSTEMC_INCLUDE=$(SYSTEMC_INCLUDE) SYSTEMC_LIBDIR=$(SYSTEMC_LIBDIR) \
	  $(VERILATOR) $(VFLAGS) --Mdir obj_dir -o sc_smoke sc_main.cpp $(RTL_SRCS)
	LD_LIBRARY_PATH=$(SYSTEMC_LIBDIR):$$LD_LIBRARY_PATH ./obj_dir/sc_smoke

fc:
	@echo "[systemc fc] flow-control scenario run lands in M4 (docs/PLAN.md §11)"

clean:
	rm -rf obj_dir logs
