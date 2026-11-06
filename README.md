# Shifu

A DOSBox-style PC/DOS emulator written in pure Hare, built on
[ViperGui](https://github.com/sunnyscoop300-a11y/vipergui). The old master of an old platform.

Version **0.12.1**: an 8088 and a 386 (with the 486's extra instructions
and a 387 maths coprocessor) with protected mode and paging, a DOS with
XMS and DPMI, a window, the PC's timer and interrupt hardware, VGA
graphics, sound, and a mouse. Wolfenstein 3D, and the DOS/4GW games Duke
Nukem 3D and Doom, play (use `-x max` for the speed they need), with VGA "mode X" (mode 13h
without chain-4) for Doom's page flipping. The 386 core uses lazy flags and
a handler table per opcode, about twice as fast as 0.10.

`shifu` on its own opens a game menu: the games listed in
`~/.config/shifu/spil.txt` (written the first time with the games found
in the current folder and the one above it), one line each:
`Name | folder | PROGRAM | options`.

```
$ make command
Command v. 2.02

C:\>VER

MS-DOS Version  2.00

C:\>DIR *.EXE
...
```

## What works

**Stage 7c — DPMI.** A DPMI 0.9 host, like CWSDPMI, for 32-bit (and
16-bit) DOS programs:
- Programs find it with INT 2Fh AX=1687h and switch to protected mode
  through it. They run in ring 3 with IOPL 3, on Shifu's GDT, LDT, IDT
  and TSS, in the top 256 KiB of memory.
- INT 31h: LDT descriptors (allocate, base, limit, rights, aliases),
  memory blocks above 1 MiB, DOS memory with selectors, real- and
  protected-mode interrupt vectors, exception handlers, calls to real
  mode (0300h-0302h), real-mode callbacks, raw mode switches, the
  virtual interrupt flag.
- Other software interrupts go down to the real-mode handlers (DOS, the
  BIOS) and back; so do hardware interrupts, unless the program has its
  own handler, which then gets them even when they come in real mode.
- An exception the program doesn't handle ends it with a message; INT
  21h AH=4Ch ends it from protected mode.
- DOS extenders with their own host (DOS/4GW, DOS/32A, PMODE/W) use
  Shifu's instead when it is there. `-p` turns it off, so they run on
  their own over XMS, as they do in DOSBox.

**Stage 7b — protected mode, paging and XMS.**
- Protected mode as on a 386: segment descriptors from the GDT and LDT
  with their base, limit (byte or 4 KiB granular, expand-down too) and
  rights; 16- and 32-bit code and stack segments; privilege levels 0-3.
- The IDT with interrupt and trap gates, exceptions with error codes,
  hardware interrupts in protected mode, and changes of privilege level
  with the stacks from the TSS. Far calls and jumps through call gates
  (parameters copied), RETF and IRET to outer levels.
- LGDT/LIDT, LLDT/LTR, LAR/LSL/VERR/VERW/ARPL, MOV CRn, the I/O
  permission bitmap and IOPL. A fault while taking an exception is a
  double fault; a third shuts the CPU down.
- Paging: page directory and tables, user/supervisor and read/write
  rights, accessed and dirty bits, page faults with CR2, and a TLB.
- Back in real mode, segments keep their protected-mode base and limit
  until loaded again, so "unreal mode" works like on the real chip.
- An XMS 3.0 driver, like HIMEM.SYS: 14.7 MiB of extended memory in
  blocks programs move data to and from or lock for their physical
  address, the HMA, and the A20 gate.
- `make beskyt` runs a tour of it all: into protected mode, ring 3,
  paging with a page fault, a timer interrupt, and back again.

**Stage 7a — the 386.** Shifu is now an AT-class PC with an Intel 80386
(`-8` makes it an IBM PC with an 8088 again). In real mode it passes
**1,758,677 of 1,758,699** tests of the
[SingleStepTests 80386 suite](https://github.com/SingleStepTests/80386),
taken from a real 386EX:
- 32-bit registers and operands (66h), 32-bit addressing with SIB bytes
  (67h), FS and GS.
- The 186 and 286 instructions: PUSHA/POPA, ENTER/LEAVE, PUSH imm,
  IMUL imm, BOUND, INS/OUTS, shifts by an immediate.
- The 386's: MOVZX/MOVSX, SETcc, near Jcc, BT/BTS/BTR/BTC, BSF/BSR,
  SHLD/SHRD, LFS/LGS/LSS, the 0Fh system instructions (SMSW, LGDT/LIDT,
  MOV CRn, CLTS).
- Exceptions as on the real chip: invalid opcode, segment limits (#GP,
  #SS), divide error and BOUND. The faulting instruction is undone and
  restarted after the handler.
- The 386's own ways: shift counts masked to 5 bits, flags bit 15 always
  0 (how programs tell a 386 from an 8086), PUSH SP pushes the old SP,
  and quirks like POPAD loading the top of ESP and SHLD with counts over
  16. The 22 tests left are a self-modifying REP, the 386EX's own I/O
  ports and odd IDIV/AAM corner cases.
- The A20 gate (port 92h, the keyboard controller, INT 15h AX=24xxh).
- About 15 million instructions a second.

**Stage 1 — the CPU.** An Intel 8086/8088 in real mode that passes all
**3,007,000** tests of the
[SingleStepTests 8088 suite](https://github.com/SingleStepTests/8088). The
8088's quirks are in too:

- undocumented opcodes
- `PUSH SP` pushes the new value
- unmasked shift counts
- REP flips IDIV's quotient
- divide errors return to the next instruction

**The mouse.** A mouse driver like MOUSE.COM is built in (INT 33h):
- Position, buttons (left, right and middle), ranges, press and release
  counts, motion counters in mickeys, and the wheel through CuteMouse's
  WheelAPI.
- The text cursor (screen and cursor masks) and the graphics cursor
  (16x16 masks with a hot spot). They're drawn onto the picture, not into
  video memory.
- The user handler programs install with AX=000Ch is called from a mouse
  interrupt, like a PS/2 mouse's, with the registers MOUSE.COM gives it.
- Coordinates are virtual like Microsoft's: 640 wide in every mode.
- In the window, the host's pointer is the PC's mouse. It's hidden while a
  program uses the mouse, since the program draws its own.

**Stage 6 — sound.** Three sound devices, mixed to 44.1 kHz and played
through ViperGui:
- The **PC speaker**: port 61h and timer 2, in every PIT mode, so both
  tones and the 1-bit sample tricks of old games work.
- An **AdLib** (Yamaha OPL2) at 388h: all 9 FM channels with 2 operators,
  envelopes timed from the datasheet, key scaling, tremolo and vibrato,
  feedback, the 4 waveforms, the rhythm mode drums, and the two timers
  games use to detect the card.
- A **Sound Blaster 2.0** at 220h, IRQ 7, DMA 1 (`BLASTER=A220 I7 D1`):
  the DSP's reset, version and speaker commands, direct output, and 8-bit
  DMA in single and auto-init mode, with the 8237 DMA controller and the
  end-of-block interrupt. The AdLib is at 228h too, as on the real card.
- Every change to a chip is stamped with its emulated time, so notes and
  samples land exactly where the program put them.
- `-o fil.wav` records the sound, `-q` turns it off.

**Stage 5 — graphics.** The video card is an IBM VGA:
- Text modes: 40 and 80 columns, 25, 28 or 50 rows.
- CGA 320x200 in 4 colours (both palettes) and 640x200.
- The EGA/VGA 16-colour modes (0Dh, 0Eh, 10h, 12h) in four bit planes,
  with the graphics controller's write modes 0-3, latches, set/reset,
  rotate and logic ops, bit mask, map mask, read modes 0 and 1, and
  scrolling through the CRTC start address and pel panning.
- In the 200-line modes the DAC is set up like a CGA monitor (bit 4 is
  intensity), as the VGA BIOS does, so games like Commander Keen get the
  right colours.
- Mode 13h, 320x200 in 256 colours.
- The DAC (ports 3C7h-3C9h) and the attribute controller's palette, so
  fades and palette tricks work.
- The BIOS draws:
  - pixels with INT 10h AH=0Ch/0Dh
  - text in graphics modes, with an 8x8 font for 200-line modes from the
    public domain font8x8
  - the palette and font services
- The ROM fonts sit where programs look for them (F000:FA6E, INT 1Fh,
  INT 43h).
- The window is 4:3. 320x200 modes are doubled like on a VGA monitor.
  In the terminal, graphics are drawn roughly with half blocks.

**Stage 4 — timer, interrupts and real PC speed.**
- The 8259 interrupt controller and the 8253 timer: IRQ 0 at 18.2 Hz (or
  whatever a game programs it to), read-back of the counters, and timer 2
  with port 61h.
- The keyboard controller: make and break scan codes on port 60h with
  IRQ 1. Games can hook INT 9 and read the keyboard themselves, and the
  BIOS handler turns the codes into keys.
- The BIOS clock is driven by INT 08h, which calls INT 1Ch for programs.
- The video card's retrace bit (port 3DAh) and CRTC cursor registers.
- Time is emulated: every instruction takes a set slice of time.
  - `-x 300` is an IBM PC.
  - `-x 3000` (the default) is a fast 286.
  - `-x max` adjusts the speed to what your machine manages.
- HLT and waiting for keys skip ahead to the next interrupt, so an idle
  program uses almost no host CPU.
- The CPU now takes hardware interrupts, waits one instruction after STI
  and loads of SS, and single-steps with the trap flag (DEBUG's `T`).

**Stage 3 — a ViperGui window.** On a Wayland desktop each program gets
its own window:
- The 80x25 text screen in an 8x16 code page 865 font, like a VGA card's.
  Box drawing, blocks and shades are drawn by rule, so frames join up
  pixel for pixel.
- A blinking cursor in the shape the program sets, and blinking text
  (or bright backgrounds, INT 10h AX=1003h).
- The keyboard as real PC keys, from the order and kind of each key event.
  Shift, Ctrl and Alt combinations are included, and the shift state is
  kept in the BIOS data area.
- `make desktop` puts "Shifu - MS-DOS 2.0" in the app menu.

**Stage 2 — a DOS, written in Hare.** No MS-DOS needed: like DOSBox, Shifu
is the DOS itself.

- `.COM` and `.EXE` (MZ, with relocation) programs, PSP, environment,
  command line, EXEC of child programs (including load-only and overlays),
  return codes, TSR.
- DOS memory as a real MCB chain: allocate, free, resize.
- Files: handles and the old FCB functions, plus:
  - folders
  - FindFirst/FindNext
  - dup/dup2
  - rename and delete
  - file times
- **Drive C: is a folder on your disk.** Names are matched without regard to
  case. æøå are translated: Shifu uses code page 865 (Nordic), as Danish
  PCs did.
- Console: keyboard input with line editing, and Ctrl-C through INT 23h.
- Redirection, like on a real PC: `shifu SORT.EXE < fil.txt` or
  `shifu FIND.EXE ... | less`.
- BIOS:
  - an 80x25 colour text screen in video memory at B800h, so programs that
    write to the screen directly work too
  - INT 10h, INT 16h (keyboard buffer in the BIOS data area), INT 1Ah
- Every interrupt vector points into a small ROM, so programs can hook
  INT 21h and its friends, like on real DOS.

Tested with MS-DOS 2.0's own programs (Microsoft has released them under
the MIT licence): COMMAND.COM, DEBUG, EDLIN, MASM, LINK, FIND, SORT and
MORE. MASM and LINK from 1983 can build a program inside Shifu.

## Run

```sh
shifu PROGRAM.EXE [arguments]      # C: is the program's folder
shifu -c folder GAMES\FOO.EXE      # C: is a folder of your choice
```

| Option | |
|--------|---|
| `-c folder` | the folder that is drive C: |
| `-m KiB` | conventional memory (64-640, default 640). MASM 1.10 needs `-m 256`: it can't count above 512 KiB |
| `-v 2.11` | the DOS version programs are told (default 5.0). Old tools want 2.x |
| `-k text` | type keys for the program (`\n` is Enter), handy for tests |
| `-t` / `-w` | terminal / window (default: a window on a desktop, the terminal otherwise) |
| `-s 1-4` | window scale (default 2: 1280x800) |
| `-q` | no sound |
| `-o fil.wav` | record the sound to a WAV file |
| `-8` | an IBM PC with an 8088 (default: a 386) |
| `-p` | no DPMI host (DOS extenders then use their own) |
| `-x cycles` | speed in instructions per ms, like DOSBox: 300 is an IBM PC, 3000 (default) a fast 286; `max` runs as fast as your machine manages |

**Ctrl-]** stops Shifu. `SHIFU_DEBUG=1` prints every DOS call. At exit,
Shifu lists any DOS calls a program used that aren't there yet.

## Build

Needs Hare 0.25 or newer, with [ViperGui](https://github.com/sunnyscoop300-a11y/vipergui) next to this
folder (`../vipergui`, or `make VIPERGUI=/path/to/vipergui`):

```sh
git clone https://github.com/sunnyscoop300-a11y/vipergui
git clone https://github.com/sunnyscoop300-a11y/shifu
cd shifu && make
```

Everything builds as static, 100 % Hare binaries.

```sh
make             # builds ./shifu and ./sst
make hej         # runs the examples (also: make farver, navn, timer, taster,
                 # vga, cga, ega)
make slange      # Snake, in mode 13h
make musik       # "Mester Jakob" on the speaker, AdLib and Sound Blaster
make tegn        # a little paint program, with the mouse
make cpu         # which CPU is this? (as a 386 and as an 8088)
make beskyt      # into protected mode and back, with 13 checks
make xms         # memory above 1 MB through the XMS driver
make dpmi        # a 32-bit program through the DPMI host, with 9 checks
make test        # unit tests: CPU and DOS
make command     # downloads MS-DOS 2.0's programs and starts COMMAND.COM
make hent-tests  # downloads the CPU test suite (~480 MB)
make cputest     # runs all 3 million 8088 tests (about a minute)
make hent-tests386  # downloads the 80386 test suite (~580 MB)
make cputest386  # runs all 1.76 million 386 tests (about a minute)
make desktop     # "Shifu - MS-DOS 2.0" in the app menu, with an icon
make SDL=1       # with SDL2 too, for windows on X11
```

When the window can't be opened, for example on X11 with the Hare-only
build, Shifu uses the terminal.

The examples in `eksempler/` are assembled with `nasm -f bin`; the built
`.com`/`.exe` files are included.

## Roadmap

1. ✅ 8086 CPU and SingleStepTests
2. ✅ DOS in Hare: programs, memory, files, console, redirection
3. ✅ A ViperGui window: the text screen with a real CP865 font
4. ✅ Timer and interrupts (PIT, PIC, keyboard IRQ), real PC speed
5. ✅ Graphics: CGA, EGA/VGA 16 colours, VGA mode 13h
6. ✅ Sound: PC speaker, AdLib (OPL2), Sound Blaster
7. 386: ✅ the CPU in real mode, ✅ protected mode, paging and XMS,
   ✅ DPMI; next: real 32-bit games (Doom, Duke Nukem 3D) and speed

## Layout

```
x86/cpu.ha       registers, memory, stack, interrupts, ModR/M decoding
x86/alu.ha       arithmetic, shifts, MUL/DIV, BCD, with real 8088 flags
x86/exec.ha      the 8088's opcode map, string instructions
x86/i386.ha      the 386: 32-bit operands and addresses, 0Fh opcodes,
                 exceptions
x86/pmode.ha     protected mode: descriptors, gates, privilege levels,
                 the TSS, paging
pc/machine.ha    memory map, ROM stubs, callbacks
pc/bios.ha       text screen, keyboard, clock (INT 10h, 16h, 1Ah)
pc/dos.ha        INT 21h
pc/loader.ha     PSP, environment, .COM/.EXE, EXEC, terminate
pc/mem.ha        the MCB chain
pc/files.ha      drive C:, paths, handles, FindFirst
pc/fcb.ha        the FCB functions
pc/stdio.ha      redirection to the host's stdin/stdout
pc/charset.ha    code page 865
pc/keyboard.ha   physical keys -> XT scan codes and BIOS keys
pc/hw.ha         the chips: PIC, PIT, keyboard controller, port 61h, CRTC
pc/video.ha      the VGA: modes, planes, registers, palettes, INT 10h
pc/render.ha     the screen as pixels, in every mode
pc/font.ha       8x16 and 8x8 fonts (made by tools/genfont.py)
pc/mouse.ha      the mouse driver (INT 33h)
pc/xms.ha        the XMS driver (like HIMEM.SYS)
pc/dpmi.ha       the DPMI host
pc/sound.ha      the PC speaker and the mixer
pc/opl.ha        the AdLib's OPL2 FM synthesizer
pc/sb.ha         the Sound Blaster DSP and the 8237 DMA controller
cmd/shifu/       frontends: gui.ha (ViperGui window), term.ha (terminal)
tools/           font and icon generators (Python + PIL)
assets/          the Shifu icon
cmd/sst/         SingleStepTests runner (8088)
cmd/sst386/      SingleStepTests runner (80386)
eksempler/       example programs (nasm source + binaries)
```

Inspired by Master Shifu from Kung Fu Panda.

## License

MIT, see [LICENSE](LICENSE). MS-DOS 2.0 (downloaded by `make hent-msdos`)
is Microsoft's, also MIT. No games are included: bring your own.
