// Tests for the DOS and BIOS: they run the example programs in
// eksempler/ (run "make test" from the project folder).
use fs;
use io;
use memio;
use os;
use path;
use strings;
use temp;
use x86;

fn run_prog(dir: str, prog: str, tail: str, keys: str = "") *machine = {
	const m = new(dir)!;
	start(m, prog, tail)!;
	for (let r .. strings::toutf8(keys)) {
		push_key(m, if (r == '\n') 0x1C0D else r: u16);
	};
	for (let i = 0; i < 1000 && !m.exited; i += 1) run(m, 100000);
	return m;
};

// The text on a screen row, without trailing spaces.
fn row_text(m: *machine, r: u8) str = {
	let s = memio::dynamic();
	for (let c = 0u8; c < text_size(m).0; c += 1) {
		memio::appendrune(&s, CHARSET[cell(m, c, r).0])!;
	};
	return strings::rtrim(memio::string(&s)!);
};

fn screen_has(m: *machine, want: str) bool = {
	for (let r = 0u8; r < text_size(m).1; r += 1) {
		const t = row_text(m, r);
		const found = strings::contains(t, want);
		free(t);
		if (found) return true;
	};
	return false;
};

@test fn hello_world() void = {
	const m = run_prog("eksempler", "HEJ.COM", "");
	defer destroy(m);
	assert(m.exited && m.exit_code == 0);
	assert(screen_has(m, "Hej fra Shifu!"));
	assert(screen_has(m, "1 4 9 16 25 36 49 64 81 100 121 144"));
};

@test fn exe_relocation_memory_and_exec() void = {
	const m = run_prog("eksempler", "mzdemo.exe", "hej Bossun");
	defer destroy(m);
	assert(m.exited && m.exit_code == 7);
	assert(screen_has(m, "Kommandolinje: [ hej Bossun]"));
	assert(screen_has(m, "Mit fulde navn: C:\\MZDEMO.EXE"));
	assert(screen_has(m, "HEJ.COM sluttede med kode 0000"));
};

@test fn keyboard_line_input() void = {
	const m = run_prog("eksempler", "NAVN.COM", "", "Bossun\nx");
	defer destroy(m);
	assert(m.exited);
	assert(screen_has(m, "Hej, Bossun! Velkommen til Shifu."));
};

@test fn files_and_folders() void = {
	// Run FILER.COM in a fresh folder so it doesn't touch eksempler/.
	const dir = temp::dir();
	defer os::rmdirall(dir)!;
	const src = os::open("eksempler/filer.com")!;
	defer io::close(src)!;
	let to = path::init(dir, "filer.com")!;
	const dst = os::create(path::string(&to), 0o644)!;
	io::copy(dst, src)!;
	io::close(dst)!;

	const m = run_prog(dir, "FILER.COM", "");
	defer destroy(m);
	assert(m.exit_code == 0);
	assert(screen_has(m, "Filen er 38 bytes"));
	assert(screen_has(m, "Hej fra en DOS-fil! æøå virker også."));
	assert(screen_has(m, "MAPPE         <MAPPE>"));
	let made = path::init(dir, "MAPPE")!;
	assert(fs::isdir(os::stat(path::string(&made))!.mode));
};

@test fn memory_chain() void = {
	const m = new(".")!;
	defer destroy(m);
	set_memory(m, 256);
	const a = mem_alloc(m, 0x100, 0x50) as u16;
	const b = mem_alloc(m, 0x200, 0x50) as u16;
	assert(b == a + 0x101);
	mem_free(m, a)!;
	// Too big: fails and says how much there is.
	match (mem_alloc(m, 0xF000, 0x50)) {
	case u16 => abort();
	case let e: (u16, doserr) =>
		assert(e.1 == 8);
		assert(e.0 == 256 * 64 - FIRST_MCB - 1 - 0x100 - 1 - 0x200 - 1);
	};
	// The freed block is reused, and blocks can shrink and grow back.
	assert(mem_alloc(m, 0x80, 0x50) as u16 == a);
	assert(mem_resize(m, b, 0x10) is void);
	assert(mem_resize(m, b, 0x300) is void);
	mem_free_owner(m, 0x50);
	assert(mcb_owner(m, FIRST_MCB) == 0);
};

@test fn fcb_patterns() void = {
	const p = fcb_pattern(strings::toutf8("*.COM"));
	assert(strings::fromutf8_unsafe(p) == "????????COM");
	const q = fcb_pattern(strings::toutf8("hej.c*"));
	assert(strings::fromutf8_unsafe(q) == "HEJ     C??");
	assert(fcb_match(&p, strings::toutf8("COMMAND.COM")));
	assert(!fcb_match(&p, strings::toutf8("SORT.EXE")));
};

@test fn charset_is_nordic() void = {
	assert(CHARSET[0x91] == 'æ' && CHARSET[0x9B] == 'ø' && CHARSET[0x86] == 'å');
	assert(from_unicode('Ø') as u8 == 0x9D);
	assert(upper(0x9B) == 0x9D);
};


@test fn keyboard_mapping() void = {
	assert(bios_key_for(0, 4, 'a') == 0x1E61);
	assert(bios_key_for(LSHIFT, 58, '\0') == 0x5400);  // Shift+F1
	assert(bios_key_for(0, 82, '\0') == 0x4800);       // up arrow
	assert(bios_key_for(CTRL, 6, '\0') == 0x2E03);     // Ctrl+C
	assert(bios_key_for(ALT, 19, '\0') == 0x1900);     // Alt+P
	assert(bios_key_for(0, 52, 'ø') == 0x289B);        // ø, Danish layout
	assert(bios_key_for(0, 40, '\0') == 0x1C0D);       // Enter
	assert(bios_key_for(0, 225, '\0') == 0);           // Shift alone
};

// Types through the whole chain: key events -> scan codes on port 60h ->
// IRQ 1 -> the BIOS's INT 9 -> keyboard buffer -> DOS.
@test fn keys_through_irq1() void = {
	const m = new("eksempler")!;
	defer destroy(m);
	start(m, "NAVN.COM", "")!;
	const keys: [_](u16, rune) = [(225, '\0'), (5, 'B'), (225, '\0'),
		(18, 'o'), (22, 's'), (22, 's'), (24, 'u'), (17, 'n'), (40, '\0'),
		(27, 'x')];
	let shift = false;
	for (let (hid, text) .. keys) {
		if (hid == 225) {
			shift = !shift;
			key_event(m, hid, shift, '\0');
			continue;
		};
		key_event(m, hid, true, text);
		key_event(m, hid, false, '\0');
	};
	for (let i = 0; i < 100 && !m.exited; i += 1) run_ms(m, 50);
	assert(m.exited);
	assert(screen_has(m, "Hej, Bossun! Velkommen til Shifu."));
	assert(bda8(m, 0x17) == 0); // shift was released
};

// IRQ 0 runs the BIOS clock at 18.2 ticks a second of emulated time.
@test fn timer_ticks() void = {
	const m = new("eksempler")!;
	defer destroy(m);
	start(m, "NAVN.COM", "")!; // waits for input; time goes on
	const t0 = bda16(m, 0x6C): u32 | bda16(m, 0x6E): u32 << 16;
	run_ms(m, 10000);
	const t1 = bda16(m, 0x6C): u32 | bda16(m, 0x6E): u32 << 16;
	assert(t1 - t0 >= 181 && t1 - t0 <= 183);
};

// A program sets the PIT to 1000 Hz and hooks INT 8, like games do.
@test fn programmed_timer() void = {
	const m = new("eksempler")!;
	defer destroy(m);
	start(m, "TIMER.COM", "")!;
	const t0 = m.vtime >> 16;
	for (let i = 0; i < 100 && !m.exited; i += 1) run_ms(m, 100);
	assert(m.exited);
	assert(screen_has(m, "2000 tik"));
	// 2000 ticks at 1000 Hz: about 2 seconds.
	const t = (m.vtime >> 16) - t0;
	assert(t >= PIT_HZ * 19 / 10 && t <= PIT_HZ * 21 / 10);
	// The BIOS clock kept going (the program chains to it).
	assert(m.pit[0].reload == 65536);
};

// A program hooks INT 9 and reads make and break codes from port 60h.
@test fn raw_scan_codes() void = {
	const m = new("eksempler")!;
	defer destroy(m);
	start(m, "TASTER.COM", "")!;
	run_ms(m, 100);
	key_event(m, 4, true, 'a');   // A: 1E
	key_event(m, 4, false, '\0'); // 9E
	key_event(m, 79, true, '\0'); // right arrow: E0 4D
	key_event(m, 79, false, '\0');
	key_event(m, 41, true, '\0'); // Esc: 01 ends it
	key_event(m, 41, false, '\0');
	for (let i = 0; i < 100 && !m.exited; i += 1) run_ms(m, 50);
	assert(m.exited);
	assert(screen_has(m, "1E 9E E0 4D E0 CD 01"));
};

// Mode 13h: a pixel through the DAC, set with the VGA's ports.
@test fn vga_mode_13h() void = {
	const m = new(".")!;
	defer destroy(m);
	set_mode(m, 0x13, true);
	m.cpu.mem[0xA0000 + 10 * 320 + 5] = 200;
	port_out(m.cpu, 0x3C8, 200);
	port_out(m.cpu, 0x3C9, 63);
	port_out(m.cpu, 0x3C9, 32);
	port_out(m.cpu, 0x3C9, 0);
	let pix: [MAX_W * MAX_H]u32 = [0...];
	const pic = render(m, pix, 0);
	assert(pic.w == 320 && pic.h == 200 && pic.xrep == 2 && pic.yrep == 2);
	assert(pix[10 * MAX_W + 5] == 0xFFFF8200);
	// The default palette: colour 4 is CGA red.
	m.cpu.mem[0xA0000] = 4;
	render(m, pix, 0);
	assert(pix[0] == 0xFFAA0000);
};

// EGA/VGA planes: write modes 0 (with set/reset), 1 (latch copy) and 2,
// read mode 1 (colour compare).
@test fn vga_planes() void = {
	const m = new(".")!;
	defer destroy(m);
	set_mode(m, 0x12, true);
	const c = m.cpu;
	// Write mode 2: colour 5 (planes 0 and 2) in the left 4 pixels.
	port_out(c, 0x3CE, 5);
	port_out(c, 0x3CF, 2);
	port_out(c, 0x3CE, 8);
	port_out(c, 0x3CF, 0xF0);
	x86::wb(c, 0xA0000, 5);
	assert(m.vga.planes[0] == 0xF0 && m.vga.planes[0x20000] == 0xF0);
	assert(m.vga.planes[0x10000] == 0 && m.vga.planes[0x30000] == 0);
	// Write mode 1: copy byte 0 to byte 1 through the latches.
	port_out(c, 0x3CF, 0xFF); // bit mask back
	port_out(c, 0x3CE, 5);
	port_out(c, 0x3CF, 1);
	x86::rb(c, 0xA0000);
	x86::wb(c, 0xA0001, 0);
	assert(m.vga.planes[1] == 0xF0 && m.vga.planes[0x20001] == 0xF0);
	// Read mode 1: where is colour 5?
	port_out(c, 0x3CF, 0x08);
	port_out(c, 0x3CE, 2);
	port_out(c, 0x3CF, 5);
	assert(x86::rb(c, 0xA0000) == 0xF0);
	// Write mode 0 with set/reset for all planes: colour 12.
	port_out(c, 0x3CE, 5);
	port_out(c, 0x3CF, 0);
	port_out(c, 0x3CE, 0);
	port_out(c, 0x3CF, 12);
	port_out(c, 0x3CE, 1);
	port_out(c, 0x3CF, 0x0F);
	x86::wb(c, 0xA0002, 0);
	assert(gfx_get(m, 16, 0) == 12 && gfx_get(m, 23, 0) == 12);
	// And it shows: pixel 0 is magenta (5), pixel 16 light red (12).
	let pix: [MAX_W * MAX_H]u32 = [0...];
	render(m, pix, 0);
	assert(pix[0] == 0xFFAA00AA && pix[16] == 0xFFFF5555);
};

// CGA: interlaced memory and the palettes.
@test fn cga_mode_4() void = {
	const m = new(".")!;
	defer destroy(m);
	set_mode(m, 4, true);
	gfx_set(m, 1, 1, 3); // odd line: second bank
	assert(m.cpu.mem[0xBA000] == 0x30);
	assert(gfx_get(m, 1, 1) == 3);
	let pix: [MAX_W * MAX_H]u32 = [0...];
	render(m, pix, 0);
	assert(pix[MAX_W + 1] == 0xFFFFFFFF); // bright white (palette 1)
	m.vga.cga_color = 0x00; // palette 0, dim: colour 3 is brown
	render(m, pix, 0);
	assert(pix[MAX_W + 1] == 0xFFAA5500);
};

// Text mode through the font: the top of an 'A'.
@test fn text_render() void = {
	const m = new(".")!;
	defer destroy(m);
	x86::write16(m.cpu, VSEG, 0, 0x1F41); // white 'A' on blue
	let pix: [MAX_W * MAX_H]u32 = [0...];
	const pic = render(m, pix, 16); // a frame with the cursor off
	assert(pic.w == 640 && pic.h == 400);
	for (let y = 0z; y < 16; y += 1) for (let x = 0z; x < 8; x += 1) {
		const on = FONT16[0x41][y] & (0x80u8 >> x: u8) != 0;
		assert(pix[y * MAX_W + x] == (if (on) 0xFFFFFFFFu32 else 0xFF0000AAu32));
	};
};

// The demos run: VGA.COM rotates the palette until a key, SLANGE.COM is
// a game that ends on Esc.
@test fn graphics_programs() void = {
	const m = new("eksempler")!;
	defer destroy(m);
	start(m, "VGA.COM", "")!;
	run_ms(m, 500);
	assert(video_mode(m) == 0x13);
	const before = m.vga.dac[40];
	run_ms(m, 100);
	assert(m.vga.dac[40][0] != before[0] || m.vga.dac[40][1] != before[1] ||
		m.vga.dac[40][2] != before[2]); // it rotates
	type_key(m, 0x1C0D);
	run_ms(m, 200);
	assert(m.exited && video_mode(m) == 3);

	const g = new("eksempler")!;
	defer destroy(g);
	start(g, "SLANGE.COM", "")!;
	run_ms(g, 1000);
	assert(video_mode(g) == 0x13);
	key_event(g, 41, true, '\0'); // Esc
	key_event(g, 41, false, '\0');
	run_ms(g, 500);
	assert(g.exited && screen_has(g, "Tak for spillet!"));
};

// Lets emulated time pass with the CPU halted (interrupts off).
fn wait_ms(m: *machine, ms: u64) void = {
	m.cpu.halted = true;
	m.cpu.flags &= ~x86::IF;
	run_ms(m, ms);
};

fn crossings(s: []f32) size = {
	let n = 0z;
	for (let i = 1z; i < len(s); i += 1) {
		if ((s[i - 1] < 0.0) != (s[i] < 0.0)) n += 1;
	};
	return n;
};

fn oplw(m: *machine, reg: u8, val: u8) void = {
	port_out(m.cpu, 0x388, reg);
	port_out(m.cpu, 0x389, val);
};

// The usual AdLib check: timer 1 must overflow after 80 µs.
@test fn adlib_detection() void = {
	const m = new(".")!;
	defer destroy(m);
	oplw(m, 4, 0x60);
	oplw(m, 4, 0x80);
	const s1 = port_in(m.cpu, 0x388);
	oplw(m, 2, 0xFF);
	oplw(m, 4, 0x21);
	wait_ms(m, 1);
	const s2 = port_in(m.cpu, 0x388);
	oplw(m, 4, 0x60);
	oplw(m, 4, 0x80);
	assert(s1 & 0xE0 == 0x00);
	assert(s2 & 0xE0 == 0xC0);
};

// A 440 Hz note on channel 0: a sine carrier, a silent modulator.
@test fn adlib_note() void = {
	const m = new(".")!;
	defer destroy(m);
	enable_audio(m, true);
	oplw(m, 0x20, 0x21);
	oplw(m, 0x40, 0x3F);
	oplw(m, 0x60, 0xF0);
	oplw(m, 0x23, 0x21);
	oplw(m, 0x43, 0x00);
	oplw(m, 0x63, 0xF0);
	oplw(m, 0xC0, 0x00);
	oplw(m, 0xA0, 0x44);   // F-number 580, block 4: 440 Hz
	oplw(m, 0xB0, 0x32);
	wait_ms(m, 50);
	take_audio(m);
	wait_ms(m, 100);
	const s = take_audio(m);
	assert(len(s) >= 4400 && len(s) <= 4420);
	const n = crossings(s);
	assert(n >= 84 && n <= 92); // 44 cycles: 88 crossings
	let peak = 0.0f32;
	for (let v .. s) if (v > peak) peak = v;
	assert(peak > 0.1);
	oplw(m, 0xB0, 0x12);   // key off: it fades away
	wait_ms(m, 100);
	take_audio(m);
};

// The PC speaker: timer 2 at 1000 Hz, port 61h bits 0 and 1 on.
@test fn speaker_tone() void = {
	const m = new(".")!;
	defer destroy(m);
	enable_audio(m, true);
	port_out(m.cpu, 0x43, 0xB6);
	port_out(m.cpu, 0x42, 0xA9); // 1193
	port_out(m.cpu, 0x42, 0x04);
	port_out(m.cpu, 0x61, port_in(m.cpu, 0x61) | 3);
	wait_ms(m, 20);
	take_audio(m);
	wait_ms(m, 100);
	const n = crossings(take_audio(m));
	assert(n >= 195 && n <= 205);
	port_out(m.cpu, 0x61, port_in(m.cpu, 0x61) & 0xFC); // off
	wait_ms(m, 50);
	take_audio(m);
	wait_ms(m, 50);
	for (let v .. take_audio(m)) assert(v < 0.05 && v > -0.05);
};

// The Sound Blaster: reset, version, and a DMA block that plays for
// 100 ms and then raises IRQ 7.
@test fn soundblaster() void = {
	const m = new(".")!;
	defer destroy(m);
	enable_audio(m, true);
	const c = m.cpu;
	port_out(c, 0x226, 1);
	port_out(c, 0x226, 0);
	assert(port_in(c, 0x22E) & 0x80 != 0);
	assert(port_in(c, 0x22A) == 0xAA);
	port_out(c, 0x22C, 0xE1);
	assert(port_in(c, 0x22A) == 2 && port_in(c, 0x22A) == 1);

	for (let i = 0u32; i < 1000; i += 1) c.mem[0x10000 + i] = 192;
	port_out(c, 0x0A, 0x05);  // mask channel 1
	port_out(c, 0x0B, 0x49);  // single, memory to card, channel 1
	port_out(c, 0x0C, 0);
	port_out(c, 0x02, 0x00);  // address 0000
	port_out(c, 0x02, 0x00);
	port_out(c, 0x03, 0xE7);  // count 999
	port_out(c, 0x03, 0x03);
	port_out(c, 0x83, 0x01);  // page 1
	port_out(c, 0x0A, 0x01);  // unmask
	port_out(c, 0x22C, 0xD1); // speaker on
	port_out(c, 0x22C, 0x40); // 10 kHz
	port_out(c, 0x22C, 156);
	port_out(c, 0x22C, 0x14); // 1000 bytes
	port_out(c, 0x22C, 0xE7);
	port_out(c, 0x22C, 0x03);
	wait_ms(m, 50);
	assert(m.pic.irr & 0x80 == 0);
	const s = take_audio(m);
	assert(s[len(s) / 2] > 0.3); // (192 - 128) / 128 * 0.7
	wait_ms(m, 60);
	assert(m.pic.irr & 0x80 != 0); // done: IRQ 7
	assert(!m.sb.playing);
};

// Calls INT 33h function ax with BX, CX, DX, the way a program would.
fn mcall(m: *machine, ax: u16, bx: u16 = 0, cx: u16 = 0, dx: u16 = 0) void = {
	m.cpu.r[x86::AX] = ax;
	m.cpu.r[x86::BX] = bx;
	m.cpu.r[x86::CX] = cx;
	m.cpu.r[x86::DX] = dx;
	int33(m);
};

// The mouse driver's functions: reset, position, ranges, buttons, mickeys.
@test fn mouse_driver() void = {
	const m = new("eksempler")!;
	defer destroy(m);
	set_mode(m, 3, true);
	mcall(m, 0);
	assert(m.cpu.r[x86::AX] == 0xFFFF && m.cpu.r[x86::BX] == 2);
	assert(mouse_used(m));

	// 80x25 text is 640x200 virtual units.
	mouse_move(m, 0.5, 0.25);
	mcall(m, 3);
	assert(m.cpu.r[x86::CX] == 320 && m.cpu.r[x86::DX] == 50);
	// 320 units right, 50 down: 320 mickeys across (8 per 8 units) and
	// 100 down (16 per 8).
	mcall(m, 0x0B);
	mouse_move(m, 1.0, 0.5);
	mcall(m, 0x0B);
	assert(m.cpu.r[x86::CX] == 320 && m.cpu.r[x86::DX] == 100);
	// The range clips the position.
	mcall(m, 3);
	assert(m.cpu.r[x86::CX] == 639);
	mcall(m, 7, 0, 300, 100);
	mcall(m, 3);
	assert(m.cpu.r[x86::CX] == 300);
	mcall(m, 4, 0, 10, 20);
	mcall(m, 3);
	assert(m.cpu.r[x86::CX] == 100 && m.cpu.r[x86::DX] == 20);

	// Two left clicks and one right; AX=5 counts the presses.
	mouse_buttons(m, 1);
	mouse_buttons(m, 0);
	mouse_buttons(m, 3);
	mcall(m, 3);
	assert(m.cpu.r[x86::BX] & 0xFF == 3);
	mouse_buttons(m, 0);
	mcall(m, 5, 0);
	assert(m.cpu.r[x86::BX] == 2 && m.cpu.r[x86::CX] == 100);
	mcall(m, 5, 0);
	assert(m.cpu.r[x86::BX] == 0);
	mcall(m, 6, 1);
	assert(m.cpu.r[x86::BX] == 1);

	// The wheel (CuteMouse's API): one step down shows in BH.
	mcall(m, 0x11);
	assert(m.cpu.r[x86::AX] == 0x574D);
	mouse_wheel(m, -1);
	mcall(m, 3);
	assert(m.cpu.r[x86::BX] >> 8 == 1);

	// The text cursor shows once AX=1 brings the level to 0.
	assert(!mouse_visible(m));
	mcall(m, 1);
	assert(mouse_visible(m));
	mcall(m, 2);
	mcall(m, 2);
	mcall(m, 1);
	assert(!mouse_visible(m));
	// Mode 13h is 640x200 too; mode 12h 640x480.
	set_mode(m, 0x12, true);
	mcall(m, 0x26);
	assert(m.cpu.r[x86::CX] == 639 && m.cpu.r[x86::DX] == 479);
};

// TEGN.COM draws with the mouse in mode 13h and counts clicks in the
// handler it installs with AX=000Ch.
@test fn mouse_paint() void = {
	const m = new("eksempler")!;
	defer destroy(m);
	start(m, "TEGN.COM", "")!;
	run_ms(m, 200);
	assert(video_mode(m) == 0x13);
	mouse_move(m, 0.25, 0.5);  // pixel (80, 100)
	run_ms(m, 50);
	mouse_buttons(m, 1);
	run_ms(m, 50);
	mouse_move(m, 0.5, 0.5);   // a line to (160, 100)
	run_ms(m, 50);
	mouse_buttons(m, 0);
	run_ms(m, 50);
	const px = m.cpu.mem[0xA0000 + 100 * 320 + 120];
	assert(px == 15);
	assert(m.cpu.mem[0xA0000 + 50 * 320 + 120] == 0);
	// Two right clicks: white (15) wraps round to blue (1).
	for (let i = 0; i < 2; i += 1) {
		mouse_buttons(m, 2);
		run_ms(m, 50);
		mouse_buttons(m, 0);
		run_ms(m, 50);
	};
	mouse_move(m, 0.25, 0.75); // (80, 150)
	mouse_buttons(m, 1);
	run_ms(m, 50);
	mouse_buttons(m, 0);
	run_ms(m, 50);
	assert(m.cpu.mem[0xA0000 + 150 * 320 + 80] == 1);
	// The cursor is drawn on the picture, not in video memory.
	let pix: []u32 = alloc([0u32...], MAX_W * MAX_H)!;
	defer free(pix);
	render(m, pix, 0);
	assert(pix[150 * MAX_W + 81] == 0xFFFFFFFF || pix[151 * MAX_W + 81] == 0xFFFFFFFF);
	key_event(m, 41, true, '\0');
	key_event(m, 41, false, '\0');
	for (let i = 0; i < 100 && !m.exited; i += 1) run_ms(m, 50);
	assert(m.exited);
	assert(screen_has(m, "Klik: 4"));
};

// In 200-line 16-colour modes the DAC is CGA-like: palette values 18h-1Fh
// (Commander Keen's bright colours) are the bright colours, 18h dark grey.
@test fn ega_200_line_palette() void = {
	const m = new("eksempler")!;
	defer destroy(m);
	set_mode(m, 0x0D, true);
	m.vga.attr[0] = 0x18;
	m.vga.attr[1] = 0x1A;
	m.vga.attr[2] = 0x06;
	let pix: []u32 = alloc([0u32...], MAX_W * MAX_H)!;
	defer free(pix);
	render(m, pix, 0);
	assert(pix[0] == 0xFF555555); // colour 0 everywhere: dark grey
	const pal = palette16(&m.vga);
	assert(pal[1] == 0xFF55FF55); // light green
	assert(pal[2] == 0xFFAA5500); // brown
	// 350- and 480-line modes keep the EGA's 64 colours.
	set_mode(m, 0x10, true);
	m.vga.attr[0] = 0x18;
	assert(palette16(&m.vga)[0] == 0xFF005555);
};

// CPU.COM tells an 8088 from a 386 the way old programs did (flag bits
// 12-15), and on the 386 counts with 32-bit registers.
@test fn cpu_detection() void = {
	const m = run_prog("eksempler", "CPU.COM", "");
	defer destroy(m);
	assert(m.exited);
	assert(screen_has(m, "Din CPU er en 80386."));
	assert(screen_has(m, "12! = 479001600"));
	assert(screen_has(m, "laveste bit er nr. 12, højeste nr. 23"));

	const m = new("eksempler")!;
	defer destroy(m);
	set_cpu(m, x86::model::I8088);
	start(m, "CPU.COM", "")!;
	for (let i = 0; i < 100 && !m.exited; i += 1) run(m, 100000);
	assert(screen_has(m, "Din CPU er en 8086 eller 8088"));
};

// The A20 gate: closed, FFFF:0010 is address 0 (like an 8088); open, it
// is the first byte above 1 MiB.
@test fn a20_gate() void = {
	const m = new("eksempler")!;
	defer destroy(m);
	m.cpu.mem[0] = 0x11;
	m.cpu.mem[0x100000] = 0x22;
	assert(x86::read8(m.cpu, 0xFFFF, 0x10) == 0x11);
	port_out(m.cpu, 0x64, 0xD1);
	port_out(m.cpu, 0x60, 0xDF);
	assert(x86::read8(m.cpu, 0xFFFF, 0x10) == 0x22);
	assert(port_in(m.cpu, 0x92) & 2 != 0);
	port_out(m.cpu, 0x92, 0);
	assert(x86::read8(m.cpu, 0xFFFF, 0x10) == 0x11);
};

// BESKYT.COM: into protected mode and back — memory above 1 MiB, #GP
// with error codes, INT n and a timer IRQ through the IDT, paging with a
// moved page and a page fault that gets fixed, ring 3 with a TSS.
@test fn protected_mode() void = {
	const m = run_prog("eksempler", "BESKYT.COM", "");
	defer destroy(m);
	assert(m.exited && m.exit_code == 0);
	assert(screen_has(m, "Tilbage i real mode."));
	assert(!screen_has(m, "FEJL"));
	let oks = 0;
	for (let r = 0u8; r < text_size(m).1; r += 1) {
		const t = row_text(m, r);
		if (strings::hassuffix(t, " OK")) oks += 1;
		free(t);
	};
	assert(oks == 13);
};

// XMS.COM uses the XMS driver: version, free memory, a block above 1 MiB
// that text is moved into and back out of, locking for its address.
@test fn xms_driver() void = {
	const m = run_prog("eksempler", "XMS.COM", "");
	defer destroy(m);
	assert(m.exited && m.exit_code == 0);
	assert(screen_has(m, "XMS version 03.00"));
	assert(screen_has(m, "Fri udvidet hukommelse: 15040 KB"));
	assert(screen_has(m, "Fri udvidet hukommelse: 14016 KB"));
	assert(screen_has(m, "Hjem fra blokken: Hej fra hukommelsen over 1 MB!"));
	assert(screen_has(m, "Blokken ligger fysisk på 00110000h"));
};

// DPMI.COM is a 32-bit DPMI client: it enters protected mode through
// Shifu's host and uses INT 31h for descriptors, memory above 1 MiB,
// DOS calls in real mode, a timer handler, an exception handler and a
// real-mode callback, then ends from protected mode.
@test fn dpmi_host() void = {
	const m = run_prog("eksempler", "DPMI.COM", "");
	defer destroy(m);
	assert(m.exited && m.exit_code == 0);
	assert(screen_has(m, "INT 21h direkte (et '*'): *"));
	assert(screen_has(m, "Tilbage til DOS fra protected mode."));
	assert(!screen_has(m, "FEJL"));
	let oks = 0;
	for (let r = 0u8; r < text_size(m).1; r += 1) {
		const t = row_text(m, r);
		if (strings::hassuffix(t, " OK")) oks += 1;
		free(t);
	};
	assert(oks == 9);
	assert(!x86::protected(m.cpu));
};

// Mode X: mode 13h with chain-4 off, drawn plane by plane, shown from the
// CRTC's start address (a second page, as Doom flips to).
@test fn mode_x() void = {
	const m = new(".")!;
	defer destroy(m);
	set_mode(m, 0x13, true);
	x86::write8(m.cpu, 0xA000, 3, 77); // chained: pixel 3
	port_out(m.cpu, 0x3C4, 4);
	port_out(m.cpu, 0x3C5, 0x06);          // chain-4 off
	assert(m.vga.unchained);
	assert(m.vga.planes[3 << 16 | 0] == 77); // pixel 3 kept: plane 3, byte 0
	// Page 2 starts at 4000h; pixel (5, 1) is plane 1, byte 4000h + 80 + 1.
	port_out(m.cpu, 0x3C4, 2);
	port_out(m.cpu, 0x3C5, 0x02);          // map mask: plane 1
	x86::write8(m.cpu, 0xA000, 0x4000 + 80 + 1, 9);
	assert(x86::read8(m.cpu, 0xA000, 0x4000 + 80 + 1) == 0); // read map 0
	port_out(m.cpu, 0x3D4, 0x0C);
	port_out(m.cpu, 0x3D5, 0x40);
	port_out(m.cpu, 0x3D4, 0x0D);
	port_out(m.cpu, 0x3D5, 0x00);
	let pix: [MAX_W * MAX_H]u32 = [0...];
	render(m, pix, 0);
	const want = dac_rgb(&m.vga, 9);
	assert(pix[1 * MAX_W + 5] == want);
	assert(pix[1 * MAX_W + 4] != want);
	// And back on: the pixels return to plain memory.
	port_out(m.cpu, 0x3C4, 4);
	port_out(m.cpu, 0x3C5, 0x0E);
	assert(!m.vga.unchained);
	assert(m.cpu.mem[0xA0000 + 3] == 77);
};
