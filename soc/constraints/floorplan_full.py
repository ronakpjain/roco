# Full granular floorplan for roco SoC (v6).
#
# Everything non-IO is fenced; LUT/FF logic follows its macros. Regions
# overlap generously (soft fence): heap strict legalization deadlocks on
# tight partitioned fences (v1/v2/v4: ERROR Unable to find legal placement)
# but passes with shared headroom (v5 overlap placed first try).
#
# Capacity model (packed COMB from post-pack probe; die 83640 COMB,
# 984 COMB/row full-width => ~7.75/COMB-row/column):
#   block            COMB load   region (X x COMB-rows)  cap.   full
#   h0cpu (u_cpu0)     ~13096   71c x 44r (Y45..93)     ~24200  54%
#   h1cpu (u_cpu1)     ~13630   71c x 44r (Y45..93)     ~24200  56%
#   h0cache (ic0+dc0)   ~4795   61c x 45r (Y2..50)      ~21270  23%
#   h1cache (ic1+dc1)   ~2981   61c x 45r (Y2..50)      ~21270  14%
#   mem (cdc+sdr+sdram*)~2950   41c x 27r (Y2..30)       ~8580  34%
#   fabric (xbar/TOP/  ~6232   51c x 33r (Y25..60)     ~13040  48%
#     uart/periph/boot)
# Submodule splits stop at the hart/cache level on purpose: Yosys merges
# cross-hart glue asymmetrically (cpu0.u_ex 7646 vs cpu1.u_ex 4237,
# dcache0.tag 3742 vs dcache1.tag 1289), so finer CPU subdivision would
# fight the optimizer. Asymmetry is sized in instead (dcache0 region is
# roomier than its mirror).
#
# Dataflow: CPUs upper (near DSP row 58, clear of SDRAM noise), caches
# mid (between CPUs and fabric; EX<->D$ lookup/forward paths stay vertical
# and short), fabric center (between both harts' endpoints), mem_cdc
# bottom-center (toward SDRAM PIO row Y0). Each CPU/cache region keeps the
# BRAM/DSP rows it needs: CPUs Y45..93 cover DSP 58; caches Y2..50 cover
# BRAM 22/46 and DSP 10/34; mem Y2..30 covers DSP 10 + BRAM 22.

ctx.createRectangularRegion("h0cpu", 0, 45, 70, 93)
ctx.createRectangularRegion("h1cpu", 56, 45, 126, 93)
ctx.createRectangularRegion("h0cache", 0, 2, 60, 50)
ctx.createRectangularRegion("h1cache", 66, 2, 126, 50)
ctx.createRectangularRegion("mem", 45, 2, 85, 30)
ctx.createRectangularRegion("fabric", 40, 25, 90, 60)

H0CPU = (
    "u_soc.u_cpu0",
    "u_soc.u_i0_axi",
    "u_soc.u_d0_axi",
    "u_soc.u_mmio0_axi",
)
H1CPU = (
    "u_soc.u_cpu1",
    "u_soc.u_i1_axi",
    "u_soc.u_d1_axi",
    "u_soc.u_mmio1_axi",
)
H0CACHE = (
    "u_soc.u_icache0",
    "u_soc.u_dcache0",
)
H1CACHE = (
    "u_soc.u_icache1",
    "u_soc.u_dcache1",
)
MEM = (
    "u_soc.u_mem_cdc",
    "u_soc.u_sdram_axi",
    "u_soc.u_sdram",
    "u_soc.u_boot_axi",
)
# TOP-level SDRAM fabric belongs at the bottom with the controller.
MEM_TOP = (
    "sdram_a_",
    "sdram_ba_",
    "sdram_ras_n_",
    "sdram_cas_n_",
    "sdram_we_n_",
    "sdram_cs_n_",
    "sdram_cke_",
    "sdram_dqm",
    "sdram_dq_",
    "sdram_clk",
)


def _cell_items():
    try:
        return list(ctx.cells.items())
    except Exception:
        return list(ctx.cells)


def _cell_type(cell_info):
    try:
        return str(cell_info.type)
    except Exception:
        return ""


counts = {"h0cpu": 0, "h1cpu": 0, "h0cache": 0, "h1cache": 0, "mem": 0, "fabric": 0, "free": 0}
for _name, _info in _cell_items():
    _type = _cell_type(_info)
    if _type in ("TRELLIS_IO", "EHXPLLL", "DCCA", "DCSC", "EXTREFB"):
        counts["free"] += 1
        continue
    if _name.endswith("$tr_io") or "$iobuf" in _name or "$tr_io_" in _name:
        counts["free"] += 1
        continue
    if _name.startswith(H0CPU):
        ctx.constrainCellToRegion(_name, "h0cpu")
        counts["h0cpu"] += 1
    elif _name.startswith(H1CPU):
        ctx.constrainCellToRegion(_name, "h1cpu")
        counts["h1cpu"] += 1
    elif _name.startswith(H0CACHE):
        ctx.constrainCellToRegion(_name, "h0cache")
        counts["h0cache"] += 1
    elif _name.startswith(H1CACHE):
        ctx.constrainCellToRegion(_name, "h1cache")
        counts["h1cache"] += 1
    elif _name.startswith(MEM) or _name.startswith(MEM_TOP):
        ctx.constrainCellToRegion(_name, "mem")
        counts["mem"] += 1
    else:
        ctx.constrainCellToRegion(_name, "fabric")
        counts["fabric"] += 1

print("granular full fence: " + " ".join("%s=%d" % (k, counts[k]) for k in ("h0cpu", "h1cpu", "h0cache", "h1cache", "mem", "fabric", "free")))
