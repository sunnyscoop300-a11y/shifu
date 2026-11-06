// shifu — the terminal frontend: the text screen drawn with ANSI colours,
// terminal bytes turned into PC keys, and redirection when stdin/stdout
// aren't a terminal.
use fmt;
use io;
use memio;
use os;
use pc;
use strings;
use time;
use unix::poll;
use unix::tty;

// The CGA/VGA text palette.
const PALETTE: [16](u8, u8, u8) = [
	(0, 0, 0), (0, 0, 170), (0, 170, 0), (0, 170, 170),
	(170, 0, 0), (170, 0, 170), (170, 85, 0), (170, 170, 170),
	(85, 85, 85), (85, 85, 255), (85, 255, 85), (85, 255, 255),
	(255, 85, 85), (255, 85, 255), (255, 255, 85), (255, 255, 255),
];

type screen = struct {
	shown: [2000]u16,
	fresh: bool,
	cursor: (u8, u8, bool),
	// Graphics modes: drawn with half blocks (two pixels a character).
	gfx: bool,
	pix: []u32,
	frames: u64,
};

// Draws a graphics mode as 80x50 "pixels" with ▀ (top colour as the
// foreground, bottom as the background). Rough, but you can see it.
fn draw_gfx(m: *pc::machine, scr: *screen) void = {
	if (len(scr.pix) == 0) scr.pix = alloc([0u32...], pc::MAX_W * pc::MAX_H)!;
	scr.gfx = true;
	scr.frames += 1;
	const pic = pc::render(m, scr.pix, scr.frames);
	const dw = pic.w: size * pic.xrep, dh = pic.h: size * pic.yrep;
	let buf = memio::dynamic();
	defer io::close(&buf)!;
	fmt::fprint(&buf, "\x1b[?25l")!;
	for (let r = 0z; r < 25; r += 1) {
		fmt::fprintf(&buf, "\x1b[{};1H", r + 1)!;
		for (let c = 0z; c < 80; c += 1) {
			const x = (c * dw / 80 + dw / 160) / pic.xrep;
			const yt = ((2 * r) * dh / 50 + dh / 100) / pic.yrep;
			const yb = ((2 * r + 1) * dh / 50 + dh / 100) / pic.yrep;
			const t = scr.pix[yt * pc::MAX_W + x], b = scr.pix[yb * pc::MAX_W + x];
			fmt::fprintf(&buf, "\x1b[38;2;{};{};{};48;2;{};{};{}m▀",
				(t >> 16) & 0xFF, (t >> 8) & 0xFF, t & 0xFF,
				(b >> 16) & 0xFF, (b >> 8) & 0xFF, b & 0xFF)!;
		};
	};
	fmt::fprint(&buf, "\x1b[0m")!;
	io::writeall(os::stdout_file, memio::buffer(&buf))!;
};

// Runs the program in the terminal. Returns true if stopped with Ctrl-].
fn terminal(m: *pc::machine, typed: str, clock: *pacer) bool = {
	const live = tty::isatty(os::stdout_file);
	const keyboard = tty::isatty(os::stdin_file);
	if (!keyboard && typed == "") pc::redirect_stdin(m, os::stdin_file);
	if (!live) pc::redirect_stdout(m, os::stdout_file);
	let parser = keyparser { ... };
	type_keys(m, &parser, typed);
	let term: (tty::termios | void) = void;
	if (keyboard) {
		match (tty::termios_query(os::stdin_file)) {
		case let t: tty::termios =>
			let t = t;
			tty::makeraw(&t): void;
			term = t;
		case => void;
		};
	};

	let scr = screen { fresh = true, ... };
	if (live) out("\x1b[H\x1b[2J");
	let input_open = keyboard;
	let last_draw = time::now(time::clock::MONOTONIC);
	let quit = false;
	// With nothing to watch (output redirected, no keyboard), run as
	// fast as possible.
	const batch = !live && !keyboard;
	for (!m.exited && !quit) {
		if (batch) {
			pc::run_ms(m, 100);
			sound_out(m, clock);
			// No keyboard, and the program waits for keys: give up.
			if (pc::waiting_for_key(m)) break;
			continue;
		};
		pace(m, clock);

		// Keys: wait a little for them (this paces the loop too).
		if (input_open) {
			const wait = 5 * time::MILLISECOND;
			let fds = [poll::pollfd {
				fd = os::stdin_file,
				events = poll::event::POLLIN,
				...
			}];
			match (poll::poll(fds, wait)) {
			case let n: uint =>
				if (n > 0) {
					let buf: [64]u8 = [0...];
					match (io::read(os::stdin_file, buf)) {
					case let k: size =>
						quit = feed(m, &parser, buf[..k]);
					case =>
						input_open = false;
					};
				};
			case => input_open = false;
			};
		} else {
			if (!keyboard && pc::waiting_for_key(m)) break;
			time::sleep(5 * time::MILLISECOND);
		};

		const now = time::now(time::clock::MONOTONIC);
		if (live && time::diff(last_draw, now) > 30 * time::MILLISECOND) {
			draw(m, &scr);
			last_draw = now;
		};
	};

	match (term) {
	case let t: tty::termios => tty::termios_restore(&t);
	case void => void;
	};
	if (live) {
		draw(m, &scr);
		// Leave the cursor below the last line in use.
		fmt::fprintf(os::stdout_file, "\x1b[0m\x1b[{};1H\r\n", last_row(m) + 1)!;
	} else if (!pc::stdout_used(m)) {
		dump(m);
	};
	return quit;
};

// Types the text of -k as keys; the two characters \n are Enter.
fn type_keys(m: *pc::machine, p: *keyparser, s: str) void = {
	const b = strings::toutf8(s);
	let keys: []u8 = [];
	defer free(keys);
	let i = 0z;
	for (i < len(b)) {
		if (b[i] == '\\' && i + 1 < len(b) && b[i + 1] == 'n') {
			append(keys, '\r')!;
			i += 2;
		} else {
			append(keys, b[i])!;
			i += 1;
		};
	};
	feed(m, p, keys);
};

fn out(s: str) void = {
	io::writeall(os::stdout_file, strings::toutf8(s))!;
};

fn last_row(m: *pc::machine, with_cursor: bool = true) u8 = {
	let last = 0u8;
	const (cols, rows) = pc::text_size(m);
	if (pc::video_info(m).kind != pc::vkind::TEXT) return rows - 1;
	for (let r = 0u8; r < rows; r += 1) {
		for (let c = 0u8; c < cols; c += 1) {
			const (ch, _) = pc::cell(m, c, r);
			if (ch != ' ' && ch != 0) last = r;
		};
	};
	const (_, crow) = pc::cursor(m);
	return if (with_cursor && crow > last) crow else last;
};

// Redraws the rows that changed since last time.
fn draw(m: *pc::machine, scr: *screen) void = {
	if (pc::video_info(m).kind != pc::vkind::TEXT) {
		draw_gfx(m, scr);
		return;
	};
	if (scr.gfx) {
		scr.gfx = false;
		scr.fresh = true;
	};
	let buf = memio::dynamic();
	defer io::close(&buf)!;
	let attr = -1;
	const (cols, rows) = pc::text_size(m);
	if (rows > 25 || cols != 80) scr.fresh = true;
	for (let r = 0u8; r < rows && r < 50; r += 1) {
		let changed = scr.fresh;
		for (let c = 0u8; c < cols; c += 1) {
			const (ch, a) = pc::cell(m, c, r);
			const v = a: u16 << 8 | ch;
			const i = (r: size * 80 + c) % len(scr.shown);
			if (scr.shown[i] != v) changed = true;
			scr.shown[i] = v;
		};
		if (!changed) continue;
		fmt::fprintf(&buf, "\x1b[{};1H", r + 1)!;
		for (let c = 0u8; c < cols; c += 1) {
			const (ch, a) = pc::cell(m, c, r);
			if (a: int != attr) {
				attr = a: int;
				const fg = PALETTE[a & 0x0F], bg = PALETTE[(a >> 4) & 7];
				fmt::fprintf(&buf, "\x1b[38;2;{};{};{};48;2;{};{};{}m",
					fg.0, fg.1, fg.2, bg.0, bg.1, bg.2)!;
			};
			memio::appendrune(&buf, pc::CHARSET[ch])!;
		};
	};
	scr.fresh = false;
	const (col, row) = pc::screen_cursor(m);
	const vis = pc::cursor_visible(m);
	fmt::fprintf(&buf, "\x1b[0m\x1b[{};{}H{}", row + 1, col + 1,
		if (vis) "\x1b[?25h" else "\x1b[?25l")!;
	io::writeall(os::stdout_file, memio::buffer(&buf))!;
};

// Prints the screen as plain text (when the output isn't a terminal).
fn dump(m: *pc::machine) void = {
	if (pc::video_info(m).kind != pc::vkind::TEXT) {
		fmt::fprintln(os::stdout_file, "[skærmen er i grafiktilstand]")!;
		return;
	};
	const cols = pc::text_size(m).0;
	const last = last_row(m, false);
	for (let r = 0u8; r <= last; r += 1) {
		let line = memio::dynamic();
		defer io::close(&line)!;
		let end = 0u8;
		for (let c = 0u8; c < cols; c += 1) {
			const (ch, _) = pc::cell(m, c, r);
			if (ch != ' ' && ch != 0) end = c + 1;
		};
		for (let c = 0u8; c < end; c += 1) {
			const (ch, _) = pc::cell(m, c, r);
			memio::appendrune(&line, pc::CHARSET[ch])!;
		};
		fmt::fprintln(os::stdout_file, memio::string(&line)!)!;
	};
};

// ---- Keys: terminal bytes to PC keys (scan code << 8 | character) ----

type keyparser = struct {
	esc: [8]u8,
	n: size,
	utf: [4]u8,
	un: size,
};

// US keyboard scan codes for the ASCII characters.
const ROWS_LOWER: [4](u8, str) = [
	(0x02, "1234567890-="), (0x10, "qwertyuiop[]"),
	(0x1E, "asdfghjkl;'`"), (0x2B, "\\zxcvbnm,./"),
];
const ROWS_UPPER: [4](u8, str) = [
	(0x02, "!@#$%^&*()_+"), (0x10, "QWERTYUIOP{}"),
	(0x1E, "ASDFGHJKL:\"~"), (0x2B, "|ZXCVBNM<>?"),
];

fn scan_of(ch: u8) u8 = {
	if (ch == ' ') return 0x39;
	for (let rows .. [ROWS_LOWER, ROWS_UPPER]) {
		for (let (base, keys) .. rows) {
			const b = strings::toutf8(keys);
			for (let i = 0z; i < len(b); i += 1) {
				if (b[i] == ch) return base + i: u8;
			};
		};
	};
	return 0;
};

fn key(m: *pc::machine, scan: u8, ch: u8) void = {
	pc::type_key(m, scan: u16 << 8 | ch);
};

// Feeds terminal input to the PC. Returns true for Ctrl-] (quit).
fn feed(m: *pc::machine, p: *keyparser, b: []u8) bool = {
	for (let i = 0z; i < len(b); i += 1) {
		const ch = b[i];
		if (p.n > 0) {
			p.esc[p.n] = ch;
			p.n += 1;
			if (esc_done(m, p)) p.n = 0;
			continue;
		};
		if (p.un > 0 || ch >= 0x80) {
			p.utf[p.un] = ch;
			p.un += 1;
			utf_done(m, p);
			continue;
		};
		switch (ch) {
		case 0x1D => return true; // Ctrl-]
		case 0x1B =>
			if (i + 1 < len(b)) {
				p.esc[0] = ch;
				p.n = 1;
			} else {
				key(m, 0x01, 0x1B); // Esc on its own
			};
		case 0x0D, 0x0A => key(m, 0x1C, 0x0D);
		case 0x7F, 0x08 => key(m, 0x0E, 0x08);
		case 0x09 => key(m, 0x0F, 0x09);
		case =>
			if (ch < 0x20) {
				// Ctrl-letter
				key(m, scan_of(ch + 'a' - 1), ch);
			} else {
				key(m, scan_of(ch), ch);
			};
		};
	};
	if (p.n == 1) {
		key(m, 0x01, 0x1B);
		p.n = 0;
	};
	return false;
};

// Handles a finished escape sequence; returns false while it goes on.
fn esc_done(m: *pc::machine, p: *keyparser) bool = {
	const s = p.esc[..p.n];
	const last = s[len(s) - 1];
	if (p.n == 2) {
		if (last == '[' || last == 'O') return false;
		key(m, 0x01, 0x1B); // Alt-something: just Esc
		return true;
	};
	if (p.n >= len(p.esc)) return true;
	if ((last < 'A' || last > 'Z') && last != '~') return false;
	const t = strings::fromutf8_unsafe(s[1..]);
	const scan: u8 = switch (t) {
	case "[A", "OA" => yield 0x48;
	case "[B", "OB" => yield 0x50;
	case "[C", "OC" => yield 0x4D;
	case "[D", "OD" => yield 0x4B;
	case "[H", "OH", "[1~" => yield 0x47;
	case "[F", "OF", "[4~" => yield 0x4F;
	case "[2~" => yield 0x52;
	case "[3~" => yield 0x53;
	case "[5~" => yield 0x49;
	case "[6~" => yield 0x51;
	case "OP" => yield 0x3B;
	case "OQ" => yield 0x3C;
	case "OR" => yield 0x3D;
	case "OS" => yield 0x3E;
	case "[15~" => yield 0x3F;
	case "[17~" => yield 0x40;
	case "[18~" => yield 0x41;
	case "[19~" => yield 0x42;
	case "[20~" => yield 0x43;
	case "[21~" => yield 0x44;
	case => yield 0;
	};
	if (scan != 0) key(m, scan, if (scan == 0x53) 0 else 0);
	return true;
};

// Handles UTF-8 (æøå and friends) once the whole character is in.
fn utf_done(m: *pc::machine, p: *keyparser) void = {
	const first = p.utf[0];
	const need: size = if (first >= 0xF0) 4 else if (first >= 0xE0) 3
		else if (first >= 0xC0) 2 else 1;
	if (p.un < need) return;
	const s = strings::fromutf8(p.utf[..p.un]);
	p.un = 0;
	const r = match (s) {
	case let s: str =>
		let it = strings::iter(s);
		yield match (strings::next(&it)) {
		case let r: rune => yield r;
		case done => return;
		};
	case => return;
	};
	match (pc::from_unicode(r)) {
	case let b: u8 =>
		const scan: u8 = switch (r) {
		case 'æ', 'Æ' => yield 0x27;
		case 'ø', 'Ø' => yield 0x28;
		case 'å', 'Å' => yield 0x1A;
		case => yield 0;
		};
		key(m, scan, b);
	case void => void;
	};
};
