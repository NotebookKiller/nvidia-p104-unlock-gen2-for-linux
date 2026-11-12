# Build gen2kr only
# (gen2kp.c / gen2hw.c are early experimental versions, kept in legacy/ and not built)
obj-m := gen2kr.o

KDIR := /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

.PHONY: all clean
