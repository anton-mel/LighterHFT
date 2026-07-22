# runtime

Orchestration and analysis layer. Parses real exchange data and runs the same algorithm as
`fpga/rtl/top/hft_top.sv` (order book, covariance, min-variance sizing), either by driving
the real FPGA through `drivers/` or as a fast native model for quick iteration.

- `lifetime_hft.py` — parses a full NASDAQ ITCH session directly (no simulator), rebalancing
  once per real second of trading time; outputs fills + a P&L series as JSON
