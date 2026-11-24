roco_dir ?= ../cc
SOC_DIR ?= ../soc
roco_cc ?= $(roco_dir)/build/roco_cc
roco_as ?= $(roco_dir)/build/roco_as
roco_ld ?= $(roco_dir)/build/roco_ld
PYTHON ?= python3

BUILD := build
USER_RUNTIME := $(addprefix $(BUILD)/,user-start.o user-syscall.o user-lib.o user_layout.o)
KERNEL_OBJS := $(addprefix $(BUILD)/,boot.o supervisor.o kernel.o)
OS_OBJS := $(KERNEL_OBJS) $(BUILD)/user_images.o
USER_HELLO := $(BUILD)/user-hello.elf
USER_WORKER := $(BUILD)/user-worker.elf
BOOT_SIM := $(SOC_DIR)/build/vl_tb_soc_boot/Vtb_soc_boot

.PHONY: all clean test console
.SECONDARY: $(USER_RUNTIME) $(BUILD)/user-hello.o $(BUILD)/user-worker.o $(BUILD)/user-shell.o $(BUILD)/user-countdown.o $(BUILD)/user-editor.o
all: $(BUILD)/roco_os.elf $(BUILD)/roco_os.packet.hex

$(BUILD):
	mkdir -p $@

$(BUILD)/%.o: %.S $(roco_as) | $(BUILD)
	$(roco_as) -o $@ $<

$(BUILD)/kernel.o: kernel.c user/syscall.h $(roco_cc) | $(BUILD)
	$(roco_cc) -c -o $@ ./$<

$(BUILD)/user-%.o: user/%.S $(roco_as) | $(BUILD)
	$(roco_as) -o $@ $<

$(BUILD)/user-%.o: user/%.c user/syscall.h $(roco_cc) | $(BUILD)
	$(roco_cc) -c -o $@ $<

$(BUILD)/user-%.elf: $(USER_RUNTIME) $(BUILD)/user-%.o $(roco_ld)
	$(roco_ld) --base 0x00400000 -o $@ $(filter %.o,$^)

$(BUILD)/user-lib.o $(BUILD)/user-shell.o $(BUILD)/user-editor.o: $(BUILD)/user-%.o: user/%.c user/lib.h user/editor.h user/syscall.h $(roco_cc) | $(BUILD)
	$(roco_cc) -O1 -c -o $@ $<

$(BUILD)/user-shell.elf: $(USER_RUNTIME) $(BUILD)/user-shell.o $(BUILD)/user-editor.o $(roco_ld)
	$(roco_ld) --base 0x00400000 -o $@ $(filter %.o,$^)

$(BUILD)/user_images.S: tools/pack_users.py $(USER_HELLO) $(USER_WORKER)
	$(PYTHON) $< $@ $(filter %.elf,$^)

$(BUILD)/user_images.o: $(BUILD)/user_images.S $(roco_as)
	$(roco_as) -o $@ $<

$(BUILD)/roco_os.bin: $(OS_OBJS) $(roco_ld)
	$(roco_ld) -o $(BUILD)/roco_os.elf --binary $@ $(OS_OBJS)

$(BUILD)/roco_os.elf: $(BUILD)/roco_os.bin
	@test -f $@ || $(roco_ld) -o $@ $(OS_OBJS)

$(BUILD)/%.packet.hex: $(BUILD)/%.bin $(SOC_DIR)/scripts/boot.py
	$(PYTHON) $(SOC_DIR)/scripts/boot.py --bin $< --emit-hex $@

$(BUILD)/user-probe.o: tests/user_probe.S $(roco_as) | $(BUILD)
	$(roco_as) -o $@ $<

$(BUILD)/probe_images.S: tools/pack_users.py $(USER_HELLO) $(BUILD)/user-probe.elf
	$(PYTHON) $< $@ $(filter %.elf,$^)

$(BUILD)/probe_images.o: $(BUILD)/probe_images.S $(roco_as)
	$(roco_as) -o $@ $<

$(BUILD)/roco_os-probe.bin: $(KERNEL_OBJS) $(BUILD)/probe_images.o $(roco_ld)
	$(roco_ld) -o $(BUILD)/roco_os-probe.elf --binary $@ $(filter %.o,$^)

$(BUILD)/console_images.S: tools/pack_users.py $(BUILD)/user-shell.elf $(USER_WORKER) $(BUILD)/user-countdown.elf
	$(PYTHON) $< $@ $(filter %.elf,$^)

$(BUILD)/console_images.o: $(BUILD)/console_images.S $(roco_as)
	$(roco_as) -o $@ $<

$(BUILD)/roco_os-console.bin: $(KERNEL_OBJS) $(BUILD)/console_images.o $(roco_ld)
	$(roco_ld) -o $(BUILD)/roco_os-console.elf --binary $@ $(filter %.o,$^)

console: $(BUILD)/roco_os-console.packet.hex
	$(MAKE) -C $(SOC_DIR) build/vl_tb_soc_boot/Vtb_soc_boot
	$(BOOT_SIM) +packet=$< +console

test: $(BUILD)/roco_os.packet.hex $(BUILD)/roco_os-probe.packet.hex $(BUILD)/roco_os-console.packet.hex
	$(MAKE) -C $(SOC_DIR) build/vl_tb_soc_boot/Vtb_soc_boot
	$(PYTHON) tools/test_boot.py $(BOOT_SIM) $(BUILD)/roco_os.packet.hex
	$(PYTHON) tools/test_boot.py $(BOOT_SIM) $(BUILD)/roco_os-probe.packet.hex --probe
	$(PYTHON) tools/test_boot.py $(BOOT_SIM) $(BUILD)/roco_os-console.packet.hex --console

clean:
	rm -rf $(BUILD)
