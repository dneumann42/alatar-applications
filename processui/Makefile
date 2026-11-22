NIM ?= nim

.PHONY: build run

build:
	$(NIM) c --nimcache:build/nimcache --out:build/processui src/processui.nim

run: build
	./build/processui
