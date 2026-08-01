library ieee;
use ieee.std_logic_1164.all;

package consts_pkg is
	-- Tylko to, co definiuje kształt naszego grafu (DAG)
	constant NUM_EXT_INPUTS			: integer := 3;  -- x0, x1, x2
	constant NUM_EXT_OUTPUTS		: integer := 3;  -- y0, y1, y2
	constant NUM_LUTS				: integer := 30; -- Liczba bramek

	-- Szerokosc globalnej szyny: 3 wejscia + 30 wyjsc z bramek = 33
	constant TOTAL_SIGNALS_WIDTH	: integer := NUM_EXT_INPUTS + NUM_LUTS;

	constant DEBUG_BUS_WIDTH	: integer := 24;

	-- Typy konfiguracyjne -  dane przysylane z NIOS
	type conf_routing_arr_t	is array (0 to NUM_LUTS-1) of std_logic_vector(19 downto 0); --30x20=600bits
	type conf_F_arr_t		is array (0 to NUM_LUTS-1) of std_logic_vector(15 downto 0);--30x16=480bits

	-- 6 bitow zeby mozna bylo zakodowac wszystkie indeksy z total_signals (0-32)
	type conf_out_arr_t is array (0 to 2) of std_logic_vector(5 downto 0);--3x6=18bits
end package consts_pkg;
