library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.consts_pkg.all;

entity wrapper is
	-- stale w formie generic po to zeby mozna bylo je konfigurowac z testbench
	generic (
		-- 50 000 000 / 3 = 16 666 666 (wymaga 24 bitow, max to 16 777 215)
		TICKS_3HZ			: integer := 16666666; -- ~333 ms przy 50MHz
		-- dla debouncera sygnalu w strefie przejsciowej kondensatora
		DEBOUNCE_CYCLES		: integer := 500000;  -- 10 ms przy 50MHz

		MAX_FITNESS 		: integer := 24;
		--opoznienie ewaluatora niezbedne zeby sygnaly zdazyly sie przeprepagowac przez DAG
		DAG_EVAL_DELAY		: integer := 7
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

			--ostatnie dwa zamieione
		analog_x_in			: in  std_logic_vector(1 downto 0);
		uart_rx_in			: in std_logic;
		analog_y_out		: out std_logic_vector(2 downto 0);


		--interfejs dla szyny AVALON-MM (do NIOS II)
		-- Adresy 0 - 63:
			--0-29 conf_routing_arr_t
			--30-59 conf_F_arr_t
			--60 conf_out_arr_t
			--61 sterowanie z NIOS
			--62 do odczytu przez NIOS
			--63 wolny
			--avs-avalonslave
		avs_address			: in  std_logic_vector(11 downto 0);--adresowanie bajtowe z mm_bridge (4kb przestrzeni adresowej- mocno na zapas w tej chwili)
		avs_chipselect		: in  std_logic;
		avs_read			: in  std_logic;
		avs_readdata		: out std_logic_vector(31 downto 0);
		avs_write			: in  std_logic;
		avs_writedata		: in  std_logic_vector(31 downto 0);
		ins_irq				: out std_logic; --interuptrequest przerwanie do Niosa


		-- TODO
		  --  - wstrzykiwanie awarii

		  -- diagnostyka
		panic_flag_out			: out std_logic ; -- obsluga ukladu RC nieaktywna
		debug_bus				: out std_logic_vector(DEBUG_BUS_WIDTH - 1 downto 0)
	);
end wrapper;

architecture rtl of wrapper is

	constant EVAL_COMBINATIONS	: integer := 2 ** NUM_EXT_INPUTS;--8 dla 3 wejsc

	-- y(2)='0' [zasilanie NanoPi nieodcianane], y(1)='1' [K5s rozladowanie], y(0)='1' [K60s rozladowanie]
	constant SAFE_OUT			: std_logic_vector(2 downto 0) := "011";

	--bazowe opoznienie ewaluacji wynikajace ze struktury FSM
	constant FSM_OVERHEAD_CYCLES : integer := 3;

	constant ADDR_CONF_ROUTING	: integer := 0;
	constant ADDR_CONF_F		: integer := NUM_LUTS;--30
	constant ADDR_CONF_OUT		: integer := NUM_LUTS * 2;--60
	constant ADDR_CMD			: integer := (NUM_LUTS * 2) + 1;--61
	constant ADDR_STATUS		: integer := (NUM_LUTS * 2) + 2;--62


	type status_reg_t is record
		panic_flag	: std_logic;
		repair_flag	: std_logic;
		fitness		: integer range 0 to MAX_FITNESS; --5 bitow
	end record;

	type command_reg_t is record
		restart_cmd	: std_logic;
		--tu ewentualne inne komendy z nios
	end record;

	function to_avalon_status(s : status_reg_t) return std_logic_vector is
		variable v : std_logic_vector(31 downto 0) := (others => '0');
	begin
		v(0) := s.panic_flag;
		v(1) := s.repair_flag;
		--bity 2-7 puste
		v(12 downto 8)  := std_logic_vector(to_unsigned(s.fitness, 5));
		--bity 13-31 puste
		return v;
	end function;

	function from_avalon_cmd(v : std_logic_vector(31 downto 0)) return command_reg_t is
		variable c : command_reg_t;
	begin
		c.restart_cmd := v(0);

		return c;
	end function;

	signal status_reg : status_reg_t;
	signal command_reg : command_reg_t;
	
	type state_t is (
		ST_INIT, 
		ST_BACKGROUND_EVAL_SETUP,
		ST_BACKGROUND_EVAL_WAIT,
		ST_BACKGROUND_EVAL_READ,
		ST_BACKGROUND_EVAL_DECISION,
		ST_REPAIR,
		ST_SERVE_ANALOG_SETUP,
		ST_SERVE_ANALOG_WAIT,
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

	-- REJESTRY DLA AVALON
	signal conf_routing_reg		: conf_routing_arr_t := (others => (others => '0'));
	signal conf_F_reg			: conf_F_arr_t		 := (others => (others => '0'));
	signal conf_out_reg			: conf_out_arr_t	 := (others => (others => '0'));

	--skrocenie adresu z zadresowania bajtowego(8bitow - 256 adresowalnych bajtow)
	-- na 32bitowymi slowami (6bitow- 64 adresowalne 32bitowe slowa)
	signal word_addr			: integer range 0 to 1023; --b mocno na zapas gdyby liczba lut miala wzrosnac

	--dla opoznienia potrzebnego na przejscie DAG z 30 LUT - 140ns
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

	--tlumaczenie adresowania bajtowego z NIOS na 4bajtowe
	word_addr <= to_integer(unsigned(avs_address(11 downto 2)));

	-- proces komunikacji z NIO przez AVALON MM
	avalon_write_proc : process(clk, rst_n)
	begin

		if rst_n = '0' then
			command_reg.restart_cmd <= '0';
		elsif rising_edge(clk) then

			command_reg.restart_cmd <= '0';

			-- obsluga zapisu od NIOS
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

	--czytanie przez NIOS asynchroniczne (optymalizacja sprzetowa - o jeden takt
	--avalon_read_proc : process(avs_chipselect, avs_read, word_addr, status_reg)
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
			--ZEROWANIE W ST_INIT 	oraz po restart_cmd od NIOS
			if reset_timer_3hz = '1' then
                timer_3hz			<= 0;
                tick_3hz			<= '0';
			-- Generator 3 Hz
			elsif timer_3hz = TICKS_3HZ then
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
			latched_y		<= SAFE_OUT;
			eval_vector		<= (others => '0'); -- kombinacja wejsc do ewaluacji
			current_fitness	<= 0;
			clear_uart_sig	<= '0';
		elsif rising_edge(clk) then
			clear_uart_sig	<= '0';

			if current_state = ST_REPAIR or current_state = ST_PANIC then
				ins_irq	<= '1';
			else
				ins_irq	<= '0';
			end if;

			case current_state is
				when ST_INIT =>
					current_state <= ST_BACKGROUND_EVAL_SETUP;

				when ST_BACKGROUND_EVAL_SETUP =>
					core_x_in     <= std_logic_vector(eval_vector);
					wait_counter <= 0;
					current_state <= ST_BACKGROUND_EVAL_WAIT;--opoznbinie 1 takt
					--

				when ST_BACKGROUND_EVAL_WAIT =>
					if wait_counter = DAG_EVAL_DELAY - FSM_OVERHEAD_CYCLES then -- (4 co w sumie da 7 cykli zwloki = 140ns)
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
					eval_vector <= (others => '0');

					if current_fitness	< MAX_FITNESS then
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

					--tutaj FSM czeka na sygnal od NIOS

					if tick_3Hz_pending_flag = '1' then
						current_state 		<= ST_PANIC; -- nie starczylo czasu pomiedzy sygnalami
					elsif command_reg.restart_cmd = '1' then
						--eval_vector			<= (others => '0');
						current_fitness		<= 0;
						current_state 		<= ST_BACKGROUND_EVAL_SETUP; -- kolejna proba
					end if;

				-- normalna praca  - obsluga systemu analogowego
				when ST_SERVE_ANALOG_SETUP =>
					-- x(2) = Flaga UART, x(1) = stan K5s, x(0) = stan K60s
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

				-- nie starczylo czasu na naprawe - trzeba zawiesic prace i ewoluowac do skutku
				when ST_PANIC =>
					-- y(2)='0' [zasilanie NanoPi nieodcianane], y(1)='1' [K5s rozladowanie], y(0)='1' [K60s rozladowanie]
					latched_y <= SAFE_OUT;

					if command_reg.restart_cmd = '1' then
						current_fitness	<= 0;
						current_state	<= ST_BACKGROUND_EVAL_SETUP;
					end if;

			end case;
	
		end if;
	end process main_fsm_proc;

	analog_y_out 				<= latched_y;

	status_reg.panic_flag	<= '1' when current_state = ST_PANIC else '0';
	status_reg.repair_flag	<= '1' when current_state = ST_REPAIR else '0';
	status_reg.fitness		<= current_fitness;

	reset_timer_3hz <= '1' when (current_state = ST_INIT or command_reg.restart_cmd = '1') else '0';

	--dzieki temu ze tutaj a nie w srodku fsm pojawia sie od razu po wejsciu do stanu a nie na takcie zegara?
	--zsyntetyzowane jako bramka or a nie przerzutnik?
	--ins_irq			<= '1' when (current_state = ST_REPAIR or current_state = ST_PANIC) else '0';
	panic_flag_out	<= status_reg.panic_flag;


	with current_state select
	state_debug <=
		"000" when ST_INIT,
		"001" when ST_BACKGROUND_EVAL_SETUP,
		"010" when ST_BACKGROUND_EVAL_READ,
		"011" when ST_BACKGROUND_EVAL_DECISION,
		"100" when ST_REPAIR,
		"101" when ST_SERVE_ANALOG_SETUP,
		"110" when ST_SERVE_ANALOG_LATCH,
		"111" when ST_PANIC,
		"000" when others;
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
	debug_bus(DEBUG_BUS_WIDTH - 1 downto 20) <= (others => '0');

end rtl;
