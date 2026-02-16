CC        ?= cc
CFLAGS     = -Wall -O2 -fPIC \
             $(shell pkg-config --cflags libbaresip) \
             $(shell pkg-config --cflags libre)
LDFLAGS    = $(shell pkg-config --libs libre)
MODULE_DIR ?= /opt/homebrew/Cellar/baresip/4.5.0/lib/baresip/modules

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
  SHARED = -bundle -undefined dynamic_lookup
else
  SHARED = -shared
endif

ausock.so: ausock.c
	$(CC) $(SHARED) $(CFLAGS) -o $@ $< $(LDFLAGS)

install: ausock.so
	install -m 644 $< $(MODULE_DIR)/

clean:
	rm -f ausock.so

.PHONY: install clean
