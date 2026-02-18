create_clock -period 333.333 -waveform {0.000 166.667} [get_ports clk]

set_property -dict {PACKAGE_PIN AB11 IOSTANDARD LVCMOS15} [get_ports clk]
set_property -dict {PACKAGE_PIN AA13 IOSTANDARD LVCMOS15} [get_ports rst_n]

set_property -dict {PACKAGE_PIN D19 IOSTANDARD LVCMOS25} [get_ports uart_rx]
set_property -dict {PACKAGE_PIN N17 IOSTANDARD LVCMOS25} [get_ports uart_tx]

set_property -dict {PACKAGE_PIN N16 IOSTANDARD LVCMOS25} [get_ports trigger]

# set_property -dict {PACKAGE_PIN G20 IOSTANDARD LVCMOS25} [get_ports led<0>]
# set_property -dict {PACKAGE_PIN L19 IOSTANDARD LVCMOS25} [get_ports led<1>]
# set_property -dict {PACKAGE_PIN K18 IOSTANDARD LVCMOS25} [get_ports led<2>]
# set_property -dict {PACKAGE_PIN H19 IOSTANDARD LVCMOS25} [get_ports led<3>]
# set_property -dict {PACKAGE_PIN K15 IOSTANDARD LVCMOS25} [get_ports led<4>]
# set_property -dict {PACKAGE_PIN P16 IOSTANDARD LVCMOS25} [get_ports led<5>]
# set_property -dict {PACKAGE_PIN T19 IOSTANDARD LVCMOS25} [get_ports led<6>]
# set_property -dict {PACKAGE_PIN T18 IOSTANDARD LVCMOS25} [get_ports led<7>]
# set_property -dict {PACKAGE_PIN H12 IOSTANDARD LVCMOS25} [get_ports led<8>]
# set_property -dict {PACKAGE_PIN H11 IOSTANDARD LVCMOS25} [get_ports led<9>]
