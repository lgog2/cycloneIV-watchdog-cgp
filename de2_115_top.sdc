# Definicja fizycznego zegara 50 MHz (okres 20.000 ns) opdlaczonego do portu CLOCK
create_clock -name CLOCK -period 20.000 [get_ports {CLOCK}]

# Nakaz automatycznego uwzględnienia fluktuacji i szumów zegarowych (jitter)
derive_clock_uncertainty