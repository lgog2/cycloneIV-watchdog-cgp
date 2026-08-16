library ieee;
use ieee.std_logic_1164.all;

package consts_pkg is
	-- core parameters defining the DAG topology
	constant NUM_EXT_INPUTS			: integer := 3;  -- x0, x1, x2
	constant NUM_EXT_OUTPUTS		: integer := 3;  -- y0, y1, y2
	constant NUM_LUTS				: integer := 30; -- Liczba bramek

	-- global bus width: 3 inputs + 30 LUT outputs = 33
	constant TOTAL_SIGNALS_WIDTH	: integer := NUM_EXT_INPUTS + NUM_LUTS;

	constant DEBUG_BUS_WIDTH	: integer := 24;

	-- configuration arrays - data payload from NIOS:

	-- Input Routing: [19:15]=sel_i3 | [14:10]=sel_i2 | [9:5]=sel_i1 | [4:0]=sel_i0
	type conf_routing_arr_t	is array (0 to NUM_LUTS-1) of std_logic_vector(19 downto 0); --30x20=600bits
	-- LUT Truth Table (F): 16 bits per LUT (representing all 16 states of a 4-input logic gate)
	type conf_F_arr_t		is array (0 to NUM_LUTS-1) of std_logic_vector(15 downto 0);--30x16=480bits

	--External Outputs Routing (y0, y1, y2): 6 bits required to address all indices from total_signals (0 to 32)
	type conf_out_arr_t		is array (0 to 2) of std_logic_vector(5 downto 0);--3x6=18bits

	-- Hardware Faults: [31:16]=SEU/MBU (16 bits) | [12:8]=SA_VAL (5 bits) | [4:0]=SA_EN (5 bits)
	type conf_fault_arr_t	is array (0 to NUM_LUTS-1) of std_logic_vector(31 downto 0);--30x32=600bits=960bits

	end package consts_pkg;
