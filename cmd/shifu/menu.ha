// shifu — the game menu: "shifu" alone, on a desktop, shows a list of the
// games in ~/.config/shifu/spil.txt and starts the one picked (as a new
// shifu, so each game gets a fresh PC). When it ends, the menu is back.
//
// spil.txt has a line per game:
//
//	Navn | mappe | PROGRAM | valg
//	Doom | ~/Videos/viper2 | DOOM.EXE | -x max
//
// The first time, Shifu writes it with the games it finds in the current
// folder and the one above it.
use ascii;
use fmt;
use fs;
use io;
use os;
use os::exec;
use strconv;
use strings;
use viper;

type game = struct {
	name: str,
	dir: str,
	prog: str,
	opts: []str,
};

// Games Shifu knows and how fast they want the CPU.
const KNOWN: [_](str, str, str) = [
	("KEEN1.EXE", "Commander Keen 1", "-x 3000"),
	("KEEN4E.EXE", "Commander Keen 4", "-x 3000"),
	("KEEN4.EXE", "Commander Keen 4", "-x 3000"),
	("KEEN5E.EXE", "Commander Keen 5", "-x 3000"),
	("KEEN6.EXE", "Commander Keen 6", "-x 3000"),
	("WOLF3D.EXE", "Wolfenstein 3D", "-x max"),
	("SPEAR.EXE", "Spear of Destiny", "-x max"),
	("DOOM.EXE", "Doom", "-x max"),
	("DOOM2.EXE", "Doom II", "-x max"),
	("HERETIC.EXE", "Heretic", "-x max"),
	("HEXEN.EXE", "Hexen", "-x max"),
	("ROTT.EXE", "Rise of the Triad", "-x max"),
	("DUKE3D.EXE", "Duke Nukem 3D", "-x max"),
];

fn config_path() str = {
	const home = os::tryenv("HOME", ".");
	const base = match (os::getenv("XDG_CONFIG_HOME")) {
	case let s: str => yield strings::dup(s)!;
	case void => yield strings::concat(home, "/.config")!;
	};
	defer free(base);
	return strings::concat(base, "/shifu/spil.txt")!;
};

// ~ at the start of a path is the home folder.
fn expand(p: str) str = {
	if (strings::hasprefix(p, "~/") || p == "~") {
		return strings::concat(os::tryenv("HOME", "."), strings::sub(p, 1))!;
	};
	return strings::dup(p)!;
};

fn games_free(gs: []game) void = {
	for (let g .. gs) {
		free(g.name);
		free(g.dir);
		free(g.prog);
		strings::freeall(g.opts);
	};
	free(gs);
};

fn load_games(file: str) []game = {
	let gs: []game = [];
	const f = match (os::open(file)) {
	case let f: io::file => yield f;
	case fs::error => return gs;
	};
	defer io::close(f)!;
	const data = match (io::drain(f)) {
	case let d: []u8 => yield d;
	case io::error => return gs;
	};
	defer free(data);
	const text = match (strings::fromutf8(data)) {
	case let s: str => yield s;
	case => return gs;
	};
	for (let line .. strings::split(text, "\n")!) {
		const line = strings::trim(line);
		if (line == "" || strings::hasprefix(line, "#")) continue;
		const parts = strings::split(line, "|")!;
		defer free(parts);
		if (len(parts) < 3) continue;
		let opts: []str = [];
		if (len(parts) > 3) {
			for (let o .. strings::split(strings::trim(parts[3]), " ")!) {
				if (o != "") append(opts, strings::dup(o)!)!;
			};
		};
		append(gs, game {
			name = strings::dup(strings::trim(parts[0]))!,
			dir = expand(strings::trim(parts[1])),
			prog = strings::dup(strings::trim(parts[2]))!,
			opts = opts,
		})!;
	};
	return gs;
};

// The first time: spil.txt with the games found here and one folder up.
fn write_default(file: str) void = {
	let text: []str = [];
	append(text, strings::dup("# Shifus spilmenu: en linje pr. spil.\n")!)!;
	append(text, strings::dup("# Navn | mappe | PROGRAM | valg (som på kommandolinjen)\n")!)!;
	append(text, strings::dup("# skala: vinduernes størrelse, 1-4 (+ og - i menuen)\n")!)!;
	append(text, strings::dup("skala = 1\n")!)!;
	defer strings::freeall(text);
	const here = match (os::realpath(".")) {
	case let r: str => yield strings::dup(r)!;
	case => yield strings::dup(".")!;
	};
	defer free(here);
	const up = match (os::realpath("..")) {
	case let r: str => yield strings::dup(r)!;
	case => yield strings::dup("..")!;
	};
	defer free(up);
	for (let dir .. [here, up]) {
		const ents = match (os::readdir(dir)) {
		case let e: []fs::dirent => yield e;
		case => continue;
		};
		defer fs::dirents_free(ents);
		for (let k .. KNOWN) {
			for (let e .. ents) {
				if (ascii::strcasecmp(e.name, k.0) != 0) continue;
				append(text, fmt::asprintf("{} | {} | {} | {}\n",
					k.1, dir, e.name, k.2)!)!;
			};
		};
	};
	const slash = strings::rindex(file, '/') as size;
	match (os::mkdirs(strings::sub(file, 0, slash), 0o755)) {
	case => void;
	};
	const f = match (os::create(file, 0o644)) {
	case let f: io::file => yield f;
	case fs::error => return;
	};
	defer io::close(f)!;
	for (let t .. text) match (fmt::fprint(f, t)) {
	case size => void;
	case io::error => return;
	};
};

// The menu, until it is closed. Returns false if there is no window.
fn menu(scale: int) bool = {
	const file = config_path();
	defer free(file);
	if (!(os::stat(file) is fs::filestat)) write_default(file);
	let scale = match (read_scale(file)) {
	case let n: int => yield n;
	case void => yield scale;
	};
	let sel = 0z;
	for (true) {
		const gs = load_games(file);
		defer games_free(gs);
		if (sel >= len(gs)) sel = 0;
		const pick = match (menu_window(gs, file, &sel, scale)) {
		case let p: (size | void | rescale) => yield p;
		case viper::error => return false;
		case nomem => return true;
		};
		match (pick) {
		case void => return true;
		case let i: size => run_game(&gs[i], scale);
		case let n: rescale =>
			scale = n;
			save_scale(file, n);
		};
	};
};

// The menu asks for another window size (+ and - keys).
type rescale = int;

// "skala = N" in spil.txt: the size of the menu and the games' windows.
fn read_scale(file: str) (int | void) = {
	const text = match (read_text(file)) {
	case let t: str => yield t;
	case void => return;
	};
	defer free(text);
	for (let line .. strings::split(text, "\n")!) {
		const (k, v) = strings::cut(strings::trim(line), "=");
		if (strings::trim(k) != "skala") continue;
		match (strconv::stoi(strings::trim(v))) {
		case let n: int => return if (n < 1) 1 else if (n > 4) 4 else n;
		case => void;
		};
	};
};

fn read_text(file: str) (str | void) = {
	const f = match (os::open(file)) {
	case let f: io::file => yield f;
	case fs::error => return;
	};
	defer io::close(f)!;
	const data = match (io::drain(f)) {
	case let d: []u8 => yield d;
	case io::error => return;
	};
	match (strings::fromutf8(data)) {
	case let s: str => return s;
	case => free(data);
	};
};

// Writes "skala = N" into spil.txt (replacing the old one).
fn save_scale(file: str, n: int) void = {
	const text = match (read_text(file)) {
	case let t: str => yield t;
	case void => return;
	};
	defer free(text);
	const f = match (os::create(file, 0o644)) {
	case let f: io::file => yield f;
	case fs::error => return;
	};
	defer io::close(f)!;
	let wrote = false;
	const lines = strings::split(text, "\n")!;
	defer free(lines);
	for (let i = 0z; i < len(lines); i += 1) {
		const line = lines[i];
		if (i + 1 == len(lines) && line == "") break;
		const (k, _) = strings::cut(strings::trim(line), "=");
		const out = if (strings::trim(k) == "skala") {
			if (wrote) continue;
			wrote = true;
			yield fmt::fprintfln(f, "skala = {}", n);
		} else if (!wrote && !strings::hasprefix(strings::trim(line), "#")) {
			wrote = true;
			match (fmt::fprintfln(f, "skala = {}", n)) {
			case size => void;
			case io::error => return;
			};
			yield fmt::fprintln(f, line);
		} else fmt::fprintln(f, line);
		match (out) {
		case size => void;
		case io::error => return;
		};
	};
	if (!wrote) match (fmt::fprintfln(f, "skala = {}", n)) {
	case => void;
	};
};

// Starts a game as a new shifu and waits for it.
fn run_game(g: *game, scale: int) void = {
	let args: []str = [];
	defer free(args);
	let sc: [2]u8 = ['0' + scale: u8, 0];
	const sc = strings::fromutf8(sc[..1])!;
	let has_s = false;
	for (let o .. g.opts) if (o == "-s") has_s = true;
	if (!has_s) {
		append(args, "-s")!;
		append(args, sc)!;
	};
	append(args, g.opts...)!;
	append(args, "-w")!;
	append(args, "-c")!;
	append(args, g.dir)!;
	append(args, g.prog)!;
	let cmd = match (exec::cmd("/proc/self/exe", args...)) {
	case let c: exec::command => yield c;
	case => return;
	};
	match (exec::start(&cmd)) {
	case let p: exec::process =>
		match (exec::wait(&p)) {
		case => void;
		};
	case => void;
	};
};

def BG: u32 = 0xFF1A0E0A;       // dark wood
def GOLD: u32 = 0xFFE8B84A;
def RED: u32 = 0xFFB0281E;      // Master Shifu's robe
def CREAM: u32 = 0xFFF2E6CC;
def DIM: u32 = 0xFF9A8A70;

// The list in a window. Returns the game picked, or void when closed.
fn menu_window(gs: []game, file: str, sel: *size, scale: int) ((size | void | rescale) | viper::error | nomem) = {
	const w = 640 * scale, h = 480 * scale;
	const win = viper::open("Shifu — spil", w, h)?;
	defer viper::close(win);
	const line = 28 * scale, top = 110 * scale;
	for (viper::frame(win)) {
		for (let ev .. viper::key_events(win)) {
			if (!ev.down) continue;
			switch (ev.hid) {
			case 82 => if (*sel > 0) *sel -= 1;                // up
			case 81 => if (*sel + 1 < len(gs)) *sel += 1;      // down
			case 74 => *sel = 0;                               // home
			case 77 => if (len(gs) > 0) *sel = len(gs) - 1;    // end
			case 40, 88, 44 => if (len(gs) > 0) return *sel;   // Enter, space
			case 41 => return void;                            // Esc
			case => void;
			};
			// + and - by the character typed (they sit on different keys on
			// Danish and US keyboards), and on the number pad.
			if ((ev.text == '+' || ev.hid == 87) && scale < 4)
				return (scale + 1): rescale;
			if ((ev.text == '-' || ev.hid == 86) && scale > 1)
				return (scale - 1): rescale;
		};
		// The mouse: point to choose, click to start.
		const (mx, my) = viper::mouse(win);
		const over = if (my >= top && len(gs) > 0) (my - top) / line else -1;
		if (over >= 0 && over < len(gs): int && mx >= 60 * scale && mx < w - 60 * scale) {
			*sel = over: size;
			if (viper::mouse_clicks(win) != 0) return *sel;
		};

		draw_menu(win, gs, file, *sel, scale);
		// For checking the look: SHIFU_MENU_PPM=fil.ppm saves the menu.
		match (os::getenv("SHIFU_MENU_PPM")) {
		case let out: str => save_ppm(win, out);
		case void => void;
		};
		viper::present(win);
	};
	return void;
};

fn draw_menu(win: *viper::window, gs: []game, file: str, sel: size, scale: int) void = {
	const w = win.width, h = win.height;
	const line = 28 * scale, top = 110 * scale;
	viper::clear(win, BG);
	viper::rect(win, 0, 0, w, 6 * scale, RED);
	viper::rect(win, 0, h - 6 * scale, w, 6 * scale, RED);
	const title = "SHIFU";
	viper::text_scaled(win, (w - viper::text_width(title, 3 * scale)) / 2,
		14 * scale, title, GOLD, 3 * scale);
	const sub = "Mesterens spilsamling";
	viper::text_scaled(win, (w - viper::text_width(sub, scale)) / 2,
		72 * scale, sub, DIM, scale);
	if (len(gs) == 0) {
		const msg = "Ingen spil endnu. Skriv dem i:";
		viper::text_scaled(win, 60 * scale, top, msg, CREAM, scale);
		viper::text_scaled(win, 60 * scale, top + line, file, GOLD, scale);
	};
	for (let i = 0z; i < len(gs); i += 1) {
		const y = top + i: int * line;
		if (y + line > h - 40 * scale) break;
		const chosen = i == sel;
		if (chosen) {
			viper::round_rect(win, 60 * scale, y, w - 120 * scale,
				line - 4 * scale, 6 * scale, RED);
		};
		viper::text_scaled(win, 76 * scale, y + 4 * scale, gs[i].name,
			if (chosen) GOLD else CREAM, scale);
		const prog = gs[i].prog;
		viper::text_scaled(win, w - 76 * scale - viper::text_width(prog, scale),
			y + 4 * scale, prog, if (chosen) CREAM else DIM, scale);
	};
	const help = "Op/ned: vælg   Enter: start   +/-: størrelse   Esc: luk";
	viper::text_scaled(win, (w - viper::text_width(help, scale)) / 2,
		h - 34 * scale, help, DIM, scale);
};

fn save_ppm(win: *viper::window, out: str) void = {
	const f = match (os::create(out, 0o644)) {
	case let f: io::file => yield f;
	case fs::error => return;
	};
	defer io::close(f)!;
	let buf: []u8 = alloc([0...], (win.width * win.height * 3): size)!;
	defer free(buf);
	for (let i = 0z; i < len(win.pixels); i += 1) {
		const p = win.pixels[i];
		buf[i * 3] = (p >> 16): u8;
		buf[i * 3 + 1] = (p >> 8): u8;
		buf[i * 3 + 2] = p: u8;
	};
	match (fmt::fprintf(f, "P6\n{} {}\n255\n", win.width, win.height)) {
	case size => void;
	case io::error => return;
	};
	match (io::writeall(f, buf)) {
	case size => void;
	case io::error => void;
	};
};
