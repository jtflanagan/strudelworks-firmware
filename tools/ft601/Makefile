# SPDX-License-Identifier: GPL-2.0-or-later
#
# Build for ft601_probe.  Portable to the Pi 5 (aarch64) as-is -- libusb is the
# only dependency and every distro ships it, which is the whole point of not
# using D3XX.
#
#   sudo apt-get install libusb-1.0-0-dev

# gnu11 rather than c11: clock_gettime/CLOCK_MONOTONIC and getrusage are POSIX,
# and strict -std=c11 hides them behind feature-test macros.
CC      ?= cc
CFLAGS  ?= -O2 -g -Wall -Wextra -Wno-unused-parameter -std=gnu11
LDFLAGS ?=

LIBUSB_CFLAGS := $(shell pkg-config --cflags libusb-1.0)
LIBUSB_LIBS   := $(shell pkg-config --libs libusb-1.0)

BIN := ft601_probe

all: $(BIN)

$(BIN): ft601_probe.c
	$(CC) $(CFLAGS) $(LIBUSB_CFLAGS) -o $@ $< $(LDFLAGS) $(LIBUSB_LIBS)

clean:
	rm -f $(BIN)

.PHONY: all clean
