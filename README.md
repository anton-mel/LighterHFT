# LighterHFT

FPGA HFT system. Reference: MIT 6.111 "HFT Accelerator" project report. Initial protocol:
NASDAQ (ITCH feed handler, OUCH order entry). Lighter Exchange port planned later.

Two hardware targets: Xilinx VMK180 (Versal AI Core, synthesis-only — blocked on a
Versal-capable license) and an Opal Kelly XEM7310 (Artix-7, real board bring-up in progress).

## Modules

- `itch_parser` — NASDAQ ITCH 5.0 byte-stream parser (add/cancel/execute/delete/replace)
- `order_book` / `order_book_top` — per-stock direct-mapped order table + binary-tree best-price ladder
- `covariance_engine` — running mean/moment/covariance update, wide fixed point
- `qr_solver` — minimum-variance portfolio weights via Givens-rotation QR + back-substitution
- `ouch_order_gen` — target-position deltas serialized to an OUCH-like Enter Order stream
- `hft_top` — wires the above into the full feed-to-order pipeline

## Layout

- `fpga/` — the hardware design itself
  - `rtl/` — SystemVerilog sources (`nasdaq/`, `common/`, `top/`)
  - `tb/` — testbenches (self-checking, run via `xvlog`/`xelab`/`xsim`)
  - `constraints/` — XDC for VMK180
  - `scripts/synth.tcl` — Vivado non-project-mode synth flow
- `drivers/` — the CPU↔FPGA routing layer (Opal Kelly FrontPanel: HDL bridge + host-side API)
- `runtime/` — orchestration and analysis: parses exchange data, drives the FPGA or a fast
  native model of the same algorithm, computes P&L
- `docs/` — design notes

## Build (VMK180 synth, on bouchet)

Needs the Versal AI Core device files + a Versal-capable license (WebPACK doesn't cover it) —
not yet installed as of this writing.

```
source /nfs/roberts/project/pi_lz484/am3785/vivado_install/Xilinx/Vivado/2023.1/settings64.sh
vivado -mode batch -source fpga/scripts/synth.tcl
```
