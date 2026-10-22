--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Clocks and Resets
-- Module Name:    clock_reset
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    One MMCM makes every clock from the 12 MHz oscillator:
--                   VCO   = 12 MHz x MULT_F           (600 MHz at 50.0)
--                   clk_sys     = VCO / 6             (100 MHz)
--                   clk_pix     = VCO / 24            (25 MHz)
--                   clk_sram_rd = VCO / 6, +37.5 deg  (100 MHz, 1.04 ns late)
--                 The SRAM capture clock phase is 37.5 deg instead of the
--                 planned 36 deg because the MMCM's static phase step for
--                 a /6 output is 45 / 6 = 7.5 deg (1/8 of a VCO period).
--                 MULT_F = 50.375 gives the exact-timing VGA fallback
--                 (25.19 MHz pixel, 100.75 MHz system, VCO 604.5 MHz).
--                 Each output drives a BUFG. Resets: rst_sys_o and
--                 rst_pix_o assert asynchronously while the MMCM is not
--                 locked or btn_rst_i is high, and release synchronously
--                 in their own domain (reset_sync).
--                 Clock domains: produces clk_sys and clk_pix (unrelated
--                 for timing) and clk_sram_rd (related to clk_sys).
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, UNISIM, UNISIM (MMCME2_BASE,
--                 BUFG), reset_sync
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First working version
-- Additional Comments:
--                 The VCO must stay inside 600 to 1200 MHz, so MULT_F
--                 must be 50.0 to 100.0 with this 12 MHz input.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
library UNISIM;
use UNISIM.vcomponents.all;

entity clock_reset is
	generic(
		MULT_F: real := 50.0 -- VCO = 12 MHz x MULT_F (50.0 or 50.375)
	);
	port(
		clk12_i: in std_logic; -- 12 MHz oscillator (L17)
		btn_rst_i: in std_logic; -- Optional manual reset, active high
		clk_sys_o: out std_logic; -- 100 MHz system clock
		clk_pix_o: out std_logic; -- 25 MHz pixel clock
		clk_sram_rd_o: out std_logic; -- 100 MHz, +37.5 deg, SRAM read capture
		rst_sys_o: out std_logic; -- Reset synchronized to clk_sys
		rst_pix_o: out std_logic; -- Reset synchronized to clk_pix
		locked_o: out std_logic -- MMCM locked
	);
end clock_reset;

architecture arch of clock_reset is
	component reset_sync is
		generic(
			STAGES: positive := 3
		);
		port(
			clk_i: in std_logic;
			arst_i: in std_logic;
			rst_o: out std_logic
		);
	end component;
	signal clk_fb: std_logic;
	signal clk_sys_mmcm: std_logic;
	signal clk_pix_mmcm: std_logic;
	signal clk_rd_mmcm: std_logic;
	signal clk_sys: std_logic;
	signal clk_pix: std_logic;
	signal locked: std_logic;
	signal arst: std_logic;
begin
	cmt: MMCME2_BASE
		generic map (
			BANDWIDTH => "OPTIMIZED",
			CLKIN1_PERIOD => 83.333, -- 12 MHz
			DIVCLK_DIVIDE => 1, -- 12 MHz / 2 would be under the 10 MHz PFD minimum
			CLKFBOUT_MULT_F => MULT_F, -- VCO = 12 MHz x 50 = 600 MHz
			CLKFBOUT_PHASE => 0.0,
			CLKOUT0_DIVIDE_F => 6.0, -- clk_sys
			CLKOUT0_DUTY_CYCLE => 0.5,
			CLKOUT0_PHASE => 0.0,
			CLKOUT1_DIVIDE => 24, -- clk_pix
			CLKOUT1_DUTY_CYCLE => 0.5,
			CLKOUT1_PHASE => 0.0,
			CLKOUT2_DIVIDE => 6, -- clk_sram_rd
			CLKOUT2_DUTY_CYCLE => 0.5,
			CLKOUT2_PHASE => 37.5, -- +1.04 ns (7.5 deg steps at /6) for the SRAM read capture
			CLKOUT3_DIVIDE => 1,
			CLKOUT4_DIVIDE => 1,
			CLKOUT5_DIVIDE => 1,
			CLKOUT6_DIVIDE => 1,
			CLKOUT4_CASCADE => FALSE,
			REF_JITTER1 => 0.010,
			STARTUP_WAIT => FALSE
		)
		port map (
			CLKOUT0 => clk_sys_mmcm,
			CLKOUT0B => open,
			CLKOUT1 => clk_pix_mmcm,
			CLKOUT1B => open,
			CLKOUT2 => clk_rd_mmcm,
			CLKOUT2B => open,
			CLKOUT3 => open,
			CLKOUT3B => open,
			CLKOUT4 => open,
			CLKOUT5 => open,
			CLKOUT6 => open,
			CLKFBOUT => clk_fb,
			CLKFBOUTB => open,
			LOCKED => locked,
			CLKIN1 => clk12_i,
			PWRDWN => '0',
			RST => '0',
			CLKFBIN => clk_fb
		);

	bufg_sys: BUFG
		port map (
			I => clk_sys_mmcm,
			O => clk_sys
		);

	bufg_pix: BUFG
		port map (
			I => clk_pix_mmcm,
			O => clk_pix
		);

	bufg_rd: BUFG
		port map (
			I => clk_rd_mmcm,
			O => clk_sram_rd_o
		);

	arst <= (not locked) or btn_rst_i; -- Both domains stay in reset until the MMCM locks

	rsync_sys: reset_sync
		port map (
			clk_i => clk_sys,
			arst_i => arst,
			rst_o => rst_sys_o
		);

	rsync_pix: reset_sync
		port map (
			clk_i => clk_pix,
			arst_i => arst,
			rst_o => rst_pix_o
		);

	clk_sys_o <= clk_sys;
	clk_pix_o <= clk_pix;
	locked_o <= locked;
end arch;
