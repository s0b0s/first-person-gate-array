--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    I2S Testbench
-- Module Name:    tb_i2s
-- Project Name:   First-Person Gate Array
-- Target Devices: Simulation only (Vivado xsim)
-- Tool versions:  Vivado 2025.1 xsim, VHDL-2008
-- Description:    Self-checking testbench for i2s_tx and tone_gen against
--                 i2s_receiver_model (which checks the I2S frame format
--                 and the MCLK / SCLK / LRCK ratios on every frame).
--                 1. Known samples: a list of stereo pairs (including
--                    0, -1, full scale positive and negative, alternating
--                    bits) is presented one pair per sample_req_o; every
--                    pair must come out of the receiver bit exact and in
--                    order.
--                 2. Tone: tone_gen (440 Hz, quarter volume) drives both
--                    channels; over 600 received samples the peaks must be
--                    within 0.1% of +/-8192 and the mean period between
--                    upward zero crossings 110.97 samples (48,828.125 /
--                    440) within half a sample.
--                 3. tone_gen disabled gives silence.
--                 Also measures the LRCK rate (48.828 kHz).
--
-- Dependencies:   VHDL-2008, IEEE.std_logic_1164, IEEE.numeric_std, tb_pkg,
--                 i2s_tx, tone_gen, i2s_receiver_model
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
use work.tb_pkg.all;

entity tb_i2s is
end tb_i2s;

architecture arch of tb_i2s is
	component i2s_tx is
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			left_i: in std_logic_vector(15 downto 0);
			right_i: in std_logic_vector(15 downto 0);
			sample_req_o: out std_logic;
			mclk_o: out std_logic;
			lrck_o: out std_logic;
			sclk_o: out std_logic;
			sdin_o: out std_logic
		);
	end component;
	component tone_gen is
		generic(
			CLK_HZ: natural := 100_000_000;
			FREQ_HZ: natural := 440
		);
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			enable_i: in std_logic;
			step_i: in std_logic;
			sample_o: out std_logic_vector(15 downto 0)
		);
	end component;
	component i2s_receiver_model is
		port(
			mclk_i: in std_logic;
			lrck_i: in std_logic;
			sclk_i: in std_logic;
			sdin_i: in std_logic;
			left_o: out std_logic_vector(15 downto 0);
			right_o: out std_logic_vector(15 downto 0);
			count_o: out natural;
			errors_o: out natural
		);
	end component;

	constant PERIOD: time := 10 ns;
	constant NPAIRS: natural := 12;
	constant TONE_SAMPLES: natural := 600;
	type word_list_t is array (0 to NPAIRS - 1) of std_logic_vector(15 downto 0);
	constant LEFTS: word_list_t := (x"0000", x"FFFF", x"7FFF", x"8000", x"5555", x"AAAA",
		x"0001", x"8001", x"1234", x"FEDC", x"00FF", x"FF00");
	constant RIGHTS: word_list_t := (x"FFFF", x"0000", x"8000", x"7FFF", x"AAAA", x"5555",
		x"C3A5", x"3C5A", x"4321", x"0F0F", x"F0F0", x"0100");
	shared variable chk: checker_t;

	signal clk: std_logic := '0';
	signal rst: std_logic := '1';
	signal done: boolean := false;

	signal left, right: std_logic_vector(15 downto 0) := (others => '0');
	signal list_left, list_right: std_logic_vector(15 downto 0) := LEFTS(0);
	signal use_tone: boolean := false;
	signal sample_req: std_logic;
	signal mclk, lrck, sclk, sdin: std_logic;
	signal tone_en: std_logic := '0';
	signal tone: std_logic_vector(15 downto 0);
	signal rx_left, rx_right: std_logic_vector(15 downto 0);
	signal rx_count: natural := 0;
	signal rx_errors: natural;
begin
	dut: i2s_tx
		port map (
			clk_i => clk,
			rst_i => rst,
			left_i => left,
			right_i => right,
			sample_req_o => sample_req,
			mclk_o => mclk,
			lrck_o => lrck,
			sclk_o => sclk,
			sdin_o => sdin
		);

	tgen: tone_gen
		port map (
			clk_i => clk,
			rst_i => rst,
			enable_i => tone_en,
			step_i => sample_req,
			sample_o => tone
		);

	rx: i2s_receiver_model
		port map (
			mclk_i => mclk,
			lrck_i => lrck,
			sclk_i => sclk,
			sdin_i => sdin,
			left_o => rx_left,
			right_o => rx_right,
			count_o => rx_count,
			errors_o => rx_errors
		);

	left <= tone when use_tone else list_left;
	right <= tone when use_tone else list_right;

	-- Clock
	process
	begin
		if (done) then
			wait;
		end if;
		clk <= '0';
		wait for PERIOD / 2;
		clk <= '1';
		wait for PERIOD / 2;
	end process;

	-- Reset
	process
	begin
		rst <= '1';
		wait for 10.5 * PERIOD;
		rst <= '0';
		wait;
	end process;

	-- Source of the known pairs: pair k + 1 goes out after request k
	process
		variable k: natural := 0;
	begin
		list_left <= LEFTS(0);
		list_right <= RIGHTS(0);
		while (k < NPAIRS - 1) loop
			wait until rising_edge(clk);
			if (sample_req = '1') then
				k := k + 1;
				list_left <= LEFTS(k);
				list_right <= RIGHTS(k);
			end if;
		end loop;
		wait;
	end process;

	-- Stimulus and checks
	process
		variable t0: time;
		type samples_t is array (0 to TONE_SAMPLES - 1) of integer;
		variable s: samples_t;
		variable smax, smin: integer;
		variable first_up, last_up, ups: integer;
		variable n0: natural;
	begin
		wait until (rst = '0');

		-- 1. Frame 0 carries the reset value (0, 0); frame f >= 1 carries
		-- pair f - 1 (it is taken at the end of frame f - 1)
		wait until (rx_count = 1);
		chk.check((rx_left = x"0000") and (rx_right = x"0000"), "frame 0 is silence");
		for k in 0 to NPAIRS - 1 loop
			wait until (rx_count = k + 2);
			chk.check(rx_left = LEFTS(k), "pair " & integer'image(k) & " left " &
				to_hex(rx_left) & " want " & to_hex(LEFTS(k)));
			chk.check(rx_right = RIGHTS(k), "pair " & integer'image(k) & " right " &
				to_hex(rx_right) & " want " & to_hex(RIGHTS(k)));
		end loop;

		-- LRCK rate: 10 frames of 2048 clocks = 204.8 us
		wait until falling_edge(lrck);
		t0 := now;
		for i in 1 to 10 loop
			wait until falling_edge(lrck);
		end loop;
		chk.check(now - t0 = 204_800 ns, "10 LRCK periods took " & time'image(now - t0));

		-- 2. Tone on both channels
		use_tone <= true;
		tone_en <= '1';
		n0 := rx_count + 3; -- Skip the frames still holding list values
		wait until (rx_count = n0);
		for i in 0 to TONE_SAMPLES - 1 loop
			wait until (rx_count = n0 + i + 1);
			s(i) := to_integer(signed(rx_left));
			chk.check(rx_left = rx_right, "tone is the same on both channels");
		end loop;
		smax := s(0);
		smin := s(0);
		ups := 0;
		first_up := -1;
		last_up := -1;
		for i in 1 to TONE_SAMPLES - 1 loop
			if (s(i) > smax) then
				smax := s(i);
			end if;
			if (s(i) < smin) then
				smin := s(i);
			end if;
			if ((s(i - 1) < 0) and (s(i) >= 0)) then
				if (first_up < 0) then
					first_up := i;
				end if;
				last_up := i;
				ups := ups + 1;
			end if;
		end loop;
		chk.check((smax >= 8184) and (smax <= 8192), "tone peak " & integer'image(smax));
		chk.check((smin <= -8184) and (smin >= -8192), "tone trough " & integer'image(smin));
		chk.check(ups >= 4, "tone has upward zero crossings: " & integer'image(ups));
		if (ups >= 2) then
			-- 110.97 samples per period: allow 110.47 .. 111.47
			chk.check((100 * (last_up - first_up) >= 11047 * (ups - 1)) and
				(100 * (last_up - first_up) <= 11147 * (ups - 1)),
				"tone period: " & integer'image(last_up - first_up) & " samples over " &
				integer'image(ups - 1) & " periods");
		end if;

		-- 3. Disabled tone is silence
		tone_en <= '0';
		n0 := rx_count + 3;
		wait until (rx_count = n0);
		chk.check((rx_left = x"0000") and (rx_right = x"0000"), "disabled tone is silent");

		chk.check(rx_errors = 0, "I2S format errors: " & integer'image(rx_errors));
		done <= true;
		tb_finish("tb_i2s", chk.checks, chk.errors);
		wait;
	end process;
end arch;
