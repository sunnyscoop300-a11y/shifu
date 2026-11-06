// sst — runs the SingleStepTests 8088 suite (MOO format) against Shifu's
// CPU: every test sets up registers and memory, runs one instruction and
// compares the result with what a real 8088 did.
//
//	sst [-v] [-n N] <fil.MOO.gz | mappe> ...
use fmt;
use fs;
use getopt;
use io;
use os;
use path;
use sort;
use sort::cmp;
use strconv;
use strings;
use viper;
use x86;

// Register order in the MOO format.
const REGS: [14]str = ["ax", "bx", "cx", "dx", "cs", "ss", "ds", "es",
	"sp", "bp", "si", "di", "ip", "flags"];

type state = struct {
	regs: [14]u16,
	have: u16, // bitmask of the registers present
	ram: [](u32, u8),
};

type test = struct {
	idx: u32,
	name: str,
	init: state,
	fina: state,
};

type stats = struct {
	files: size,
	tests: size,
	failed: size,
	bad_files: size,
};

fn rd16(b: []u8, p: size) u16 = b[p]: u16 | b[p + 1]: u16 << 8;
fn rd32(b: []u8, p: size) u32 = b[p]: u32 | b[p + 1]: u32 << 8 |
	b[p + 2]: u32 << 16 | b[p + 3]: u32 << 24;

fn parse_state(b: []u8, st: *state) void = {
	let p = 0z;
	for (p + 8 <= len(b)) {
		const id = b[p..p + 4];
		const n = rd32(b, p + 4): size;
		const d = b[p + 8..p + 8 + n];
		if (strings::fromutf8_unsafe(id) == "REGS") {
			st.have = rd16(d, 0);
			let q = 2z;
			for (let i = 0z; i < 14; i += 1) {
				if (st.have & (1 << i: u16) == 0) continue;
				st.regs[i] = rd16(d, q);
				q += 2;
			};
		} else if (strings::fromutf8_unsafe(id) == "RAM ") {
			const cnt = rd32(d, 0): size;
			for (let i = 0z; i < cnt; i += 1) {
				const e = 4 + i * 5;
				append(st.ram, (rd32(d, e), d[e + 4]))!;
			};
		};
		p += 8 + n;
	};
};

fn parse_test(b: []u8, t: *test) void = {
	t.idx = rd32(b, 0);
	let p = 4z;
	for (p + 8 <= len(b)) {
		const id = strings::fromutf8_unsafe(b[p..p + 4]);
		const n = rd32(b, p + 4): size;
		const d = b[p + 8..p + 8 + n];
		switch (id) {
		case "NAME" =>
			const l = rd32(d, 0): size;
			t.name = strings::fromutf8_unsafe(d[4..4 + l]);
		case "INIT" => parse_state(d, &t.init);
		case "FINA" => parse_state(d, &t.fina);
		case => void;
		};
		p += 8 + n;
	};
};

fn free_test(t: *test) void = {
	free(t.init.ram);
	free(t.fina.ram);
};

// Which flags the real chip leaves undefined, from v2/metadata.json.
fn flags_mask(op: u8, reg: int) u16 = {
	const no_af: u16 = 0xFFEF;
	switch (op) {
	case 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D,
		0x20, 0x21, 0x22, 0x23, 0x24, 0x25,
		0x30, 0x31, 0x32, 0x33, 0x34, 0x35,
		0x84, 0x85, 0xA8, 0xA9 =>
		return no_af;
	case 0x27, 0x2F => return 0xF7FF; // DAA, DAS: OF
	case 0x37, 0x3F => return 63291;  // AAA, AAS: O S Z P
	case 0x80, 0x81, 0x82, 0x83 =>
		if (reg == 1 || reg == 4 || reg == 6) return no_af;
	case 0xD0, 0xD1, 0xD2, 0xD3 =>
		if (reg == 4 || reg == 5 || reg == 7) return no_af;
		if (reg == 6) return 63274;
	case 0xD4, 0xD5 => return 63470; // AAM, AAD: O A C
	case 0xF6, 0xF7 =>
		switch (reg) {
		case 0, 1 => return no_af;
		case 4, 5 => return 65323;
		case 6, 7 => return 63274;
		case => void;
		};
	case => void;
	};
	return 0xFFFF;
};

// Runs one test. Returns a description of the first mismatch, or "" when
// the CPU got everything right. The CPU's memory is left clean afterwards.
fn run_test(c: *x86::cpu, t: *test, fmask: u16, divides: bool, why: []u8) str = {
	x86::reset(c);
	const ir = &t.init.regs;
	c.r[x86::AX] = ir[0]; c.r[x86::BX] = ir[1];
	c.r[x86::CX] = ir[2]; c.r[x86::DX] = ir[3];
	c.s[x86::CS] = ir[4]; c.s[x86::SS] = ir[5];
	c.s[x86::DS] = ir[6]; c.s[x86::ES] = ir[7];
	c.r[x86::SP] = ir[8]; c.r[x86::BP] = ir[9];
	c.r[x86::SI] = ir[10]; c.r[x86::DI] = ir[11];
	c.ip = ir[12];
	c.flags = ir[13];
	for (let (a, v) .. t.init.ram) c.mem[a & 0xFFFFF] = v;
	c.log_writes = true;
	c.writes = c.writes[..0];

	x86::step(c);
	for (let guard = 0; c.in_rep && guard < 1000000; guard += 1) {
		x86::step(c);
	};
	c.log_writes = false;

	let msg = "";
	const got: [14]u16 = [
		c.r[x86::AX], c.r[x86::BX], c.r[x86::CX], c.r[x86::DX],
		c.s[x86::CS], c.s[x86::SS], c.s[x86::DS], c.s[x86::ES],
		c.r[x86::SP], c.r[x86::BP], c.r[x86::SI], c.r[x86::DI],
		c.ip, c.flags,
	];
	for (let i = 0z; i < 14 && msg == ""; i += 1) {
		let want = t.init.regs[i];
		if (t.fina.have & (1 << i: u16) != 0) want = t.fina.regs[i];
		let g = got[i];
		if (i == 13) {
			want &= fmask;
			g &= fmask;
		};
		if (g != want) {
			msg = fmt::bsprintf(why, "{} er {:_04X}, skulle være {:_04X}",
				REGS[i], g, want)!;
		};
	};
	// A divide error pushes the flags, undefined ones included, so the
	// same mask applies to that copy on the stack.
	let flo = 0xFFFFFFFFu32, fhi = 0xFFFFFFFFu32;
	if (divides) {
		let ss = t.init.regs[5], sp = t.init.regs[8];
		if (t.fina.have & (1 << 5) != 0) ss = t.fina.regs[5];
		if (t.fina.have & (1 << 8) != 0) sp = t.fina.regs[8];
		if (sp == t.init.regs[8] - 6) {
			flo = x86::linear(ss, sp + 4) & 0xFFFFF;
			fhi = x86::linear(ss, sp + 5) & 0xFFFFF;
		};
	};
	for (let (a, v) .. t.fina.ram) {
		if (msg != "") break;
		let g = c.mem[a & 0xFFFFF];
		let v = v;
		if (a & 0xFFFFF == flo) {
			g &= fmask: u8;
			v &= fmask: u8;
		} else if (a & 0xFFFFF == fhi) {
			g &= (fmask >> 8): u8;
			v &= (fmask >> 8): u8;
		};
		if (g != v) {
			msg = fmt::bsprintf(why, "[{:_05X}] er {:_02X}, skulle være {:_02X}",
				a, g, v)!;
		};
	};
	// Writes the test doesn't list must have left the old value.
	for (let w .. c.writes) {
		if (msg != "") break;
		const a = w >> 8, old = w: u8;
		let listed = false;
		for (let (fa, _) .. t.fina.ram) {
			if (fa & 0xFFFFF == a) listed = true;
		};
		if (!listed && a != flo && a != fhi && c.mem[a] != old && first_write(c, a) == w) {
			msg = fmt::bsprintf(why, "skrev [{:_05X}] = {:_02X}, som ikke skulle ændres",
				a, c.mem[a])!;
		};
	};

	// Clean up for the next test.
	for (let (a, _) .. t.init.ram) c.mem[a & 0xFFFFF] = 0;
	for (let w .. c.writes) c.mem[w >> 8] = 0;
	return msg;
};

// The first logged write to address a (it holds the value before the test).
fn first_write(c: *x86::cpu, a: u32) u32 = {
	for (let w .. c.writes) if (w >> 8 == a) return w;
	return 0;
};

fn hexbyte(s: str) (u8 | void) = {
	match (strconv::stou8(s, strconv::base::HEX)) {
	case let v: u8 => return v;
	case => return;
	};
};

fn run_file(c: *x86::cpu, file: str, verbose: bool, show: size, st: *stats) void = {
	// "80.3.MOO.gz" -> opcode 80, reg 3
	const base = path::basename(file);
	const parts = strings::split(base, ".")!;
	defer free(parts);
	const op = match (hexbyte(parts[0])) {
	case let v: u8 => yield v;
	case void =>
		fmt::errorfln("{}: kan ikke se opkoden i filnavnet", file)!;
		st.bad_files += 1;
		return;
	};
	let reg = -1;
	if (len(parts) > 1 && len(parts[1]) == 1) {
		match (strconv::stoi(parts[1])) {
		case let v: int => reg = v;
		case => void;
		};
	};
	const fmask = flags_mask(op, reg);
	const divides = op == 0xD4 || ((op == 0xF6 || op == 0xF7) && reg >= 6);

	const raw = match (os::open(file)) {
	case let f: io::file =>
		defer io::close(f)!;
		yield match (io::drain(f)) {
		case let b: []u8 => yield b;
		case let e: io::error =>
			fmt::errorfln("{}: {}", file, io::strerror(e))!;
			st.bad_files += 1;
			return;
		};
	case let e: fs::error =>
		fmt::errorfln("{}: {}", file, fs::strerror(e))!;
		st.bad_files += 1;
		return;
	};
	let data = raw;
	if (strings::hassuffix(file, ".gz")) {
		data = match (viper::gunzip(raw)) {
		case let b: []u8 => yield b;
		case let e: viper::badpng =>
			fmt::errorfln("{}: {}", file, e)!;
			free(raw);
			st.bad_files += 1;
			return;
		case nomem =>
			fmt::fatal("ikke nok hukommelse");
		};
		free(raw);
	};
	defer free(data);

	if (len(data) < 8 || strings::fromutf8_unsafe(data[..4]) != "MOO ") {
		fmt::errorfln("{}: ikke en MOO-fil", file)!;
		st.bad_files += 1;
		return;
	};

	let n = 0z, bad = 0z;
	let why: [256]u8 = [0...];
	let p = 0z;
	for (p + 8 <= len(data)) {
		const id = strings::fromutf8_unsafe(data[p..p + 4]);
		const l = rd32(data, p + 4): size;
		if (id == "TEST") {
			let t = test { ... };
			parse_test(data[p + 8..p + 8 + l], &t);
			const msg = run_test(c, &t, fmask, divides, why);
			n += 1;
			if (msg != "") {
				bad += 1;
				if (bad <= show) {
					fmt::printfln("  #{} {}: {}", t.idx, t.name, msg)!;
				};
			};
			free_test(&t);
		};
		p += 8 + l;
	};

	st.files += 1;
	st.tests += n;
	st.failed += bad;
	if (bad == 0) {
		if (verbose) fmt::printfln("{:-12} OK   {} tests", base, n)!;
	} else {
		fmt::printfln("{:-12} FEJL {} af {}", base, bad, n)!;
	};
};

fn is_test_file(name: str) bool =
	strings::hassuffix(name, ".MOO.gz") || strings::hassuffix(name, ".MOO");

export fn main() void = {
	const help: []getopt::help = [
		"kør SingleStepTests 8088-tests mod Shifus CPU",
		('v', "vis også filer der består"),
		('n', "N", "vis højst N fejl pr. fil (standard 3)"),
		"<fil.MOO.gz|mappe>...",
	];
	const cmd = getopt::parse(os::args, help...);
	defer getopt::finish(&cmd);
	let verbose = false, show = 3z;
	for (let (flag, val) .. cmd.opts) {
		switch (flag) {
		case 'v' => verbose = true;
		case 'n' => show = strconv::stoz(val)!;
		case => abort();
		};
	};
	if (len(cmd.args) == 0) {
		getopt::printusage(os::stderr, os::args[0], help)!;
		os::exit(1);
	};

	let files: []str = [];
	defer strings::freeall(files);
	for (let a .. cmd.args) {
		match (os::readdir(a)) {
		case let ents: []fs::dirent =>
			defer fs::dirents_free(ents);
			for (let e .. ents) {
				if (!is_test_file(e.name)) continue;
				let buf = path::init(a, e.name)!;
				append(files, strings::dup(path::string(&buf))!)!;
			};
		case =>
			append(files, strings::dup(a)!)!;
		};
	};
	sort::sort(files, size(str), &cmp::strs)!;

	const c = x86::new()!;
	defer x86::destroy(c);
	let st = stats { ... };
	for (let f .. files) run_file(c, f, verbose, show, &st);

	const ok = st.tests - st.failed;
	fmt::printfln("\n{} filer, {} tests: {} rigtige, {} forkerte ({}.{}%)",
		st.files, st.tests, ok, st.failed,
		if (st.tests == 0) 0z else ok * 100 / st.tests,
		if (st.tests == 0) 0z else (ok * 1000 / st.tests) % 10)!;
	if (st.failed > 0 || st.bad_files > 0) os::exit(1);
};
