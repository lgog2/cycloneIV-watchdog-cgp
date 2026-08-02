----------------------------------------------------------------------------------
-- file name: UART_detector.vhd
-- DESCRIPTION:
--		Asynchronous RX line activity detector (start bit detector).
--		Monitors the RX line for falling edges and validates them by sampling
--		in the middle of the expected bit duration.
--		NOTE: it may generate multiple pulses during a single UART frame
--		which is not hindering its function as activity indicator.
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity UART_detector is
	Port (
		clk			: in  std_logic; -- 50 MHz
		rst_n		: in  std_logic; -- asynchronous active-low reset
		rx_in		: in  std_logic; -- asynchronous RX line
		pulse_out	: out std_logic  -- detection pulse signal
	);
end UART_detector;

architecture rtl of UART_detector is

	-- Calculations: clock 50 MHz and baud rate 1500000bps (nanopi):
		-- Tc = 1 / 50 Mhz = 20 ns
		-- Tbit = 1 / 1.5 Mbps = 666.67 ns
		-- N = 666.66 / 20 = 33.33 cycles fo bit (half -around 16 cycles)
	 
	constant HALF_BIT_CYCLES : integer := 16;
	 
	-- metastability neutralization and edge detector (3-stage shift register)
	signal rx_sync : std_logic_vector(2 downto 0) := "111";
	 
	type state_type is (IDLE, VALIDATE, REARM);
	signal state : state_type := IDLE;

	signal counter : integer range 0 to HALF_BIT_CYCLES - 1 := 0;

begin

	process(clk, rst_n)
	begin
		if rst_n = '0' then
			rx_sync		<= "111";
			state		<= IDLE;
			counter		<= 0;
			pulse_out	<= '0';
		elsif rising_edge(clk) then

			-- shift register for synchronization
			rx_sync <= rx_sync(1 downto 0) & rx_in;

			-- default output state (detection pulse active for only 1 clock cycle)
			pulse_out <= '0';


			case state is
				when IDLE =>
					-- falling edge detection (from '1' to '0')
					if rx_sync(2) = '1' and rx_sync(1) = '0' then
						state	<= VALIDATE;
						counter	<= 0;
					end if;

				when VALIDATE =>
					if counter = HALF_BIT_CYCLES - 1 then
						-- middle of the bit reached
						if rx_sync(1) = '0' then
							-- stable low state - positive validation
							pulse_out <= '1';
							state       <= REARM;
						else
							-- Line did not hold the low state - glitch/noise
							state       <= IDLE;
						end if;
						counter <= 0;
					else
						counter <= counter + 1;
					end if;

				when REARM =>
					-- blocking further detection until the line returns to high state
					if rx_sync(1) = '1' then
						state <= IDLE;
					end if;

			end case;
		end if;
	end process;

end rtl;
