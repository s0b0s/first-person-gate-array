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
--                 Start-up (the power-on AA may come before configuration,
--                 so it is not awaited): STARTUP_CYCLES after en_i rises,
--                 send FF (reset), expect FA, AA, 00; send F4 (enable
--                 reporting), expect FA. A wrong byte, a send error or no
--                 byte within RESP_TIMEOUT_CYCLES (the self-test after FF
--                 takes up to about 500 ms) counts a retry and starts over
--                 after the start-up delay.
--                 Streaming, 100 packets/s of 3 bytes. Byte 1: bit 0 left,
--                 1 right, 2 middle, 3 always '1', 4 X sign, 5 Y sign,
--                 6 X overflow, 7 Y overflow; byte 2: dx 7:0; byte 3:
--                 dy 7:0. dx, dy are 9-bit two's complement, Y up
--                 positive.
--                 A first byte without bit 3 is dropped (slipped
--                 framing); a gap over PACKET_GAP_CYCLES also starts a new
--                 packet (bytes about 1 ms apart, packets 10 ms). Overflow
--                 packets are dropped. AA 00 as the first two bytes means
--                 a replug (an AA first byte has Y overflow set, so it is
--                 never a real packet): start over from FF.
--                 dx_o / dy_o: motion summed since the last take_i,
--                 including a packet completing this cycle; take_i clears
--                 the sums at the same edge, so nothing is lost or counted
--                 twice. Sums saturate at 16 bits; x/y_total_o wrap.
--                 state_o: 0 off, 1 start-up delay, 2 send FF, 3 FF on the
--                 wire, 4 wait FA, 5 wait AA, 6 wait 00, 7 send F4, 8 F4
--                 on the wire, 9 wait FA, 10 streaming.
--                 Clock domain: clk_i (system).
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First working version
-- Revision 1.01 - One-process state machine
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
	type mouse_state_type is (MOUSE_OFF, MOUSE_DELAY, MOUSE_SEND_RESET, MOUSE_TX_RESET,
		MOUSE_ACK_RESET, MOUSE_BAT, MOUSE_ID, MOUSE_SEND_ENABLE, MOUSE_TX_ENABLE,
		MOUSE_ACK_ENABLE, MOUSE_STREAM);
	-- Larger of two naturals (maximum() is VHDL-2008)
	function max_nat(a, b: natural) return natural is
	begin
		if (a > b) then
			return a;
		end if;
		return b;
	end function;
	constant TIMER_MAX: positive := max_nat(STARTUP_CYCLES, RESP_TIMEOUT_CYCLES);

	signal mouse_state: mouse_state_type := MOUSE_OFF;
	signal timer: natural range 0 to TIMER_MAX := 0;
	signal gap: natural range 0 to PACKET_GAP_CYCLES := 0; -- Clocks since the last byte
	signal idx: natural range 0 to 2 := 0; -- Next byte's position in a packet
	signal b0, b1: std_logic_vector(7 downto 0) := (others => '0');
	signal buttons: std_logic_vector(2 downto 0) := (others => '0');
	signal retries: unsigned(7 downto 0) := (others => '0');

	-- Packet completing this cycle
	signal pkt_valid: std_logic;
	signal pkt_dx, pkt_dy: signed(8 downto 0);

	signal acc_x, acc_y: signed(15 downto 0) := (others => '0');
	signal sum_x, sum_y: signed(15 downto 0);
	signal total_x, total_y: signed(15 downto 0) := (others => '0');

	function state_code(s: mouse_state_type) return std_logic_vector is
	begin
		return std_logic_vector(to_unsigned(mouse_state_type'pos(s), 4));
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
	process(clk_i, rst_i)
		variable fail: boolean;
		variable pos: natural range 0 to 2;
	begin
		if (rst_i = '1') then
			mouse_state <= MOUSE_OFF;
			timer <= 0;
			gap <= 0;
			idx <= 0;
			b0 <= (others => '0');
			b1 <= (others => '0');
			buttons <= (others => '0');
			retries <= (others => '0');
		elsif rising_edge(clk_i) then
			fail := false;
			if (en_i = '0') then
				mouse_state <= MOUSE_OFF;
				timer <= 0;
				idx <= 0;
				buttons <= (others => '0');
			else
				-- Response timer for every start-up state (an assignment
				-- further down this branch overrides it)
				if ((mouse_state = MOUSE_OFF) or (mouse_state = MOUSE_STREAM)) then
					timer <= 0;
				elsif (timer /= TIMER_MAX) then
					timer <= timer + 1;
				end if;

				case mouse_state is
					when MOUSE_OFF =>
						mouse_state <= MOUSE_DELAY;
					when MOUSE_DELAY =>
						if (timer = STARTUP_CYCLES - 1) then
							mouse_state <= MOUSE_SEND_RESET;
							timer <= 0;
						end if;
					when MOUSE_SEND_RESET =>
						if (tx_ready_i = '1') then
							mouse_state <= MOUSE_TX_RESET;
						end if;
					when MOUSE_TX_RESET =>
						if (tx_done_i = '1') then
							mouse_state <= MOUSE_ACK_RESET;
							timer <= 0;
						elsif (tx_err_i = '1') then
							fail := true;
						end if;
					when MOUSE_ACK_RESET | MOUSE_BAT | MOUSE_ID | MOUSE_ACK_ENABLE =>
						if (rx_valid_i = '1') then
							timer <= 0;
							if ((mouse_state = MOUSE_ACK_RESET) and (rx_data_i = x"FA")) then
								mouse_state <= MOUSE_BAT;
							elsif ((mouse_state = MOUSE_BAT) and (rx_data_i = x"AA")) then
								mouse_state <= MOUSE_ID;
							elsif ((mouse_state = MOUSE_ID) and (rx_data_i = x"00")) then
								mouse_state <= MOUSE_SEND_ENABLE;
							elsif ((mouse_state = MOUSE_ACK_ENABLE) and (rx_data_i = x"FA")) then
								mouse_state <= MOUSE_STREAM;
								idx <= 0;
							else
								fail := true;
							end if;
						end if;
					when MOUSE_SEND_ENABLE =>
						if (tx_ready_i = '1') then
							mouse_state <= MOUSE_TX_ENABLE;
						end if;
					when MOUSE_TX_ENABLE =>
						if (tx_done_i = '1') then
							mouse_state <= MOUSE_ACK_ENABLE;
							timer <= 0;
						elsif (tx_err_i = '1') then
							fail := true;
						end if;
					when MOUSE_STREAM =>
						if (rx_valid_i = '1') then
							gap <= 0;
							-- A long silence ends any partial packet
							if (gap = PACKET_GAP_CYCLES) then
								pos := 0;
							else
								pos := idx;
							end if;
							case pos is
								when 0 =>
									if (rx_data_i(3) = '1') then
										b0 <= rx_data_i;
										idx <= 1;
									else
										idx <= 0; -- Slipped framing: drop it
									end if;
								when 1 =>
									if ((b0 = x"AA") and (rx_data_i = x"00")) then
										mouse_state <= MOUSE_SEND_RESET; -- Mouse replugged
										idx <= 0;
									else
										b1 <= rx_data_i;
										idx <= 2;
									end if;
								when others =>
									-- Third byte: pkt_valid (below) is '1' in this
									-- cycle unless an overflow bit is set
									idx <= 0;
									if (b0(7 downto 6) = "00") then -- No X or Y overflow
										buttons <= b0(2 downto 0);
									end if;
							end case;
						elsif (gap /= PACKET_GAP_CYCLES) then
							gap <= gap + 1;
						end if;
					when others =>
						mouse_state <= MOUSE_OFF;
				end case;

				if ((mouse_state /= MOUSE_OFF) and (mouse_state /= MOUSE_DELAY) and
					(mouse_state /= MOUSE_STREAM) and (timer = RESP_TIMEOUT_CYCLES)) then
					fail := true;
				end if;
				-- A failure overrides whatever the case chose
				if (fail) then
					mouse_state <= MOUSE_DELAY;
					timer <= 0;
					if (retries /= x"FF") then
						retries <= retries + 1;
					end if;
				end if;
			end if;
		end if;
	end process;

	-- Packet completing this cycle, combinational so that the motion sums
	-- see it in the same cycle: the third byte of a packet in MOUSE_STREAM
	-- (no long gap before it) without an overflow bit
	pkt_valid <= '1' when ((en_i = '1') and (mouse_state = MOUSE_STREAM) and
		(rx_valid_i = '1') and (gap /= PACKET_GAP_CYCLES) and (idx = 2) and
		(b0(7 downto 6) = "00")) else '0';
	-- 9-bit deltas: sign from byte 1, low bits from byte 2 / byte 3 (arriving now)
	pkt_dx <= signed(b0(4) & b1);
	pkt_dy <= signed(b0(5) & rx_data_i);

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

	-- Command byte and request follow the state directly
	tx_data_o <= x"F4" when ((mouse_state = MOUSE_SEND_ENABLE) or
		(mouse_state = MOUSE_TX_ENABLE)) else x"FF";
	tx_valid_o <= '1' when ((mouse_state = MOUSE_SEND_RESET) or
		(mouse_state = MOUSE_SEND_ENABLE)) else '0';
	dx_o <= std_logic_vector(sum_x);
	dy_o <= std_logic_vector(sum_y);
	buttons_o <= buttons;
	x_total_o <= std_logic_vector(total_x);
	y_total_o <= std_logic_vector(total_y);
	state_o <= state_code(mouse_state);
	retries_o <= std_logic_vector(retries);
end arch;
