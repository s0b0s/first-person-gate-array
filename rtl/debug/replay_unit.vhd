--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Replay Unit
-- Module Name:    replay_unit
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    Deterministic replay: records the per-frame input
--                 snapshots and game-state CRCs into SRAM, and can play a
--                 recorded (or uploaded) snapshot stream back into the game
--                 in place of the keyboard and mouse. The same stream gives
--                 the same CRC every frame on the board, in simulation and
--                 in the Python model, which proves they behave alike.
--                 Modes (mode_i, taken at the first frame after a change;
--                 a change restarts the frame counter at 0):
--                   0 pass-through  snap_out = snap_in, one clock later
--                   1 record        pass-through, and frame k's snapshot
--                                   goes to REPLAY_BASE + 5 k (5 bytes,
--                                   little endian)
--                   2 play          frame k's snapshot is read back from
--                                   REPLAY_BASE + 5 k and replaces
--                                   snap_in; snap_in_valid_i still marks
--                                   the frame. The next frame's bytes are
--                                   prefetched right after a frame is
--                                   delivered, so the game never waits.
--                 In modes 1 and 2 each CRC (crc_valid_i, once per frame
--                 at render start) goes to CRC_BASE + 4 k, little endian.
--                 After MAX_FRAMES frames recording stops and play falls
--                 back to pass-through until the mode changes.
--                 The PC uploads or downloads both areas with the UART
--                 'S' and 'M' commands (tools/uart/).
--                 SRAM access is a byte-serial engine on an arbiter master
--                 port: snapshot writes (5), CRC writes (4), prefetch reads
--                 (5). A CRC that arrives while another job runs waits in
--                 a one-entry buffer.
--                 Coding: two-segment style, registers in record r.
--                 Clock domain: clk_i (system). Latency: pass-through 1
--                 clock; play delivers 1 clock after snap_in_valid_i when
--                 the prefetch is done (it takes about 30 clocks).
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std, hw_pkg,
--                 game_pkg
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - Stage 3
-- Additional Comments:
--                 None.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.hw_pkg.all;
use work.game_pkg.all;

entity replay_unit is
	generic(
		MAX_FRAMES: positive := 3600 -- 60 s at 60 frames per second
	);
	port(
		clk_i: in std_logic; -- System clock
		rst_i: in std_logic; -- Asynchronous reset, active high
		mode_i: in std_logic_vector(1 downto 0); -- 0 pass-through, 1 record, 2 play
		frames_o: out std_logic_vector(15 downto 0); -- Frames recorded or played
		snap_in_i: in std_logic_vector(SNAP_BITS - 1 downto 0); -- From ps2_input
		snap_in_valid_i: in std_logic; -- Pulse once per frame
		snap_out_o: out std_logic_vector(SNAP_BITS - 1 downto 0); -- To the game core
		snap_out_valid_o: out std_logic; -- Pulse
		crc_i: in std_logic_vector(31 downto 0); -- Game state CRC
		crc_valid_i: in std_logic; -- Pulse once per frame
		-- SRAM arbiter master port
		m_req_o: out std_logic;
		m_we_o: out std_logic;
		m_addr_o: out std_logic_vector(18 downto 0);
		m_wdata_o: out std_logic_vector(7 downto 0);
		m_gnt_i: in std_logic;
		m_rvalid_i: in std_logic;
		m_rdata_i: in std_logic_vector(7 downto 0)
	);
end replay_unit;

architecture arch of replay_unit is
	constant CRC_BASE: natural := 16#75800#; -- Just past the snapshot log (0x71000 + 5 x 3600 = 0x75650)

	-- SRAM engine jobs
	type job_t is (J_IDLE, J_SNAP, J_CRC, J_READ);

	type regs_t is record
		mode: std_logic_vector(1 downto 0); -- Mode in effect
		mode_old: std_logic_vector(1 downto 0); -- mode_i last clock
		restart: std_logic; -- Mode changed: start over at the next frame
		frame: unsigned(15 downto 0); -- Snapshot frame counter
		crc_frame: unsigned(15 downto 0); -- CRC frame counter
		out_snap: std_logic_vector(SNAP_BITS - 1 downto 0);
		out_valid: std_logic;
		wait_deliver: std_logic; -- Play: frame tick seen, prefetch not done yet
		-- Snapshot write buffer
		snap: std_logic_vector(SNAP_BITS - 1 downto 0);
		snap_pend: std_logic;
		snap_addr: unsigned(18 downto 0);
		-- CRC write buffer
		crc: std_logic_vector(31 downto 0);
		crc_pend: std_logic;
		crc_addr: unsigned(18 downto 0);
		-- Play prefetch buffer
		fetch: std_logic_vector(SNAP_BITS - 1 downto 0);
		fetch_pend: std_logic; -- A prefetch should run
		fetch_ok: std_logic; -- fetch holds the next frame's snapshot
		fetch_addr: unsigned(18 downto 0);
		-- Engine
		job: job_t;
		k: unsigned(2 downto 0); -- Bytes issued
		got: unsigned(2 downto 0); -- Read bytes returned
	end record;

	constant REGS_INIT: regs_t := (
		mode => "00",
		mode_old => "00",
		restart => '0',
		frame => (others => '0'),
		crc_frame => (others => '0'),
		out_snap => (others => '0'),
		out_valid => '0',
		wait_deliver => '0',
		snap => (others => '0'),
		snap_pend => '0',
		snap_addr => (others => '0'),
		crc => (others => '0'),
		crc_pend => '0',
		crc_addr => (others => '0'),
		fetch => (others => '0'),
		fetch_pend => '0',
		fetch_ok => '0',
		fetch_addr => (others => '0'),
		job => J_IDLE,
		k => (others => '0'),
		got => (others => '0')
	);

	signal r: regs_t := REGS_INIT;
	signal r_next: regs_t;

	-- SRAM address of frame f's snapshot (5 f) and CRC (4 f)
	function snap_address(f: unsigned(15 downto 0)) return unsigned is
	begin
		return to_unsigned(REPLAY_BASE, 19) + shift_left(resize(f, 19), 2) + resize(f, 19);
	end function;

	function crc_address(f: unsigned(15 downto 0)) return unsigned is
	begin
		return to_unsigned(CRC_BASE, 19) + shift_left(resize(f, 19), 2);
	end function;
begin
	process(r, mode_i, snap_in_i, snap_in_valid_i, crc_i, crc_valid_i, m_gnt_i, m_rvalid_i,
		m_rdata_i)
		variable v: regs_t;
		variable active: boolean;
	begin
		v := r;
		v.out_valid := '0';
		v.mode_old := mode_i;

		-- A mode change takes effect at the next frame; a new play mode
		-- starts prefetching frame 0 at once
		if (mode_i /= r.mode_old) then
			v.restart := '1';
			v.fetch_ok := '0';
			v.fetch_pend := '0';
			v.wait_deliver := '0';
			if (mode_i = "10") then
				v.fetch_pend := '1';
				v.fetch_addr := snap_address(to_unsigned(0, 16));
			end if;
		end if;

		-- Frame tick
		if (snap_in_valid_i = '1') then
			if (v.restart = '1') then
				v.restart := '0';
				v.mode := mode_i;
				v.frame := (others => '0');
				v.crc_frame := (others => '0');
			end if;
			active := v.frame < MAX_FRAMES; -- A full log falls back to pass-through
			if ((v.mode = "10") and active) then
				-- Play: deliver the prefetched snapshot (or as soon as it
				-- arrives)
				if (v.fetch_ok = '1') then
					-- Deliver frame f, prefetch frame f + 1
					v.out_snap := v.fetch;
					v.out_valid := '1';
					v.fetch_ok := '0';
					v.fetch_pend := '1';
					v.fetch_addr := snap_address(v.frame + 1);
					v.frame := v.frame + 1;
				else
					v.wait_deliver := '1';
				end if;
			else
				v.out_snap := snap_in_i;
				v.out_valid := '1';
				if ((v.mode = "01") and active) then
					v.snap := snap_in_i;
					v.snap_pend := '1';
					v.snap_addr := snap_address(v.frame);
					v.frame := v.frame + 1;
				end if;
			end if;
		end if;

		-- A late prefetch completes a delivery that is waiting
		if ((r.wait_deliver = '1') and (r.fetch_ok = '1')) then
			v.wait_deliver := '0';
			v.out_snap := r.fetch;
			v.out_valid := '1';
			v.fetch_ok := '0';
			v.frame := r.frame + 1;
			v.fetch_pend := '1';
			v.fetch_addr := snap_address(r.frame + 1);
		end if;

		-- CRC of this frame
		if ((crc_valid_i = '1') and (r.mode /= "00") and (r.crc_frame < MAX_FRAMES)) then
			v.crc := crc_i;
			v.crc_pend := '1';
			v.crc_addr := crc_address(r.crc_frame);
			v.crc_frame := r.crc_frame + 1;
		end if;

		-- SRAM engine: one job at a time, byte by byte
		case r.job is
			when J_IDLE =>
				v.k := (others => '0');
				v.got := (others => '0');
				if (r.snap_pend = '1') then
					v.job := J_SNAP;
				elsif (r.crc_pend = '1') then
					v.job := J_CRC;
				elsif ((r.fetch_pend = '1') and (r.fetch_ok = '0')) then
					v.job := J_READ;
				end if;
			when J_SNAP =>
				if (m_gnt_i = '1') then
					v.k := r.k + 1;
					if (r.k = 4) then -- Fifth and last snapshot byte granted
						v.snap_pend := '0';
						v.job := J_IDLE;
					end if;
				end if;
			when J_CRC =>
				if (m_gnt_i = '1') then
					v.k := r.k + 1;
					if (r.k = 3) then
						v.crc_pend := '0';
						v.job := J_IDLE;
					end if;
				end if;
			when J_READ =>
				-- k stops at 5 (all reads issued) while the data comes back
				if ((m_gnt_i = '1') and (r.k /= 5)) then
					v.k := r.k + 1;
				end if;
				if (m_rvalid_i = '1') then
					-- Bytes return in order, lowest first
					v.fetch := m_rdata_i & r.fetch(SNAP_BITS - 1 downto 8);
					v.got := r.got + 1;
					if (r.got = 4) then
						v.job := J_IDLE;
						v.fetch_pend := '0';
						-- A mode change during the read cancels it
						if ((r.fetch_pend = '1') and (mode_i = r.mode_old)) then
							v.fetch_ok := '1';
						end if;
					end if;
				end if;
		end case;
		r_next <= v;
	end process;

	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			r <= REGS_INIT;
		elsif rising_edge(clk_i) then
			r <= r_next;
		end if;
	end process;

	-- SRAM master outputs from the current job
	process(r)
	begin
		m_req_o <= '0';
		m_we_o <= '0';
		m_addr_o <= (others => '0');
		m_wdata_o <= (others => '0');
		case r.job is
			when J_SNAP =>
				m_req_o <= '1';
				m_we_o <= '1';
				m_addr_o <= std_logic_vector(r.snap_addr + resize(r.k, 19));
				m_wdata_o <= r.snap(8 * to_integer(r.k) + 7 downto 8 * to_integer(r.k));
			when J_CRC =>
				m_req_o <= '1';
				m_we_o <= '1';
				m_addr_o <= std_logic_vector(r.crc_addr + resize(r.k, 19));
				-- Byte k, low byte first; k(1 downto 0) keeps the slice in range (k is 0..3 here)
				m_wdata_o <= r.crc(8 * to_integer(r.k(1 downto 0)) + 7 downto 8 * to_integer(r.k(1 downto 0)));
			when J_READ =>
				if (r.k /= 5) then
					m_req_o <= '1';
				end if;
				m_addr_o <= std_logic_vector(r.fetch_addr + resize(r.k, 19));
			when others =>
				null;
		end case;
	end process;

	snap_out_o <= r.out_snap;
	snap_out_valid_o <= r.out_valid;
	frames_o <= std_logic_vector(r.frame);
end arch;
