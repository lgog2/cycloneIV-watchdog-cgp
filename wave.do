onerror {resume}
quietly WaveActivateNextPane {} 0
add wave -noupdate /tb_wrapper/tb_clk
add wave -noupdate /tb_wrapper/debug_tick_pending
add wave -noupdate /tb_wrapper/tb_rst_n
add wave -noupdate -expand /tb_wrapper/tb_analog_x_in
add wave -noupdate -expand /tb_wrapper/debug_final_x
add wave -noupdate -expand /tb_wrapper/DUT/core_y_out
add wave -noupdate -expand /tb_wrapper/tb_analog_y_out
add wave -noupdate -radix unsigned /tb_wrapper/debug_fitness
add wave -noupdate -radix unsigned /tb_wrapper/debug_eval_vec
add wave -noupdate /tb_wrapper/DUT/current_state
add wave -noupdate /tb_wrapper/tb_uart_rx_in
add wave -noupdate /tb_wrapper/debug_uart_alive
TreeUpdate [SetDefaultTree]
WaveRestoreCursors {{Cursor 1} {3339805 ps} 0}
quietly wave cursor active 1
configure wave -namecolwidth 211
configure wave -valuecolwidth 164
configure wave -justifyvalue left
configure wave -signalnamewidth 0
configure wave -snapdistance 10
configure wave -datasetprefix 0
configure wave -rowmargin 4
configure wave -childrowmargin 2
configure wave -gridoffset 0
configure wave -gridperiod 1
configure wave -griddelta 40
configure wave -timeline 0
configure wave -timelineunits ns
update
WaveRestoreZoom {3297385 ps} {3591715 ps}
