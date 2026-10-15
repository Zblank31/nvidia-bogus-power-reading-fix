# Measurement tools: only a C compiler is needed (no CUDA toolkit; libcuda is loaded at run time with dlopen).
CC ?= gcc
CFLAGS ?= -O2

all: gpuload sondeclk

gpuload: gpuload.c
	$(CC) $(CFLAGS) -o $@ $< -ldl

sondeclk: sondeclk.c
	$(CC) $(CFLAGS) -o $@ $< -ldl

clean:
	rm -f gpuload sondeclk

.PHONY: all clean
