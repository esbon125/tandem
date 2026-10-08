# SmartPower commands, executed by run_tool -name {VERIFYPOWER} from
# run_verify_power.tcl. Vectorless baseline: no simulation activity
# annotated, so dynamic power of fabric logic uses SmartPower's default
# toggle rates -- treat per-instance dynamic numbers as order-of-magnitude.

set out_dir [file normalize [file join [file dirname [info script]] power_reports]]

# Without this, every fabric clock domain comes up at 0 MHz (only the MSS
# hard block shows dynamic power): take the frequencies from the SDC clock
# constraints, then let vectorless propagate activity from them.
puts "SmartPower: initializing clocks from SDC constraints"
smartpower_init_set_clocks_options -with_clock_constraints {true} -with_default_values {false}
smartpower_init_do -with {vectorless} -opmode {Active} -clocks {true} \
    -registers {true} -set_reset {true} -primaryinputs {true} \
    -combinational {true} -enables {true} -othersets {true}

puts "SmartPower: computing vectorless activity"
smartpower_compute_vectorless

foreach opcond {typical worst} {
    puts "SmartPower: writing $out_dir/power_vectorless_${opcond}.txt"
    smartpower_report_power \
        -powerunit {mW} -frequnit {MHz} -opcond $opcond -opmode {Active} \
        -power_summary {true} -rail_breakdown {true} -type_breakdown {true} \
        -clock_breakdown {true} -thermal_summary {true} -opcond_summary {true} \
        -clock_summary {true} -instance_breakdown {true} \
        -power_threshold {true} -min_power {0.1} \
        -style {Text} -sortby {power values} -sortorder {descending} \
        "$out_dir/power_vectorless_${opcond}.txt"
}

# Every instance, no threshold, as CSV: summarize_power_by_module.py rolls
# these leaf cells up into per-module totals (the Text report only lists
# leaves above -min_power, which hides how much each RTL module adds up to).
puts "SmartPower: writing $out_dir/power_vectorless_typical_instances.csv"
smartpower_report_power \
    -powerunit {mW} -frequnit {MHz} -opcond {typical} -opmode {Active} \
    -power_summary {false} -rail_breakdown {false} -type_breakdown {false} \
    -clock_breakdown {false} -thermal_summary {false} -opcond_summary {false} \
    -clock_summary {false} -instance_breakdown {true} -power_threshold {false} \
    -style {CSV} -sortby {power values} -sortorder {descending} \
    "$out_dir/power_vectorless_typical_instances.csv"
