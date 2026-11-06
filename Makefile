CFLAGS := -arch arm64 -mmacosx-version-min=14.0 -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter

all: build/diapatch build/DiaPatches.dylib build/diapatch-mobile

build/diapatch: src/diapatch/main.m | build
	clang $(CFLAGS) -framework Foundation -o $@ $<

build/DiaPatches.dylib: src/dylib/DiaPatches.m src/dylib/ArcBar.m src/dylib/ArcBar.h src/dylib/Tabs.m src/dylib/Tabs.h | build
	clang $(CFLAGS) -dynamiclib -framework AppKit -framework QuartzCore -lsqlite3 -o $@ $(filter %.m,$^)

build/index_html.h: src/mobile/index.html | build
	cd src/mobile && xxd -i index.html > ../../$@

build/diapatch-mobile: src/mobile/main.m build/index_html.h | build
	clang $(CFLAGS) -Ibuild -framework AppKit -o $@ src/mobile/main.m

build:
	mkdir -p $@

clean:
	rm -rf build

.PHONY: all clean
