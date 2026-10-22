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
-- Description:    Stage-2/3 loader jobs from the game data in flash
--                 (format in tools/flash_image/make_gamedata.py):
--                   art job    item 8 (sprite art, 197,632 bytes) copied
--                              byte by byte into SRAM at ART_BASE
--                   level job  item 1..3: 4096 tile words into the tile
--                              map (port B), 32 actor records into the
--                              actor table (slots past the level's count
--                              are written as 0), and the start pose
--                 Game data layout (tools/flash_image/make_gamedata.py),
--                 little endian, at FLASH_DATA_BASE:
--                   0..7 "SHOOTER0", 8..9 version, 10..11 entry count N,
--                   then N entries of 12 bytes: u32 id, u32 offset (from
--                   the image start), u32 length
--                 Level item (tools/model/level.py): 12,288 tile bytes (3
--                 per tile, index y * 64 + x), start x u32, start y u32
--                 (Q6.16), angle u16, actor count u16, count x 8-byte
--                 actor records, level number u8.
--                 Each job makes three flash_reader requests:
--                   S_HDR_REQ / S_HDR_DATA    12 header bytes, check magic
--                   S_DIR_REQ / S_DIR_DATA    12 N directory bytes, find
--                                             the id, keep offset, length
--                   S_ITEM_REQ / S_ITEM_DATA  the item itself
--                 then S_CLEAR (level: zero the unused actor slots) or
--                 S_FLUSH (art: wait for the last SRAM write).
--                 Art bytes are written through an SRAM arbiter master
--                 port; while a byte waits for its grant data_ready_o is
--                 low, so the flash reader stops SCK (back-pressure)
--                 instead of losing data.
--                 Bad magic, N = 0 or a missing id set error_o (held until
--                 the next start) and end without done_o.
--                 Coding: two-segment style, registers in record r.
--                 Clock domain: clk_i (system). Time is set by the flash
--                 (25 MHz SCK, 3.1 MB/s): about 4 ms for a level, 64 ms
--                 for the art.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std, hw_pkg,
--                 render_types_pkg
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - Stage 2
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
	constant MAGIC: magic_t := (x"53", x"48", x"4F", x"4F", x"54", x"45", x"52", x"30"); -- "SHOOTER0"

	type state_t is (S_IDLE, S_HDR_REQ, S_HDR_DATA, S_DIR_REQ, S_DIR_DATA, S_ITEM_REQ,
		S_ITEM_DATA, S_CLEAR, S_FLUSH);

	type regs_t is record
		state: state_t;
		art: std_logic; -- '1' art job, '0' level job
		id: std_logic_vector(7 downto 0);
		idx: unsigned(17 downto 0); -- Byte index within the current read
		magic_ok: std_logic;
		count: unsigned(15 downto 0); -- Directory entries
		ent: unsigned(3 downto 0); -- Byte within a directory entry, 0..11
		match: std_logic; -- Current entry's id matches so far
		found: std_logic;
		offset: unsigned(23 downto 0); -- Current entry's offset (low 3 bytes)
		length: unsigned(23 downto 0); -- Current entry's length (low 3 bytes)
		item: unsigned(23 downto 0); -- Offset of the wanted item
		item_len: unsigned(23 downto 0); -- Its length
		phase: unsigned(1 downto 0); -- Byte within a tile word, 0..2
		b0: std_logic_vector(7 downto 0);
		b1: std_logic_vector(7 downto 0);
		tile: unsigned(11 downto 0);
		pose: std_logic_vector(79 downto 0); -- Pose bytes, newest in 79:72
		rec: std_logic_vector(63 downto 0); -- Actor record, newest byte in 63:56
		rec_byte: unsigned(2 downto 0); -- Byte within an actor record
		slot: unsigned(5 downto 0); -- Next actor slot, 0..32
		map_we: std_logic;
		map_addr: unsigned(11 downto 0);
		map_data: std_logic_vector(23 downto 0);
		act_we: std_logic;
		act_addr: unsigned(4 downto 0);
		act_data: std_logic_vector(63 downto 0);
		pend: std_logic; -- Art byte waiting for its SRAM grant
		m_addr: unsigned(18 downto 0);
		m_data: std_logic_vector(7 downto 0);
		start_x: std_logic_vector(POS_BITS - 1 downto 0);
		start_y: std_logic_vector(POS_BITS - 1 downto 0);
		start_angle: std_logic_vector(ANGLE_BITS - 1 downto 0);
		done: std_logic;
		error: std_logic;
	end record;

	constant REGS_INIT: regs_t := (
		state => S_IDLE,
		art => '0',
		id => (others => '0'),
		idx => (others => '0'),
		magic_ok => '0',
		count => (others => '0'),
		ent => (others => '0'),
		match => '0',
		found => '0',
		offset => (others => '0'),
		length => (others => '0'),
		item => (others => '0'),
		item_len => (others => '0'),
		phase => (others => '0'),
		b0 => (others => '0'),
		b1 => (others => '0'),
		tile => (others => '0'),
		pose => (others => '0'),
		rec => (others => '0'),
		rec_byte => (others => '0'),
		slot => (others => '0'),
		map_we => '0',
		map_addr => (others => '0'),
		map_data => (others => '0'),
		act_we => '0',
		act_addr => (others => '0'),
		act_data => (others => '0'),
		pend => '0',
		m_addr => (others => '0'),
		m_data => (others => '0'),
		start_x => (others => '0'),
		start_y => (others => '0'),
		start_angle => (others => '0'),
		done => '0',
		error => '0'
	);

	signal r: regs_t := REGS_INIT;
	signal r_next: regs_t;
	signal ready: std_logic;
begin
	-- Art bytes are taken only when no earlier byte is still waiting for
	-- the SRAM (one byte of buffering is plenty: the flash delivers a byte
	-- every 32 clocks, an SRAM write takes 2 to 4)
	ready <= not r.pend;

	process(r, art_start_i, level_start_i, level_i, req_ready_i, data_valid_i, data_i,
		data_last_i, m_gnt_i, ready)
		variable v: regs_t;
		variable b: std_logic_vector(7 downto 0);
		variable take: boolean;
	begin
		v := r;
		v.done := '0';
		v.map_we := '0';
		v.act_we := '0';
		b := data_i;
		take := (data_valid_i = '1') and (ready = '1');
		if ((r.pend = '1') and (m_gnt_i = '1')) then
			v.pend := '0';
		end if;
		case r.state is
			when S_IDLE =>
				if (art_start_i = '1') then
					v.art := '1';
					v.id := std_logic_vector(to_unsigned(ART_ID, 8));
					v.error := '0';
					v.state := S_HDR_REQ;
				elsif (level_start_i = '1') then
					v.art := '0';
					v.id := "000000" & level_i; -- Levels 1..3 are directory ids 1..3
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
				if (take) then
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
				if (take) then
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
						when 8 =>
							v.length(7 downto 0) := unsigned(b);
						when 9 =>
							v.length(15 downto 8) := unsigned(b);
						when 10 =>
							v.length(23 downto 16) := unsigned(b);
						when others =>
							null; -- High bytes of the offset and length are 0
					end case;
					if (r.ent = 11) then
						v.ent := (others => '0');
						if ((r.match = '1') and (r.found = '0')) then
							v.found := '1';
							v.item := r.offset;
							v.item_len := r.length;
						end if;
					else
						v.ent := r.ent + 1;
					end if;
					if (data_last_i = '1') then
						if ((v.found = '1') and (v.item_len /= 0)) then
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
				v.rec_byte := (others => '0');
				v.slot := (others => '0');
				if (req_ready_i = '1') then
					v.state := S_ITEM_DATA;
				end if;

			when S_ITEM_DATA =>
				if (take) then
					v.idx := r.idx + 1;
					if (r.art = '1') then
						-- Art: one SRAM write per byte
						v.pend := '1';
						v.m_addr := to_unsigned(ART_BASE, 19) + resize(r.idx, 19);
						v.m_data := b;
					elsif (r.idx < POSE_START) then
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
					elsif (r.idx < ACTORS_START) then
						-- Start pose (10 bytes) then the actor count (2 bytes,
						-- not needed: the item length and data_last end the
						-- records); bytes shift in from the top
						if (r.idx < COUNT_START) then
							v.pose := b & r.pose(79 downto 8);
						end if;
					elsif (r.slot < 32) then
						-- Actor records, 8 bytes little endian; the final
						-- level-number byte never completes a record
						v.rec := b & r.rec(63 downto 8);
						v.rec_byte := r.rec_byte + 1;
						if (r.rec_byte = 7) then
							v.act_we := '1';
							v.act_addr := r.slot(4 downto 0);
							v.act_data := b & r.rec(63 downto 8);
							v.slot := r.slot + 1;
						end if;
					end if;
					if (data_last_i = '1') then
						-- pose(31:0) start x, (63:32) start y, (79:64) angle
						if (r.art = '0') then
							v.start_x := v.pose(POS_BITS - 1 downto 0);
							v.start_y := v.pose(32 + POS_BITS - 1 downto 32);
							v.start_angle := v.pose(64 + ANGLE_BITS - 1 downto 64);
							v.state := S_CLEAR;
						else
							v.state := S_FLUSH;
						end if;
					end if;
				end if;

			when S_CLEAR =>
				-- Empty the actor slots the level does not use
				if (r.slot < 32) then
					v.act_we := '1';
					v.act_addr := r.slot(4 downto 0);
					v.act_data := (others => '0');
					v.slot := r.slot + 1;
				else
					v.done := '1';
					v.state := S_IDLE;
				end if;

			when S_FLUSH =>
				if (v.pend = '0') then
					v.done := '1';
					v.state := S_IDLE;
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
				req_len_o <= std_logic_vector(r.item_len);
			when others =>
				req_addr_o <= std_logic_vector(to_unsigned(FLASH_DATA_BASE, 24));
				req_len_o <= std_logic_vector(to_unsigned(12, 24));
		end case;
	end process;
	data_ready_o <= ready;
	map_we_o <= r.map_we;
	map_addr_o <= std_logic_vector(r.map_addr);
	map_data_o <= r.map_data;
	act_we_o <= r.act_we;
	act_addr_o <= std_logic_vector(r.act_addr);
	act_data_o <= r.act_data;
	start_x_o <= r.start_x;
	start_y_o <= r.start_y;
	start_angle_o <= r.start_angle;
	m_req_o <= r.pend;
	m_we_o <= '1';
	m_addr_o <= std_logic_vector(r.m_addr);
	m_wdata_o <= r.m_data;
	busy_o <= '0' when (r.state = S_IDLE) else '1';
	done_o <= r.done;
	error_o <= r.error;
end arch;
