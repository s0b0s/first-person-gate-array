--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    SPI Flash Reader
-- Module Name:    flash_reader
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    Single-bit SPI (mode 0) reader for the Cmod's 4 MB
--                 configuration flash, used after configuration when its
--                 pins are user I/O. SCK reaches the flash through user
--                 pin E19 (Cmod manual), so STARTUPE2 is not needed. The
--                 fitted part may be a Macronix MX25L3233F (current boards)
--                 or a Micron N25Q032A (Cmod manual); both answer READ ID
--                 (0x9F) and READ (0x03, 24-bit address, up to 50 MHz)
--                 the same way. Only these two read commands exist here:
--                 the design can never write or erase the flash.
--                 Request: req_id_i = '1' sends 0x9F, '0' sends 0x03 and
--                 req_addr_i; then req_len_i bytes are read and handed
--                 out on a valid/ready port (data_last_o marks the last).
--                 SCK timing, SCK_DIV = 4 (25 MHz): one SCK period is
--                 phases 0..3 of the system clock. SCK and MOSI change
--                 together at the start of phase 0 (SCK falls), SCK rises
--                 at the start of phase 2, and MISO is taken from the IOB
--                 input register that sampled the pin at the start of
--                 phase 3: 30 ns after the falling edge, leaving room for
--                 the flash's output delay (8 ns) plus pin and board
--                 delays, and 10 ns before the next falling edge.
--                 Back-pressure: the received byte waits in an output
--                 register. If the previous byte has still not been taken
--                 when the next one is complete, SCK stops (low, CS still
--                 low; the flash allows a stopped clock) until it is.
--                 CS_n is held high for 2 x SCK_DIV clocks between
--                 commands and goes low SCK_DIV clocks before the first
--                 SCK edge.
--                 Clock domain: clk_i (system). Throughput at 25 MHz SCK:
--                 3.1 MB/s while the consumer keeps up.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First working version
-- Additional Comments:
--                 SCK_DIV must be even and at least 4. req_len_i must be
--                 at least 1. DQ2 (WP_n) and DQ3 (HOLD_n) must be driven
--                 high by the top level.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity flash_reader is
	generic(
		SCK_DIV: positive := 4 -- System clocks per SCK period (even, >= 4)
	);
	port(
		clk_i: in std_logic; -- System clock
		rst_i: in std_logic; -- Asynchronous reset, active high
		-- Request
		req_valid_i: in std_logic; -- Request present
		req_ready_o: out std_logic; -- Request taken on a cycle with req_valid_i
		req_id_i: in std_logic; -- '1' READ ID (0x9F), '0' READ (0x03)
		req_addr_i: in std_logic_vector(23 downto 0); -- Byte address (READ only)
		req_len_i: in std_logic_vector(23 downto 0); -- Bytes to return, >= 1
		-- Data out
		data_valid_o: out std_logic; -- data_o holds a byte
		data_ready_i: in std_logic; -- Byte taken on a cycle with data_valid_o
		data_o: out std_logic_vector(7 downto 0); -- Byte read
		data_last_o: out std_logic; -- data_o is the last byte of the request
		busy_o: out std_logic; -- A command is in progress
		-- Flash pins
		cs_n_o: out std_logic; -- Chip select, active low
		sck_o: out std_logic; -- Serial clock, idle low
		mosi_o: out std_logic; -- DQ0, data to the flash
		miso_i: in std_logic -- DQ1, data from the flash
	);
end flash_reader;

architecture arch of flash_reader is
	constant HALF: natural := SCK_DIV / 2;
	constant SAMPLE_PH: natural := HALF + HALF / 2; -- Phase whose MISO sample is used
	constant GAP_CYCLES: natural := 2 * SCK_DIV;

	type state_t is (S_IDLE, S_START, S_XFER, S_HAND, S_FINISH);
	signal state: state_t := S_IDLE;
	signal state_next: state_t;
	signal ph: natural range 0 to SCK_DIV - 1 := 0;
	signal ph_next: natural range 0 to SCK_DIV - 1;
	signal bitn: natural range 0 to 7 := 0;
	signal bitn_next: natural range 0 to 7;
	signal gap: natural range 0 to GAP_CYCLES - 1 := 0;
	signal gap_next: natural range 0 to GAP_CYCLES - 1;
	signal is_id: std_logic := '0';
	signal is_id_next: std_logic;
	signal addr: std_logic_vector(23 downto 0) := (others => '0');
	signal addr_next: std_logic_vector(23 downto 0);
	signal cmd_left: natural range 0 to 4 := 0; -- Command bytes left, current included
	signal cmd_left_next: natural range 0 to 4;
	signal rx_left: unsigned(23 downto 0) := (others => '0'); -- Bytes still to return
	signal rx_left_next: unsigned(23 downto 0);
	signal txreg: std_logic_vector(7 downto 0) := (others => '0');
	signal txreg_next: std_logic_vector(7 downto 0);
	signal shreg: std_logic_vector(7 downto 0) := (others => '0');
	signal shreg_next: std_logic_vector(7 downto 0);
	signal out_data: std_logic_vector(7 downto 0) := (others => '0');
	signal out_data_next: std_logic_vector(7 downto 0);
	signal out_valid: std_logic := '0';
	signal out_valid_next: std_logic;
	signal out_last: std_logic := '0';
	signal out_last_next: std_logic;

	-- Pin registers (IOB)
	signal cs_n_r: std_logic := '1';
	signal cs_n_next: std_logic;
	signal sck_r: std_logic := '0';
	signal sck_next: std_logic;
	signal mosi_r: std_logic := '0';
	signal mosi_next: std_logic;
	signal miso_q: std_logic := '0';
	attribute IOB: string;
	attribute IOB of cs_n_r, sck_r, mosi_r, miso_q: signal is "TRUE";
begin
	process(state, ph, bitn, gap, is_id, addr, cmd_left, rx_left, txreg, shreg, out_data,
		out_valid, out_last, cs_n_r, mosi_r, miso_q, req_valid_i, req_id_i, req_addr_i,
		req_len_i, data_ready_i)
		variable out_free: boolean;
		variable rx_byte: std_logic_vector(7 downto 0);
		variable next_tx: std_logic_vector(7 downto 0);

		-- Hand a complete received byte to the output register and decide
		-- whether the command is finished
		procedure deliver(b: std_logic_vector(7 downto 0)) is
		begin
			out_data_next <= b;
			out_valid_next <= '1';
			if (rx_left = 1) then
				out_last_next <= '1';
				state_next <= S_FINISH;
				gap_next <= GAP_CYCLES - 1;
				cs_n_next <= '1';
			else
				out_last_next <= '0';
				state_next <= S_XFER;
				mosi_next <= '0';
				txreg_next <= (others => '0');
			end if;
			rx_left_next <= rx_left - 1;
			ph_next <= 0;
			bitn_next <= 0;
		end procedure;
	begin
		state_next <= state;
		ph_next <= ph;
		bitn_next <= bitn;
		gap_next <= gap;
		is_id_next <= is_id;
		addr_next <= addr;
		cmd_left_next <= cmd_left;
		rx_left_next <= rx_left;
		txreg_next <= txreg;
		shreg_next <= shreg;
		out_data_next <= out_data;
		out_last_next <= out_last;
		cs_n_next <= cs_n_r;
		sck_next <= '0';
		mosi_next <= mosi_r;
		-- The output byte empties when the consumer takes it
		out_valid_next <= out_valid and (not data_ready_i);
		out_free := (out_valid = '0') or (data_ready_i = '1');
		-- Received byte including this cycle's sample (SAMPLE_PH may be the
		-- last phase of the bit)
		if ((state = S_XFER) and (ph = SAMPLE_PH)) then
			rx_byte := shreg(6 downto 0) & miso_q; -- MSB first: new bit enters at the bottom
		else
			rx_byte := shreg;
		end if;

		case state is
			when S_IDLE =>
				cs_n_next <= '1';
				if (req_valid_i = '1') then
					is_id_next <= req_id_i;
					addr_next <= req_addr_i;
					rx_left_next <= unsigned(req_len_i);
					if (req_id_i = '1') then
						cmd_left_next <= 1; -- 0x9F alone
					else
						cmd_left_next <= 4; -- 0x03 plus three address bytes
					end if;
					state_next <= S_START;
					gap_next <= SCK_DIV - 1;
					cs_n_next <= '0';
				end if;

			when S_START =>
				-- CS_n setup time before the first rising SCK edge
				if (gap = 0) then
					state_next <= S_XFER;
					ph_next <= 0;
					bitn_next <= 0;
					if (is_id = '1') then
						next_tx := x"9F";
					else
						next_tx := x"03";
					end if;
					-- Bit 7 goes out now, the rest shifts out of txreg
					mosi_next <= next_tx(7);
					txreg_next <= next_tx(6 downto 0) & '0';
				else
					gap_next <= gap - 1;
				end if;

			when S_XFER =>
				shreg_next <= rx_byte;
				if (ph = SCK_DIV - 1) then
					if (bitn /= 7) then
						-- Next bit of this byte
						ph_next <= 0;
						bitn_next <= bitn + 1;
						mosi_next <= txreg(7);
						txreg_next <= txreg(6 downto 0) & '0';
					elsif (cmd_left /= 0) then
						-- A command or address byte is done; send the next one,
						-- or zeros while reading
						cmd_left_next <= cmd_left - 1;
						case cmd_left is
							when 4 =>
								next_tx := addr(23 downto 16);
							when 3 =>
								next_tx := addr(15 downto 8);
							when 2 =>
								next_tx := addr(7 downto 0);
							when others =>
								next_tx := x"00";
						end case;
						ph_next <= 0;
						bitn_next <= 0;
						mosi_next <= next_tx(7);
						txreg_next <= next_tx(6 downto 0) & '0';
					elsif (out_free) then
						deliver(rx_byte);
					else
						-- Output still full: stop SCK (low) and hold the byte
						state_next <= S_HAND;
					end if;
				else
					ph_next <= ph + 1;
					if (ph + 1 >= HALF) then -- SCK high for the second half of the bit
						sck_next <= '1';
					end if;
				end if;

			when S_HAND =>
				if (out_free) then
					deliver(shreg);
				end if;

			when S_FINISH =>
				cs_n_next <= '1';
				if (gap = 0) then
					state_next <= S_IDLE;
				else
					gap_next <= gap - 1;
				end if;

			when others =>
				state_next <= S_IDLE;
		end case;
	end process;

	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			state <= S_IDLE;
			ph <= 0;
			bitn <= 0;
			gap <= 0;
			is_id <= '0';
			addr <= (others => '0');
			cmd_left <= 0;
			rx_left <= (others => '0');
			txreg <= (others => '0');
			shreg <= (others => '0');
			out_data <= (others => '0');
			out_valid <= '0';
			out_last <= '0';
			cs_n_r <= '1';
			sck_r <= '0';
			mosi_r <= '0';
			miso_q <= '0';
		elsif rising_edge(clk_i) then
			state <= state_next;
			ph <= ph_next;
			bitn <= bitn_next;
			gap <= gap_next;
			is_id <= is_id_next;
			addr <= addr_next;
			cmd_left <= cmd_left_next;
			rx_left <= rx_left_next;
			txreg <= txreg_next;
			shreg <= shreg_next;
			out_data <= out_data_next;
			out_valid <= out_valid_next;
			out_last <= out_last_next;
			cs_n_r <= cs_n_next;
			sck_r <= sck_next;
			mosi_r <= mosi_next;
			miso_q <= miso_i;
		end if;
	end process;

	req_ready_o <= '1' when (state = S_IDLE) else '0';
	data_valid_o <= out_valid;
	data_o <= out_data;
	data_last_o <= out_last;
	busy_o <= '0' when (state = S_IDLE) else '1';
	cs_n_o <= cs_n_r;
	sck_o <= sck_r;
	mosi_o <= mosi_r;
end arch;
