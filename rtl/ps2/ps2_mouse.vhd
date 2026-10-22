--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    PS/2 Mouse
-- Module Name:    ps2_mouse
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    PS/2 mouse driver on top of ps2_host.
--                 Start-up: the mouse may finish its self-test before
--                 the FPGA is configured, so its AA is not awaited.
--                 STARTUP_CYCLES after en_i rises: send FF (reset),
--                 expect FA, AA, 00; send F4 (enable data reporting),
--                 expect FA. A wrong byte, no byte within
--                 RESP_TIMEOUT_CYCLES (the self-test after FF takes up
--                 to about 500 ms) or a send error counts a retry and
--                 starts over after the start-up delay.
--                 Streaming (default 100 reports/s): 3-byte packets
--                   byte 1: bit 0 left, 1 right, 2 middle button,
--                           bit 3 always '1', bit 4 X sign, 5 Y sign,
--                           bit 6 X overflow, 7 Y overflow
--                   byte 2: dx low 8 bits, byte 3: dy low 8 bits
--                 dx and dy are 9-bit two's complement (Y up is
--                 positive). A first byte without bit 3 means framing
--                 slipped: it is dropped until a byte with bit 3 comes.
--                 A byte arriving more than PACKET_GAP_CYCLES after the
--                 previous one also starts a new packet (bytes of one
--                 packet are about 1 ms apart, packets about 10 ms).
--                 Packets with an overflow bit are dropped. AA then 00
--                 as the first two bytes of a packet means the mouse was
--                 plugged in again (an AA first byte always has the Y
--                 overflow bit, so it is never a real packet): start
--                 over from FF.
--                 Motion: dx_o / dy_o show the motion summed since the
--                 last take_i, including a packet completing this cycle;
--                 take_i clears the sums at the same edge, so no packet
--                 is lost or counted twice. Sums saturate at 16 bits.
--                 x_total_o / y_total_o wrap (bring-up page).
--                 state_o codes: 0 off (en_i low), 1 start-up delay,
--                 2 send FF, 3 FF on the wire, 4 wait FA, 5 wait AA,
--                 6 wait 00, 7 send F4, 8 F4 on the wire, 9 wait FA,
--                 10 streaming.
--                 Clock domain: clk_i (system).
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std
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

entity ps2_mouse is
	generic(
		STARTUP_CYCLES: positive := 50_000_000; -- 500 ms before the first FF
		RESP_TIMEOUT_CYCLES: positive := 100_000_000; -- 1 s for each expected byte
		PACKET_GAP_CYCLES: positive := 300_000 -- 3 ms: a new packet starts
	);
	port(
		clk_i: in std_logic; -- System clock
		rst_i: in std_logic; -- Asynchronous reset, active high
		en_i: in std_logic; -- '0' = mouse off (PWR_SENSE gate)
		rx_data_i: in std_logic_vector(7 downto 0); -- Byte from the host
		rx_valid_i: in std_logic; -- Byte present (one cycle)
		tx_data_o: out std_logic_vector(7 downto 0); -- Command byte
		tx_valid_o: out std_logic; -- Command present
		tx_ready_i: in std_logic; -- Host takes the command
		tx_done_i: in std_logic; -- Pulse: mouse acknowledged on the wire
		tx_err_i: in std_logic; -- Pulse: send timed out
		take_i: in std_logic; -- Pulse: read dx_o / dy_o and clear the sums
		dx_o: out std_logic_vector(15 downto 0); -- Signed motion since last take
		dy_o: out std_logic_vector(15 downto 0); -- Signed motion since last take
		buttons_o: out std_logic_vector(2 downto 0); -- game_pkg BTN_* positions
		x_total_o: out std_logic_vector(15 downto 0); -- Running total, wraps
		y_total_o: out std_logic_vector(15 downto 0); -- Running total, wraps
		state_o: out std_logic_vector(3 downto 0); -- See the header
		retries_o: out std_logic_vector(7 downto 0) -- Failed start-ups, saturating
	);
end ps2_mouse;

architecture arch of ps2_mouse is
	type state_t is (S_OFF, S_DELAY, S_SEND_RESET, S_TX_RESET, S_ACK_RESET, S_BAT, S_ID,
		S_SEND_ENABLE, S_TX_ENABLE, S_ACK_ENABLE, S_STREAM);
	-- Larger of two naturals (maximum() is VHDL-2008)
	function max_nat(a, b: natural) return natural is
	begin
		if (a > b) then
			return a;
		end if;
		return b;
	end function;
	constant TIMER_MAX: positive := max_nat(STARTUP_CYCLES, RESP_TIMEOUT_CYCLES);

	signal state: state_t := S_OFF;
	signal state_next: state_t;
	signal timer: natural range 0 to TIMER_MAX := 0;
	signal timer_next: natural range 0 to TIMER_MAX;
	signal gap: natural range 0 to PACKET_GAP_CYCLES := 0; -- Clocks since the last byte
	signal gap_next: natural range 0 to PACKET_GAP_CYCLES;
	signal idx: natural range 0 to 2 := 0; -- Next byte's position in a packet
	signal idx_next: natural range 0 to 2;
	signal b0, b1: std_logic_vector(7 downto 0) := (others => '0');
	signal b0_next, b1_next: std_logic_vector(7 downto 0);
	signal buttons: std_logic_vector(2 downto 0) := (others => '0');
	signal buttons_next: std_logic_vector(2 downto 0);
	signal retries: unsigned(7 downto 0) := (others => '0');
	signal retries_next: unsigned(7 downto 0);

	-- Packet completing this cycle
	signal pkt_valid: std_logic;
	signal pkt_dx, pkt_dy: signed(8 downto 0);

	signal acc_x, acc_y: signed(15 downto 0) := (others => '0');
	signal sum_x, sum_y: signed(15 downto 0);
	signal total_x, total_y: signed(15 downto 0) := (others => '0');

	function state_code(s: state_t) return std_logic_vector is
	begin
		return std_logic_vector(to_unsigned(state_t'pos(s), 4));
	end function;

	-- a + b clamped to the 16-bit signed range
	function sat_add(a: signed(15 downto 0); b: signed(8 downto 0)) return signed is
		variable s: signed(16 downto 0);
	begin
		s := resize(a, 17) + resize(b, 17);
		if (s > 32767) then
			return to_signed(32767, 16);
		elsif (s < -32768) then
			return to_signed(-32768, 16);
		end if;
		return s(15 downto 0);
	end function;
begin
	process(state, timer, gap, idx, b0, b1, buttons, retries, en_i, rx_valid_i, rx_data_i,
		tx_ready_i, tx_done_i, tx_err_i)
		variable fail: boolean;
		variable pos: natural range 0 to 2;
	begin
		state_next <= state;
		timer_next <= timer;
		gap_next <= gap;
		idx_next <= idx;
		b0_next <= b0;
		b1_next <= b1;
		buttons_next <= buttons;
		retries_next <= retries;
		pkt_valid <= '0';
		-- 9-bit deltas: sign from byte 1, low bits from byte 2 / byte 3 (arriving now)
		pkt_dx <= signed(b0(4) & b1);
		pkt_dy <= signed(b0(5) & rx_data_i);
		fail := false;

		if (en_i = '0') then
			state_next <= S_OFF;
			timer_next <= 0;
			idx_next <= 0;
			buttons_next <= (others => '0');
		else
			-- Response timer for every start-up state
			if ((state = S_OFF) or (state = S_STREAM)) then
				timer_next <= 0;
			elsif (timer /= TIMER_MAX) then
				timer_next <= timer + 1;
			end if;

			case state is
				when S_OFF =>
					state_next <= S_DELAY;
				when S_DELAY =>
					if (timer = STARTUP_CYCLES - 1) then
						state_next <= S_SEND_RESET;
						timer_next <= 0;
					end if;
				when S_SEND_RESET =>
					if (tx_ready_i = '1') then
						state_next <= S_TX_RESET;
					end if;
				when S_TX_RESET =>
					if (tx_done_i = '1') then
						state_next <= S_ACK_RESET;
						timer_next <= 0;
					elsif (tx_err_i = '1') then
						fail := true;
					end if;
				when S_ACK_RESET | S_BAT | S_ID | S_ACK_ENABLE =>
					if (rx_valid_i = '1') then
						timer_next <= 0;
						if ((state = S_ACK_RESET) and (rx_data_i = x"FA")) then
							state_next <= S_BAT;
						elsif ((state = S_BAT) and (rx_data_i = x"AA")) then
							state_next <= S_ID;
						elsif ((state = S_ID) and (rx_data_i = x"00")) then
							state_next <= S_SEND_ENABLE;
						elsif ((state = S_ACK_ENABLE) and (rx_data_i = x"FA")) then
							state_next <= S_STREAM;
							idx_next <= 0;
						else
							fail := true;
						end if;
					end if;
				when S_SEND_ENABLE =>
					if (tx_ready_i = '1') then
						state_next <= S_TX_ENABLE;
					end if;
				when S_TX_ENABLE =>
					if (tx_done_i = '1') then
						state_next <= S_ACK_ENABLE;
						timer_next <= 0;
					elsif (tx_err_i = '1') then
						fail := true;
					end if;
				when S_STREAM =>
					if (rx_valid_i = '1') then
						gap_next <= 0;
						-- A long silence ends any partial packet
						if (gap = PACKET_GAP_CYCLES) then
							pos := 0;
						else
							pos := idx;
						end if;
						case pos is
							when 0 =>
								if (rx_data_i(3) = '1') then
									b0_next <= rx_data_i;
									idx_next <= 1;
								else
									idx_next <= 0; -- Slipped framing: drop it
								end if;
							when 1 =>
								if ((b0 = x"AA") and (rx_data_i = x"00")) then
									state_next <= S_SEND_RESET; -- Mouse replugged
									idx_next <= 0;
								else
									b1_next <= rx_data_i;
									idx_next <= 2;
								end if;
							when others =>
								idx_next <= 0;
								if (b0(7 downto 6) = "00") then -- No X or Y overflow
									pkt_valid <= '1';
									buttons_next <= b0(2 downto 0);
								end if;
						end case;
					elsif (gap /= PACKET_GAP_CYCLES) then
						gap_next <= gap + 1;
					end if;
				when others =>
					state_next <= S_OFF;
			end case;

			if ((state /= S_OFF) and (state /= S_DELAY) and (state /= S_STREAM) and
				(timer = RESP_TIMEOUT_CYCLES)) then
				fail := true;
			end if;
			if (fail) then
				state_next <= S_DELAY;
				timer_next <= 0;
				if (retries /= x"FF") then
					retries_next <= retries + 1;
				end if;
			end if;
		end if;
	end process;

	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			state <= S_OFF;
			timer <= 0;
			gap <= 0;
			idx <= 0;
			b0 <= (others => '0');
			b1 <= (others => '0');
			buttons <= (others => '0');
			retries <= (others => '0');
		elsif rising_edge(clk_i) then
			state <= state_next;
			timer <= timer_next;
			gap <= gap_next;
			idx <= idx_next;
			b0 <= b0_next;
			b1 <= b1_next;
			buttons <= buttons_next;
			retries <= retries_next;
		end if;
	end process;

	-- Motion sums: what take_i reads includes a packet landing this cycle
	sum_x <= sat_add(acc_x, pkt_dx) when (pkt_valid = '1') else acc_x;
	sum_y <= sat_add(acc_y, pkt_dy) when (pkt_valid = '1') else acc_y;

	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			acc_x <= (others => '0');
			acc_y <= (others => '0');
			total_x <= (others => '0');
			total_y <= (others => '0');
		elsif rising_edge(clk_i) then
			if ((take_i = '1') or (en_i = '0')) then
				acc_x <= (others => '0');
				acc_y <= (others => '0');
			else
				acc_x <= sum_x;
				acc_y <= sum_y;
			end if;
			if (pkt_valid = '1') then
				total_x <= total_x + resize(pkt_dx, 16);
				total_y <= total_y + resize(pkt_dy, 16);
			end if;
		end if;
	end process;

	tx_data_o <= x"F4" when ((state = S_SEND_ENABLE) or (state = S_TX_ENABLE)) else x"FF";
	tx_valid_o <= '1' when ((state = S_SEND_RESET) or (state = S_SEND_ENABLE)) else '0';
	dx_o <= std_logic_vector(sum_x);
	dy_o <= std_logic_vector(sum_y);
	buttons_o <= buttons;
	x_total_o <= std_logic_vector(total_x);
	y_total_o <= std_logic_vector(total_y);
	state_o <= state_code(state);
	retries_o <= std_logic_vector(retries);
end arch;
