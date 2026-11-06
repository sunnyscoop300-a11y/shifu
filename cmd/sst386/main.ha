// sst386 — runs the SingleStepTests 80386 real-mode suite (MOO format)
// against Shifu's 386: every test sets up registers and memory, runs one
// instruction (to the HLT after it, or in the exception handler) and
// compares the result with what a real 386EX did.
//
//	sst386 [-v] [-n N] <fil.MOO.gz | mappe> ...
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

// Register order in the MOO format's RG32 chunk.
def NREG: size = 20;
const REGS: [NREG]str = ["cr0", "cr3", "eax", "ebx", "ecx", "edx", "esi",
	"edi", "ebp", "esp", "cs", "ds", "es", "fs", "gs", "ss", "eip", "eflags",
	"dr6", "dr7"];
def R_EFLAGS: size = 17;

type state = struct {
	regs: [NREG]u32,
	have: u32,
	mask: [NREG]u32,
	ram: [](u32, u8),
};

type test = struct {
	idx: u32,
	name: str,
	init: state,
	fina: state,
	exc: int,
	flag_addr: u32,
	hash: [40]u8,
};

// Undefined-flag masks from the suite's 80386.csv ("0FBC", "D2.5", ...),
// and the hashes of withdrawn tests from revocation_list.txt.
let umasks: [](str, u32) = [];
let revoked: []str = [];

fn load_meta(dir: str) void = {
	let parent = path::dirname(strings::rtrim(dir, '/'));
	if (strings::hassuffix(dir, ".gz")) parent = path::dirname(parent);
	let buf = path::init(parent, "80386.csv")!;
	match (os::open(path::string(&buf))) {
	case let f: io::file =>
		defer io::close(f)!;
		const b = io::drain(f)!;
		defer free(b);
		const lines = strings::split(strings::fromutf8(b)!, "\n")!;
		defer free(lines);
		for (let i = 1z; i < len(lines); i += 1) {
			const f = strings::split(lines[i], ",")!;
			defer free(f);
			if (len(f) < 40 || f[39] == "") continue;
			const key = if (f[4] == "") strings::dup(f[0])!
				else strings::concat(f[0], ".", f[4])!;
			const m = strconv::stou32(strings::trimprefix(f[39], "0x"),
				strconv::base::HEX)!;
			append(umasks, (key, m))!;
		};
	case fs::error => fmt::errorfln("(fandt ikke {})", path::string(&buf))!;
	};
	buf = path::init(parent, "revocation_list.txt")!;
	match (os::open(path::string(&buf))) {
	case let f: io::file =>
		defer io::close(f)!;
		const b = io::drain(f)!;
		defer free(b);
		const lines = strings::split(strings::fromutf8(b)!, "\n")!;
		defer free(lines);
		for (let l .. lines) {
			const l = strings::trim(l);
			if (len(l) > 0) append(revoked, strings::dup(l)!)!;
		};
	case fs::error => void;
	};
};

// The flags mask for a test file: "670FBC.MOO.gz" is opcode 0FBC.
fn file_umask(base: str) u32 = {
	let name = strings::cut(base, ".MOO").0;
	for (len(name) > 2 && (strings::hasprefix(name, "66") ||
			strings::hasprefix(name, "67"))) {
		name = strings::sub(name, 2, strings::end);
	};
	for (let (k, m) .. umasks) if (k == name) return m;
	return 0xFFFF;
};

type stats = struct {
	files: size,
	tests: size,
	failed: size,
	bad_files: size,
};

fn rd32(b: []u8, p: size) u32 = b[p]: u32 | b[p + 1]: u32 << 8 |
	b[p + 2]: u32 << 16 | b[p + 3]: u32 << 24;

// RG32 or RM32: a bitmask, then the registers it names.
fn parse_regs(d: []u8, out: *[NREG]u32) u32 = {
	const have = rd32(d, 0);
	let q = 4z;
	for (let i = 0z; i < NREG; i += 1) {
		if (have & (1u32 << i: u8) == 0) continue;
		out[i] = rd32(d, q);
		q += 4;
	};
	return have;
};

fn parse_state(b: []u8, st: *state) void = {
	st.mask = [0xFFFFFFFF...];
	let p = 0z;
	for (p + 8 <= len(b)) {
		const id = strings::fromutf8_unsafe(b[p..p + 4]);
		const n = rd32(b, p + 4): size;
		const d = b[p + 8..p + 8 + n];
		switch (id) {
		case "RG32" => st.have = parse_regs(d, &st.regs);
		case "RM32" =>
			let m: [NREG]u32 = [0xFFFFFFFF...];
			parse_regs(d, &m);
			st.mask = m;
		case "RAM " =>
			const cnt = rd32(d, 0): size;
			for (let i = 0z; i < cnt; i += 1) {
				const e = 4 + i * 5;
				append(st.ram, (rd32(d, e), d[e + 4]))!;
			};
		case => void;
		};
		p += 8 + n;
	};
};

fn parse_test(b: []u8, t: *test) void = {
	t.idx = rd32(b, 0);
	t.exc = -1;
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
		case "EXCP" =>
			t.exc = d[0]: int;
			t.flag_addr = rd32(d, 1);
		case "HASH" =>
			const hex = strings::toutf8("0123456789abcdef");
			for (let i = 0z; i < 20; i += 1) {
				t.hash[i * 2] = hex[d[i] >> 4];
				t.hash[i * 2 + 1] = hex[d[i] & 15];
			};
		case => void;
		};
		p += 8 + n;
	};
};

fn free_test(t: *test) void = {
	free(t.init.ram);
	free(t.fina.ram);
};

fn get_regs(c: *x86::cpu) [NREG]u32 = [
	c.cr0, c.cr3,
	x86::get32(c, x86::AX), x86::get32(c, x86::BX), x86::get32(c, x86::CX),
	x86::get32(c, x86::DX), x86::get32(c, x86::SI), x86::get32(c, x86::DI),
	x86::get32(c, x86::BP), x86::get32(c, x86::SP),
	c.s[x86::CS], c.s[x86::DS], c.s[x86::ES], c.s[x86::FS], c.s[x86::GS],
	c.s[x86::SS], c.eip, x86::eflags(c), 0, 0,
];

// Runs one test. Returns a description of the first mismatch, or "".
fn run_test(c: *x86::cpu, t: *test, top: *[NREG]u32, why: []u8) str = {
	x86::reset(c);
	const r = &t.init.regs;
	c.cr0 = r[0];
	c.cr3 = r[1];
	const order: [8]size = [x86::AX, x86::BX, x86::CX, x86::DX, x86::SI,
		x86::DI, x86::BP, x86::SP];
	for (let i = 0z; i < 8; i += 1) x86::set32(c, order[i], r[2 + i]);
	c.s[x86::CS] = r[10]: u16;
	c.s[x86::DS] = r[11]: u16;
	c.s[x86::ES] = r[12]: u16;
	c.s[x86::FS] = r[13]: u16;
	c.s[x86::GS] = r[14]: u16;
	c.s[x86::SS] = r[15]: u16;
	c.ip = r[16]: u16;
	c.eip = r[16];
	c.flags = r[17]: u16;
	c.lz_op = 0;
	c.flagsh = (r[17] >> 16): u16;
	for (let (a, v) .. t.init.ram) c.mem[a & 0xFFFFFF] = v;
	c.log_writes = true;
	c.writes = c.writes[..0];

	for (let guard = 0; !c.halted && guard < 100000; guard += 1) {
		x86::step(c);
	};
	c.log_writes = false;

	let msg = "";
	if (!c.halted) msg = "kom aldrig til HLT";
	const got = get_regs(c);
	for (let i = 0z; i < 18 && msg == ""; i += 1) {
		let want = t.init.regs[i];
		if (t.fina.have & (1u32 << i: u8) != 0) want = t.fina.regs[i];
		const m = top[i] & t.fina.mask[i] & (if (i >= 10 && i <= 15) 0xFFFFu32
			else 0xFFFFFFFFu32);
		if (got[i] & m != want & m) {
			msg = fmt::bsprintf(why, "{} er {:_08X}, skulle være {:_08X}",
				REGS[i], got[i], want)!;
		};
	};
	// The flags an exception pushed may hold undefined bits too.
	const fm = top[R_EFLAGS] & t.fina.mask[R_EFLAGS];
	for (let (a, v) .. t.fina.ram) {
		if (msg != "") break;
		let g = c.mem[a & 0xFFFFFF];
		let v = v;
		if (t.exc >= 0 && a == t.flag_addr) {
			g &= fm: u8;
			v &= fm: u8;
		} else if (t.exc >= 0 && a == t.flag_addr + 1) {
			g &= (fm >> 8): u8;
			v &= (fm >> 8): u8;
		};
		if (g != v) {
			msg = fmt::bsprintf(why, "[{:_06X}] er {:_02X}, skulle være {:_02X}",
				a, g, v)!;
		};
	};
	// Writes the test doesn't list must have left the old value.
	for (let w .. c.writes) {
		if (msg != "") break;
		const a = w >> 8, old = w: u8;
		let listed = false;
		for (let (fa, _) .. t.fina.ram) {
			if (fa & 0xFFFFFF == a) listed = true;
		};
		if (!listed && c.mem[a] != old && first_write(c, a) == w) {
			msg = fmt::bsprintf(why, "skrev [{:_06X}] = {:_02X}, som ikke skulle ændres",
				a, c.mem[a])!;
		};
	};
	if (msg != "" && t.exc >= 0) {
		const n = len(msg);
		msg = fmt::bsprintf(why[n..], "{} (undtagelse {})", msg, t.exc)!;
	};

	for (let (a, _) .. t.init.ram) c.mem[a & 0xFFFFFF] = 0;
	for (let w .. c.writes) c.mem[w >> 8] = 0;
	return msg;
};

fn first_write(c: *x86::cpu, a: u32) u32 = {
	for (let w .. c.writes) if (w >> 8 == a) return w;
	return 0;
};

// Hashes of tests the suite has withdrawn are skipped: the file sits next
// to the test folder.
fn run_file(c: *x86::cpu, file: str, verbose: bool, show: size, st: *stats) void = {
	const base = path::basename(file);
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

	let top: [NREG]u32 = [0xFFFFFFFF...];
	const um = file_umask(base);
	let n = 0z, bad = 0z;
	let why: [512]u8 = [0...];
	let p = 0z;
	for (p + 8 <= len(data)) {
		const id = strings::fromutf8_unsafe(data[p..p + 4]);
		const l = rd32(data, p + 4): size;
		const d = data[p + 8..p + 8 + l];
		if (id == "RM32") {
			parse_regs(d, &top);
		} else if (id == "TEST") {
			top[R_EFLAGS] &= 0xFFFF0000 | um;
			let t = test { ... };
			parse_test(d, &t);
			let skip = false;
			for (let h .. revoked) {
				if (h == strings::fromutf8_unsafe(t.hash)) skip = true;
			};
			if (skip) {
				free_test(&t);
				p += 8 + l;
				continue;
			};
			const msg = run_test(c, &t, &top, why);
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
		if (verbose) fmt::printfln("{:-14} OK   {} tests", base, n)!;
	} else {
		fmt::printfln("{:-14} FEJL {} af {}", base, bad, n)!;
	};
};

fn is_test_file(name: str) bool =
	strings::hassuffix(name, ".MOO.gz") || strings::hassuffix(name, ".MOO");

export fn main() void = {
	const help: []getopt::help = [
		"kør SingleStepTests 80386-tests (real mode) mod Shifus 386",
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
	x86::set_model(c, x86::model::I386);
	x86::set_a20(c, true);
	let st = stats { ... };
	load_meta(cmd.args[0]);
	for (let f .. files) run_file(c, f, verbose, show, &st);

	const ok = st.tests - st.failed;
	fmt::printfln("\n{} filer, {} tests: {} rigtige, {} forkerte ({}.{}%)",
		st.files, st.tests, ok, st.failed,
		if (st.tests == 0) 0z else ok * 100 / st.tests,
		if (st.tests == 0) 0z else (ok * 1000 / st.tests) % 10)!;
	if (st.failed > 0 || st.bad_files > 0) os::exit(1);
};
