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
-- Description:    Loads a level from flash game data into the tile map BRAM
--                 (port B writes) and returns its start pose.
--                 Game data at FLASH_DATA_BASE (tools/flash_image/
--                 make_gamedata.py), little endian: 0..7 "FPGADATA",
--                 8..9 version, 10..11 entry count N, then N 12-byte
--                 entries (u32 id, u32 offset from image start, u32
--                 length). A level item (12,298 bytes) is 4096 3-byte tile
--                 words (index y * 64 + x), start x and y (u32, Q6.16) and
--                 start angle (u16).
--                 Three flash_reader requests: header (check magic),
--                 directory (find id), level item (every third byte
--                 writes a tile word). Bad magic, N = 0 or a missing id
--                 set error_o (held until the next start), no done_o.
--                 Clock domain: clk_i (system). About 4 ms per level at
--                 25 MHz SCK.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std, hw_pkg,
--                 render_types_pkg
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
	constant MAGIC: magic_t := (x"46", x"50", x"47", x"41", x"44", x"41", x"54", x"41"); -- "FPGADATA"

	type ld_state_type is (LD_IDLE, LD_HDR_REQ, LD_HDR_DATA, LD_DIR_REQ, LD_DIR_DATA, LD_ITEM_REQ,
		LD_ITEM_DATA);
	signal ld_state: ld_state_type := LD_IDLE;

	signal id: std_logic_vector(7 downto 0) := (others => '0');
	signal idx: unsigned(13 downto 0) := (others => '0'); -- Byte index within the current read
	signal magic_ok: std_logic := '0';
	signal count: unsigned(15 downto 0) := (others => '0'); -- Directory entries
	signal ent: unsigned(3 downto 0) := (others => '0'); -- Byte within a directory entry, 0..11
	signal match: std_logic := '0'; -- Current entry's id matches so far
	signal found: std_logic := '0';
	signal offset: unsigned(23 downto 0) := (others => '0'); -- Current entry's offset (low 3 bytes)
	signal item: unsigned(23 downto 0) := (others => '0'); -- Offset of the level item
	signal phase: unsigned(1 downto 0) := (others => '0'); -- Byte within a tile word, 0..2
	signal b0: std_logic_vector(7 downto 0) := (others => '0');
	signal b1: std_logic_vector(7 downto 0) := (others => '0');
	signal tile: unsigned(11 downto 0) := (others => '0');
	signal pose: std_logic_vector(79 downto 0) := (others => '0'); -- Last 10 bytes, newest in 79:72
	signal map_we: std_logic := '0';
	signal map_addr: unsigned(11 downto 0) := (others => '0');
	signal map_data: std_logic_vector(23 downto 0) := (others => '0');
	signal start_x: std_logic_vector(POS_BITS - 1 downto 0) := (others => '0');
	signal start_y: std_logic_vector(POS_BITS - 1 downto 0) := (others => '0');
	signal start_angle: std_logic_vector(ANGLE_BITS - 1 downto 0) := (others => '0');
	signal done: std_logic := '0';
	signal err: std_logic := '0';
begin
	process(clk_i, rst_i)
		variable count_n: unsigned(15 downto 0); -- count including this byte
		variable pose_n: std_logic_vector(79 downto 0); -- pose including this byte
	begin
		if (rst_i = '1') then
			ld_state <= LD_IDLE;
			id <= (others => '0');
			idx <= (others => '0');
			magic_ok <= '0';
			count <= (others => '0');
			ent <= (others => '0');
			match <= '0';
			found <= '0';
			offset <= (others => '0');
			item <= (others => '0');
			phase <= (others => '0');
			b0 <= (others => '0');
			b1 <= (others => '0');
			tile <= (others => '0');
			pose <= (others => '0');
			map_we <= '0';
			map_addr <= (others => '0');
			map_data <= (others => '0');
			start_x <= (others => '0');
			start_y <= (others => '0');
			start_angle <= (others => '0');
			done <= '0';
			err <= '0';
		elsif rising_edge(clk_i) then
			done <= '0';
			map_we <= '0';
			case ld_state is
				when LD_IDLE =>
					if (start_i = '1') then
						id <= level_id_i;
						err <= '0';
						ld_state <= LD_HDR_REQ;
					end if;

				when LD_HDR_REQ =>
					idx <= (others => '0');
					magic_ok <= '1';
					if (req_ready_i = '1') then
						ld_state <= LD_HDR_DATA;
					end if;

				when LD_HDR_DATA =>
					if (data_valid_i = '1') then
						idx <= idx + 1;
						count_n := count;
						if (idx < 8) then
							if (data_i /= MAGIC(to_integer(idx(2 downto 0)))) then
								magic_ok <= '0';
							end if;
						elsif (idx = 10) then
							-- Entry count N, little endian (bytes 8 and 9 are the version)
							count_n(7 downto 0) := unsigned(data_i);
						elsif (idx = 11) then
							count_n(15 downto 8) := unsigned(data_i);
						end if;
						count <= count_n;
						if (data_last_i = '1') then
							if ((magic_ok = '0') or (count_n = 0)) then
								err <= '1';
								ld_state <= LD_IDLE;
							else
								ld_state <= LD_DIR_REQ;
							end if;
						end if;
					end if;

				when LD_DIR_REQ =>
					ent <= (others => '0');
					found <= '0';
					if (req_ready_i = '1') then
						ld_state <= LD_DIR_DATA;
					end if;

				when LD_DIR_DATA =>
					if (data_valid_i = '1') then
						case to_integer(ent) is
							when 0 =>
								if (data_i = id) then
									match <= '1';
								else
									match <= '0';
								end if;
							when 1 | 2 | 3 =>
								-- The id is a u32: its upper three bytes must be 0 too
								if (data_i /= x"00") then
									match <= '0';
								end if;
							when 4 =>
								offset(7 downto 0) <= unsigned(data_i);
							when 5 =>
								offset(15 downto 8) <= unsigned(data_i);
							when 6 =>
								offset(23 downto 16) <= unsigned(data_i);
							when others =>
								null; -- Offset byte 3 and the length are not needed
						end case;
						if (ent = 11) then
							ent <= (others => '0');
							if ((match = '1') and (found = '0')) then
								found <= '1';
								item <= offset;
							end if;
						else
							ent <= ent + 1;
						end if;
						if (data_last_i = '1') then
							-- Found earlier, or by the entry that ends with this byte
							if ((found = '1') or ((ent = 11) and (match = '1'))) then
								ld_state <= LD_ITEM_REQ;
							else
								err <= '1';
								ld_state <= LD_IDLE;
							end if;
						end if;
					end if;

				when LD_ITEM_REQ =>
					idx <= (others => '0');
					phase <= (others => '0');
					tile <= (others => '0');
					if (req_ready_i = '1') then
						ld_state <= LD_ITEM_DATA;
					end if;

				when LD_ITEM_DATA =>
					if (data_valid_i = '1') then
						idx <= idx + 1;
						pose_n := pose;
						if (idx < POSE_START) then
							-- Tile words: low byte first
							if (phase = 0) then
								b0 <= data_i;
								phase <= "01";
							elsif (phase = 1) then
								b1 <= data_i;
								phase <= "10";
							else
								map_we <= '1';
								map_addr <= tile;
								map_data <= data_i & b1 & b0;
								tile <= tile + 1;
								phase <= "00";
							end if;
						else
							-- Start pose bytes shift in from the top
							pose_n := data_i & pose(79 downto 8);
						end if;
						pose <= pose_n;
						if (data_last_i = '1') then
							-- pose(31:0) start x, (63:32) start y, (79:64) angle
							start_x <= pose_n(POS_BITS - 1 downto 0);
							start_y <= pose_n(32 + POS_BITS - 1 downto 32);
							start_angle <= pose_n(64 + ANGLE_BITS - 1 downto 64);
							done <= '1';
							ld_state <= LD_IDLE;
						end if;
					end if;

				when others =>
					null;
			end case;
		end if;
	end process;

	-- Flash request, decoded from the state
	req_valid_o <= '1' when ((ld_state = LD_HDR_REQ) or (ld_state = LD_DIR_REQ) or
		(ld_state = LD_ITEM_REQ)) else '0';
	req_id_o <= '0';
	process(ld_state, count, item)
	begin
		case ld_state is
			when LD_DIR_REQ =>
				req_addr_o <= std_logic_vector(to_unsigned(FLASH_DATA_BASE + 12, 24));
				-- 12 bytes per entry: 8 N + 4 N
				req_len_o <= std_logic_vector(shift_left(resize(count, 24), 3) +
					shift_left(resize(count, 24), 2));
			when LD_ITEM_REQ =>
				req_addr_o <= std_logic_vector(to_unsigned(FLASH_DATA_BASE, 24) + item);
				req_len_o <= std_logic_vector(to_unsigned(LEVEL_BYTES, 24));
			when others =>
				req_addr_o <= std_logic_vector(to_unsigned(FLASH_DATA_BASE, 24));
				req_len_o <= std_logic_vector(to_unsigned(12, 24));
		end case;
	end process;
	data_ready_o <= '1';
	map_we_o <= map_we;
	map_addr_o <= std_logic_vector(map_addr);
	map_data_o <= map_data;
	start_x_o <= start_x;
	start_y_o <= start_y;
	start_angle_o <= start_angle;
	busy_o <= '0' when (ld_state = LD_IDLE) else '1';
	done_o <= done;
	error_o <= err;
end arch;
