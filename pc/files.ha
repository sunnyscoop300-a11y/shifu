// Shifu — drive C: is a folder on the host. DOS paths are uppercase CHARSET
// 8.3 names; host names are matched without regard to case, and æøå are
// translated between CHARSET and UTF-8.
use errors;
use fs;
use io;
use os;
use path;
use strings;
use time::date;
use x86;

export type devkind = enum {
	FILE,
	CON,
	NUL,
	PRN,
	AUX,
	HOSTIN,  // the host's stdin (redirected input)
	HOSTOUT, // the host's stdout (redirected output)
};

export type openfile = struct {
	kind: devkind,
	f: io::file,
	refs: uint,
};

// One FindFirst search in progress.
export type search = struct {
	id: u16,
	hits: []found,
	pos: size,
};

export type found = struct {
	name: [13]u8, // NAME.EXT, zero-terminated
	attr: u8,
	time: u16,
	date: u16,
	sz: u32,
};

fn files_init(m: *machine) (void | nomem) = {
	// Handles 0-2 are CON, 3 is AUX, 4 is PRN.
	append(m.sft, alloc(openfile { kind = devkind::CON, refs = 3, ... })?)?;
	append(m.sft, alloc(openfile { kind = devkind::AUX, refs = 1, ... })?)?;
	append(m.sft, alloc(openfile { kind = devkind::PRN, refs = 1, ... })?)?;
};

fn files_close_all(m: *machine) void = {
	for (let e .. m.sft) match (e) {
	case null => void;
	case let f: *openfile =>
		if (f.kind == devkind::FILE) io::close(f.f): void;
		free(f);
	};
	free(m.sft);
};

fn finds_free(m: *machine) void = {
	for (let s .. m.finds) free(s.hits);
	free(m.finds);
};

// Maps a host file system error to a DOS error code.
fn fserr(e: fs::error) u16 = {
	match (e) {
	case errors::noentry => return 2;
	case errors::noaccess => return 5;
	case errors::exists => return 0x50;
	case => return 5;
	};
};

// ---- Paths ----

fn eqb(a: []u8, b: []u8) bool = {
	if (len(a) != len(b)) return false;
	for (let i = 0z; i < len(a); i += 1) if (a[i] != b[i]) return false;
	return true;
};

// Reads a zero-terminated string from emulated memory.
fn read_asciiz(m: *machine, seg: u16, off: u16) []u8 = {
	let s: []u8 = [];
	for (let i = 0u16; i < 256; i += 1) {
		const ch = x86::read8(m.cpu, seg, off + i);
		if (ch == 0) break;
		append(s, ch)!;
	};
	return s;
};

fn write_bytes(m: *machine, seg: u16, off: u16, b: []u8) void = {
	for (let i = 0z; i < len(b); i += 1) {
		x86::write8(m.cpu, seg, off + i: u16, b[i]);
	};
};

// Turns a DOS path into the list of its components from the root of C:
// (uppercase, "." and ".." resolved). The caller frees the result.
fn dos_split(m: *machine, raw: []u8) ([][]u8 | doserr) = {
	let p = raw;
	if (len(p) >= 2 && p[1] == ':') {
		const d = upper(p[0]);
		if (d != 'C') return 15: doserr; // invalid drive
		p = p[2..];
	};
	let comps: [][]u8 = [];
	const absolute = len(p) > 0 && (p[0] == '\\' || p[0] == '/');
	if (!absolute) {
		for (let c .. split_bytes(m.cwd)) append(comps, c)!;
	};
	for (let c .. split_bytes(p)) {
		if (eqb(c, ['.'])) continue;
		if (eqb(c, ['.', '.'])) {
			if (len(comps) == 0) {
				free(comps);
				return 3: doserr;
			};
			delete(comps[len(comps) - 1]);
			continue;
		};
		append(comps, c)!;
	};
	return comps;
};

// Splits on \ and /, uppercasing. Returns slices of a fresh copy.
fn split_bytes(p: []u8) [][]u8 = {
	let up: []u8 = alloc(p...)!;
	for (let i = 0z; i < len(up); i += 1) up[i] = upper(up[i]);
	let out: [][]u8 = [];
	let start = 0z;
	for (let i = 0z; i <= len(up); i += 1) {
		if (i == len(up) || up[i] == '\\' || up[i] == '/') {
			if (i > start) append(out, up[start..i])!;
			start = i + 1;
		};
	};
	// The copy stays alive as long as the slices; it is small.
	return out;
};

// Joins components into "A\B\C" (no leading backslash).
fn dos_join(comps: [][]u8) []u8 = {
	let s: []u8 = [];
	for (let i = 0z; i < len(comps); i += 1) {
		if (i > 0) append(s, '\\')!;
		append(s, comps[i]...)!;
	};
	return s;
};

// A host file name as an uppercase DOS name, if it is a valid 8.3 name
// in CHARSET.
fn host_to_dos(name: str, out: []u8) (size | void) = {
	let n = 0z, base = 0z, ext = 0z, dot = false;
	if (name == "." || name == "..") {
		out[..len(name)] = strings::toutf8(name);
		return len(name);
	};
	let it = strings::iter(name);
	for (let r => strings::next(&it)) {
		const b = match (from_unicode(r)) {
		case let b: u8 => yield b;
		case void => return;
		};
		if (b == '.') {
			if (dot || base == 0) return;
			dot = true;
		} else if (b <= ' ' || b == '\\' || b == '/' || b == ':' ||
			b == '*' || b == '?') {
			return;
		} else if (dot) {
			ext += 1;
		} else {
			base += 1;
		};
		if (n >= 12) return;
		out[n] = upper(b);
		n += 1;
	};
	if (base > 8 || ext > 3 || (dot && ext == 0)) return;
	return n;
};

// Finds the host name matching a DOS name in a host folder.
fn host_lookup(dir: str, want: []u8) (str | void) = {
	const ents = match (os::readdir(dir)) {
	case let e: []fs::dirent => yield e;
	case => return;
	};
	defer fs::dirents_free(ents);
	let buf: [13]u8 = [0...];
	for (let e .. ents) {
		match (host_to_dos(e.name, buf)) {
		case let n: size =>
			if (eqb(buf[..n], want)) return strings::dup(e.name)!;
		case void => void;
		};
	};
};

// The UTF-8 form of a DOS name (for creating host files).
fn dos_to_host_name(b: []u8) str = {
	let s: []u8 = [];
	for (let ch .. b) {
		const enc = strings::toutf8(strings::fromrunes([CHARSET[ch]])!);
		append(s, enc...)!;
		free(enc);
	};
	return strings::fromutf8(s)!;
};

// Finds the host path for DOS path components. The last component may
// be missing (for creating files): then the second value is false.
fn host_path(m: *machine, comps: [][]u8) ((str, bool) | doserr) = {
	let p = strings::dup(m.root)!;
	for (let i = 0z; i < len(comps); i += 1) {
		const last = i + 1 == len(comps);
		match (host_lookup(p, comps[i])) {
		case let name: str =>
			let buf = path::init(p, name)!;
			free(name);
			free(p);
			p = strings::dup(path::string(&buf))!;
		case void =>
			if (!last) {
				free(p);
				return 3: doserr; // path not found
			};
			const name = dos_to_host_name(comps[i]);
			let buf = path::init(p, name)!;
			free(name);
			free(p);
			return (strings::dup(path::string(&buf))!, false);
		};
	};
	return (p, true);
};

// Resolves a DOS path at seg:off to a host path.
fn resolve(m: *machine, seg: u16, off: u16) ((str, bool) | doserr) = {
	const raw = read_asciiz(m, seg, off);
	defer free(raw);
	const comps = dos_split(m, raw)?;
	defer free(comps);
	return host_path(m, comps);
};

// The device a DOS name refers to, if any (CON, NUL, ...).
fn device_of(m: *machine, seg: u16, off: u16) (devkind | void) = {
	const raw = read_asciiz(m, seg, off);
	defer free(raw);
	let start = 0z;
	for (let i = 0z; i < len(raw); i += 1) {
		if (raw[i] == '\\' || raw[i] == '/' || raw[i] == ':') start = i + 1;
	};
	let name: []u8 = [];
	defer free(name);
	for (let i = start; i < len(raw) && raw[i] != '.'; i += 1) {
		append(name, upper(raw[i]))!;
	};
	const n = strings::fromutf8_unsafe(name);
	switch (n) {
	case "CON" => return devkind::CON;
	case "NUL" => return devkind::NUL;
	case "PRN", "LPT1" => return devkind::PRN;
	case "AUX", "COM1" => return devkind::AUX;
	case => return;
	};
};

// ---- Handles ----

// The current program's job file table: (segment, offset, size).
fn jft(m: *machine) (u16, u16, u16) = {
	const c = m.cpu;
	return (x86::read16(c, m.psp, 0x36), x86::read16(c, m.psp, 0x34),
		x86::read16(c, m.psp, 0x32));
};

fn handle_file(m: *machine, h: u16) (*openfile | doserr) = {
	const (seg, off, n) = jft(m);
	if (h >= n) return 6: doserr;
	const i = x86::read8(m.cpu, seg, off + h);
	if (i == 0xFF || i: size >= len(m.sft)) return 6: doserr;
	match (m.sft[i]) {
	case null => return 6: doserr;
	case let f: *openfile => return f;
	};
};

// Puts an open file in the SFT and gives the program a handle for it.
fn new_handle(m: *machine, of: openfile) (u16 | doserr) = {
	const (seg, off, n) = jft(m);
	let h = 0u16;
	for (h < n && x86::read8(m.cpu, seg, off + h) != 0xFF) h += 1;
	if (h >= n) return 4: doserr; // too many open files
	let slot = len(m.sft);
	for (let i = 0z; i < len(m.sft); i += 1) {
		if (m.sft[i] is null) {
			slot = i;
			break;
		};
	};
	if (slot >= 255) return 4: doserr;
	const e = alloc(of)!;
	e.refs = 1;
	if (slot == len(m.sft)) append(m.sft, e)! else m.sft[slot] = e;
	x86::write8(m.cpu, seg, off + h, slot: u8);
	return h;
};

fn sft_release(m: *machine, i: u8) void = {
	if (i: size >= len(m.sft)) return;
	match (m.sft[i]) {
	case null => void;
	case let f: *openfile =>
		f.refs -= 1;
		if (f.refs == 0) {
			if (f.kind == devkind::FILE) io::close(f.f): void;
			free(f);
			m.sft[i] = null;
		};
	};
};

fn close_handle(m: *machine, h: u16) (void | doserr) = {
	handle_file(m, h)?;
	const (seg, off, _) = jft(m);
	const i = x86::read8(m.cpu, seg, off + h);
	x86::write8(m.cpu, seg, off + h, 0xFF);
	sft_release(m, i);
};

// Makes handle `to` refer to the same file as `from`.
fn dup_handle(m: *machine, from: u16, to: (u16 | void)) (u16 | doserr) = {
	const f = handle_file(m, from)?;
	const (seg, off, n) = jft(m);
	const i = x86::read8(m.cpu, seg, off + from);
	let h = 0u16;
	match (to) {
	case let t: u16 =>
		if (t >= n) return 6: doserr;
		if (x86::read8(m.cpu, seg, off + t) != 0xFF) close_handle(m, t)?;
		h = t;
	case void =>
		for (h < n && x86::read8(m.cpu, seg, off + h) != 0xFF) h += 1;
		if (h >= n) return 4: doserr;
	};
	x86::write8(m.cpu, seg, off + h, i);
	f.refs += 1;
	return h;
};

// Closes every handle a program has open.
fn close_program_files(m: *machine, psp: u16) void = {
	const c = m.cpu;
	const seg = x86::read16(c, psp, 0x36), off = x86::read16(c, psp, 0x34);
	const n = x86::read16(c, psp, 0x32);
	for (let h = 0u16; h < n; h += 1) {
		const i = x86::read8(c, seg, off + h);
		if (i != 0xFF) {
			x86::write8(c, seg, off + h, 0xFF);
			sft_release(m, i);
		};
	};
};

// ---- Opening ----

fn is_dir(host: str) bool = match (os::stat(host)) {
case let st: fs::filestat => yield fs::isdir(st.mode);
case fs::error => yield false;
};

fn open_file(m: *machine, seg: u16, off: u16, mode: u8) (u16 | doserr) = {
	match (device_of(m, seg, off)) {
	case let d: devkind =>
		return new_handle(m, openfile { kind = d, ... });
	case void => void;
	};
	const (host, exists) = resolve(m, seg, off)?;
	defer free(host);
	if (!exists) return 2: doserr;
	// A directory (also "", which is the current one) can't be opened:
	// not found for an empty name, access denied otherwise, as in DOS.
	if (is_dir(host)) {
		return if (x86::read8(m.cpu, seg, off) == 0) 2: doserr else 5: doserr;
	};
	const flags = switch (mode & 3) {
	case 0 => yield fs::flag::RDONLY;
	case 1 => yield fs::flag::WRONLY;
	case => yield fs::flag::RDWR;
	};
	match (os::open(host, flags)) {
	case let f: io::file =>
		return new_handle(m, openfile { kind = devkind::FILE, f = f, ... });
	case let e: fs::error =>
		return fserr(e): doserr;
	};
};

fn create_file(m: *machine, seg: u16, off: u16, must_be_new: bool) (u16 | doserr) = {
	match (device_of(m, seg, off)) {
	case let d: devkind =>
		return new_handle(m, openfile { kind = d, ... });
	case void => void;
	};
	const (host, exists) = resolve(m, seg, off)?;
	defer free(host);
	if (x86::read8(m.cpu, seg, off) == 0) return 3: doserr;
	if (exists && is_dir(host)) return 5: doserr;
	if (exists && must_be_new) return 0x50: doserr;
	match (os::create(host, 0o644, fs::flag::RDWR | fs::flag::TRUNC)) {
	case let f: io::file =>
		return new_handle(m, openfile { kind = devkind::FILE, f = f, ... });
	case let e: fs::error =>
		return fserr(e): doserr;
	};
};

// ---- File times ----

// A host time as DOS packed (time, date).
fn dos_time(t: fs::filestat) (u16, u16) = {
	const d = date::from_instant(date::LOCAL, t.mtime);
	const y = date::year(&d);
	const tm = (date::hour(&d) << 11 | date::minute(&d) << 5 |
		date::second(&d) / 2): u16;
	const dt = (if (y < 1980) 0 else ((y - 1980) << 9 |
		date::month(&d) << 5 | date::day(&d))): u16;
	return (tm, dt);
};

// ---- FindFirst / FindNext ----

// Expands a DOS name pattern to FCB form: 11 bytes, '?' for wildcards.
fn fcb_pattern(p: []u8) [11]u8 = {
	let out: [11]u8 = [' '...];
	let i = 0z, j = 0z;
	for (i < len(p) && p[i] != '.' && j < 8; i += 1) {
		if (p[i] == '*') {
			for (j < 8) {
				out[j] = '?';
				j += 1;
			};
		} else {
			out[j] = upper(p[i]);
			j += 1;
		};
	};
	for (i < len(p) && p[i] != '.') i += 1;
	if (i < len(p)) i += 1;
	j = 8;
	for (i < len(p) && j < 11; i += 1) {
		if (p[i] == '*') {
			for (j < 11) {
				out[j] = '?';
				j += 1;
			};
		} else {
			out[j] = upper(p[i]);
			j += 1;
		};
	};
	return out;
};

fn fcb_match(pat: *[11]u8, name: []u8) bool = {
	const n = if (eqb(name, ['.']) || eqb(name, ['.', '.'])) {
		let f: [11]u8 = [' '...];
		f[..len(name)] = name;
		yield f;
	} else fcb_pattern(name);
	for (let i = 0z; i < 11; i += 1) {
		if (pat[i] != '?' && pat[i] != n[i]) return false;
	};
	return true;
};

// Starts a search for a DOS path pattern; returns the search's id.
fn find_start(m: *machine, raw: []u8, attr: u8) (u16 | doserr) = {
	const comps = dos_split(m, raw)?;
	defer free(comps);
	if (len(comps) == 0) return 3: doserr;
	const pat = fcb_pattern(comps[len(comps) - 1]);
	return find_start_fcb(m, comps[..len(comps) - 1], &pat, attr);
};

// Starts a search in a folder for an 11-byte FCB pattern.
fn find_start_fcb(m: *machine, dir: [][]u8, pat: *[11]u8, attr: u8) (u16 | doserr) = {
	let hits: []found = [];
	if (attr == 0x08) {
		// Only the volume label.
		let f = found { attr = 0x08, ... };
		f.name[..5] = strings::toutf8("SHIFU");
		append(hits, f)!;
	} else {
		const (host, exists) = host_path(m, dir)?;
		defer free(host);
		if (!exists) return 3: doserr;
		const ents = match (os::readdir(host)) {
		case let e: []fs::dirent => yield e;
		case => return 3: doserr;
		};
		defer fs::dirents_free(ents);
		let names: []str = [];
		defer free(names);
		if (len(dir) > 0) {
			append(names, ".")!;
			append(names, "..")!;
		};
		for (let e .. ents) append(names, e.name)!;
		for (let name .. names) {
			let f = found { ... };
			const n = match (host_to_dos(name, f.name)) {
			case let n: size => yield n;
			case void => continue;
			};
			if (!fcb_match(pat, f.name[..n])) continue;
			let full = path::init(host, name)!;
			const st = match (os::stat(path::string(&full))) {
			case let s: fs::filestat => yield s;
			case => continue;
			};
			if (fs::isdir(st.mode)) {
				if (attr & 0x10 == 0) continue;
				f.attr = 0x10;
			} else {
				f.attr = 0x20;
				f.sz = if (st.sz > 0xFFFFFFFF) 0xFFFFFFFF else st.sz: u32;
			};
			const (t, d) = dos_time(st);
			f.time = t;
			f.date = d;
			append(hits, f)!;
		};
	};
	if (len(hits) == 0) {
		free(hits);
		return 0x12: doserr; // no more files
	};
	// Keep at most 32 searches going.
	m.find_id += 1;
	if (m.find_id == 0) m.find_id = 1;
	if (len(m.finds) >= 32) {
		free(m.finds[0].hits);
		delete(m.finds[0]);
	};
	append(m.finds, search { id = m.find_id, hits = hits, pos = 0 })!;
	return m.find_id;
};

// The next hit of a search.
fn find_take(m: *machine, id: u16) (*found | doserr) = {
	for (let s &.. m.finds) {
		if (s.id != id) continue;
		if (s.pos >= len(s.hits)) return 0x12: doserr;
		s.pos += 1;
		return &s.hits[s.pos - 1];
	};
	return 0x12: doserr;
};

// INT 21h AH=4Eh: FindFirst with the ASCIIZ pattern at seg:off.
fn find_first(m: *machine, seg: u16, off: u16, attr: u8) (void | doserr) = {
	const raw = read_asciiz(m, seg, off);
	defer free(raw);
	const id = find_start(m, raw, attr)?;
	const c = m.cpu;
	x86::write8(c, m.dta_seg, m.dta_off, 3); // drive C:
	x86::write16(c, m.dta_seg, m.dta_off + 0x0D, id);
	x86::write16(c, m.dta_seg, m.dta_off + 0x0F, 0x4853); // "SH"
	return find_next(m);
};

// INT 21h AH=4Fh: the next hit, into the DTA.
fn find_next(m: *machine) (void | doserr) = {
	const c = m.cpu;
	const id = x86::read16(c, m.dta_seg, m.dta_off + 0x0D);
	if (x86::read16(c, m.dta_seg, m.dta_off + 0x0F) != 0x4853) {
		return 0x12: doserr;
	};
	const f = find_take(m, id)?;
	const d = m.dta_seg, o = m.dta_off;
	x86::write8(c, d, o + 0x15, f.attr);
	x86::write16(c, d, o + 0x16, f.time);
	x86::write16(c, d, o + 0x18, f.date);
	x86::write16(c, d, o + 0x1A, f.sz: u16);
	x86::write16(c, d, o + 0x1C, (f.sz >> 16): u16);
	write_bytes(m, d, o + 0x1E, f.name);
};
