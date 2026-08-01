library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- ==============================================================================
-- UWAGA ARCHITEKTONICZNA:
-- Modul wykrywa spadek napięcia na linii RX UART (kazdy bit startu)
-- ale dodatkowo w trakcie jednej ramki UART wygenerowac dodakowe impulsy
-- co nie przeszkadza w jego funkcjonalnosci jako detektora 'sygnalu zycia'
-- ==============================================================================

entity UART_detector is
	Port (
		clk			: in  std_logic; -- 50 MHz
		rst_n		: in  std_logic; -- reset asynchroniczny, aktywny stanem niskim
		rx_in		: in  std_logic; -- asynchroniczna linia RX
		pulse_out	: out std_logic  -- sygnal wykrycia
	);
end UART_detector;

architecture rtl of UART_detector is

	-- Obliczenia zegar 50 MHz i baud rate 1500000bps (nanopi):
		-- Tc = 1 / 50 Mhz = 20 ns
		-- Tbit = 1 / 1.5 Mbps = 666.67 ns
		-- N = 666.66 / 20 = 33.33 cykle zegara na bit (polowa to ok 16 cykli)
	 
	constant HALF_BIT_CYCLES : integer := 16;
	 
	 -- neutralizacja metastabilności i detekcja
	signal rx_sync : std_logic_vector(2 downto 0) := "111";
	 
	type state_type is (IDLE, VALIDATE, REARM);
    
	signal state : state_type := IDLE;

	-- licznik do 15 (wymaga 4 bitow)
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

			-- rejestr przesuwny
			rx_sync <= rx_sync(1 downto 0) & rx_in;

			-- domyslny stan wyjscia (sygnal wykrycia aktywny tylko przez 1 takt)
			pulse_out <= '0';

			case state is
				when IDLE =>
					-- Wykrycie zbocza opadającego (z '1' na '0')
					if rx_sync(2) = '1' and rx_sync(1) = '0' then
						state	<= VALIDATE;
						counter	<= 0;
					end if;

				when VALIDATE =>
					if counter = HALF_BIT_CYCLES - 1 then
						-- zliczono 16 cykli - polowa bitu
						if rx_sync(1) = '0' then
							-- stabilny stan niski - weryfikacja pozytywna
							pulse_out <= '1';
							state       <= REARM;
						else
							-- linia nie utrzymala stanu niskiego - weryfikacja negatywna
							state       <= IDLE;
						end if;
						counter <= 0;
					else
						counter <= counter + 1;
					end if;

				when REARM =>
					-- blokada az do wykrycia znowu stanu wysokiego
					if rx_sync(1) = '1' then
						state <= IDLE;
					end if;

			end case;
		end if;
	end process;

end rtl;
