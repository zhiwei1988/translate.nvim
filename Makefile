DEPS_DIR := deps
MINI := $(DEPS_DIR)/mini.nvim
NVIM ?= nvim

.PHONY: all deps test test-file clean

all: test

deps: $(MINI)

$(MINI):
	@mkdir -p $(DEPS_DIR)
	git clone --filter=blob:none --depth 1 https://github.com/echasnovski/mini.nvim $(MINI)

test: deps
	$(NVIM) --headless --noplugin -u tests/minimal_init.lua \
		-c "luafile tests/run.lua"

# make test-file FILE=tests/test_prompt.lua
test-file: deps
	TEST_FILE=$(FILE) $(NVIM) --headless --noplugin -u tests/minimal_init.lua \
		-c "luafile tests/run.lua"

clean:
	rm -rf $(DEPS_DIR)
