# Non-interactive run control for `make sim` (hook honored by utils/make/modelsim.mk:263-269).
# Runs the simulation in 1 ms chunks until the PULP-cluster test prints a verdict
# on the ESP console UART, then quits. Delete this file to get the interactive prompt.

set chunk_ms 1
set max_chunks 120
set verdicts {"RUNG2 PASS" "RUNG2 FAIL" "pulp] done" "not found" "Fatal:" "Error loading design"}

proc transcript_text {} {
    if {[catch {open "transcript" r} f]} { return "" }
    set txt [read $f]
    close $f
    return $txt
}

for {set i 0} {$i < $max_chunks} {incr i} {
    if {[catch {run $chunk_ms ms} msg]} {
        puts "vsim.tcl: run aborted: $msg"
        break
    }
    set txt [transcript_text]
    set hit 0
    foreach v $verdicts {
        if {[string first $v $txt] >= 0} { set hit 1; break }
    }
    if {$hit} {
        puts "vsim.tcl: verdict marker found after [expr {($i + 1) * $chunk_ms}] ms"
        # a little slack so trailing prints flush
        catch {run 100 us}
        break
    }
}
quit -f
