library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity de2_115_top is
	Port (
		CLOCK		: in  std_logic; -- 50MHz
		KEY			: in  std_logic_vector(3 downto 0); -- Przyciski (Active-Low)

		-- JP5 (36 pinow) - diagnostyka
		GPIO		: out std_logic_vector(23 downto 0);

		-- praca (RC + UART)
		EX_I		: in std_logic_vector(2 downto 0);
		EX_O		: out std_logic_vector(2 downto 0);

		-- Diody LED
		LEDR		: out std_logic_vector(17 downto 0); -- Czerwone
		LEDG		: out std_logic_vector(8 downto 0)   -- Zielone
	);
end de2_115_top;

architecture Structural of de2_115_top is

	component wrapper is
		Port (
			clk						: in  std_logic;
			rst_n					: in  std_logic;
			analog_x_in				: in  std_logic_vector(1 downto 0);
			uart_rx_in				: in  std_logic;
			analog_y_out			: out std_logic_vector(2 downto 0);
			panic_flag_out			: out std_logic;
			debug_bus				: out std_logic_vector(23 downto 0)
		);
	end component;

	-- diagnostyka
	signal internal_bus 			: std_logic_vector(23 downto 0);
	signal hardware_panic			: std_logic;

	-- sygnaly posredniczace dla izolacji inout
	signal internal_analog_x_in		: std_logic_vector(1 downto 0);
	signal internal_analog_y_out	: std_logic_vector(2 downto 0);
	signal internal_uart_rx_in		: std_logic;

	-- reset
	signal clean_rst_n				: std_logic := '0';
	signal key0_sync				: std_logic_vector(1 downto 0) := "11";

	-- liczniki dla przycisku reset oraz dla sygnalizacji dioda tick_3Hz (50ms przy 50MHz)
	constant TIME_50MS				: integer := 2500000;
	signal rst_counter				: integer range 0 to TIME_50MS := 0;

	signal led_50ms_cnt						: integer range 0 to TIME_50MS := 0;
	signal tick_3Hz_pending_flag_visible	: std_logic := '0';


begin

	inst_cgp_core : wrapper
	port map (
		clk					=> CLOCK,
		rst_n				=> clean_rst_n,
		analog_x_in			=> internal_analog_x_in,
		analog_y_out		=> internal_analog_y_out,
		uart_rx_in			=> internal_uart_rx_in,
		panic_flag_out		=> hardware_panic,
		debug_bus			=> internal_bus
	);

	process(CLOCK)
	begin
		if rising_edge(CLOCK) then
			--KEY(0) - reset - eliminacja metastabilnosci
			key0_sync <= key0_sync(0) & KEY(0);

			-- przedluzanie reset do 5oms i rozpoczynanie pracy odreset
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


	led_stretcher_proc : process(CLOCK)
	begin
		if rising_edge(CLOCK) then
			if clean_rst_n = '0' then
				led_50ms_cnt <= 0;
				tick_3Hz_pending_flag_visible  <= '0';
			else

				if internal_bus(17) = '1' then
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


	-- Lewa strona: EX_IO (7 pinow) - praca (RC + UART)
	-- Pobieranie wejsc
	internal_analog_x_in(0) <= EX_I(0);
	internal_analog_x_in(1) <= EX_I(1);
	internal_uart_rx_in     <= EX_I(2);

	-- wystawienie wyjsc
	EX_O(2 downto 0)		<= internal_analog_y_out;

	-- JP5 (36 pinow) - diagnostyka
	GPIO(23 downto 0)		<= internal_bus;

	-- diagnostyka diodami:
	-- czerwone
	LEDR(17) <= tick_3Hz_pending_flag_visible;
	LEDR(16) <= internal_bus(16); -- uart_alive_flag
	LEDR(15) <= hardware_panic;

	LEDR(14 downto 0)   <= (others => '0');

	-- Zielone
	 LEDG(8)   <= internal_bus(14); -- x0 (stan k60)
	 LEDG(7)   <= '0';
	 LEDG(6)   <= internal_bus(15);  --x1 (stan k5)
	 LEDG(5)   <= '0';
	 LEDG(4)   <= internal_bus(11);  --y0 (rozladowanie k60)
	 LEDG(3)   <= '0';
	 LEDG(2)   <= internal_bus(12);  --y1 (rozladowanie k5)
	 LEDG(1)   <= '0';
	 LEDG(0)   <= internal_bus(13);  --y2 (odciecie)

end Structural;
