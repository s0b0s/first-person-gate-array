# Out-of-context implementation of single blocks at their own clock rates, to record
# LUT / FF / BRAM / DSP / worst slack per block, to check each against its budget.
#
# Usage (from the repository root):
#   vivado -mode batch -source scripts/ooc.tcl -tclargs block1 [block2 ...]
#   with no arguments, every stage-0 block in the list below
#   set OOC_ONLY (see below) to read only some RTL files
#
# Every input port whose name contains "clk" gets a clock: 40 ns for pixel-domain ports
# (names containing "pix" or "rd_clk"), 10 ns otherwise. Results: build/ooc/<block>_*.rpt and
# one line per block in build/ooc/summary.txt.

set part xc7a35tcpg236-1
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root build ooc]
file mkdir $out

set blocks $argv
if {[llength $blocks] == 0} {
	set blocks {sram_controller sram_arbiter sync_fifo display_controller buffer_manager
		power_gate ps2_input flash_reader uart_rx uart_tx debug_port i2s_tx tone_gen
		text_painter sram_tester}
}

proc vhd_files {dir} {
	set files [glob -nocomplain -directory $dir *.vhd]
	foreach sub [glob -nocomplain -type d -directory $dir *] {
		set files [concat $files [vhd_files $sub]]
	}
	return $files
}
set pkgs [lsort [glob -directory [file join $root rtl pkg] *.vhd]]
# OOC_ONLY (environment, optional): comma-separated path fragments; only RTL files whose path
# contains one are read (packages always are), so an unfinished file elsewhere does not stop
# the run. Example: OOC_ONLY=game/asset_loader,debug/replay_unit
set only {}
if {[info exists ::env(OOC_ONLY)]} {
	set only [split $::env(OOC_ONLY) ","]
}
set others {}
foreach f [lsort [vhd_files [file join $root rtl]]] {
	if {[lsearch -exact $pkgs $f] >= 0} {
		continue
	}
	set keep [expr {[llength $only] == 0}]
	foreach frag $only {
		if {$frag ne "" && [string first $frag $f] >= 0} {
			set keep 1
		}
	}
	if {$keep} {
		lappend others $f
	}
}

set_part $part
# Threads: VIVADO_THREADS, else every core (Windows NUMBER_OF_PROCESSORS); Vivado's default is
# 2, and placement and routing use up to 8 of whatever is allowed
if {[info exists ::env(VIVADO_THREADS)]} {
	set threads $::env(VIVADO_THREADS)
} elseif {[info exists ::env(NUMBER_OF_PROCESSORS)]} {
	set threads $::env(NUMBER_OF_PROCESSORS)
} else {
	set threads 8
}
set_param general.maxThreads $threads
puts "Vivado threads: [get_param general.maxThreads]"
# The design is VHDL-93 (the course's standard); only the testbenches use VHDL-2008
read_vhdl $pkgs
read_vhdl $others

set summary [open [file join $out summary.txt] a]
foreach block $blocks {
	close_design -quiet
	synth_design -top $block -part $part -mode out_of_context
	foreach port [get_ports -quiet -filter {DIRECTION == IN && NAME =~ *clk*}] {
		set period 10.0
		if {[string match *pix* $port] || [string match *rd_clk* $port]} {
			set period 40.0
		}
		create_clock -name $port -period $period $port
	}
	# Clocks of a block are unrelated unless one is the SRAM capture clock
	set clks [get_clocks -quiet]
	if {[llength $clks] > 1 && [llength [get_clocks -quiet clk_rd_i]] == 0} {
		set groups {}
		foreach c $clks {
			lappend groups -group $c
		}
		set_clock_groups -asynchronous {*}$groups
	}
	opt_design
	place_design
	route_design
	report_utilization -file [file join $out ${block}_utilization.rpt]
	report_timing_summary -file [file join $out ${block}_timing.rpt]
	set util [report_utilization -return_string]
	regexp {Slice LUTs\*?\s*\|\s*(\d+)} $util -> luts
	regexp {Slice Registers\s*\|\s*(\d+)} $util -> ffs
	regexp {Block RAM Tile\s*\|\s*([\d.]+)} $util -> bram
	regexp {DSPs\s*\|\s*(\d+)} $util -> dsp
	set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
	set line [format "%-20s LUT %5s  FF %5s  BRAM36 %4s  DSP %2s  WNS %s" $block $luts $ffs $bram $dsp $wns]
	puts "OOC_RESULT $line"
	puts $summary $line
	flush $summary
}
close $summary
