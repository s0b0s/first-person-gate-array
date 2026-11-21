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
-- Description:    Single-bit SPI (mode 0) reader for the 4 MB
--                 configuration flash, used after configuration. SCK is on
--                 user pin E19, so no STARTUPE2. Only READ ID (0x9F) and
--                 READ (0x03, 24-bit address, up to 50 MHz), identical on
--                 the Macronix MX25L3233F and Micron N25Q032A; it can
--                 never write or erase.
--                 Request: req_id_i = '1' sends 0x9F, else 0x03 and
--                 req_addr_i; req_len_i bytes come back on a valid/ready
--                 port, data_last_o on the last.
--                 SCK_DIV = 4 (25 MHz): SCK falls and MOSI changes at
--                 phase 0, SCK rises at phase 2, and the IOB register
--                 samples MISO at phase 3: 30 ns after the fall (flash
--                 output delay 8 ns plus board delays), 10 ns before the
--                 next fall.
--                 If the output byte is still untaken when the next one is
--                 complete, SCK stops low (CS stays low) until it is.
--                 CS_n is high 2 x SCK_DIV clocks between commands and
--                 low SCK_DIV clocks before the first SCK edge.
--                 Clock domain: clk_i (system). Throughput 3.1 MB/s at
--                 25 MHz SCK.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First working version
-- Revision 1.01 - One-process state machine
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

	type spi_state_type is (SPI_IDLE, SPI_START, SPI_XFER, SPI_HAND, SPI_FINISH);
	signal spi_state: spi_state_type := SPI_IDLE;
	signal ph: natural range 0 to SCK_DIV - 1 := 0;
	signal bitn: natural range 0 to 7 := 0;
	signal gap: natural range 0 to GAP_CYCLES - 1 := 0;
	signal is_id: std_logic := '0';
	signal addr: std_logic_vector(23 downto 0) := (others => '0');
	signal cmd_left: natural range 0 to 4 := 0; -- Command bytes left, current included
	signal rx_left: unsigned(23 downto 0) := (others => '0'); -- Bytes still to return
	signal txreg: std_logic_vector(7 downto 0) := (others => '0');
	signal shreg: std_logic_vector(7 downto 0) := (others => '0');
	signal out_data: std_logic_vector(7 downto 0) := (others => '0');
	signal out_valid: std_logic := '0';
	signal out_last: std_logic := '0';

	-- Pin registers (IOB)
	signal cs_n_r: std_logic := '1';
	signal sck_r: std_logic := '0';
	signal mosi_r: std_logic := '0';
	signal miso_q: std_logic := '0';
	attribute IOB: string;
	attribute IOB of cs_n_r, sck_r, mosi_r, miso_q: signal is "TRUE";
begin
	process(clk_i, rst_i)
		variable out_free: boolean;
		variable rx_byte: std_logic_vector(7 downto 0);
		variable next_tx: std_logic_vector(7 downto 0);

		-- Hand a complete received byte to the output register and decide
		-- whether the command is finished
		procedure deliver(b: std_logic_vector(7 downto 0)) is
		begin
			out_data <= b;
			out_valid <= '1';
			if (rx_left = 1) then
				out_last <= '1';
				spi_state <= SPI_FINISH;
				gap <= GAP_CYCLES - 1;
				cs_n_r <= '1';
			else
				out_last <= '0';
				spi_state <= SPI_XFER;
				mosi_r <= '0';
				txreg <= (others => '0');
			end if;
			rx_left <= rx_left - 1;
			ph <= 0;
			bitn <= 0;
		end procedure;
	begin
		if (rst_i = '1') then
			spi_state <= SPI_IDLE;
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
			miso_q <= miso_i; -- IOB input register
			sck_r <= '0'; -- SCK is low unless SPI_XFER raises it below
			-- The output byte empties when the consumer takes it
			-- (deliver sets it again in the same cycle)
			out_valid <= out_valid and (not data_ready_i);
			out_free := (out_valid = '0') or (data_ready_i = '1');
			-- Received byte including this cycle's sample (SAMPLE_PH may be the
			-- last phase of the bit)
			if ((spi_state = SPI_XFER) and (ph = SAMPLE_PH)) then
				rx_byte := shreg(6 downto 0) & miso_q; -- MSB first: new bit enters at the bottom
			else
				rx_byte := shreg;
			end if;

			case spi_state is
				when SPI_IDLE =>
					cs_n_r <= '1';
					if (req_valid_i = '1') then
						is_id <= req_id_i;
						addr <= req_addr_i;
						rx_left <= unsigned(req_len_i);
						if (req_id_i = '1') then
							cmd_left <= 1; -- 0x9F alone
						else
							cmd_left <= 4; -- 0x03 plus three address bytes
						end if;
						spi_state <= SPI_START;
						gap <= SCK_DIV - 1;
						cs_n_r <= '0';
					end if;

				when SPI_START =>
					-- CS_n setup time before the first rising SCK edge
					if (gap = 0) then
						spi_state <= SPI_XFER;
						ph <= 0;
						bitn <= 0;
						if (is_id = '1') then
							next_tx := x"9F";
						else
							next_tx := x"03";
						end if;
						-- Bit 7 goes out now, the rest shifts out of txreg
						mosi_r <= next_tx(7);
						txreg <= next_tx(6 downto 0) & '0';
					else
						gap <= gap - 1;
					end if;

				when SPI_XFER =>
					shreg <= rx_byte;
					if (ph = SCK_DIV - 1) then
						if (bitn /= 7) then
							-- Next bit of this byte
							ph <= 0;
							bitn <= bitn + 1;
							mosi_r <= txreg(7);
							txreg <= txreg(6 downto 0) & '0';
						elsif (cmd_left /= 0) then
							-- A command or address byte is done; send the next one,
							-- or zeros while reading
							cmd_left <= cmd_left - 1;
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
							ph <= 0;
							bitn <= 0;
							mosi_r <= next_tx(7);
							txreg <= next_tx(6 downto 0) & '0';
						elsif (out_free) then
							deliver(rx_byte);
						else
							-- Output still full: stop SCK (low) and hold the byte
							spi_state <= SPI_HAND;
						end if;
					else
						ph <= ph + 1;
						if (ph + 1 >= HALF) then -- SCK high for the second half of the bit
							sck_r <= '1';
						end if;
					end if;

				when SPI_HAND =>
					if (out_free) then
						deliver(shreg);
					end if;

				when SPI_FINISH =>
					cs_n_r <= '1';
					if (gap = 0) then
						spi_state <= SPI_IDLE;
					else
						gap <= gap - 1;
					end if;

				when others =>
					spi_state <= SPI_IDLE;
			end case;
		end if;
	end process;

	req_ready_o <= '1' when (spi_state = SPI_IDLE) else '0';
	data_valid_o <= out_valid;
	data_o <= out_data;
	data_last_o <= out_last;
	busy_o <= '0' when (spi_state = SPI_IDLE) else '1';
	cs_n_o <= cs_n_r;
	sck_o <= sck_r;
	mosi_o <= mosi_r;
end arch;
