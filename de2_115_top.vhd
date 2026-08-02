----------------------------------------------------------------------------------
-- file name: de2_115_top.vhd
-- DESCRIPTION:
--		Top-level entity for the Altera DE2-115 development board.
--		Instantiates the Nios II Qsys system (CGP Watchdog) and routes
--		signals for normal Watchdog operation.
--		Implements a 50ms Power-On/Button Reset stretcher and LED strechers
--		for debug signals and 24-bit wide debug bus.
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity de2_115_top is
	Port (
		CLOCK		: in  std_logic; -- 50MHz
		KEY			: in  std_logic_vector(3 downto 0); -- pushbuttons (Active-Low) - only one used

		-- JP5 (24 pins) - diagnostics
		GPIO		: out std_logic_vector(23 downto 0);

		-- external operation interface (RC & watched system)
		-- EX_I(0) : 60s capacitor state input
		-- EX_I(1) : 5s capacitor state input
		-- EX_I(2) : UART heartbeat RX from watched system
		EX_I		: in std_logic_vector(2 downto 0);
		-- EX_O(0) : 60s capacitor discharge signal
		-- EX_O(1) : 5s capacitor discharge signal
		-- EX_O(2) : Watched system power cutoff signal
		EX_O		: out std_logic_vector(2 downto 0);

		-- Status LEDs
		LEDR		: out std_logic_vector(17 downto 0); -- Red LEDs
		LEDG		: out std_logic_vector(8 downto 0)   -- Green LEDs
	);
end de2_115_top;

architecture Structural of de2_115_top is

	component cgp_watchdog_nios is
		port (
			clk_clk				: in  std_logic;
			reset_reset_n		: in  std_logic;

			cgpw_analog_x_in	: in  std_logic_vector(1 downto 0);
			cgpw_analog_y_out	: out std_logic_vector(2 downto 0);
			cgpw_panic_flag_out	: out std_logic;
			cgpw_debug_bus		: out std_logic_vector(23 downto 0);
			cgpw_uart_rx_in		: in  std_logic

		);
	end component;

	-- diagnostics
	signal debug_bus						: std_logic_vector(23 downto 0);
	signal hardware_panic					: std_logic;

	-- intermediary signals for top-level IO
	signal internal_analog_x_in				: std_logic_vector(1 downto 0);
	signal internal_analog_y_out			: std_logic_vector(2 downto 0);
	signal internal_uart_rx_in				: std_logic;

	-- reset signal and shift register for reset signal synchronisation
	signal clean_rst_n						: std_logic := '0';
	signal key0_sync						: std_logic_vector(1 downto 0) := "11";

	-- counters for reset stretch and 3Hz tick LED strecher (50ms at 50MHz)
	constant TIME_50MS						: integer := 2500000;
	signal rst_counter						: integer range 0 to TIME_50MS := 0;

	signal led_50ms_cnt						: integer range 0 to TIME_50MS := 0;
	signal tick_3Hz_pending_flag_visible	: std_logic := '0';


begin

	inst_nios : cgp_watchdog_nios
	port map (
		clk_clk						=> CLOCK,
		reset_reset_n				=> clean_rst_n,

		cgpw_analog_x_in			=> internal_analog_x_in,
		cgpw_uart_rx_in				=> internal_uart_rx_in,
		cgpw_analog_y_out			=> internal_analog_y_out,
		cgpw_panic_flag_out			=> hardware_panic,
		cgpw_debug_bus				=> debug_bus
	);

	process(CLOCK)
	begin
		if rising_edge(CLOCK) then
			--KEY(0) - reset - metastability elimination
			key0_sync <= key0_sync(0) & KEY(0);

			-- stretching reset to 50ms and ensuring reset on power-on
			if key0_sync(1) = '0' then
				rst_counter <= 0;
				clean_rst_n <= '0';
			elsif rst_counter < TIME_50MS then
				rst_counter <= rst_counter + 1;
				clean_rst_n <= '0';
			else
				clean_rst_n <= '1';
			end if;
		end if;
	end process;

	-- signal stretcher for LED visibility
	led_stretcher_proc : process(CLOCK)
	begin
		if rising_edge(CLOCK) then
			if clean_rst_n = '0' then
				led_50ms_cnt <= 0;
				tick_3Hz_pending_flag_visible  <= '0';
			else
				-- debug_bus(17) corresponds to tick_3Hz_pending_flag
				if debug_bus(17) = '1' then
					led_50ms_cnt <= TIME_50MS;
					tick_3Hz_pending_flag_visible  <= '1';
				elsif led_50ms_cnt > 0 then
					led_50ms_cnt <= led_50ms_cnt - 1;
					tick_3Hz_pending_flag_visible  <= '1';
				else
					tick_3Hz_pending_flag_visible  <= '0';
				end if;
			end if;
		end if;
	end process led_stretcher_proc;


	-- external IO mapping:
	-- inputs
	internal_analog_x_in(0)	<= EX_I(0);
	internal_analog_x_in(1)	<= EX_I(1);
	internal_uart_rx_in		<= EX_I(2);

	-- outputs
	EX_O(2 downto 0)		<= internal_analog_y_out;

	-- diagnostics outputs
	GPIO(23 downto 0)		<= debug_bus;

	-- red LEDs mapping (System Flags)
	LEDR(17)	<= tick_3Hz_pending_flag_visible;
	LEDR(16)	<= debug_bus(16); -- uart_alive_flag
	LEDR(15)	<= hardware_panic;

	LEDR(14 downto 0)	<= (others => '0');

	-- green LEDs mapping (Capacitor states & discharge control)
	LEDG(8)		<= debug_bus(14); -- final_x(0) (60s cap state)
	LEDG(7)		<= '0';
	LEDG(6)		<= debug_bus(15);  --final_x(1) (5s cap state)
	LEDG(5)		<= '0';
	LEDG(4)		<= debug_bus(11);  --latched_y(0) (60s cap discharge)
	LEDG(3)		<= '0';
	LEDG(2)		<= debug_bus(12);  --latched_y(1) (5s cap discharge)
	LEDG(1)		<= '0';
	LEDG(0)		<= debug_bus(13);  --latched_y(2) (power cutoff)

end Structural;
