# ==============================================================================
# file name: de2_115_top.sdc
# DESCRIPTION: Synopsys Design Constraints for the CGP Watchdog system
# ==============================================================================

# Define the 50 MHz physical clock (20.000 ns period) connected to the CLOCK port
create_clock -name CLOCK -period 20.000 [get_ports {CLOCK}]

# Multicycle exception for the CGP evaluation path (30-LUT DAG) - 8 clock cycles (160 ns)
# Shifts the setup latching edge 8 cycles forward to allow combinatorial propagation
set_multicycle_path -setup -end -from [get_registers {*core_x_in* *conf_routing_reg* *conf_F_reg* *conf_out_reg* *fault_masks_reg*}] -to [get_registers {*current_fitness* *latched_y*}] 8

# Hold edge correction (Anchor the hold check to the original launch edge)
set_multicycle_path -hold -end -from [get_registers {*core_x_in* *conf_routing_reg* *conf_F_reg* *conf_out_reg* *fault_masks_reg*}] -to [get_registers {*current_fitness* *latched_y*}] 7

# Automatically calculate and apply clock jitter and uncertainty margins
derive_clock_uncertainty

# Asynchronous inputs (buttons, RC states, UART) treated as false paths
# (Timing is ignored here because signals cross clock domains via internal 2-FF synchronizers)
set_false_path -from [all_inputs]
#set_false_path -from [get_ports {KEY* EX_I* rst_n}]

# Asynchronous/slow outputs (LEDs, GPIO debug bus, EX_O) treated as false paths
set_false_path -to [all_outputs]
#set_false_path -to [get_ports {LEDR* LEDG* GPIO* EX_O*}]
