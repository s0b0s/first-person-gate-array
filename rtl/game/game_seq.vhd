--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Stage-1 Game Sequencer
-- Module Name:    game_seq
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    Stage-1 game sequencer: once per frame it runs the player
--                 and door update of tools/model/game.py (Game.step), bit
--                 for bit, then hands the result to the renderer.
--                 Order of one step (all integer, ">>" = arithmetic shift):
--                   1 angle = (angle + turn) mod 1024
--                   2 cs = cos(angle), sn = sin(angle) (Q2.16, SIN_TABLE)
--                     vx = move*cs - strafe*sn, vy = move*sn + strafe*cs
--                     dx = vx >> 4, dy = vy >> 4 (>> 3 when running)
--                   3 move x, then y: the player box (half size R = 0.25
--                     tile = 16384) at the new position is tested against
--                     the 2 x 2 map cells it overlaps (4 reads of map port
--                     B). Solid = wall texture /= 0 unless it is a door
--                     whose table entry is fully open (64). If blocked,
--                     the box is put flush against the cell it ran into:
--                       dx > 0: max(px, ((nx + HALF) with bits 15:0 cleared)
--                               - HALF - 1)
--                       dx < 0: min(px, ((nx - HALF) with bits 15:0 cleared)
--                               + 65536 + HALF)
--                   4 use: the cell at (px + (3 cs >> 2), py + (3 sn >> 2));
--                     a door there starts opening (new table entry in the
--                     first idle slot), or closes when open and the player
--                     is not in it, or reopens when closing
--                   5 doors, all 8 entries in parallel (they do not depend
--                     on each other): OPENING +2 per frame up to 64, then
--                     OPEN for 180 frames, then CLOSING -2 per frame to 0
--                     (IDLE); a closing door with the player inside
--                     reopens; an expiring open door with the player
--                     inside waits 30 more frames
--                 Then the state is copied to the outputs and
--                 render_start_o pulses; the outputs change only then, so
--                 the renderer sees one consistent frame.
--                 States: S_IDLE, S_TURN, S_SIN, S_COS, S_VEL, S_MX, S_MY,
--                 S_BOX_A (cell address out), S_BOX_D (cell data in),
--                 S_MX_END, S_MY_END, S_USE, S_USE_D, S_DOORS, S_OUT.
--                 Coding: two-segment style with all registers in one
--                 record r (as rtl/debug/debug_port.vhd).
--                 Clock domain: clk_i (system). About 25 clocks per frame.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std, game_pkg,
--                 render_pkg (SIN_TABLE), render_types_pkg
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - Stage 1 (player, collision, doors)
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
		eye_o: out std_logic_vector(EYE_BITS - 1 downto 0); -- 32 in stage 1
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

	type door_t is record
		x: unsigned(5 downto 0);
		y: unsigned(5 downto 0);
		open_amt: signed(7 downto 0); -- 0..64
		state: unsigned(1 downto 0);
		timer: unsigned(7 downto 0);
	end record;
	type doors_t is array (0 to 7) of door_t;
	constant DOOR_CLEAR: door_t := ((others => '0'), (others => '0'), (others => '0'),
		ST_IDLE, (others => '0'));

	type state_t is (S_IDLE, S_TURN, S_SIN, S_COS, S_VEL, S_MX, S_MY, S_BOX_A, S_BOX_D,
		S_MX_END, S_MY_END, S_USE, S_USE_D, S_DOORS, S_OUT);

	type regs_t is record
		state: state_t;
		armed: std_logic; -- frame_start seen, waiting for the snapshot
		snap: std_logic_vector(SNAP_BITS - 1 downto 0);
		px: pos_t;
		py: pos_t;
		angle: unsigned(9 downto 0);
		cs: trig_t;
		sn: trig_t;
		dx: pos_t;
		dy: pos_t;
		bx: pos_t; -- Box center under test
		by: pos_t;
		k: unsigned(1 downto 0); -- Box cell 0..3: bit 0 picks x, bit 1 picks y
		hit: std_logic; -- A tested cell was solid
		ctx_y: std_logic; -- Box test is for the y move
		doors: doors_t;
		ucell: unsigned(11 downto 0); -- Use target cell, y & x
		start: std_logic;
		pos_x_o: std_logic_vector(POS_BITS - 1 downto 0);
		pos_y_o: std_logic_vector(POS_BITS - 1 downto 0);
		angle_o: std_logic_vector(ANGLE_BITS - 1 downto 0);
		doors_o: std_logic_vector(DOORS_BITS - 1 downto 0);
		state_o: std_logic_vector(15 downto 0);
		timer_o: std_logic_vector(63 downto 0);
	end record;

	constant REGS_INIT: regs_t := (
		state => S_IDLE,
		armed => '0',
		snap => (others => '0'),
		px => (others => '0'),
		py => (others => '0'),
		angle => (others => '0'),
		cs => (others => '0'),
		sn => (others => '0'),
		dx => (others => '0'),
		dy => (others => '0'),
		bx => (others => '0'),
		by => (others => '0'),
		k => (others => '0'),
		hit => '0',
		ctx_y => '0',
		doors => (others => DOOR_CLEAR),
		ucell => (others => '0'),
		start => '0',
		pos_x_o => (others => '0'),
		pos_y_o => (others => '0'),
		angle_o => (others => '0'),
		doors_o => (others => '0'),
		state_o => (others => '0'),
		timer_o => (others => '0')
	);

	signal r: regs_t := REGS_INIT;
	signal r_next: regs_t;
	signal rom_addr: unsigned(9 downto 0);
	signal rom_data: trig_t := (others => '0');
	signal map_addr: unsigned(11 downto 0);

	-- Map cell (y & x) of the box corner k around (bx, by): bits 21:16 of
	-- (b -/+ HALF) are the cell index, which is (b +/- HALF) >> 16 masked to 0..63
	function box_cell(bx: pos_t; by: pos_t; k: unsigned(1 downto 0)) return unsigned is
		variable cx, cy: pos_t;
	begin
		if (k(0) = '0') then
			cx := bx - HALF;
		else
			cx := bx + HALF;
		end if;
		if (k(1) = '0') then
			cy := by - HALF;
		else
			cy := by + HALF;
		end if;
		return unsigned(std_logic_vector(cy(21 downto 16))) & unsigned(std_logic_vector(cx(21 downto 16)));
	end function;

	-- Is cell (y & x) one of the 2 x 2 cells the player box overlaps?
	function player_in(px: pos_t; py: pos_t; cell: unsigned(11 downto 0)) return boolean is
		variable hit: boolean := false;
	begin
		for k in 0 to 3 loop
			if (box_cell(px, py, to_unsigned(k, 2)) = cell) then
				hit := true;
			end if;
		end loop;
		return hit;
	end function;

	-- Door table entry for cell (y & x): index 0..7, or 8 when none is active
	function door_index(doors: doors_t; cell: unsigned(11 downto 0)) return natural is
	begin
		for i in 0 to 7 loop
			if ((doors(i).state /= ST_IDLE) and (doors(i).y & doors(i).x = cell)) then
				return i;
			end if;
		end loop;
		return 8;
	end function;

	-- Solid test of a tile word read from map cell (y & x)
	function solid(t: std_logic_vector(23 downto 0); doors: doors_t; cell: unsigned(11 downto 0))
		return boolean is
		variable i: natural range 0 to 8;
	begin
		if (unsigned(t(TILE_WALL_HI downto TILE_WALL_LO)) = 0) then
			return false;
		end if;
		if (unsigned(t(TILE_SPECIAL_HI downto TILE_SPECIAL_LO)) = SPECIAL_DOOR) then
			i := door_index(doors, cell);
			if ((i < 8) and (doors(i mod 8).open_amt = DOOR_OPEN)) then
				return false;
			end if;
		end if;
		return true;
	end function;

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

	------------------------------------------------------------------
	-- Next state
	------------------------------------------------------------------
	process(r, load_i, start_x_i, start_y_i, start_angle_i, frame_start_i, snapshot_i,
		snapshot_valid_i, map_data_i, rom_data)
		variable v: regs_t;
		variable turn: signed(11 downto 0);
		variable vx, vy: signed(19 downto 0);
		variable nx: pos_t;
		variable edge: pos_t;
		variable ux, uy: pos_t;
		variable t3: signed(19 downto 0);
		variable i: natural range 0 to 8;
		variable d: door_t;
		variable inside: boolean;
	begin
		v := r;
		v.start := '0';
		rom_addr <= r.angle;
		map_addr <= box_cell(r.bx, r.by, r.k);

		if (frame_start_i = '1') then
			v.armed := '1';
		end if;

		case r.state is
			when S_IDLE =>
				-- (frame_start and the snapshot may come in the same clock)
				if ((snapshot_valid_i = '1') and ((r.armed = '1') or (frame_start_i = '1'))) then
					v.snap := snapshot_i;
					v.armed := '0';
					v.state := S_TURN;
				end if;

			when S_TURN =>
				-- Adding the low 10 bits of the signed turn is mod 1024
				turn := signed(r.snap(SNAP_TURN_HI downto SNAP_TURN_LO));
				v.angle := r.angle + unsigned(std_logic_vector(turn(9 downto 0)));
				v.state := S_SIN;

			when S_SIN =>
				rom_addr <= r.angle; -- sin(angle) arrives in S_COS
				v.state := S_COS;

			when S_COS =>
				rom_addr <= r.angle + 256; -- cos(angle) arrives in S_VEL
				v.sn := rom_data;
				v.state := S_VEL;

			when S_VEL =>
				v.cs := rom_data;
				-- v = move * (cos, sin) + strafe * (-sin, cos), Q2.16
				vx := times(r.snap(SNAP_MOVE_HI downto SNAP_MOVE_LO), rom_data) -
					times(r.snap(SNAP_STRAFE_HI downto SNAP_STRAFE_LO), r.sn);
				vy := times(r.snap(SNAP_MOVE_HI downto SNAP_MOVE_LO), r.sn) +
					times(r.snap(SNAP_STRAFE_HI downto SNAP_STRAFE_LO), rom_data);
				-- Full input moves 1/8 tile per frame running, 1/16 walking
				if (r.snap(SNAP_RUN) = '1') then
					v.dx := resize(shift_right(vx, 3), 24);
					v.dy := resize(shift_right(vy, 3), 24);
				else
					v.dx := resize(shift_right(vx, 4), 24);
					v.dy := resize(shift_right(vy, 4), 24);
				end if;
				v.state := S_MX;

			when S_MX =>
				-- Test the box at the new x, current y
				v.bx := r.px + r.dx;
				v.by := r.py;
				v.k := "00";
				v.hit := '0';
				v.ctx_y := '0';
				if (r.dx = 0) then
					v.state := S_MY;
				else
					v.state := S_BOX_A;
				end if;

			when S_MY =>
				-- Test the box at the final x, new y
				v.bx := r.px;
				v.by := r.py + r.dy;
				v.k := "00";
				v.hit := '0';
				v.ctx_y := '1';
				if (r.dy = 0) then
					v.state := S_USE;
				else
					v.state := S_BOX_A;
				end if;

			when S_BOX_A =>
				-- map_addr is the cell of corner k (default assignment above)
				v.state := S_BOX_D;

			when S_BOX_D =>
				if (solid(map_data_i, r.doors, box_cell(r.bx, r.by, r.k))) then
					v.hit := '1';
				end if;
				v.k := r.k + 1;
				if (r.k = 3) then
					if (r.ctx_y = '0') then
						v.state := S_MX_END;
					else
						v.state := S_MY_END;
					end if;
				else
					v.state := S_BOX_A;
				end if;

			when S_MX_END =>
				nx := r.bx;
				if (r.hit = '0') then
					v.px := nx;
				elsif (r.dx > 0) then
					-- Blocked: slide the box flush against the solid cell
					-- (right side 1 unit short of its left edge)
					edge := ((nx + HALF) and x"FF0000") - HALF - 1;
					if (edge > r.px) then
						v.px := edge;
					end if;
				else
					edge := ((nx - HALF) and x"FF0000") + 65536 + HALF; -- Left side on its right edge
					if (edge < r.px) then
						v.px := edge;
					end if;
				end if;
				v.state := S_MY;

			when S_MY_END =>
				-- Same clamp as S_MX_END, for y
				nx := r.by;
				if (r.hit = '0') then
					v.py := nx;
				elsif (r.dy > 0) then
					edge := ((nx + HALF) and x"FF0000") - HALF - 1;
					if (edge > r.py) then
						v.py := edge;
					end if;
				else
					edge := ((nx - HALF) and x"FF0000") + 65536 + HALF;
					if (edge < r.py) then
						v.py := edge;
					end if;
				end if;
				v.state := S_USE;

			when S_USE =>
				-- Cell 0.75 tile ahead: c * 3 >> 2
				t3 := resize(r.cs, 20) + shift_left(resize(r.cs, 20), 1);
				ux := r.px + resize(shift_right(t3, 2), 24);
				t3 := resize(r.sn, 20) + shift_left(resize(r.sn, 20), 1);
				uy := r.py + resize(shift_right(t3, 2), 24);
				v.ucell := unsigned(std_logic_vector(uy(21 downto 16))) &
					unsigned(std_logic_vector(ux(21 downto 16)));
				if (r.snap(SNAP_USE) = '1') then
					v.state := S_USE_D;
				else
					v.state := S_DOORS;
				end if;

			when S_USE_D =>
				-- map_addr = ucell was presented last cycle (see below)
				if ((unsigned(map_data_i(TILE_SPECIAL_HI downto TILE_SPECIAL_LO)) = SPECIAL_DOOR) and
					(unsigned(map_data_i(TILE_WALL_HI downto TILE_WALL_LO)) /= 0)) then
					i := door_index(r.doors, r.ucell);
					if (i = 8) then
						-- New entry in the first idle slot (none free: ignore)
						for j in 7 downto 0 loop
							if (r.doors(j).state = ST_IDLE) then
								i := j;
							end if;
						end loop;
						if (i < 8) then
							v.doors(i mod 8).x := r.ucell(5 downto 0);
							v.doors(i mod 8).y := r.ucell(11 downto 6);
							v.doors(i mod 8).open_amt := (others => '0');
							v.doors(i mod 8).timer := (others => '0');
							v.doors(i mod 8).state := ST_OPENING;
						end if;
					elsif (r.doors(i mod 8).state = ST_OPEN) then
						if (not player_in(r.px, r.py, r.ucell)) then
							v.doors(i mod 8).state := ST_CLOSING;
						end if;
					elsif (r.doors(i mod 8).state = ST_CLOSING) then
						v.doors(i mod 8).state := ST_OPENING;
					end if;
				end if;
				v.state := S_DOORS;

			when S_DOORS =>
				for j in 0 to 7 loop
					d := v.doors(j);
					inside := player_in(r.px, r.py, d.y & d.x);
					case d.state is
						when ST_OPENING =>
							d.open_amt := d.open_amt + DOOR_STEP;
							if (d.open_amt >= DOOR_OPEN) then
								d.open_amt := to_signed(DOOR_OPEN, 8);
								d.state := ST_OPEN;
								d.timer := to_unsigned(DOOR_STAY, 8);
							end if;
						when ST_OPEN =>
							d.timer := d.timer - 1;
							if (d.timer = 0) then
								if (inside) then
									d.timer := to_unsigned(DOOR_RETRY, 8);
								else
									d.state := ST_CLOSING;
								end if;
							end if;
						when ST_CLOSING =>
							if (inside) then
								d.state := ST_OPENING;
							else
								d.open_amt := d.open_amt - DOOR_STEP;
								if (d.open_amt <= 0) then
									d.open_amt := (others => '0');
									d.state := ST_IDLE;
								end if;
							end if;
						when others =>
							null;
					end case;
					v.doors(j) := d;
				end loop;
				v.state := S_OUT;

			when S_OUT =>
				v.pos_x_o := std_logic_vector(r.px(POS_BITS - 1 downto 0));
				v.pos_y_o := std_logic_vector(r.py(POS_BITS - 1 downto 0));
				v.angle_o := std_logic_vector(r.angle);
				for j in 0 to 7 loop
					if (r.doors(j).state = ST_IDLE) then
						v.doors_o(DOOR_BITS * j + DOOR_BITS - 1 downto DOOR_BITS * j) := (others => '0');
					else
						v.doors_o(DOOR_BITS * j + DOOR_X_HI downto DOOR_BITS * j + DOOR_X_LO) :=
							std_logic_vector(r.doors(j).x);
						v.doors_o(DOOR_BITS * j + DOOR_Y_HI downto DOOR_BITS * j + DOOR_Y_LO) :=
							std_logic_vector(r.doors(j).y);
						v.doors_o(DOOR_BITS * j + DOOR_OPEN_HI downto DOOR_BITS * j + DOOR_OPEN_LO) :=
							std_logic_vector(r.doors(j).open_amt(6 downto 0)); -- 0..64 fits 7 bits
					end if;
					v.state_o(2 * j + 1 downto 2 * j) := std_logic_vector(r.doors(j).state);
					v.timer_o(8 * j + 7 downto 8 * j) := std_logic_vector(r.doors(j).timer);
				end loop;
				v.start := '1';
				v.state := S_IDLE;
		end case;

		-- The use read: present the target cell while entering S_USE_D
		if (r.state = S_USE) then
			map_addr <= v.ucell;
		end if;

		-- A level (re)start overrides everything
		if (load_i = '1') then
			v.state := S_IDLE;
			v.armed := '0';
			v.px := resize(signed('0' & start_x_i), 24); -- Unsigned Q6.16 in, signed inside
			v.py := resize(signed('0' & start_y_i), 24);
			v.angle := unsigned(start_angle_i);
			v.doors := (others => DOOR_CLEAR);
		end if;
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

	map_addr_o <= std_logic_vector(map_addr);
	pos_x_o <= r.pos_x_o;
	pos_y_o <= r.pos_y_o;
	angle_o <= r.angle_o;
	eye_o <= std_logic_vector(to_unsigned(32, EYE_BITS));
	doors_o <= r.doors_o;
	render_start_o <= r.start;
	busy_o <= '0' when (r.state = S_IDLE) else '1';
	door_state_o <= r.state_o;
	door_timer_o <= r.timer_o;
end arch;
