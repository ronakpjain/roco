# Lattice Diamond batch build for the roco SoC (LFE5U-85F-6BG381C).
# Run headless inside the container via:  diamondc /work/soc/diamond/roco.tcl
# with CWD=/work, soc/ synced from the repo, out/ writable.
#
# NOTE: prj_* task names below follow the Diamond Tcl dictionary but have
# not been executed yet. The first real run will confirm them against
# diamondc output; update this file (and README.md) with what works.

set impl impl1
set proj roco_soc

# Fresh project each run (the work tree is disposable; sources are synced).
# NOTE: out/ is a bind mount from the host — never delete it, only write
# into it (deleting a mount point fails with "file busy").
file delete -force $proj
file mkdir out

prj_project new -name $proj -impl $impl -dev LFE5U-85F-6BG381C -synthesis synplify -lpf soc/constraints/roco.lpf
prj_impl option top "roco_top"

# Same RTL as the Yosys flow. Synplify OEM reads SystemVerilog-2012;
# the only vendor primitive below the board top is the EHXPLLL in
# rtl/roco_top.sv, which Diamond understands natively.
# Headers (.svh) are added excluded-from-build so Synplify sees them for
# `include resolution but doesn't compile them as design units (compiling
# a header as Verilog is CS219). The .sv files are real design sources.
foreach f [glob soc/rtl/common/*.svh soc/rtl/common/*.sv] {
    catch {prj_src add $f -exclude} m
    if {[string match "*invalid*" $m]} { puts "svh add note: $m" }
}
foreach f [glob soc/rtl/*.sv soc/rtl/*/*.sv] { prj_src add $f }
# Verilog `include "axi4_defs.svh" (bare name, header lives in
# soc/rtl/common) needs an include search path. This exact block (values
# with inner quotes) is the verbatim config from the run that compiled
# clean in 22s -- do not "clean it up" without a passing run first.
foreach opt {{include path} {verilog include path} {hdr path} include} {
    catch {prj_impl option $opt {"soc/rtl/common"}} msg
    puts "include opt '$opt': $msg"
}

proc run_step {label args} {
    puts "=== $label: $args ==="
    if {[catch {eval $args} msg]} {
        puts "$label FAILED: $msg"
        foreach pat {impl1/*.srr impl1/*.srf impl1/*.log impl1/*.tcl impl1/synlog/* *.srr *.log *.ldf} {
            foreach f [glob -nocomplain $pat] {
                catch {file copy -force $f out/}
                puts "saved $f -> out/"
            }
        }
        error "$label failed: $msg"
    }
}

run_step Synthesis prj_run Synthesis -impl $impl
run_step Map prj_run Map -impl $impl
run_step PAR prj_run PAR -impl $impl
run_step Export prj_run Export -impl $impl

# Exported names are <proj>_<impl>.<ext>; normalize for the Makefile.
foreach {src dst} {
    ${proj}_${impl}.bit out/roco_diamond.bit
    ${proj}_${impl}.twr out/roco_diamond.twr
    ${proj}_${impl}.mrp out/roco_diamond.mrp
} {
    if {[file exists $impl/$src]} {
        file copy -force $impl/$src $dst
        puts "wrote $dst"
    } else {
        puts "WARNING: expected artifact missing: $impl/$src"
    }
}
