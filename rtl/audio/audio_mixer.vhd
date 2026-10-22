--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Audio Mixer
-- Module Name:    audio_mixer
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    8 effect voices + 1 music voice, mixed exactly like
--                 Mixer in tools/model/audio.py, with the samples streamed
--                 from the SPI flash.
--
--                 Output samples. Every sample_req_i (from i2s_tx, one per
--                 2,048 clocks) starts the computation of the next output
--                 pair; left_o / right_o change once it is done: 10 clocks
--                 per waiting command, 7 per playing voice, 2 per free
--                 one, 10 for the music and output (at most about 250
--                 clocks), well before the next sample_req_i.
--                 Command timing rule: commands taken on snd_* in clock
--                 cycles before a sample_req_i are applied, in the order
--                 taken, at the start of the computation that sample_req_i
--                 starts (the model's command() before sample()); a
--                 command taken in the same cycle as sample_req_i waits
--                 for the next one. music_i is sampled the same way: a new
--                 value restarts that track at position 0 in the
--                 computation started by the sample_req_i that sees it.
--                 Up to 16 commands may wait.
--
--                 Per output sample (model formats): each voice holds a
--                 position Q.16 in its sound advanced by STEP = 14798
--                 (11,025 / 48,828.125 in Q.16); the sample is
--                 byte[pos >> 16] - 128; gains (vol * (31 -+ pan)) >> 5;
--                 music gain 40, or 20 while more than 4 effect voices
--                 play; out = sat16((sum * master) >> 4). Voice allocation:
--                 lowest free voice, else the lowest-priority voice (lowest
--                 index on ties) if its priority is lower than the new
--                 one's, else the command is dropped. A sound id above 17
--                 does not exist and is ignored.
--
--                 Sample storage (audio_ram, 4 KB): the first 64 bytes of
--                 every item ("heads") are loaded at start-up, so a new
--                 sound plays its first 283 output samples (5.8 ms) from
--                 the head while its 256-byte ring fills from flash. Ring v
--                 holds the item's bytes 64, 65, ... at address
--                 v * 256 + (byte mod 256); fill(v) counts the bytes
--                 written (raised once a whole chunk is in). A ring is
--                 topped up in chunks of 64 bytes
--                 whenever at most 192 unread bytes remain, so after the
--                 first chunk at least 192 bytes (17 ms) are always ahead
--                 of the player: the 9 rings need 99 KB/s, the flash
--                 gives about 3 MB/s minus the loader's commands.
--                 A restarted voice gets a new generation number gen(v);
--                 the fetch machine notices it, restarts that ring, and
--                 does not commit a chunk requested for the old sound.
--                 The music ring streams the track in a loop (fill and the
--                 read pointer ru count bytes without wrapping, mod 2^20).
--                 A byte the ring does not hold yet (an underflow; never
--                 expected) plays as silence and is counted.
--
--                 Start-up (first time enable_i is '1'): read the flash
--                 directory at 0x220000, keep the flash address and length
--                 of items 16..33 (sounds 0..17) and 40..42 (music 1..3),
--                 then load the 21 heads. Until then the output is 0 and
--                 commands are dropped. enable_i = '0' later silences
--                 everything and stops refills (the directory is kept).
--
--                 Clock domain: clk_i (system, 100 MHz).
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std, hw_pkg,
--                 render_types_pkg, audio_ram
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
use work.hw_pkg.all;
use work.render_types_pkg.all;

entity audio_mixer is
	port(
		clk_i: in std_logic; -- System clock
		rst_i: in std_logic; -- Asynchronous reset, active high
		enable_i: in std_logic; -- '0': silent, no flash traffic
		-- Sound commands (render_types_pkg SND_*)
		snd_valid_i: in std_logic;
		snd_ready_o: out std_logic;
		snd_data_i: in std_logic_vector(SND_BITS - 1 downto 0);
		music_i: in std_logic_vector(1 downto 0); -- 0 off, 1..3 track
		master_i: in std_logic_vector(5 downto 0); -- Master volume 0..63
		-- To and from i2s_tx
		sample_req_i: in std_logic; -- Start computing the next pair
		left_o: out std_logic_vector(15 downto 0);
		right_o: out std_logic_vector(15 downto 0);
		-- Flash client port (to flash_arbiter)
		req_valid_o: out std_logic;
		req_ready_i: in std_logic;
		req_id_o: out std_logic;
		req_addr_o: out std_logic_vector(23 downto 0);
		req_len_o: out std_logic_vector(23 downto 0);
		data_valid_i: in std_logic;
		data_ready_o: out std_logic;
		data_i: in std_logic_vector(7 downto 0);
		data_last_i: in std_logic;
		underflows_o: out std_logic_vector(15 downto 0) -- Ring underflows (saturating)
	);
end audio_mixer;

architecture arch of audio_mixer is
	component audio_ram is
		port(
			clk_i: in std_logic;
			we_i: in std_logic;
			waddr_i: in std_logic_vector(11 downto 0);
			wdata_i: in std_logic_vector(7 downto 0);
			raddr_i: in std_logic_vector(11 downto 0);
			rdata_o: out std_logic_vector(7 downto 0)
		);
	end component;

	constant STEP: natural := 14798; -- round(11025 / 48828.125 * 65536) = round(14797.50)
	constant ITEMS: natural := 21; -- 18 sounds + 3 music tracks
	constant HEAD_BASE: natural := 2304; -- Heads after the nine rings
	constant HEAD: natural := 64; -- Bytes per head and per refill chunk
	constant MUSIC_ITEM0: natural := 17; -- Item of track t is 17 + t
	constant MUSIC_VOL: natural := 40;

	-- Item table (32 deep so it maps onto LUT RAM; 21 used)
	type addr_array_t is array (0 to 31) of unsigned(23 downto 0);
	type len_array_t is array (0 to 31) of unsigned(19 downto 0);
	type u20_9_t is array (0 to 8) of unsigned(19 downto 0);
	type u8_9_t is array (0 to 8) of unsigned(7 downto 0);
	type u32_8_t is array (0 to 7) of unsigned(31 downto 0);
	type u7_8_t is array (0 to 7) of unsigned(6 downto 0);
	type u5_8_t is array (0 to 7) of unsigned(4 downto 0);
	type u4_8_t is array (0 to 7) of unsigned(3 downto 0);
	type fifo_t is array (0 to 15) of std_logic_vector(SND_BITS - 1 downto 0);

	------------------------------------------------------------------
	-- Fetch machine (owns the directory, the fill counters, the flash
	-- port and the RAM write port)
	------------------------------------------------------------------
	type fstate_t is (F_OFF, F_HDR_REQ, F_HDR, F_ENT_REQ, F_ENT, F_HEAD_REQ, F_HEAD,
		F_SCAN, F_DECIDE, F_REQ, F_DATA, F_COMMIT);
	signal f_state: fstate_t := F_OFF;
	signal item_addr: addr_array_t := (others => (others => '0')); -- Flash address of each item
	signal item_len: len_array_t := (others => (others => '0')); -- Its length in bytes (0: absent)
	signal tbl_we: std_logic := '0';
	signal tbl_item: natural range 0 to 31 := 0;
	signal tbl_addr: unsigned(23 downto 0) := (others => '0');
	signal tbl_len: unsigned(19 downto 0) := (others => '0');
	signal fill: u20_9_t := (others => (others => '0'));
	signal fill_gen: u8_9_t := (others => (others => '0'));
	signal mfpos: unsigned(19 downto 0) := (others => '0'); -- Track offset of the next music byte to fetch
	signal entries: unsigned(15 downto 0) := (others => '0');
	signal bytes: unsigned(15 downto 0) := (others => '0'); -- Bytes of the current reply so far
	signal entry: std_logic_vector(95 downto 0) := (others => '0');
	signal fv: natural range 0 to ITEMS := 0; -- Item (heads) or voice (refills) being served
	signal sv: natural range 0 to 8 := 0; -- Ring the refill scan looks at next
	signal cur_gen: unsigned(7 downto 0) := (others => '0'); -- gen of the voice when its chunk was requested
	-- Copy of the ring under scan (F_SCAN -> F_DECIDE)
	signal s_act, s_genok: std_logic := '0';
	signal s_gen: unsigned(7 downto 0) := (others => '0');
	signal s_fill, s_idx, s_len, s_off: unsigned(19 downto 0) := (others => '0'); -- s_off: item offset of the next fetch
	signal s_addr: unsigned(23 downto 0) := (others => '0');
	signal w_fill, w_mf: unsigned(19 downto 0) := (others => '0'); -- fill / mfpos while a chunk arrives
	signal ready: std_logic := '0'; -- Directory and heads loaded
	signal f_req_valid: std_logic := '0';
	signal f_req_addr: unsigned(23 downto 0) := (others => '0');
	signal f_req_len: unsigned(23 downto 0) := (others => '0');
	signal ram_we: std_logic := '0';
	signal ram_waddr: unsigned(11 downto 0) := (others => '0');
	signal ram_wdata: std_logic_vector(7 downto 0) := (others => '0');

	------------------------------------------------------------------
	-- Mix machine (owns the voices, the music position, the command
	-- queue, the RAM read address and the outputs)
	------------------------------------------------------------------
	type mstate_t is (M_IDLE, M_CMD, M_ALLOC, M_START, M_VLOOK, M_VOICE, M_VWAIT, M_VREAD, M_VMUL,
		M_VACC, M_MUSIC, M_MWAIT, M_MREAD, M_MMUL, M_MACC, M_MADV, M_OUT1, M_OUT2);
	signal m_state: mstate_t := M_IDLE;
	signal fifo: fifo_t := (others => (others => '0'));
	signal wp, rp: unsigned(4 downto 0) := (others => '0');
	signal napply: unsigned(4 downto 0) := (others => '0');
	-- Command being started: the command, its gains, the allocation scan
	signal c_cmd: std_logic_vector(SND_BITS - 1 downto 0) := (others => '0');
	signal c_gl, c_gr: unsigned(6 downto 0) := (others => '0');
	signal c_free: std_logic := '0'; -- A free voice was found (c_slot)
	signal c_slot, c_low, sc: natural range 0 to 7 := 0; -- c_low: lowest priority so far
	signal active: std_logic_vector(7 downto 0) := (others => '0');
	signal vitem: u5_8_t := (others => (others => '0'));
	signal pos: u32_8_t := (others => (others => '0'));
	signal gl, gr: u7_8_t := (others => (others => '0'));
	signal pri: u4_8_t := (others => (others => '0'));
	signal gen: u8_9_t := (others => (others => '0'));
	signal track: unsigned(1 downto 0) := (others => '0');
	signal mpos: unsigned(35 downto 0) := (others => '0');
	signal ru: unsigned(19 downto 0) := (others => '0');
	signal mhead: std_logic := '1'; -- Music still reading its head
	signal mv: natural range 0 to 7 := 0;
	-- Copy of voice mv (M_VLOOK)
	signal v_act, v_ok: std_logic := '0';
	signal v_item: unsigned(4 downto 0) := (others => '0');
	signal v_pos: unsigned(31 downto 0) := (others => '0');
	signal v_gl, v_gr: unsigned(6 downto 0) := (others => '0');
	signal v_len, v_fill: unsigned(19 downto 0) := (others => '0');
	signal mnext: unsigned(35 downto 0) := (others => '0');
	signal m_len: unsigned(19 downto 0) := (others => '0');
	signal smp: signed(8 downto 0) := (others => '0'); -- byte - 128
	signal prod_l, prod_r: signed(16 downto 0) := (others => '0');
	signal out_l, out_r: signed(28 downto 0) := (others => '0');
	signal valid_byte: std_logic := '0';
	signal acc_l, acc_r: signed(21 downto 0) := (others => '0');
	signal busy_n: unsigned(3 downto 0) := (others => '0');
	signal ram_raddr: unsigned(11 downto 0) := (others => '0');
	signal ram_rdata: std_logic_vector(7 downto 0);
	signal left_q, right_q: signed(15 downto 0) := (others => '0');
	signal underflows: unsigned(15 downto 0) := (others => '0');
	signal full: std_logic;

	-- Signed difference a - b of two mod-2^20 counters (how far a is ahead)
	function ahead(a: unsigned(19 downto 0); b: unsigned(19 downto 0)) return signed is
	begin
		return signed(a - b);
	end function;

	-- Next ring of the round-robin refill scan
	function next9(v: natural range 0 to 8) return natural is
	begin
		if (v = 8) then
			return 0;
		end if;
		return v + 1;
	end function;

	-- min(64, remaining) for a refill or head request
	function chunk(remaining: unsigned(19 downto 0)) return unsigned is
	begin
		if (remaining > HEAD) then
			return to_unsigned(HEAD, 24);
		end if;
		return resize(remaining, 24);
	end function;

	-- Saturate to 16 bits
	function sat16(q: signed(24 downto 0)) return signed is
	begin
		if (q > 32767) then
			return to_signed(32767, 16);
		elsif (q < -32768) then
			return to_signed(-32768, 16);
		end if;
		return q(15 downto 0);
	end function;
begin
	ram: audio_ram
		port map (
			clk_i => clk_i,
			we_i => ram_we,
			waddr_i => std_logic_vector(ram_waddr),
			wdata_i => ram_wdata,
			raddr_i => std_logic_vector(ram_raddr),
			rdata_o => ram_rdata
		);

	-- Item table: LUT RAM, written while the directory is read, read
	-- asynchronously by both machines (no reset, so it is not made of
	-- flip-flops; the directory is read again after every reset)
	process(clk_i)
	begin
		if rising_edge(clk_i) then
			if (tbl_we = '1') then
				item_addr(tbl_item) <= tbl_addr;
				item_len(tbl_item) <= tbl_len;
			end if;
		end if;
	end process;

	------------------------------------------------------------------
	-- Fetch machine
	------------------------------------------------------------------
	process(clk_i, rst_i)
		variable ent: std_logic_vector(95 downto 0);
		variable id: unsigned(31 downto 0);
		variable item: integer range -1 to ITEMS - 1;
	begin
		if (rst_i = '1') then
			f_state <= F_OFF;
			tbl_we <= '0';
			tbl_item <= 0;
			tbl_addr <= (others => '0');
			tbl_len <= (others => '0');
			fill <= (others => (others => '0'));
			fill_gen <= (others => (others => '0'));
			mfpos <= (others => '0');
			entries <= (others => '0');
			bytes <= (others => '0');
			entry <= (others => '0');
			fv <= 0;
			sv <= 0;
			cur_gen <= (others => '0');
			s_act <= '0';
			s_genok <= '0';
			s_gen <= (others => '0');
			s_fill <= (others => '0');
			s_idx <= (others => '0');
			s_len <= (others => '0');
			s_off <= (others => '0');
			s_addr <= (others => '0');
			w_fill <= (others => '0');
			w_mf <= (others => '0');
			ready <= '0';
			f_req_valid <= '0';
			f_req_addr <= (others => '0');
			f_req_len <= (others => '0');
			ram_we <= '0';
			ram_waddr <= (others => '0');
			ram_wdata <= (others => '0');
		elsif rising_edge(clk_i) then
			ram_we <= '0';
			tbl_we <= '0';
			case f_state is
				when F_OFF =>
					if (enable_i = '1') then
						if (ready = '1') then
							f_state <= F_SCAN;
						else
							f_state <= F_HDR_REQ;
						end if;
					end if;

				-- Directory header: "SHOOTER0", version, entry count
				when F_HDR_REQ =>
					f_req_valid <= '1';
					f_req_addr <= to_unsigned(FLASH_DATA_BASE, 24);
					f_req_len <= to_unsigned(12, 24);
					bytes <= (others => '0');
					if ((f_req_valid = '1') and (req_ready_i = '1')) then
						f_req_valid <= '0';
						f_state <= F_HDR;
					end if;
				when F_HDR =>
					if (data_valid_i = '1') then
						bytes <= bytes + 1;
						-- Entry count is header bytes 10..11, little endian
						if (bytes = 10) then
							entries(7 downto 0) <= unsigned(data_i);
						elsif (bytes = 11) then
							entries(15 downto 8) <= unsigned(data_i);
						end if;
						if (data_last_i = '1') then
							f_state <= F_ENT_REQ;
						end if;
					end if;

				-- Directory entries: id, offset, length (12 bytes each)
				when F_ENT_REQ =>
					f_req_valid <= '1';
					f_req_addr <= to_unsigned(FLASH_DATA_BASE + 12, 24);
					f_req_len <= resize(entries * 12, 24);
					bytes <= (others => '0');
					if ((f_req_valid = '1') and (req_ready_i = '1')) then
						f_req_valid <= '0';
						f_state <= F_ENT;
					end if;
				when F_ENT =>
					if (data_valid_i = '1') then
						-- Bytes arrive first to last: shift in from the top
						entry <= data_i & entry(95 downto 8);
						if (bytes = 11) then
							bytes <= (others => '0');
							-- Whole entry, byte i at bits 8i+7..8i: id 31:0,
							-- offset 63:32, length 95:64 (little endian)
							ent := data_i & entry(95 downto 8);
							id := unsigned(ent(31 downto 0));
							item := -1;
							if ((id >= 16) and (id <= 33)) then
								item := to_integer(id(5 downto 0)) - 16; -- Sounds: items 0..17
							elsif ((id >= 40) and (id <= 42)) then
								-- Music tracks 1..3: items 18..20
								item := to_integer(id(5 downto 0)) - 40 + MUSIC_ITEM0 + 1;
							end if;
							if (item >= 0) then
								-- Keep 24 offset bits (4 MB flash) and 20 length bits
								tbl_we <= '1';
								tbl_item <= item;
								tbl_addr <= to_unsigned(FLASH_DATA_BASE, 24) + unsigned(ent(55 downto 32));
								tbl_len <= unsigned(ent(83 downto 64));
							end if;
						else
							bytes <= bytes + 1;
						end if;
						if (data_last_i = '1') then
							fv <= 0;
							f_state <= F_HEAD_REQ;
						end if;
					end if;

				-- Heads: the first 64 bytes of every item
				when F_HEAD_REQ =>
					if (fv = ITEMS) then
						ready <= '1';
						fv <= 0;
						f_state <= F_SCAN;
					elsif (item_len(fv) = 0) then
						fv <= fv + 1;
					else
						f_req_valid <= '1';
						f_req_addr <= item_addr(fv);
						f_req_len <= chunk(item_len(fv));
						bytes <= (others => '0');
						if ((f_req_valid = '1') and (req_ready_i = '1')) then
							f_req_valid <= '0';
							f_state <= F_HEAD;
						end if;
					end if;
				when F_HEAD =>
					if (data_valid_i = '1') then
						ram_we <= '1';
						ram_waddr <= to_unsigned(HEAD_BASE + fv * HEAD, 12) + bytes(11 downto 0);
						ram_wdata <= data_i;
						bytes <= bytes + 1;
						if (data_last_i = '1') then
							fv <= fv + 1;
							f_state <= F_HEAD_REQ;
						end if;
					end if;

				-- Refills: visit the nine rings in turn. F_SCAN copies the
				-- ring's state into s_* registers, F_DECIDE acts on them
				-- (two clocks per ring keep the multiplexers out of the
				-- request arithmetic).
				when F_SCAN =>
					s_gen <= gen(sv);
					if (fill_gen(sv) = gen(sv)) then
						s_genok <= '1';
					else
						s_genok <= '0';
					end if;
					s_fill <= fill(sv);
					if (sv < 8) then
						s_act <= active(sv);
						s_idx <= resize(pos(sv)(31 downto 16), 20);
						s_len <= item_len(to_integer(vitem(sv)));
						s_addr <= item_addr(to_integer(vitem(sv)));
						s_off <= fill(sv);
					else
						if (track /= 0) then
							s_act <= '1';
						else
							s_act <= '0';
						end if;
						s_idx <= ru;
						s_len <= item_len(MUSIC_ITEM0 + to_integer(track));
						s_addr <= item_addr(MUSIC_ITEM0 + to_integer(track));
						s_off <= mfpos;
					end if;
					if (enable_i = '0') then
						f_state <= F_OFF;
					else
						f_state <= F_DECIDE;
					end if;
				when F_DECIDE =>
					sv <= next9(sv);
					f_state <= F_SCAN;
					if (s_genok = '0') then
						-- The voice was restarted: start its ring again
						fill_gen(sv) <= s_gen;
						fill(sv) <= to_unsigned(HEAD, 20);
						if (sv = 8) then
							mfpos <= to_unsigned(HEAD, 20);
						end if;
					elsif ((s_act = '1') and ((sv = 8) or (s_off < s_len)) and (ahead(s_fill, s_idx) <= 192)) then
						-- At most 192 bytes ahead: fetch the next chunk
						-- (music: up to the end of the track; the next
						-- chunk starts again at its beginning)
						f_req_valid <= '1';
						f_req_addr <= s_addr + resize(s_off, 24);
						f_req_len <= chunk(s_len - s_off);
						cur_gen <= s_gen;
						fv <= sv;
						w_fill <= s_fill;
						w_mf <= s_off;
						f_state <= F_REQ;
					end if;
				when F_REQ =>
					if (req_ready_i = '1') then
						f_req_valid <= '0';
						f_state <= F_DATA;
					end if;
				when F_DATA =>
					-- w_fill / w_mf count the chunk's bytes; they are
					-- committed to fill / mfpos after the last one
					if (data_valid_i = '1') then
						ram_we <= '1';
						ram_waddr <= to_unsigned(fv, 4) & w_fill(7 downto 0); -- Ring fv: fv * 256 + fill mod 256
						ram_wdata <= data_i;
						w_fill <= w_fill + 1;
						if (w_mf + 1 = s_len) then
							w_mf <= (others => '0');
						else
							w_mf <= w_mf + 1;
						end if;
						if (data_last_i = '1') then
							f_state <= F_COMMIT;
						end if;
					end if;
				when F_COMMIT =>
					-- A chunk fetched for a sound that has been replaced
					-- since is not committed (its ring restarts instead)
					if (gen(fv) = cur_gen) then
						fill(fv) <= w_fill;
						if (fv = 8) then
							mfpos <= w_mf;
						end if;
					end if;
					f_state <= F_SCAN;
			end case;
		end if;
	end process;

	req_valid_o <= f_req_valid;
	req_id_o <= '0';
	req_addr_o <= std_logic_vector(f_req_addr);
	req_len_o <= std_logic_vector(f_req_len);
	data_ready_o <= '1';

	------------------------------------------------------------------
	-- Mix machine
	------------------------------------------------------------------
	-- 5-bit pointers over 16 slots: the extra bit tells full from empty
	full <= '1' when ((wp - rp) = 16) else '0';
	snd_ready_o <= not full;

	-- Command queue storage: LUT RAM, written at wp, read at rp
	process(clk_i)
	begin
		if rising_edge(clk_i) then
			if ((snd_valid_i = '1') and (full = '0')) then
				fifo(to_integer(wp(3 downto 0))) <= snd_data_i;
			end if;
		end if;
	end process;

	process(clk_i, rst_i)
		variable vol: unsigned(5 downto 0);
		variable pan: signed(6 downto 0);
		variable slot: integer range -1 to 7;
		variable idx: unsigned(19 downto 0);
		variable mitem: natural range 0 to ITEMS - 1;
		variable g: unsigned(6 downto 0);
	begin
		if (rst_i = '1') then
			m_state <= M_IDLE;
			wp <= (others => '0');
			rp <= (others => '0');
			napply <= (others => '0');
			c_cmd <= (others => '0');
			c_gl <= (others => '0');
			c_gr <= (others => '0');
			c_free <= '0';
			c_slot <= 0;
			c_low <= 0;
			sc <= 0;
			active <= (others => '0');
			vitem <= (others => (others => '0'));
			pos <= (others => (others => '0'));
			gl <= (others => (others => '0'));
			gr <= (others => (others => '0'));
			pri <= (others => (others => '0'));
			gen <= (others => (others => '0'));
			v_act <= '0';
			v_item <= (others => '0');
			v_pos <= (others => '0');
			v_gl <= (others => '0');
			v_gr <= (others => '0');
			v_len <= (others => '0');
			v_ok <= '0';
			v_fill <= (others => '0');
			track <= (others => '0');
			mpos <= (others => '0');
			mnext <= (others => '0');
			m_len <= (others => '0');
			ru <= (others => '0');
			mhead <= '1';
			mv <= 0;
			valid_byte <= '0';
			smp <= (others => '0');
			prod_l <= (others => '0');
			prod_r <= (others => '0');
			acc_l <= (others => '0');
			acc_r <= (others => '0');
			out_l <= (others => '0');
			out_r <= (others => '0');
			busy_n <= (others => '0');
			ram_raddr <= (others => '0');
			left_q <= (others => '0');
			right_q <= (others => '0');
			underflows <= (others => '0');
		elsif rising_edge(clk_i) then
			-- Command queue: take one command per clock while there is room
			if ((snd_valid_i = '1') and (full = '0')) then
				wp <= wp + 1;
			end if;

			case m_state is
				when M_IDLE =>
					if (sample_req_i = '1') then
						if ((enable_i = '0') or (ready = '0')) then
							-- Silent: drop waiting commands, stop every voice
							rp <= wp;
							active <= (others => '0');
							if (track /= 0) then
								track <= (others => '0');
								gen(8) <= gen(8) + 1;
							end if;
							left_q <= (others => '0');
							right_q <= (others => '0');
						else
							-- Commands taken before this cycle are applied now
							napply <= wp - rp;
							if (unsigned(music_i) /= track) then
								track <= unsigned(music_i);
								mpos <= (others => '0');
								ru <= (others => '0');
								mhead <= '1';
								gen(8) <= gen(8) + 1;
							end if;
							acc_l <= (others => '0');
							acc_r <= (others => '0');
							busy_n <= (others => '0');
							m_state <= M_CMD;
						end if;
					end if;

				-- Start the waiting sounds in order: M_CMD takes one from
				-- the queue, M_ALLOC looks at voices 0..7 one per clock
				-- (first free voice, lowest priority with lowest index),
				-- M_START sets up the chosen voice. 10 clocks per command.
				when M_CMD =>
					if (napply = 0) then
						mv <= 0;
						m_state <= M_VLOOK;
					else
						c_cmd <= fifo(to_integer(rp(3 downto 0)));
						rp <= rp + 1;
						napply <= napply - 1;
						c_free <= '0';
						c_low <= 0;
						sc <= 0;
						m_state <= M_ALLOC;
					end if;
				when M_ALLOC =>
					vol := unsigned(c_cmd(SND_VOL_HI downto SND_VOL_LO));
					pan := resize(signed(c_cmd(SND_PAN_HI downto SND_PAN_LO)), 7);
					-- Gains (vol * (31 - pan)) >> 5 left and (vol * (31 + pan)) >> 5 right
					c_gl <= resize(shift_right(resize(vol, 13) * unsigned(to_signed(31, 7) - pan), 5), 7);
					c_gr <= resize(shift_right(resize(vol, 13) * unsigned(to_signed(31, 7) + pan), 5), 7);
					if ((active(sc) = '0') and (c_free = '0')) then
						c_free <= '1';
						c_slot <= sc;
					end if;
					if (pri(sc) < pri(c_low)) then
						c_low <= sc;
					end if;
					if (sc = 7) then
						m_state <= M_START;
					else
						sc <= sc + 1;
					end if;
				when M_START =>
					slot := -1;
					if (c_free = '1') then
						slot := c_slot;
					elsif (pri(c_low) < unsigned(c_cmd(SND_PRI_HI downto SND_PRI_LO))) then
						slot := c_low;
					end if;
					if (unsigned(c_cmd(SND_ID_HI downto SND_ID_LO)) >= 18) then
						slot := -1; -- No such sound: ignored
					end if;
					if (slot >= 0) then
						active(slot) <= '1';
						vitem(slot) <= unsigned(c_cmd(SND_ID_HI downto SND_ID_LO));
						pos(slot) <= (others => '0');
						gl(slot) <= c_gl;
						gr(slot) <= c_gr;
						pri(slot) <= unsigned(c_cmd(SND_PRI_HI downto SND_PRI_LO));
						gen(slot) <= gen(slot) + 1;
					end if;
					m_state <= M_CMD;

				-- Effect voices 0..7. M_VLOOK copies voice mv into v_*;
				-- M_VOICE ends it or sets the RAM address; the RAM reads
				-- at the M_VWAIT clock; M_VREAD takes the byte, M_VMUL
				-- multiplies by the gains, M_VACC adds and advances.
				when M_VLOOK =>
					v_act <= active(mv);
					v_item <= vitem(mv);
					v_pos <= pos(mv);
					v_gl <= gl(mv);
					v_gr <= gr(mv);
					v_len <= item_len(to_integer(vitem(mv)));
					if (fill_gen(mv) = gen(mv)) then
						v_ok <= '1';
					else
						v_ok <= '0';
					end if;
					v_fill <= fill(mv);
					m_state <= M_VOICE;
				when M_VOICE =>
					idx := resize(v_pos(31 downto 16), 20); -- Byte index: integer part of the Q.16 position
					if ((v_act = '0') or (idx >= v_len)) then
						-- Free, or the sound has ended (the model frees it
						-- here too, without output)
						active(mv) <= '0';
						if (mv = 7) then
							m_state <= M_MUSIC;
						else
							mv <= mv + 1;
							m_state <= M_VLOOK;
						end if;
					else
						-- Bytes 0..63 from the item's head, later ones from ring mv once fetched
						if (idx < HEAD) then
							ram_raddr <= to_unsigned(HEAD_BASE, 12) + shift_left(resize(v_item, 12), 6) +
								idx(11 downto 0);
							valid_byte <= '1';
						elsif ((v_ok = '1') and (ahead(v_fill, idx) > 0)) then
							ram_raddr <= to_unsigned(mv, 4) & idx(7 downto 0);
							valid_byte <= '1';
						else
							valid_byte <= '0';
						end if;
						m_state <= M_VWAIT;
					end if;
				when M_VWAIT =>
					m_state <= M_VREAD;
				when M_VREAD =>
					if (valid_byte = '1') then
						smp <= signed(resize(unsigned(ram_rdata), 9)) - 128;
					else
						smp <= (others => '0');
						if (underflows /= x"FFFF") then
							underflows <= underflows + 1;
						end if;
					end if;
					m_state <= M_VMUL;
				when M_VMUL =>
					prod_l <= smp * signed('0' & v_gl);
					prod_r <= smp * signed('0' & v_gr);
					m_state <= M_VACC;
				when M_VACC =>
					acc_l <= acc_l + resize(prod_l, 22);
					acc_r <= acc_r + resize(prod_r, 22);
					pos(mv) <= v_pos + STEP;
					busy_n <= busy_n + 1;
					if (mv = 7) then
						m_state <= M_MUSIC;
					else
						mv <= mv + 1;
						m_state <= M_VLOOK;
					end if;

				-- Music voice: same steps, then the position advances and
				-- wraps at the end of the track in M_MACC / M_MADV
				when M_MUSIC =>
					if (track = 0) then
						m_state <= M_OUT1;
					else
						mitem := MUSIC_ITEM0 + to_integer(track);
						m_len <= item_len(mitem);
						if (mhead = '1') then
							ram_raddr <= to_unsigned(HEAD_BASE + mitem * HEAD, 12) + resize(ru(5 downto 0), 12);
							valid_byte <= '1';
						elsif ((fill_gen(8) = gen(8)) and (ahead(fill(8), ru) > 0)) then
							ram_raddr <= x"8" & ru(7 downto 0); -- Music ring 8 at 8 * 256
							valid_byte <= '1';
						else
							valid_byte <= '0';
						end if;
						m_state <= M_MWAIT;
					end if;
				when M_MWAIT =>
					m_state <= M_MREAD;
				when M_MREAD =>
					if (valid_byte = '1') then
						smp <= signed(resize(unsigned(ram_rdata), 9)) - 128;
					else
						smp <= (others => '0');
						if (underflows /= x"FFFF") then
							underflows <= underflows + 1;
						end if;
					end if;
					m_state <= M_MMUL;
				when M_MMUL =>
					if (busy_n > 4) then
						g := to_unsigned(MUSIC_VOL / 2, 7);
					else
						g := to_unsigned(MUSIC_VOL, 7);
					end if;
					prod_l <= smp * signed('0' & g);
					prod_r <= smp * signed('0' & g);
					m_state <= M_MACC;
				when M_MACC =>
					acc_l <= acc_l + resize(prod_l, 22);
					acc_r <= acc_r + resize(prod_r, 22);
					mnext <= mpos + STEP;
					m_state <= M_MADV;
				when M_MADV =>
					-- Wrap at the track length (the model's mpos -= len << 16)
					if (mnext(35 downto 16) >= m_len) then
						mpos <= (mnext(35 downto 16) - m_len) & mnext(15 downto 0);
					else
						mpos <= mnext;
					end if;
					-- STEP < 1.0: the byte index moves by 0 or 1 (a wrap
					-- also counts as one), so ru follows the stream
					if (mnext(35 downto 16) /= mpos(35 downto 16)) then
						ru <= ru + 1;
						if (ru = HEAD - 1) then
							mhead <= '0';
						end if;
					end if;
					m_state <= M_OUT1;

				-- Output: (mix * master) >> 4, saturated to 16 bits
				when M_OUT1 =>
					out_l <= acc_l * signed('0' & master_i);
					out_r <= acc_r * signed('0' & master_i);
					m_state <= M_OUT2;
				when M_OUT2 =>
					left_q <= sat16(out_l(28 downto 4));
					right_q <= sat16(out_r(28 downto 4));
					m_state <= M_IDLE;
			end case;
		end if;
	end process;

	left_o <= std_logic_vector(left_q);
	right_o <= std_logic_vector(right_q);
	underflows_o <= std_logic_vector(underflows);
end arch;
