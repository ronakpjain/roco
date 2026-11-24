roco_dir ?= ../cc
SOC_DIR ?= ../soc
roco_cc ?= $(roco_dir)/build/roco_cc
roco_as ?= $(roco_dir)/build/roco_as
roco_ld ?= $(roco_dir)/build/roco_ld
PYTHON ?= python3

BUILD := build
USER_RUNTIME := $(addprefix $(BUILD)/,user-start.o user-syscall.o user-lib.o user_layout.o)
KERNEL_OBJS := $(addprefix $(BUILD)/,boot.o supervisor.o kernel.o fs.o)
BOOT_SIM := $(SOC_DIR)/build/vl_tb_soc_boot/Vtb_soc_boot

# Every image mounts a filesystem built from its own manifest. User
# programs are files under /bin, loaded by the kernel at boot and by
# spawn/exec at runtime; nothing is baked into the kernel image.
ROOTFS_TXT := $(addprefix rootfs/,base.manifest motd.txt readme.txt notes.txt hello.script)
ROOTFS_DEFAULT := $(addprefix $(BUILD)/,user-hello.elf user-worker.elf)
ROOTFS_PROBE := $(addprefix $(BUILD)/,user-hello.elf user-probe.elf)
ROOTFS_CONSOLE := $(addprefix $(BUILD)/,user-shell.elf user-worker.elf user-countdown.elf user-primes.elf user-chain.elf user-spin.elf user-alloc.elf)
ROOTFS_ELFS := $(sort $(ROOTFS_DEFAULT) $(ROOTFS_PROBE) $(ROOTFS_CONSOLE))

.PHONY: all clean test console
.SECONDARY: $(USER_RUNTIME) $(BUILD)/user-hello.o $(BUILD)/user-worker.o $(BUILD)/user-shell.o $(BUILD)/user-countdown.o $(BUILD)/user-editor.o $(BUILD)/user-primes.o $(BUILD)/user-chain.o $(BUILD)/user-spin.o $(BUILD)/user-alloc.o
all: $(BUILD)/roco_os.elf $(BUILD)/roco_os.packet.hex

$(BUILD):
	mkdir -p $@

$(BUILD)/%.o: %.S $(roco_as) | $(BUILD)
	$(roco_as) -o $@ $<

$(BUILD)/kernel.o: kernel.c user/syscall.h kernel_fs.h $(roco_cc) | $(BUILD)
	$(roco_cc) -c -o $@ ./$<

$(BUILD)/fs.o: fs.c kernel_fs.h $(roco_cc) | $(BUILD)
	$(roco_cc) -c -o $@ ./$<

$(BUILD)/rootfs-%.S: tools/mkfs.py rootfs/%.manifest $(ROOTFS_TXT) $(ROOTFS_ELFS)
	$(PYTHON) tools/mkfs.py rootfs/$*.manifest -o $@ -I $(BUILD)

$(BUILD)/rootfs-%.o: $(BUILD)/rootfs-%.S $(roco_as) | $(BUILD)
	$(roco_as) -o $@ $<

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

$(BUILD)/roco_os.bin: $(KERNEL_OBJS) $(BUILD)/rootfs-default.o $(ROOTFS_DEFAULT) $(roco_ld)
	$(roco_ld) -o $(BUILD)/roco_os.elf --binary $@ $(filter %.o,$^)

$(BUILD)/roco_os.elf: $(BUILD)/roco_os.bin
	@test -f $@ || $(roco_ld) -o $@ $(KERNEL_OBJS) $(BUILD)/rootfs-default.o

$(BUILD)/%.packet.hex: $(BUILD)/%.bin $(SOC_DIR)/scripts/boot.py
	$(PYTHON) $(SOC_DIR)/scripts/boot.py --bin $< --emit-hex $@

$(BUILD)/user-probe.o: tests/user_probe.S $(roco_as) | $(BUILD)
	$(roco_as) -o $@ $<

$(BUILD)/user-probe.elf: $(USER_RUNTIME) $(BUILD)/user-probe.o $(roco_ld)
	$(roco_ld) --base 0x00400000 -o $@ $(filter %.o,$^)

$(BUILD)/roco_os-probe.bin: $(KERNEL_OBJS) $(BUILD)/rootfs-probe.o $(ROOTFS_PROBE) $(roco_ld)
	$(roco_ld) -o $(BUILD)/roco_os-probe.elf --binary $@ $(filter %.o,$^)

$(BUILD)/roco_os-console.bin: $(KERNEL_OBJS) $(BUILD)/rootfs-console.o $(ROOTFS_CONSOLE) $(roco_ld)
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
