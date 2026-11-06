// Shifu — loading and ending programs: PSP, environment, .COM and .EXE
// (MZ) files, EXEC (INT 21h AH=4Bh) and terminate.
use fs;
use io;
use os;
use strings;
use x86;

fn rd16(b: []u8, p: size) u16 = {
	if (p + 1 >= len(b)) return 0;
	return b[p]: u16 | b[p + 1]: u16 << 8;
};

fn read_host_file(host: str) ([]u8 | doserr) = {
	const f = match (os::open(host)) {
	case let f: io::file => yield f;
	case let e: fs::error => return fserr(e): doserr;
	};
	defer io::close(f): void;
	match (io::drain(f)) {
	case let b: []u8 => return b;
	case => return 5: doserr;
	};
};

// Builds an environment block: the strings, an empty string, the word 1
// and the program's full name.
fn make_env(m: *machine, parent_env: u16, progname: []u8, owner: u16) (u16 | doserr) = {
	let b: []u8 = [];
	defer free(b);
	if (parent_env == 0) {
		const vars = ["PATH=C:\\", "COMSPEC=C:\\COMMAND.COM",
			"PROMPT=$P$G", "BLASTER=A220 I7 D1 T3"];
		for (let v .. vars) {
			append(b, strings::toutf8(v)...)!;
			append(b, 0)!;
		};
	} else {
		// Copy the parent's strings up to the double zero.
		for (let i = 0u16; i < 0x7FFF; i += 1) {
			const ch = x86::read8(m.cpu, parent_env, i);
			append(b, ch)!;
			if (ch == 0 && (i == 0 || x86::read8(m.cpu, parent_env, i - 1) == 0)) {
				break;
			};
		};
		if (len(b) > 0) delete(b[len(b) - 1]);
	};
	if (len(b) == 0) append(b, 0)!;
	append(b, [0, 1, 0]...)!;
	append(b, progname...)!;
	append(b, 0)!;
	const paras = ((len(b) + 15) / 16): u16;
	const seg = match (mem_alloc(m, paras, owner)) {
	case let s: u16 => yield s;
	case let e: (u16, doserr) => return e.1;
	};
	write_bytes(m, seg, 0, b);
	return seg;
};

// Fills an FCB from the start of a command-line word (just the drive and
// the 8.3 name, the way old programs expect).
fn parse_fcb(m: *machine, seg: u16, off: u16, word: []u8) void = {
	x86::write8(m.cpu, seg, off, 0);
	for (let i = 1u16; i < 12; i += 1) x86::write8(m.cpu, seg, off + i, ' ');
	if (len(word) == 0 || word[0] == '/') return;
	let w = word;
	if (len(w) >= 2 && w[1] == ':') {
		x86::write8(m.cpu, seg, off, upper(w[0]) - 'A' + 1);
		w = w[2..];
	};
	const pat = fcb_pattern(w);
	for (let i = 0u16; i < 11; i += 1) {
		x86::write8(m.cpu, seg, off + 1 + i, pat[i]);
	};
};

// The words of a command tail (for the FCBs).
fn tail_words(tail: []u8) ([]u8, []u8) = {
	let words: [2][]u8 = [[]...];
	let n = 0z, i = 0z;
	for (n < 2) {
		for (i < len(tail) && (tail[i] == ' ' || tail[i] == '\t')) i += 1;
		if (i >= len(tail)) break;
		const start = i;
		for (i < len(tail) && tail[i] != ' ' && tail[i] != '\t') i += 1;
		words[n] = tail[start..i];
		n += 1;
	};
	return (words[0], words[1]);
};

// Loads a program into memory and makes it the current one. The CPU's
// registers are set so the next step runs it.
//	host     its host path
//	dosname  its full DOS name, e.g. C:\GAMES\FOO.EXE
//	tail     the command line after the name
fn load(m: *machine, host: str, dosname: []u8, tail: []u8, parent: u16,
	parent_env: u16) (void | doserr) = {
	const c = m.cpu;
	const file = read_host_file(host)?;
	defer free(file);
	const exe = len(file) >= 0x1C &&
		((file[0] == 'M' && file[1] == 'Z') || (file[0] == 'Z' && file[1] == 'M'));

	// How much memory the program needs and wants, in paragraphs.
	let need = 0u32, want = 0xFFFFu32;
	let hdr = 0z, image = len(file);
	if (exe) {
		const pages = rd16(file, 4): size, last = rd16(file, 2): size;
		hdr = rd16(file, 8): size * 16;
		image = pages * 512 - (if (last != 0) 512 - last else 0z) - hdr;
		if (hdr + image > len(file)) image = len(file) - hdr;
		const paras = ((image + 15) / 16): u32;
		need = 0x10 + paras + rd16(file, 0x0A);
		want = 0x10 + paras + rd16(file, 0x0C);
		if (want > 0xFFFF || rd16(file, 0x0C) == 0) want = 0xFFFF;
	} else {
		if (len(file) > 0xFF00 - 0x100) return 8: doserr;
		need = ((len(file) + 0x100 + 0x100 + 15) / 16): u32;
	};

	// Environment first, then the program gets the biggest block.
	const env = make_env(m, parent_env, dosname, 8)?;
	const largest = match (mem_alloc(m, 0xFFFF, 0)) {
	case u16 => abort();
	case let e: (u16, doserr) => yield e.0;
	};
	if (largest: u32 < need) {
		mem_free(m, env): void;
		return 8: doserr;
	};
	const blk = if (want < largest) want: u16 else largest;
	const psp = match (mem_alloc(m, blk, 8)) {
	case let s: u16 => yield s;
	case let e: (u16, doserr) =>
		mem_free(m, env): void;
		return e.1;
	};
	x86::write16(c, env - 1, 1, psp);
	x86::write16(c, psp - 1, 1, psp);
	// MCB name: the file name without extension.
	let base = 0z;
	for (let i = 0z; i < len(dosname); i += 1) {
		if (dosname[i] == '\\') base = i + 1;
	};
	let name = dosname[base..];
	for (let i = 0z; i < len(name); i += 1) {
		if (name[i] == '.') {
			name = name[..i];
			break;
		};
	};
	mcb_name(m, psp, name);
	mcb_name(m, env, name);

	// The PSP.
	for (let i = 0u16; i < 0x100; i += 1) x86::write8(c, psp, i, 0);
	x86::write16(c, psp, 0x00, 0x20CD);        // INT 20h
	x86::write16(c, psp, 0x02, psp + blk);    // end of our memory
	for (let i = 0u16; i < 3; i += 1) {        // INT 22h-24h vectors
		x86::write16(c, psp, 0x0A + i * 4, x86::read16(c, 0, (0x22 + i) * 4));
		x86::write16(c, psp, 0x0C + i * 4, x86::read16(c, 0, (0x22 + i) * 4 + 2));
	};
	x86::write16(c, psp, 0x16, parent);
	// Handles: inherited from the parent, or the standard five.
	for (let h = 0u16; h < 20; h += 1) x86::write8(c, psp, 0x18 + h, 0xFF);
	if (parent == 0) {
		const std: [5]u8 = [0, 0, 0, 1, 2];
		for (let h = 0u16; h < 5; h += 1) x86::write8(c, psp, 0x18 + h, std[h]);
	} else {
		const (seg, off, n) = jft(m);
		for (let h = 0u16; h < n && h < 20; h += 1) {
			const i = x86::read8(c, seg, off + h);
			x86::write8(c, psp, 0x18 + h, i);
			if (i != 0xFF && i: size < len(m.sft)) match (m.sft[i]) {
			case null => void;
			case let f: *openfile => f.refs += 1;
			};
		};
	};
	x86::write16(c, psp, 0x2C, env);
	x86::write16(c, psp, 0x32, 20);
	x86::write16(c, psp, 0x34, 0x18);
	x86::write16(c, psp, 0x36, psp);
	x86::write8(c, psp, 0x50, 0xCD); // INT 21h; RETF
	x86::write8(c, psp, 0x51, 0x21);
	x86::write8(c, psp, 0x52, 0xCB);
	const (w1, w2) = tail_words(tail);
	parse_fcb(m, psp, 0x5C, w1);
	parse_fcb(m, psp, 0x6C, w2);
	const tl = if (len(tail) > 126) 126u16 else len(tail): u16;
	x86::write8(c, psp, 0x80, tl: u8);
	write_bytes(m, psp, 0x81, tail[..tl]);
	x86::write8(c, psp, 0x81 + tl, 0x0D);

	// The program itself.
	c.r = [0...];
	if (exe) {
		const start = psp + 0x10;
		for (let i = 0z; i < image; i += 1) {
			c.mem[(x86::linear(start, 0) + i: u32) & 0xFFFFF] = file[hdr + i];
		};
		const nrel = rd16(file, 6): size, tab = rd16(file, 0x18): size;
		for (let i = 0z; i < nrel; i += 1) {
			const off = rd16(file, tab + i * 4);
			const seg = rd16(file, tab + i * 4 + 2);
			const v = x86::read16(c, start + seg, off);
			x86::write16(c, start + seg, off, v + start);
		};
		c.s[x86::CS] = start + rd16(file, 0x16);
		c.ip = rd16(file, 0x14);
		c.s[x86::SS] = start + rd16(file, 0x0E);
		c.r[x86::SP] = rd16(file, 0x10);
		c.s[x86::DS] = psp;
		c.s[x86::ES] = psp;
	} else {
		write_bytes(m, psp, 0x100, file);
		c.s = [psp...];
		c.ip = 0x100;
		c.r[x86::SP] = if (blk >= 0x1000) 0xFFFE else blk * 16 - 2;
		x86::write16(c, psp, c.r[x86::SP], 0); // RET goes to INT 20h
	};
	c.r[x86::CX] = 0x00FF;
	c.r[x86::DX] = psp;
	c.r[x86::SI] = c.ip;
	c.r[x86::DI] = c.r[x86::SP];
	c.r[x86::BP] = 0x091C;
	x86::set_flags(c, 0x0202); // interrupts on (bits 12-15 read as 1 on an 8088)
	m.psp = psp;
	m.dta_seg = psp;
	m.dta_off = 0x80;
};

// Starts the first program. path is a DOS path on C: (e.g. "GAME.EXE"),
// tail the rest of its command line.
export fn start(m: *machine, prog: str, tail: str) (void | doserr) = {
	const raw = strings::toutf8(prog);
	const comps = dos_split(m, raw)?;
	defer free(comps);
	const (host, exists) = host_path(m, comps)?;
	defer free(host);
	if (!exists) return 2: doserr;
	let full: []u8 = alloc(strings::toutf8("C:\\")...)!;
	defer free(full);
	const joined = dos_join(comps);
	defer free(joined);
	append(full, joined...)!;
	// The program's folder becomes the current directory.
	free(m.cwd);
	m.cwd = dos_join(comps[..len(comps) - 1]);
	// A DOS command tail starts with the space after the name.
	let t: []u8 = [];
	defer free(t);
	if (len(tail) > 0 && !strings::hasprefix(tail, " ")) append(t, ' ')!;
	append(t, strings::toutf8(tail)...)!;
	load(m, host, full, t, 0, 0)?;
	m.root_psp = m.psp;
	x86::write16(m.cpu, m.psp, 0x16, m.psp); // its own parent, like COMMAND.COM
};

// INT 21h AH=4Bh: AL=0 load and run, AL=3 load an overlay.
fn exec(m: *machine) (void | doserr) = {
	const c = m.cpu;
	const al = x86::get8(c, 0);
	const pb_seg = c.s[x86::ES], pb = c.r[x86::BX];
	const (host, exists) = resolve(m, c.s[x86::DS], c.r[x86::DX])?;
	defer free(host);
	if (!exists) return 2: doserr;

	if (al == 3) {
		// Overlay: load at a segment, relocated by a factor; no PSP.
		const file = read_host_file(host)?;
		defer free(file);
		const at = x86::read16(c, pb_seg, pb);
		const factor = x86::read16(c, pb_seg, pb + 2);
		if (len(file) >= 0x1C && file[0] == 'M' && file[1] == 'Z') {
			const hdr = rd16(file, 8): size * 16;
			const pages = rd16(file, 4): size, last = rd16(file, 2): size;
			let image = pages * 512 - (if (last != 0) 512 - last else 0z) - hdr;
			if (hdr + image > len(file)) image = len(file) - hdr;
			for (let i = 0z; i < image; i += 1) {
				c.mem[(x86::linear(at, 0) + i: u32) & 0xFFFFF] = file[hdr + i];
			};
			const nrel = rd16(file, 6): size, tab = rd16(file, 0x18): size;
			for (let i = 0z; i < nrel; i += 1) {
				const off = rd16(file, tab + i * 4);
				const seg = rd16(file, tab + i * 4 + 2);
				const v = x86::read16(c, at + seg, off);
				x86::write16(c, at + seg, off, v + factor);
			};
		} else {
			for (let i = 0z; i < len(file); i += 1) {
				c.mem[(x86::linear(at, 0) + i: u32) & 0xFFFFF] = file[i];
			};
		};
		return;
	};
	if (al != 0 && al != 1) return 1: doserr;

	// The command tail from the parameter block.
	const tseg = x86::read16(c, pb_seg, pb + 4), toff = x86::read16(c, pb_seg, pb + 2);
	const tlen = x86::read8(c, tseg, toff);
	let tail: []u8 = [];
	defer free(tail);
	for (let i = 0u16; i < tlen; i += 1) append(tail, x86::read8(c, tseg, toff + 1 + i))!;
	let env = x86::read16(c, pb_seg, pb);
	if (env == 0) env = x86::read16(c, m.psp, 0x2C);

	const raw = read_asciiz(m, c.s[x86::DS], c.r[x86::DX]);
	defer free(raw);
	const comps = dos_split(m, raw)?;
	defer free(comps);
	let full: []u8 = alloc(strings::toutf8("C:\\")...)!;
	defer free(full);
	const joined = dos_join(comps);
	defer free(joined);
	append(full, joined...)!;

	// Remember where the parent's INT 21h frame is: terminate returns
	// through it.
	const parent = m.psp;
	x86::write16(c, parent, 0x2E, c.r[x86::SP]);
	x86::write16(c, parent, 0x30, c.s[x86::SS]);
	// The child returns to just after the parent's INT 21h (its INT 22h
	// address), unless someone like a debugger changes that.
	const ret_ip = x86::read16(c, c.s[x86::SS], c.r[x86::SP]);
	const ret_cs = x86::read16(c, c.s[x86::SS], c.r[x86::SP] + 2);
	if (al == 0) {
		load(m, host, full, tail, parent, env)?;
		x86::write16(c, m.psp, 0x0A, ret_ip);
		x86::write16(c, m.psp, 0x0C, ret_cs);
		return;
	};

	// AL=1 (debuggers): load, but hand back the start registers in the
	// parameter block instead of running it.
	const save_r = c.r, save_s = c.s, save_ip = c.ip, save_f = c.flags;
	const save_dta = (m.dta_seg, m.dta_off);
	load(m, host, full, tail, parent, env)?;
	const child_ss = c.s[x86::SS], child_sp = c.r[x86::SP] - 2;
	x86::write16(c, child_ss, child_sp, c.r[x86::AX]); // AX on the stack
	const child_cs = c.s[x86::CS], child_ip = c.ip;
	x86::write16(c, m.psp, 0x0A, ret_ip);
	x86::write16(c, m.psp, 0x0C, ret_cs);
	c.r = save_r;
	c.s = save_s;
	c.ip = save_ip;
	c.flags = save_f;
	x86::write16(c, pb_seg, pb + 0x0E, child_sp);
	x86::write16(c, pb_seg, pb + 0x10, child_ss);
	x86::write16(c, pb_seg, pb + 0x12, child_ip);
	x86::write16(c, pb_seg, pb + 0x14, child_cs);
	m.dta_seg = save_dta.0;
	m.dta_off = save_dta.1;
};

// Ends the current program. keep: stay resident with keep_paras
// paragraphs (INT 21h AH=31h).
fn terminate(m: *machine, code: u8, keep: bool, keep_paras: u16) void = {
	const c = m.cpu;
	const psp = m.psp;
	const parent = x86::read16(c, psp, 0x16);
	m.last_code = (if (keep) 0x0300u16 else 0u16) | code;
	m.line_on = false;
	if (keep) {
		mem_resize(m, psp, keep_paras): void;
	} else {
		close_program_files(m, psp);
		mem_free_owner(m, psp);
	};
	if (psp == m.root_psp || parent == psp || parent == 0) {
		m.exited = true;
		m.exit_code = code;
		c.halted = true;
		return;
	};
	// The program's INT 22h-24h go back to what they were when it
	// started (they were saved in its PSP).
	for (let i = 0u16; i < 6; i += 1) {
		x86::write16(c, 0, 0x22 * 4 + i * 2, x86::read16(c, psp, 0x0A + i * 2));
	};
	// Back to the parent, through the INT 21h frame it called EXEC with,
	// to the terminate address (INT 22h).
	m.psp = parent;
	m.dta_seg = parent;
	m.dta_off = 0x80;
	c.s[x86::SS] = x86::read16(c, parent, 0x30);
	c.r[x86::SP] = x86::read16(c, parent, 0x2E);
	// Like MS-DOS, the frame gets fresh flags (F202h: interrupts on).
	x86::write16(c, c.s[x86::SS], c.r[x86::SP], x86::read16(c, psp, 0x0A));
	x86::write16(c, c.s[x86::SS], c.r[x86::SP] + 2, x86::read16(c, psp, 0x0C));
	// On a 386, the top bits would be IOPL 3 and "nested task".
	x86::write16(c, c.s[x86::SS], c.r[x86::SP] + 4,
		if (c.model == x86::model::I386) 0x0202 else 0xF202);
	c.s[x86::CS] = ROMSEG;
	c.ip = m.iret21;
};
