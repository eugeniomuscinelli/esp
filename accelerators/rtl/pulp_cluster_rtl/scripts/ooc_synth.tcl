# Out-of-context Vivado synthesis of the PULP cluster accelerator.
#
# The cluster is synthesized on its own, in non-project mode, and saved as a
# checkpoint plus a black-box stub. The SoC project then uses the stub and the
# checkpoint instead of the vendor sources.
#
# vivado -mode batch -source ooc_synth.tcl -tclargs <acc_root> <part> <period_ns> <outdir> <probe|synth>
#   probe: RTL elaboration only (minutes)
#   synth: full synthesis, reports, checkpoint and stub

lassign $argv acc_root part period outdir mode
set top    pulp_cluster_rtl_basic_dma64

# File list reduced to what the wrapper reaches (scripts/gen_syn_flist.py)
set files {}
set incdirs {}
set fh [open $outdir/syn_flist.f]
while {[gets $fh l] >= 0} {
  set l [string trim $l]
  if {$l eq ""} continue
  if {[string match "+incdir+*" $l]} { lappend incdirs [string range $l 8 end]; continue }
  if {![file exists $l]} { error "missing source $l" }
  lappend files $l
}
close $fh
puts "OOC: [llength $files] files, [llength $incdirs] include dirs"

# Same macros as the simulated configuration, minus the simulation-only ones
set simonly {TARGET_SIMULATION TRACE_EXECUTION TARGET_CV32E40P_INCLUDE_TRACER}
set defs {}
set fh [open $acc_root/pulp_cluster_rtl.defines]
while {[gets $fh l] >= 0} {
  set d [string map {+define+ ""} [string trim $l]]
  if {$d eq "" || [lsearch -exact $simonly $d] >= 0} continue
  lappend defs $d
}
close $fh
puts "OOC: defines $defs"

set_param general.maxThreads 8
read_verilog -sv $files
catch { auto_detect_xpm }
catch { set_property XPM_LIBRARIES {XPM_MEMORY} [current_project] }

set args [list -top $top -part $part -mode out_of_context -include_dirs $incdirs]
foreach d $defs { lappend args -verilog_define $d }

file mkdir $outdir
if {$mode eq "probe"} {
  synth_design -rtl {*}$args
  puts "OOC: RTL elaboration complete"
  exit 0
}

set xdc $outdir/ooc_clock.xdc
set fh [open $xdc w]
puts $fh "create_clock -name clk -period $period \[get_ports clk\]"
close $fh
read_xdc -mode out_of_context $xdc

synth_design {*}$args
report_utilization -file $outdir/utilization.rpt
report_utilization -hierarchical -hierarchical_depth 5 -file $outdir/utilization_hier.rpt
report_timing_summary -max_paths 10 -file $outdir/timing_synth.rpt
write_checkpoint -force $outdir/${top}.dcp
write_verilog -mode synth_stub -force $outdir/${top}_stub.v
puts "OOC: synthesis complete"
