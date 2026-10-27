# MegaX: out-of-context synthesis of one part of the design (no project), to narrow down
# synthesis problems quickly on the Fedora host:
#   cd CORE && vivado -mode batch -source ../tools/synth/ooc.tcl -tclargs <top> [shell]
# Reads the machine's files (CORE/sources.txt); with "shell" also the MEGA65 shell (CORE/vhdl)
# and the M2M packages it needs. Runs in CORE/ooc-<top> (the init-file paths of the RAMs are
# relative to a directory two levels below CORE, like Vivado's synth_1).
set top   [lindex $argv 0]
set shell [expr {[llength $argv] > 1 && [lindex $argv 1] eq "shell"}]
set part  xc7a200tfbg484-2
file mkdir ooc-$top/run
cd ooc-$top/run
set core ../..
set f [open $core/sources.txt]
while {[gets $f line] >= 0} {
    if {[regexp {^(vhdl|sv)\s+(\S+)} $line -> kind path]} {
        if {$kind eq "vhdl"} {
            read_vhdl -vhdl2008 $core/$path
        } elseif {[string match *.sv $path]} {
            read_verilog -sv $core/$path
        } else {
            read_verilog $core/$path
        }
    }
}
close $f
if {$shell} {
    foreach p {../M2M/QNICE/vhdl/tools.vhd ../M2M/vhdl/av_pipeline/video_modes_pkg.vhd
               ../M2M/vhdl/controllers/HDMI/types_pkg.vhd} {
        read_vhdl -vhdl2008 $core/$p
    }
    foreach s {globals config clk keyboard x68_boot main mega65} {
        read_vhdl -vhdl2008 $core/vhdl/$s.vhd
    }
}
set gen {}
if {$top eq "MEGA65_Core"} { set gen {-generic G_BOARD=MEGA65_R6} }
synth_design -top $top -part $part -mode out_of_context -flatten_hierarchy rebuilt {*}$gen
report_utilization -file utilization.rpt
puts "OOC $top OK"
