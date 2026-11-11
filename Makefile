NVIM ?= nvim

.PHONY: test fmt

test:
	$(NVIM) -n --clean -l tests/run.lua

fmt:
	stylua lua/ plugin/ tests/
