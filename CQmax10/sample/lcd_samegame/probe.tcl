project_new -overwrite -family "MAX 10" -part 10M08SCE144C8G tmp_probe
puts "=== device UFM / feature query ==="
if {[catch {set fam [get_global_assignment -name FAMILY]} e]} { puts "fam err $e" }
puts "family=[get_global_assignment -name FAMILY] device=[get_global_assignment -name DEVICE]"
# Try device family info / feature queries
foreach cmd {
  "get_device_family_info $q -family \"MAX 10\" -part 10M08SCE144C8G -info ufm_count"
} {
  # placeholder
}
# List device part numbers available to cross-check SC vs SA vs plain
puts "=== part numbers containing 10M08 ==="
foreach p [get_part_list -family "MAX 10"] {
  if {[string match "*10M08*" $p]} { puts $p }
}
project_close
