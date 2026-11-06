// Shifu — File Control Blocks: DOS 1's CP/M-style file functions
// (INT 21h AH=0Fh-28h). COMMAND.COM 2.x's DIR and many 80s programs use
// them.
//
// An FCB (at DS:DX, or 7 bytes in for an "extended" FCB starting FFh):
//	00  drive (0 = current, 3 = C:)
//	01  name, 8 bytes, space-padded      09  extension, 3 bytes
//	0C  current block                    0E  record size (128)
//	10  file size (4)                    14  date    16  time
//	18  Shifu: SFT index of the open file, 19: A5h when open
//	20  current record in the block      21  random record (4)
use fs;
use io;
use os;
use x86;

// The FCB at DS:DX: (segment, offset of the normal part, search
// attributes, extended?).
fn fcb_at(m: *machine) (u16, u16, u8, bool) = {
	const c = m.cpu;
	const s = c.s[x86::DS], o = c.r[x86::DX];
	if (x86::read8(c, s, o) == 0xFF) {
		return (s, o + 7, x86::read8(c, s, o + 6), true);
	};
	return (s, o, 0, false);
};

// The file name in an FCB, as a DOS path ("NAME.EXT").
fn fcb_name(m: *machine, s: u16, o: u16, at: u16) []u8 = {
	let n: []u8 = [];
	for (let i = 0u16; i < 8; i += 1) {
		const ch = x86::read8(m.cpu, s, o + at + i);
		if (ch == ' ') break;
		append(n, ch)!;
	};
	let ext = 0z;
	for (let i = 0u16; i < 3; i += 1) {
		const ch = x86::read8(m.cpu, s, o + at + 8 + i);
		if (ch == ' ') break;
		if (ext == 0) append(n, '.')!;
		append(n, ch)!;
		ext += 1;
	};
	return n;
};

fn fcb_file(m: *machine, s: u16, o: u16) (*openfile | void) = {
	if (x86::read8(m.cpu, s, o + 0x19) != 0xA5) return;
	const i = x86::read8(m.cpu, s, o + 0x18);
	if (i: size >= len(m.sft)) return;
	match (m.sft[i]) {
	case null => return;
	case let f: *openfile =>
		if (f.kind != devkind::FILE) return;
		return f;
	};
};

fn fcb_recsize(m: *machine, s: u16, o: u16) u16 = {
	let r = x86::read16(m.cpu, s, o + 0x0E);
	if (r == 0) {
		r = 128;
		x86::write16(m.cpu, s, o + 0x0E, r);
	};
	return r;
};

fn fcb_open(m: *machine, create: bool) u8 = {
	const c = m.cpu;
	const (s, o, _, _) = fcb_at(m);
	const name = fcb_name(m, s, o, 1);
	defer free(name);
	const comps = match (dos_split(m, name)) {
	case let p: [][]u8 => yield p;
	case doserr => return 0xFF;
	};
	defer free(comps);
	const (host, exists) = match (host_path(m, comps)) {
	case let r: (str, bool) => yield r;
	case doserr => return 0xFF;
	};
	defer free(host);
	if (!exists && !create) return 0xFF;
	const f = if (create) {
		yield match (os::create(host, 0o644, fs::flag::RDWR | fs::flag::TRUNC)) {
		case let f: io::file => yield f;
		case fs::error => return 0xFF;
		};
	} else {
		yield match (os::open(host, fs::flag::RDWR)) {
		case let f: io::file => yield f;
		case fs::error =>
			yield match (os::open(host, fs::flag::RDONLY)) {
			case let f: io::file => yield f;
			case fs::error => return 0xFF;
			};
		};
	};
	let slot = len(m.sft);
	for (let i = 0z; i < len(m.sft); i += 1) {
		if (m.sft[i] is null) {
			slot = i;
			break;
		};
	};
	if (slot >= 255) {
		io::close(f): void;
		return 0xFF;
	};
	const e = alloc(openfile { kind = devkind::FILE, f = f, refs = 1 })!;
	if (slot == len(m.sft)) append(m.sft, e)! else m.sft[slot] = e;

	let sz = 0u32, tm = 0u16, dt = 0u16;
	match (os::fstat(f)) {
	case let st: fs::filestat =>
		sz = st.sz: u32;
		const td = dos_time(st);
		tm = td.0;
		dt = td.1;
	case => void;
	};
	if (x86::read8(c, s, o) == 0) x86::write8(c, s, o, 3);
	x86::write16(c, s, o + 0x0C, 0);
	x86::write16(c, s, o + 0x0E, 128);
	x86::write16(c, s, o + 0x10, sz: u16);
	x86::write16(c, s, o + 0x12, (sz >> 16): u16);
	x86::write16(c, s, o + 0x14, dt);
	x86::write16(c, s, o + 0x16, tm);
	x86::write8(c, s, o + 0x18, slot: u8);
	x86::write8(c, s, o + 0x19, 0xA5);
	return 0;
};

fn fcb_close(m: *machine) u8 = {
	const (s, o, _, _) = fcb_at(m);
	if (fcb_file(m, s, o) is void) return 0xFF;
	sft_release(m, x86::read8(m.cpu, s, o + 0x18));
	x86::write8(m.cpu, s, o + 0x19, 0);
	return 0;
};

// Reads or writes n records at record number rec. Returns the FCB
// status (0 ok, 1 end of file, 3 partial record) and records done.
fn fcb_io(m: *machine, s: u16, o: u16, rec: u32, n: u16, write: bool) (u8, u16) = {
	const c = m.cpu;
	const f = match (fcb_file(m, s, o)) {
	case let f: *openfile => yield f;
	case void => return (1, 0);
	};
	const rs = fcb_recsize(m, s, o): size;
	const total = rs * n;
	match (io::seek(f.f, (rec: size * rs): io::off, io::whence::SET)) {
	case io::off => void;
	case => return (1, 0);
	};
	let buf: []u8 = alloc([0u8...], total)!;
	defer free(buf);
	if (write) {
		for (let i = 0z; i < total; i += 1) {
			buf[i] = x86::read8(c, m.dta_seg, m.dta_off + i: u16);
		};
		match (io::writeall(f.f, buf)) {
		case size => void;
		case => return (1, 0);
		};
		// Keep the file size in the FCB up to date.
		const end = rec: size * rs + total;
		const sz = x86::read16(c, s, o + 0x10): u32 | x86::read16(c, s, o + 0x12): u32 << 16;
		if (end > sz) {
			x86::write16(c, s, o + 0x10, end: u16);
			x86::write16(c, s, o + 0x12, (end >> 16): u16);
		};
		return (0, n);
	};
	let got = 0z;
	for (got < total) {
		match (io::read(f.f, buf[got..])) {
		case let k: size => got += k;
		case => break;
		};
	};
	write_bytes(m, m.dta_seg, m.dta_off, buf); // zero-padded
	if (got == 0) return (1, 0);
	const full = (got / rs): u16;
	if (got % rs != 0) return (3, full + 1);
	return (0, full);
};

fn fcb_current(m: *machine, s: u16, o: u16) u32 =
	x86::read16(m.cpu, s, o + 0x0C): u32 * 128 + x86::read8(m.cpu, s, o + 0x20);

fn fcb_set_current(m: *machine, s: u16, o: u16, rec: u32) void = {
	x86::write16(m.cpu, s, o + 0x0C, (rec / 128): u16);
	x86::write8(m.cpu, s, o + 0x20, (rec % 128): u8);
};

fn fcb_random(m: *machine, s: u16, o: u16) u32 =
	x86::read16(m.cpu, s, o + 0x21): u32 | x86::read8(m.cpu, s, o + 0x23): u32 << 16;

fn fcb_set_random(m: *machine, s: u16, o: u16, rec: u32) void = {
	x86::write16(m.cpu, s, o + 0x21, rec: u16);
	x86::write8(m.cpu, s, o + 0x23, (rec >> 16): u8);
	if (fcb_recsize(m, s, o) < 64) x86::write8(m.cpu, s, o + 0x24, (rec >> 24): u8);
};

// Writes a search hit to the DTA as an FCB plus directory entry.
fn fcb_found(m: *machine, f: *found, ext: bool, attr: u8) void = {
	const c = m.cpu;
	let d = m.dta_off;
	if (ext) {
		x86::write8(c, m.dta_seg, d, 0xFF);
		for (let i = 1u16; i < 6; i += 1) x86::write8(c, m.dta_seg, d + i, 0);
		x86::write8(c, m.dta_seg, d + 6, attr);
		d += 7;
	};
	x86::write8(c, m.dta_seg, d, 3);
	let n = 0z;
	for (n < len(f.name) && f.name[n] != 0) n += 1;
	let fcbname: [11]u8 = [' '...];
	if (f.name[0] == '.') {
		fcbname[..n] = f.name[..n];
	} else {
		fcbname = fcb_pattern(f.name[..n]);
	};
	write_bytes(m, m.dta_seg, d + 1, fcbname);
	x86::write8(c, m.dta_seg, d + 12, f.attr);
	for (let i = 13u16; i < 23; i += 1) x86::write8(c, m.dta_seg, d + i, 0);
	x86::write16(c, m.dta_seg, d + 23, f.time);
	x86::write16(c, m.dta_seg, d + 25, f.date);
	x86::write16(c, m.dta_seg, d + 27, 0);
	x86::write16(c, m.dta_seg, d + 29, f.sz: u16);
	x86::write16(c, m.dta_seg, d + 31, (f.sz >> 16): u16);
};

fn fcb_search(m: *machine, first: bool) u8 = {
	const c = m.cpu;
	const (s, o, attr, ext) = fcb_at(m);
	if (first) {
		let pat: [11]u8 = [0...];
		for (let i = 0u16; i < 11; i += 1) pat[i] = upper(x86::read8(c, s, o + 1 + i));
		const cwd = split_bytes(m.cwd);
		defer free(cwd);
		const id = match (find_start_fcb(m, cwd, &pat, attr)) {
		case let id: u16 => yield id;
		case doserr => return 0xFF;
		};
		x86::write16(c, s, o + 0x0C, id);
		x86::write16(c, s, o + 0x0E, 0x4653); // "SF"
	};
	if (x86::read16(c, s, o + 0x0E) != 0x4653) return 0xFF;
	const f = match (find_take(m, x86::read16(c, s, o + 0x0C))) {
	case let f: *found => yield f;
	case doserr => return 0xFF;
	};
	fcb_found(m, f, ext, attr);
	return 0;
};

// Deletes (or renames) every file an FCB pattern matches.
fn fcb_delete_rename(m: *machine, rename: bool) u8 = {
	const c = m.cpu;
	const (s, o, _, _) = fcb_at(m);
	let pat: [11]u8 = [0...];
	for (let i = 0u16; i < 11; i += 1) pat[i] = upper(x86::read8(c, s, o + 1 + i));
	const cwd = split_bytes(m.cwd);
	defer free(cwd);
	const id = match (find_start_fcb(m, cwd, &pat, 0)) {
	case let id: u16 => yield id;
	case doserr => return 0xFF;
	};
	let any = false;
	for (true) {
		const f = match (find_take(m, id)) {
		case let f: *found => yield f;
		case doserr => break;
		};
		let n = 0z;
		for (n < len(f.name) && f.name[n] != 0) n += 1;
		let oldname: []u8 = alloc(f.name[..n]...)!;
		defer free(oldname);
		const (host, exists) = match (resolve_bytes(m, oldname)) {
		case let r: (str, bool) => yield r;
		case doserr => continue;
		};
		defer free(host);
		if (!exists) continue;
		if (!rename) {
			match (os::remove(host)) {
			case void => any = true;
			case fs::error => void;
			};
			continue;
		};
		// The new name: '?' keeps the old name's character.
		const old = fcb_pattern(oldname);
		let nn: [11]u8 = [0...];
		for (let i = 0u16; i < 11; i += 1) {
			const ch = upper(x86::read8(c, s, o + 0x11 + i));
			nn[i] = if (ch == '?') old[i] else ch;
		};
		let newname: []u8 = [];
		defer free(newname);
		for (let i = 0z; i < 8 && nn[i] != ' '; i += 1) append(newname, nn[i])!;
		if (nn[8] != ' ') {
			append(newname, '.')!;
			for (let i = 8z; i < 11 && nn[i] != ' '; i += 1) append(newname, nn[i])!;
		};
		const (to, taken) = match (resolve_bytes(m, newname)) {
		case let r: (str, bool) => yield r;
		case doserr => continue;
		};
		defer free(to);
		if (taken) continue;
		match (os::rename(host, to)) {
		case void => any = true;
		case fs::error => void;
		};
	};
	return if (any) 0 else 0xFF;
};

fn resolve_bytes(m: *machine, raw: []u8) ((str, bool) | doserr) = {
	const comps = dos_split(m, raw)?;
	defer free(comps);
	return host_path(m, comps);
};

// INT 21h AH=0Fh-28h. Returns the AL value.
fn fcb_call(m: *machine, ah: u8) u8 = {
	const c = m.cpu;
	switch (ah) {
	case 0x0F => return fcb_open(m, false);
	case 0x10 => return fcb_close(m);
	case 0x11 => return fcb_search(m, true);
	case 0x12 => return fcb_search(m, false);
	case 0x13 => return fcb_delete_rename(m, false);
	case 0x16 => return fcb_open(m, true);
	case 0x17 => return fcb_delete_rename(m, true);
	case => void;
	};
	const (s, o, _, _) = fcb_at(m);
	switch (ah) {
	case 0x14, 0x15 => // sequential read / write
		const rec = fcb_current(m, s, o);
		const (st, n) = fcb_io(m, s, o, rec, 1, ah == 0x15);
		fcb_set_current(m, s, o, rec + n);
		return st;
	case 0x21, 0x22 => // random read / write
		const rec = fcb_random(m, s, o);
		fcb_set_current(m, s, o, rec);
		const (st, _) = fcb_io(m, s, o, rec, 1, ah == 0x22);
		return st;
	case 0x23 => // file size in records
		if (fcb_open(m, false) != 0) return 0xFF;
		const sz = x86::read16(c, s, o + 0x10): u32 | x86::read16(c, s, o + 0x12): u32 << 16;
		const rs = 128u32;
		fcb_close(m);
		fcb_set_random(m, s, o, (sz + rs - 1) / rs);
		return 0;
	case 0x24 => // set random record from the current one
		fcb_set_random(m, s, o, fcb_current(m, s, o));
		return 0;
	case 0x27, 0x28 => // random block read / write, CX records
		const rec = fcb_random(m, s, o);
		const n = c.r[x86::CX];
		if (ah == 0x28 && n == 0) {
			// Set the file size.
			match (fcb_file(m, s, o)) {
			case let f: *openfile =>
				truncate(f.f, (rec: size * fcb_recsize(m, s, o)): io::off);
			case void => void;
			};
			return 0;
		};
		const (st, k) = fcb_io(m, s, o, rec, n, ah == 0x28);
		c.r[x86::CX] = k;
		fcb_set_random(m, s, o, rec + k);
		fcb_set_current(m, s, o, rec + k);
		return st;
	case => return 0xFF;
	};
};
