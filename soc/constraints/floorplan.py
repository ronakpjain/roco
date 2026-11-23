# roco SoC floorplan for nextpnr-ecp5 (LFE5U-85F, CABGA381).
#
# Goal: close timing on the 48 MHz core clock (clk_core). Without guidance
# the dual-hart SoC places at ~37 MHz: routing dominates (~22 ns of a
# 27 ns critical path) because hart logic for both cores and caches spreads
# across the whole die.
#
# Strategy (v3: macro-anchored): constrain only the hard/distributed macros
# (block RAM, DSP, distributed RAMW) of each hart to its own half of the
# fabric and leave all LUT/FF logic unconstrained. The timing-driven placer
# then pulls each hart's logic toward its own caches/DSPs instead of
# intermixing the harts. Everything else - crossbar, CDC, SDRAM, boot,
# UART, APB, TOP glue - stays free.
#
# v1 (three regions: hart0/hart1/bottom mem strip) and v2 (two full hart
# fences for all LUT/FF/RAMW/BRAM/DSP) both failed heap legalization
# (ERROR: Unable to find legal placement ... TRELLIS_COMB) despite generous
# capacity, so v3 constrains only ~1k macro cells instead of ~52k logic
# cells.
#
# Device grid (85F): X 0..126, Y 0..95. Logic lives on Y 2..9,11..21,
# 23..33,35..45,47..57,59..69,71..81,83..93 (gaps: PIO/PLL Y 0..1, DSP rows
# Y 10/34/58, BRAM rows Y 22/46/70/82). Both hart regions span Y 12..93 so
# each keeps all four BRAM rows and the 34/58 DSP rows. The 7-column overlap
# (X 60..66) gives shared headroom without letting the macros intermix.
#
# Usage: nextpnr-ecp5 ... --pre-place constraints/floorplan.py ...
# See Makefile PNR_FLOORPLAN. Override the file (not PNR_FLAGS) to try a
# different floorplan without losing the shared routing flags.

# Hart0 macros: left half (plus overlap).
ctx.createRectangularRegion("hart0", 0, 12, 66, 93)
# Hart1 macros: right half (plus overlap).
ctx.createRectangularRegion("hart1", 60, 12, 126, 93)

HART0_PREFIXES = (
    "u_soc.u_cpu0",
    "u_soc.u_icache0",
    "u_soc.u_dcache0",
    "u_soc.u_i0_axi",
    "u_soc.u_d0_axi",
    "u_soc.u_mmio0_axi",
)

HART1_PREFIXES = (
    "u_soc.u_cpu1",
    "u_soc.u_icache1",
    "u_soc.u_dcache1",
    "u_soc.u_i1_axi",
    "u_soc.u_d1_axi",
    "u_soc.u_mmio1_axi",
)

# Only anchor macros; LUT/FF logic follows via connectivity. RAMW is
# distributed (tag RAMs, regfiles) but still worth anchoring: it is the
# cache-adjacent state each hart's logic hangs off.
MACRO_TYPES = ("DP16KD", "MULT18X18D", "TRELLIS_RAMW")


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


count_hart0 = 0
count_hart1 = 0
count_free = 0

for _name, _info in _cell_items():
    _type = _cell_type(_info)
    if _type in ("TRELLIS_IO", "EHXPLLL", "DCCA", "DCSC", "EXTREFB"):
        count_free += 1
        continue
    if _name.endswith("$tr_io") or "$iobuf" in _name or "$tr_io_" in _name:
        count_free += 1
        continue
    if _type not in MACRO_TYPES:
        count_free += 1
        continue
    if _name.startswith(HART0_PREFIXES):
        ctx.constrainCellToRegion(_name, "hart0")
        count_hart0 += 1
    elif _name.startswith(HART1_PREFIXES):
        ctx.constrainCellToRegion(_name, "hart1")
        count_hart1 += 1
    else:
        count_free += 1

print("floorplan: hart0_macros=%d hart1_macros=%d unconstrained=%d" % (count_hart0, count_hart1, count_free))
