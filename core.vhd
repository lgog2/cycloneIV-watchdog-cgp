library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.consts_pkg.all;

entity core is
	 -- interfejs dla ukladu zewnetrznego:
			-- x0 		: stan k 60s
			-- x1 		: stan k 5s
			-- x2			: sygnal zycia od nanopi
			-- y0 		:	sygnal rozladowywyjacy k60
			-- y1 		:	sygnal rozladowywujacy k5
			-- y2 		:	sygnal odcinajacy zasilanie nanopi
	Port (
		x_in	: in  std_logic_vector(NUM_EXT_INPUTS - 1 downto 0);--3
		y_out	: out std_logic_vector(NUM_EXT_OUTPUTS - 1 downto 0); --3

		-- konfiduracja z NIOS -61 cykli (61x32bity)
		--genotyp to [30 x [F, in0, in1, in2, in3], out0, out1, out2]
		conf_routing_in	: in  conf_routing_arr_t;
		conf_F_in		: in  conf_F_arr_t;
		conf_out_in		: in  conf_out_arr_t

	);
end core;

architecture rtl of core is

	signal lut_outputs     : std_logic_vector(NUM_LUTS - 1 downto 0);

	--wektor wszystkich potencjalnych wejsc (3zewnetrzne + 30 z lut = 33)
	signal all_signals		: std_logic_vector(TOTAL_SIGNALS_WIDTH - 1 downto 0); --0-32

	-- Macierz bezpiecznych wejść dla każdego LUT
	type node_inputs_matrix_t is array (0 to NUM_LUTS - 1) of std_logic_vector(TOTAL_SIGNALS_WIDTH - 1 downto 0);
	signal node_inputs_matrix : node_inputs_matrix_t;


	-- tymczasowe sztywne ustawienie 3 pierwszych LUT
	signal conf_F			: conf_F_arr_t;--30 x std_logic_vector(15 downto 0);--30x16=480bits
	signal conf_routing		: conf_routing_arr_t;--30 x std_logic_vector(19 downto 0); --30x20=600bits
	signal conf_out			: conf_out_arr_t;--std_logic_vector(5 downto 0);--3x6=18bits


begin
	-- sztywne przy[isanie wejsc zewnetrznych x2-0 do poczatku wektora wszystkich wejsc
	--all_signals(NUM_EXT_INPUTS - 1 downto 0) <= x_in;

	all_signals <= lut_outputs & x_in;



	--TYMCZASOWE SZTYWNE WPISANIE FUNKCJI DO TRZECH PIERWCZYCH LUT:

	-- wizualizacja funkcji F dla poszczegolnych rownan- tablica prawdy LUT:
	--
	--                    || lut_0    y0 = (I2 & ~I0) | I1
	--                    || lut_1    y1 = ~I0
	--                    || lut_2    y2 = I0 & ~I1
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

	--odkomentowac do testu  ze sztywnym ziarnem:
	-- LUT0 :   y0 = (I2 & ~I0) | I1
	--conf_F(0) <= X"DCDC";
	--conf_F(0) <= X"0000";
	--indeksy all_signals_in I3=0 , I2=2, I1=1, I0=0
	--conf_routing(0) <= "00000" & "00010" & "00001" & "00000";

	-- LUT 1:   y1 = ~I0
	--conf_F(1) <= X"5555";
	--indeksy all_signals_in I3=0 , I2=0, I1=0, I0=0
	--conf_routing(1) <= "00000" & "00000" & "00000" & "00000";

	-- LUT 2:   y2 = I0 & ~I1
	--onf_F(2) <= X"2222";
	--indeksy all_signals_in I3=0 , I2=, I1=1, I0=0
	--conf_routing(2) <= "00000" & "00000" & "00001" & "00000";

	--zamianic 0 na 3 do testu  ze sztywnym ziarnem
	-- Generowanie konfiguracji pozostalych LUT z zewnatrz za pomoca petli strukturalnej
	--gen_conf_override: for i in 0 to NUM_LUTS - 1 generate
	--	conf_F(i)			<= conf_F_in(i);
	--	conf_routing(i) 	<= conf_routing_in(i);
	--end generate;

	conf_F <= conf_F_in;
	conf_routing <= conf_routing_in;
	-- do testu ze sztywnym ziarnem zamienic na ponizsze:
	--conf_F(3 to NUM_LUTS - 1) <= conf_F_in(3 to NUM_LUTS - 1);
	--conf_routing(3 to NUM_LUTS - 1) <= conf_routing_in(3 to NUM_LUTS - 1);

	--------------------------------------------------------------------------------------------
	-- BUDOWANIE BEZPIECZNEJ MACIERZY WEJSC (DAG zabezpiecznienie przed petlami na etapie analizy prze quartus)
	gen_matrix_rows: for i in 0 to NUM_LUTS - 1 generate

		--odciecie polaczen z wyzszych lut oraz od samego siebie
		node_inputs_matrix(i)(TOTAL_SIGNALS_WIDTH - 1 downto i + NUM_EXT_INPUTS) <= (others => '0');

		--dozwolone polaczenia od lut nizszych i wejsc zewnetrznych
		node_inputs_matrix(i)(i + NUM_EXT_INPUTS - 1 downto 0) <= all_signals(i + NUM_EXT_INPUTS - 1 downto 0);

	end generate;
-----------------------------------------------------------------------------------------


	-- generowanie 30 LUT stanowiacych core
	gen_cgp_nodes: for i in 0 to NUM_LUTS - 1 generate
	begin
		lut_cell_inst : entity work.Lut4Cell
		generic map (
			NODE_INDEX => i
		)
		port map (
			--wejscia:
			all_signals_in	=> node_inputs_matrix(i),
			conf_routing_in	=> conf_routing(i),
			conf_F_in			=> conf_F(i),

			--wyjscie:
			out_signal     => lut_outputs(i)
		);
	end generate;

	--odkomentowac do testu  ze sztywnym ziarnem
	-- przypisanie sztywne wyjsc z pierwszych trzech LUT (3-5 w all_signals_in) do wyjsc zewnetrznych
	--conf_out(0) <= std_logic_vector(to_unsigned(NUM_EXT_INPUTS, 6));--3
	--conf_out(1) <= std_logic_vector(to_unsigned(NUM_EXT_INPUTS + 1, 6));--4
	--conf_out(2) <= std_logic_vector(to_unsigned(NUM_EXT_INPUTS + 2, 6));--5

	--zakomentowac do testu  ze sztywnym ziarnem
	conf_out <= conf_out_in;

	y_out(0) <= all_signals(to_integer(unsigned(conf_out(0)))) when to_integer(unsigned(conf_out(0))) < TOTAL_SIGNALS_WIDTH else '0';
	y_out(1) <= all_signals(to_integer(unsigned(conf_out(1)))) when to_integer(unsigned(conf_out(1))) < TOTAL_SIGNALS_WIDTH else '0';
	y_out(2) <= all_signals(to_integer(unsigned(conf_out(2))) )when to_integer(unsigned(conf_out(2))) < TOTAL_SIGNALS_WIDTH else '0';

end rtl;
