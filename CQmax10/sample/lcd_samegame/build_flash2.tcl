# Build a Platform Designer system containing just the On-Chip Flash IP,
# configured to hold the logo data in UFM (initialize from Intel HEX).

package require -exact qsys 14.0

create_system logo_flash

set_project_property DEVICE_FAMILY {MAX 10}
set_project_property DEVICE 10M08SCE144C8G
set_project_property HIDE_FROM_IP_CATALOG {false}

add_instance ufm altera_onchip_flash 24.1

set_instance_parameter_value ufm {DATA_INTERFACE} {Parallel}
set_instance_parameter_value ufm {CONFIGURATION_SCHEME} {Internal Configuration}
set_instance_parameter_value ufm {CONFIGURATION_MODE} {Single Uncompressed Image}
set_instance_parameter_value ufm {initFlashContent} {true}
set_instance_parameter_value ufm {useNonDefaultInitFile} {true}
set_instance_parameter_value ufm {initializationFileName} {logo_rom.hex}

add_interface ufm_clock clock sink
set_interface_property ufm_clock EXPORT_OF ufm.clk

add_interface ufm_reset reset sink
set_interface_property ufm_reset EXPORT_OF ufm.nreset

add_interface ufm_data conduit end
set_interface_property ufm_data EXPORT_OF ufm.data

add_interface ufm_csr conduit end
set_interface_property ufm_csr EXPORT_OF ufm.csr

save_system logo_flash.qsys
