# Lattice Diamond batch flow (Hercules + Docker)

Proprietary A/B path for the roco SoC next to the default Yosys+nextpnr
flow. Goal: compare routed Fmax on the LFE5U-85F-6BG381C, and ship a
Diamond-built bitstream if Diamond closes timing that nextpnr cannot.

## One-time setup (Hercules)

Hercules already has Docker 29 and 132 GB free, so only two manual steps
remain. Both need a lattice-semi.com account; neither can be scripted.

### 1. Diamond installer `.run` (login-walled download)

1. Log in at lattice-semi.com → Downloads → Lattice Diamond software.
2. Download **Diamond 3.14 for Linux 64-bit (base)**. A service pack is
   optional; base alone is enough for a first timing comparison.
   (Confirmed working shape: `3.14.0.75.2_Diamond_lin.zip` containing one
   `*-Diamond_lin.run` self-extracting binary.)
3. Unzip it and copy the `.run` file to Hercules (`build.sh` picks up
   `installer/*.run`):
   `unzip 3.14.0.75.2_Diamond_lin.zip`
   `scp 3.14.0.75.2_Diamond_lin.run hercules:roco-diamond/installer/`

If Lattice only offers a newer 3.x, take it and pass
`DIAMOND_VERSION=<that>` to `build.sh`; the Dockerfile keys the install
path off that variable.

### 2. Free node-locked license (needs the container MAC, not the host's)

Diamond (including the bundled Synplify OEM) needs a license file even
for the free ECP5 tier, and a node-locked license is bound to one MAC.
Containers get a random MAC every run, so we pin a fixed one and license
*it* — this survives host NIC/MAC changes:

- Container MAC (already baked into `run.sh`): `02:44:49:41:4D:44`
- HostID for the Lattice form (uppercase, no separators): `024449414D44`

Walkthrough:

1. Log in at lattice-semi.com → Licensing → Request a License.
2. Product: Lattice Diamond, license type: **free node-locked**.
3. When asked for the Host ID, enter `024449414D44`.
   (Do NOT use any host NIC MAC — that would tie
   the license to the host instead of the container.)
4. Lattice emails `license.dat`. Copy it to
   `hercules:roco-diamond/license/license.dat` (mode 644 is fine; it is
   bind-mounted read-only into the container).

Alternative: run `lmgrd` as a floating server on Hercules and point the
container at it. More moving parts; only worth it if several containers
or hosts need to share one license.

### 3. Build the image (on Hercules, one time)

```sh
ssh hercules roco-diamond/soc/diamond/build.sh        # or with DIAMOND_VERSION=x.y
```

This copies the Dockerfile into `~/roco-diamond/docker-build/`, then
`docker build -t roco-diamond`. Expect ~10 GB in the image. Re-run after
editing the Dockerfile.

## Per-run flow (from this repo)

```sh
make diamond-bitstream        # sync sources, build on Hercules, and fetch artifacts
```

What it does:

1. Copies `rtl/`, `constraints/`, and `diamond/` to `hercules:roco-diamond/soc/`.
2. Runs `soc/diamond/run.sh` over SSH: `docker run --rm` with the pinned
   `--mac-address`, bind-mounting sources (read-only), `license/`
   (read-only, as `LM_LICENSE_FILE`), and `out/` (artifacts).
3. After timing passes, fetches the bitstream, reports, routed design,
   and preferences into `build/`.

Inside the container, `diamondc` runs `soc/diamond/roco.tcl`: new
`roco_soc` project for `LFE5U-85F-6BG381C`, Synplify synthesis of the same
RTL, then Map → PAR → Export (bitstream). Our `constraints/roco.lpf`
is Diamond-native syntax (LOCATE/IOBUF/FREQUENCY plus the Lattice
`BLOCK RESETPATHS/ASYNCPATHS` directives), so it is reused as-is; if PAR
complains about any directive we will fork a `constraints/roco_diamond.lpf`.

## Reading the result

- `build/roco_diamond.bit` — configuration bitstream.
- `build/roco_diamond.twr` — authoritative TRACE report.
- `build/roco_diamond_par.twr` — PAR timing report for comparison.
- `build/roco_diamond.mrp` — map report (utilization sanity check).
- `build/roco_diamond.ncd` and `build/roco_diamond.prf` — routed design
  and preferences used to reproduce the authoritative TRACE report.

## Notes and known iteration points

- The exact `prj_run` task names in `roco.tcl` follow the Diamond Tcl
  dictionary but have not been executed yet — the first real run will
  confirm them against `diamondc` output, and this file will be updated.
- The `.run` is a Qt Installer Framework bundle (not InstallBuilder):
  headless install goes through `QT_QPA_PLATFORM=minimal` + the
  auto-click script `soc/diamond/install.qs`. If pages/flags differ for
  a newer Diamond release, adjust `install.qs`/Dockerfile from the first
  build log. If the unattended installer flags differ for your Diamond version,
  adjust them in the Dockerfile from the first build log.
- Flashing from Hercules later: pass the USB cable through with
  `--device /dev/bus/usb` plus Diamond's udev rules, and drive it with
  `pgrcmd`. Out of scope for the timing comparison.
