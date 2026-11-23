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

prj_project new -name $proj -impl $impl -dev LFE5U-85F-6BG381C -synthesis synplify
prj_impl option top "roco_top"

# Same RTL as the Yosys flow. Synplify OEM reads SystemVerilog-2012;
# the only vendor primitive below the board top is the EHXPLLL in
# rtl/roco_top.sv, which Diamond understands natively.
foreach f [glob soc/rtl/common/*.svh soc/rtl/common/*.sv] { prj_src add $f }
foreach f [glob soc/rtl/*.sv soc/rtl/*/*.sv] { prj_src add $f }

# Diamond-native LPF: LOCATE/IOBUF/FREQUENCY plus the Lattice BLOCK
# RESETPATHS/ASYNCPATHS directives. If PAR rejects anything, fork
# constraints/roco_diamond.lpf and point the line below at it.
prj_src add soc/constraints/roco.lpf
# A fresh project already carries an empty "Logic Preference", so a second
# one arrives disabled; enable ours explicitly (wrapped in catch: if this
# Diamond's dictionary lacks prj_src enable, Map will tell us instead).
catch { prj_src enable soc/constraints/roco.lpf } enable_msg
puts "lpf enable: $enable_msg"

prj_run Synthesis -impl $impl
prj_run Map -impl $impl
prj_run PAR -impl $impl
prj_run Export -impl $impl

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
