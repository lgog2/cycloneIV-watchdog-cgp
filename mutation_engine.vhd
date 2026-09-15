--------------------------------------------------------------------------------
-- file name: mutation_engine.vhd
-- DESCRIPTION :
--		Asynchronous combinatorial mutation engine for CGP.

-- TECHNICAL MECHANISM:
--		The engine dynamically maps 64-bit pseudo-random noise (PRNG) into a highly
--		structured mutation payload (gene index, node index, new payload data) in a
--		single clock-less combinational pass.
--
-- 1. LEMIRE'S FAST SCALING:
--		Instead of utilizing hardware-expensive modulo dividers (e.g., X mod 153),
--		this module treats the 32-bit PRNG noise as a fixed-point fraction [0, 1)
--		and scales it to the required topological limit [0, TOTAL_GENES - 1].
--		Formula: Result = (PRNG_32 * TOTAL_GENES) / 2^32.
--		Hardware realization: A single embedded DSP multiplier truncating the lower
--		32-bits via wire routing (shift right).
--
-- 2. GENE DECODER:
--		The total gene space [0 to TOTAL_GENES-1] is dynamically segmented:
--		- [0 to F-1](0-29)			: Truth Table (LUT logic) mutation.
--		- [F to F+R-1](30-149)		: Routing mutation (divided by shift operations).
--		- [F+R to TOTAL-1](150-152)	: Output multiplexer mutation.
--
-- 3. UNIFORM PROBABILITY DISTRIBUTION & MODULO BIAS:
--		By flattening the topological elements into a single 1D gene array, every
--		configuration atom receives an identical mutation probability of exactly
--		(1 / TOTAL_GENES). Based on default topology (30 nodes, 4 inputs):
--		- Logic Mutation Probability   : TOTAL_GENES_F / TOTAL_GENES (~19.6%)
--		- Routing Mutation Probability : TOTAL_GENES_ROUTING / TOTAL_GENES (~78.4%)
--		- Output Mutation Probability  : TOTAL_GENES_OUT / TOTAL_GENES (~2.0%)
--		Lemire's scaling introduces a theoretical modulo bias since 2^32 is not
--		perfectly divisible by TOTAL_GENES. However, this bias is bounded at
--		~3.5e-8, which is negligible for hardware PRNG applications, guaranteeing
--		an effectively isotropic mutation field.

-- 4. DAG CONSTRAINT ENFORCEMENT:
--		To guarantee Directed Acyclic Graph (DAG) integrity, the 'int_limit' signal
--		dynamically calculates the maximum valid routing index for any given node
--		(NUM_EXT_INPUTS + int_node_idx).
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.consts_pkg.all;

entity mutation_engine is
	port (
		-- INPUT: 64-bit asynchronous noise from external PRNG
		prng_64_in		: in  std_logic_vector(63 downto 0);

		-- OUTPUTS: Asynchronously computed mutation instructions
		target_gene_out	: out integer range 0 to (TOTAL_GENES - 1);
		node_idx_out	: out integer range 0 to (NUM_LUTS - 1);
		in_idx_out		: out integer range 0 to (NUM_LUT_INPUTS - 1);
		val_F_out		: out std_logic_vector((2**NUM_LUT_INPUTS) - 1 downto 0);--15-0
		val_route_out	: out std_logic_vector(OUTPUT_ROUTE_WIDTH - 1 downto 0)--5-0
	);
end entity mutation_engine;

architecture rtl of mutation_engine is

	-- Word splitting for Lemire's scaling
	alias prng_A_in			: std_logic_vector(31 downto 0) is prng_64_in(31 downto 0);
	alias prng_B_in			: std_logic_vector(31 downto 0) is prng_64_in(63 downto 32);

	-- DSP multiplier signals
	signal dsp_mult_A		: unsigned(63 downto 0);
	signal dsp_mult_B		: unsigned(63 downto 0);

	-- Internal decoder signals
	signal int_target_gene	: integer range 0 to TOTAL_GENES - 1;--0-152
	signal int_route_idx	: integer range 0 to (TOTAL_GENES_ROUTING - 1);--0-119
	signal int_node_idx		: integer range 0 to (NUM_LUTS - 1);--0-29
	signal int_limit		: integer range 0 to TOTAL_SIGNALS_WIDTH;--0-33

begin
	-- =========================================================================
	-- MAIN GENE SELECTOR (Lemire's Scaling)
	-- =========================================================================
	-- Maps 32-bit PRNG to [0, 152] range using hardware multipliers (DSP)
	dsp_mult_A		<= unsigned(prng_A_in) * to_unsigned(TOTAL_GENES, 32);
	int_target_gene	<= to_integer(dsp_mult_A(63 downto 32));

	-- =========================================================================
	-- DECODER
	-- =========================================================================
	-- Offset extraction for routing genes (genes 30 to 149)
	int_route_idx	<= (int_target_gene - TOTAL_GENES_F)
						when (int_target_gene >= TOTAL_GENES_F and int_target_gene < (TOTAL_GENES_F + TOTAL_GENES_ROUTING))
						else 0;

	-- Node index extraction (integer division by 4 using logical shift right)
	-- Note: '10' allows up to 1024 routing genes (NUM_LUTS up to 256)
	int_node_idx	<= to_integer(to_unsigned(int_route_idx, 10)(9 downto 2));

	-- Input pin index extraction (modulo 4 using bitwise AND mask)
	in_idx_out		<= to_integer(to_unsigned(int_route_idx, 10)(1 downto 0));

	-- Topological constraint limit
	-- Limits valid routing sources to inputs (3) + preceding nodes (N)
	int_limit		<= TOTAL_SIGNALS_WIDTH
						when (int_target_gene >= (TOTAL_GENES_F + TOTAL_GENES_ROUTING)) else (NUM_EXT_INPUTS + int_node_idx);

	-- =========================================================================
	-- NEW MUTATION PAYLOAD GENERATION
	-- =========================================================================
	-- Maps secondary 32-bit PRNG to dynamically calculated routing limit [0, int_limit-1]
	dsp_mult_B		<= unsigned(prng_B_in) * to_unsigned(int_limit, 32);

	-- =========================================================================
	-- OUTPUT ASSIGNMENTS
	-- =========================================================================
	-- Scaled valid routing index taken from upper 32-bits of Lemire's multiplication
	val_route_out	<= std_logic_vector(dsp_mult_B((32 + OUTPUT_ROUTE_WIDTH - 1) downto 32));--37-32

	-- Random 16-bit Truth Table data taken directly from secondary 32-bit PRNG
	val_F_out		<= prng_B_in(15 downto 0);

	target_gene_out	<= int_target_gene;
	node_idx_out	<= int_node_idx;

end architecture rtl;
