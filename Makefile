# nes2msxtr: NROM / MMC1 / UxROM / MMC3 NES -> MSX turboR + V9990 (GFX9000) cartridge.
#
# ROM is a file name in sourcerom/ (with or without .nes) or a path:
#   make ROM=contra                  translate sourcerom/contra.nes (a game you
#                                    have the rights to port) -> build/contra/
#   make samples                     build every sample found in sourcerom/
#   make profile ROM=path/to/game.nes  play it in openMSX, then rebuild with the
#                                    hot routines copied into the banks using them
#                                    (run it 2-3 times: profiles accumulate)
#   make run ROM=...                 play it; a crash or F11 saves a replay
#   make replay ROM=... REPLAY=...   play a saved replay back and report the crash
#   make discover ROM=...            play the attract mode headless and add the
#                                    computed-jump targets the tracer missed to
#                                    build/<game>/entries.txt (make run adds the
#                                    ones real play reaches when it stops on them;
#                                    DISCOVER_POKES="32=09,30=00;..." adds play runs
#                                    with NES RAM bytes held, e.g. lives / level;
#                                    DISCOVER_PLAY=2 presses Start every 4 s up to
#                                    40 s first, for games with an intro and menus)
#   make test                        end-to-end check with the bundled test ROM
#   make deps                        install the tools needed (tools/deps.sh)

ROM ?= testrom/testrom.nes
SOURCEROM ?= sourcerom
ROMFILE := $(firstword $(wildcard $(ROM) $(SOURCEROM)/$(ROM) $(SOURCEROM)/$(ROM).nes) $(ROM))
OUT ?= build/$(basename $(notdir $(ROMFILE)))
SAMPLES := contra doubledragonii supermariobros
FRAMES ?= 210
PROFILE_SECS ?= 40

all: $(OUT)/$(basename $(notdir $(ROMFILE))).rom

$(OUT)/%.rom: $(ROMFILE) tools/*.py runtime/*.asm $(wildcard $(OUT)/entries.txt)
	@if [ ! -f $(OUT)/entries.txt ] && [ -f samples/$*.entries.txt ]; then \
	    mkdir -p $(OUT); cp samples/$*.entries.txt $(OUT)/entries.txt; \
	    echo "using samples/$*.entries.txt (jump targets found by playing)"; fi
	python3 tools/nes2msxtr.py $(ROMFILE) $(OUT)

testrom/testrom.nes testrom/stacktest.nes testrom/uxtest.nes testrom/mmc3test.nes: testrom/*.s testrom/*.cfg testrom/mkchr.py
	$(MAKE) -C testrom

# Reference run (Python 6502) vs. the cartridge on an emulated FS-A1GT,
# once as a single code bank and once forced into 2K banks, for each
# test ROM.
# the sample games present in sourcerom/
samples:
	@for g in $(SAMPLES); do if [ -f $(SOURCEROM)/$$g.nes ]; then \
	    $(MAKE) --no-print-directory ROM=$$g || echo "$$g: build failed"; \
	    else echo "$(SOURCEROM)/$$g.nes not found, skipped"; fi; done

# test cartridges boot straight into the game: the RAM checks run for a fixed time
NOSPLASH := --splash ''

test: test-testrom test-stacktest test-uxtest test-mmc3 test-ramext

test-testrom: testrom/testrom.nes
	python3 tools/ref6502.py testrom/testrom.nes $(FRAMES) build/ref_ram.bin
	python3 tools/nes2msxtr.py $(NOSPLASH) testrom/testrom.nes build/testrom
	tools/omsx/run.sh build/testrom/testrom.rom build/testrom 12
	python3 tools/compare.py build/ref_ram.bin build/testrom/msx_ram.bin
	python3 tools/nes2msxtr.py $(NOSPLASH) testrom/testrom.nes build/testrom_mb --bank-kb 2
	tools/omsx/run.sh build/testrom_mb/testrom.rom build/testrom_mb 14
	python3 tools/compare.py build/ref_ram.bin build/testrom_mb/msx_ram.bin

test-stacktest: testrom/stacktest.nes
	python3 tools/ref6502.py testrom/stacktest.nes $(FRAMES) build/ref_stack.bin
	python3 tools/nes2msxtr.py $(NOSPLASH) testrom/stacktest.nes build/stacktest
	tools/omsx/run.sh build/stacktest/stacktest.rom build/stacktest 12
	python3 tools/compare.py build/ref_stack.bin build/stacktest/msx_ram.bin
	python3 tools/nes2msxtr.py $(NOSPLASH) testrom/stacktest.nes build/stacktest_mb --bank-kb 2
	tools/omsx/run.sh build/stacktest_mb/stacktest.rom build/stacktest_mb 14
	python3 tools/compare.py build/ref_stack.bin build/stacktest_mb/msx_ram.bin

# UxROM + CHR RAM: also compares the background patterns rebuilt from CHR RAM
test-uxtest: testrom/uxtest.nes
	python3 tools/ref6502.py testrom/uxtest.nes $(FRAMES) build/ref_ux.bin build/ref_ux_chr.bin
	python3 tools/nes2msxtr.py $(NOSPLASH) testrom/uxtest.nes build/uxtest
	tools/omsx/run.sh build/uxtest/uxtest.rom build/uxtest 12
	python3 tools/compare.py build/ref_ux.bin build/uxtest/msx_ram.bin build/ref_ux_chr.bin build/uxtest/v9990_vram.bin
	python3 tools/nes2msxtr.py $(NOSPLASH) testrom/uxtest.nes build/uxtest_mb --bank-kb 2
	tools/omsx/run.sh build/uxtest_mb/uxtest.rom build/uxtest_mb 14
	python3 tools/compare.py build/ref_ux.bin build/uxtest_mb/msx_ram.bin build/ref_ux_chr.bin build/uxtest_mb/v9990_vram.bin

test-mmc3: testrom/mmc3test.nes
	python3 tools/ref6502.py testrom/mmc3test.nes $(FRAMES) build/ref_mmc3.bin build/ref_mmc3_chr.bin
	python3 tools/nes2msxtr.py $(NOSPLASH) testrom/mmc3test.nes build/mmc3test
	tools/omsx/run.sh build/mmc3test/mmc3test.rom build/mmc3test 12
	python3 tools/compare.py build/ref_mmc3.bin build/mmc3test/msx_ram.bin build/ref_mmc3_chr.bin build/mmc3test/v9990_vram.bin
	python3 tools/nes2msxtr.py $(NOSPLASH) testrom/mmc3test.nes build/mmc3test_mb --bank-kb 2
	tools/omsx/run.sh build/mmc3test_mb/mmc3test.rom build/mmc3test_mb 14
	python3 tools/compare.py build/ref_mmc3.bin build/mmc3test_mb/msx_ram.bin build/ref_mmc3_chr.bin build/mmc3test_mb/v9990_vram.bin

# uxtest padded past the turboR's 512K: runs from a RAM expansion cartridge
test-ramext: testrom/uxtest.nes
	python3 tools/ref6502.py testrom/uxtest.nes $(FRAMES) build/ref_ux.bin build/ref_ux_chr.bin
	python3 tools/nes2msxtr.py $(NOSPLASH) testrom/uxtest.nes build/uxtest_ram --pad-kb 600
	tools/omsx/run.sh build/uxtest_ram/uxtest.rom build/uxtest_ram 12
	python3 tools/compare.py build/ref_ux.bin build/uxtest_ram/msx_ram.bin build/ref_ux_chr.bin build/uxtest_ram/v9990_vram.bin

profile: all
	tools/omsx/profile.sh $(OUT)/$(basename $(notdir $(ROMFILE))).rom $(OUT) $(PROFILE_SECS)
	python3 tools/profile.py $(OUT)
	python3 tools/nes2msxtr.py $(ROMFILE) $(OUT)

DISCOVER_SECS ?= 90
DISCOVER_POKES ?=
DISCOVER_PLAY ?= 1
discover:
	DISCOVER_POKES="$(DISCOVER_POKES)" DISCOVER_PLAY="$(DISCOVER_PLAY)" python3 tools/discover.py $(ROMFILE) $(OUT) $(DISCOVER_SECS) 60

# Interactive; a crash (or F11) saves build/<game>/crash-*.omr/.rom/.txt.
run: all
	OPENMSX=$(OPENMSX) tools/omsx/view.sh $(OUT)/$(basename $(notdir $(ROMFILE))).rom $(OUT)

# Play a saved session back headless: make replay ROM=... REPLAY=build/<game>/crash-1.omr
# (uses the cartridge saved next to the replay, so later rebuilds don't matter)
replay:
	OPENMSX=$(OPENMSX) tools/omsx/view.sh $(REPLAY:.omr=.rom) $(OUT) $(REPLAY)

OPENMSX ?= $(firstword $(wildcard /Applications/openMSX.app/Contents/MacOS/openmsx) openmsx)

clean:
	rm -rf build

# install python3, z80asm, cc65 and openMSX (Homebrew or apt), check the FS-A1GT ROMs
deps:
	tools/deps.sh

.PHONY: all deps samples test test-testrom test-stacktest test-uxtest test-mmc3 test-ramext profile discover run replay clean
