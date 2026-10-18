# lp/ — low power: UPF intent (authored, not run) + power-state emulation.
# M0: scaffold.  M6 adds bridge.upf (PD_AON always-on control plane / PD_DP
# switchable datapath), the DV-only power sequencer, the power-aware TB, and
# docs/power_intent.md.  See docs/PLAN.md §9.
.PHONY: upf-pa upf-tb pd pd-ret

# UPF on a commercial power-aware simulator if one is on PATH, else a notice (exit 0).
upf-pa:
	@if command -v vcs >/dev/null 2>&1 || command -v xrun >/dev/null 2>&1 || command -v vsim >/dev/null 2>&1; then \
	  echo "[upf] a commercial PA simulator is on PATH, but the UPF flow lands in M6 (docs/PLAN.md §9)"; \
	else \
	  echo "[upf] no commercial power-aware simulator on PATH; UPF is authored, not run (docs/PLAN.md §9)"; \
	fi

# functional (not power-aware) Icarus run of the power-aware TB (PMU sequencing).
upf-tb:
	@echo "[upf-tb] power-aware TB (PMU sequencing, no UPF) lands in M6 (docs/PLAN.md §11)"

# UPF-like power-state emulation (cocotb on Icarus): corruption / isolation / retention.
pd:
	@echo "[pd-emu] power-state emulation lands in M6 (docs/PLAN.md §11)"
pd-ret:
	@echo "[pd-emu-ret] retention emulation lands in M6 (docs/PLAN.md §11)"
