# roco CPU
#
# Requires: verible, iverilog, verilator, yosys and a RISC-V ELF toolchain
# for software builds (riscv64-elf-gcc).

RTL_DIR := rtl
SIM_DIR := sim
SW_DIR := sw
BUILD_DIR := build

VERIBLE_FORMAT := verible-verilog-format
VERIBLE_SYNTAX := verible-verilog-syntax
VERILATOR := verilator
IVERILOG := iverilog
VVP := vvp
PYTHON := python3
YOSYS := yosys
NEXTPNR := nextpnr-ecp5
ECPPACK := ecppack
RISCV ?= $(shell command -v riscv64-elf-gcc >/dev/null 2>&1 && echo riscv64-elf \
	|| (test -x /opt/homebrew/opt/riscv64-elf-gcc/bin/riscv64-elf-gcc \
	    && echo /opt/homebrew/opt/riscv64-elf-gcc/bin/riscv64-elf) || echo riscv64-elf)

ROCO_DIR ?= ../c
ROCO_AS ?= $(ROCO_DIR)/build/roco-as
ROCO_LD ?= $(ROCO_DIR)/build/roco-ld
ROCO_CC ?= $(ROCO_DIR)/build/roco-cc

FORMAT_FLAGS := --flagfile=.verible-verilog-format

RTL_SV := $(shell find $(RTL_DIR) -name '*.sv')
# The board top contains the ECP5 PLL primitive, which simulation does not model.
SIM_RTL := $(filter-out $(RTL_DIR)/roco_top.sv,$(RTL_SV))
RTL_SVH := $(shell find $(RTL_DIR) -name '*.svh')
SIM_SV := $(shell find $(SIM_DIR) -name '*.sv')
ALL_SV := $(RTL_SV) $(SIM_SV)

.PHONY: all format format-check syntax lint hooks clean test-core test-isa test-mm test-vm test-muldiv test-muldiv-core test-atomic test-vector test-vector-c test-irq test-sdram test-soc test-isa-soc test-boot synth timing bitstream

all: format-check syntax lint

format:
	$(VERIBLE_FORMAT) $(FORMAT_FLAGS) --inplace $(ALL_SV) $(RTL_SVH)

format-check:
	@status=0; \
	for f in $(ALL_SV) $(RTL_SVH); do \
		$(VERIBLE_FORMAT) $(FORMAT_FLAGS) --verify $$f || status=1; \
	done; \
	exit $$status

syntax:
	$(VERIBLE_SYNTAX) --error_limit=20 $(ALL_SV) $(RTL_SVH)

# Keep advisory style/width warnings nonfatal, but reject structural defects.
LINT_FLAGS := --lint-only --Wall -Wno-fatal -Werror-PINMISSING -Werror-PINNOCONNECT \
	-Werror-UNDRIVEN -Werror-MULTIDRIVEN -Werror-LATCH -Werror-UNOPTFLAT

lint:
	$(VERILATOR) $(LINT_FLAGS) -I$(RTL_DIR)/common \
		--top-module rv32_core $(SIM_RTL)
	$(VERILATOR) $(LINT_FLAGS) -I$(RTL_DIR)/common \
		--top-module sdram_ctrl $(SIM_RTL)
	$(VERILATOR) $(LINT_FLAGS) -I$(RTL_DIR)/common \
		--top-module roco_soc $(SIM_RTL)

hooks:
	git config core.hooksPath .githooks
	@echo "pre-commit hook enabled"

build:
	mkdir -p $(BUILD_DIR)

# Directed assembly tests use the sibling roco toolchain.
$(ROCO_AS) $(ROCO_LD):
	cmake -S $(ROCO_DIR) -B $(ROCO_DIR)/build
	cmake --build $(ROCO_DIR)/build

.PHONY: roco-tools
roco-tools:
	cmake -S $(ROCO_DIR) -B $(ROCO_DIR)/build
	cmake --build $(ROCO_DIR)/build

$(BUILD_DIR)/%.o: sw/tests/%.S $(ROCO_AS) | build
	$(ROCO_AS) -o $@ $<

$(BUILD_DIR)/%.elf: $(BUILD_DIR)/%.o $(ROCO_LD) | build
	$(ROCO_LD) -o $@ --binary $(BUILD_DIR)/$*.bin --hex $(BUILD_DIR)/$*.hex \
		--map $(BUILD_DIR)/$*.map $<

$(BUILD_DIR)/%.hex: $(BUILD_DIR)/%.elf
	@test -f $@ || $(ROCO_LD) -o $(BUILD_DIR)/$*.elf --binary $(BUILD_DIR)/$*.bin \
		--hex $@ --map $(BUILD_DIR)/$*.map $(BUILD_DIR)/$*.o

.PHONY: test-redirect
test-redirect: $(BUILD_DIR)/redirect.hex $(BUILD_DIR)/tb_core.vvp $(BUILD_DIR)/tb_soc.vvp
	$(VVP) $(BUILD_DIR)/tb_core.vvp +hex=$(BUILD_DIR)/redirect.hex
	$(VVP) $(BUILD_DIR)/tb_soc.vvp +hex=$(BUILD_DIR)/redirect.hex

.PHONY: test-trap-pipeline
test-trap-pipeline: $(BUILD_DIR)/trap-pipeline.hex $(BUILD_DIR)/tb_core.vvp $(BUILD_DIR)/tb_soc.vvp
	$(VVP) $(BUILD_DIR)/tb_core.vvp +hex=$(BUILD_DIR)/trap-pipeline.hex
	$(VVP) $(BUILD_DIR)/tb_soc.vvp +hex=$(BUILD_DIR)/trap-pipeline.hex

.PHONY: test-satp-fetch
test-satp-fetch: $(BUILD_DIR)/satp-fetch.hex $(BUILD_DIR)/tb_core.vvp $(BUILD_DIR)/tb_soc.vvp
	$(VVP) $(BUILD_DIR)/tb_core.vvp +hex=$(BUILD_DIR)/satp-fetch.hex
	$(VVP) $(BUILD_DIR)/tb_soc.vvp +hex=$(BUILD_DIR)/satp-fetch.hex

$(BUILD_DIR)/vector-c.s: sw/vector/main.c $(ROCO_CC) | build
	$(ROCO_CC) -S -o $@ $<

$(BUILD_DIR)/vector-c-main.o: $(BUILD_DIR)/vector-c.s $(ROCO_AS) | build
	$(ROCO_AS) -o $@ $<

$(BUILD_DIR)/vector-c-crt0.o: sw/vector/crt0.S $(ROCO_AS) | build
	$(ROCO_AS) -o $@ $<

$(BUILD_DIR)/vector-c.elf: $(BUILD_DIR)/vector-c-crt0.o $(BUILD_DIR)/vector-c-main.o $(ROCO_LD) | build
	$(ROCO_LD) -o $@ --binary $(BUILD_DIR)/vector-c.bin --hex $(BUILD_DIR)/vector-c.hex \
		--map $(BUILD_DIR)/vector-c.map $(BUILD_DIR)/vector-c-crt0.o $(BUILD_DIR)/vector-c-main.o

.PHONY: test-vector-start
test-vector-start: $(BUILD_DIR)/vector-start.hex $(BUILD_DIR)/tb_core.vvp $(BUILD_DIR)/tb_soc.vvp
	$(VVP) $(BUILD_DIR)/tb_core.vvp +hex=$(BUILD_DIR)/vector-start.hex +max_cycles=100000
	$(VVP) $(BUILD_DIR)/tb_soc.vvp +hex=$(BUILD_DIR)/vector-start.hex +max_cycles=100000

.PHONY: test-atomic-order
test-atomic-order: $(BUILD_DIR)/atomic-order.hex $(BUILD_DIR)/tb_core.vvp $(BUILD_DIR)/tb_soc.vvp
	$(VVP) $(BUILD_DIR)/tb_core.vvp +hex=$(BUILD_DIR)/atomic-order.hex +max_cycles=100000
	$(VVP) $(BUILD_DIR)/tb_soc.vvp +hex=$(BUILD_DIR)/atomic-order.hex +max_cycles=100000 +check_atomic_order

$(BUILD_DIR)/hello.s: sw/hello/main.c sw/hello/roco_io.h $(ROCO_CC) | build
	$(ROCO_CC) -S -o $@ $<

$(BUILD_DIR)/hello-main.o: $(BUILD_DIR)/hello.s $(ROCO_AS) | build
	$(ROCO_AS) -o $@ $<

$(BUILD_DIR)/hello-crt0.o: sw/crt0.S $(ROCO_AS) | build
	$(ROCO_AS) -o $@ $<

$(BUILD_DIR)/hello-io.o: sw/hello/roco_io.S $(ROCO_AS) | build
	$(ROCO_AS) -o $@ $<

$(BUILD_DIR)/hello.elf: $(BUILD_DIR)/hello-crt0.o $(BUILD_DIR)/hello-main.o $(BUILD_DIR)/hello-io.o $(ROCO_LD) | build
	$(ROCO_LD) -o $@ --binary $(BUILD_DIR)/hello.bin --hex $(BUILD_DIR)/hello.hex \
		--map $(BUILD_DIR)/hello.map $(BUILD_DIR)/hello-crt0.o $(BUILD_DIR)/hello-main.o $(BUILD_DIR)/hello-io.o

$(BUILD_DIR)/hello.bin: $(BUILD_DIR)/hello.elf
	@test -f $@ || $(ROCO_LD) -o $(BUILD_DIR)/hello.elf --binary $@ \
		--hex $(BUILD_DIR)/hello.hex --map $(BUILD_DIR)/hello.map \
		$(BUILD_DIR)/hello-crt0.o $(BUILD_DIR)/hello-main.o $(BUILD_DIR)/hello-io.o

$(BUILD_DIR)/hello.packet.hex: $(BUILD_DIR)/hello.bin | build
	$(PYTHON) scripts/boot.py --bin $< --emit-hex $@

$(BUILD_DIR)/tb_core.vvp: $(SIM_RTL) $(RTL_SVH) sim/tb_core.sv sim/cpi_monitor.sv | build
	$(IVERILOG) -g2012 -I$(RTL_DIR)/common -s tb_core -o $@ sim/tb_core.sv sim/cpi_monitor.sv $(SIM_RTL)

$(BUILD_DIR)/tb_muldiv.vvp: rtl/core/rv32_divider.sv rtl/core/rv32_mul_prod.sv \
	rtl/core/rv32_mul_finish.sv sim/tb_muldiv.sv | build
	$(IVERILOG) -g2012 -I$(RTL_DIR)/common -s tb_muldiv -o $@ \
		sim/tb_muldiv.sv rtl/core/rv32_divider.sv rtl/core/rv32_mul_prod.sv \
		rtl/core/rv32_mul_finish.sv

test-muldiv: $(BUILD_DIR)/tb_muldiv.vvp
	$(VVP) $(BUILD_DIR)/tb_muldiv.vvp

$(BUILD_DIR)/tb_sdram_ctrl.vvp: rtl/mem/sdram_ctrl.sv sim/sdram_model.sv sim/tb_sdram_ctrl.sv | build
	$(IVERILOG) -g2012 -I$(RTL_DIR)/common -o $@ \
		sim/tb_sdram_ctrl.sv rtl/mem/sdram_ctrl.sv sim/sdram_model.sv

test-sdram: $(BUILD_DIR)/tb_sdram_ctrl.vvp
	$(VVP) $(BUILD_DIR)/tb_sdram_ctrl.vvp

$(BUILD_DIR)/tb_mmu.vvp: $(RTL_SV) sim/tb_mmu.sv | build
	$(IVERILOG) -g2012 -I$(RTL_DIR)/common -s tb_mmu -o $@ sim/tb_mmu.sv $(SIM_RTL)

test-muldiv-core: $(BUILD_DIR)/muldiv.hex $(BUILD_DIR)/tb_core.vvp
	$(VVP) $(BUILD_DIR)/tb_core.vvp +hex=$(BUILD_DIR)/muldiv.hex

$(BUILD_DIR)/tb_dcache.vvp: rtl/mem/dcache.sv sim/tb_dcache.sv | build
	$(IVERILOG) -g2012 -s tb_dcache -o $@ $^

.PHONY: test-dcache
test-dcache: $(BUILD_DIR)/tb_dcache.vvp
	$(VVP) $<

$(BUILD_DIR)/tb_regfile.vvp: rtl/core/rv32_regfile.sv sim/tb_regfile.sv | build
	$(IVERILOG) -g2012 -s tb_regfile -o $@ $^

.PHONY: test-regfile
test-regfile: $(BUILD_DIR)/tb_regfile.vvp
	$(VVP) $<

$(BUILD_DIR)/tb_vec_regs.vvp: rtl/core/rv32_vec.sv sim/tb_vec_regs.sv | build
	$(IVERILOG) -g2012 -I$(RTL_DIR)/common -s tb_vec_regs -o $@ $^

.PHONY: test-vector-regs
test-vector-regs: $(BUILD_DIR)/tb_vec_regs.vvp
	$(VVP) $<

test-vector: $(BUILD_DIR)/vector.hex $(BUILD_DIR)/tb_core.vvp $(BUILD_DIR)/tb_soc.vvp
	$(VVP) $(BUILD_DIR)/tb_core.vvp +hex=$(BUILD_DIR)/vector.hex
	$(VVP) $(BUILD_DIR)/tb_soc.vvp +hex=$(BUILD_DIR)/vector.hex

test-vector-c: $(BUILD_DIR)/vector-c.hex $(BUILD_DIR)/tb_core.vvp $(BUILD_DIR)/tb_soc.vvp
	$(VVP) $(BUILD_DIR)/tb_core.vvp +hex=$(BUILD_DIR)/vector-c.hex
	$(VVP) $(BUILD_DIR)/tb_soc.vvp +hex=$(BUILD_DIR)/vector-c.hex

.PHONY: test-vector-irq
test-vector-irq: $(BUILD_DIR)/vector-irq.hex $(BUILD_DIR)/tb_core.vvp $(BUILD_DIR)/tb_soc.vvp
	$(VVP) $(BUILD_DIR)/tb_core.vvp +hex=$(BUILD_DIR)/vector-irq.hex
	$(VVP) $(BUILD_DIR)/tb_soc.vvp +hex=$(BUILD_DIR)/vector-irq.hex

.PHONY: test-vector-fence
test-vector-fence: $(BUILD_DIR)/vector-fence.hex $(BUILD_DIR)/tb_core.vvp $(BUILD_DIR)/tb_soc.vvp
	$(VVP) $(BUILD_DIR)/tb_core.vvp +hex=$(BUILD_DIR)/vector-fence.hex
	$(VVP) $(BUILD_DIR)/tb_soc.vvp +hex=$(BUILD_DIR)/vector-fence.hex

test-atomic: $(BUILD_DIR)/atomic.hex $(BUILD_DIR)/tb_core.vvp $(BUILD_DIR)/tb_soc.vvp
	$(VVP) $(BUILD_DIR)/tb_core.vvp +hex=$(BUILD_DIR)/atomic.hex
	$(VVP) $(BUILD_DIR)/tb_soc.vvp +hex=$(BUILD_DIR)/atomic.hex

.PHONY: test-atomic-mmio
test-atomic-mmio: $(BUILD_DIR)/atomic-mmio.hex $(BUILD_DIR)/tb_soc.vvp
	$(VVP) $(BUILD_DIR)/tb_soc.vvp +hex=$(BUILD_DIR)/atomic-mmio.hex

.PHONY: test-csr-intent
test-csr-intent: $(BUILD_DIR)/csr-intent.hex $(BUILD_DIR)/tb_core.vvp $(BUILD_DIR)/tb_soc.vvp
	$(VVP) $(BUILD_DIR)/tb_core.vvp +hex=$(BUILD_DIR)/csr-intent.hex
	$(VVP) $(BUILD_DIR)/tb_soc.vvp +hex=$(BUILD_DIR)/csr-intent.hex

test-irq: $(BUILD_DIR)/interrupt.hex $(BUILD_DIR)/tb_core.vvp
	$(VVP) $(BUILD_DIR)/tb_core.vvp +hex=$(BUILD_DIR)/interrupt.hex +irq_after=300

.PHONY: test-vectored-irq
test-vectored-irq: $(BUILD_DIR)/vectored-irq.hex $(BUILD_DIR)/tb_core.vvp $(BUILD_DIR)/tb_soc.vvp
	$(VVP) $(BUILD_DIR)/tb_core.vvp +hex=$(BUILD_DIR)/vectored-irq.hex
	$(VVP) $(BUILD_DIR)/tb_soc.vvp +hex=$(BUILD_DIR)/vectored-irq.hex

test-mm: $(BUILD_DIR)/tb_mmu.vvp
	$(VVP) $(BUILD_DIR)/tb_mmu.vvp

$(BUILD_DIR)/tb_soc.vvp: $(RTL_SV) sim/tb_soc.sv sim/cpi_monitor.sv sim/sdram_model.sv | build
	$(IVERILOG) -g2012 -I$(RTL_DIR)/common -o $@ \
		sim/tb_soc.sv sim/cpi_monitor.sv sim/sdram_model.sv $(SIM_RTL)

test-soc: $(BUILD_DIR)/basic.hex $(BUILD_DIR)/tb_soc.vvp
	$(VVP) $(BUILD_DIR)/tb_soc.vvp +hex=$(BUILD_DIR)/basic.hex

test-isa-soc: $(BUILD_DIR)/tb_soc.vvp
	./scripts/get-riscv-tests.sh
	$(PYTHON) scripts/run_isa_tests.py --sim soc --riscv-prefix $(RISCV)-
	$(PYTHON) scripts/run_isa_tests.py --sim soc --riscv-prefix $(RISCV)- --suite rv32um
	$(PYTHON) scripts/run_isa_tests.py --sim soc --riscv-prefix $(RISCV)- --suite rv32ua

$(BUILD_DIR)/tb_soc_boot.vvp: $(RTL_SV) sim/tb_soc_boot.sv sim/sdram_model.sv | build
	$(IVERILOG) -g2012 -I$(RTL_DIR)/common -o $@ \
		sim/tb_soc_boot.sv sim/sdram_model.sv $(SIM_RTL)

test-boot: $(BUILD_DIR)/hello.packet.hex $(BUILD_DIR)/tb_soc_boot.vvp
	$(VVP) $(BUILD_DIR)/tb_soc_boot.vvp +packet=$(BUILD_DIR)/hello.packet.hex

test-core: $(BUILD_DIR)/basic.hex $(BUILD_DIR)/tb_core.vvp
	$(VVP) $(BUILD_DIR)/tb_core.vvp +hex=$(BUILD_DIR)/basic.hex

$(BUILD_DIR)/tb_vec_reduce.vvp: rtl/core/rv32_vec_reduce.sv sim/tb_vec_reduce.sv | build
	$(IVERILOG) -g2012 -s tb_vec_reduce -o $@ $^

.PHONY: test-vector-reduce
test-vector-reduce: $(BUILD_DIR)/tb_vec_reduce.vvp
	$(VVP) $<

.PHONY: test-vector-retire
test-vector-retire: $(BUILD_DIR)/vector-retire.hex $(BUILD_DIR)/tb_core.vvp $(BUILD_DIR)/tb_soc.vvp
	$(VVP) $(BUILD_DIR)/tb_core.vvp +hex=$(BUILD_DIR)/vector-retire.hex
	$(VVP) $(BUILD_DIR)/tb_soc.vvp +hex=$(BUILD_DIR)/vector-retire.hex

.PHONY: test-cpi
test-cpi: $(BUILD_DIR)/cpi-jalr.hex $(BUILD_DIR)/cpi-vm.hex $(BUILD_DIR)/cpi-forward.hex $(BUILD_DIR)/cpi-vector.hex $(BUILD_DIR)/tb_core.vvp $(BUILD_DIR)/tb_soc.vvp
	$(PYTHON) scripts/run_cpi_tests.py

test-vm: $(BUILD_DIR)/vm.hex $(BUILD_DIR)/tb_core.vvp $(BUILD_DIR)/tb_soc.vvp
	$(VVP) $(BUILD_DIR)/tb_core.vvp +hex=$(BUILD_DIR)/vm.hex
	$(VVP) $(BUILD_DIR)/tb_soc.vvp +hex=$(BUILD_DIR)/vm.hex

test-isa: $(BUILD_DIR)/tb_core.vvp
	./scripts/get-riscv-tests.sh
	$(PYTHON) scripts/run_isa_tests.py --riscv-prefix $(RISCV)-
	$(PYTHON) scripts/run_isa_tests.py --riscv-prefix $(RISCV)- --suite rv32um
	$(PYTHON) scripts/run_isa_tests.py --riscv-prefix $(RISCV)- --suite rv32ua

synth: $(BUILD_DIR)/roco.json

$(BUILD_DIR)/roco.json: $(RTL_SV) | build
	$(YOSYS) -p "read_verilog -sv -I$(RTL_DIR)/common $(RTL_SV); synth_ecp5 -top roco_top -json $@"

# Share routing settings between timing measurements and the shipped bitstream.
PNR_SEED ?= 4
PNR_FLAGS ?= --placer-heap-timingweight 30
# Diagnostic route: report timing even when the unchanged 48 MHz PLL fails.
TIMING_SEED ?= $(PNR_SEED)
timing: $(BUILD_DIR)/roco.json
	$(NEXTPNR) --45k --package CABGA381 --speed 6 $(PNR_FLAGS) \
		--json $< --lpf constraints/roco.lpf \
		--textcfg $(BUILD_DIR)/timing-seed$(TIMING_SEED).config \
		--report $(BUILD_DIR)/timing-seed$(TIMING_SEED).json \
		--detailed-timing-report --timing-allow-fail --seed $(TIMING_SEED) \
		--log $(BUILD_DIR)/timing-seed$(TIMING_SEED).log

bitstream: $(BUILD_DIR)/roco.bit

# Re-route when a command-line seed or routing flag changes.
.PHONY: force-pnr-options
$(BUILD_DIR)/pnr-options: force-pnr-options | build
	@printf '%s\n' "$(NEXTPNR)" "$(PNR_SEED)" "$(PNR_FLAGS)" > $@.tmp
	@cmp -s $@.tmp $@ || mv $@.tmp $@

$(BUILD_DIR)/roco.config: $(BUILD_DIR)/roco.json constraints/roco.lpf Makefile $(BUILD_DIR)/pnr-options
	$(NEXTPNR) --45k --package CABGA381 --speed 6 $(PNR_FLAGS) \
		--json $(BUILD_DIR)/roco.json --lpf constraints/roco.lpf \
		--seed $(PNR_SEED) --textcfg $@.tmp \
		--report $(BUILD_DIR)/roco-timing.json --detailed-timing-report \
		--log $(BUILD_DIR)/roco-route.log
	mv $@.tmp $@

$(BUILD_DIR)/roco.bit: $(BUILD_DIR)/roco.config
	$(ECPPACK) --svf $(BUILD_DIR)/roco.svf $< $@

clean:
	rm -rf $(BUILD_DIR)
