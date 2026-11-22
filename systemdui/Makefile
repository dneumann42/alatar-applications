NIM ?= nim
export NIM

.PHONY: build run hot

build:
	$(NIM) c --nimcache:build/nimcache --out:build/systemdui --ic:on --stackTrace:on --lineTrace:on src/systemdui.nim

run: build
	./build/systemdui

hot: build
	bash scripts/hot.sh
