library ieee;
use ieee.std_logic_1164.all;
use IEEE.NUMERIC_STD.ALL;

use work.consts_pkg.all;

entity Lut4Cell is 
	generic (
		NODE_INDEX : integer := 0
	);
	port(
		-- szyna wszystkich mozliwych wejsc (30wyjsc lut + 2 wejscia zewnetrzne = 32)
		--w rzeczywistosci  31 wystarczy : max 29 lut poprzedzajcych nie 30 (bo DAG)
		--Quartus podczas syntezy to zoptymalizuje
		all_signals_in		: in  std_logic_vector(TOTAL_SIGNALS_WIDTH - 1 downto 0); --0-32
		-- konfiguracja wejsc -routing- co jest podlaczone do kazdego z 4 wejsc:
			--19-15: i3
			--14-10: i2
			--9-5: i1
			--4-0: i0
		conf_routing_in		: in  std_logic_vector(19 downto 0);

		conf_F_in 			: in std_logic_vector(15 downto 0);

		out_signal			: out std_logic

		--mask_sa0        : in  std_logic_vector(3 downto 0);
		--mask_sa1        : in  std_logic_vector(3 downto 0);
	);
end Lut4Cell;

architecture rtl of Lut4Cell is

	--constant MAX_INPUT_IDX : integer := (NUM_EXT_INPUTS - 1) + NODE_INDEX;
	signal sel_i0, sel_i1, sel_i2, sel_i3 : integer range 0 to 31; --
	signal i0, i1, i2, i3 : std_logic;
	signal address : integer range 0 to 15;
begin
	-- dekodowanie 5-bitowych indeksow sygnalu wejsciowego (0 do 31 bo skoro DAG to ostatni 32 nigdy nie zostanie przypisany)
	sel_i0 <= to_integer(unsigned(conf_routing_in(4 downto 0)));
	sel_i1 <= to_integer(unsigned(conf_routing_in(9 downto 5)));
	sel_i2 <= to_integer(unsigned(conf_routing_in(14 downto 10)));
	sel_i3 <= to_integer(unsigned(conf_routing_in(19 downto 15)));

	 -- 'w' jak 'wire'; '<=' rozne znaczenie zalezne od kontekstu
	 --dzieki warunkom quartus zsyntetyzuje tylko polaczenia niezbedne do budowy DAG
	 --tzn odetnie wszystkie potencjalne polaczenia do LUT o wyzszym indeksie niz podany jako generic MAX_INPUT_IDX
	--i0 <= all_signals_in(sel_i0) when sel_i0 <= MAX_INPUT_IDX else '0';
	--i1 <= all_signals_in(sel_i1) when sel_i1 <= MAX_INPUT_IDX else '0';
	--i2 <= all_signals_in(sel_i2) when sel_i2 <= MAX_INPUT_IDX else '0';
	--i3 <= all_signals_in(sel_i3) when sel_i3 <= MAX_INPUT_IDX else '0';

	i0 <= all_signals_in(sel_i0);
	i1 <= all_signals_in(sel_i1);
	i2 <= all_signals_in(sel_i2);
	i3 <= all_signals_in(sel_i3);

	--w_i0 <= (tu_przejsciowy OR mask_sa1(0)) AND (NOT mask_sa0(0)); itd

	address			<= to_integer(unsigned'(i3 & i2 & i1 & i0));
	out_signal		<= conf_F_in(address);
end rtl;
