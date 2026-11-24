# Copyright (c) 2011-2026 Columbia University, System Level Design Group
# SPDX-License-Identifier: Apache-2.0
#
# Fill the black boxes of accelerators synthesized out of context (ACC_OOC in
# vivado.mk). Runs as the post hook of init_design in the implementation run.
#
# Input: the list ooc_checkpoints, made of pairs <module name> <checkpoint>.
#
# Vivado links only its own IP checkpoints by itself, so each checkpoint is
# read into its black-box cell here. That read reloads the whole design from
# the constraints saved with it, and a property that a constraint file had
# removed from a port (set to an empty value) comes back. Those removals are
# recorded before the read and applied again after it.

if {![info exists ooc_checkpoints]} { set ooc_checkpoints {} }

set ooc_cleared {}
foreach p [get_ports] {
  foreach k [list_property $p] {
    if {[get_property $k $p] eq ""} { lappend ooc_cleared [get_property NAME $p] $k }
  }
}

foreach {mod dcp} $ooc_checkpoints {
  set cells [get_cells -quiet -hierarchical -filter "REF_NAME == $mod && IS_BLACKBOX"]
  if {[llength $cells] == 0} { puts "OOCLINK: no black-box cell of $mod, $dcp not used"; continue }
  set names {}
  foreach c $cells { lappend names [get_property NAME $c] }
  foreach n $names {
    puts "OOCLINK: reading $dcp into $n"
    read_checkpoint -cell [get_cells $n] $dcp
  }
}

foreach {name k} $ooc_cleared {
  set p [get_ports -quiet $name]
  if {[llength $p] != 1} continue
  if {[get_property $k $p] ne ""} {
    if {[catch {set_property $k {} $p}]} {
      puts "OOCLINK: $k on port $name changed in the reload and could not be cleared again"
    } else {
      puts "OOCLINK: cleared $k on port $name again"
    }
  }
}
