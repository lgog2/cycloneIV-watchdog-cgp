----------------------------------------------------------------------------------
-- file name: LUT4Cell.vhd
-- DESCRIPTION:
--		Configurable 4-input Look-Up Table (LUT4)
--		Integrates a 16-bit programmable truth table with routing multiplexers
--		to dynamically select 4 signals from the global signal bus.
--		Building block for the CGP DAG Reconfigurable Circuit (VRC).
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use IEEE.NUMERIC_STD.ALL;

use work.consts_pkg.all;

entity Lut4Cell is 
	generic (
		-- unused parameter
		NODE_INDEX : integer := 0
	);
	port(
		-- global input bus (30 LUT outputs + 3 external inputs = 33 signals)
		all_signals_in		: in  std_logic_vector(TOTAL_SIGNALS_WIDTH - 1 downto 0); --0-32
		-- input routing configuration
		--(selects which signals from all_signals_in connect to the 4 LUT inputs):
		-- only indices 0-31 are addressable (5bit)
		-- index 32 (output of the 30th LUT) is unreachable (DAG topology)
		-- Bits 19-15: i3 selector
		-- Bits 14-10: i2 selector
		-- Bits  9-5 : i1 selector
		-- Bits  4-0 : i0 selector
		conf_routing_in		: in  std_logic_vector(19 downto 0);

		conf_F_in 			: in std_logic_vector(15 downto 0);

		out_signal			: out std_logic

	);
end Lut4Cell;

architecture rtl of Lut4Cell is

	signal sel_i0, sel_i1, sel_i2, sel_i3 : integer range 0 to 31; --
	signal i0, i1, i2, i3 : std_logic;
	signal address : integer range 0 to 15;
begin
	-- decodin 5-bit routing configuration into integer selectors
	sel_i0 <= to_integer(unsigned(conf_routing_in(4 downto 0)));
	sel_i1 <= to_integer(unsigned(conf_routing_in(9 downto 5)));
	sel_i2 <= to_integer(unsigned(conf_routing_in(14 downto 10)));
	sel_i3 <= to_integer(unsigned(conf_routing_in(19 downto 15)));

	i0 <= all_signals_in(sel_i0);
	i1 <= all_signals_in(sel_i1);
	i2 <= all_signals_in(sel_i2);
	i3 <= all_signals_in(sel_i3);

	address			<= to_integer(unsigned'(i3 & i2 & i1 & i0));
	out_signal		<= conf_F_in(address);
end rtl;
