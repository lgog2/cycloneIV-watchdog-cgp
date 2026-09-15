--------------------------------------------------------------------------------
-- file name: consts_pkg.vhd
-- DESCRIPTION:
--		Global system parameters and data types
--		Fully parameterized. Vector widths scale automatically based on NUM_LUTS.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

package consts_pkg is

	-- =========================================================================
	-- HELPER FUNCTION (Evaluated at compile-time)
	-- =========================================================================
	-- Computes the ceiling of log base 2 (used to determine bus widths)
	function clog2(depth : integer) return integer;

	-- =========================================================================
	-- CORE TOPOLOGY PARAMETERS
	-- =========================================================================
	constant NUM_EXT_INPUTS			: integer := 3;  -- x0, x1, x2
	constant NUM_EXT_OUTPUTS		: integer := 3;  -- y0, y1, y2
	constant NUM_LUTS				: integer := 30; -- total nodes
	constant NUM_LUT_INPUTS			: integer := 4;  -- Inputs per node

	-- global bus width: 3 inputs + 30 LUT outputs = 33
	constant TOTAL_SIGNALS_WIDTH	: integer := NUM_EXT_INPUTS + NUM_LUTS;

	constant DEBUG_BUS_WIDTH		: integer := 24;

	-- =========================================================================
	-- Constants for mutation engine:
	-- =========================================================================
	constant TOTAL_GENES_F			: integer := NUM_LUTS;--30
	constant TOTAL_GENES_ROUTING	: integer := NUM_LUTS * NUM_LUT_INPUTS;--120
	constant TOTAL_GENES_OUT		: integer := NUM_EXT_OUTPUTS;--3
	-- total mutation space (30 + 120 + 3 = 153)
	constant TOTAL_GENES 			: integer := TOTAL_GENES_F + TOTAL_GENES_ROUTING + TOTAL_GENES_OUT;

	-- Automatically calculated routing value width for DAG(clog2(32) = 5 bits)
	constant INTERNAL_ROUTE_WIDTH 		: integer := clog2(TOTAL_SIGNALS_WIDTH - 1);

	-- Automatically calculated routing value width for outputs(clog2(33) = 6 bits)
	constant OUTPUT_ROUTE_WIDTH 		: integer := clog2(TOTAL_SIGNALS_WIDTH);

	-- ======================================================================================
	-- Configuration arrays - data payload from NIOS:
	-- ======================================================================================

	-- Input Routing: [19:15]=sel_i3 | [14:10]=sel_i2 | [9:5]=sel_i1 | [4:0]=sel_i0
	type conf_routing_arr_t	is array (0 to NUM_LUTS-1) of std_logic_vector( ((NUM_LUT_INPUTS * INTERNAL_ROUTE_WIDTH) - 1) downto 0 ); --19-0 (30x20=600bits)
	-- LUT Truth Table (F): 16 bits per LUT (representing all 16 states of a 4-input logic gate)
	type conf_F_arr_t		is array (0 to NUM_LUTS-1) of std_logic_vector((2**NUM_LUT_INPUTS) - 1 downto 0);--15-0 (30x16=480bits)

	--External Outputs Routing (y0, y1, y2): 6 bits required to address all indices from total_signals (0 to 32)
	type conf_out_arr_t		is array (0 to 2) of std_logic_vector(OUTPUT_ROUTE_WIDTH - 1 downto 0);--5-0 (3x6=18bits)

	-- Hardware Faults[31:0]:
	--	[31:16]=SPBI/MPBI (16 bits)
	--	[15:13]unused
	--	[12:8]=SA_VAL (5 bits) (Stuck-At Value: 1=VCC, 0=GND for [OUT, I3, I2, I1, I0])
	--	[7:5]   : unused
	--	[4:0]=SA_EN (5 bits) (Stuck-At Enable: 1=Fault Active, 0=Healthy for [OUT, I3, I2, I1, I0])
	type conf_fault_arr_t	is array (0 to NUM_LUTS-1) of std_logic_vector(31 downto 0);--30x32=960bits

end package consts_pkg;


package body consts_pkg is

	function clog2(depth : integer) return integer is
		variable temp : integer := depth;
		variable ret_val : integer := 0;
	begin
		while temp > 1 loop
			ret_val	:= ret_val + 1;
			temp	:= temp / 2;
		end loop;

		-- Adjustment for non-powers of 2
		if (2**ret_val) < depth then
			ret_val := ret_val + 1;
		end if;

		return ret_val;
	end function;

end package body consts_pkg;

