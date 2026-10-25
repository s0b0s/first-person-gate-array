## --------------------------------------------------------------------------
## First-Person Gate Array - Cmod A7-35T constraints
## Pin map: frozen, because the carrier PCB is drawn from it; moving a pin
## means changing the PCB. Pmod port JA is deliberately NOT assigned (one JA
## VCC pin only feeds 3.3 V to the PCB through a jumper).
## Top-level port names match rtl/top/bringup_top.vhd (and later the game top).
## --------------------------------------------------------------------------

## Configuration and bitstream (boot from the on-board QSPI flash)
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]

## --------------------------------------------------------------------------
## Clocks
## --------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN L17 IOSTANDARD LVCMOS33 } [get_ports clk12]
create_clock -name clk12 -period 83.333 [get_ports clk12]

## The MMCM outputs are derived automatically; these lines only rename them.
create_generated_clock -name clk_sys [get_pins clocks/cmt/CLKOUT0]
create_generated_clock -name clk_pix [get_pins clocks/cmt/CLKOUT1]
create_generated_clock -name clk_sram_rd [get_pins clocks/cmt/CLKOUT2]

## The system and pixel domains meet only in the display controller, through
## synchronizers and dual-clock RAMs. clk_sram_rd stays with clk_sys: the SRAM
## capture path between them must be timed.
set_clock_groups -asynchronous -group [get_clocks {clk_sys clk_sram_rd}] -group [get_clocks clk_pix]

## --------------------------------------------------------------------------
## On-board I/O
## --------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN A17 IOSTANDARD LVCMOS33 } [get_ports {led[0]}]
set_property -dict { PACKAGE_PIN C16 IOSTANDARD LVCMOS33 } [get_ports {led[1]}]
set_property -dict { PACKAGE_PIN C17 IOSTANDARD LVCMOS33 } [get_ports led0_r]
set_property -dict { PACKAGE_PIN B16 IOSTANDARD LVCMOS33 } [get_ports led0_g]
set_property -dict { PACKAGE_PIN B17 IOSTANDARD LVCMOS33 } [get_ports led0_b]
set_property -dict { PACKAGE_PIN A18 IOSTANDARD LVCMOS33 } [get_ports {btn[0]}]
set_property -dict { PACKAGE_PIN B18 IOSTANDARD LVCMOS33 } [get_ports {btn[1]}]
set_property -dict { PACKAGE_PIN J17 IOSTANDARD LVCMOS33 } [get_ports uart_txd_in]
set_property -dict { PACKAGE_PIN J18 IOSTANDARD LVCMOS33 } [get_ports uart_rxd_out]

## QSPI flash, used as user I/O after configuration. SCK is the extra
## connection on E19 (Cmod A7 manual), so no STARTUPE2 is needed.
set_property -dict { PACKAGE_PIN K19 IOSTANDARD LVCMOS33 IOB TRUE } [get_ports qspi_cs_n]
set_property -dict { PACKAGE_PIN E19 IOSTANDARD LVCMOS33 IOB TRUE } [get_ports qspi_sck]
set_property -dict { PACKAGE_PIN D18 IOSTANDARD LVCMOS33 IOB TRUE } [get_ports {qspi_dq[0]}]
set_property -dict { PACKAGE_PIN D19 IOSTANDARD LVCMOS33 IOB TRUE } [get_ports {qspi_dq[1]}]
set_property -dict { PACKAGE_PIN G18 IOSTANDARD LVCMOS33 } [get_ports {qspi_dq[2]}]
set_property -dict { PACKAGE_PIN F18 IOSTANDARD LVCMOS33 } [get_ports {qspi_dq[3]}]

## SRAM IS61WV5128BLL-10: every register in the IOBs (timing notes below)
set_property -dict { PACKAGE_PIN M18 IOSTANDARD LVCMOS33 } [get_ports {sram_a[0]}]
set_property -dict { PACKAGE_PIN M19 IOSTANDARD LVCMOS33 } [get_ports {sram_a[1]}]
set_property -dict { PACKAGE_PIN K17 IOSTANDARD LVCMOS33 } [get_ports {sram_a[2]}]
set_property -dict { PACKAGE_PIN N17 IOSTANDARD LVCMOS33 } [get_ports {sram_a[3]}]
set_property -dict { PACKAGE_PIN P17 IOSTANDARD LVCMOS33 } [get_ports {sram_a[4]}]
set_property -dict { PACKAGE_PIN P18 IOSTANDARD LVCMOS33 } [get_ports {sram_a[5]}]
set_property -dict { PACKAGE_PIN R18 IOSTANDARD LVCMOS33 } [get_ports {sram_a[6]}]
set_property -dict { PACKAGE_PIN W19 IOSTANDARD LVCMOS33 } [get_ports {sram_a[7]}]
set_property -dict { PACKAGE_PIN U19 IOSTANDARD LVCMOS33 } [get_ports {sram_a[8]}]
set_property -dict { PACKAGE_PIN V19 IOSTANDARD LVCMOS33 } [get_ports {sram_a[9]}]
set_property -dict { PACKAGE_PIN W18 IOSTANDARD LVCMOS33 } [get_ports {sram_a[10]}]
set_property -dict { PACKAGE_PIN T17 IOSTANDARD LVCMOS33 } [get_ports {sram_a[11]}]
set_property -dict { PACKAGE_PIN T18 IOSTANDARD LVCMOS33 } [get_ports {sram_a[12]}]
set_property -dict { PACKAGE_PIN U17 IOSTANDARD LVCMOS33 } [get_ports {sram_a[13]}]
set_property -dict { PACKAGE_PIN U18 IOSTANDARD LVCMOS33 } [get_ports {sram_a[14]}]
set_property -dict { PACKAGE_PIN V16 IOSTANDARD LVCMOS33 } [get_ports {sram_a[15]}]
set_property -dict { PACKAGE_PIN W16 IOSTANDARD LVCMOS33 } [get_ports {sram_a[16]}]
set_property -dict { PACKAGE_PIN W17 IOSTANDARD LVCMOS33 } [get_ports {sram_a[17]}]
set_property -dict { PACKAGE_PIN V15 IOSTANDARD LVCMOS33 } [get_ports {sram_a[18]}]
set_property -dict { PACKAGE_PIN W15 IOSTANDARD LVCMOS33 } [get_ports {sram_dq[0]}]
set_property -dict { PACKAGE_PIN W13 IOSTANDARD LVCMOS33 } [get_ports {sram_dq[1]}]
set_property -dict { PACKAGE_PIN W14 IOSTANDARD LVCMOS33 } [get_ports {sram_dq[2]}]
set_property -dict { PACKAGE_PIN U15 IOSTANDARD LVCMOS33 } [get_ports {sram_dq[3]}]
set_property -dict { PACKAGE_PIN U16 IOSTANDARD LVCMOS33 } [get_ports {sram_dq[4]}]
set_property -dict { PACKAGE_PIN V13 IOSTANDARD LVCMOS33 } [get_ports {sram_dq[5]}]
set_property -dict { PACKAGE_PIN V14 IOSTANDARD LVCMOS33 } [get_ports {sram_dq[6]}]
set_property -dict { PACKAGE_PIN U14 IOSTANDARD LVCMOS33 } [get_ports {sram_dq[7]}]
set_property -dict { PACKAGE_PIN P19 IOSTANDARD LVCMOS33 } [get_ports sram_oe_n]
set_property -dict { PACKAGE_PIN R19 IOSTANDARD LVCMOS33 } [get_ports sram_we_n]
set_property -dict { PACKAGE_PIN N19 IOSTANDARD LVCMOS33 } [get_ports sram_ce_n]
set_property IOB TRUE [get_ports {sram_a[*] sram_dq[*]}]
set_property DRIVE 12 [get_ports {sram_a[*] sram_dq[*] sram_oe_n sram_we_n sram_ce_n}]
set_property SLEW FAST [get_ports {sram_a[*] sram_dq[*] sram_oe_n sram_we_n}]

## --------------------------------------------------------------------------
## DIP pins to the carrier PCB (23 used; JA and the other DIP pins unassigned)
## --------------------------------------------------------------------------
## PS/2 through the level shifter: open drain ('0' or 'Z'), the shifter's
## 10 kohm resistors are the pull-ups. Shifter channel An (3.3 V side) maps to
## Bn (5 V side), which goes to the Pmod PS2 socket (Pmod pin 1 Data, 3 Clock).
## DIP 1 kb_clk: A4/B4, keyboard Clock
set_property -dict { PACKAGE_PIN M3 IOSTANDARD LVCMOS33 DRIVE 8 } [get_ports kb_clk]
## DIP 2 kb_dat: A3/B3, keyboard Data
set_property -dict { PACKAGE_PIN L3 IOSTANDARD LVCMOS33 DRIVE 8 } [get_ports kb_dat]
## DIP 3 ms_clk: A2/B2, mouse Clock
set_property -dict { PACKAGE_PIN A16 IOSTANDARD LVCMOS33 DRIVE 8 } [get_ports ms_clk]
## DIP 4 ms_dat: A1/B1, mouse Data
set_property -dict { PACKAGE_PIN K3 IOSTANDARD LVCMOS33 DRIVE 8 } [get_ports ms_dat]

## Pmod I2S2, DAC row only (Pmod pins 1 MCLK, 2 LRCK, 3 SCLK, 4 SDIN). The DIP
## order runs SDIN to MCLK so the four PCB traces run in parallel without
## crossing.
## DIP 17 -> I2S2 pin 4
set_property -dict { PACKAGE_PIN M1 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8 IOB TRUE } [get_ports i2s_sdin]
## DIP 18 -> I2S2 pin 3
set_property -dict { PACKAGE_PIN N3 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8 IOB TRUE } [get_ports i2s_sclk]
## DIP 19 -> I2S2 pin 2
set_property -dict { PACKAGE_PIN P3 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8 IOB TRUE } [get_ports i2s_lrck]
## DIP 20 -> I2S2 pin 1
set_property -dict { PACKAGE_PIN M2 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8 IOB TRUE } [get_ports i2s_mclk]

## PWR_SENSE: the PCB 3.3 V net; pulled down so a missing jumper reads '0'
set_property -dict { PACKAGE_PIN W3 IOSTANDARD LVCMOS33 PULLDOWN TRUE } [get_ports pwr_sense]

## Pmod VGA: slow edges for unterminated traces, all registers in IOBs so
## every bit changes at the same time
set_property -dict { PACKAGE_PIN V3 IOSTANDARD LVCMOS33 } [get_ports vga_vs]
set_property -dict { PACKAGE_PIN W5 IOSTANDARD LVCMOS33 } [get_ports vga_hs]
set_property -dict { PACKAGE_PIN V4 IOSTANDARD LVCMOS33 } [get_ports {vga_g[3]}]
set_property -dict { PACKAGE_PIN U4 IOSTANDARD LVCMOS33 } [get_ports {vga_g[2]}]
set_property -dict { PACKAGE_PIN V5 IOSTANDARD LVCMOS33 } [get_ports {vga_g[1]}]
set_property -dict { PACKAGE_PIN W4 IOSTANDARD LVCMOS33 } [get_ports {vga_g[0]}]
set_property -dict { PACKAGE_PIN U5 IOSTANDARD LVCMOS33 } [get_ports {vga_b[3]}]
set_property -dict { PACKAGE_PIN U2 IOSTANDARD LVCMOS33 } [get_ports {vga_b[2]}]
set_property -dict { PACKAGE_PIN W6 IOSTANDARD LVCMOS33 } [get_ports {vga_b[1]}]
set_property -dict { PACKAGE_PIN U3 IOSTANDARD LVCMOS33 } [get_ports {vga_b[0]}]
set_property -dict { PACKAGE_PIN U7 IOSTANDARD LVCMOS33 } [get_ports {vga_r[3]}]
set_property -dict { PACKAGE_PIN W7 IOSTANDARD LVCMOS33 } [get_ports {vga_r[2]}]
set_property -dict { PACKAGE_PIN U8 IOSTANDARD LVCMOS33 } [get_ports {vga_r[1]}]
set_property -dict { PACKAGE_PIN V8 IOSTANDARD LVCMOS33 } [get_ports {vga_r[0]}]
set_property -dict { SLEW SLOW DRIVE 8 IOB TRUE } [get_ports {vga_*}]

## --------------------------------------------------------------------------
## I/O timing
## --------------------------------------------------------------------------
## SRAM: every SRAM-facing register sits in an IOB (OLOGIC/ILOGIC, checked by
## scripts/build.tcl, which stops if one is not), so its pin timing is fixed
## by the silicon, not by placement. Vivado cannot chain the address output
## path into the data input path, so the read window is checked by hand from
## the routed clock-to-pad and input delays, allowing 0.5 ns of board trace each
## way and 1 ns for the SRAM's input load:
##   read setup (slow corner): data at the capture flip-flop by 23.24 ns, needed
##     by 26.40 (edge 20 + 1.04 phase + 5.86 clock delay, less 0.5): +3.2 ns
##   read hold (fast corner): old data holds tOHA = 2 ns past the next address,
##     to 25.36 ns, needed until 23.73 (edge 23.43 plus 0.3): +1.6 ns
##   write: WE_n low 10 ns at CYCLES = 2 (tPWE 8 ns)
## The paths between the IOB registers and the fabric (including the
## clk_sram_rd capture register into clk_sys) stay fully timed.
set_false_path -to [get_ports {sram_a[*] sram_dq[*] sram_oe_n sram_we_n sram_ce_n}]
set_false_path -from [get_ports {sram_dq[*]}]

## Asynchronous or slow external interfaces: every one of these signals
## either goes through a 3-flop synchronizer (inputs) or comes from an IOB
## register whose timing the receiving device does not depend on at the
## nanosecond level (VGA monitor locks to the syncs, the I2S DAC runs from
## MCLK with tens of ns of margin, LEDs).
set_false_path -from [get_ports {btn[*] uart_txd_in pwr_sense kb_clk kb_dat ms_clk ms_dat}]
set_false_path -to [get_ports {led[*] led0_* uart_rxd_out vga_* i2s_* kb_clk kb_dat ms_clk ms_dat}]
## SPI flash at 25 MHz: SCK, CS_n and MOSI change in the middle of 40 ns bit
## times and MISO is sampled 30 ns after the falling SCK edge (flash
## tV = 8 ns), so nanosecond-level I/O delays do not matter.
set_false_path -to [get_ports {qspi_cs_n qspi_sck qspi_dq[*]}]
set_false_path -from [get_ports {qspi_dq[*]}]

## CDC waivers: these pins are sampled by IOB registers on purpose; their
## timing is the hand-checked I/O window (SRAM, above)
## or a mid-bit sample 30 ns after SCK falls (flash), not a clock-domain crossing.
create_waiver -type CDC -id {CDC-1} -from [get_ports {sram_dq[*]}] -description {SRAM read data, IOB capture on clk_sram_rd, hand-checked window}
create_waiver -type CDC -id {CDC-1} -from [get_ports {qspi_dq[1]}] -description {Flash MISO, sampled 30 ns after SCK falls}
