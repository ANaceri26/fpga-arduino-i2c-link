create_clock -name clk50 -period 20.000 [get_ports MAX10_CLK1_50]
derive_clock_uncertainty
# Asynchronous button assertion; reset_release synchronizes release.
set_false_path -from [get_ports KEY0]
# Exclude only asynchronous input paths into the first synchronizer stages.
set_false_path -from [get_ports {SW[*]}] -to [get_registers {*switch_meta*}]
set_false_path -from [get_ports I2C_SCL] -to [get_registers {*|scl_meta}]
set_false_path -from [get_ports I2C_SDA] -to [get_registers {*|sda_meta}]
# Human-viewed indicators are not synchronous external interfaces.
set_false_path -to [get_ports {LEDR[*] HEX0[*] HEX1[*] HEX2[*] HEX3[*] HEX4[*] HEX5[*]}]
# I2C pins are timed by the protocol divider, not an external parallel clock.
set_false_path -to [get_ports {I2C_SDA I2C_SCL}]
