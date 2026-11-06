// Shifu — the PC around the CPU: memory map, ROM stubs and BIOS data.
//
// Memory map:
//	0000:0000  interrupt vector table
//	0040:0000  BIOS data area
//	0060:0000  DOS data (InDOS flag, list of lists)
//	0100:0000  first memory control block; programs live from here
//	A000:0000  end of conventional memory (640 KiB)
//	B800:0000  colour text screen
//	F000:0000  ROM: 16 bytes per interrupt vector, mostly "callback n; IRET"
//	F000:1000  the mouse driver's interrupt routine (mouse.ha)
//	F000:1100  the XMS driver's entry point (xms.ha)
//	F000:1180  the DPMI host's real-mode stubs and stack (dpmi.ha)
//
// Callbacks (the emulator-only instruction FE 38 nn nn) call into Hare:
// 0-FFh are interrupt services, 108h the timer tick, 109h the keyboard
// interrupt, 10Ah "end of interrupt" for the PIC, and 10Bh/10Ch start and
// end the mouse driver's calls of a program's handler.
use fmt;
use io;
use os;
use strconv;
use strings;
use x86;

export def ROMSEG: u16 = 0xF000;
export def DOSSEG: u16 = 0x0060;
export def FIRST_MCB: u16 = 0x0100;
export def MEM_TOP: u16 = 0xA000;

// Sets how much conventional memory the PC has, in KiB (64-640; default
// 640). Call before [[start]]. Some old programs misbehave with too much.
export fn set_memory(m: *machine, kib: u16) void = {
	if (kib < 64) kib = 64;
	if (kib > 640) kib = 640;
	set_bda16(m, 0x13, kib);
	mcb_set(m, FIRST_MCB, 'Z', 0, kib * 64 - FIRST_MCB - 1);
};

// The IRET that unused vectors point at (where the IBM BIOS has its own).
def DUMMY_IRET: u16 = 0xFF53;

// Interrupts left for programs: 60h-66h, 68h-6Fh and 78h-FFh.
fn unused_vector(n: u8) bool =
	(n >= 0x60 && n <= 0x66) || (n >= 0x68 && n <= 0x6F) || n >= 0x78;

// Where interrupt n's ROM stub lives.
fn stub_off(n: u8) u16 = n: u16 * 16;

// Services that, like a real BIOS and DOS, turn interrupts back on (STI)
// first, so the timer and keyboard keep going while they wait.
fn sti_first(n: u8) bool = switch (n) {
case 0x10, 0x13, 0x14, 0x15, 0x16, 0x17, 0x1A, 0x20, 0x21, 0x29, 0x2F,
	0x33, 0x67 => yield true;
case => yield false;
};

// Writes "callback num" (FE 38 lo hi) at a; returns the next address.
fn cb(c: *x86::cpu, a: u32, num: u16) u32 = {
	c.mem[a] = 0xFE;
	c.mem[a + 1] = 0x38;
	c.mem[a + 2] = num: u8;
	c.mem[a + 3] = (num >> 8): u8;
	return a + 4;
};

// Writes interrupt n's ROM code; returns the offset of its IRET.
fn build_stub(c: *x86::cpu, n: u8) u16 = {
	let a = x86::linear(ROMSEG, stub_off(n));
	switch (n) {
	case 0x08 => // timer: tick; INT 1Ch; EOI; IRET
		a = cb(c, a, 0x108);
		c.mem[a] = 0xCD;
		c.mem[a + 1] = 0x1C;
		a = cb(c, a + 2, 0x10A);
	case 0x09 => a = cb(c, a, 0x109); // keyboard
	case 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F => a = cb(c, a, 0x10A);
	case =>
		if (sti_first(n)) {
			c.mem[a] = 0xFB;
			a += 1;
		};
		a = cb(c, a, n);
	};
	c.mem[a] = 0xCF; // IRET
	return (a - x86::linear(ROMSEG, 0)): u16;
};

// A DOS error code (see [[strerror]]).
export type doserr = !u16;

export type machine = struct {
	cpu: *x86::cpu,
	// The host folder that is drive C:.
	root: str,
	// The current directory on C:, without the leading backslash.
	cwd: []u8,

	// The program running, and the one Shifu started.
	psp: u16,
	root_psp: u16,
	dta_seg: u16,
	dta_off: u16,
	// Return code of the last program that ended (INT 21h AH=4Dh).
	last_code: u16,
	last_error: u16,

	// Open files, shared by all programs (DOS's system file table).
	sft: []nullable *openfile,
	finds: []search,
	find_id: u16,

	// Keys waiting for room in the BIOS keyboard buffer.
	key_queue: []u16,
	// Console input state.
	line: []u8,
	line_on: bool,
	con_in: []u8,
	ext_key: u8,

	// Redirection to the host (see stdio.ha).
	host_out: io::file,
	out_buf: []u8,
	out_used: bool,
	in_buf: []u8,
	in_part: []u8,
	in_eof: bool,

	// The DOS version programs are told (major, minor).
	version: (u8, u8),

	// Set when the program waits (for a key, or in HLT): time can skip
	// ahead to the next interrupt.
	idle: bool,
	// Callbacks that waited for a key during the last run.
	key_waits: size,
	// Where the IRET of the INT 21h stub is (terminate returns through it).
	iret21: u16,

	// Emulated time: PIT ticks << 16, and how much each instruction takes.
	vtime: u64,
	tpi: u64,
	cycles: u32,
	next_timer: u64,
	pic: pic,
	pic2_imr: u8,
	pit: [3]pitchan,
	port61: u8,
	// Keyboard controller: scan codes waiting (with the BIOS key each make
	// code means), and the one at port 60h.
	kbd_q: [](u8, u16),
	kbd_data: u8,
	kbd_key: u16,
	kbd_full: bool,
	// A keyboard controller command waiting for its data byte (D1h:
	// write the output port, which holds the A20 gate).
	kbc_cmd: u8,
	kbd_next: u64,
	// Modifier keys held on the host keyboard (for working out BIOS keys).
	host_mods: u8,
	// Sound (sound.ha, opl.ha, sb.ha).
	audio_on: bool,
	audio_out: []f32,
	snd_t: u64,
	spk: spkstate,
	spk_ev: []spkstate,
	opl_ev: []oplwrite,
	hp_in: f32,
	hp_out: f32,
	opl: opl,
	sb: sb,
	dma: dma,
	// The mouse driver (mouse.ha) and the XMS driver (xms.ha).
	mouse: mousestate,
	xms: xms,
	// The DPMI host (dpmi.ha), unless turned off.
	dpmi: dpmi,
	no_dpmi: bool,
	// Video card registers (the CRTC here, the rest in vga).
	crtc: [32]u8,
	crtc_index: u8,
	vga: vga,
	// Set when the first program has ended.
	exited: bool,
	exit_code: u8,

	// Print every DOS call to stderr (SHIFU_DEBUG=1).
	debug: bool,
	// Calls programs asked for that Shifu doesn't have yet, as
	// interrupt << 8 | AH.
	missing: []u16,
};

// Makes a PC with C: in the host folder root.
export fn new(root: str) (*machine | nomem) = {
	const c = x86::new()?;
	let m = alloc(machine {
		cpu = c,
		root = root,
		version = (5, 0),
		...
	})?;
	c.user = m;
	c.callback = &on_callback;
	// A 386 AT (set_cpu makes it an 8088 PC).
	x86::set_model(c, x86::model::I386);

	// The ROM, and every vector pointing into it.
	// Vectors no BIOS or DOS service uses all point at one dummy IRET,
	// like on a real PC: DOS extenders (the DOS/4GW stub, for one) look
	// for the free vectors by finding neighbours that are the same.
	c.mem[x86::linear(ROMSEG, DUMMY_IRET)] = 0xCF;
	for (let n = 0z; n < 256; n += 1) {
		const iret = build_stub(c, n: u8);
		if (n == 0x21) m.iret21 = iret;
		const off = if (unused_vector(n: u8)) DUMMY_IRET else stub_off(n: u8);
		x86::write16(c, 0, n: u16 * 4, off);
		x86::write16(c, 0, n: u16 * 4 + 2, ROMSEG);
	};
	// BIOS date and model byte (FF = IBM PC).
	const date = strings::toutf8("11/04/26");
	c.mem[0xFFFF5..0xFFFF5 + len(date)] = date;
	c.mem[0xFFFFE] = 0xFC;

	m.debug = match (os::getenv("SHIFU_DEBUG")) {
	case str => yield true;
	case void => yield false;
	};
	c.ring_on = m.debug;
	// SHIFU_WATCH=seg:off:len prints every write there (for debugging).
	match (os::getenv("SHIFU_WATCH")) {
	case let w: str =>
		const parts = strings::split(w, ":")!;
		defer free(parts);
		if (len(parts) == 3) {
			const seg = hexnum(parts[0]), off = hexnum(parts[1]);
			const n = hexnum(parts[2]);
			c.watch_lo = (seg << 4) + off;
			c.watch_hi = c.watch_lo + n;
			c.log_writes = true;
			c.ring_on = true;
		};
	case void => void;
	};
	match (watch_range("SHIFU_WATCH2")) {
	case let r: (u32, u32) =>
		c.watch2_lo = r.0;
		c.watch2_hi = r.0 + r.1;
		c.log_writes = true;
		if (c.watch_hi == 0) {
			// The first range must be set for the second to count.
			c.watch_lo = 0xFFFFFFFF;
			c.watch_hi = 0xFFFFFFFF;
		};
	case void => void;
	};
	match (watch_range("SHIFU_PEEK")) {
	case let r: (u32, u32) =>
		c.peek_lo = r.0;
		c.peek_n = r.1;
	case void => void;
	};
	set_speed(m, 3000);
	hw_init(m);
	sb_init(m);
	video_init(m);
	bios_init(m);
	mouse_init(m);
	xms_init(m);
	dpmi_init(m);
	mem_init(m);
	files_init(m)?;
	return m;
};

export fn destroy(m: *machine) void = {
	files_close_all(m);
	free(m.cwd);
	free(m.line);
	free(m.con_in);
	finds_free(m);
	free(m.missing);
	free(m.key_queue);
	free(m.kbd_q);
	free(m.vga.planes);
	sound_free(m);
	mouse_free(m);
	xms_free(m);
	dpmi_free(m);
	free(m.out_buf);
	free(m.in_buf);
	free(m.in_part);
	x86::destroy(m.cpu);
	free(m);
};

// Sets the CPU speed in instructions per millisecond, like DOSBox's
// "cycles": 300 is about an IBM PC (4.77 MHz 8088), 3000 (the default) a
// fast 286, 20000 a 486.
export fn set_speed(m: *machine, cycles: u32) void = {
	if (cycles < 50) cycles = 50;
	m.cycles = cycles;
	m.tpi = PIT_HZ * 65536 / 1000 / cycles;
};

export fn speed(m: *machine) u32 = m.cycles;

// Runs n instructions' worth of time (tests use this).
export fn run(m: *machine, n: size) void = {
	run_until(m, m.vtime + n: u64 * m.tpi);
};

// Runs ms milliseconds of emulated time.
export fn run_ms(m: *machine, ms: u64) void = run_us(m, ms * 1000);

// Runs us microseconds of emulated time.
export fn run_us(m: *machine, us: u64) void = {
	run_until(m, m.vtime + us * PIT_HZ / 1000 * 65536 / 1000);
};

fn run_until(m: *machine, target: u64) void = {
	const c = m.cpu;
	m.key_waits = 0;
	key_pump(m);
	for (m.vtime < target && !m.exited) {
		// The PC around the CPU reads and sets flags directly.
		x86::fsync(c);
		const t = m.vtime >> 16;
		if (t >= m.next_timer) timer_event(m);
		if (t >= m.sb.next_irq) sb_block_done(m);
		if (len(m.kbd_q) != 0) kbd_pump(m);
		if (x86::irq_ready(c)) {
			if (m.pic.irr & ~m.pic.imr != 0) match (pic_take(m)) {
			case let v: u8 =>
				c.halted = false;
				m.idle = false;
				if (!dpmi_rm_irq(m, v)) x86::interrupt(c, v);
			case void => void;
			};
			if (len(m.mouse.queue) != 0 && mouse_irq(m)) m.idle = false;
		};
		if (c.halted || m.idle) {
			// Waiting: skip ahead to the next timer tick.
			m.idle = false;
			let next = m.next_timer;
			if (m.sb.next_irq < next) next = m.sb.next_irq;
			let to = next << 16;
			if (to > target) to = target;
			if (to <= m.vtime) to = m.vtime + m.tpi;
			m.vtime = to;
			continue;
		};
		// A run of instructions up to the next thing that can happen:
		// a timer or Sound Blaster interrupt, or one the program allowed
		// (an IRQ waiting with interrupts on), or a key to deliver.
		let limit = m.next_timer << 16;
		if (m.sb.next_irq << 16 < limit) limit = m.sb.next_irq << 16;
		if (target < limit) limit = target;
		// Interrupts and keys are looked for every 8 instructions:
		// soon enough, and much cheaper than after each one.
		let k = 0u32;
		for (true) {
			x86::step(c);
			m.vtime += m.tpi;
			if (m.vtime >= limit || c.halted || m.idle || m.exited) break;
			k += 1;
			if (k & 7 != 0) continue;
			if (c.flags & x86::IF != 0 && (m.pic.irr & ~m.pic.imr != 0 ||
				len(m.mouse.queue) != 0)) break;
			if (len(m.kbd_q) != 0 && !m.kbd_full) break;
		};
		// Every 50 million instructions: where the program is.
		static let next_dump = 50000000u64;
		if (m.debug && c.count >= next_dump) {
			next_dump = c.count + 50000000;
			fmt::errorfln("  [{} mio. instr.]", c.count / 1000000)!;
			x86::dump(c);
			dpmi_status(m);
		};
	};
	x86::fsync(c);
	sound_render(m);
	flush(m);
};

// Whether the program spent the last run waiting for a key, with none on
// the way.
export fn waiting_for_key(m: *machine) bool =
	m.key_waits > 0 && len(m.kbd_q) == 0 && len(m.key_queue) == 0 &&
	!m.kbd_full && !key_ready(m);

// seg:off:len from an environment variable (hex), as (address, length).
fn watch_range(var: str) ((u32, u32) | void) = {
	const w = match (os::getenv(var)) {
	case let w: str => yield w;
	case void => return;
	};
	const parts = strings::split(w, ":")!;
	defer free(parts);
	if (len(parts) != 3) return;
	return ((hexnum(parts[0]) << 4) + hexnum(parts[1]), hexnum(parts[2]));
};

fn hexnum(s: str) u32 = match (strconv::stou32(s, strconv::base::HEX)) {
case let v: u32 => yield v;
case => yield 0;
};

// Prints the CPU's state to stderr (with SHIFU_DEBUG: also the last
// instructions).
export fn dump(m: *machine) void = x86::dump(m.cpu);

// SHIFU_FIND=text: at the end, where the text is in memory and which
// instructions push its address (PUSH imm32), with the 24 bytes before
// them (for debugging: that finds the variables a printf prints).
export fn debug_find(m: *machine) void = {
	const c = m.cpu;
	if (c.peek_n > 0) {
		fmt::errorf("PEEK til sidst {:_06X}:", c.peek_lo)!;
		for (let i = 0u32; i < c.peek_n; i += 1) {
			if (i % 4 == 0) fmt::errorf(" ")!;
			fmt::errorf("{:_02X}", c.mem[(c.peek_lo + i) & 0xFFFFFF])!;
		};
		fmt::errorln()!;
	};
	const text = match (os::getenv("SHIFU_FIND")) {
	case let t: str => yield strings::toutf8(t);
	case void => return;
	};
	const mem = m.cpu.mem;
	let found = 0;
	for (let a = 0z; a + len(text) < len(mem) && found < 4; a += 1) {
		if (mem[a] != text[0] || !bytes_at(mem, a, text)) continue;
		found += 1;
		fmt::errorfln("FIND tekst ved {:_06X}", a)!;
		const want: [5]u8 = [0x68, a: u8, (a >> 8): u8, (a >> 16): u8, (a >> 24): u8];
		let pushes = 0;
		for (let b = 24z; b + 5 < len(mem) && pushes < 4; b += 1) {
			if (mem[b] != 0x68 || !bytes_at(mem, b, want)) continue;
			pushes += 1;
			fmt::errorf("FIND push ved {:_06X}:", b)!;
			for (let k = b - 24; k < b + 10; k += 1) fmt::errorf(" {:_02X}", mem[k])!;
			fmt::errorln()!;
		};
	};
};

fn bytes_at(mem: []u8, a: size, want: []u8) bool = {
	for (let i = 0z; i < len(want); i += 1) if (mem[a + i] != want[i]) return false;
	return true;
};

// Makes the PC an IBM PC with an 8088 or an AT-class PC with a 386 (the
// default for Shifu's frontend). Call before [[start]].
export fn set_cpu(m: *machine, model: x86::model) void = {
	const c = m.cpu;
	x86::set_model(c, model);
	x86::set_a20(c, false);
	// The BIOS model byte: FF is an IBM PC, FC an AT.
	c.mem[0xFFFFE] = if (model == x86::model::I386) 0xFC else 0xFF;
	// The equipment word: the 386 has a 387 beside it.
	const eq = x86::read16(c, 0x40, 0x10);
	x86::write16(c, 0x40, 0x10, if (model == x86::model::I386) eq | 2 else eq & ~2u16);
};

export fn cpu_model(m: *machine) x86::model = m.cpu.model;

// Turns Shifu's DPMI host off (DOS extenders then use their own, over
// XMS).
export fn set_dpmi(m: *machine, on: bool) void = {
	m.no_dpmi = !on;
};

// Sets the DOS version programs see (default 5.0; old tools want 2.x).
export fn set_version(m: *machine, major: u8, minor: u8) void = {
	m.version = (major, minor);
};

fn on_callback(c: *x86::cpu, n: u16) void = {
	const m = c.user: *machine;
	let fin = true;
	switch (n) {
	case 0x00 => fin = divide_overflow(m);
	case 0x10 =>
		const ah = x86::get8(c, 4);
		if (m.debug && (ah == 0x00 || ah == 0x4F)) {
			fmt::errorfln("INT 10 AX={:_04X} BX={:_04X} CX={:_04X} DX={:_04X} ES:DI={:_04X}:{:_04X}",
				c.r[x86::AX], c.r[x86::BX], c.r[x86::CX], c.r[x86::DX],
				c.s[x86::ES], c.r[x86::DI])!;
		};
		fin = int10(m);
		if (m.debug && (ah == 0x00 || ah == 0x4F)) {
			fmt::errorfln("  -> AX={:_04X} BX={:_04X}", c.r[x86::AX], c.r[x86::BX])!;
		};
	case 0x11 => c.r[x86::AX] = x86::read16(c, 0x40, 0x10);
	case 0x12 => c.r[x86::AX] = x86::read16(c, 0x40, 0x13);
	case 0x13, 0x15 => fin = int13_15(m, n: u8);
	case 0x14, 0x17 => x86::set8(c, 4, 0);
	case 0x16 => fin = int16(m);
	case 0x1A => fin = int1a(m);
	case 0x20 => terminate(m, 0, false, 0);
	case 0x21 =>
		if (m.debug) {
			fmt::errorfln("INT 21 AX={:_04X} BX={:_04X} CX={:_04X} DX={:_04X} DS={:_04X} fra {:_04X}:{:_04X}",
				c.r[x86::AX], c.r[x86::BX], c.r[x86::CX], c.r[x86::DX],
				c.s[x86::DS], x86::read16(c, c.s[x86::SS], c.r[x86::SP] + 2),
				x86::read16(c, c.s[x86::SS], c.r[x86::SP]))!;
			// Calls that take a file name: show it.
			switch (x86::get8(c, 4)) {
			case 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x41, 0x43, 0x4B, 0x4E,
				0x56, 0x5A, 0x5B, 0x6C =>
				const at = if (x86::get8(c, 4) == 0x6C) c.r[x86::SI] else c.r[x86::DX];
				const name = read_asciiz(m, c.s[x86::DS], at);
				fmt::errorfln("  navn: \"{}\"", strings::fromutf8_unsafe(name))!;
				free(name);
			case => void;
			};
		};
		// Like MS-DOS, remember the caller's stack in its PSP on every
		// call: terminating a child returns to the parent through it.
		if (m.psp != 0) {
			x86::write16(c, m.psp, 0x2E, c.r[x86::SP]);
			x86::write16(c, m.psp, 0x30, c.s[x86::SS]);
		};
		fin = int21(m);
		if (m.debug) {
			fmt::errorfln("  -> AX={:_04X} SS:SP={:_04X}:{:_04X} ramme {:_04X}:{:_04X} flag {:_04X}",
				c.r[x86::AX], c.s[x86::SS], c.r[x86::SP],
				x86::read16(c, c.s[x86::SS], c.r[x86::SP] + 2),
				x86::read16(c, c.s[x86::SS], c.r[x86::SP]),
				x86::read16(c, c.s[x86::SS], c.r[x86::SP] + 4))!;
		};
	case 0x29 => tty_out(m, x86::get8(c, 0));
	case 0x2F => int2f(m);
	case 0x33 => fin = int33(m);
	case 0x67 => x86::set8(c, 4, 0x84); // no EMS
	case 0x108 => timer_tick(m);
	case 0x109 => keyboard_irq(m);
	case 0x10A => pic_eoi(m);
	case 0x10B => mouse_isr_begin(m);
	case 0x10C => mouse_isr_end(m);
	case 0x10D => xms_call(m);
	case =>
		if (n >= 0x110 && n < 0x500) dpmi_callback(m, n);
	};
	if (!fin) {
		// Not ready yet (waiting for a key): run this callback again.
		c.ip -= 4;
		m.idle = true;
		m.key_waits += 1;
	};
};

// The flags the interrupted program gets back are on the stack, so that
// is where results like CF and ZF go.
fn ret_flag(m: *machine, f: u16, on: bool) void = {
	const c = m.cpu;
	const sp = c.r[x86::SP] + 4;
	let v = x86::read16(c, c.s[x86::SS], sp);
	if (on) v |= f else v &= ~f;
	x86::write16(c, c.s[x86::SS], sp, v);
};

// Ends a call with success (CF clear).
fn ok(m: *machine) bool = {
	ret_flag(m, x86::CF, false);
	return true;
};

// Ends a call with a DOS error: CF set, AX = code.
fn fail(m: *machine, code: u16) bool = {
	m.cpu.r[x86::AX] = code;
	m.last_error = code;
	ret_flag(m, x86::CF, true);
	return true;
};

fn divide_overflow(m: *machine) bool = {
	con_str(m, "\r\nDivide overflow\r\n");
	terminate(m, 0xFF, false, 0);
	return true;
};

// Notes a call Shifu doesn't have, once.
fn missing(m: *machine, n: u8, ah: u8) void = {
	const k = n: u16 << 8 | ah: u16;
	for (let s .. m.missing) if (s == k) return;
	append(m.missing, k)!;
};

// The calls programs made that Shifu doesn't have yet (interrupt << 8 | AH).
export fn missing_calls(m: *machine) []u16 = m.missing;

// A DOS error code in words.
export fn strerror(e: doserr) str = {
	switch (e: u16) {
	case 1 => return "ugyldig funktion";
	case 2 => return "filen findes ikke";
	case 3 => return "stien findes ikke";
	case 4 => return "for mange åbne filer";
	case 5 => return "adgang nægtet";
	case 6 => return "ugyldigt handle";
	case 7 => return "hukommelseskæden er ødelagt";
	case 8 => return "ikke nok hukommelse";
	case 9 => return "ugyldig hukommelsesblok";
	case 0x0F => return "ugyldigt drev";
	case 0x12 => return "ikke flere filer";
	case 0x50 => return "filen findes allerede";
	case => return "DOS-fejl";
	};
};
export fn dbg_count(m: *machine) u64 = m.cpu.count;
