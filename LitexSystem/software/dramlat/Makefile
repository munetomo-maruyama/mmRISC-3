#---------------------------------------------------------------------------
# dramlat : built as LiteX's bare-metal demo (its Makefile and linker.ld,
#           from litex_bare_metal_demo), against a build's BIOS libraries
#
#   make BUILD_DIR=<build>        (scripts/build_dramlat.sh)
#---------------------------------------------------------------------------
BUILD_DIR?=../../build/

include $(BUILD_DIR)/software/include/generated/variables.mak
include $(SOC_DIRECTORY)/software/common.mak

OBJECTS   = crt0.o dramlat.o

COMMA = ,
REGULAR_LIBS = $(filter-out $(ALWAYS_LINK_LIBS),$(LIBS))
ALWAYS_LINK_LIBFLAGS = $(if $(ALWAYS_LINK_LIBS),-Wl$(COMMA)--whole-archive $(ALWAYS_LINK_LIBS:lib%=-l%) -Wl$(COMMA)--no-whole-archive)

all: dramlat.bin

%.bin: %.elf
	$(OBJCOPY) -O binary $< $@
	chmod -x $@

vpath %.a $(PACKAGES:%=../%)

dramlat.elf: $(OBJECTS)
	$(CC) $(LDFLAGS) -T linker.ld -N -o $@ \
		$(OBJECTS) \
		$(PACKAGES:%=-L$(BUILD_DIR)/software/%) \
		-Wl,--start-group \
		$(REGULAR_LIBS:lib%=-l%) \
		$(ALWAYS_LINK_LIBFLAGS) \
		-Wl,--end-group \
		-Wl,--gc-sections \
		-Wl,-Map,$@.map
	chmod -x $@

-include $(OBJECTS:.o=.d)

VPATH = $(BIOS_DIRECTORY):$(BIOS_DIRECTORY)/cmds:$(CPU_DIRECTORY)

%.o: %.c
	$(compile)

%.o: %.S
	$(assemble)

clean:
	$(RM) $(OBJECTS) $(OBJECTS:.o=.d) dramlat.elf dramlat.elf.map dramlat.bin

.PHONY: all clean
