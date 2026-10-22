--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    PS/2 Host
-- Module Name:    ps2_host
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    PS/2 host for one device (keyboard or mouse):
--                 - both raw lines go through 3-stage synchronizers that
--                   power up '1' (the bus idles high, so no false edge
--                   after configuration)
--                 - glitch filter: the lines are sampled every
--                   SAMPLE_CYCLES clocks (1 MHz at 100 MHz) and a line
--                   takes a new level only after 4 equal samples in a
--                   row. A clean edge is delayed 4 to 5 us, far less
--                   than the 30 us or more of a half bit, and both lines
--                   are delayed alike, so data is still stable at each
--                   filtered clock edge
--                 - falling edges of the filtered clock drive ps2_rx and
--                   ps2_tx; the receiver is off while transmitting
--                 Outputs are pull requests ('1' = drive the line low);
--                 the top level turns them into open drain ('0' or 'Z',
--                 never '1'). en_i = '0' (PWR_SENSE gate off) clears the
--                 receiver and transmitter and releases both lines.
--                 Clock domain: clk_i (system). Line inputs are
--                 asynchronous.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std,
--                 synchronizer, ps2_rx, ps2_tx
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

entity ps2_host is
	generic(
		SAMPLE_CYCLES: positive := 100; -- Clocks per glitch-filter sample
		RX_TIMEOUT_CYCLES: positive := 200_000; -- 2 ms: abandon a partial frame
		TX_INHIBIT_CYCLES: positive := 15_000; -- 150 us: clock low before sending
		TX_RELEASE_CYCLES: positive := 1_000; -- 10 us: data low before clock release
		TX_TIMEOUT_CYCLES: positive := 2_000_000 -- 20 ms: whole send limit
	);
	port(
		clk_i: in std_logic; -- System clock
		rst_i: in std_logic; -- Asynchronous reset, active high
		en_i: in std_logic; -- '0' = idle and release the lines
		ps2_clk_i: in std_logic; -- Raw clock line
		ps2_dat_i: in std_logic; -- Raw data line
		clk_pull_o: out std_logic; -- '1' = drive the clock line low
		dat_pull_o: out std_logic; -- '1' = drive the data line low
		rx_data_o: out std_logic_vector(7 downto 0); -- Received byte
		rx_valid_o: out std_logic; -- Pulse: good byte received
		rx_parity_err_o: out std_logic; -- Pulse: parity error
		rx_frame_err_o: out std_logic; -- Pulse: start or stop bit error
		rx_timeout_o: out std_logic; -- Pulse: partial frame abandoned
		tx_data_i: in std_logic_vector(7 downto 0); -- Byte to send
		tx_valid_i: in std_logic; -- Byte present
		tx_ready_o: out std_logic; -- Byte taken if tx_valid_i
		tx_done_o: out std_logic; -- Pulse: device acknowledged
		tx_err_o: out std_logic -- Pulse: send timed out
	);
end ps2_host;

architecture arch of ps2_host is
	component synchronizer is
		generic(
			STAGES: positive := 3;
			INIT: std_logic := '0'
		);
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			async_i: in std_logic;
			sync_o: out std_logic
		);
	end component;
	component ps2_rx is
		generic(
			TIMEOUT_CYCLES: positive := 200_000
		);
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			en_i: in std_logic;
			fall_i: in std_logic;
			dat_i: in std_logic;
			data_o: out std_logic_vector(7 downto 0);
			valid_o: out std_logic;
			parity_err_o: out std_logic;
			frame_err_o: out std_logic;
			timeout_o: out std_logic
		);
	end component;
	component ps2_tx is
		generic(
			INHIBIT_CYCLES: positive := 15_000;
			RELEASE_CYCLES: positive := 1_000;
			TIMEOUT_CYCLES: positive := 2_000_000
		);
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			en_i: in std_logic;
			data_i: in std_logic_vector(7 downto 0);
			valid_i: in std_logic;
			ready_o: out std_logic;
			fall_i: in std_logic;
			clk_lvl_i: in std_logic;
			dat_lvl_i: in std_logic;
			pull_clk_o: out std_logic;
			pull_dat_o: out std_logic;
			busy_o: out std_logic;
			done_o: out std_logic;
			err_o: out std_logic
		);
	end component;

	signal clk_sync, dat_sync: std_logic;
	signal tick_count: natural range 0 to SAMPLE_CYCLES - 1 := 0;
	signal clk_hist, dat_hist: std_logic_vector(3 downto 0) := (others => '1');
	signal clk_lvl, dat_lvl: std_logic := '1'; -- Filtered levels
	signal clk_lvl_old: std_logic := '1';
	signal fall: std_logic;
	signal tx_busy: std_logic;
	signal rx_en: std_logic;
	signal tx_pull_clk, tx_pull_dat: std_logic;
begin
	sync_clk: synchronizer
		generic map (
			INIT => '1'
		)
		port map (
			clk_i => clk_i,
			rst_i => rst_i,
			async_i => ps2_clk_i,
			sync_o => clk_sync
		);

	sync_dat: synchronizer
		generic map (
			INIT => '1'
		)
		port map (
			clk_i => clk_i,
			rst_i => rst_i,
			async_i => ps2_dat_i,
			sync_o => dat_sync
		);

	-- Glitch filter: take a new level only after 4 equal samples
	process(clk_i, rst_i)
		variable clk_h, dat_h: std_logic_vector(3 downto 0);
	begin
		if (rst_i = '1') then
			tick_count <= 0;
			clk_hist <= (others => '1');
			dat_hist <= (others => '1');
			clk_lvl <= '1';
			dat_lvl <= '1';
			clk_lvl_old <= '1';
		elsif rising_edge(clk_i) then
			clk_lvl_old <= clk_lvl;
			if (tick_count = SAMPLE_CYCLES - 1) then
				tick_count <= 0;
				clk_h := clk_hist(2 downto 0) & clk_sync;
				dat_h := dat_hist(2 downto 0) & dat_sync;
				clk_hist <= clk_h;
				dat_hist <= dat_h;
				if (clk_h = "0000") then
					clk_lvl <= '0';
				elsif (clk_h = "1111") then
					clk_lvl <= '1';
				end if;
				if (dat_h = "0000") then
					dat_lvl <= '0';
				elsif (dat_h = "1111") then
					dat_lvl <= '1';
				end if;
			else
				tick_count <= tick_count + 1;
			end if;
		end if;
	end process;

	fall <= clk_lvl_old and (not clk_lvl);
	rx_en <= en_i and (not tx_busy); -- While sending, the clock edges carry the bits

	rx: ps2_rx
		generic map (
			TIMEOUT_CYCLES => RX_TIMEOUT_CYCLES
		)
		port map (
			clk_i => clk_i,
			rst_i => rst_i,
			en_i => rx_en,
			fall_i => fall,
			dat_i => dat_lvl,
			data_o => rx_data_o,
			valid_o => rx_valid_o,
			parity_err_o => rx_parity_err_o,
			frame_err_o => rx_frame_err_o,
			timeout_o => rx_timeout_o
		);

	tx: ps2_tx
		generic map (
			INHIBIT_CYCLES => TX_INHIBIT_CYCLES,
			RELEASE_CYCLES => TX_RELEASE_CYCLES,
			TIMEOUT_CYCLES => TX_TIMEOUT_CYCLES
		)
		port map (
			clk_i => clk_i,
			rst_i => rst_i,
			en_i => en_i,
			data_i => tx_data_i,
			valid_i => tx_valid_i,
			ready_o => tx_ready_o,
			fall_i => fall,
			clk_lvl_i => clk_lvl,
			dat_lvl_i => dat_lvl,
			pull_clk_o => tx_pull_clk,
			pull_dat_o => tx_pull_dat,
			busy_o => tx_busy,
			done_o => tx_done_o,
			err_o => tx_err_o
		);

	clk_pull_o <= en_i and tx_pull_clk;
	dat_pull_o <= en_i and tx_pull_dat;
end arch;
