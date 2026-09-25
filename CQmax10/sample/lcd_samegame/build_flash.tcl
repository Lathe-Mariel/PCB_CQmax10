# Build a Platform Designer system containing just the On-Chip Flash IP,
# configured to hold the logo data in UFM (initialize from Intel HEX).

package require -exact qsys 14.0

# create system
create_system logo_flash

set_project_property DEVICE_FAMILY {MAX 10}
set_project_property DEVICE 10M08SCE144C8G
set_project_property HIDE_FROM_IP_CATALOG {false}

# add on-chip flash instance
add_instance ufm altera_onchip_flash 24.1

# configure: use parallel data interface, initialize from file
set_instance_parameter_value ufm {DATA_INTERFACE} {Parallel}
set_instance_parameter_value ufm {CONFIGURATION_SCHEME} {Internal Configuration}
set_instance_parameter_value ufm {CONFIGURATION_MODE} {Single Uncompressed Image}
set_instance_parameter_value ufm {initFlashContent} {true}
set_instance_parameter_value ufm {useNonDefaultInitFile} {true}
set_instance_parameter_value ufm {initializationFileName} {logo_rom.hex}

# connect clock + reset
add_interface clk clock sink
set_interface_property clk EXPORT_OF clk.clk_in
add_interface_port clk clk_clk clk Input 1
set_interface_property clk associatedClock {}

add_connection clk.clk ufm.clock

# export data + csr avalon interfaces as conduits (we drive them from RTL)
add_interface ufm_data conduit end
set_interface_property ufm_data EXPORT_OF ufm.avalon_slave_0
add_interface ufm_csr conduit end
set_interface_property ufm_csr EXPORT_OF ufm.avalon_slave_1
add_interface ufm_reset conduit end
set_interface_property ufm_reset EXPORT_OF ufm.reset

# save + generate
save_system logo_flash.qsys
generate_system -synthesis -output-directory logo_flash_gen
