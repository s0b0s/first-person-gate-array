--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Asset Loader
-- Module Name:    asset_loader
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    Loader jobs from the flash game data:
--                   art job    item 8 (sprite art, 197,632 bytes) copied
--                              byte by byte into SRAM at ART_BASE
--                   level job  item 1..3: 4096 tile words into the tile
--                              map (port B), 32 actor records (unused
--                              slots zeroed) and the start pose
--                 Game data at FLASH_DATA_BASE (make_gamedata.py), little
--                 endian: 0..7 "FPGADATA", 8..9 version, 10..11 entry
--                 count N, then N 12-byte entries (u32 id, u32 offset from
--                 image start, u32 length).
--                 Level item (tools/model/level.py): 12,288 tile bytes (3
--                 per tile, index y * 64 + x), start x, y u32 (Q6.16),
--                 angle u16, actor count u16, 8-byte actor records, level
--                 number u8.
--                 Each job reads header (check magic), directory (find id)
--                 and item, then LD_CLEAR (zero unused actor slots) or
--                 LD_FLUSH (wait for the last art SRAM write). While an
--                 art byte waits for its SRAM grant, data_ready_o is low
--                 and the flash reader stops SCK. Bad magic, N = 0 or a
--                 missing id set error_o (held until the next start), no
--                 done_o.
--                 Clock domain: clk_i (system). Flash-bound (3.1 MB/s):
--                 about 4 ms per level, 64 ms for the art.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std, hw_pkg,
--                 render_types_pkg
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First working version
-- Revision 1.01 - Plain signals instead of records; one-process state machine
-- Additional Comments:
--                 Items must be shorter than 2^18 bytes. A start pulse
--                 while busy is ignored.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.hw_pkg.all;
use work.render_types_pkg.all;

entity asset_loader is
	port(
		clk_i: in std_logic; -- System clock
		rst_i: in std_logic; -- Asynchronous reset, active high
		art_start_i: in std_logic; -- Pulse: copy the art item into SRAM
		level_start_i: in std_logic; -- Pulse: load level level_i
		level_i: in std_logic_vector(1 downto 0); -- Level 1..3
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
		-- Tile map port B writes
		map_we_o: out std_logic;
		map_addr_o: out std_logic_vector(11 downto 0); -- y & x
		map_data_o: out std_logic_vector(23 downto 0); -- Tile word
		-- Actor table writes
		act_we_o: out std_logic;
		act_addr_o: out std_logic_vector(4 downto 0); -- Slot 0..31
		act_data_o: out std_logic_vector(63 downto 0); -- Actor record
		-- Start pose of the loaded level
		start_x_o: out std_logic_vector(POS_BITS - 1 downto 0); -- Q6.16
		start_y_o: out std_logic_vector(POS_BITS - 1 downto 0);
		start_angle_o: out std_logic_vector(ANGLE_BITS - 1 downto 0);
		-- SRAM arbiter master port (art writes only)
		m_req_o: out std_logic;
		m_we_o: out std_logic;
		m_addr_o: out std_logic_vector(18 downto 0);
		m_wdata_o: out std_logic_vector(7 downto 0);
		m_gnt_i: in std_logic;
		busy_o: out std_logic;
		done_o: out std_logic; -- Pulse: job finished
		error_o: out std_logic -- Bad data or item not found
	);
end asset_loader;

architecture arch of asset_loader is
	constant ART_ID: natural := 8; -- Directory id of the sprite art (make_gamedata.py)
	constant POSE_START: natural := 4096 * 3; -- Byte index of start x
	constant COUNT_START: natural := POSE_START + 10; -- Actor count u16
	constant ACTORS_START: natural := COUNT_START + 2; -- First actor record
	type magic_t is array (0 to 7) of std_logic_vector(7 downto 0);
	constant MAGIC: magic_t := (x"46", x"50", x"47", x"41", x"44", x"41", x"54", x"41"); -- "FPGADATA"

	type ld_state_type is (LD_IDLE, LD_HDR_REQ, LD_HDR_DATA, LD_DIR_REQ, LD_DIR_DATA, LD_ITEM_REQ,
		LD_ITEM_DATA, LD_CLEAR, LD_FLUSH);
	signal ld_state: ld_state_type := LD_IDLE;

	signal art: std_logic := '0'; -- '1' art job, '0' level job
	signal id: std_logic_vector(7 downto 0) := (others => '0');
	signal idx: unsigned(17 downto 0) := (others => '0'); -- Byte index within the current read
	signal magic_ok: std_logic := '0';
	signal count: unsigned(15 downto 0) := (others => '0'); -- Directory entries
	signal ent: unsigned(3 downto 0) := (others => '0'); -- Byte within a directory entry, 0..11
	signal match: std_logic := '0'; -- Current entry's id matches so far
	signal found: std_logic := '0';
	signal offset: unsigned(23 downto 0) := (others => '0'); -- Current entry's offset (low 3 bytes)
	signal ent_len: unsigned(23 downto 0) := (others => '0'); -- Current entry's length (low 3 bytes)
	signal item: unsigned(23 downto 0) := (others => '0'); -- Offset of the wanted item
	signal item_len: unsigned(23 downto 0) := (others => '0'); -- Its length
	signal phase: unsigned(1 downto 0) := (others => '0'); -- Byte within a tile word, 0..2
	signal b0: std_logic_vector(7 downto 0) := (others => '0');
	signal b1: std_logic_vector(7 downto 0) := (others => '0');
	signal tile: unsigned(11 downto 0) := (others => '0');
	signal pose: std_logic_vector(79 downto 0) := (others => '0'); -- Pose bytes, newest in 79:72
	signal rec: std_logic_vector(63 downto 0) := (others => '0'); -- Actor record, newest byte in 63:56
	signal rec_byte: unsigned(2 downto 0) := (others => '0'); -- Byte within an actor record
	signal slot: unsigned(5 downto 0) := (others => '0'); -- Next actor slot, 0..32
	signal map_we: std_logic := '0';
	signal map_addr: unsigned(11 downto 0) := (others => '0');
	signal map_data: std_logic_vector(23 downto 0) := (others => '0');
	signal act_we: std_logic := '0';
	signal act_addr: unsigned(4 downto 0) := (others => '0');
	signal act_data: std_logic_vector(63 downto 0) := (others => '0');
	signal pend: std_logic := '0'; -- Art byte waiting for its SRAM grant
	signal m_addr: unsigned(18 downto 0) := (others => '0');
	signal m_data: std_logic_vector(7 downto 0) := (others => '0');
	signal start_x: std_logic_vector(POS_BITS - 1 downto 0) := (others => '0');
	signal start_y: std_logic_vector(POS_BITS - 1 downto 0) := (others => '0');
	signal start_angle: std_logic_vector(ANGLE_BITS - 1 downto 0) := (others => '0');
	signal done: std_logic := '0';
	signal err: std_logic := '0';
	signal ready: std_logic;
	signal take: std_logic; -- A flash byte is accepted this clock
begin
	-- Take an art byte only when none waits for the SRAM (one byte of buffer is
	-- enough: a flash byte every 32 clocks, an SRAM write takes 2 to 4)
	ready <= not pend;
	take <= data_valid_i and ready;

	process(clk_i, rst_i)
		variable count_n: unsigned(15 downto 0); -- count including this byte
		variable found_n: std_logic; -- found including the entry ending now
		variable len_n: unsigned(23 downto 0); -- item_len likewise
		variable pose_n: std_logic_vector(79 downto 0); -- pose including this byte
	begin
		if (rst_i = '1') then
			ld_state <= LD_IDLE;
			art <= '0';
			id <= (others => '0');
			idx <= (others => '0');
			magic_ok <= '0';
			count <= (others => '0');
			ent <= (others => '0');
			match <= '0';
			found <= '0';
			offset <= (others => '0');
			ent_len <= (others => '0');
			item <= (others => '0');
			item_len <= (others => '0');
			phase <= (others => '0');
			b0 <= (others => '0');
			b1 <= (others => '0');
			tile <= (others => '0');
			pose <= (others => '0');
			rec <= (others => '0');
			rec_byte <= (others => '0');
			slot <= (others => '0');
			map_we <= '0';
			map_addr <= (others => '0');
			map_data <= (others => '0');
			act_we <= '0';
			act_addr <= (others => '0');
			act_data <= (others => '0');
			pend <= '0';
			m_addr <= (others => '0');
			m_data <= (others => '0');
			start_x <= (others => '0');
			start_y <= (others => '0');
			start_angle <= (others => '0');
			done <= '0';
			err <= '0';
		elsif rising_edge(clk_i) then
			done <= '0';
			map_we <= '0';
			act_we <= '0';
			-- The SRAM write of a pending art byte is granted
			if ((pend = '1') and (m_gnt_i = '1')) then
				pend <= '0';
			end if;
			case ld_state is
				when LD_IDLE =>
					if (art_start_i = '1') then
						art <= '1';
						id <= std_logic_vector(to_unsigned(ART_ID, 8));
						err <= '0';
						ld_state <= LD_HDR_REQ;
					elsif (level_start_i = '1') then
						art <= '0';
						id <= "000000" & level_i; -- Levels 1..3 are directory ids 1..3
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
					if (take = '1') then
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
					if (take = '1') then
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
							when 8 =>
								ent_len(7 downto 0) <= unsigned(data_i);
							when 9 =>
								ent_len(15 downto 8) <= unsigned(data_i);
							when 10 =>
								ent_len(23 downto 16) <= unsigned(data_i);
							when others =>
								null; -- High bytes of the offset and length are 0
						end case;
						found_n := found;
						len_n := item_len;
						if (ent = 11) then
							ent <= (others => '0');
							if ((match = '1') and (found = '0')) then
								found_n := '1';
								item <= offset;
								len_n := ent_len;
							end if;
						else
							ent <= ent + 1;
						end if;
						found <= found_n;
						item_len <= len_n;
						if (data_last_i = '1') then
							if ((found_n = '1') and (len_n /= 0)) then
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
					rec_byte <= (others => '0');
					slot <= (others => '0');
					if (req_ready_i = '1') then
						ld_state <= LD_ITEM_DATA;
					end if;

				when LD_ITEM_DATA =>
					if (take = '1') then
						idx <= idx + 1;
						pose_n := pose;
						if (art = '1') then
							-- Art: one SRAM write per byte
							pend <= '1';
							m_addr <= to_unsigned(ART_BASE, 19) + resize(idx, 19);
							m_data <= data_i;
						elsif (idx < POSE_START) then
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
						elsif (idx < ACTORS_START) then
							-- Start pose (10 bytes), then the actor count (unused:
							-- data_last ends the records); bytes shift in from the top
							if (idx < COUNT_START) then
								pose_n := data_i & pose(79 downto 8);
							end if;
						elsif (slot < 32) then
							-- Actor records, 8 bytes little endian (the final level
							-- byte never completes one)
							rec <= data_i & rec(63 downto 8);
							rec_byte <= rec_byte + 1;
							if (rec_byte = 7) then
								act_we <= '1';
								act_addr <= slot(4 downto 0);
								act_data <= data_i & rec(63 downto 8);
								slot <= slot + 1;
							end if;
						end if;
						pose <= pose_n;
						if (data_last_i = '1') then
							-- pose(31:0) start x, (63:32) start y, (79:64) angle
							if (art = '0') then
								start_x <= pose_n(POS_BITS - 1 downto 0);
								start_y <= pose_n(32 + POS_BITS - 1 downto 32);
								start_angle <= pose_n(64 + ANGLE_BITS - 1 downto 64);
								ld_state <= LD_CLEAR;
							else
								ld_state <= LD_FLUSH;
							end if;
						end if;
					end if;

				when LD_CLEAR =>
					-- Empty the actor slots the level does not use
					if (slot < 32) then
						act_we <= '1';
						act_addr <= slot(4 downto 0);
						act_data <= (others => '0');
						slot <= slot + 1;
					else
						done <= '1';
						ld_state <= LD_IDLE;
					end if;

				when LD_FLUSH =>
					-- Done once the last art byte has its grant (now or before)
					if ((pend = '0') or (m_gnt_i = '1')) then
						done <= '1';
						ld_state <= LD_IDLE;
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
	process(ld_state, count, item, item_len)
	begin
		case ld_state is
			when LD_DIR_REQ =>
				req_addr_o <= std_logic_vector(to_unsigned(FLASH_DATA_BASE + 12, 24));
				-- 12 bytes per entry: 8 N + 4 N
				req_len_o <= std_logic_vector(shift_left(resize(count, 24), 3) +
					shift_left(resize(count, 24), 2));
			when LD_ITEM_REQ =>
				req_addr_o <= std_logic_vector(to_unsigned(FLASH_DATA_BASE, 24) + item);
				req_len_o <= std_logic_vector(item_len);
			when others =>
				req_addr_o <= std_logic_vector(to_unsigned(FLASH_DATA_BASE, 24));
				req_len_o <= std_logic_vector(to_unsigned(12, 24));
		end case;
	end process;
	data_ready_o <= ready;
	map_we_o <= map_we;
	map_addr_o <= std_logic_vector(map_addr);
	map_data_o <= map_data;
	act_we_o <= act_we;
	act_addr_o <= std_logic_vector(act_addr);
	act_data_o <= act_data;
	start_x_o <= start_x;
	start_y_o <= start_y;
	start_angle_o <= start_angle;
	m_req_o <= pend;
	m_we_o <= '1';
	m_addr_o <= std_logic_vector(m_addr);
	m_wdata_o <= m_data;
	busy_o <= '0' when (ld_state = LD_IDLE) else '1';
	done_o <= done;
	error_o <= err;
end arch;
