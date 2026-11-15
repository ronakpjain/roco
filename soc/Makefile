# roco_cpu
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
SIM ?= verilator
ifeq ($(SIM),verilator)
CORE_SIM := $(BUILD_DIR)/vl_tb_core/tb_core_vl
SOC_SIM := $(BUILD_DIR)/vl_tb_soc/tb_soc_vl
CORE_SIM_DEP := $(CORE_SIM)
SOC_SIM_DEP := $(SOC_SIM)
else
CORE_SIM := $(VVP) $(BUILD_DIR)/tb_core.vvp
SOC_SIM := $(VVP) $(BUILD_DIR)/tb_soc.vvp
CORE_SIM_DEP := $(BUILD_DIR)/tb_core.vvp
SOC_SIM_DEP := $(BUILD_DIR)/tb_soc.vvp
endif
export CORE_SIM_CMD = $(CORE_SIM)
export SOC_SIM_CMD = $(SOC_SIM)

IVERILOG := iverilog
VVP := vvp
PYTHON := python3
YOSYS := yosys
NEXTPNR := nextpnr-ecp5
ECPPACK := ecppack
RISCV ?= $(shell command -v riscv64-elf-gcc >/dev/null 2>&1 && echo riscv64-elf \
	|| (test -x /opt/homebrew/opt/riscv64-elf-gcc/bin/riscv64-elf-gcc \
	    && echo /opt/homebrew/opt/riscv64-elf-gcc/bin/riscv64-elf) || echo riscv64-elf)

ROCO_DIR ?= ../cc
ROCO_AS ?= $(ROCO_DIR)/build/roco_as
ROCO_LD ?= $(ROCO_DIR)/build/roco_ld
ROCO_CC ?= $(ROCO_DIR)/build/roco_cc

FORMAT_FLAGS := --flagfile=.verible-verilog-format

RTL_SV := $(shell find $(RTL_DIR) -name '*.sv')
# The board top contains the ECP5 PLL primitive, which simulation does not model.
SIM_RTL := $(filter-out $(RTL_DIR)/roco_top.sv,$(RTL_SV))
RTL_SVH := $(shell find $(RTL_DIR) -name '*.svh')
SIM_SV := $(shell find $(SIM_DIR) -name '*.sv')
ALL_SV := $(RTL_SV) $(SIM_SV)

.PHONY: all format format_check syntax lint hooks clean test_core test_isa test_mm test_vm test_muldiv test_muldiv_core test_atomic test_vector test_vector_c test_irq test_sdram test_soc test_isa_soc test_boot synth timing bitstream

all: format_check syntax lint

format:
	$(VERIBLE_FORMAT) $(FORMAT_FLAGS) --inplace $(ALL_SV) $(RTL_SVH)

format_check:
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

VL_FLAGS := --binary --timing -j 4 -Wno-fatal -I$(RTL_DIR)/common

lint:
	$(VERILATOR) $(LINT_FLAGS) -I$(RTL_DIR)/common \
		--top-module roco_cpu $(SIM_RTL)
	$(VERILATOR) $(LINT_FLAGS) -I$(RTL_DIR)/common \
		--top-module sdram_ctrl $(SIM_RTL)
	$(VERILATOR) $(LINT_FLAGS) -I$(RTL_DIR)/common \
		--top-module roco_soc $(SIM_RTL)

hooks:
	git config core.hooksPath .githooks
	@echo "pre-commit hook enabled"

build:
	mkdir -p $(BUILD_DIR)

# Directed assembly tests use the sibling roco_cc toolchain.
$(ROCO_AS) $(ROCO_LD):
	cmake -S $(ROCO_DIR) -B $(ROCO_DIR)/build
	cmake --build $(ROCO_DIR)/build

.PHONY: roco_tools
roco_tools:
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

.PHONY: test_redirect
test_redirect: $(BUILD_DIR)/redirect.hex $(CORE_SIM_DEP) $(SOC_SIM_DEP)
	$(CORE_SIM) +hex=$(BUILD_DIR)/redirect.hex
	$(SOC_SIM) +hex=$(BUILD_DIR)/redirect.hex

.PHONY: test_trap_pipeline
test_trap_pipeline: $(BUILD_DIR)/trap_pipeline.hex $(CORE_SIM_DEP) $(SOC_SIM_DEP)
	$(CORE_SIM) +hex=$(BUILD_DIR)/trap_pipeline.hex
	$(SOC_SIM) +hex=$(BUILD_DIR)/trap_pipeline.hex

.PHONY: test_satp_fetch
test_satp_fetch: $(BUILD_DIR)/satp_fetch.hex $(CORE_SIM_DEP) $(SOC_SIM_DEP)
	$(CORE_SIM) +hex=$(BUILD_DIR)/satp_fetch.hex
	$(SOC_SIM) +hex=$(BUILD_DIR)/satp_fetch.hex

$(BUILD_DIR)/vector_c.s: sw/vector/main.c $(ROCO_CC) | build
	$(ROCO_CC) -S -o $@ $<

$(BUILD_DIR)/vector_c-main.o: $(BUILD_DIR)/vector_c.s $(ROCO_AS) | build
	$(ROCO_AS) -o $@ $<

$(BUILD_DIR)/vector_c-crt0.o: sw/vector/crt0.S $(ROCO_AS) | build
	$(ROCO_AS) -o $@ $<

$(BUILD_DIR)/vector_c.elf: $(BUILD_DIR)/vector_c-crt0.o $(BUILD_DIR)/vector_c-main.o $(ROCO_LD) | build
	$(ROCO_LD) -o $@ --binary $(BUILD_DIR)/vector_c.bin --hex $(BUILD_DIR)/vector_c.hex \
		--map $(BUILD_DIR)/vector_c.map $(BUILD_DIR)/vector_c-crt0.o $(BUILD_DIR)/vector_c-main.o

.PHONY: test_vector_start
test_vector_start: $(BUILD_DIR)/vector_start.hex $(CORE_SIM_DEP) $(SOC_SIM_DEP)
	$(CORE_SIM) +hex=$(BUILD_DIR)/vector_start.hex +max_cycles=100000
	$(SOC_SIM) +hex=$(BUILD_DIR)/vector_start.hex +max_cycles=100000

.PHONY: test_atomic_order
test_atomic_order: $(BUILD_DIR)/atomic_order.hex $(CORE_SIM_DEP) $(SOC_SIM_DEP)
	$(CORE_SIM) +hex=$(BUILD_DIR)/atomic_order.hex +max_cycles=100000
	$(SOC_SIM) +hex=$(BUILD_DIR)/atomic_order.hex +max_cycles=100000 +check_atomic_order

$(BUILD_DIR)/hello_boot.s: sw/hello/boot.c sw/hello/roco_io.h $(ROCO_CC) | build
	$(ROCO_CC) -S -o $@ $<

$(BUILD_DIR)/hello_boot-main.o: $(BUILD_DIR)/hello_boot.s $(ROCO_AS) | build
	$(ROCO_AS) -o $@ $<

$(BUILD_DIR)/hello_boot.elf: $(BUILD_DIR)/hello-crt0.o $(BUILD_DIR)/hello_boot-main.o $(BUILD_DIR)/hello-io.o $(ROCO_LD) | build
	$(ROCO_LD) -o $@ --binary $(BUILD_DIR)/hello_boot.bin --hex $(BUILD_DIR)/hello_boot.hex \
		--map $(BUILD_DIR)/hello_boot.map $(BUILD_DIR)/hello-crt0.o $(BUILD_DIR)/hello_boot-main.o $(BUILD_DIR)/hello-io.o

$(BUILD_DIR)/hello_boot.bin: $(BUILD_DIR)/hello_boot.elf
	@test -f $@ || $(ROCO_LD) -o $(BUILD_DIR)/hello_boot.elf --binary $@ \
		--hex $(BUILD_DIR)/hello_boot.hex --map $(BUILD_DIR)/hello_boot.map \
		$(BUILD_DIR)/hello-crt0.o $(BUILD_DIR)/hello_boot-main.o $(BUILD_DIR)/hello-io.o

$(BUILD_DIR)/hello_boot.packet.hex: $(BUILD_DIR)/hello_boot.bin | build
	$(PYTHON) scripts/boot.py --bin $< --emit-hex $@

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

$(BUILD_DIR)/vl_tb_core/tb_core_vl: $(SIM_RTL) $(RTL_SVH) sim/tb_core.sv sim/cpi_monitor.sv | build
	$(VERILATOR) $(VL_FLAGS) --top-module tb_core -Mdir $(BUILD_DIR)/vl_tb_core \
		-o tb_core_vl sim/tb_core.sv sim/cpi_monitor.sv $(SIM_RTL)

$(BUILD_DIR)/vl_tb_soc/tb_soc_vl: $(SIM_RTL) $(RTL_SVH) sim/tb_soc.sv sim/cpi_monitor.sv sim/sdram_model.sv | build
	$(VERILATOR) $(VL_FLAGS) --top-module tb_soc -Mdir $(BUILD_DIR)/vl_tb_soc \
		-o tb_soc_vl sim/tb_soc.sv sim/cpi_monitor.sv sim/sdram_model.sv $(SIM_RTL)

$(BUILD_DIR)/tb_core.vvp: $(SIM_RTL) $(RTL_SVH) sim/tb_core.sv sim/cpi_monitor.sv | build
	$(IVERILOG) -g2012 -I$(RTL_DIR)/common -s tb_core -o $@ sim/tb_core.sv sim/cpi_monitor.sv $(SIM_RTL)

$(BUILD_DIR)/tb_muldiv.vvp: rtl/core/roco_cpu_divider.sv rtl/core/roco_cpu_mul_prod.sv \
	rtl/core/roco_cpu_mul_term.sv rtl/core/roco_cpu_mul_sum.sv \
	rtl/core/roco_cpu_mul_finish.sv sim/tb_muldiv.sv | build
	$(IVERILOG) -g2012 -I$(RTL_DIR)/common -s tb_muldiv -o $@ \
		sim/tb_muldiv.sv rtl/core/roco_cpu_divider.sv rtl/core/roco_cpu_mul_prod.sv \
		rtl/core/roco_cpu_mul_term.sv rtl/core/roco_cpu_mul_sum.sv \
		rtl/core/roco_cpu_mul_finish.sv

test_muldiv: $(BUILD_DIR)/tb_muldiv.vvp
	$(VVP) $(BUILD_DIR)/tb_muldiv.vvp

$(BUILD_DIR)/tb_sdram_ctrl.vvp: rtl/mem/sdram_ctrl.sv sim/sdram_model.sv sim/tb_sdram_ctrl.sv | build
	$(IVERILOG) -g2012 -I$(RTL_DIR)/common -o $@ \
		sim/tb_sdram_ctrl.sv rtl/mem/sdram_ctrl.sv sim/sdram_model.sv

test_sdram: $(BUILD_DIR)/tb_sdram_ctrl.vvp
	$(VVP) $(BUILD_DIR)/tb_sdram_ctrl.vvp

$(BUILD_DIR)/tb_mmu.vvp: $(RTL_SV) sim/tb_mmu.sv | build
	$(IVERILOG) -g2012 -I$(RTL_DIR)/common -s tb_mmu -o $@ sim/tb_mmu.sv $(SIM_RTL)

test_muldiv_core: $(BUILD_DIR)/muldiv.hex $(CORE_SIM_DEP)
	$(CORE_SIM) +hex=$(BUILD_DIR)/muldiv.hex

$(BUILD_DIR)/tb_dcache.vvp: rtl/mem/dcache.sv sim/tb_dcache.sv | build
	$(IVERILOG) -g2012 -s tb_dcache -o $@ $^

.PHONY: test_dcache
test_dcache: $(BUILD_DIR)/tb_dcache.vvp
	$(VVP) $<

$(BUILD_DIR)/tb_regfile.vvp: rtl/core/roco_cpu_regfile.sv sim/tb_regfile.sv | build
	$(IVERILOG) -g2012 -s tb_regfile -o $@ $^

.PHONY: test_regfile
test_regfile: $(BUILD_DIR)/tb_regfile.vvp
	$(VVP) $<

$(BUILD_DIR)/tb_vec_regs.vvp: rtl/core/roco_cpu_vec.sv sim/tb_vec_regs.sv | build
	$(IVERILOG) -g2012 -I$(RTL_DIR)/common -s tb_vec_regs -o $@ $^

.PHONY: test_vector_regs
test_vector_regs: $(BUILD_DIR)/tb_vec_regs.vvp
	$(VVP) $<

test_vector: $(BUILD_DIR)/vector.hex $(CORE_SIM_DEP) $(SOC_SIM_DEP)
	$(CORE_SIM) +hex=$(BUILD_DIR)/vector.hex
	$(SOC_SIM) +hex=$(BUILD_DIR)/vector.hex

test_vector_c: $(BUILD_DIR)/vector_c.hex $(CORE_SIM_DEP) $(SOC_SIM_DEP)
	$(CORE_SIM) +hex=$(BUILD_DIR)/vector_c.hex
	$(SOC_SIM) +hex=$(BUILD_DIR)/vector_c.hex

.PHONY: test_vector_irq
test_vector_irq: $(BUILD_DIR)/vector_irq.hex $(CORE_SIM_DEP) $(SOC_SIM_DEP)
	$(CORE_SIM) +hex=$(BUILD_DIR)/vector_irq.hex
	$(SOC_SIM) +hex=$(BUILD_DIR)/vector_irq.hex

.PHONY: test_vector_fence
test_vector_fence: $(BUILD_DIR)/vector_fence.hex $(CORE_SIM_DEP) $(SOC_SIM_DEP)
	$(CORE_SIM) +hex=$(BUILD_DIR)/vector_fence.hex
	$(SOC_SIM) +hex=$(BUILD_DIR)/vector_fence.hex

test_atomic: $(BUILD_DIR)/atomic.hex $(CORE_SIM_DEP) $(SOC_SIM_DEP)
	$(CORE_SIM) +hex=$(BUILD_DIR)/atomic.hex
	$(SOC_SIM) +hex=$(BUILD_DIR)/atomic.hex

.PHONY: test_atomic_mmio
test_atomic_mmio: $(BUILD_DIR)/atomic_mmio.hex $(SOC_SIM_DEP)
	$(SOC_SIM) +hex=$(BUILD_DIR)/atomic_mmio.hex

.PHONY: test_csr_intent
test_csr_intent: $(BUILD_DIR)/csr_intent.hex $(CORE_SIM_DEP) $(SOC_SIM_DEP)
	$(CORE_SIM) +hex=$(BUILD_DIR)/csr_intent.hex
	$(SOC_SIM) +hex=$(BUILD_DIR)/csr_intent.hex

test_irq: $(BUILD_DIR)/interrupt.hex $(CORE_SIM_DEP)
	$(CORE_SIM) +hex=$(BUILD_DIR)/interrupt.hex +irq_after=300

.PHONY: test_vectored_irq
test_vectored_irq: $(BUILD_DIR)/vectored_irq.hex $(CORE_SIM_DEP) $(SOC_SIM_DEP)
	$(CORE_SIM) +hex=$(BUILD_DIR)/vectored_irq.hex
	$(SOC_SIM) +hex=$(BUILD_DIR)/vectored_irq.hex

test_mm: $(BUILD_DIR)/tb_mmu.vvp
	$(VVP) $(BUILD_DIR)/tb_mmu.vvp

$(BUILD_DIR)/tb_soc.vvp: $(RTL_SV) sim/tb_soc.sv sim/cpi_monitor.sv sim/sdram_model.sv | build
	$(IVERILOG) -g2012 -I$(RTL_DIR)/common -o $@ \
		sim/tb_soc.sv sim/cpi_monitor.sv sim/sdram_model.sv $(SIM_RTL)

test_soc: $(BUILD_DIR)/basic.hex $(SOC_SIM_DEP)
	$(SOC_SIM) +hex=$(BUILD_DIR)/basic.hex

test_isa_soc: $(BUILD_DIR)/tb_soc.vvp
	./scripts/get_riscv_tests.sh
	$(PYTHON) scripts/run_isa_tests.py --sim soc --riscv-prefix $(RISCV)-
	$(PYTHON) scripts/run_isa_tests.py --sim soc --riscv-prefix $(RISCV)- --suite rv32um
	$(PYTHON) scripts/run_isa_tests.py --sim soc --riscv-prefix $(RISCV)- --suite rv32ua

$(BUILD_DIR)/tb_soc_boot.vvp: $(RTL_SV) sim/tb_soc_boot.sv sim/sdram_model.sv | build
	$(IVERILOG) -g2012 -I$(RTL_DIR)/common -o $@ \
		sim/tb_soc_boot.sv sim/sdram_model.sv $(SIM_RTL)

$(BUILD_DIR)/tb_uart_boot_restart.vvp: rtl/periph/uart_boot.sv sim/tb_uart_boot_restart.sv | build
	$(IVERILOG) -g2012 -s tb_uart_boot_restart -o $@ $^

test_boot: $(BUILD_DIR)/hello_boot.packet.hex $(BUILD_DIR)/tb_soc_boot.vvp $(BUILD_DIR)/tb_uart_boot_restart.vvp
	$(VVP) $(BUILD_DIR)/tb_uart_boot_restart.vvp
	$(VVP) $(BUILD_DIR)/tb_soc_boot.vvp +packet=$(BUILD_DIR)/hello_boot.packet.hex

.PHONY: test_hello
test_hello: $(BUILD_DIR)/hello.packet.hex $(BUILD_DIR)/tb_soc_boot.vvp
	$(VVP) $(BUILD_DIR)/tb_soc_boot.vvp +packet=$(BUILD_DIR)/hello.packet.hex

test_core: $(BUILD_DIR)/basic.hex $(CORE_SIM_DEP)
	$(CORE_SIM) +hex=$(BUILD_DIR)/basic.hex

$(BUILD_DIR)/tb_vec_reduce.vvp: rtl/core/roco_cpu_vec_reduce.sv sim/tb_vec_reduce.sv | build
	$(IVERILOG) -g2012 -s tb_vec_reduce -o $@ $^

.PHONY: test_vector_reduce
test_vector_reduce: $(BUILD_DIR)/tb_vec_reduce.vvp
	$(VVP) $<

.PHONY: test_vector_retire
test_vector_retire: $(BUILD_DIR)/vector_retire.hex $(CORE_SIM_DEP) $(SOC_SIM_DEP)
	$(CORE_SIM) +hex=$(BUILD_DIR)/vector_retire.hex
	$(SOC_SIM) +hex=$(BUILD_DIR)/vector_retire.hex

.PHONY: test_cpi
test_cpi: $(BUILD_DIR)/cpi_jalr.hex $(BUILD_DIR)/cpi_vm.hex $(BUILD_DIR)/cpi_forward.hex $(BUILD_DIR)/cpi_vector.hex $(CORE_SIM_DEP) $(SOC_SIM_DEP)
	$(PYTHON) scripts/run_cpi_tests.py

test_vm: $(BUILD_DIR)/vm.hex $(CORE_SIM_DEP) $(SOC_SIM_DEP)
	$(CORE_SIM) +hex=$(BUILD_DIR)/vm.hex
	$(SOC_SIM) +hex=$(BUILD_DIR)/vm.hex

test_isa: $(BUILD_DIR)/tb_core.vvp
	./scripts/get_riscv_tests.sh
	$(PYTHON) scripts/run_isa_tests.py --riscv-prefix $(RISCV)-
	$(PYTHON) scripts/run_isa_tests.py --riscv-prefix $(RISCV)- --suite rv32um
	$(PYTHON) scripts/run_isa_tests.py --riscv-prefix $(RISCV)- --suite rv32ua

synth: $(BUILD_DIR)/roco.json

$(BUILD_DIR)/roco.json: $(RTL_SV) | build
	$(YOSYS) -p "read_verilog -sv -I$(RTL_DIR)/common $(RTL_SV); synth_ecp5 -top roco_top -json $@"

# Share routing settings between timing measurements and the shipped bitstream.
PNR_SEED ?= 4
PNR_FLAGS ?= --placer-heap-timingweight 30
# Diagnostic route: report timing even when the system clock target fails.
TIMING_SEED ?= $(PNR_SEED)
timing: $(BUILD_DIR)/roco.json
	$(NEXTPNR) --45k --package CABGA381 --speed 6 $(PNR_FLAGS) \
		--json $< --lpf constraints/roco.lpf \
		--textcfg $(BUILD_DIR)/timing_seed$(TIMING_SEED).config \
		--report $(BUILD_DIR)/timing_seed$(TIMING_SEED).json \
		--detailed-timing-report --timing-allow-fail --seed $(TIMING_SEED) \
		--log $(BUILD_DIR)/timing_seed$(TIMING_SEED).log

bitstream: $(BUILD_DIR)/roco.bit

# Re-route when a command-line seed or routing flag changes.
.PHONY: force_pnr_options
$(BUILD_DIR)/pnr_options: force_pnr_options | build
	@printf '%s\n' "$(NEXTPNR)" "$(PNR_SEED)" "$(PNR_FLAGS)" > $@.tmp
	@cmp -s $@.tmp $@ || mv $@.tmp $@

$(BUILD_DIR)/roco.config: $(BUILD_DIR)/roco.json constraints/roco.lpf Makefile $(BUILD_DIR)/pnr_options
	$(NEXTPNR) --45k --package CABGA381 --speed 6 $(PNR_FLAGS) \
		--json $(BUILD_DIR)/roco.json --lpf constraints/roco.lpf \
		--seed $(PNR_SEED) --textcfg $@.tmp \
		--report $(BUILD_DIR)/roco_timing.json --detailed-timing-report \
		--log $(BUILD_DIR)/roco_route.log
	mv $@.tmp $@

$(BUILD_DIR)/roco.bit: $(BUILD_DIR)/roco.config
	$(ECPPACK) --svf $(BUILD_DIR)/roco.svf $< $@

clean:
	rm -rf $(BUILD_DIR)

$(BUILD_DIR)/tb_if_queue.vvp: rtl/core/roco_cpu_if_stage.sv sim/tb_if_queue.sv | build
	$(IVERILOG) -g2012 -s tb_if_queue -o $@ $^

.PHONY: test_if_queue
test_if_queue: $(BUILD_DIR)/tb_if_queue.vvp
	$(VVP) $<
