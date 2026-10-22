--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    SPI Flash Reader Testbench
-- Module Name:    tb_flash_reader
-- Project Name:   First-Person Gate Array
-- Target Devices: Simulation only (Vivado xsim)
-- Tool versions:  Vivado 2025.1 xsim, VHDL-2008
-- Description:    Self-checking testbench for flash_reader against
--                 spi_flash_model (which checks SCK speed, CS timing,
--                 mode 0 and MOSI setup). The board adds 3 ns from the
--                 FPGA's pins to the flash and 2 ns back, on top of the
--                 flash's 8 ns output delay.
--                 Requests (every byte compared with the model's memory,
--                 data_last_o only on the last byte, nothing after it):
--                 - READ ID, 3 bytes (C2 20 16) and 5 bytes (then FF FF)
--                 - READ 1 byte at 0, 16 at 0x220000 (game data start),
--                   8 at the top of the 4 MB, 16 bytes written through
--                   the back door
--                 - READ 300 bytes at 0x123456 with random back-pressure,
--                   including stalls of hundreds of clocks
--                 Also: SCK is 25 MHz, req_ready_o stays low while busy
--                 (a request held during a command waits for the end),
--                 and the model counts one completed command per request.
--
-- Dependencies:   VHDL-2008, IEEE.std_logic_1164, IEEE.numeric_std,
--                 IEEE.math_real, tb_pkg, flash_reader, spi_flash_model
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
use IEEE.math_real.all;
use work.tb_pkg.all;
use work.spi_flash_model_pkg.all;

entity tb_flash_reader is
end tb_flash_reader;

architecture arch of tb_flash_reader is
	component flash_reader is
		generic(
			SCK_DIV: positive := 4
		);
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			req_valid_i: in std_logic;
			req_ready_o: out std_logic;
			req_id_i: in std_logic;
			req_addr_i: in std_logic_vector(23 downto 0);
			req_len_i: in std_logic_vector(23 downto 0);
			data_valid_o: out std_logic;
			data_ready_i: in std_logic;
			data_o: out std_logic_vector(7 downto 0);
			data_last_o: out std_logic;
			busy_o: out std_logic;
			cs_n_o: out std_logic;
			sck_o: out std_logic;
			mosi_o: out std_logic;
			miso_i: in std_logic
		);
	end component;
	component spi_flash_model is
		generic(
			JEDEC_ID: std_logic_vector(23 downto 0) := x"C22016";
			T_V: time := 8 ns;
			T_SCK_MIN: time := 20 ns;
			T_CSS: time := 5 ns;
			T_CSH: time := 30 ns;
			T_DS: time := 2 ns
		);
		port(
			cs_n_i: in std_logic;
			sck_i: in std_logic;
			mosi_i: in std_logic;
			miso_o: out std_logic;
			reads_o: out natural;
			errors_o: out natural
		);
	end component;

	constant PERIOD: time := 10 ns;
	constant T_TO_FLASH: time := 3 ns; -- FPGA clock-to-out plus trace to the flash
	constant T_FROM_FLASH: time := 2 ns; -- Trace back to the FPGA input
	constant MAX_BYTES: natural := 512;
	shared variable chk: checker_t;

	signal clk: std_logic := '0';
	signal rst: std_logic := '1';
	signal done: boolean := false;

	signal req_valid: std_logic := '0';
	signal req_ready: std_logic;
	signal req_id: std_logic := '0';
	signal req_addr: std_logic_vector(23 downto 0) := (others => '0');
	signal req_len: std_logic_vector(23 downto 0) := (others => '0');
	signal data_valid, data_last, busy: std_logic;
	signal data_ready: std_logic := '1';
	signal data: std_logic_vector(7 downto 0);
	signal cs_n, sck, mosi, miso: std_logic;
	signal flash_cs_n, flash_sck, flash_mosi, flash_miso: std_logic;
	signal flash_reads, flash_errors: natural;

	-- Received bytes of the current request
	type bytes_t is array (0 to MAX_BYTES - 1) of std_logic_vector(7 downto 0);
	signal rx_bytes: bytes_t := (others => (others => '0'));
	signal rx_count: natural := 0;
	signal rx_last_at: integer := -1; -- Index of the byte that had data_last_o
	signal rx_clear: boolean := false;
	signal stall: boolean := false; -- Random back-pressure on data_ready
	signal ready_while_busy: natural := 0;
begin
	dut: flash_reader
		port map (
			clk_i => clk,
			rst_i => rst,
			req_valid_i => req_valid,
			req_ready_o => req_ready,
			req_id_i => req_id,
			req_addr_i => req_addr,
			req_len_i => req_len,
			data_valid_o => data_valid,
			data_ready_i => data_ready,
			data_o => data,
			data_last_o => data_last,
			busy_o => busy,
			cs_n_o => cs_n,
			sck_o => sck,
			mosi_o => mosi,
			miso_i => miso
		);

	-- Board wiring delays
	flash_cs_n <= transport cs_n after T_TO_FLASH;
	flash_sck <= transport sck after T_TO_FLASH;
	flash_mosi <= transport mosi after T_TO_FLASH;
	miso <= transport flash_miso after T_FROM_FLASH;

	flash: spi_flash_model
		port map (
			cs_n_i => flash_cs_n,
			sck_i => flash_sck,
			mosi_i => flash_mosi,
			miso_o => flash_miso,
			reads_o => flash_reads,
			errors_o => flash_errors
		);

	-- Clock
	process
	begin
		if (done) then
			wait;
		end if;
		clk <= '0';
		wait for PERIOD / 2;
		clk <= '1';
		wait for PERIOD / 2;
	end process;

	-- Reset
	process
	begin
		rst <= '1';
		wait for 10.5 * PERIOD;
		rst <= '0';
		wait;
	end process;

	-- Consumer: random ready with occasional long stalls when asked
	process
		variable seed1, seed2: positive := 3;
		variable r: real;
	begin
		wait until rising_edge(clk);
		if (stall) then
			uniform(seed1, seed2, r);
			if (r < 0.02) then -- Here r * 10000 < 200, so the stall lasts 200 to 400 clocks
				data_ready <= '0';
				for i in 1 to 200 + integer(trunc(r * 10000.0)) loop
					wait until rising_edge(clk);
				end loop;
			elsif (r < 0.5) then
				data_ready <= '0';
			else
				data_ready <= '1';
			end if;
		else
			data_ready <= '1';
		end if;
	end process;

	-- Collector: every byte handed over, and the request port rule
	process(clk)
	begin
		if rising_edge(clk) then
			if (rx_clear) then
				rx_count <= 0;
				rx_last_at <= -1;
			elsif ((data_valid = '1') and (data_ready = '1')) then
				if (rx_count < MAX_BYTES) then
					rx_bytes(rx_count) <= data;
				end if;
				if (data_last = '1') then
					rx_last_at <= rx_count;
				end if;
				rx_count <= rx_count + 1;
			end if;
			if ((busy = '1') and (req_ready = '1')) then
				ready_while_busy <= ready_while_busy + 1;
			end if;
		end if;
	end process;

	-- Stimulus and checks
	process
		variable reqs: natural := 0;
		variable t0: time;

		-- Issue one request, wait for all its bytes, compare with the
		-- model's memory (or the ID bytes)
		procedure do_read(id: std_logic; addr: natural; len: natural; name: string) is
			variable want: natural;
		begin
			rx_clear <= true;
			wait until rising_edge(clk);
			rx_clear <= false;
			req_id <= id;
			req_addr <= std_logic_vector(to_unsigned(addr, 24));
			req_len <= std_logic_vector(to_unsigned(len, 24));
			req_valid <= '1';
			loop
				wait until rising_edge(clk);
				exit when (req_ready = '1');
			end loop;
			req_valid <= '0';
			reqs := reqs + 1;
			loop
				wait until rising_edge(clk);
				exit when (busy = '0');
			end loop;
			-- The last byte may still wait in the output register while the
			-- consumer stalls
			for i in 1 to 20000 loop
				exit when (rx_count >= len);
				wait until rising_edge(clk);
			end loop;
			wait for 20 * PERIOD; -- Nothing may follow the last byte
			chk.check(rx_count = len, name & ": got " & integer'image(rx_count) & " of " &
				integer'image(len) & " bytes");
			chk.check(rx_last_at = len - 1, name & ": data_last on byte " &
				integer'image(rx_last_at));
			for i in 0 to len - 1 loop
				if (id = '1') then
					case i is
						when 0 => want := 16#C2#;
						when 1 => want := 16#20#;
						when 2 => want := 16#16#;
						when others => want := 16#FF#;
					end case;
				else
					want := flash_mem.read(addr + i);
				end if;
				if (i < rx_count) then
					chk.check(unsigned(rx_bytes(i)) = to_unsigned(want, 8), name & ": byte " &
						integer'image(i) & " is " & to_hex(rx_bytes(i)) & ", want " &
						to_hex(std_logic_vector(to_unsigned(want, 8))));
				end if;
			end loop;
		end procedure;
	begin
		for i in 0 to 15 loop
			flash_mem.write(16#200000# + i, 17 * i);
		end loop;
		wait until (rst = '0');
		wait until rising_edge(clk);
		chk.check(cs_n = '1' and sck = '0', "idle pins: CS_n high, SCK low");

		do_read('1', 0, 3, "READ ID");
		do_read('1', 0, 5, "READ ID, 5 bytes");
		do_read('0', 0, 1, "READ 1 at 0");
		do_read('0', 16#220000#, 16, "READ 16 at 0x220000");
		do_read('0', 16#3FFFF8#, 8, "READ 8 at the top");
		do_read('0', 16#200000#, 16, "READ back-door bytes");

		-- SCK speed: measure during a long read
		rx_clear <= true;
		wait until rising_edge(clk);
		rx_clear <= false;
		req_id <= '0';
		req_addr <= x"010000";
		req_len <= std_logic_vector(to_unsigned(64, 24));
		req_valid <= '1';
		wait until rising_edge(clk) and (req_ready = '1');
		-- Hold a second request: it must wait until the first finishes
		req_addr <= x"020000";
		req_len <= std_logic_vector(to_unsigned(4, 24));
		wait until rising_edge(sck);
		wait until rising_edge(sck);
		t0 := now;
		for i in 1 to 10 loop
			wait until rising_edge(sck);
		end loop;
		-- 10 SCK periods of 40 ns: 25 MHz, a quarter of the 100 MHz clock
		chk.check(now - t0 = 400 ns, "SCK period " & time'image((now - t0) / 10));
		wait until rising_edge(clk) and (req_ready = '1');
		chk.check(rx_count = 64, "second request taken only after the first finished");
		req_valid <= '0';
		reqs := reqs + 2;
		wait until rising_edge(clk) and (busy = '0');
		wait for 20 * PERIOD;
		chk.check(rx_count = 68, "both held requests delivered " & integer'image(rx_count));

		-- Back-pressure
		stall <= true;
		do_read('0', 16#123456#, 300, "READ 300 with back-pressure");
		stall <= false;

		wait for 100 * PERIOD;
		chk.check(ready_while_busy = 0, "req_ready low while busy");
		chk.check(flash_reads = reqs, "flash model saw " & integer'image(flash_reads) &
			" commands, expected " & integer'image(reqs));
		chk.check(flash_errors = 0, "flash model errors: " & integer'image(flash_errors));
		done <= true;
		tb_finish("tb_flash_reader", chk.checks, chk.errors);
		wait;
	end process;
end arch;
