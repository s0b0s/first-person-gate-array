--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Line Fetcher
-- Module Name:    line_fetcher
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    System-domain half of the display: copies one rendered
--                 line (RENDER_W bytes) from the front framebuffer in SRAM
--                 into the line buffer half (line mod 2), as SRAM arbiter
--                 master 0 (top priority).
--                 first_i (once per frame, in vertical blanking) fetches
--                 line 0 and latches front_i, so the buffer shown cannot
--                 change in the middle of a frame; next_i fetches the
--                 following line. The pixel side sends next_i when it
--                 starts showing line r (on scanline 2r), so line r + 1
--                 has two scanlines (6,400 clocks) for 320 reads (640
--                 clocks at 2 cycles per access).
--                 The line numbers are counted here, so only single-bit
--                 event pulses cross from the pixel domain.
--                 line_start_o pulses with line_o when a fetch starts
--                 (the buffer manager uses it as a display line clock).
--                 overrun_o pulses if a request arrives while a fetch is
--                 still running (a missed deadline; never expected).
--                 Clock domain: clk_i (system).
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std, hw_pkg,
--                 game_pkg
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
use work.game_pkg.all;

entity line_fetcher is
	port(
		clk_i: in std_logic; -- System clock
		rst_i: in std_logic; -- Asynchronous reset, active high
		first_i: in std_logic; -- Pulse: fetch line 0 of a new frame
		next_i: in std_logic; -- Pulse: fetch the next line
		front_i: in std_logic; -- Front buffer select (latched at first_i)
		-- SRAM arbiter master port (reads only)
		m_req_o: out std_logic;
		m_addr_o: out std_logic_vector(18 downto 0);
		m_gnt_i: in std_logic;
		m_rvalid_i: in std_logic;
		m_rdata_i: in std_logic_vector(7 downto 0);
		-- Line buffer write port
		lb_we_o: out std_logic;
		lb_addr_o: out std_logic_vector(9 downto 0);
		lb_data_o: out std_logic_vector(7 downto 0);
		-- Status
		line_start_o: out std_logic; -- Pulse when a line fetch starts
		line_o: out std_logic_vector(7 downto 0); -- Line being fetched
		overrun_o: out std_logic -- Pulse: request while still busy
	);
end line_fetcher;

architecture arch of line_fetcher is
	signal line: unsigned(7 downto 0) := (others => '0');
	signal base: unsigned(18 downto 0) := (others => '0'); -- SRAM address of x = 0
	signal x_req: natural range 0 to RENDER_W := RENDER_W; -- Next byte to request
	signal x_ret: natural range 0 to RENDER_W := RENDER_W; -- Next byte to return
	signal busy: std_logic;
	signal last_line: std_logic;
	signal start: std_logic;
	signal line_start: std_logic := '0';
	signal overrun: std_logic := '0';
begin
	busy <= '1' when ((x_req /= RENDER_W) or (x_ret /= RENDER_W)) else '0';
	last_line <= '1' when (line = RENDER_H - 1) else '0';
	-- After the last line, next_i is ignored: line 0 waits for first_i
	start <= first_i or (next_i and (not busy) and (not last_line));

	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			line <= (others => '0');
			base <= (others => '0');
			x_req <= RENDER_W;
			x_ret <= RENDER_W;
			line_start <= '0';
			overrun <= '0';
		elsif rising_edge(clk_i) then
			line_start <= start;
			overrun <= (first_i or next_i) and busy;
			if (first_i = '1') then
				-- New frame: line 0 of the buffer that is front now. Any
				-- unfinished fetch is abandoned (only after an overrun).
				line <= (others => '0');
				if (front_i = '1') then
					base <= to_unsigned(FB1_BASE, 19);
				else
					base <= to_unsigned(FB0_BASE, 19);
				end if;
				x_req <= 0;
				x_ret <= 0;
			elsif (start = '1') then
				line <= line + 1;
				base <= base + RENDER_W;
				x_req <= 0;
				x_ret <= 0;
			else
				if ((x_req /= RENDER_W) and (m_gnt_i = '1')) then
					x_req <= x_req + 1;
				end if;
				if ((x_ret /= RENDER_W) and (m_rvalid_i = '1')) then
					x_ret <= x_ret + 1;
				end if;
			end if;
		end if;
	end process;

	m_req_o <= '1' when (x_req /= RENDER_W) else '0';
	m_addr_o <= std_logic_vector(base + x_req);

	-- Returned bytes go straight into the line buffer
	lb_we_o <= m_rvalid_i when (x_ret /= RENDER_W) else '0';
	lb_addr_o <= std_logic_vector(line(0) & to_unsigned(x_ret, 9)); -- Half = line mod 2, 512 bytes each
	lb_data_o <= m_rdata_i;

	line_start_o <= line_start;
	line_o <= std_logic_vector(line);
	overrun_o <= overrun;
end arch;
