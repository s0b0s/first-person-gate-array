--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Level Loader
-- Module Name:    level_loader
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    Loads a level from the game data in flash into the tile
--                 map BRAM (port B writes) and returns its start pose.
--                 The game
--                 data at FLASH_DATA_BASE (tools/flash_image/
--                 make_gamedata.py) starts with a header and directory,
--                 all little endian:
--                   0..7 "SHOOTER0", 8..9 version, 10..11 entry count N,
--                   then N entries of 12 bytes: u32 id, u32 offset (from
--                   the start of the image), u32 length
--                 A level item is 4096 tile words of 3 bytes (index
--                 y * 64 + x), then start x and start y (u32, Q6.16) and
--                 the start angle (u16): 12,298 bytes.
--                 Three flash_reader requests, one per state pair:
--                   S_HDR_REQ / S_HDR_DATA    12 header bytes, check magic
--                   S_DIR_REQ / S_DIR_DATA    12 N directory bytes, find id
--                   S_ITEM_REQ / S_ITEM_DATA  the level item; every third
--                                             byte writes one tile word
--                 Bad magic, N = 0 or a missing id set error_o (held until
--                 the next start) and end without done_o.
--                 Coding: two-segment style, registers in record r.
--                 Clock domain: clk_i (system). Time is set by the flash:
--                 about 4 ms for a level at 25 MHz SCK.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std, hw_pkg,
--                 render_types_pkg
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - Stage 1
-- Additional Comments:
--                 None.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.hw_pkg.all;
use work.render_types_pkg.all;

entity level_loader is
	port(
		clk_i: in std_logic; -- System clock
		rst_i: in std_logic; -- Asynchronous reset, active high
		start_i: in std_logic; -- Pulse: load level level_id_i
		level_id_i: in std_logic_vector(7 downto 0); -- Directory id of the level
		-- flash_reader request port
		req_valid_o: out std_logic;
		req_ready_i: in std_logic;
		req_id_o: out std_logic; -- Always '0' (READ, not JEDEC ID)
		req_addr_o: out std_logic_vector(23 downto 0);
		req_len_o: out std_logic_vector(23 downto 0);
		-- flash_reader data port
		data_valid_i: in std_logic;
		data_ready_o: out std_logic;
		data_i: in std_logic_vector(7 downto 0);
		data_last_i: in std_logic;
		-- Map port B writes
		map_we_o: out std_logic;
		map_addr_o: out std_logic_vector(11 downto 0); -- y & x
		map_data_o: out std_logic_vector(23 downto 0); -- Tile word
		-- Start pose of the loaded level
		start_x_o: out std_logic_vector(POS_BITS - 1 downto 0); -- Q6.16
		start_y_o: out std_logic_vector(POS_BITS - 1 downto 0);
		start_angle_o: out std_logic_vector(ANGLE_BITS - 1 downto 0);
		busy_o: out std_logic;
		done_o: out std_logic; -- Pulse: map and start pose loaded
		error_o: out std_logic -- Bad data or level not found
	);
end level_loader;

architecture arch of level_loader is
	constant LEVEL_BYTES: natural := 4096 * 3 + 10; -- 3 bytes per tile, then x (4), y (4), angle (2)
	constant POSE_START: natural := 4096 * 3; -- Byte index of start x
	type magic_t is array (0 to 7) of std_logic_vector(7 downto 0);
	constant MAGIC: magic_t := (x"53", x"48", x"4F", x"4F", x"54", x"45", x"52", x"30"); -- "SHOOTER0"

	type state_t is (S_IDLE, S_HDR_REQ, S_HDR_DATA, S_DIR_REQ, S_DIR_DATA, S_ITEM_REQ,
		S_ITEM_DATA);

	type regs_t is record
		state: state_t;
		id: std_logic_vector(7 downto 0);
		idx: unsigned(13 downto 0); -- Byte index within the current read
		magic_ok: std_logic;
		count: unsigned(15 downto 0); -- Directory entries
		ent: unsigned(3 downto 0); -- Byte within a directory entry, 0..11
		match: std_logic; -- Current entry's id matches so far
		found: std_logic;
		offset: unsigned(23 downto 0); -- Current entry's offset (low 3 bytes)
		item: unsigned(23 downto 0); -- Offset of the level item
		phase: unsigned(1 downto 0); -- Byte within a tile word, 0..2
		b0: std_logic_vector(7 downto 0);
		b1: std_logic_vector(7 downto 0);
		tile: unsigned(11 downto 0);
		pose: std_logic_vector(79 downto 0); -- Last 10 bytes, newest in 79:72
		map_we: std_logic;
		map_addr: unsigned(11 downto 0);
		map_data: std_logic_vector(23 downto 0);
		start_x: std_logic_vector(POS_BITS - 1 downto 0);
		start_y: std_logic_vector(POS_BITS - 1 downto 0);
		start_angle: std_logic_vector(ANGLE_BITS - 1 downto 0);
		done: std_logic;
		error: std_logic;
	end record;

	constant REGS_INIT: regs_t := (
		state => S_IDLE,
		id => (others => '0'),
		idx => (others => '0'),
		magic_ok => '0',
		count => (others => '0'),
		ent => (others => '0'),
		match => '0',
		found => '0',
		offset => (others => '0'),
		item => (others => '0'),
		phase => (others => '0'),
		b0 => (others => '0'),
		b1 => (others => '0'),
		tile => (others => '0'),
		pose => (others => '0'),
		map_we => '0',
		map_addr => (others => '0'),
		map_data => (others => '0'),
		start_x => (others => '0'),
		start_y => (others => '0'),
		start_angle => (others => '0'),
		done => '0',
		error => '0'
	);

	signal r: regs_t := REGS_INIT;
	signal r_next: regs_t;
begin
	process(r, start_i, level_id_i, req_ready_i, data_valid_i, data_i, data_last_i)
		variable v: regs_t;
		variable b: std_logic_vector(7 downto 0);
	begin
		v := r;
		v.done := '0';
		v.map_we := '0';
		b := data_i;
		case r.state is
			when S_IDLE =>
				if (start_i = '1') then
					v.id := level_id_i;
					v.error := '0';
					v.state := S_HDR_REQ;
				end if;

			when S_HDR_REQ =>
				v.idx := (others => '0');
				v.magic_ok := '1';
				if (req_ready_i = '1') then
					v.state := S_HDR_DATA;
				end if;

			when S_HDR_DATA =>
				if (data_valid_i = '1') then
					v.idx := r.idx + 1;
					if (r.idx < 8) then
						if (b /= MAGIC(to_integer(r.idx(2 downto 0)))) then
							v.magic_ok := '0';
						end if;
					elsif (r.idx = 10) then
						-- Entry count N, little endian (bytes 8 and 9 are the version)
						v.count(7 downto 0) := unsigned(b);
					elsif (r.idx = 11) then
						v.count(15 downto 8) := unsigned(b);
					end if;
					if (data_last_i = '1') then
						if ((r.magic_ok = '0') or (v.count = 0)) then
							v.error := '1';
							v.state := S_IDLE;
						else
							v.state := S_DIR_REQ;
						end if;
					end if;
				end if;

			when S_DIR_REQ =>
				v.ent := (others => '0');
				v.found := '0';
				if (req_ready_i = '1') then
					v.state := S_DIR_DATA;
				end if;

			when S_DIR_DATA =>
				if (data_valid_i = '1') then
					case to_integer(r.ent) is
						when 0 =>
							if (b = r.id) then
								v.match := '1';
							else
								v.match := '0';
							end if;
						when 1 | 2 | 3 =>
							-- The id is a u32: its upper three bytes must be 0 too
							if (b /= x"00") then
								v.match := '0';
							end if;
						when 4 =>
							v.offset(7 downto 0) := unsigned(b);
						when 5 =>
							v.offset(15 downto 8) := unsigned(b);
						when 6 =>
							v.offset(23 downto 16) := unsigned(b);
						when others =>
							null; -- Offset byte 3 and the length are not needed
					end case;
					if (r.ent = 11) then
						v.ent := (others => '0');
						if ((r.match = '1') and (r.found = '0')) then
							v.found := '1';
							v.item := r.offset;
						end if;
					else
						v.ent := r.ent + 1;
					end if;
					if (data_last_i = '1') then
						if (v.found = '1') then
							v.state := S_ITEM_REQ;
						else
							v.error := '1';
							v.state := S_IDLE;
						end if;
					end if;
				end if;

			when S_ITEM_REQ =>
				v.idx := (others => '0');
				v.phase := (others => '0');
				v.tile := (others => '0');
				if (req_ready_i = '1') then
					v.state := S_ITEM_DATA;
				end if;

			when S_ITEM_DATA =>
				if (data_valid_i = '1') then
					v.idx := r.idx + 1;
					if (r.idx < POSE_START) then
						-- Tile words: low byte first
						if (r.phase = 0) then
							v.b0 := b;
							v.phase := "01";
						elsif (r.phase = 1) then
							v.b1 := b;
							v.phase := "10";
						else
							v.map_we := '1';
							v.map_addr := r.tile;
							v.map_data := b & r.b1 & r.b0;
							v.tile := r.tile + 1;
							v.phase := "00";
						end if;
					else
						-- Start pose bytes shift in from the top
						v.pose := b & r.pose(79 downto 8);
					end if;
					if (data_last_i = '1') then
						-- pose(31:0) start x, (63:32) start y, (79:64) angle
						v.start_x := v.pose(POS_BITS - 1 downto 0);
						v.start_y := v.pose(32 + POS_BITS - 1 downto 32);
						v.start_angle := v.pose(64 + ANGLE_BITS - 1 downto 64);
						v.done := '1';
						v.state := S_IDLE;
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

	req_valid_o <= '1' when ((r.state = S_HDR_REQ) or (r.state = S_DIR_REQ) or
		(r.state = S_ITEM_REQ)) else '0';
	req_id_o <= '0';
	process(r)
	begin
		case r.state is
			when S_DIR_REQ =>
				req_addr_o <= std_logic_vector(to_unsigned(FLASH_DATA_BASE + 12, 24));
				-- 12 bytes per entry: 8 N + 4 N
				req_len_o <= std_logic_vector(resize(shift_left(resize(r.count, 24), 3) +
					shift_left(resize(r.count, 24), 2), 24));
			when S_ITEM_REQ =>
				req_addr_o <= std_logic_vector(to_unsigned(FLASH_DATA_BASE, 24) + r.item);
				req_len_o <= std_logic_vector(to_unsigned(LEVEL_BYTES, 24));
			when others =>
				req_addr_o <= std_logic_vector(to_unsigned(FLASH_DATA_BASE, 24));
				req_len_o <= std_logic_vector(to_unsigned(12, 24));
		end case;
	end process;
	data_ready_o <= '1';
	map_we_o <= r.map_we;
	map_addr_o <= std_logic_vector(r.map_addr);
	map_data_o <= r.map_data;
	start_x_o <= r.start_x;
	start_y_o <= r.start_y;
	start_angle_o <= r.start_angle;
	busy_o <= '0' when (r.state = S_IDLE) else '1';
	done_o <= r.done;
	error_o <= r.error;
end arch;
