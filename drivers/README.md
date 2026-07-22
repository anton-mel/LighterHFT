# drivers

CPU↔FPGA routing layer for the Opal Kelly XEM7310 (Artix-7).

- `opalkelly/hdl/` — Opal Kelly FrontPanel HDL kit (okHost, okPipeIn/Out, okWireIn/Out,
  okTriggerIn/Out) — third-party, vendored from the FrontPanel SDK
- `opalkelly/host/` — host-side FrontPanel API (`ok.py`, `libokFrontPanel.dylib`) and the
  driver script that loads the bitstream, streams ITCH bytes in via PipeIn, and reads fill
  events back via PipeOut

Bridges `fpga/rtl/top/hft_top.sv` to real USB3 hardware without touching the core trading
logic itself.
