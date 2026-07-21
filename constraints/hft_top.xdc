# Synthesis-stage timing only; no pin LOCs yet -- this targets VMK180 for synth/utilization
# proof, not board bring-up (no physical I/O mapping done).
create_clock -period 10.000 -name clk [get_ports clk]
