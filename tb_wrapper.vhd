library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_wrapper is
	-- Testbench nie ma komunikacji z zewnatrz
end tb_wrapper;

architecture behavior of tb_wrapper is

	-- Sygnaly wewnetrzne stymulujace
	signal tb_clk			: std_logic := '0';
	signal tb_rst_n			: std_logic := '0';
	signal tb_analog_x_in	: std_logic_vector(1 downto 0) := "00";
	signal tb_uart_rx_in	: std_logic := '1'; -- Idle UART - 1

	-- Sygnaly obserwacyjne
	signal tb_analog_y_out		: std_logic_vector(2 downto 0);
	signal tb_panic_flag_out	: std_logic;
	signal tb_debug_bus			: std_logic_vector(23 downto 0);

	constant CLK_PERIOD			: time		:= 20 ns;
	constant SIM_TICKS_3HZ		: integer	:= 100;
	constant TICK_3HZ_PERIOD : time := SIM_TICKS_3HZ * CLK_PERIOD;

	alias debug_fsm_state		: std_logic_vector(2 downto 0)	is tb_debug_bus(2 downto 0);
	alias debug_eval_vec		: std_logic_vector(2 downto 0)	is tb_debug_bus(5 downto 3);
	alias debug_fitness			: std_logic_vector(4 downto 0)	is tb_debug_bus(10 downto 6);
	alias debug_latched_y		: std_logic_vector(2 downto 0)	is tb_debug_bus(13 downto 11);
	alias debug_final_x			: std_logic_vector(1 downto 0)	is tb_debug_bus(15 downto 14);
	alias debug_uart_alive		: std_logic						is tb_debug_bus(16);
	alias debug_tick_pending	: std_logic						is tb_debug_bus(17);
	alias debug_PANIC_state		: std_logic						is tb_debug_bus(18);
	alias debug_REPAIR_state	: std_logic						is tb_debug_bus(19);

begin

	-- Instancjacja testowanego ukladu (Device Under Test)
	DUT: entity work.wrapper
		generic map (
			DEBOUNCE_CYCLES	=> 5,				-- skrocenie z 10ms do 100ns w symulacji
			TICKS_3HZ		=> SIM_TICKS_3HZ	--przyspieszenie z 3Hz do 500KHz w symulacji - tick co 2us
		)
		port map (
			clk				=> tb_clk,
			rst_n			=> tb_rst_n,
			analog_x_in		=> tb_analog_x_in,
			uart_rx_in		=> tb_uart_rx_in,
			analog_y_out	=> tb_analog_y_out,
			panic_flag_out	=> tb_panic_flag_out,
			debug_bus		=> tb_debug_bus
		);

	-- GENEROWANIE ZEGARA

	clk_process: process
	begin
		tb_clk <= '0';
		wait for CLK_PERIOD / 2;
		tb_clk <= '1';
		wait for CLK_PERIOD / 2;
	end process;


	-- WSTRZYKIWANIE BODŹCOW

	stim_process: process
	begin
		-- reset
		tb_rst_n <= '0';
		wait for 100 ns;

		tb_rst_n <= '1';

		--czas na przetestowanie 8 wektorow - (2 takty na kazda kombinacje - min 16taktow)
		wait for 20 * CLK_PERIOD; --400 ns

		-- Kondensator k5s
		tb_analog_x_in(1) <= '1';
		wait for 200 ns;

		tb_analog_x_in(0) <= '1';

		wait for 100 ns;

		tb_analog_x_in(1) <= '0';

		-- sygnal UART -
		-- Start bit musi trwac > 320 ns, aby 'UART_detector' uznal go za wazny.
		tb_uart_rx_in <= '0';
		wait for 700 ns;
		tb_uart_rx_in <= '1';

		-- zeby zaobserwowac tick 3Hz pending flag
		wait for TICK_3HZ_PERIOD;

		tb_analog_x_in(0) <= '0';

		wait;
	end process;

end behavior;
