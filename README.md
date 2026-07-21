# LighterHFT

FPGA HFT system, synthesis-only (no board programming). Target: Xilinx VMK180 (Versal AI Core).
Reference: MIT 6.111 "HFT Accelerator" project report. Initial protocol: NASDAQ (ITCH feed
handler, OUCH order entry). Lighter Exchange port planned later.

## Modules

- `itch_parser` — NASDAQ ITCH 5.0 byte-stream parser (add/cancel/execute/delete/replace)
- `order_book` / `order_book_top` — per-stock direct-mapped order table + binary-tree best-price ladder
- `covariance_engine` — running mean/moment/covariance update, Q2.14 fixed point
- `qr_solver` — minimum-variance portfolio weights via Givens-rotation QR + back-substitution
- `ouch_order_gen` — target-position deltas serialized to an OUCH-like Enter Order stream
- `hft_top` — wires the above into the full feed-to-order pipeline

## Layout

- `rtl/` — SystemVerilog sources (`nasdaq/`, `common/`, `top/`)
- `tb/` — testbenches (self-checking, run via `xvlog`/`xelab`/`xsim`)
- `constraints/` — XDC for VMK180
- `scripts/synth.tcl` — Vivado non-project-mode synth flow
- `docs/` — design notes

## Build (synth only, on bouchet)

Needs the Versal AI Core device files + a Versal-capable license (WebPACK doesn't cover it) —
not yet installed as of this writing.

```
source /nfs/roberts/project/pi_lz484/am3785/vivado_install/Xilinx/Vivado/2023.1/settings64.sh
vivado -mode batch -source scripts/synth.tcl
```

## Workflow

- `main` is protected; all work lands via PR from `feature/*` branches.
- Commits: keyword-only messages, no prose, no AI co-author trailer.
- Code: no comments except single-liners where the why is non-obvious.
