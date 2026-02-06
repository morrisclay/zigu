TOP = ../../lib/micropython
BUILD = build

include $(TOP)/py/mkenv.mk

QSTR_DEFS = qstrdefsport.h
MICROPY_ROM_TEXT_COMPRESSION = 0

include $(TOP)/py/py.mk

INC += -I.
INC += -Iinclude
INC += -I$(TOP)
INC += -I$(BUILD)

CC = cc
CFLAGS += $(INC) -Wall -std=c99
CFLAGS += -DMICROPY_ROM_TEXT_COMPRESSION=0

SRC_C = \
	mphalport.c \
	mp_main.c \
	modukernel.c \
	../libc_shim.c \

SRC_QSTR += mphalport.c modukernel.c

OBJ += $(PY_CORE_O)
OBJ += $(addprefix $(BUILD)/, $(SRC_C:.c=.o))

all: $(BUILD)/genhdr/qstrdefs.generated.h $(BUILD)/genhdr/moduledefs.h $(BUILD)/genhdr/root_pointers.h $(BUILD)/genhdr/mpversion.h

include $(TOP)/py/mkrules.mk
