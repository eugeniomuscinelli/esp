# Non-interactive run control for `make sim` (hook honored by utils/make/modelsim.mk:263-269).
# Runs the simulation in 1 ms chunks until the PULP-cluster test prints a verdict
# on the ESP console UART, then quits. Delete this file for the interactive prompt.
#
# All logic lives inside a proc: vsim echoes interactive commands AND their return
# values into the transcript, so any top-level literal or list containing a verdict
# string would match itself (bitten twice during bring-up, see the report).

proc rung_watch {} {
    set chunk_ms 1
    set max_chunks 120
    set g2 "G2"
    set dn "ne"
    set ft "tal:"
    set nf "found"
    set verdicts [list "RUN${g2} PASS" "RUN${g2} FAIL" "pulp\] do${dn}" "not ${nf}" "Fa${ft}"]

    for {set i 0} {$i < $max_chunks} {incr i} {
        if {[catch {run $chunk_ms ms} msg]} {
            puts "vsim.tcl: run aborted: $msg"
            return
        }
        if {[catch {open "transcript" r} f]} { continue }
        set txt [read $f]
        close $f
        foreach v $verdicts {
            if {[string first $v $txt] >= 0} {
                puts "vsim.tcl: verdict after [expr {($i + 1) * $chunk_ms}] ms"
                catch {run 500 us}
                return
            }
        }
    }
    puts "vsim.tcl: max_chunks reached without verdict"
}
rung_watch
quit -f
