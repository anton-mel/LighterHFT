set part "xcvm1802-vsva2197-2MP-e-S"

set rtl_files [glob -nocomplain rtl/common/*.sv rtl/nasdaq/*.sv rtl/top/*.sv]
read_verilog -sv $rtl_files
read_xdc constraints/hft_top.xdc

synth_design -top hft_top -part $part

file mkdir reports
report_utilization -file reports/utilization.rpt
report_timing_summary -file reports/timing.rpt
write_checkpoint -force reports/hft_top_synth.dcp
