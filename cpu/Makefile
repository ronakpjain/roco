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
RISCV ?= $(shell command -v riscv64-elf-gcc >/dev/null 2>&1 && echo riscv64-elf \
	|| (test -x /opt/homebrew/opt/riscv64-elf-gcc/bin/riscv64-elf-gcc \
	    && echo /opt/homebrew/opt/riscv64-elf-gcc/bin/riscv64-elf) || echo riscv64-elf)

FORMAT_FLAGS := --flagfile=.verible-verilog-format

RTL_SV := $(shell find $(RTL_DIR) -name '*.sv')
RTL_SVH := $(shell find $(RTL_DIR) -name '*.svh')
SIM_SV := $(shell find $(SIM_DIR) -name '*.sv')
ALL_SV := $(RTL_SV) $(SIM_SV)

.PHONY: all format format-check syntax lint hooks clean test-core test-isa test-sdram

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

lint:
	$(VERILATOR) --lint-only --Wall -Wno-fatal \
		-I$(RTL_DIR)/common \
		--top-module rv32_core \
		$(RTL_SV)
	$(VERILATOR) --lint-only --Wall -Wno-fatal \
		-I$(RTL_DIR)/common \
		--top-module sdram_ctrl \
		$(RTL_SV)

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

$(BUILD_DIR)/tb_core.vvp: $(RTL_SV) sim/tb_core.sv | build
	$(IVERILOG) -g2012 -I$(RTL_DIR)/common -o $@ sim/tb_core.sv $(RTL_SV)

$(BUILD_DIR)/tb_sdram_ctrl.vvp: rtl/mem/sdram_ctrl.sv sim/sdram_model.sv sim/tb_sdram_ctrl.sv | build
	$(IVERILOG) -g2012 -I$(RTL_DIR)/common -o $@ \
		sim/tb_sdram_ctrl.sv rtl/mem/sdram_ctrl.sv sim/sdram_model.sv

test-sdram: $(BUILD_DIR)/tb_sdram_ctrl.vvp
	$(VVP) $(BUILD_DIR)/tb_sdram_ctrl.vvp

test-core: $(BUILD_DIR)/basic.hex $(BUILD_DIR)/tb_core.vvp
	$(VVP) $(BUILD_DIR)/tb_core.vvp +hex=$(BUILD_DIR)/basic.hex

test-isa: $(BUILD_DIR)/tb_core.vvp
	./scripts/get-riscv-tests.sh
	$(PYTHON) scripts/run_isa_tests.py --riscv-prefix $(RISCV)-

clean:
	rm -rf $(BUILD_DIR)
