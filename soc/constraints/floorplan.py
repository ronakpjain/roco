# Soft full fence for roco SoC (overlap variant, proven placeable).
#
# Three overlapping vertical regions (Y 2..93, all logic rows + BRAM/DSP):
# - hart0  X 0..85    (68% width for ~44% load)
# - center X 25..102  (62% width for ~14% load: xbar/CDC/SDRAM/boot/UART/APB/TOP)
# - hart1  X 42..126  (67% width for ~42% load)
# Everything non-IO is bounded; overlap keeps heap legalization feasible
# (tight partitioned/granular fences deadlock it: ERROR Unable to find legal
# placement). Extremes stay separated (hart0 out of far right, hart1 out of
# far left) to shorten intra-hart paths while the shared center stays short
# for broadcast cones.
ctx.createRectangularRegion("hart0", 0, 2, 85, 93)
ctx.createRectangularRegion("center", 25, 2, 102, 93)
ctx.createRectangularRegion("hart1", 42, 2, 126, 93)

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


c0 = c1 = cc = cf = 0
for _name, _info in _cell_items():
    _type = _cell_type(_info)
    if _type in ("TRELLIS_IO", "EHXPLLL", "DCCA", "DCSC", "EXTREFB"):
        cf += 1
        continue
    if _name.endswith("$tr_io") or "$iobuf" in _name or "$tr_io_" in _name:
        cf += 1
        continue
    if _name.startswith(HART0_PREFIXES):
        ctx.constrainCellToRegion(_name, "hart0")
        c0 += 1
    elif _name.startswith(HART1_PREFIXES):
        ctx.constrainCellToRegion(_name, "hart1")
        c1 += 1
    else:
        ctx.constrainCellToRegion(_name, "center")
        cc += 1

print("soft full fence: hart0=%d hart1=%d center=%d io_free=%d" % (c0, c1, cc, cf))
