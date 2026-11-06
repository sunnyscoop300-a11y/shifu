# Shifu — a DOS emulator in pure Hare, on top of ViperGui.
#
#   make              build shifu and sst
#   make hej          run the example programs (also farver, navn,
#                     timer, taster, vga, cga, ega)
#   make slange       play Snake
#   make musik        Mester Jakob on three sound cards
#   make tegn         paint with the mouse
#   make cpu          which CPU is this? (386, or 8088 with -8)
#   make beskyt       into protected mode and back
#   make xms          extended memory through the XMS driver
#   make dpmi         a 32-bit program through the DPMI host
#   make test         unit tests (CPU and DOS)
#   make hent-msdos   download MS-DOS 2.0's programs from Microsoft (MIT)
#   make command      run MS-DOS 2.0's COMMAND.COM in Shifu
#   make hent-tests   download the SingleStepTests 8088 suite (~480 MB)
#   make cputest      run all 3 million 8088 tests
#   make hent-tests386  download the SingleStepTests 80386 suite (~580 MB)
#   make cputest386   run all 1.76 million 386 tests
#   make desktop      put "Shifu - MS-DOS 2.0" in the app menu
#   make spil         put "Shifu - spil" (the game menu) in the app menu
#                     and on the desktop
#   make SDL=1        also build the SDL2 backend (for X11 desktops)

# ViperGui lives next to this folder (sst borrows its gunzip).
VIPERGUI ?= ../vipergui

# Hare's own module path plus ViperGui.
STDPATH := $(shell hare version -v | awk '/^HAREPATH:/ {f=1; next} /^[^\t]/ {f=0} f {sub(/^\t/, ""); printf "%s:", $$0}')
export HAREPATH := $(STDPATH)$(abspath $(VIPERGUI))

# Pure Hare: no SDL2, no C libraries (the window needs Wayland).
ifdef SDL
FLAGS = -lSDL2
else
FLAGS = -T +nosdl
endif
TESTS = tests/8088/v2_binary
TESTS386 = tests/80386/v1_ex_real_mode

all: shifu sst sst386

shifu: cmd/shifu/*.ha x86/*.ha pc/*.ha
	@test -d $(VIPERGUI)/viper || { echo "Fandt ikke ViperGui i $(VIPERGUI) (brug make VIPERGUI=/sti/til/vipergui)"; exit 1; }
	hare build $(FLAGS) -o $@ cmd/shifu

sst: cmd/sst/*.ha x86/*.ha
	@test -d $(VIPERGUI)/viper || { echo "Fandt ikke ViperGui i $(VIPERGUI) (brug make VIPERGUI=/sti/til/vipergui)"; exit 1; }
	hare build $(FLAGS) -o $@ cmd/sst

sst386: cmd/sst386/*.ha x86/*.ha
	@test -d $(VIPERGUI)/viper || { echo "Fandt ikke ViperGui i $(VIPERGUI) (brug make VIPERGUI=/sti/til/vipergui)"; exit 1; }
	hare build $(FLAGS) -o $@ cmd/sst386

hej: shifu
	./shifu eksempler/hej.com
	./shifu eksempler/mzdemo.exe hej fra make

farver: shifu
	./shifu eksempler/farver.com

navn: shifu
	./shifu eksempler/navn.com

timer: shifu
	./shifu eksempler/timer.com

taster: shifu
	./shifu eksempler/taster.com

vga: shifu
	./shifu eksempler/vga.com

cga: shifu
	./shifu eksempler/cga.com

ega: shifu
	./shifu eksempler/ega.com

slange: shifu
	./shifu eksempler/slange.com

musik: shifu
	./shifu eksempler/musik.com

tegn: shifu
	./shifu eksempler/tegn.com

cpu: shifu
	./shifu eksempler/cpu.com
	./shifu -8 eksempler/cpu.com

beskyt: shifu
	./shifu eksempler/beskyt.com

xms: shifu
	./shifu eksempler/xms.com

dpmi: shifu
	./shifu eksempler/dpmi.com

test:
	hare test -T +nosdl x86
	hare test -T +nosdl pc

msdos:
	git clone --depth 1 --filter=blob:none --sparse https://github.com/microsoft/MS-DOS msdos-git
	cd msdos-git && git sparse-checkout set v2.0/bin
	mkdir -p msdos
	cp msdos-git/v2.0/bin/*.COM msdos-git/v2.0/bin/*.EXE msdos-git/LICENSE msdos/
	rm -rf msdos-git

hent-msdos: msdos

command: shifu msdos
	./shifu -m 256 -v 2.0 -c msdos COMMAND.COM

$(TESTS):
	git clone --depth 1 --filter=blob:none --sparse https://github.com/SingleStepTests/8088 tests/8088
	cd tests/8088 && git sparse-checkout set v2_binary

hent-tests: $(TESTS)

cputest: sst $(TESTS)
	./sst $(TESTS)

$(TESTS386):
	git clone --depth 1 --filter=blob:none --sparse https://github.com/SingleStepTests/80386 tests/80386
	cd tests/80386 && git sparse-checkout set v1_ex_real_mode /80386.csv /revocation_list.txt

hent-tests386: $(TESTS386)

# 22 tests are known not to pass (see README), so the result is shown,
# not treated as an error.
cputest386: sst386 $(TESTS386)
	./sst386 $(TESTS386) || true

APPS = $(HOME)/.local/share/applications
ICONS = $(HOME)/.local/share/icons/hicolor
SIZES = 16 24 32 48 64 128 256

desktop: shifu msdos
	@mkdir -p $(APPS)
	@for s in $(SIZES); do \
		mkdir -p $(ICONS)/$${s}x$${s}/apps; \
		cp assets/shifu-icon-$$s.png $(ICONS)/$${s}x$${s}/apps/shifu.png; \
	done
	@printf '%s\n' '[Desktop Entry]' 'Type=Application' 'Name=Shifu - MS-DOS 2.0' \
		'Comment=COMMAND.COM fra 1983 i en DOS-emulator skrevet i Hare' \
		'Exec=$(CURDIR)/shifu -w -m 256 -v 2.0 -c $(CURDIR)/msdos COMMAND.COM' \
		'Path=$(CURDIR)/msdos' 'Icon=shifu' 'Terminal=false' \
		'Categories=System;Emulator;' 'StartupWMClass=shifu' \
		> $(APPS)/shifu.desktop
	@command -v update-desktop-database >/dev/null && update-desktop-database $(APPS) || true
	@command -v kbuildsycoca6 >/dev/null && kbuildsycoca6 >/dev/null 2>&1 || true
	@echo "Installeret. Se efter Shifu i menuen."

spil: shifu
	@mkdir -p $(APPS)
	@for s in $(SIZES); do \
		mkdir -p $(ICONS)/$${s}x$${s}/apps; \
		cp assets/shifu-icon-$$s.png $(ICONS)/$${s}x$${s}/apps/shifu.png; \
	done
	@printf '%s\n' '[Desktop Entry]' 'Type=Application' 'Name=Shifu - spil' \
		'Comment=Start dine DOS-spil i Shifu' \
		'Exec=$(CURDIR)/shifu -w' 'Path=$(CURDIR)' 'Icon=shifu' \
		'Terminal=false' 'Categories=Game;Emulator;' 'StartupWMClass=shifu' \
		> $(APPS)/shifu-spil.desktop
	@chmod +x $(APPS)/shifu-spil.desktop
	@d=$$(xdg-user-dir DESKTOP 2>/dev/null || echo $(HOME)/Desktop); \
	if [ -d "$$d" ] && [ "$$d" != "$(HOME)" ]; then \
		cp $(APPS)/shifu-spil.desktop "$$d/" && chmod +x "$$d/shifu-spil.desktop"; \
		command -v gio >/dev/null && gio set "$$d/shifu-spil.desktop" metadata::trusted true 2>/dev/null; \
		echo "Ikon lagt på skrivebordet: $$d"; \
	fi
	@command -v update-desktop-database >/dev/null && update-desktop-database $(APPS) || true
	@command -v kbuildsycoca6 >/dev/null && kbuildsycoca6 >/dev/null 2>&1 || true
	@echo "Installeret. Se efter \"Shifu - spil\" i menuen."

undesktop:
	rm -f $(APPS)/shifu.desktop $(APPS)/shifu-spil.desktop
	d=$$(xdg-user-dir DESKTOP 2>/dev/null || echo $(HOME)/Desktop); rm -f "$$d/shifu-spil.desktop"
	for s in $(SIZES); do rm -f $(ICONS)/$${s}x$${s}/apps/shifu.png; done

clean:
	rm -f shifu sst sst386

.PHONY: all hej farver navn timer taster vga cga ega slange musik tegn cpu beskyt xms dpmi test hent-msdos command hent-tests cputest hent-tests386 cputest386 desktop spil undesktop clean
