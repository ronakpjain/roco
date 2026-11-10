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

FORMAT_FLAGS := --flagfile=.verible-verilog-format

RTL_SV := $(shell find $(RTL_DIR) -name '*.sv')
# The board top contains the ECP5 PLL primitive, which simulation does not model.
SIM_RTL := $(filter-out $(RTL_DIR)/roco_top.sv,$(RTL_SV))
RTL_SVH := $(shell find $(RTL_DIR) -name '*.svh')
SIM_SV := $(shell find $(SIM_DIR) -name '*.sv')
ALL_SV := $(RTL_SV) $(SIM_SV)

.PHONY: all format format-check syntax lint hooks clean test-core test-isa test-sdram test-soc test-isa-soc test-boot synth bitstream

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

$(BUILD_DIR)/basic.elf: sw/tests/basic.S sw/link.ld | build
	$(RISCV)-gcc -march=rv32i_zicsr -mabi=ilp32 -nostdlib -nostartfiles \
		-T sw/link.ld -o $@ $<

$(BUILD_DIR)/basic.bin: $(BUILD_DIR)/basic.elf
	$(RISCV)-objcopy -O binary $< $@

$(BUILD_DIR)/basic.hex: $(BUILD_DIR)/basic.bin
	$(PYTHON) scripts/elf2hex.py $< $@

$(BUILD_DIR)/hello.elf: sw/crt0.S sw/hello/main.c sw/hello/roco_io.h sw/link.ld | build
	$(RISCV)-gcc -march=rv32i_zicsr -mabi=ilp32 -ffreestanding -O2 -nostdlib -nostartfiles \
		-T sw/link.ld -o $@ sw/crt0.S sw/hello/main.c

$(BUILD_DIR)/hello.bin: $(BUILD_DIR)/hello.elf
	$(RISCV)-objcopy -O binary $< $@

$(BUILD_DIR)/hello.hex: $(BUILD_DIR)/hello.bin
	$(PYTHON) scripts/elf2hex.py $< $@

$(BUILD_DIR)/hello.packet.hex: $(BUILD_DIR)/hello.elf
	$(PYTHON) scripts/boot.py --elf $< --emit-hex $@ --riscv-prefix $(RISCV)-

$(BUILD_DIR)/tb_core.vvp: $(SIM_RTL) $(RTL_SVH) sim/tb_core.sv | build
	$(IVERILOG) -g2012 -I$(RTL_DIR)/common -s tb_core -o $@ sim/tb_core.sv $(SIM_RTL)

$(BUILD_DIR)/tb_sdram_ctrl.vvp: rtl/mem/sdram_ctrl.sv sim/sdram_model.sv sim/tb_sdram_ctrl.sv | build
	$(IVERILOG) -g2012 -I$(RTL_DIR)/common -o $@ \
		sim/tb_sdram_ctrl.sv rtl/mem/sdram_ctrl.sv sim/sdram_model.sv

test-sdram: $(BUILD_DIR)/tb_sdram_ctrl.vvp
	$(VVP) $(BUILD_DIR)/tb_sdram_ctrl.vvp

$(BUILD_DIR)/tb_soc.vvp: $(RTL_SV) sim/tb_soc.sv sim/sdram_model.sv | build
	$(IVERILOG) -g2012 -I$(RTL_DIR)/common -o $@ \
		sim/tb_soc.sv sim/sdram_model.sv $(SIM_RTL)

test-soc: $(BUILD_DIR)/basic.hex $(BUILD_DIR)/tb_soc.vvp
	$(VVP) $(BUILD_DIR)/tb_soc.vvp +hex=$(BUILD_DIR)/basic.hex

test-isa-soc: $(BUILD_DIR)/tb_soc.vvp
	./scripts/get-riscv-tests.sh
	$(PYTHON) scripts/run_isa_tests.py --sim soc --riscv-prefix $(RISCV)-

$(BUILD_DIR)/tb_soc_boot.vvp: $(RTL_SV) sim/tb_soc_boot.sv sim/sdram_model.sv | build
	$(IVERILOG) -g2012 -I$(RTL_DIR)/common -o $@ \
		sim/tb_soc_boot.sv sim/sdram_model.sv $(SIM_RTL)

test-boot: $(BUILD_DIR)/hello.packet.hex $(BUILD_DIR)/tb_soc_boot.vvp
	$(VVP) $(BUILD_DIR)/tb_soc_boot.vvp +packet=$(BUILD_DIR)/hello.packet.hex

test-core: $(BUILD_DIR)/basic.hex $(BUILD_DIR)/tb_core.vvp
	$(VVP) $(BUILD_DIR)/tb_core.vvp +hex=$(BUILD_DIR)/basic.hex

test-isa: $(BUILD_DIR)/tb_core.vvp
	./scripts/get-riscv-tests.sh
	$(PYTHON) scripts/run_isa_tests.py --riscv-prefix $(RISCV)-

synth: $(BUILD_DIR)/roco.json

$(BUILD_DIR)/roco.json: $(RTL_SV) | build
	$(YOSYS) -p "read_verilog -sv -I$(RTL_DIR)/common $(RTL_SV); synth_ecp5 -top roco_top -json $@"

bitstream: $(BUILD_DIR)/roco.bit

$(BUILD_DIR)/roco.config: $(BUILD_DIR)/roco.json constraints/roco.lpf
	$(NEXTPNR) --45k --package CABGA381 --speed 6 \
		--json $(BUILD_DIR)/roco.json --lpf constraints/roco.lpf \
		--textcfg $@

$(BUILD_DIR)/roco.bit: $(BUILD_DIR)/roco.config
	$(ECPPACK) --svf $(BUILD_DIR)/roco.svf $< $@

clean:
	rm -rf $(BUILD_DIR)
