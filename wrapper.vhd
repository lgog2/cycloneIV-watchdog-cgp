----------------------------------------------------------------------------------
-- file name: wrapper.vhd
-- DESCRIPTION:
--	Synchronous FSM controller.
--	Operates at 50MHz, serving as the synchronization boundary
--	between the asynchronous reconfigurable VRC core, the external 3Hz RC circuit,
--	the watched system, and the Nios II processor (via Avalon-MM).
--	Manages hardware fitness evaluation, autonomous (1+1)-ES evolution,
--	telemetry, and provides interface for hardware fault injection.
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.consts_pkg.all;

entity wrapper is
	generic (
		-- 50 000 000 / 3 = 16 666 666 (Requires 24 bits, max is 16 777 215)
		TICKS_3HZ			: integer := 16666666; -- ~333 ms at 50MHz
		-- debouncer delay for capacitors transitional state signals
		DEBOUNCE_CYCLES		: integer := 500000;  -- 10 ms at 50MHz

		MAX_FITNESS			: integer := 24;
		-- evaluator delay required for signal propagation through the DAG
		DAG_EVAL_DELAY		: integer := 8
	);

	Port (
		clk					: in  std_logic; -- 50 MHz clock (t = 20ns)
		rst_n				: in  std_logic; -- asynchronous active-low reset

	--- external interface:
			-- analog_x_in[0] 		: 60s capacitor state
			-- analog_x_in[1] 		: 5s capacitor state
			-- uart_rx				: heartbeat signal from watched system
			-- analog_y_out[0] 		: 60s capacitor discharge signal
			-- analog_y_out[1] 		: 5s capacitor discharge signal
			-- analog_y_out[2] 		: watched system power cutoff signal

		analog_x_in			: in  std_logic_vector(1 downto 0);
		uart_rx_in			: in  std_logic;
		analog_y_out		: out std_logic_vector(2 downto 0);

		-- AVALON-MM Slave Interface (for NIOS II)
		-- Address Map (0 - 63):
			--0-29 conf_routing_arr_t
			--30-59 conf_F_arr_t
			--60 conf_out_arr_t
			--61 control register (commands and configuration from NIOS)
			--62 status register for feedback to NIOS
			--63 expected truth table
			--64 faults injection
			--90 cost of last repair in generations of evolution
			--91 live counter of generations of evolution
			--100 PRNG seed LSB
			--101 PRNG seed MSB
			--102 PRNG out LSB
			--103 PRNG out MSB

		avs_address			: in  std_logic_vector(11 downto 0);-- byte addressing from NIOS (4kb address space)
		avs_chipselect		: in  std_logic;
		avs_read			: in  std_logic;
		avs_readdata		: out std_logic_vector(31 downto 0);
		avs_write			: in  std_logic;
		avs_writedata		: in  std_logic_vector(31 downto 0);
		avs_waitrequest		: out std_logic; -- freezes NIOS during Avalon-MM read/write
		ins_irq				: out std_logic; -- Interrupt request to NIOS

		-- diagnostics
		panic_flag_out		: out std_logic; -- watchdog functionality disabled
		debug_bus			: out std_logic_vector(DEBUG_BUS_WIDTH - 1 downto 0)-- 23-0
	);
end wrapper;

architecture rtl of wrapper is

	constant EVAL_COMBINATIONS		: integer := 2**NUM_EXT_INPUTS;-- 8

	-- y(2)='0' [watched system power kept ON], y(1)='1' [5s cap discharge], y(0)='1' [60s cap discharge]
	constant SAFE_OUT				: std_logic_vector(2 downto 0) := "011";

	-- Base evaluation latency from the FSM pipeline
	constant FSM_OVERHEAD_CYCLES	: integer := 3;

	-- ADDRESS MAP
	constant ADDR_CONF_ROUTING		: integer := 0;
	constant ADDR_CONF_F			: integer := NUM_LUTS;-- 30
	constant ADDR_CONF_OUT			: integer := NUM_LUTS * 2;-- 60
	constant ADDR_CTRL				: integer := (NUM_LUTS * 2) + 1;-- 61
	constant ADDR_STATUS			: integer := (NUM_LUTS * 2) + 2;-- 62
	constant ADDR_EXPECTED_Y		: integer := (NUM_LUTS * 2) + 3;-- 63;
	constant ADDR_FAULT_BASE		: integer := (NUM_LUTS * 2) + 4;-- 64;

	-- TELEMETRY & SEED ADDRESSES
	constant ADDR_LAST_REPAIR_GENS	: integer := (NUM_LUTS * 2) + 30; -- 90
	constant ADDR_CURRENT_GENS		: integer := (NUM_LUTS * 2) + 31; -- 91
	constant ADDR_PRNG_SEED_L		: integer := (NUM_LUTS * 2) + 40; -- 100
	constant ADDR_PRNG_SEED_H		: integer := (NUM_LUTS * 2) + 41; -- 101
	constant ADDR_PRNG_OUT_L		: integer := (NUM_LUTS * 2) + 42; -- 102
	constant ADDR_PRNG_OUT_H		: integer := (NUM_LUTS * 2) + 43; -- 103

	type status_reg_t is record
		panic_flag		: std_logic;
		repair_flag		: std_logic;
		fitness			: integer range 0 to MAX_FITNESS; -- 5 bits
	end record;

	type control_reg_t is record
		restart_cmd		: std_logic; -- strobe
		prng_step_cmd	: std_logic; -- strobe for manual PRNG control
		load_conf_cmd	: std_logic; -- strobe: load configuration from shadow registers
		evo_disable		: std_logic; -- state disabling hardware evolution (mode switch from default ON)
		reset_3hz_cmd	: std_logic;-- strobe reseting timer of 3hz generator
		load_seed_cmd	: std_logic;-- strobe loading seed to PRNG

	end record;

	function to_avalon_status(s : status_reg_t) return std_logic_vector is
		variable v : std_logic_vector(31 downto 0) := (others => '0');
	begin
		v(0) := s.panic_flag;
		v(1) := s.repair_flag;
		--bits 2-7 reserved
		v(12 downto 8)  := std_logic_vector(to_unsigned(s.fitness, 5));
		--bits 13-31 reserved
		return v;
	end function;

	function from_avalon_ctrl(v : std_logic_vector(31 downto 0)) return control_reg_t is
		variable c : control_reg_t;
	begin
		c.restart_cmd	:= v(0);
		c.prng_step_cmd	:= v(1);
		c.load_conf_cmd	:= v(2);
		c.evo_disable	:= v(3);
		c.reset_3hz_cmd	:= v(4);
		c.load_seed_cmd	:= v(5);

		return c;
	end function;

	type state_t is (
		ST_INIT,
		ST_BACKGROUND_EVAL_SETUP,
		ST_BACKGROUND_EVAL_WAIT,
		ST_BACKGROUND_EVAL_READ,
		ST_BACKGROUND_EVAL_DECISION,
		ST_BACKGROUND_EVAL_DONE,
		ST_REPAIR,
		ST_PANIC,
		ST_SERVE_ANALOG_SETUP,
		ST_SERVE_ANALOG_WAIT,
		ST_SERVE_ANALOG_LATCH
	);

	signal current_state	: state_t;
	signal state_debug		: std_logic_vector(3 downto 0);

	-- metastability synchronizers
	signal sync_x0 : std_logic_vector(1 downto 0) := "00";
	signal sync_x1 : std_logic_vector(1 downto 0) := "00";
	signal final_x : std_logic_vector(1 downto 0);

	-- 10ms debouncer counters for 50MHz capacitor state sampling
	signal cnt_x0 : integer range 0 to DEBOUNCE_CYCLES := 0;
	signal cnt_x1 : integer range 0 to DEBOUNCE_CYCLES := 0;

	-- core interface
	signal core_x_in		: std_logic_vector(2 downto 0);
	signal core_y_out		: std_logic_vector(2 downto 0);
	signal latched_y		: std_logic_vector(2 downto 0);

	-- evaluation interface
	signal eval_vector		: unsigned(2 downto 0) := (others => '0');-- inputs combination
	signal current_fitness	: integer range 0 to MAX_FITNESS := 0;-- forces 5-bit register synthesis
	signal snapshot_fitness	: integer range 0 to MAX_FITNESS := 0;-- snapshot register for status_reg

	-- expected truth table outputs for fitness evaluation - detailed in 'core.vhd'
	type truth_table_t is array (0 to 7) of std_logic_vector(2 downto 0);
	--three registers for TMR (Triple Modular Redundancy) initialized with the same truth table
	signal expected_y_reg_A : truth_table_t := ( "010", "100", "011", "001", "011", "100", "011", "001" );
	signal expected_y_reg_B : truth_table_t := ( "010", "100", "011", "001", "011", "100", "011", "001" );
	signal expected_y_reg_C : truth_table_t := ( "010", "100", "011", "001", "011", "100", "011", "001" );
	-- combinatorial output from TMR
	signal voted_expected_y : truth_table_t;

	-- 3Hz tick generator from 50MHz clock (ZOH sampling trigger)
	signal timer_3hz			: integer range 0 to TICKS_3HZ := 0;
	signal tick_3hz				: std_logic;
	signal tick_3Hz_pending_flag: std_logic := '0';

	-- UART signals and flags
	signal uart_alive_flag		: std_logic := '0';
	signal uart_signal			: std_logic;
	signal clear_uart_sig		: std_logic;

	-- AVALON-MM REGISTERS
	--signal conf_routing_reg : conf_routing_arr_t	:= (others => (others => '0'));
	-- hard-configured for watchdog functionality:
	signal conf_routing_reg : conf_routing_arr_t := (
		-- LUT 0: I3=0(Junk), I2=2(x2), I1=1(x1), I0=0(x0)
		0 => "00000" & "00010" & "00001" & "00000",

		-- LUT 1: I3=0, I2=0, I1=0(wszystko Junk), I0=0(x0)
		1 => "00000" & "00000" & "00000" & "00000",

		-- LUT 2: I3=0(Junk), I2=0(Junk), I1=1(x1), I0=0(x0)
		2 => "00000" & "00000" & "00001" & "00000",

		others => (others => '0') -- JUNK DNA
	);

	--signal conf_F_reg : conf_F_arr_t := (others => (others => '0'));
	-- hard-configured for watchdog functionality:
	signal conf_F_reg : conf_F_arr_t := (
		0 => x"DCDC", -- LUT 0: y0 = (x2 & !x0) | x1
		1 => x"5555", -- LUT 1: y1 = !x0
		2 => x"2222", -- LUT 2: y2 = x0 & !x1
		others => x"0000" -- JUNK DNA (Hardware mutation engine will fill this with entropy over time)
	);

	--signal conf_out_reg : conf_out_arr_t	:= (others => (others => '0'));
	-- hard-configured for watchdog functionality:
	signal conf_out_reg : conf_out_arr_t := (
		0 => "000011", -- y0 (60s cap) -> points to LUT 0 (Index 3)
		1 => "000100", -- y1 (5s cap)  -> points to LUT 1 (Index 4)
		2 => "000101"  -- y2 (power)   -> points to LUT 2 (Index 5)
	);

	-- shadow configuration registers for reconfiguration from NIOS
	signal shadow_routing_reg	: conf_routing_arr_t := (others => (others => '0'));
	signal shadow_F_reg			: conf_F_arr_t       := (others => (others => '0'));
	signal shadow_out_reg		: conf_out_arr_t     := (others => (others => '0'));


	signal fault_masks_reg		: conf_fault_arr_t		:= (others => (others => '0'));

	signal status_reg			: status_reg_t;
	signal control_reg			: control_reg_t;

	-- address translation: Avalon-MM byte addressing to 32-bit word indexing
	-- (from 4k addressable bytes to 1k addressable words)
	signal word_addr			: integer range 0 to 1023;
	--- delay counter for 30-LUT DAG propagation time (160ns)
	signal wait_counter			: integer range 0 to DAG_EVAL_DELAY - FSM_OVERHEAD_CYCLES := 0;-- 0-5
	--signal reset_timer_3hz		: std_logic;
	signal internal_waitreq		: std_logic;


	-- HARDWARE EVOLUTION SIGNALS
	signal prng_load_seed		: std_logic := '0';
	signal prng_seed_in			: std_logic_vector(63 downto 0) := (others => '0');
	signal prng_rand_out		: std_logic_vector(63 downto 0);

	signal mut_step				: std_logic := '0';
	signal mut_target_gene		: integer range 0 to (TOTAL_GENES - 1);--152
	signal mut_node_idx			: integer range 0 to (NUM_LUTS - 1);--31
	signal mut_in_idx			: integer range 0 to (NUM_LUT_INPUTS - 1);--3
	signal mut_val_F			: std_logic_vector((2**NUM_LUT_INPUTS) - 1 downto 0);--15-0
	signal mut_val_route		: std_logic_vector(OUTPUT_ROUTE_WIDTH - 1 downto 0);--5-0

	-- Child - asynchronic combinations - no registers
	signal child_comb_routing	: conf_routing_arr_t;
	signal child_comb_F			: conf_F_arr_t;
	signal child_comb_out		: conf_out_arr_t;

	-- entry signals to VRC core muxed from child(combinations) or parent(conf registers)
	signal vrc_routing_in		: conf_routing_arr_t;
	signal vrc_F_in				: conf_F_arr_t;
	signal vrc_out_in			: conf_out_arr_t;


	signal parent_fitness		: integer range 0 to MAX_FITNESS := 0;
	signal is_evaluating_child	: std_logic := '0';
	signal is_panicking			: std_logic := '0';

	-- telemetry
	signal gen_counter			: unsigned(31 downto 0) := (others => '0');
	signal last_repair_gens		: unsigned(31 downto 0) := (others => '0');

begin

	UART_det_inst : entity work.UART_detector
		Port map (
			clk				=> clk,
			rst_n			=> rst_n,
			rx_in			=> uart_rx_in,
			pulse_out		=> uart_signal
		);

	core_inst : entity work.core
		Port map (
			x_in			=> core_x_in,
			-- input signals from parent or child (via mux)
			conf_routing_in	=> vrc_routing_in,
			conf_F_in		=> vrc_F_in,
			fault_masks_in	=> fault_masks_reg,
			conf_out_in		=> vrc_out_in,

			y_out			=> core_y_out
		);

	prng_inst : entity work.xorshift64
		Port map (
			clk				=> clk,
			rst_n			=> rst_n,
			enable			=> mut_step or control_reg.prng_step_cmd,
			load_seed		=> prng_load_seed,
			seed_in			=> prng_seed_in,

			rand_out		=> prng_rand_out
		);

	mutation_engine_inst : entity work.mutation_engine
		port map (
			prng_64_in		=> prng_rand_out,

			target_gene_out	=> mut_target_gene,
			node_idx_out	=> mut_node_idx,
			in_idx_out		=> mut_in_idx,
			val_F_out		=> mut_val_F,
			val_route_out	=> mut_val_route
		);


	-- translation from Avalon-MM byte address to 32-bit word address
	word_addr				<= to_integer(unsigned(avs_address(11 downto 2)));

	analog_y_out			<= latched_y;

	status_reg.panic_flag	<= is_panicking;
	status_reg.repair_flag	<= '1' when current_state = ST_REPAIR else '0';
	status_reg.fitness		<= snapshot_fitness;

	internal_waitreq		<= '1' when (current_state = ST_INIT or
										current_state = ST_BACKGROUND_EVAL_SETUP or
										current_state = ST_BACKGROUND_EVAL_WAIT or
										current_state = ST_BACKGROUND_EVAL_READ or
										current_state = ST_BACKGROUND_EVAL_DECISION)
							else '0';

	avs_waitrequest			<= '1' when (internal_waitreq = '1' and avs_read = '1' and word_addr = ADDR_STATUS)
							else '0';

	ins_irq					<= is_panicking;
	panic_flag_out			<= is_panicking;


	-- TMR - combinatorial output
	gen_voter: for i in 0 to 7 generate
		voted_expected_y(i)(0) <= (expected_y_reg_A(i)(0) and expected_y_reg_B(i)(0)) or (expected_y_reg_B(i)(0) and expected_y_reg_C(i)(0)) or (expected_y_reg_A(i)(0) and expected_y_reg_C(i)(0));
		voted_expected_y(i)(1) <= (expected_y_reg_A(i)(1) and expected_y_reg_B(i)(1)) or (expected_y_reg_B(i)(1) and expected_y_reg_C(i)(1)) or (expected_y_reg_A(i)(1) and expected_y_reg_C(i)(1));
		voted_expected_y(i)(2) <= (expected_y_reg_A(i)(2) and expected_y_reg_B(i)(2)) or (expected_y_reg_B(i)(2) and expected_y_reg_C(i)(2)) or (expected_y_reg_A(i)(2) and expected_y_reg_C(i)(2));
	end generate;

	-- choosing signals to VRC from parent or child (mutant)
	vrc_F_in		<= child_comb_F			when (is_evaluating_child = '1') else conf_F_reg;
	vrc_routing_in	<= child_comb_routing	when (is_evaluating_child = '1') else conf_routing_reg;
	vrc_out_in		<= child_comb_out		when (is_evaluating_child = '1') else conf_out_reg;

	-- ASYNCHRONIC CHILD CREATION (mutation of parent)
	process(conf_F_reg, conf_routing_reg, conf_out_reg, mut_target_gene, mut_node_idx, mut_in_idx, mut_val_F, mut_val_route)
	begin
		-- cloning parent
		child_comb_F		<= conf_F_reg;
		child_comb_routing	<= conf_routing_reg;
		child_comb_out		<= conf_out_reg;

--========================================================================
		-- applying mutation
--========================================================================
		-- mutation in function F
		if mut_target_gene < TOTAL_GENES_F then --30
			child_comb_F(mut_target_gene) <= mut_val_F;
		-- mutation in one of LUT inputs
		elsif mut_target_gene < (TOTAL_GENES_F + TOTAL_GENES_ROUTING) then --150
			case mut_in_idx is
				when 0 =>
					child_comb_routing(mut_node_idx)(INTERNAL_ROUTE_WIDTH - 1 downto 0)	<= mut_val_route(INTERNAL_ROUTE_WIDTH - 1 downto 0);--4-0
				when 1 =>
					child_comb_routing(mut_node_idx)((INTERNAL_ROUTE_WIDTH * 2) - 1 downto INTERNAL_ROUTE_WIDTH)	<= mut_val_route(INTERNAL_ROUTE_WIDTH - 1 downto 0);--9-5<=4-0
				when 2 =>
					child_comb_routing(mut_node_idx)((INTERNAL_ROUTE_WIDTH * 3) - 1 downto INTERNAL_ROUTE_WIDTH * 2)	<= mut_val_route(INTERNAL_ROUTE_WIDTH - 1 downto 0);--14-10<=4-0
				when 3 =>
					child_comb_routing(mut_node_idx)((INTERNAL_ROUTE_WIDTH * 4) - 1 downto INTERNAL_ROUTE_WIDTH * 3)	<= mut_val_route(INTERNAL_ROUTE_WIDTH - 1 downto 0);--19-15<=4-0
				when others => null;
			end case;
		-- mutation in one of external outputs
		elsif mut_target_gene < TOTAL_GENES then --153
			if mut_target_gene = TOTAL_GENES_F + TOTAL_GENES_ROUTING then--150
				child_comb_out(0) <= mut_val_route;
			elsif mut_target_gene = TOTAL_GENES_F + TOTAL_GENES_ROUTING + 1 then--151
				child_comb_out(1) <= mut_val_route;
			else
				child_comb_out(2) <= mut_val_route;--152
			end if;
		end if;
	end process;


	-- Avalon-MM write process (from Nios II - commands, fault injection and reconfiguration via shadow registers)
	avalon_write_proc : process(clk, rst_n)
	begin
		if rst_n = '0' then
			control_reg.restart_cmd		<= '0';
			control_reg.prng_step_cmd	<= '0';
			control_reg.load_conf_cmd	<= '0';
			control_reg.evo_disable		<= '0'; -- default mode - hardware evolution is ON
			control_reg.reset_3hz_cmd	<= '0';
			control_reg.load_seed_cmd	<= '0';
			prng_load_seed				<= '0';
		elsif rising_edge(clk) then

			control_reg.restart_cmd		<= '0';
			control_reg.prng_step_cmd	<= '0';
			control_reg.load_conf_cmd	<= '0';
			control_reg.reset_3hz_cmd	<= '0';
			control_reg.load_seed_cmd	<= '0';
			prng_load_seed				<= '0';

			-- handling of Avalon-MM write requests
			if avs_chipselect = '1' and avs_write = '1' then
				case word_addr is
					-- writing configuration from Nios II to shadow registers
					when ADDR_CONF_ROUTING to ADDR_CONF_F - 1 =>
						shadow_routing_reg(word_addr) <= avs_writedata((NUM_LUT_INPUTS * INTERNAL_ROUTE_WIDTH) - 1 downto 0);--19-0

					when ADDR_CONF_F to ADDR_CONF_OUT - 1 =>
						shadow_F_reg(word_addr - ADDR_CONF_F) <= avs_writedata((2**NUM_LUT_INPUTS) - 1 downto 0);--15-0

					when ADDR_CONF_OUT =>
						shadow_out_reg(0) <= avs_writedata(OUTPUT_ROUTE_WIDTH - 1 downto 0);--5-0
						shadow_out_reg(1) <= avs_writedata((OUTPUT_ROUTE_WIDTH * 2) - 1 downto OUTPUT_ROUTE_WIDTH);--11-6
						shadow_out_reg(2) <= avs_writedata((OUTPUT_ROUTE_WIDTH * 3) - 1 downto OUTPUT_ROUTE_WIDTH * 2);--17-12

					when ADDR_CTRL =>
									control_reg <= from_avalon_ctrl(avs_writedata);
									-- loading seed to PRNG
									prng_load_seed <= avs_writedata(5);
					when ADDR_EXPECTED_Y =>
						for i in 0 to 7 loop
							expected_y_reg_A(i) <= avs_writedata((i * 3) + 2 downto (i * 3));
							expected_y_reg_B(i) <= avs_writedata((i * 3) + 2 downto (i * 3));
							expected_y_reg_C(i) <= avs_writedata((i * 3) + 2 downto (i * 3));
						end loop;
					when ADDR_FAULT_BASE to ADDR_FAULT_BASE + NUM_LUTS - 1 =>
						fault_masks_reg(word_addr - ADDR_FAULT_BASE) <= avs_writedata;
					when ADDR_PRNG_SEED_L =>
						-- feeding hardware xorshift64 module with new seed - lower part
						prng_seed_in(31 downto 0) <= avs_writedata;

					when ADDR_PRNG_SEED_H =>
						-- feeding hardware xorshift64 module with new seed - higher part
						prng_seed_in(63 downto 32) <= avs_writedata;
					when others => null;

				end case;
			end if;
		end if;
	end process;

	-- Avalon-MM read process
	avalon_read_proc : process(clk)
	begin
		if rising_edge(clk) then
			avs_readdata <= (others => '0');

			if avs_chipselect = '1' and avs_read = '1' then
				if word_addr = ADDR_STATUS then
					-- reading only evo_disable bit (mode of evolution: software/hardware)
					avs_readdata <= to_avalon_status(status_reg);
				elsif word_addr = ADDR_EXPECTED_Y then
					-- packing TMR output to bits [23:0] of avs_readdata (higher bits initialized as '0')
					for i in 0 to 7 loop
						avs_readdata((i * 3) + 2 downto (i * 3)) <= voted_expected_y(i);
					end loop;
				elsif word_addr = ADDR_PRNG_OUT_L then
					-- reading random 32bit value from hardware xorshift32 module - lower part
					avs_readdata <= prng_rand_out(31 downto 0);
				elsif word_addr = ADDR_PRNG_OUT_H then
					-- reading random 32bit value from hardware xorshift32 module - higher part
					avs_readdata <= prng_rand_out(63 downto 32);
				elsif word_addr >= ADDR_CONF_ROUTING and word_addr < ADDR_CONF_F then
					avs_readdata((NUM_LUT_INPUTS * INTERNAL_ROUTE_WIDTH) - 1 downto 0) <= conf_routing_reg(word_addr);--19-0
				elsif word_addr >= ADDR_CONF_F and word_addr < ADDR_CONF_OUT then
					avs_readdata((2**NUM_LUT_INPUTS) - 1 downto 0) <= conf_F_reg(word_addr - ADDR_CONF_F);--15-0
				elsif word_addr = ADDR_CONF_OUT then
					avs_readdata(OUTPUT_ROUTE_WIDTH - 1 downto 0)	<= conf_out_reg(0);--5-0
					avs_readdata((OUTPUT_ROUTE_WIDTH * 2) - 1 downto OUTPUT_ROUTE_WIDTH)	<= conf_out_reg(1);--11-6
					avs_readdata((OUTPUT_ROUTE_WIDTH * 3) - 1 downto OUTPUT_ROUTE_WIDTH * 2)	<= conf_out_reg(2);--17-12

				-- telemetry
				elsif word_addr = ADDR_LAST_REPAIR_GENS then
					avs_readdata <= std_logic_vector(last_repair_gens);
				elsif word_addr = ADDR_CURRENT_GENS then
					avs_readdata <= std_logic_vector(gen_counter);
				end if;
			end if;
		end if;
	end process;

	-- external inputs synchronization and debouncing process
	analog_sync_proc : process(clk, rst_n)
	begin
		if rst_n = '0' then
			sync_x0 <= "00";
			sync_x1 <= "00";
			cnt_x0  <= 0;
			cnt_x1  <= 0;
			final_x <= "00";

		elsif rising_edge(clk) then
			-- metastability protection (2-stage shift register)
			sync_x0 <= sync_x0(0) & analog_x_in(0);
			sync_x1 <= sync_x1(0) & analog_x_in(1);

			-- debouncer for capacitor transitional states
			if sync_x0(1) = final_x(0) then
				-- signal is stable and matches current output
				cnt_x0	<= 0;
			else
				-- signal differs from current state - start verification:
				if cnt_x0 = DEBOUNCE_CYCLES then
					-- signal stable for 10ms - latch new state
					final_x(0)	<= sync_x0(1);
					cnt_x0		<= 0;
				else
					-- counting 10ms
					cnt_x0	<= cnt_x0 + 1;
				end if;
			end if;

			-- repeated logic for the second capacitor signal
			if sync_x1(1) = final_x(1) then
				cnt_x1	<= 0;
			else
				if cnt_x1 = DEBOUNCE_CYCLES then
					final_x(1)	<= sync_x1(1);
					cnt_x1		<= 0;
				else
					cnt_x1		<= cnt_x1 + 1;
				end if;
			end if;
		end if;
	end process analog_sync_proc;

	-- 3Hz tick generator and flag management process
	timer_3hz_proc : process(clk, rst_n)
	begin
		if rst_n = '0' then
			timer_3hz				<= 0;
			--tick_3hz				<= '0';
			tick_3Hz_pending_flag	<= '0';
			uart_alive_flag			<= '0';
		elsif rising_edge(clk) then
			-- reset in ST_SERVE_ANALOG_LATCH or upon Nios II command
			if control_reg.reset_3hz_cmd = '1' or current_state = ST_SERVE_ANALOG_LATCH then
				timer_3hz				<= 0;
				tick_3Hz_pending_flag	<= '0';
			else

				if timer_3hz = TICKS_3HZ then
					timer_3hz				<= 0;
					tick_3hz_pending_flag	<='1';
				else
					timer_3hz	<= timer_3hz + 1;
				end if;
			end if;

			-- UART heartbeat flag
			if uart_signal = '1' then
				uart_alive_flag	<= '1';
			elsif clear_uart_sig = '1' then
				uart_alive_flag	<= '0';
			end if;
		end if;
	end process timer_3hz_proc;


	-- main FSM process
	main_fsm_proc : process(clk, rst_n)
		-- points scored by current input vector (max 3 per truth table row - 1 for each equation)
		variable match_pts : integer range 0 to 3;
	begin
		if rst_n = '0' then
			current_state		<= ST_INIT;
			core_x_in			<= (others => '0');
			-- y(2)='0' [watched system power kept ON], y(1)='1' [5s cap discharge], y(0)='1' [60s cap discharge]
			latched_y			<= SAFE_OUT;
			eval_vector			<= (others => '0');
			current_fitness		<= 0;
			clear_uart_sig		<= '0';
			snapshot_fitness	<= 0;

			parent_fitness		<= 0;
			is_evaluating_child	<= '0';
			mut_step			<= '0';
			gen_counter			<= (others => '0');
			is_panicking		<= '0';

		elsif rising_edge(clk) then
			clear_uart_sig <= '0';

			if control_reg.restart_cmd = '1' then
				current_state		<= ST_INIT;
				core_x_in			<= (others => '0');
				latched_y			<= SAFE_OUT;
				eval_vector			<= (others => '0');
				current_fitness		<= 0;
				snapshot_fitness	<= 0;
				parent_fitness		<= 0;
				is_evaluating_child	<= '0';
				mut_step			<= '0';
				gen_counter			<= (others => '0');
				is_panicking		<= '0';

			elsif control_reg.load_conf_cmd = '1' then
				conf_routing_reg	<= shadow_routing_reg;
				conf_F_reg			<= shadow_F_reg;
				conf_out_reg		<= shadow_out_reg;

				-- reset of evolution metadata
				current_fitness		<= 0;
				parent_fitness		<= 0;
				snapshot_fitness	<= 0;
				gen_counter			<= (others => '0');

				is_evaluating_child	<= '0';
				eval_vector			<= (others => '0');
				current_state		<= ST_BACKGROUND_EVAL_SETUP;

			else

				case current_state is
					when ST_INIT =>
						current_state <= ST_BACKGROUND_EVAL_SETUP;

					when ST_BACKGROUND_EVAL_SETUP =>
						core_x_in		<= std_logic_vector(eval_vector);
						wait_counter	<= 0;
						mut_step		<= '0';
						current_state	<= ST_BACKGROUND_EVAL_WAIT;

					when ST_BACKGROUND_EVAL_WAIT =>
						-- wait remaining cycles to achive 160ns total delay
						if wait_counter = DAG_EVAL_DELAY - FSM_OVERHEAD_CYCLES then -- 8-3=5
							current_state	<= ST_BACKGROUND_EVAL_READ;
						else
							wait_counter	<= wait_counter + 1;
						end if;

					when ST_BACKGROUND_EVAL_READ =>
						match_pts := 0;
						-- fitness evaluation relies on TMR protected truth table
						if core_y_out(0) = voted_expected_y(to_integer(eval_vector))(0) then match_pts := match_pts + 1; end if;
						if core_y_out(1) = voted_expected_y(to_integer(eval_vector))(1) then match_pts := match_pts + 1; end if;
						if core_y_out(2) = voted_expected_y(to_integer(eval_vector))(2) then match_pts := match_pts + 1; end if;

						current_fitness		<= current_fitness + match_pts;

						if eval_vector = EVAL_COMBINATIONS - 1 then

							current_state	<= ST_BACKGROUND_EVAL_DECISION;
						else
							eval_vector		<= eval_vector + 1;
							current_state	<= ST_BACKGROUND_EVAL_SETUP;
						end if;

					when ST_BACKGROUND_EVAL_DECISION =>
						eval_vector			<= (others => '0');

						if is_evaluating_child = '1' then

							if current_fitness >= parent_fitness then
								-- mutant set as new parent
								conf_F_reg			<= child_comb_F;
								conf_routing_reg	<= child_comb_routing;
								conf_out_reg		<= child_comb_out;
								parent_fitness		<= current_fitness;
								snapshot_fitness	<= current_fitness;
							end if;
							is_evaluating_child		<= '0';
						else

							parent_fitness		<= current_fitness;
							snapshot_fitness	<= current_fitness;
						end if;

						current_state	<= ST_BACKGROUND_EVAL_DONE;

					when ST_BACKGROUND_EVAL_DONE =>
						if snapshot_fitness < MAX_FITNESS then
							-- logic broken
							if tick_3Hz_pending_flag = '1' then
								current_state <= ST_PANIC;
							else
								current_state <= ST_REPAIR;
							end if;
						else
							-- logic correct (system undamaged or healed)
							is_panicking <= '0';
							current_fitness <= 0;

							-- reset repair cost info data system is healed
							if gen_counter > 0 then
								last_repair_gens	<= gen_counter;
								gen_counter			<= (others => '0');
							end if;

							if tick_3Hz_pending_flag = '1' then
								current_state <= ST_SERVE_ANALOG_SETUP;
							else
								current_state <= ST_BACKGROUND_EVAL_SETUP;
							end if;
						end if;

					-- background repair - between 3Hz ticks
					when ST_REPAIR =>
						if control_reg.evo_disable = '0' then
							-- hardware evolution mode
							mut_step			<= '1';
							is_evaluating_child	<= '1';
							gen_counter			<= gen_counter + 1;
						end if;

						current_fitness	<= 0;
						current_state	<= ST_BACKGROUND_EVAL_SETUP;

					-- system deadline missed (333ms window exceeded)
					when ST_PANIC =>
						is_panicking	<= '1'; -- forces hardware interrupt (ins_irq) to Nios II
						current_fitness	<= 0;
						current_state	<= ST_SERVE_ANALOG_SETUP;

					-- normal operation - serving the external RC circuit and watched system
					when ST_SERVE_ANALOG_SETUP =>
						-- x(2)=heartbeat flag from UART_detector, x(1)=5s cap state, x(0)=60s cap state
						core_x_in		<= uart_alive_flag & final_x;
						wait_counter	<= 0;
						current_state	<= ST_SERVE_ANALOG_WAIT;

					when ST_SERVE_ANALOG_WAIT =>
						if wait_counter = DAG_EVAL_DELAY - FSM_OVERHEAD_CYCLES then
							current_state	<= ST_SERVE_ANALOG_LATCH;
						else
							wait_counter	<= wait_counter + 1;
						end if;

					when ST_SERVE_ANALOG_LATCH =>
						if is_panicking = '1' then
							latched_y	<= SAFE_OUT;
						else
							latched_y	<= core_y_out;
						end if;

						clear_uart_sig	<= '1';

						current_state	<= ST_BACKGROUND_EVAL_SETUP;

				end case;
			end if;
		end if;
	end process main_fsm_proc;


	with current_state select
	state_debug <=
		"0000" when ST_INIT,
		"0001" when ST_BACKGROUND_EVAL_SETUP,
		"0010" when ST_BACKGROUND_EVAL_WAIT,
		"0011" when ST_BACKGROUND_EVAL_READ,
		"0100" when ST_BACKGROUND_EVAL_DECISION,
		"0101" when ST_BACKGROUND_EVAL_DONE,
		"0110" when ST_REPAIR,
		"0111" when ST_PANIC,
		"1000" when ST_SERVE_ANALOG_SETUP,
		"1001" when ST_SERVE_ANALOG_WAIT,
		"1010" when ST_SERVE_ANALOG_LATCH,
		"1111" when others;

	-- unused bits tied to zero
	debug_bus(2 downto 0)		<= (others => '0');

	-- currently tested input combination
	debug_bus(5 downto 3)		<= std_logic_vector(eval_vector);

	-- current fitness value
	debug_bus(10 downto 6)		<= std_logic_vector(to_unsigned(current_fitness, 5));

	-- latched capacitor discharge signals (3Hz update rate)
	debug_bus(13 downto 11)		<= latched_y;

	-- synchronized capacitor state signals (50MHz update rate)
	debug_bus(15 downto 14)		<= final_x;

	debug_bus(16)				<= uart_alive_flag;
	debug_bus(17)				<= tick_3Hz_pending_flag;

	debug_bus(18)				<= is_panicking;
	debug_bus(19)				<= '1' when current_state = ST_REPAIR else '0';

	-- FMS state
	debug_bus(DEBUG_BUS_WIDTH - 1 downto 20)	<= state_debug;--23-20 Most Significant Nibble (MSN) for direct HEX readout

end rtl;
