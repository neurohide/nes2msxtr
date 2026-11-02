# Original NES test ROMs for the nes2msxtr translator.
all: testrom.nes stacktest.nes uxtest.nes mmc3test.nes

%.nes: %.s testrom.chr nrom128.cfg
	ca65 -o $*.o $*.s
	ld65 -C nrom128.cfg -o $@ -Ln $*.lbl $*.o

uxtest.nes: uxtest.s uxrom.cfg
	ca65 -o uxtest.o uxtest.s
	ld65 -C uxrom.cfg -o $@ -Ln uxtest.lbl uxtest.o

mmc3test.nes: mmc3test.s mmc3.cfg
	ca65 -o mmc3test.o mmc3test.s
	ld65 -C mmc3.cfg -o $@ -Ln mmc3test.lbl mmc3test.o

testrom.chr: mkchr.py
	python3 mkchr.py $@

clean:
	rm -f *.o *.nes *.lbl testrom.chr

.PHONY: all clean
