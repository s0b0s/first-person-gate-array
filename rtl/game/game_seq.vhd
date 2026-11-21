--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Maze Game Sequencer
-- Module Name:    game_seq
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    Maze game sequencer: once per frame runs the player and
--                 door update of Game.step (tools/model/game.py) bit for
--                 bit, then hands the result to the renderer.
--                 One step (integer, ">>" = arithmetic shift):
--                   1 angle = (angle + turn) mod 1024
--                   2 cs, sn = cos, sin(angle) (Q2.16, SIN_TABLE)
--                     vx = move*cs - strafe*sn, vy = move*sn + strafe*cs
--                     dx = vx >> 4, dy = vy >> 4 (>> 3 when running)
--                   3 move x, then y: the player box (half size 0.25 tile
--                     = 16384) is tested against the 2 x 2 cells it
--                     overlaps (4 map port B reads). Solid = wall texture
--                     /= 0 unless a fully open (64) door. If blocked, the
--                     box goes flush against the cell:
--                       dx > 0: max(px, ((nx + HALF) with bits 15:0 cleared)
--                               - HALF - 1)
--                       dx < 0: min(px, ((nx - HALF) with bits 15:0 cleared)
--                               + 65536 + HALF)
--                   4 use: cell at (px + (3 cs >> 2), py + (3 sn >> 2)); a
--                     door there opens (first idle entry), closes if open
--                     and the player is not in it, or reopens if closing
--                   5 doors, all 8 in parallel: OPENING +2 per frame to
--                     64, OPEN 180 frames, CLOSING -2 per frame to 0
--                     (IDLE); a closing door with the player inside
--                     reopens, an expiring open one waits 30 more frames
--                 The outputs change only when render_start_o pulses, so
--                 the renderer sees one consistent frame.
--                 Door table: parallel arrays, looked up by cell in a
--                 combinational process. ROM and map addresses are
--                 combinational so reads start in the same clock.
--                 Clock domain: clk_i (system). About 25 clocks per frame.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std, game_pkg,
--                 render_pkg (SIN_TABLE), render_types_pkg
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - Player, collision, doors
-- Revision 1.01 - Plain signals instead of records; one-process state machine
-- Additional Comments:
--                 None.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.game_pkg.all;
use work.render_pkg.all;
use work.render_types_pkg.all;

entity game_seq is
	port(
		clk_i: in std_logic; -- System clock
		rst_i: in std_logic; -- Asynchronous reset, active high
		load_i: in std_logic; -- Pulse: start pose below, door table cleared
		start_x_i: in std_logic_vector(POS_BITS - 1 downto 0); -- Q6.16
		start_y_i: in std_logic_vector(POS_BITS - 1 downto 0); -- Q6.16
		start_angle_i: in std_logic_vector(ANGLE_BITS - 1 downto 0);
		frame_start_i: in std_logic; -- Pulse from the buffer manager
		snapshot_i: in std_logic_vector(SNAP_BITS - 1 downto 0); -- Input snapshot
		snapshot_valid_i: in std_logic; -- Pulse, 2 clocks after frame_start_i
		map_addr_o: out std_logic_vector(11 downto 0); -- Map port B, y & x
		map_data_i: in std_logic_vector(23 downto 0); -- Tile word, 1 clock later
		pos_x_o: out std_logic_vector(POS_BITS - 1 downto 0); -- Renderer registers
		pos_y_o: out std_logic_vector(POS_BITS - 1 downto 0);
		angle_o: out std_logic_vector(ANGLE_BITS - 1 downto 0);
		eye_o: out std_logic_vector(EYE_BITS - 1 downto 0); -- 32 in game_top
		doors_o: out std_logic_vector(DOORS_BITS - 1 downto 0); -- Idle entries zero
		render_start_o: out std_logic; -- Pulse: outputs hold this frame's state
		busy_o: out std_logic; -- Update running (map port B in use)
		door_state_o: out std_logic_vector(8 * 2 - 1 downto 0); -- Debug: entry states
		door_timer_o: out std_logic_vector(8 * 8 - 1 downto 0) -- Debug: entry timers
	);
end game_seq;

architecture arch of game_seq is
	constant HALF: integer := 16384; -- Player half size R, 0.25 tile in Q.16
	constant DOOR_STEP: integer := 2;
	constant DOOR_OPEN: integer := 64;
	constant DOOR_STAY: natural := 180; -- Frames a door stays open (3 s)
	constant DOOR_RETRY: natural := 30; -- Extra frames when the player is in it
	constant ST_IDLE: unsigned(1 downto 0) := "00";
	constant ST_OPENING: unsigned(1 downto 0) := "01";
	constant ST_OPEN: unsigned(1 downto 0) := "10";
	constant ST_CLOSING: unsigned(1 downto 0) := "11";

	subtype pos_t is signed(23 downto 0); -- Q6.16 with headroom for +/- HALF
	subtype trig_t is signed(17 downto 0); -- Q2.16

	-- Door table, 8 entries as parallel arrays
	type cell_array_t is array (0 to 7) of unsigned(5 downto 0);
	type amt_array_t is array (0 to 7) of signed(7 downto 0);
	type st_array_t is array (0 to 7) of unsigned(1 downto 0);
	type timer_array_t is array (0 to 7) of unsigned(7 downto 0);

	type seq_state_type is (SEQ_IDLE, SEQ_TURN, SEQ_SIN, SEQ_COS, SEQ_VEL, SEQ_MX, SEQ_MY,
		SEQ_BOX_A, SEQ_BOX_D, SEQ_MX_END, SEQ_MY_END, SEQ_USE, SEQ_USE_D, SEQ_DOORS, SEQ_OUT);
	signal seq_state: seq_state_type := SEQ_IDLE;

	signal armed: std_logic := '0'; -- frame_start seen, waiting for the snapshot
	signal snap: std_logic_vector(SNAP_BITS - 1 downto 0) := (others => '0');
	signal px: pos_t := (others => '0');
	signal py: pos_t := (others => '0');
	signal angle: unsigned(9 downto 0) := (others => '0');
	signal cs: trig_t := (others => '0');
	signal sn: trig_t := (others => '0');
	signal dx: pos_t := (others => '0');
	signal dy: pos_t := (others => '0');
	signal bx: pos_t := (others => '0'); -- Box center under test
	signal by: pos_t := (others => '0');
	signal k: unsigned(1 downto 0) := (others => '0'); -- Box cell 0..3: bit 0 picks x, bit 1 picks y
	signal hit: std_logic := '0'; -- A tested cell was solid
	signal ctx_y: std_logic := '0'; -- Box test is for the y move
	signal door_x: cell_array_t := (others => (others => '0'));
	signal door_y: cell_array_t := (others => (others => '0'));
	signal door_amt: amt_array_t := (others => (others => '0')); -- Open amount 0..64
	signal door_st: st_array_t := (others => ST_IDLE);
	signal door_timer: timer_array_t := (others => (others => '0'));
	signal ucell: unsigned(11 downto 0) := (others => '0'); -- Use target cell, y & x
	signal start: std_logic := '0';
	signal out_x: std_logic_vector(POS_BITS - 1 downto 0) := (others => '0');
	signal out_y: std_logic_vector(POS_BITS - 1 downto 0) := (others => '0');
	signal out_angle: std_logic_vector(ANGLE_BITS - 1 downto 0) := (others => '0');
	signal out_doors: std_logic_vector(DOORS_BITS - 1 downto 0) := (others => '0');
	signal out_state: std_logic_vector(15 downto 0) := (others => '0');
	signal out_timer: std_logic_vector(63 downto 0) := (others => '0');

	signal rom_addr: unsigned(9 downto 0);
	signal rom_data: trig_t := (others => '0');
	signal map_addr: unsigned(11 downto 0);
	-- Velocity, Q2.16 (valid in SEQ_VEL, when rom_data holds cos)
	signal vel_x: signed(19 downto 0);
	signal vel_y: signed(19 downto 0);
	-- Box corner k: cell index = bits 21:16 of (b -/+ HALF)
	signal corner_x: pos_t;
	signal corner_y: pos_t;
	signal box_cell: unsigned(11 downto 0);
	-- Use target 0.75 tile ahead: c * 3 >> 2
	signal cs3: signed(19 downto 0);
	signal sn3: signed(19 downto 0);
	signal use_x: pos_t;
	signal use_y: pos_t;
	signal use_cell: unsigned(11 downto 0);
	-- Cells under the edges of the player box at (px, py)
	signal pl_xm: pos_t;
	signal pl_xp: pos_t;
	signal pl_ym: pos_t;
	signal pl_yp: pos_t;
	signal pl_x0: unsigned(5 downto 0);
	signal pl_x1: unsigned(5 downto 0);
	signal pl_y0: unsigned(5 downto 0);
	signal pl_y1: unsigned(5 downto 0);
	-- Door table lookups
	signal box_open: std_logic; -- First active entry at box_cell is fully open
	signal use_found: std_logic; -- An active entry is at ucell ...
	signal use_idx: natural range 0 to 7; -- ... the first one
	signal free_found: std_logic; -- An idle entry exists ...
	signal free_idx: natural range 0 to 7; -- ... the first one
	signal door_in: std_logic_vector(7 downto 0); -- Entry's cell is under the player box
	signal use_in: std_logic; -- ucell is under the player box

	-- move * c for move in -2..1 (2-bit signed snapshot field)
	function times(m: std_logic_vector(1 downto 0); c: trig_t) return signed is
	begin
		case m is
			when "01" =>
				return resize(c, 20);
			when "11" =>
				return -resize(c, 20);
			when "10" =>
				return -shift_left(resize(c, 20), 1);
			when others =>
				return to_signed(0, 20);
		end case;
	end function;
begin
	------------------------------------------------------------------
	-- Sine ROM (cos(a) = sin(a + 256)), registered read
	------------------------------------------------------------------
	process(clk_i)
	begin
		if rising_edge(clk_i) then
			rom_data <= to_signed(SIN_TABLE(to_integer(rom_addr)), 18);
		end if;
	end process;

	-- sin read in SEQ_SIN (ready in SEQ_COS), cos in SEQ_COS (ready in SEQ_VEL)
	rom_addr <= angle + 256 when (seq_state = SEQ_COS) else angle;

	------------------------------------------------------------------
	-- Combinational datapath
	------------------------------------------------------------------
	-- v = move * (cos, sin) + strafe * (-sin, cos)
	vel_x <= times(snap(SNAP_MOVE_HI downto SNAP_MOVE_LO), rom_data) -
		times(snap(SNAP_STRAFE_HI downto SNAP_STRAFE_LO), sn);
	vel_y <= times(snap(SNAP_MOVE_HI downto SNAP_MOVE_LO), sn) +
		times(snap(SNAP_STRAFE_HI downto SNAP_STRAFE_LO), rom_data);

	corner_x <= bx - HALF when (k(0) = '0') else bx + HALF;
	corner_y <= by - HALF when (k(1) = '0') else by + HALF;
	box_cell <= unsigned(std_logic_vector(corner_y(21 downto 16))) &
		unsigned(std_logic_vector(corner_x(21 downto 16)));

	cs3 <= resize(cs, 20) + shift_left(resize(cs, 20), 1);
	sn3 <= resize(sn, 20) + shift_left(resize(sn, 20), 1);
	use_x <= px + resize(shift_right(cs3, 2), 24);
	use_y <= py + resize(shift_right(sn3, 2), 24);
	use_cell <= unsigned(std_logic_vector(use_y(21 downto 16))) &
		unsigned(std_logic_vector(use_x(21 downto 16)));

	pl_xm <= px - HALF;
	pl_xp <= px + HALF;
	pl_ym <= py - HALF;
	pl_yp <= py + HALF;
	pl_x0 <= unsigned(std_logic_vector(pl_xm(21 downto 16)));
	pl_x1 <= unsigned(std_logic_vector(pl_xp(21 downto 16)));
	pl_y0 <= unsigned(std_logic_vector(pl_ym(21 downto 16)));
	pl_y1 <= unsigned(std_logic_vector(pl_yp(21 downto 16)));
	use_in <= '1' when (((ucell(5 downto 0) = pl_x0) or (ucell(5 downto 0) = pl_x1)) and
		((ucell(11 downto 6) = pl_y0) or (ucell(11 downto 6) = pl_y1))) else '0';

	-- Door table lookups; the loop runs 7 down to 0 so the lowest match wins
	process(door_x, door_y, door_amt, door_st, box_cell, ucell, pl_x0, pl_x1, pl_y0, pl_y1)
	begin
		box_open <= '0';
		use_found <= '0';
		use_idx <= 0;
		free_found <= '0';
		free_idx <= 0;
		for j in 7 downto 0 loop
			if ((door_st(j) /= ST_IDLE) and (door_y(j) & door_x(j) = box_cell)) then
				if (door_amt(j) = DOOR_OPEN) then
					box_open <= '1';
				else
					box_open <= '0';
				end if;
			end if;
			if ((door_st(j) /= ST_IDLE) and (door_y(j) & door_x(j) = ucell)) then
				use_found <= '1';
				use_idx <= j;
			end if;
			if (door_st(j) = ST_IDLE) then
				free_found <= '1';
				free_idx <= j;
			end if;
			if (((door_x(j) = pl_x0) or (door_x(j) = pl_x1)) and
				((door_y(j) = pl_y0) or (door_y(j) = pl_y1))) then
				door_in(j) <= '1';
			else
				door_in(j) <= '0';
			end if;
		end loop;
	end process;

	-- Map port B: box corner under test, or the use target entering SEQ_USE_D
	map_addr <= use_cell when (seq_state = SEQ_USE) else box_cell;

	------------------------------------------------------------------
	-- State machine
	------------------------------------------------------------------
	process(clk_i, rst_i)
		variable edge: pos_t; -- Clamped coordinate of a blocked move
	begin
		if (rst_i = '1') then
			seq_state <= SEQ_IDLE;
			armed <= '0';
			snap <= (others => '0');
			px <= (others => '0');
			py <= (others => '0');
			angle <= (others => '0');
			cs <= (others => '0');
			sn <= (others => '0');
			dx <= (others => '0');
			dy <= (others => '0');
			bx <= (others => '0');
			by <= (others => '0');
			k <= (others => '0');
			hit <= '0';
			ctx_y <= '0';
			door_x <= (others => (others => '0'));
			door_y <= (others => (others => '0'));
			door_amt <= (others => (others => '0'));
			door_st <= (others => ST_IDLE);
			door_timer <= (others => (others => '0'));
			ucell <= (others => '0');
			start <= '0';
			out_x <= (others => '0');
			out_y <= (others => '0');
			out_angle <= (others => '0');
			out_doors <= (others => '0');
			out_state <= (others => '0');
			out_timer <= (others => '0');
		elsif rising_edge(clk_i) then
			start <= '0';
			if (frame_start_i = '1') then
				armed <= '1';
			end if;

			case seq_state is
				when SEQ_IDLE =>
					-- (frame_start and the snapshot may come in the same clock)
					if ((snapshot_valid_i = '1') and ((armed = '1') or (frame_start_i = '1'))) then
						snap <= snapshot_i;
						armed <= '0';
						seq_state <= SEQ_TURN;
					end if;

				when SEQ_TURN =>
					-- Adding the low 10 bits of the signed turn is mod 1024
					angle <= angle + unsigned(snap(SNAP_TURN_LO + 9 downto SNAP_TURN_LO));
					seq_state <= SEQ_SIN;

				when SEQ_SIN =>
					seq_state <= SEQ_COS;

				when SEQ_COS =>
					sn <= rom_data;
					seq_state <= SEQ_VEL;

				when SEQ_VEL =>
					cs <= rom_data;
					-- Full input moves 1/8 tile per frame running, 1/16 walking
					if (snap(SNAP_RUN) = '1') then
						dx <= resize(shift_right(vel_x, 3), 24);
						dy <= resize(shift_right(vel_y, 3), 24);
					else
						dx <= resize(shift_right(vel_x, 4), 24);
						dy <= resize(shift_right(vel_y, 4), 24);
					end if;
					seq_state <= SEQ_MX;

				when SEQ_MX =>
					-- Test the box at the new x, current y
					bx <= px + dx;
					by <= py;
					k <= "00";
					hit <= '0';
					ctx_y <= '0';
					if (dx = 0) then
						seq_state <= SEQ_MY;
					else
						seq_state <= SEQ_BOX_A;
					end if;

				when SEQ_MY =>
					-- Test the box at the final x, new y
					bx <= px;
					by <= py + dy;
					k <= "00";
					hit <= '0';
					ctx_y <= '1';
					if (dy = 0) then
						seq_state <= SEQ_USE;
					else
						seq_state <= SEQ_BOX_A;
					end if;

				when SEQ_BOX_A =>
					-- map_addr is the cell of corner k
					seq_state <= SEQ_BOX_D;

				when SEQ_BOX_D =>
					-- Solid: wall texture /= 0, unless a door that is fully open
					if ((unsigned(map_data_i(TILE_WALL_HI downto TILE_WALL_LO)) /= 0) and
						((unsigned(map_data_i(TILE_SPECIAL_HI downto TILE_SPECIAL_LO)) /= SPECIAL_DOOR) or
						(box_open = '0'))) then
						hit <= '1';
					end if;
					k <= k + 1;
					if (k = 3) then
						if (ctx_y = '0') then
							seq_state <= SEQ_MX_END;
						else
							seq_state <= SEQ_MY_END;
						end if;
					else
						seq_state <= SEQ_BOX_A;
					end if;

				when SEQ_MX_END =>
					if (hit = '0') then
						px <= bx;
					elsif (dx > 0) then
						-- Blocked: slide the box flush against the solid cell
						-- (right side 1 unit short of its left edge)
						edge := ((bx + HALF) and x"FF0000") - HALF - 1;
						if (edge > px) then
							px <= edge;
						end if;
					else
						edge := ((bx - HALF) and x"FF0000") + 65536 + HALF; -- Left side on its right edge
						if (edge < px) then
							px <= edge;
						end if;
					end if;
					seq_state <= SEQ_MY;

				when SEQ_MY_END =>
					-- Same clamp as SEQ_MX_END, for y
					if (hit = '0') then
						py <= by;
					elsif (dy > 0) then
						edge := ((by + HALF) and x"FF0000") - HALF - 1;
						if (edge > py) then
							py <= edge;
						end if;
					else
						edge := ((by - HALF) and x"FF0000") + 65536 + HALF;
						if (edge < py) then
							py <= edge;
						end if;
					end if;
					seq_state <= SEQ_USE;

				when SEQ_USE =>
					-- map_addr = use_cell now, so the tile arrives in SEQ_USE_D
					ucell <= use_cell;
					if (snap(SNAP_USE) = '1') then
						seq_state <= SEQ_USE_D;
					else
						seq_state <= SEQ_DOORS;
					end if;

				when SEQ_USE_D =>
					if ((unsigned(map_data_i(TILE_SPECIAL_HI downto TILE_SPECIAL_LO)) = SPECIAL_DOOR) and
						(unsigned(map_data_i(TILE_WALL_HI downto TILE_WALL_LO)) /= 0)) then
						if (use_found = '0') then
							-- New entry in the first idle slot (none free: ignore)
							if (free_found = '1') then
								door_x(free_idx) <= ucell(5 downto 0);
								door_y(free_idx) <= ucell(11 downto 6);
								door_amt(free_idx) <= (others => '0');
								door_timer(free_idx) <= (others => '0');
								door_st(free_idx) <= ST_OPENING;
							end if;
						elsif (door_st(use_idx) = ST_OPEN) then
							if (use_in = '0') then
								door_st(use_idx) <= ST_CLOSING;
							end if;
						elsif (door_st(use_idx) = ST_CLOSING) then
							door_st(use_idx) <= ST_OPENING;
						end if;
					end if;
					seq_state <= SEQ_DOORS;

				when SEQ_DOORS =>
					-- All 8 entries step at once
					for j in 0 to 7 loop
						case door_st(j) is
							when ST_OPENING =>
								door_amt(j) <= door_amt(j) + DOOR_STEP;
								if (door_amt(j) + DOOR_STEP >= DOOR_OPEN) then
									door_amt(j) <= to_signed(DOOR_OPEN, 8);
									door_st(j) <= ST_OPEN;
									door_timer(j) <= to_unsigned(DOOR_STAY, 8);
								end if;
							when ST_OPEN =>
								-- The timer expires when it steps from 1 to 0
								door_timer(j) <= door_timer(j) - 1;
								if (door_timer(j) = 1) then
									if (door_in(j) = '1') then
										door_timer(j) <= to_unsigned(DOOR_RETRY, 8);
									else
										door_st(j) <= ST_CLOSING;
									end if;
								end if;
							when ST_CLOSING =>
								if (door_in(j) = '1') then
									door_st(j) <= ST_OPENING;
								else
									door_amt(j) <= door_amt(j) - DOOR_STEP;
									if (door_amt(j) - DOOR_STEP <= 0) then
										door_amt(j) <= (others => '0');
										door_st(j) <= ST_IDLE;
									end if;
								end if;
							when others =>
								null;
						end case;
					end loop;
					seq_state <= SEQ_OUT;

				when SEQ_OUT =>
					out_x <= std_logic_vector(px(POS_BITS - 1 downto 0));
					out_y <= std_logic_vector(py(POS_BITS - 1 downto 0));
					out_angle <= std_logic_vector(angle);
					for j in 0 to 7 loop
						if (door_st(j) = ST_IDLE) then
							out_doors(DOOR_BITS * j + DOOR_BITS - 1 downto DOOR_BITS * j) <= (others => '0');
						else
							out_doors(DOOR_BITS * j + DOOR_X_HI downto DOOR_BITS * j + DOOR_X_LO) <=
								std_logic_vector(door_x(j));
							out_doors(DOOR_BITS * j + DOOR_Y_HI downto DOOR_BITS * j + DOOR_Y_LO) <=
								std_logic_vector(door_y(j));
							out_doors(DOOR_BITS * j + DOOR_OPEN_HI downto DOOR_BITS * j + DOOR_OPEN_LO) <=
								std_logic_vector(door_amt(j)(6 downto 0)); -- 0..64 fits 7 bits
						end if;
						out_state(2 * j + 1 downto 2 * j) <= std_logic_vector(door_st(j));
						out_timer(8 * j + 7 downto 8 * j) <= std_logic_vector(door_timer(j));
					end loop;
					start <= '1';
					seq_state <= SEQ_IDLE;

				when others =>
					null;
			end case;

			-- A level (re)start overrides everything
			if (load_i = '1') then
				seq_state <= SEQ_IDLE;
				armed <= '0';
				px <= resize(signed('0' & start_x_i), 24); -- Unsigned Q6.16 in, signed inside
				py <= resize(signed('0' & start_y_i), 24);
				angle <= unsigned(start_angle_i);
				door_x <= (others => (others => '0'));
				door_y <= (others => (others => '0'));
				door_amt <= (others => (others => '0'));
				door_st <= (others => ST_IDLE);
				door_timer <= (others => (others => '0'));
			end if;
		end if;
	end process;

	map_addr_o <= std_logic_vector(map_addr);
	pos_x_o <= out_x;
	pos_y_o <= out_y;
	angle_o <= out_angle;
	eye_o <= std_logic_vector(to_unsigned(32, EYE_BITS));
	doors_o <= out_doors;
	render_start_o <= start;
	busy_o <= '0' when (seq_state = SEQ_IDLE) else '1';
	door_state_o <= out_state;
	door_timer_o <= out_timer;
end arch;
