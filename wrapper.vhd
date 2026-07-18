library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity wrapper is
	-- stale w formie generic po to zeby mozna bylo je konfigurowac z testbench
	generic (
		-- 50 000 000 / 3 = 16 666 666 (wymaga 24 bitow, max to 16 777 215)
		TICKS_3HZ		: integer := 16666666; -- ~333 ms przy 50MHz
		-- dla debouncera sygnalu w strefie przejsciowej kondensatora
		DEBOUNCE_CYCLES	: integer := 500000;  -- 10 ms przy 50MHz

		MAX_FITNESS 	: integer := 24
	);

	Port (
		clk					: in  std_logic;                    -- zegar 50 MHz (t = 20ns)
		rst_n				: in  std_logic;                    -- asynchroniczny reset aktywowany stanem niskim

		-- interfejs dla ukladu zewnetrznego:
			-- analog_x_in[0] 		: stan k 60s
			-- analog_x_in[1] 		: stan k 5s
			-- uart_rx	: sygnal zycia od nanopi
			-- analog_y_out[0] 		:	sygnal rozladowywyjacy k60
			-- analog_y_out[1] 		:	sygnal rozladowywujacy k5
			-- analog_y_out[2] 		:	sygnal odcinajacy zasilanie nanopi
		analog_x_in				: in  std_logic_vector(1 downto 0);
		uart_rx_in				: in std_logic;
		analog_y_out			: out std_logic_vector(2 downto 0);

		-- TODO interfejs kontrolny (dla procesora NIOS II przez szyne Avalon-MM)
		  --  - wstrzykiwanie awarii
		  --  - rekonfiguracja bramek LUT

		  -- diagnostyka
		panic_flag_out			: out std_logic ; -- obsluga ukladu RC nieaktywna
		debug_bus				: out std_logic_vector(23 downto 0)
	);
end wrapper;

architecture rtl of wrapper is
	component core is
		Port (
			x : in  std_logic_vector(2 downto 0);
			y : out std_logic_vector(2 downto 0)
		);
	end component;
	
	component UART_detector is
		Port (
			clk				: in  std_logic; -- 50 MHz
			rst_n			: in  std_logic; -- reset asynchroniczny, aktywny stanem niskim
			rx_in			: in  std_logic; -- asynchroniczna linia RX
			pulse_out		: out std_logic  -- syganal wykrycia (20 ns)
		);
	end component;
	
	type state_t is (
		ST_INIT, 
		ST_BACKGROUND_EVAL_SETUP,
		ST_BACKGROUND_EVAL_READ,
		ST_BACKGROUND_EVAL_DECISION,
		ST_REPAIR,
		ST_SERVE_ANALOG_SETUP,
		ST_SERVE_ANALOG_LATCH,
		ST_PANIC
	);
	
	signal current_state : state_t;
	
	signal state_debug : std_logic_vector(2 downto 0);
	
	-- dla eliminacji metastabilnosci
	signal sync_x0 : std_logic_vector(1 downto 0) := "00";
	signal sync_x1 : std_logic_vector(1 downto 0) := "00";
	signal final_x: std_logic_vector(1 downto 0);
	
	-- dla debouncera 10ms podczas probkowania stanow kondensatorow z 50MHz
	signal cnt_x0 : integer range 0 to DEBOUNCE_CYCLES := 0;
	signal cnt_x1 : integer range 0 to DEBOUNCE_CYCLES := 0;

	-- do rdzenia
	signal core_x_in					: std_logic_vector(2 downto 0);
	signal core_y_out					: std_logic_vector(2 downto 0);
	signal latched_y 					: std_logic_vector(2 downto 0);

	-- dla ewaluacji
	signal eval_vector 				: unsigned(2 downto 0) := (others => '0'); --kombinacje wejsc

	signal current_fitness			: integer range 0 to MAX_FITNESS := 0; --wymuszenie zastowania rejestru 5bitowego
	
	-- tablica prawidlowych wyjsc dla ewaluacji (rozpisane w komentarzu w 'core.vhd')
	type truth_table_t is array (0 to 7) of std_logic_vector(2 downto 0);
	constant EXPECTED_Y : truth_table_t := (
		"010", "100", "011", "001", "011", "100", "011", "001"
	);

	--dla  generowania sygnalu 3 Hz z sygnalu zegarowego 50 MHz (probkowanie ZOH Zero-Order Hold)
	signal timer_3hz   : integer range 0 to TICKS_3HZ := 0;
	signal tick_3hz    : std_logic;

	-- sygnaly sterujace i flagi
	signal tick_3Hz_pending_flag	: std_logic := '0';
	signal uart_alive_flag			: std_logic := '0';
	signal uart_signal				: std_logic;
	signal clear_uart_sig			: std_logic;

begin

	UART_det_int : UART_detector
		Port map (
			clk   => clk,
			rst_n  => rst_n,
			rx_in   => uart_rx_in,
			pulse_out => uart_signal
		);

	core_inst : core
		Port map (
			x => core_x_in,
			y => core_y_out
		);
		
	--	proces synchronizacji wejsc analogowych
	analog_sync_proc : process(clk, rst_n)
	begin
		if rst_n = '0' then
			sync_x0 <= "00";
			sync_x1 <= "00";
			cnt_x0  <= 0;
			cnt_x1  <= 0;
			final_x <= "00";

		elsif rising_edge(clk) then
			-- ochrona przed metastabilnosci
			sync_x0 <= sync_x0(0) & analog_x_in(0);
			sync_x1 <= sync_x1(0) & analog_x_in(1);

			-- debouncer do stabilizacji sygnalu z kondensatora w strefie przejsciowej
			if sync_x0(1) = final_x(0) then
				-- sygnal jest stabilny i zgodny z obecnym stanem wyjscia
				cnt_x0 <= 0;
			else
				-- jezeli sygnal rozni sie od obecnego stanu - weryfikacja :
				if cnt_x0 = DEBOUNCE_CYCLES then
					-- sygnal byl stabilny przez 10ms - weryfikacja pozytywna
					final_x(0) <= sync_x0(1);
					cnt_x0     <= 0;
				else
					-- odliczanie 10 ms
					cnt_x0 <= cnt_x0 + 1;
				end if;
			end if;

			-- to samo co poprzednio dla synalu z drugiego kondensatora
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
	
		
	--	proces generowania sygnalu 3Hz i ustawiania flag
	timer_3hz_proc : process(clk, rst_n)
	begin
		if rst_n = '0' then
			timer_3hz				<= 0;
			tick_3hz 				<= '0';
			tick_3Hz_pending_flag	<= '0';
			uart_alive_flag			<= '0';
		elsif rising_edge(clk) then
			-- Generator 3 Hz
			if timer_3hz = TICKS_3HZ then
				--timer_3hz        <= (others => '0');
				timer_3hz			<= 0;
				tick_3hz			<= '1';
			else
				timer_3hz			<= timer_3hz + 1;
				tick_3hz			<= '0';
			end if;

			-- ustawienie flagi zadania obslugi sygnalu 3 Hz
			if tick_3hz	= '1' then
				tick_3Hz_pending_flag <= '1';
			elsif current_state = ST_SERVE_ANALOG_LATCH then
				tick_3Hz_pending_flag <= '0';
			end if;

			-- ustawienie flagi zycia UART
			if uart_signal = '1' then
				uart_alive_flag <= '1';
			elsif clear_uart_sig = '1' then
				uart_alive_flag <= '0';
			end if;
		end if;
	
	
	end process timer_3hz_proc;
		
	
	
	--	proces automatu  skonczonego (maszyna stanow)
	main_fsm_proc : process(clk, rst_n)
		-- ile punktow zdobyla dana kombinacja wejsc podczas ewaluacji ( 1 dla kazdego z 3 rownan wzorcowych)
		variable match_pts : integer range 0 to 3; 
	begin
		if rst_n = '0' then
			current_state	<= ST_INIT;
			core_x_in		<= (others => '0');
			-- y(2)='0' [zasilanie NanoPi nieodcianane], y(1)='1' [K5s rozladowanie], y(0)='1' [K60s rozladowanie]
			latched_y		<= "011";
			eval_vector		<= (others => '0'); -- kombinacja wejsc do ewaluacji
			current_fitness	<= 0;
			clear_uart_sig	<= '0';
			panic_flag_out	<= '0';
		elsif rising_edge(clk) then
			clear_uart_sig	<= '0';

			case current_state is
				when ST_INIT =>
					current_state <= ST_BACKGROUND_EVAL_SETUP;

				when ST_BACKGROUND_EVAL_SETUP =>
					core_x_in     <= std_logic_vector(eval_vector);
					current_state <= ST_BACKGROUND_EVAL_READ;
					  
				when ST_BACKGROUND_EVAL_READ =>
					match_pts := 0;
					if core_y_out(0) = EXPECTED_Y(to_integer(eval_vector))(0) then match_pts := match_pts + 1; end if;
					if core_y_out(1) = EXPECTED_Y(to_integer(eval_vector))(1) then match_pts := match_pts + 1; end if;
					if core_y_out(2) = EXPECTED_Y(to_integer(eval_vector))(2) then match_pts := match_pts + 1; end if;

					current_fitness <= current_fitness + match_pts;

					if eval_vector = 7 then
						current_state <= ST_BACKGROUND_EVAL_DECISION;
					else
						eval_vector   <= eval_vector + 1;
						current_state <= ST_BACKGROUND_EVAL_SETUP;
					end if;

				when ST_BACKGROUND_EVAL_DECISION =>
					eval_vector <= (others => '0');

					if current_fitness	< 24 then
						current_state	<= ST_REPAIR;
					elsif tick_3Hz_pending_flag = '1' then -- max fitness(24) and tick_pending
						current_state	<= ST_SERVE_ANALOG_SETUP;
						current_fitness	<= 0;
					else -- max fitness(24) and !tick_pending
						current_fitness	<= 0;
						current_state	<= ST_BACKGROUND_EVAL_SETUP;
					end if;

					-- naprawa w tle - pomiedzy sygnalami 3Hz do ukladu analogowego
				when ST_REPAIR =>
					current_fitness		<= 0;
					eval_vector			<= (others => '0');

					if tick_3Hz_pending_flag = '1' then
						current_state 	<= ST_PANIC; -- nie starczylo czasu pomiedzy sygnalami
					else
						--TODO przerwanie kounikujace do NIOS, rekonfiguracja
						current_state 	<= ST_BACKGROUND_EVAL_SETUP; -- kolejna proba
					end if;

				-- normalna praca  - obsluga systemu analogowego
				when ST_SERVE_ANALOG_SETUP =>
					-- x(2) = Flaga UART, x(1) = stan K5s, x(0) = stan K60s
					core_x_in		<= uart_alive_flag & final_x;
					current_state	<= ST_SERVE_ANALOG_LATCH;

				when ST_SERVE_ANALOG_LATCH =>
					latched_y		<= core_y_out;
					clear_uart_sig	<= '1';
					current_state	<= ST_BACKGROUND_EVAL_SETUP;

				-- nie starczylo czasu na naprawe - trzeba zawiesic prace i ewoluowac do skutku
				when ST_PANIC =>
					panic_flag_out <= '1';
					current_state <= ST_PANIC;

			end case;
	
		end if;
	end process main_fsm_proc;
	
	analog_y_out 				<= latched_y;

	with current_state select
	state_debug <=
		"000" when ST_INIT,
		"001" when ST_BACKGROUND_EVAL_SETUP,
		"010" when ST_BACKGROUND_EVAL_READ,
		"011" when ST_BACKGROUND_EVAL_DECISION,
		"100" when ST_REPAIR,
		"101" when ST_SERVE_ANALOG_SETUP,
		"110" when ST_SERVE_ANALOG_LATCH,
		"111" when ST_PANIC;
	-- kod stanu
	debug_bus(2 downto 0)	<= state_debug;
	-- akualnie testowana kombinacja wejsc
	debug_bus(5 downto 3)	<= std_logic_vector(eval_vector);
	 
	 -- aktualna wartosc fitness
	debug_bus(10 downto 6)	<= std_logic_vector(to_unsigned(current_fitness, 5));
		
	-- sygnaly rozladowania do kondensatorow (zatrzasniete - czestliwosc zmian 3Hz)
	debug_bus(13 downto 11)	<= latched_y;
	 
	 -- sygnaly stanu kondensatorow ( czestotliwosc zmian - 50MHz)
	debug_bus(15 downto 14)	<= final_x;
	 
	 -- flagi omunikacyjne
	debug_bus(16)			<= uart_alive_flag;
	debug_bus(17)			<= tick_3Hz_pending_flag;
	 
	 -- flagi kokretnych stanow
	debug_bus(18)			<= '1' when current_state = ST_PANIC else '0';
	debug_bus(19)			<= '1' when current_state = ST_REPAIR else '0';


	 -- nieuzywane w tej chwili
	debug_bus(23 downto 20) <= (others => '0');

end rtl;
