// shifu — runs a DOS program, in a ViperGui window or in the terminal.
//
//	shifu [-c mappe] PROGRAM [argumenter...]
//
// Drive C: is the program's folder (or the -c folder, then PROGRAM is a
// path on C:). On a Wayland desktop the program gets a window with a real
// PC font (-t: use the terminal instead); in the terminal the 80x25 text
// screen is drawn with colours. Ctrl-] stops Shifu.
//
// Like on a real PC, standard input and output can be redirected:
// "shifu SORT.EXE < fil.txt" or "shifu FIND.EXE ... | less". A program
// that draws on the screen instead gets its last screen printed as text.
// -k types keys for the program ("\n" is Enter) — handy for tests.
use endian;
use fmt;
use fs;
use getopt;
use io;
use os;
use path;
use pc;
use strconv;
use strings;
use time;
use unix::tty;
use viper;
use x86;

export fn main() void = {
	const help: []getopt::help = [
		"kør et DOS-program",
		('c', "mappe", "mappen der er drev C: (PROGRAM er så en sti på C:)"),
		('m', "KiB", "hukommelse i KiB (64-640, standard 640)"),
		('v', "version", "DOS-versionen programmet ser, fx 2.11 (standard 5.0)"),
		('k', "taster", "tast dette ind for programmet (\\n er Enter)"),
		('t', "brug terminalen, ikke et vindue"),
		('w', "brug et vindue (også når output er omdirigeret)"),
		('s', "skala", "vinduets forstørrelse, 1-4 (standard 2)"),
		('q', "ingen lyd"),
		('o', "fil.wav", "optag lyden til en WAV-fil"),
		('x', "cycles", "hastighed i instruktioner pr. ms, eller max (standard 3000; 300 = IBM PC)"),
		('8', "kør som en IBM PC med en 8088 (standard: en 386)"),
		('p', "ingen DPMI-vært (DOS-extendere bruger så deres egen)"),
		"[PROGRAM [argumenter...]]  (uden PROGRAM: spilmenuen)",
	];
	const cmd = getopt::parse(os::args, help...);
	defer getopt::finish(&cmd);
	let cdir: (str | void) = void;
	let version = (5u8, 0u8);
	let typed = "";
	let kib = 640u16;
	let want_term = false, want_win = false;
	let scale = 2;
	let cycles = 3000u32;
	let auto = false;
	let quiet = false;
	let wavfile = "";
	let i8088 = false;
	let no_dpmi = false;
	for (let (flag, val) .. cmd.opts) {
		switch (flag) {
		case '8' => i8088 = true;
		case 'p' => no_dpmi = true;
		case 'c' => cdir = val;
		case 'k' => typed = val;
		case 't' => want_term = true;
		case 'q' => quiet = true;
		case 'o' => wavfile = val;
		case 'w' => want_win = true;
		case 'x' =>
			if (val == "max" || val == "auto") {
				auto = true;
			} else match (strconv::stou32(val)) {
			case let v: u32 => cycles = v;
			case => fmt::fatalf("shifu: forstår ikke hastigheden {}", val);
			};
		case 's' =>
			match (strconv::stoi(val)) {
			case let v: int => scale = if (v < 1) 1 else if (v > 4) 4 else v;
			case => fmt::fatalf("shifu: forstår ikke skalaen {}", val);
			};
		case 'm' =>
			match (strconv::stou16(val)) {
			case let v: u16 => kib = v;
			case => fmt::fatalf("shifu: forstår ikke hukommelsen {}", val);
			};
		case 'v' =>
			const (maj, min) = strings::cut(val, ".");
			const a = strconv::stou8(maj);
			const b = strconv::stou8(if (min == "") "0" else min);
			match (a) {
			case let a: u8 =>
				match (b) {
				case let b: u8 => version = (a, b);
				case => fmt::fatalf("shifu: forstår ikke versionen {}", val);
				};
			case => fmt::fatalf("shifu: forstår ikke versionen {}", val);
			};
		case => abort();
		};
	};
	if (len(cmd.args) < 1) {
		// No program: the game menu, on a desktop.
		const desktop = os::getenv("WAYLAND_DISPLAY") is str ||
			os::getenv("DISPLAY") is str;
		if ((desktop || want_win) && !want_term && menu(scale)) os::exit(0);
		getopt::printusage(os::stderr, os::args[0], help)!;
		os::exit(1);
	};

	// Work out drive C: and the program's DOS name.
	let root = "", prog = "";
	match (cdir) {
	case let d: str =>
		root = d;
		prog = cmd.args[0];
	case void =>
		const p = cmd.args[0];
		root = path::dirname(p);
		prog = path::basename(p);
	};
	const root = match (os::realpath(root)) {
	case let r: str => yield strings::dup(r)!;
	case =>
		fmt::fatalf("shifu: fandt ikke mappen {}", root);
	};
	defer free(root);
	const tail = strings::join(" ", cmd.args[1..]...)!;
	defer free(tail);

	const m = pc::new(root)!;
	defer pc::destroy(m);
	pc::set_cpu(m, if (i8088) x86::model::I8088 else x86::model::I386);
	pc::set_dpmi(m, !no_dpmi);
	pc::set_version(m, version.0, version.1);
	pc::set_memory(m, kib);
	pc::set_speed(m, cycles);
	let clock = pacer { last = time::now(time::clock::MONOTONIC), auto = auto, ... };
	// Sound when a person is watching (not for pipes and tests).
	if (!quiet && interactive_out()) {
		const a = viper::audio_open();
		clock.audio = a;
		pc::enable_audio(m, true);
	};
	if (wavfile != "") {
		clock.recording = true;
		pc::enable_audio(m, true);
	};
	defer match (clock.audio) {
	case let a: *viper::audio => viper::audio_close(a);
	case null => void;
	};
	match (pc::start(m, prog, tail)) {
	case void => void;
	case let e: pc::doserr =>
		fmt::fatalf("shifu: kan ikke starte {}: {}", prog, pc::strerror(e));
	};

	// A window when there is a desktop and nothing is redirected.
	const desktop = match (os::getenv("WAYLAND_DISPLAY")) {
	case str => yield true;
	case void => yield os::getenv("DISPLAY") is str;
	};
	const interactive = tty::isatty(os::stdout_file) &&
		tty::isatty(os::stdin_file) && typed == "";
	let quit = false;
	let windowed = false;
	if (want_win || (desktop && interactive && !want_term)) {
		const title = strings::concat("Shifu — ", prog)!;
		defer free(title);
		match (window(m, title, scale, &clock)) {
		case let q: bool =>
			quit = q;
			windowed = true;
		case let e: viper::error =>
			if (want_win) fmt::fatalf("shifu: kan ikke åbne et vindue: {}", viper::strerror(e));
			// No window (e.g. X11 in a Hare-only build): use the terminal.
		case nomem => fmt::fatal("shifu: ikke nok hukommelse");
		};
	};
	if (!windowed) quit = terminal(m, typed, &clock);

	for (let k .. pc::missing_calls(m)) {
		fmt::errorfln("shifu: programmet brugte INT {:_02X}h AH={:_02X}h, som ikke er lavet endnu",
			k >> 8, k & 0xFF)!;
	};
	pc::debug_find(m);
	if (os::getenv("SHIFU_STATS") is str) fmt::errorfln("instr: {}", pc::dbg_count(m))!;
	if (quit) {
		fmt::errorln("shifu: stoppet med Ctrl-]")!;
		pc::dump(m);
	};
	if (wavfile != "") write_wav(wavfile, clock.recorded);
	free(clock.recorded);
	os::exit(m.exit_code: int);
};


// Keeps emulated time in step with real time.
type pacer = struct {
	last: time::instant,
	// -x max: adjust the speed to what the host manages.
	auto: bool,
	audio: nullable *viper::audio,
	// -o: everything played, kept for a WAV file.
	recording: bool,
	recorded: []i16,
};

// Hands the sound made since last time to the speakers and the recording.
fn sound_out(m: *pc::machine, p: *pacer) void = {
	const s = pc::take_audio(m);
	if (p.recording) {
		for (let v .. s) append(p.recorded, (v * 32000.0): i16)!;
	};
	match (p.audio) {
	case let a: *viper::audio =>
		viper::audio_stream(a, s);
		viper::audio_pump(a);
	case null => void;
	};
};

// Writes 16-bit mono 44.1 kHz samples as a WAV file.
fn write_wav(path: str, s: []i16) void = {
	const f = match (os::create(path, 0o644)) {
	case let f: io::file => yield f;
	case let e: fs::error =>
		fmt::errorfln("shifu: kan ikke skrive {}: {}", path, fs::strerror(e))!;
		return;
	};
	defer io::close(f)!;
	const n = len(s): u32 * 2;
	let h: [44]u8 = [0...];
	h[0..4] = strings::toutf8("RIFF");
	endian::leputu32(h[4..8], 36 + n);
	h[8..16] = strings::toutf8("WAVEfmt ");
	endian::leputu32(h[16..20], 16);
	endian::leputu16(h[20..22], 1);       // PCM
	endian::leputu16(h[22..24], 1);       // mono
	endian::leputu32(h[24..28], 44100);
	endian::leputu32(h[28..32], 88200);
	endian::leputu16(h[32..34], 2);
	endian::leputu16(h[34..36], 16);
	h[36..40] = strings::toutf8("data");
	endian::leputu32(h[40..44], n);
	io::writeall(f, h)!;
	let out: []u8 = alloc([0u8...], n)!;
	defer free(out);
	for (let i = 0z; i < len(s); i += 1) endian::leputu16(out[i * 2..i * 2 + 2], s[i]: u16);
	io::writeall(f, out)!;
	fmt::errorfln("shifu: optog {} sekunders lyd i {}", len(s) / 44100, path)!;
};

fn interactive_out() bool = tty::isatty(os::stdout_file);

// Runs the PC for the real time that passed since last time (at most
// 100 ms, so a stall doesn't make the program race to catch up).
fn pace(m: *pc::machine, p: *pacer) void = {
	const t = time::now(time::clock::MONOTONIC);
	let us = time::diff(p.last, t) / time::MICROSECOND;
	p.last = t;
	if (us > 100000) us = 100000;
	if (us <= 0) return;
	pc::run_us(m, us: u64);
	sound_out(m, p);
	if (!p.auto) return;
	// Use about 70 % of the time for the PC.
	const used = time::diff(t, time::now(time::clock::MONOTONIC)) / time::MICROSECOND;
	const cyc = pc::speed(m);
	if (used * 10 < us * 6 && !pc::waiting_for_key(m) && cyc < 200000) {
		pc::set_speed(m, cyc + cyc / 10 + 10);
	} else if (used * 10 > us * 8 && cyc > 300) {
		pc::set_speed(m, cyc - cyc / 10);
	};
};
