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
-- Description:    Deterministic replay: records per-frame input snapshots
--                 and game-state CRCs into SRAM, and plays a recorded (or
--                 uploaded) snapshot stream back in place of keyboard and
--                 mouse. The same stream gives the same CRCs on the board,
--                 in simulation and in the Python model.
--                 Modes (mode_i, taken at the next frame; a change
--                 restarts the frame counter at 0):
--                   0 pass-through  snap_out = snap_in, one clock later
--                   1 record        pass-through; frame k's snapshot goes
--                                   to REPLAY_BASE + 5 k (little endian)
--                   2 play          frame k's snapshot is read from
--                                   REPLAY_BASE + 5 k and replaces
--                                   snap_in (snap_in_valid_i still marks
--                                   the frame); the next one is
--                                   prefetched so the game never waits.
--                 In modes 1 and 2 each CRC goes to CRC_BASE + 4 k. After
--                 MAX_FRAMES, recording stops and play falls back to
--                 pass-through until the mode changes. The PC moves both
--                 areas with the UART 'S' and 'M' commands.
--                 SRAM: a byte-serial engine on an arbiter master port
--                 (snapshot writes, CRC writes, prefetch reads); a CRC
--                 arriving during another job waits in a one-entry buffer.
--                 Variables carry next mode, frame, restart and fetch_ok
--                 because a frame tick reads them in the same clock a mode
--                 change or late prefetch updates them.
--                 Clock domain: clk_i (system). Latency: pass-through 1
--                 clock; play 1 clock after snap_in_valid_i once the
--                 prefetch (about 30 clocks) is done.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std, hw_pkg,
--                 game_pkg
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First working version
-- Revision 1.01 - Plain signals instead of records; one-process state machine
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
	type job_state_type is (JOB_IDLE, JOB_SNAP, JOB_CRC, JOB_READ);
	signal job_state: job_state_type := JOB_IDLE;

	signal mode: std_logic_vector(1 downto 0) := "00"; -- Mode in effect
	signal mode_old: std_logic_vector(1 downto 0) := "00"; -- mode_i last clock
	signal restart: std_logic := '0'; -- Mode changed: start over at the next frame
	signal frame: unsigned(15 downto 0) := (others => '0'); -- Snapshot frame counter
	signal crc_frame: unsigned(15 downto 0) := (others => '0'); -- CRC frame counter
	signal out_snap: std_logic_vector(SNAP_BITS - 1 downto 0) := (others => '0');
	signal out_valid: std_logic := '0';
	signal wait_deliver: std_logic := '0'; -- Play: frame tick seen, prefetch not done yet
	-- Snapshot write buffer
	signal snap: std_logic_vector(SNAP_BITS - 1 downto 0) := (others => '0');
	signal snap_pend: std_logic := '0';
	signal snap_addr: unsigned(18 downto 0) := (others => '0');
	-- CRC write buffer
	signal crc: std_logic_vector(31 downto 0) := (others => '0');
	signal crc_pend: std_logic := '0';
	signal crc_addr: unsigned(18 downto 0) := (others => '0');
	-- Play prefetch buffer
	signal fetch: std_logic_vector(SNAP_BITS - 1 downto 0) := (others => '0');
	signal fetch_pend: std_logic := '0'; -- A prefetch should run
	signal fetch_ok: std_logic := '0'; -- fetch holds the next frame's snapshot
	signal fetch_addr: unsigned(18 downto 0) := (others => '0');
	-- Engine byte counters
	signal k: unsigned(2 downto 0) := (others => '0'); -- Bytes issued
	signal got: unsigned(2 downto 0) := (others => '0'); -- Read bytes returned

	-- SRAM address of frame f's snapshot: REPLAY_BASE + 5 f
	function snap_address(f: unsigned(15 downto 0)) return unsigned is
	begin
		return to_unsigned(REPLAY_BASE, 19) + shift_left(resize(f, 19), 2) + resize(f, 19);
	end function;
begin
	process(clk_i, rst_i)
		-- Next values of the registers that later steps read back in the same clock
		variable restart_n: std_logic;
		variable mode_n: std_logic_vector(1 downto 0);
		variable frame_n: unsigned(15 downto 0);
		variable fetch_ok_n: std_logic;
	begin
		if (rst_i = '1') then
			job_state <= JOB_IDLE;
			mode <= "00";
			mode_old <= "00";
			restart <= '0';
			frame <= (others => '0');
			crc_frame <= (others => '0');
			out_snap <= (others => '0');
			out_valid <= '0';
			wait_deliver <= '0';
			snap <= (others => '0');
			snap_pend <= '0';
			snap_addr <= (others => '0');
			crc <= (others => '0');
			crc_pend <= '0';
			crc_addr <= (others => '0');
			fetch <= (others => '0');
			fetch_pend <= '0';
			fetch_ok <= '0';
			fetch_addr <= (others => '0');
			k <= (others => '0');
			got <= (others => '0');
		elsif rising_edge(clk_i) then
			restart_n := restart;
			mode_n := mode;
			frame_n := frame;
			fetch_ok_n := fetch_ok;
			out_valid <= '0';
			mode_old <= mode_i;

			-- A mode change takes effect at the next frame; play prefetches frame 0 at once
			if (mode_i /= mode_old) then
				restart_n := '1';
				fetch_ok_n := '0';
				fetch_pend <= '0';
				wait_deliver <= '0';
				if (mode_i = "10") then
					fetch_pend <= '1';
					fetch_addr <= to_unsigned(REPLAY_BASE, 19); -- Frame 0
				end if;
			end if;

			-- Frame tick
			if (snap_in_valid_i = '1') then
				if (restart_n = '1') then
					restart_n := '0';
					mode_n := mode_i;
					frame_n := (others => '0');
					crc_frame <= (others => '0');
				end if;
				-- A full log (frame_n = MAX_FRAMES) falls back to pass-through
				if ((mode_n = "10") and (frame_n < MAX_FRAMES)) then
					-- Play: deliver the prefetched snapshot (or when it arrives)
					if (fetch_ok_n = '1') then
						-- Deliver frame f, prefetch frame f + 1
						out_snap <= fetch;
						out_valid <= '1';
						fetch_ok_n := '0';
						fetch_pend <= '1';
						fetch_addr <= snap_address(frame_n + 1);
						frame_n := frame_n + 1;
					else
						wait_deliver <= '1';
					end if;
				else
					out_snap <= snap_in_i;
					out_valid <= '1';
					if ((mode_n = "01") and (frame_n < MAX_FRAMES)) then
						snap <= snap_in_i;
						snap_pend <= '1';
						snap_addr <= snap_address(frame_n);
						frame_n := frame_n + 1;
					end if;
				end if;
			end if;

			-- A late prefetch completes a delivery that is waiting
			if ((wait_deliver = '1') and (fetch_ok = '1')) then
				wait_deliver <= '0';
				out_snap <= fetch;
				out_valid <= '1';
				fetch_ok_n := '0';
				frame_n := frame + 1;
				fetch_pend <= '1';
				fetch_addr <= snap_address(frame + 1);
			end if;

			-- CRC of this frame goes to CRC_BASE + 4 crc_frame
			if ((crc_valid_i = '1') and (mode /= "00") and (crc_frame < MAX_FRAMES)) then
				crc <= crc_i;
				crc_pend <= '1';
				crc_addr <= to_unsigned(CRC_BASE, 19) + shift_left(resize(crc_frame, 19), 2);
				crc_frame <= crc_frame + 1;
			end if;

			-- SRAM engine: one job at a time, byte by byte
			case job_state is
				when JOB_IDLE =>
					k <= (others => '0');
					got <= (others => '0');
					if (snap_pend = '1') then
						job_state <= JOB_SNAP;
					elsif (crc_pend = '1') then
						job_state <= JOB_CRC;
					elsif ((fetch_pend = '1') and (fetch_ok = '0')) then
						job_state <= JOB_READ;
					end if;

				when JOB_SNAP =>
					if (m_gnt_i = '1') then
						k <= k + 1;
						if (k = 4) then -- Fifth and last snapshot byte granted
							snap_pend <= '0';
							job_state <= JOB_IDLE;
						end if;
					end if;

				when JOB_CRC =>
					if (m_gnt_i = '1') then
						k <= k + 1;
						if (k = 3) then
							crc_pend <= '0';
							job_state <= JOB_IDLE;
						end if;
					end if;

				when JOB_READ =>
					-- k stops at 5 (all reads issued) while the data comes back
					if ((m_gnt_i = '1') and (k /= 5)) then
						k <= k + 1;
					end if;
					if (m_rvalid_i = '1') then
						-- Bytes return in order, lowest first
						fetch <= m_rdata_i & fetch(SNAP_BITS - 1 downto 8);
						got <= got + 1;
						if (got = 4) then
							job_state <= JOB_IDLE;
							fetch_pend <= '0';
							-- A mode change during the read cancels it
							if ((fetch_pend = '1') and (mode_i = mode_old)) then
								fetch_ok_n := '1';
							end if;
						end if;
					end if;

				when others =>
					null;
			end case;

			restart <= restart_n;
			mode <= mode_n;
			frame <= frame_n;
			fetch_ok <= fetch_ok_n;
		end if;
	end process;

	-- SRAM master outputs from the current job
	process(job_state, k, snap_addr, snap, crc_addr, crc, fetch_addr)
	begin
		m_req_o <= '0';
		m_we_o <= '0';
		m_addr_o <= (others => '0');
		m_wdata_o <= (others => '0');
		case job_state is
			when JOB_SNAP =>
				m_req_o <= '1';
				m_we_o <= '1';
				m_addr_o <= std_logic_vector(snap_addr + resize(k, 19));
				m_wdata_o <= snap(8 * to_integer(k) + 7 downto 8 * to_integer(k));
			when JOB_CRC =>
				m_req_o <= '1';
				m_we_o <= '1';
				m_addr_o <= std_logic_vector(crc_addr + resize(k, 19));
				-- Byte k, low byte first; k(1 downto 0) keeps the slice in range (k is 0..3 here)
				m_wdata_o <= crc(8 * to_integer(k(1 downto 0)) + 7 downto 8 * to_integer(k(1 downto 0)));
			when JOB_READ =>
				if (k /= 5) then
					m_req_o <= '1';
				end if;
				m_addr_o <= std_logic_vector(fetch_addr + resize(k, 19));
			when others =>
				null;
		end case;
	end process;

	snap_out_o <= out_snap;
	snap_out_valid_o <= out_valid;
	frames_o <= std_logic_vector(frame);
end arch;
