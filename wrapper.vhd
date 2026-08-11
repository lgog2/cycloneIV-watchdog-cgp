----------------------------------------------------------------------------------
-- file name: wrapper.vhd
-- DESCRIPTION:
--		Synchronous FSM controller.
--		Operates at 50MHz, serving as the synchronization boundary
--		between the asynchronous reconfigurable VRC core, the external 3Hz RC circuit,
--		the watched system, and the Nios II processor (via Avalon-MM).
--		Manages hardware fitness evaluation and provides interface for
--		(TODO)hardware fault injection.
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

		MAX_FITNESS 		: integer := 24;
		-- evaluator delay required for signal propagation through the DAG
		DAG_EVAL_DELAY		: integer := 7
	);

	Port (
		clk					: in  std_logic;                    -- 50 MHz clock (t = 20ns)
		rst_n				: in  std_logic;                    -- asynchronous active-low reset

		--- external interface:
			-- analog_x_in[0] 		: 60s capacitor state
			-- analog_x_in[1] 		: 5s capacitor state
			-- uart_rx				: heartbeat signal from watched system
			-- analog_y_out[0] 		: 60s capacitor discharge signal
			-- analog_y_out[1] 		: 5s capacitor discharge signal
			-- analog_y_out[2] 		: watched system power cutoff signal

		analog_x_in			: in  std_logic_vector(1 downto 0);
		uart_rx_in			: in std_logic;
		analog_y_out		: out std_logic_vector(2 downto 0);


		-- AVALON-MM Slave Interface (for NIOS II)
		-- Address Map (0 - 63):
			--0-29 conf_routing_arr_t
			--30-59 conf_F_arr_t
			--60 conf_out_arr_t
			--61 register for commands from NIOS
			--62 status register for feedback to NIOS
			--63 reserved
		avs_address			: in  std_logic_vector(11 downto 0);--byte addressing from NIOS (4kb address space)
		avs_chipselect		: in  std_logic;
		avs_read			: in  std_logic;
		avs_readdata		: out std_logic_vector(31 downto 0);
		avs_write			: in  std_logic;
		avs_writedata		: in  std_logic_vector(31 downto 0);
		avs_waitrequest		: out std_logic; --freezes NIOS during Avalon-MM read/write
		ins_irq				: out std_logic; --Interrupt request to NIOS


		-- TODO
		-- faults injection

		-- diagnostics
		panic_flag_out			: out std_logic ; -- watchdog functionality disabled
		debug_bus				: out std_logic_vector(DEBUG_BUS_WIDTH - 1 downto 0)--23-0
	);
end wrapper;

architecture rtl of wrapper is

	constant EVAL_COMBINATIONS	: integer := 2 ** NUM_EXT_INPUTS;--8

	-- y(2)='0' [watched system power kept ON], y(1)='1' [5s cap discharge], y(0)='1' [60s cap discharge]
	constant SAFE_OUT			: std_logic_vector(2 downto 0) := "011";

	--Base evaluation latency from the FSM pipeline
	constant FSM_OVERHEAD_CYCLES : integer := 3;

	constant ADDR_CONF_ROUTING	: integer := 0;
	constant ADDR_CONF_F		: integer := NUM_LUTS;--30
	constant ADDR_CONF_OUT		: integer := NUM_LUTS * 2;--60
	constant ADDR_CMD			: integer := (NUM_LUTS * 2) + 1;--61
	constant ADDR_STATUS		: integer := (NUM_LUTS * 2) + 2;--62


	type status_reg_t is record
		panic_flag	: std_logic;
		repair_flag	: std_logic;
		fitness		: integer range 0 to MAX_FITNESS; --5 bits
	end record;

	type command_reg_t is record
		restart_cmd	: std_logic;
		-- reserved for future Nios II commands
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

	function from_avalon_cmd(v : std_logic_vector(31 downto 0)) return command_reg_t is
		variable c : command_reg_t;
	begin
		c.restart_cmd := v(0);

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
		ST_SERVE_ANALOG_SETUP,
		ST_SERVE_ANALOG_WAIT,
		ST_SERVE_ANALOG_LATCH,
		ST_PANIC
	);

	signal current_state : state_t;

	signal state_debug : std_logic_vector(3 downto 0);

	-- metastability synchronizers
	signal sync_x0 : std_logic_vector(1 downto 0) := "00";
	signal sync_x1 : std_logic_vector(1 downto 0) := "00";
	signal final_x : std_logic_vector(1 downto 0);

	-- 10ms debouncer counters for 50MHz capacitor state sampling
	signal cnt_x0 : integer range 0 to DEBOUNCE_CYCLES := 0;
	signal cnt_x1 : integer range 0 to DEBOUNCE_CYCLES := 0;

	-- core interface
	signal core_x_in					: std_logic_vector(2 downto 0);
	signal core_y_out					: std_logic_vector(2 downto 0);
	signal latched_y 					: std_logic_vector(2 downto 0);

	-- evaluation interface
	signal eval_vector 				: unsigned(2 downto 0) := (others => '0'); -- inputs combination
	signal current_fitness			: integer range 0 to MAX_FITNESS := 0; -- forces 5-bit register synthesis

	-- snapshot register for status_reg
	signal snapshot_fitness			: integer range 0 to MAX_FITNESS := 0;

	-- expected truth table outputs for fitness evaluation (detailed in 'core.vhd')
	type truth_table_t is array (0 to 7) of std_logic_vector(2 downto 0);
	constant EXPECTED_Y : truth_table_t := (
		"010", "100", "011", "001", "011", "100", "011", "001"
	);

	-- 3Hz tick generator from 50MHz clock (ZOH sampling trigger)
	signal timer_3hz   : integer range 0 to TICKS_3HZ := 0;
	signal tick_3hz    : std_logic;

	-- control signals and flags
	signal tick_3Hz_pending_flag	: std_logic := '0';
	signal uart_alive_flag			: std_logic := '0';
	signal uart_signal				: std_logic;
	signal clear_uart_sig			: std_logic;

	-- AVALON-MM REGISTERS
	signal conf_routing_reg		: conf_routing_arr_t := (others => (others => '0'));
	signal conf_F_reg			: conf_F_arr_t		 := (others => (others => '0'));
	signal conf_out_reg			: conf_out_arr_t	 := (others => (others => '0'));

	signal status_reg 			: status_reg_t;
	signal command_reg 			: command_reg_t;

	-- address translation: Avalon-MM byte addressing to 32-bit word indexing
	-- (from 4k addressable bytes to 1k addressable words)
	signal word_addr			: integer range 0 to 1023; --above 62 - reserve for future system expansion

	--- delay counter for 30-LUT DAG propagation time (140ns)
	signal wait_counter 		: integer range 0 to DAG_EVAL_DELAY - FSM_OVERHEAD_CYCLES := 0;

	signal reset_timer_3hz : std_logic;

begin

	UART_det_int : entity work.UART_detector
		Port map (
			clk			=> clk,
			rst_n		=> rst_n,
			rx_in		=> uart_rx_in,
			pulse_out	=> uart_signal
		);

	core_inst : entity work.core
		Port map (
			x_in			=> core_x_in,
			y_out			=> core_y_out,

			conf_routing_in	=> conf_routing_reg,
			conf_F_in		=> conf_F_reg,
			conf_out_in		=> conf_out_reg
		);

	-- translation from Avalon-MM byte address to 32-bit word address
	word_addr <= to_integer(unsigned(avs_address(11 downto 2)));

	analog_y_out 			<= latched_y;

	status_reg.panic_flag	<= '1' when current_state = ST_PANIC else '0';
	status_reg.repair_flag	<= '1' when current_state = ST_REPAIR else '0';
	status_reg.fitness		<= snapshot_fitness;

	avs_waitrequest			<= '1' when (current_state = ST_BACKGROUND_EVAL_SETUP or
										current_state = ST_BACKGROUND_EVAL_WAIT or
										current_state = ST_BACKGROUND_EVAL_READ or
										current_state = ST_BACKGROUND_EVAL_DECISION)
							else '0';

	ins_irq					<= '1' when (current_state = ST_REPAIR or
										current_state = ST_PANIC)
							else '0';

	reset_timer_3hz 		<= '1' when (current_state = ST_INIT or
										current_state = ST_SERVE_ANALOG_LATCH)
							else '0';

	panic_flag_out			<= status_reg.panic_flag;

	-- Avalon-MM write process (from Nios II)
	avalon_write_proc : process(clk, rst_n)
	begin

		if rst_n = '0' then
			command_reg.restart_cmd <= '0';
		elsif rising_edge(clk) then

			command_reg.restart_cmd <= '0';

			-- handling of Avalon-MM write requests
			if avs_chipselect = '1' and avs_write = '1' then
				case word_addr is
					when ADDR_CONF_ROUTING to ADDR_CONF_F - 1 =>
						conf_routing_reg(word_addr) <= avs_writedata(19 downto 0);
					when ADDR_CONF_F to ADDR_CONF_OUT - 1 =>
						conf_F_reg(word_addr - ADDR_CONF_F)  <= avs_writedata(15 downto 0);
					when ADDR_CONF_OUT =>
						conf_out_reg(0) <= avs_writedata(5 downto 0);
						conf_out_reg(1) <= avs_writedata(11 downto 6);
						conf_out_reg(2) <= avs_writedata(17 downto 12);
					when ADDR_CMD =>
						command_reg <= from_avalon_cmd(avs_writedata);
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
					avs_readdata <= to_avalon_status(status_reg);
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
				cnt_x0 <= 0;
			else
				-- signal differs from current state - start verification:
				if cnt_x0 = DEBOUNCE_CYCLES then
					-- signal stable for 10ms - latch new state
					final_x(0)	<= sync_x0(1);
					cnt_x0		<= 0;
				else
					-- counting 10ms
					cnt_x0 <= cnt_x0 + 1;
				end if;
			end if;

			-- repeated logic for the second capacitor signal
			if sync_x1(1) = final_x(1) then
				cnt_x1 <= 0;
			else
				if cnt_x1 = DEBOUNCE_CYCLES then
					final_x(1)	<= sync_x1(1);
					cnt_x1    	<= 0;
				else
					cnt_x1 <= cnt_x1 + 1;
				end if;
			end if;

		end if;
	end process analog_sync_proc;


	-- 3Hz tick generator and flag management process
	timer_3hz_proc : process(clk, rst_n)
	begin
		if rst_n = '0' then
			timer_3hz				<= 0;
			tick_3hz 				<= '0';
			tick_3Hz_pending_flag	<= '0';
			uart_alive_flag			<= '0';
		elsif rising_edge(clk) then
			-- reset in ST_INIT or upon Nios II restart command
			if reset_timer_3hz = '1' then
				timer_3hz			<= 0;
				tick_3hz			<= '0';
			-- 3Hz generator
			elsif timer_3hz = TICKS_3HZ then
				timer_3hz			<= 0;
				tick_3hz			<= '1';
			else
				timer_3hz			<= timer_3hz + 1;
				tick_3hz			<= '0';
			end if;

			-- tick_3Hz_pending_flag
			if tick_3hz	= '1' then
				tick_3Hz_pending_flag <= '1';
			elsif current_state = ST_SERVE_ANALOG_LATCH then
				tick_3Hz_pending_flag <= '0';
			end if;

			-- UART heartbeat flag
			if uart_signal = '1' then
				uart_alive_flag <= '1';
			elsif clear_uart_sig = '1' then
				uart_alive_flag <= '0';
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
		elsif rising_edge(clk) then
			clear_uart_sig	<= '0';

			case current_state is
				when ST_INIT =>
					current_state <= ST_BACKGROUND_EVAL_SETUP;

				when ST_BACKGROUND_EVAL_SETUP =>

					core_x_in		<= std_logic_vector(eval_vector);
					wait_counter	<= 0;
					current_state	<= ST_BACKGROUND_EVAL_WAIT;-- 1 clock cycle latency

				when ST_BACKGROUND_EVAL_WAIT =>
					-- wait remaining cycles to achive 140ns total delay
					if wait_counter = DAG_EVAL_DELAY - FSM_OVERHEAD_CYCLES then -- 7-3=4
						current_state <= ST_BACKGROUND_EVAL_READ;
					else
						wait_counter <= wait_counter + 1;
					end if;

				when ST_BACKGROUND_EVAL_READ =>
					match_pts := 0;
					if core_y_out(0) = EXPECTED_Y(to_integer(eval_vector))(0) then match_pts := match_pts + 1; end if;
					if core_y_out(1) = EXPECTED_Y(to_integer(eval_vector))(1) then match_pts := match_pts + 1; end if;
					if core_y_out(2) = EXPECTED_Y(to_integer(eval_vector))(2) then match_pts := match_pts + 1; end if;

					current_fitness <= current_fitness + match_pts;

					if eval_vector = EVAL_COMBINATIONS - 1 then

						current_state <= ST_BACKGROUND_EVAL_DECISION;
					else
						eval_vector   <= eval_vector + 1;
						current_state <= ST_BACKGROUND_EVAL_SETUP;
					end if;

				when ST_BACKGROUND_EVAL_DECISION =>
					eval_vector			<= (others => '0');

					-- snapshot to status register
					snapshot_fitness	<= current_fitness;

					current_state		<= ST_BACKGROUND_EVAL_DONE;

				when ST_BACKGROUND_EVAL_DONE =>
					if snapshot_fitness	< MAX_FITNESS then
						current_state	<= ST_REPAIR;
					elsif tick_3Hz_pending_flag = '1' then -- max fitness(24) and tick_pending
						current_fitness	<= 0;
						current_state	<= ST_SERVE_ANALOG_SETUP;
					else -- max fitness(24) and !tick_pending
						current_fitness	<= 0;
						current_state	<= ST_BACKGROUND_EVAL_SETUP;
					end if;

				-- background repair - between 3Hz ticks
				when ST_REPAIR =>

					-- FSM waits for Nios II restart command

					if tick_3Hz_pending_flag = '1' then
						current_state 		<= ST_PANIC; -- time budget between 3Hz ticks exceeded
					elsif command_reg.restart_cmd = '1' then
						current_fitness		<= 0;
						current_state 		<= ST_BACKGROUND_EVAL_SETUP; -- loop back to evaluation
					end if;

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
					latched_y		<= core_y_out;
					clear_uart_sig	<= '1';
					current_state	<= ST_BACKGROUND_EVAL_SETUP;

				-- time budget between 3Hz ticks exceeded - suspend normal operation (and evolve until repaired)
				when ST_PANIC =>
					-- y(2)='0' [watched system power kept ON], y(1)='1' [5s cap discharge], y(0)='1' [60s cap discharge]
					latched_y <= SAFE_OUT;

					if command_reg.restart_cmd = '1' then
						current_fitness		<= 0;
						current_state		<= ST_BACKGROUND_EVAL_SETUP;
					end if;

			end case;

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
		"0111" when ST_SERVE_ANALOG_SETUP,
		"1000" when ST_SERVE_ANALOG_WAIT,
		"1001" when ST_SERVE_ANALOG_LATCH,
		"1010" when ST_PANIC,
		"1111" when others;

	-- unused bits tied to zero
	debug_bus(2 downto 0)	<= (others => '0');

	-- currently tested input combination
	debug_bus(5 downto 3)	<= std_logic_vector(eval_vector);

	-- current fitness value
	debug_bus(10 downto 6)	<= std_logic_vector(to_unsigned(current_fitness, 5));

	-- latched capacitor discharge signals (3Hz update rate)
	debug_bus(13 downto 11)	<= latched_y;

	-- synchronized capacitor state signals (50MHz update rate)
	debug_bus(15 downto 14)	<= final_x;

	-- flags
	debug_bus(16)			<= uart_alive_flag;
	debug_bus(17)			<= tick_3Hz_pending_flag;

	-- specific state flags
	debug_bus(18)			<= '1' when current_state = ST_PANIC else '0';
	debug_bus(19)			<= '1' when current_state = ST_REPAIR else '0';


	-- FMS state
	debug_bus(DEBUG_BUS_WIDTH - 1 downto 20) <= state_debug;--23-20 Most Significant Nibble (MSN) for direct HEX readout

end rtl;
