CFLAGS := -arch arm64 -mmacosx-version-min=14.0 -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter
DYLIB_SOURCES := $(wildcard src/dylib/*.[hm] src/dylib/*/*.[hm])

all: build/diapatch build/DiaPatches.dylib

build/diapatch: src/diapatch/main.m | build
	clang $(CFLAGS) -framework Foundation -o $@ $<

build/DiaPatches.dylib: $(DYLIB_SOURCES) | build
	clang $(CFLAGS) -dynamiclib -framework AppKit -framework QuartzCore -o $@ $(filter %.m,$^)

build:
	mkdir -p $@

test: build/DiaPatches.dylib
	./test.sh

clean:
	rm -rf build

.PHONY: all clean test
