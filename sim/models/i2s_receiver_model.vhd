--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    I2S Receiver Model
-- Module Name:    i2s_receiver_model
-- Project Name:   First-Person Gate Array
-- Target Devices: Simulation only (Vivado xsim)
-- Tool versions:  Vivado 2025.1 xsim, VHDL-2008
-- Description:    Receiving side of an I2S DAC like the Pmod I2S2's
--                 CS4344, used to check i2s_tx:
--                 - samples SDIN and LRCK on SCLK rising edges; an LRCK
--                   change marks a new channel ('0' left, '1' right);
--                   the first SCLK after the change is the I2S delay
--                   slot, the next 16 carry the sample MSB first, and the
--                   rest must be '0' (16-bit samples, zero padded)
--                 - each channel must last exactly 32 SCLK periods, each
--                   frame exactly 256 MCLK periods (single-speed mode)
--                 - after a whole frame (left then right) it updates
--                   left_o and right_o and increments count_o
--                 Problems are reported (severity error) and counted in
--                 errors_o. The first, partial frame is ignored.
--
-- Dependencies:   VHDL-2008, IEEE.std_logic_1164, IEEE.numeric_std
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First working version
-- Additional Comments:
--                 None.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity i2s_receiver_model is
	generic(
		-- true: assume LRCK was high before time 0, so the first left
		-- channel after reset is decoded (DAC driven from power-up);
		-- false: wait for a real 1 to 0 LRCK edge (lines that start high-Z)
		ASSUME_START: boolean := true
	);
	port(
		mclk_i: in std_logic;
		lrck_i: in std_logic;
		sclk_i: in std_logic;
		sdin_i: in std_logic;
		left_o: out std_logic_vector(15 downto 0); -- Last whole frame, left
		right_o: out std_logic_vector(15 downto 0); -- Last whole frame, right
		count_o: out natural; -- Stereo samples received
		errors_o: out natural -- Format errors
	);
end i2s_receiver_model;

architecture arch of i2s_receiver_model is
	signal format_errors: natural := 0;
	signal ratio_errors: natural := 0;

	function initial_lrck return std_logic is
	begin
		if (ASSUME_START) then
			return '1';
		end if;
		return 'X';
	end function;
begin
	-- Bit decoding on SCLK rising edges
	process
		variable lrck_old: std_logic := initial_lrck;
		variable slots: natural := 0; -- SCLK periods seen in the current channel
		variable word: std_logic_vector(15 downto 0) := (others => '0');
		variable left_word: std_logic_vector(15 downto 0) := (others => '0');
		variable have_left: boolean := false;
		variable started: boolean := false;
		variable count: natural := 0;
		variable errs: natural := 0;
	begin
		wait until rising_edge(sclk_i);
		if ((lrck_i /= '0') and (lrck_i /= '1')) then
			-- Lines not driven (for example high-Z before the PWR_SENSE gate
			-- opens): forget the frame; decoding restarts at the next real
			-- 1 to 0 LRCK edge after the lines are driven
			lrck_old := 'X';
			started := false;
			have_left := false;
			slots := 0;
		elsif ((lrck_old = 'X') and (lrck_i /= lrck_old)) then
			-- First driven value: wait for the next real edge
			lrck_old := lrck_i;
			slots := 0;
		elsif (lrck_i /= lrck_old) then
			-- The previous channel ends here: it must have had 32 slots
			if (started) then
				if (slots /= 31) then
					errs := errs + 1;
					report "I2S model: channel lasted " & integer'image(slots + 1) &
						" SCLK periods, not 32" severity error;
				elsif (lrck_old = '0') then
					left_word := word;
					have_left := true;
				elsif (have_left) then
					left_o <= left_word;
					right_o <= word;
					count := count + 1;
					count_o <= count;
					have_left := false;
				end if;
			end if;
			started := started or (lrck_i = '0');
			slots := 0;
			word := (others => '0');
			lrck_old := lrck_i;
		else
			slots := slots + 1;
			-- Slot 0 is the I2S one-bit delay; slots 1 to 16 carry the sample, MSB first
			if ((slots >= 1) and (slots <= 16)) then
				word(16 - slots) := sdin_i;
			elsif (started and (sdin_i /= '0')) then
				errs := errs + 1;
				report "I2S model: padding bit " & integer'image(slots) & " is not '0'"
					severity error;
			end if;
		end if;
		format_errors <= errs;
	end process;

	-- Clock ratios: per LRCK period, 256 MCLK and 64 SCLK rising edges
	process
		variable mclks, sclks: natural := 0;
		variable frames: natural := 0;
		variable errs: natural := 0;
	begin
		wait on mclk_i, sclk_i, lrck_i;
		if (rising_edge(mclk_i)) then
			mclks := mclks + 1;
		end if;
		if (rising_edge(sclk_i)) then
			sclks := sclks + 1;
		end if;
		if (falling_edge(lrck_i)) then
			-- The first falling edge ends a frame that started at reset
			if (frames >= 1) then
				if (mclks /= 256) then
					errs := errs + 1;
					report "I2S model: " & integer'image(mclks) & " MCLK per frame" severity error;
				end if;
				if (sclks /= 64) then
					errs := errs + 1;
					report "I2S model: " & integer'image(sclks) & " SCLK per frame" severity error;
				end if;
			end if;
			frames := frames + 1;
			mclks := 0;
			sclks := 0;
		end if;
		ratio_errors <= errs;
	end process;

	errors_o <= format_errors + ratio_errors;
end arch;
