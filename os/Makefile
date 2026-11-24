ROCO_DIR ?= ../cc
SOC_DIR ?= ../soc
ROCO_CC ?= $(ROCO_DIR)/build/roco_cc
ROCO_AS ?= $(ROCO_DIR)/build/roco_as
ROCO_LD ?= $(ROCO_DIR)/build/roco_ld
PYTHON ?= python3

BUILD := build
USER_RUNTIME := $(addprefix $(BUILD)/,user-start.o user-syscall.o user_layout.o)
KERNEL_OBJS := $(addprefix $(BUILD)/,boot.o supervisor.o kernel.o)
OS_OBJS := $(KERNEL_OBJS) $(BUILD)/user_images.o
USER_HELLO := $(BUILD)/user-hello.elf
USER_WORKER := $(BUILD)/user-worker.elf
BOOT_SIM := $(SOC_DIR)/build/vl_tb_soc_boot/Vtb_soc_boot

.PHONY: all clean test console
.SECONDARY: $(USER_RUNTIME) $(BUILD)/user-hello.o $(BUILD)/user-worker.o
all: $(BUILD)/roco-os.elf $(BUILD)/roco-os.packet.hex

$(BUILD):
	mkdir -p $@

$(BUILD)/%.o: %.S $(ROCO_AS) | $(BUILD)
	$(ROCO_AS) -o $@ $<

$(BUILD)/kernel.o: kernel.c user/syscall.h $(ROCO_CC) | $(BUILD)
	$(ROCO_CC) -c -o $@ ./$<

$(BUILD)/user-%.o: user/%.S $(ROCO_AS) | $(BUILD)
	$(ROCO_AS) -o $@ $<

$(BUILD)/user-%.o: user/%.c user/syscall.h $(ROCO_CC) | $(BUILD)
	$(ROCO_CC) -c -o $@ $<

$(BUILD)/user-%.elf: $(USER_RUNTIME) $(BUILD)/user-%.o $(ROCO_LD)
	$(ROCO_LD) --base 0x00400000 -o $@ $(filter %.o,$^)

$(BUILD)/user_images.S: tools/pack_users.py $(USER_HELLO) $(USER_WORKER)
	$(PYTHON) $< $@ $(filter %.elf,$^)

$(BUILD)/user_images.o: $(BUILD)/user_images.S $(ROCO_AS)
	$(ROCO_AS) -o $@ $<

$(BUILD)/roco-os.bin: $(OS_OBJS) $(ROCO_LD)
	$(ROCO_LD) -o $(BUILD)/roco-os.elf --binary $@ $(OS_OBJS)

$(BUILD)/roco-os.elf: $(BUILD)/roco-os.bin
	@test -f $@ || $(ROCO_LD) -o $@ $(OS_OBJS)

$(BUILD)/%.packet.hex: $(BUILD)/%.bin $(SOC_DIR)/scripts/boot.py
	$(PYTHON) $(SOC_DIR)/scripts/boot.py --bin $< --emit-hex $@

$(BUILD)/user-probe.o: tests/user_probe.S $(ROCO_AS) | $(BUILD)
	$(ROCO_AS) -o $@ $<

$(BUILD)/probe_images.S: tools/pack_users.py $(USER_HELLO) $(BUILD)/user-probe.elf
	$(PYTHON) $< $@ $(filter %.elf,$^)

$(BUILD)/probe_images.o: $(BUILD)/probe_images.S $(ROCO_AS)
	$(ROCO_AS) -o $@ $<

$(BUILD)/roco-os-probe.bin: $(KERNEL_OBJS) $(BUILD)/probe_images.o $(ROCO_LD)
	$(ROCO_LD) -o $(BUILD)/roco-os-probe.elf --binary $@ $(filter %.o,$^)

$(BUILD)/console_images.S: tools/pack_users.py $(BUILD)/user-shell.elf $(USER_WORKER) $(BUILD)/user-countdown.elf
	$(PYTHON) $< $@ $(filter %.elf,$^)

$(BUILD)/console_images.o: $(BUILD)/console_images.S $(ROCO_AS)
	$(ROCO_AS) -o $@ $<

$(BUILD)/roco-os-console.bin: $(KERNEL_OBJS) $(BUILD)/console_images.o $(ROCO_LD)
	$(ROCO_LD) -o $(BUILD)/roco-os-console.elf --binary $@ $(filter %.o,$^)

console: $(BUILD)/roco-os-console.packet.hex
	$(MAKE) -C $(SOC_DIR) build/vl_tb_soc_boot/Vtb_soc_boot
	$(BOOT_SIM) +packet=$< +console

test: $(BUILD)/roco-os.packet.hex $(BUILD)/roco-os-probe.packet.hex $(BUILD)/roco-os-console.packet.hex
	$(MAKE) -C $(SOC_DIR) build/vl_tb_soc_boot/Vtb_soc_boot
	$(PYTHON) tools/test_boot.py $(BOOT_SIM) $(BUILD)/roco-os.packet.hex
	$(PYTHON) tools/test_boot.py $(BOOT_SIM) $(BUILD)/roco-os-probe.packet.hex --probe
	$(PYTHON) tools/test_boot.py $(BOOT_SIM) $(BUILD)/roco-os-console.packet.hex --console

clean:
	rm -rf $(BUILD)
