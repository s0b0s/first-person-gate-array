# Non-project Vivado build: synthesis, implementation, reports, bitstream, flash image.
#
# Usage (from the repository root):
#   vivado -mode batch -source scripts/build.tcl -tclargs [top] [sram_cycles]
#   top          top-level entity, default bringup_top
#   Windows:     D:\Xilinx\2025.1\Vivado\bin\vivado.bat -mode batch -source scripts/build.tcl
#
# Outputs go to build/<top>/: <top>.bit, <top>.mcs (bitstream at 0x000000, plus
# build/gamedata.bin at 0x220000 when that file exists), checkpoints, and reports
# (utilization, timing summary, clock interaction, CDC, I/O, DRC, methodology, power).

set top bringup_top
if {[llength $argv] > 0} {
	set top [lindex $argv 0]
}
set part xc7a35tcpg236-1
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root build $top]
file mkdir $out

# All synthesizable VHDL: packages first, then every other file under rtl/
proc vhd_files {dir} {
	set files [glob -nocomplain -directory $dir *.vhd]
	foreach sub [glob -nocomplain -type d -directory $dir *] {
		set files [concat $files [vhd_files $sub]]
	}
	return $files
}
set pkgs [lsort [glob -directory [file join $root rtl pkg] *.vhd]]
set others {}
foreach f [lsort [vhd_files [file join $root rtl]]] {
	if {[lsearch -exact $pkgs $f] < 0} {
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
read_xdc [file join $root constraints cmod_a7_shooter.xdc]

synth_design -top $top -part $part
write_checkpoint -force [file join $out ${top}_synth.dcp]
report_utilization -file [file join $out ${top}_utilization_synth.rpt]

# Timing-driven directives: the full game fills 65 % of the LUTs and several blocks run
# within tens of ps of 10 ns, which the default strategy missed by up to 0.06 ns
opt_design
place_design -directive ExtraTimingOpt
phys_opt_design -directive AggressiveExplore
route_design -directive Explore
# A post-route physical optimization pass only when setup still fails
if {[get_property SLACK [get_timing_paths -max_paths 1 -setup]] < 0} {
	phys_opt_design -directive AggressiveExplore
}
write_checkpoint -force [file join $out ${top}_routed.dcp]

# The SRAM pin timing is analysed by hand (constraints/cmod_a7_shooter.xdc) on the
# condition that every SRAM-facing register is in an IOB; stop if one is not.
set sram_regs {}
foreach pattern {a_q_reg* dq_o_q_reg* dq_t_q_reg* cap_q_reg* *_oddr} {
	set sram_regs [concat $sram_regs [get_cells -quiet -hier -filter "NAME =~ *sram/$pattern"]]
}
set not_in_iob 0
foreach c $sram_regs {
	if {![string match "*LOGIC*" [get_property LOC $c]]} {
		puts "ERROR: SRAM register $c is not in an IOB ([get_property LOC $c])"
		incr not_in_iob
	}
}
puts "SRAM IOB check: [llength $sram_regs] registers, $not_in_iob outside IOBs"
if {$not_in_iob > 0} {
	error "SRAM registers outside IOBs; the hand timing analysis does not apply"
}

report_utilization -file [file join $out ${top}_utilization.rpt]
report_utilization -hierarchical -file [file join $out ${top}_utilization_hier.rpt]
report_timing_summary -max_paths 20 -report_unconstrained -file [file join $out ${top}_timing.rpt]
report_clock_interaction -file [file join $out ${top}_clock_interaction.rpt]
report_cdc -details -file [file join $out ${top}_cdc.rpt]
report_io -file [file join $out ${top}_io.rpt]
report_drc -file [file join $out ${top}_drc.rpt]
report_methodology -file [file join $out ${top}_methodology.rpt]
report_power -file [file join $out ${top}_power.rpt]
# SRAM interface paths in detail (for the hand check in the SRAM doc)
report_timing -to [get_ports {sram_a[*] sram_dq[*] sram_we_n sram_oe_n}] -max_paths 4 \
	-file [file join $out ${top}_sram_out.rpt]
report_timing -from [get_ports {sram_dq[*]}] -max_paths 4 -file [file join $out ${top}_sram_in.rpt]
report_timing -from [get_ports {sram_dq[*]}] -hold -max_paths 4 \
	-file [file join $out ${top}_sram_in_hold.rpt]

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "BUILD_RESULT top=$top WNS=$wns WHS=$whs"

write_bitstream -force [file join $out ${top}.bit]

# Flash image: bitstream at 0, game data at 0x220000 (FLASH_DATA_BASE in hw_pkg)
set loads [list up 0x00000000 [file join $out ${top}.bit]]
set data [file join $root build gamedata.bin]
if {[file exists $data]} {
	write_cfgmem -force -format mcs -size 4 -interface SPIx4 \
		-loadbit $loads -loaddata [list up 0x00220000 $data] -file [file join $out ${top}.mcs]
} else {
	write_cfgmem -force -format mcs -size 4 -interface SPIx4 \
		-loadbit $loads -file [file join $out ${top}.mcs]
}
