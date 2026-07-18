library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity core is
	 -- interfejs dla ukladu zewnetrznego:
			-- x0 		: stan k 60s
			-- x1 		: stan k 5s
			-- x2			: sygnal zycia od nanopi
			-- y0 		:	sygnal rozladowywyjacy k60
			-- y1 		:	sygnal rozladowywujacy k5
			-- y2 		:	sygnal odcinajacy zasilanie nanopi
	Port (
		x : in  std_logic_vector(2 downto 0);
		y : out std_logic_vector(2 downto 0)
	);
end core;

architecture Structural of core is

	-- deklaracja komponentu LUT4
	component LUT4Cell is
		Port (
			F : in  std_logic_vector(15 downto 0);
			Address     : in  std_logic_vector(3 downto 0);
			Out_signal  : out std_logic
		);
	end component;

	-- 3 wejscia pierwotne + 30 wyjsc komorek LUT = 33
	signal all_signals : std_logic_vector(32 downto 0);

begin

	all_signals(0) <= x(0); -- kondensator 60s
	all_signals(1) <= x(1); -- kondensator 5s
	all_signals(2) <= x(2); -- sygnal zycia z UART
	 
	-- wizualizacja funkcji F dla poszczegolnych rownan- tablica prawdy LUT:
	--
	--                    || lut_0 (y0) = (I2 & ~I0) | I1
	--                    || lut_1 (y1) = ~I0
	--                    || lut_2 (y2) = I0 & ~I1
	------------------------------------------------------------------------------
	-- ADRES | I3 I2 I1 I0 || lut_0 | lut_1  | lut_2| - mozliwe 65536 takich kombinacji
	-- (Dec) |  8  4  2  1 || y0_out| y1_out| y2_out|   (tu tylko 3 odpowiadajace rownaniom ziarna)
	-- ---------------------------------------------------------------------------
	--   0   |  0  0  0  0 ||   0   |   1   |   0   |
	--   1   |  0  0  0  1 ||   0   |   0   |   1   |
	--   2   |  0  0  1  0 ||   1   |   1   |   0   |
	--   3   |  0  0  1  1 ||   1   |   0   |   0   |
	--   4   |  0  1  0  0 ||   1   |   1   |   0   |
	--   5   |  0  1  0  1 ||   0   |   0   |   1   |
	--   6   |  0  1  1  0 ||   1   |   1   |   0   |
	--   7   |  0  1  1  1 ||   1   |   0   |   0   |
	-- ----------------------------------------------------------------------------
	--   8   |  1  0  0  0 ||   0   |   1   |   0   |
	--   9   |  1  0  0  1 ||   0   |   0   |   1   |
	--  10   |  1  0  1  0 ||   1   |   1   |   0   |
	--  11   |  1  0  1  1 ||   1   |   0   |   0   |
	--  12   |  1  1  0  0 ||   1   |   1   |   0   |
	--  13   |  1  1  0  1 ||   0   |   0   |   1   |
	--  14   |  1  1  1  0 ||   1   |   1   |   0   |
	--  15   |  1  1  1  1 ||   1   |   0   |   0   |
	-- ----------------------------------------------------------------------------
	--
	-- lut_0.F = 16'hDCDC  (Bin: 16'b1101_1100_1101_1100, Dec: 16'd56540)
	-- lut_1.F = 16'h5555  (Bin: 16'b0101_0101_0101_0101, Dec: 16'd21845)
	-- lut_2.F = 16'h2222  (Bin: 16'b0010_0010_0010_0010, Dec: 16'd8738)
	--
	-- ----------------------------------------------------------------------------*/

	-- Generowanie powtarzalnej matrycy 30 LUT za pomoca petli strukturalnej
	gen_cgp_nodes: for i in 0 to 29 generate
		signal node_F  : std_logic_vector(15 downto 0);
		signal node_addr : std_logic_vector(3 downto 0);
	begin

		-- LUT 0: y0 = x1 or (x2 and not x0)
		-- Adress [0, x2, x1, x0]
		node_0_init: if i = 0 generate
			node_F	 <= X"DCDC";
			node_addr(0) <= all_signals(0); -- x0
			node_addr(1) <= all_signals(1); -- x1
			node_addr(2) <= all_signals(2); -- x2
			node_addr(3) <= '0';            -- Stuck-At-0
		end generate;

		-- LUT 1: y1 = not x0
		-- Adres [0, 0, 0, x0]
		node_1_init: if i = 1 generate
			node_F     <= X"5555";
			node_addr(0) <= all_signals(0);
			node_addr(1) <= '0';
			node_addr(2) <= '0';
			node_addr(3) <= '0';
				-- zapis uniwersalny gdyby liczba wejsc miala sie zmienic:
				-- node_addr <= (
				--		0 => all_signals(0), 
				--		others => '0'
				--	);
		end generate;

		-- LUT 2: y2 = x0 and not x1
		-- Adres [0, 0, x1, x0]
		node_2_init: if i = 2 generate
			node_F     <= X"2222";
			node_addr(0) <= all_signals(0);
			node_addr(1) <= all_signals(1);
			node_addr(2) <= '0';
			node_addr(3) <= '0';
		end generate;

		-- LUT 3 do 29: y = 0
		node_init: if i > 2 generate
			--node_F	<= X"0000";
			--node_addr	<= "0000";
			-- zapis uniwersalny gdyby liczba wejsc miala sie zmienic:
			node_F     <= (others => '0');
			node_addr    <= (others => '0');
				
		end generate;

		-- instancjacja fizyczna komorki LUT konkreten w strukturze FPGA
		lut_cell_inst : LUT4Cell
		port map (
			F => node_F,
			Address		=> node_addr,
			Out_signal	=> all_signals(i + 3)
		);

	end generate;

	-- wyprowaszebnie sygnalow do wyjsc z ukladu
	y(0) <= all_signals(3); -- LUT 0 do y0
	y(1) <= all_signals(4); -- LUT 1 do y1
	y(2) <= all_signals(5); -- LUT 2 do y2

end Structural;
