# Definicja fizycznego zegara 50 MHz (okres 20.000 ns) opdlaczonego do portu CLOCK
create_clock -name CLOCK -period 20.000 [get_ports {CLOCK}]

# Wyjatek wielocyklowy dla sciezki ewaluacji w CGP (DAG 30LUT) 7 taktow - 140ns
# przesunicie krawedzi zatrzaskujacej (Setup) o 5 cykli w przod (do 100 ns)
set_multicycle_path -setup -end -from [get_registers {*core_x_in* *conf_routing_reg* *conf_F_reg* *conf_out_reg*}] -to [get_registers {*current_fitness* *latched_y*}] 7

# Korekta krawedzi Hold (odkad sie liczy)
# Zawsze jest to (Wartosc_Setup - 1 ) - odjecie od tego dodatkowo 6
set_multicycle_path -hold -end -from [get_registers {*core_x_in* *conf_routing_reg* *conf_F_reg* *conf_out_reg*}] -to [get_registers {*current_fitness* *latched_y*}] 6

# Nakaz automatycznego uwzględnienia fluktuacji i szumów zegarowych (jitter)
derive_clock_uncertainty

# wejscia asynchroniczne (przyciski, stany RC, UART) jako sciezki niezalezne czasowo
set_false_path -from [all_inputs]
#set_false_path -from [get_ports {KEY* EX_I* rst_n}]

# wyjscia (diody LED, magistrala debugowania GPIO, EX_O) jako sciezki niezalezne czasowo
set_false_path -to [all_outputs]
#set_false_path -to [get_ports {LEDR* LEDG* GPIO* EX_O*}]
