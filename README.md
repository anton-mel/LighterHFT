# LighterHFT

FPGA HFT system, synthesis-only (no board programming). Target: Xilinx VMK180 (Versal AI Core).
Reference: MIT FPGA HFT paper. Initial protocol: NASDAQ (ITCH feed handler, OUCH order entry). Lighter Exchange port planned later.

## Layout

- `rtl/` — SystemVerilog sources
  - `nasdaq/` — ITCH parser, OUCH order entry
  - `common/` — shared modules
- `tb/` — testbenches
- `constraints/` — XDC for VMK180
- `scripts/` — Vivado non-project-mode Tcl build (`synth.tcl`, `build.tcl`)
- `docs/` — design notes

## Build (synth only, on bouchet)

```
source /nfs/roberts/project/pi_lz484/am3785/vivado_install/Xilinx/Vivado/2023.1/settings64.sh
vivado -mode batch -source scripts/synth.tcl
```

## Workflow

- `main` is protected; all work lands via PR from `feature/*` branches.
- Commits: keyword-only messages, no prose, no AI co-author trailer.
- Code: no comments except single-liners where the why is non-obvious.
