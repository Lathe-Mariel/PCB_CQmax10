set_global_assignment -entity "logo_flash" -library "lib_logo_flash" -name IP_TOOL_NAME "Qsys"
set_global_assignment -entity "logo_flash" -library "lib_logo_flash" -name IP_TOOL_VERSION "25.1"
set_global_assignment -entity "logo_flash" -library "lib_logo_flash" -name IP_TOOL_ENV "Qsys"
set_global_assignment -library "lib_logo_flash" -name SPD_FILE [file join $::quartus(sip_path) "../logo_flash.spd"]
set_global_assignment -library "lib_logo_flash" -name MISC_FILE [file join $::quartus(sip_path) "../../logo_flash.qsys"]

set_global_assignment -library "lib_logo_flash" -name MISC_FILE [file join $::quartus(sip_path) "logo_flash.v"]
set_global_assignment -library "lib_logo_flash" -name MISC_FILE [file join $::quartus(sip_path) "submodules/altera_onchip_flash_util.v"]
set_global_assignment -library "lib_logo_flash" -name MISC_FILE [file join $::quartus(sip_path) "submodules/altera_onchip_flash.v"]
set_global_assignment -library "lib_logo_flash" -name MISC_FILE [file join $::quartus(sip_path) "submodules/altera_onchip_flash_avmm_data_controller.v"]
set_global_assignment -library "lib_logo_flash" -name MISC_FILE [file join $::quartus(sip_path) "submodules/altera_onchip_flash_avmm_csr_controller.v"]
