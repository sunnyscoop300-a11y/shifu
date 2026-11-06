// Shifu — DOS (INT 21h), written in Hare. Calls that need a key wait by
// returning false: the ROM stub then runs again until a key is there.
use fs;
use io;
use os;
use rt;
use strings;
use time::date;
use x86;

// ---- Console ----

// Writes a character to standard output: the screen (CON, tabs
// expanded) unless it was redirected.
fn con_out(m: *machine, ch: u8) void = {
	switch (kind_of(m, 1)) {
	case devkind::CON => void;
	case devkind::HOSTOUT =>
		host_write(m, ch);
		return;
	case devkind::FILE =>
		match (handle_file(m, 1)) {
		case let f: *openfile =>
			match (io::write(f.f, [ch])) {
			case size => void;
			case io::error => void;
			};
		case doserr => void;
		};
		return;
	case => return;
	};
	if (ch == '\t') {
		for (true) {
			tty_out(m, ' ');
			const (col, _) = cursor(m);
			if (col % 8 == 0) break;
		};
		return;
	};
	tty_out(m, ch);
};

fn con_str(m: *machine, s: str) void = {
	for (let b .. strings::toutf8(s)) con_out(m, b);
};

// Gets a key for the character input functions: extended keys come as
// 0 followed by the scan code. Returns void when no key is waiting.
fn con_getch(m: *machine) (u8 | void) = {
	if (m.ext_key != 0) {
		const k = m.ext_key;
		m.ext_key = 0;
		return k;
	};
	match (std_in(m)) {
	case let b: u8 => return b;
	case void => void;
	};
	if (!key_ready(m)) return;
	const k = pop_key(m);
	const ch = k: u8;
	if (ch == 0 || ch == 0xE0) {
		m.ext_key = (k >> 8): u8;
		if (m.ext_key == 0) m.ext_key = 0xFF;
		return 0;
	};
	return ch;
};

// Reads a byte when standard input is redirected (0x1A = Ctrl-Z at the
// end). void means "use the keyboard".
fn std_in(m: *machine) (u8 | void) = {
	const f = match (handle_file(m, 0)) {
	case let f: *openfile => yield f;
	case doserr => return 0x1A;
	};
	let b: [1]u8 = [0];
	switch (f.kind) {
	case devkind::CON => return;
	case devkind::HOSTIN =>
		return if (host_read(m, f.f, b) == 1) b[0] else 0x1A;
	case devkind::FILE =>
		match (io::read(f.f, b)) {
		case let n: size => return if (n == 1) b[0] else 0x1A;
		case => return 0x1A;
		};
	case => return 0x1A;
	};
};

// Whether standard input has something to read.
fn std_ready(m: *machine) bool = {
	if (m.ext_key != 0) return true;
	if (kind_of(m, 0) != devkind::CON) return true;
	return key_ready(m);
};

// Ctrl-C: like DOS, print ^C and call INT 23h. If the program has its own
// handler, it runs, and when it returns the interrupted DOS call starts
// over; otherwise the program ends.
fn ctrl_c(m: *machine) void = {
	const c = m.cpu;
	con_str(m, "^C\r\n");
	m.line_on = false;
	const vseg = x86::read16(c, 0, 0x23 * 4 + 2);
	const ss = c.s[x86::SS], sp = c.r[x86::SP];
	const cs = x86::read16(c, ss, sp + 2), ip = x86::read16(c, ss, sp);
	if (vseg == ROMSEG || x86::read16(c, cs, ip - 2) != 0x21CD) {
		terminate(m, 0, false, 0);
		return;
	};
	// Back up to the caller's INT 21h, and call the handler so that it
	// returns through our IRET.
	x86::write16(c, ss, sp, ip - 2);
	x86::interrupt(c, 0x23);
};

// Feeds waiting keys into the line being typed (INT 21h AH=0Ah, and
// reading from CON). Returns true when Enter ends the line.
fn line_input(m: *machine, max: size) (bool | void) = {
	if (!m.line_on) {
		m.line_on = true;
		m.line = m.line[..0];
	};
	const redirected = kind_of(m, 0) != devkind::CON;
	for (std_ready(m)) {
		const ch = if (redirected) {
			const b = match (std_in(m)) {
			case let b: u8 => yield b;
			case void => yield 0x1Au8;
			};
			if (b == 0x1A) {
				// End of input: finish the line.
				m.line_on = false;
				return true;
			};
			yield b;
		} else pop_key(m): u8;
		switch (ch) {
		case 0x0D =>
			m.line_on = false;
			con_out(m, 0x0D);
			return true;
		case 0x03 =>
			m.line_on = false;
			return;
		case 0x08 =>
			if (len(m.line) > 0) {
				delete(m.line[len(m.line) - 1]);
				tty_out(m, 8);
				tty_out(m, ' ');
				tty_out(m, 8);
			};
		case 0, 0xE0, 0x0A, 0x1B => void;
		case =>
			if (len(m.line) + 1 < max) {
				append(m.line, ch)!;
				con_out(m, ch);
			};
		};
	};
	return false;
};

// ---- INT 21h ----

fn int21(m: *machine) bool = {
	const c = m.cpu;
	const ah = x86::get8(c, 4), al = x86::get8(c, 0);
	const ds = c.s[x86::DS], dx = c.r[x86::DX];
	switch (ah) {
	case 0x00 => terminate(m, 0, false, 0);
	case 0x01, 0x07, 0x08 => // read a character (01 echoes)
		const ch = match (con_getch(m)) {
		case let ch: u8 => yield ch;
		case void => return false;
		};
		if (ch == 3 && ah != 0x07) {
			ctrl_c(m);
			return true;
		};
		if (ah == 0x01) con_out(m, ch);
		x86::set8(c, 0, ch);
	case 0x02 => // write DL
		con_out(m, x86::get8(c, 2));
		x86::set8(c, 0, x86::get8(c, 2));
	case 0x06 => // direct console I/O
		if (x86::get8(c, 2) == 0xFF) {
			match (con_getch(m)) {
			case let ch: u8 =>
				x86::set8(c, 0, ch);
				ret_flag(m, x86::ZF, false);
			case void =>
				x86::set8(c, 0, 0);
				ret_flag(m, x86::ZF, true);
				m.idle = true;
			};
		} else {
			con_out(m, x86::get8(c, 2));
			x86::set8(c, 0, x86::get8(c, 2));
		};
	case 0x09 => // write a $-terminated string
		for (let i = 0u16; i < 0xFFFF; i += 1) {
			const ch = x86::read8(c, ds, dx + i);
			if (ch == '$') break;
			con_out(m, ch);
		};
		x86::set8(c, 0, '$');
	case 0x0A => // buffered line input at DS:DX
		const max = x86::read8(c, ds, dx);
		if (max == 0) return true;
		match (line_input(m, max)) {
		case let fin: bool =>
			if (!fin) return false;
		case void =>
			ctrl_c(m);
			return true;
		};
		const n = len(m.line): u8;
		x86::write8(c, ds, dx + 1, n);
		write_bytes(m, ds, dx + 2, m.line);
		x86::write8(c, ds, dx + 2 + n, 0x0D);
	case 0x0B => // is a key waiting?
		const ready = std_ready(m);
		x86::set8(c, 0, if (ready) 0xFF else 0);
		if (!ready) m.idle = true;
	case 0x0C => // flush the keyboard, then call AL
		for (key_ready(m)) pop_key(m);
		m.ext_key = 0;
		x86::set8(c, 4, al);
		if (al == 0x01 || al == 0x06 || al == 0x07 || al == 0x08 || al == 0x0A) {
			// Run the requested function from now on.
			return int21(m);
		};
	case 0x0D => void; // disk reset
	case 0x0E => // select drive: only C:
		x86::set8(c, 0, 3);
	case 0x0F, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
		0x21, 0x22, 0x23, 0x24, 0x27, 0x28 => // FCB file functions
		x86::set8(c, 0, fcb_call(m, ah));
	case 0x19 => x86::set8(c, 0, 2); // current drive: C:
	case 0x1A => // set DTA
		m.dta_seg = ds;
		m.dta_off = dx;
	case 0x25 => // set interrupt vector
		x86::write16(c, 0, al: u16 * 4, dx);
		x86::write16(c, 0, al: u16 * 4 + 2, ds);
	case 0x26 => // create a new PSP at segment DX (a copy of ours)
		for (let i = 0u16; i < 0x100; i += 1) {
			x86::write8(c, dx, i, x86::read8(c, m.psp, i));
		};
		for (let i = 0u16; i < 3; i += 1) {
			x86::write16(c, dx, 0x0A + i * 4, x86::read16(c, 0, (0x22 + i) * 4));
			x86::write16(c, dx, 0x0C + i * 4, x86::read16(c, 0, (0x22 + i) * 4 + 2));
		};
	case 0x29 => // parse a file name into an FCB
		parse_name(m);
	case 0x2A => // date
		const d = date::localnow();
		c.r[x86::CX] = date::year(&d): u16;
		x86::set8(c, 6, date::month(&d): u8);
		x86::set8(c, 2, date::day(&d): u8);
		x86::set8(c, 0, ((date::weekday(&d) + 1) % 7): u8);
	case 0x2B, 0x2D => x86::set8(c, 0, 0); // set date/time: pretend
	case 0x2C => // time
		const d = date::localnow();
		x86::set8(c, 5, date::hour(&d): u8);
		x86::set8(c, 1, date::minute(&d): u8);
		x86::set8(c, 6, date::second(&d): u8);
		x86::set8(c, 2, (date::nanosecond(&d) / 10000000): u8);
	case 0x2E => void; // set verify flag
	case 0x2F => // get DTA
		c.s[x86::ES] = m.dta_seg;
		c.r[x86::BX] = m.dta_off;
	case 0x30 => // DOS version (5.0 unless told otherwise)
		c.r[x86::AX] = m.version.1: u16 << 8 | m.version.0;
		c.r[x86::BX] = 0;
		c.r[x86::CX] = 0;
	case 0x31 => // stay resident
		terminate(m, al, true, dx);
	case 0x33 => // Ctrl-Break flag and friends
		switch (al) {
		case 0x00 => x86::set8(c, 2, 0);
		case 0x05 => x86::set8(c, 2, 3); // booted from C:
		case 0x06 =>
			c.r[x86::BX] = m.version.1: u16 << 8 | m.version.0;
			c.r[x86::DX] = 0;
		case => void;
		};
	case 0x34 => // address of the InDOS flag
		c.s[x86::ES] = DOSSEG;
		c.r[x86::BX] = 0;
	case 0x35 => // get interrupt vector
		c.r[x86::BX] = x86::read16(c, 0, al: u16 * 4);
		c.s[x86::ES] = x86::read16(c, 0, al: u16 * 4 + 2);
	case 0x36 => // free disk space
		c.r[x86::AX] = 32;     // sectors per cluster
		c.r[x86::BX] = 0x7FFF; // free clusters
		c.r[x86::CX] = 512;    // bytes per sector
		c.r[x86::DX] = 0xFFFF; // clusters
	case 0x37 => // switch character
		if (al == 0) x86::set8(c, 2, '/');
		x86::set8(c, 0, 0);
	case 0x38 => // country info: Denmark
		country(m);
		c.r[x86::BX] = 45;
		return ok(m);
	case 0x39, 0x3A, 0x3B => return dir_call(m, ah);
	case 0x3C => // create
		return result(m, create_file(m, ds, dx, false));
	case 0x3D => // open
		return result(m, open_file(m, ds, dx, al));
	case 0x3E => // close
		match (close_handle(m, c.r[x86::BX])) {
		case void => return ok(m);
		case let e: doserr => return fail(m, e);
		};
	case 0x3F => return read_handle(m);
	case 0x40 => return write_handle(m);
	case 0x41 => // delete
		match (resolve(m, ds, dx)) {
		case let e: doserr => return fail(m, e);
		case let r: (str, bool) =>
			defer free(r.0);
			if (!r.1) return fail(m, 2);
			match (os::remove(r.0)) {
			case void => return ok(m);
			case let e: fs::error => return fail(m, fserr(e));
			};
		};
	case 0x42 => return seek_handle(m);
	case 0x43 => // file attributes
		match (resolve(m, ds, dx)) {
		case let e: doserr => return fail(m, e);
		case let r: (str, bool) =>
			defer free(r.0);
			if (!r.1) return fail(m, 2);
			if (al == 0) {
				const st = match (os::stat(r.0)) {
				case let s: fs::filestat => yield s;
				case let e: fs::error => return fail(m, fserr(e));
				};
				c.r[x86::CX] = if (fs::isdir(st.mode)) 0x10 else 0x20;
			};
			return ok(m);
		};
	case 0x44 => return ioctl(m);
	case 0x45 => // duplicate handle
		return result(m, dup_handle(m, c.r[x86::BX], void));
	case 0x46 => // force duplicate
		match (dup_handle(m, c.r[x86::BX], c.r[x86::CX])) {
		case u16 => return ok(m);
		case let e: doserr => return fail(m, e);
		};
	case 0x47 => // current directory into DS:SI
		const drive = x86::get8(c, 2);
		if (drive != 0 && drive != 3) return fail(m, 15);
		write_bytes(m, ds, c.r[x86::SI], m.cwd);
		x86::write8(c, ds, c.r[x86::SI] + len(m.cwd): u16, 0);
		c.r[x86::AX] = 0x0100;
		return ok(m);
	case 0x48 => // allocate memory
		match (mem_alloc(m, c.r[x86::BX], m.psp)) {
		case let s: u16 =>
			c.r[x86::AX] = s;
			return ok(m);
		case let e: (u16, doserr) =>
			c.r[x86::BX] = e.0;
			return fail(m, e.1);
		};
	case 0x49 => // free memory
		match (mem_free(m, c.s[x86::ES])) {
		case void => return ok(m);
		case let e: doserr => return fail(m, e);
		};
	case 0x4A => // resize memory
		match (mem_resize(m, c.s[x86::ES], c.r[x86::BX])) {
		case void => return ok(m);
		case let e: (u16, doserr) =>
			c.r[x86::BX] = e.0;
			return fail(m, e.1);
		};
	case 0x4B => // EXEC
		match (exec(m)) {
		case void =>
			if (al == 3 || al == 1) return ok(m);
			return true; // the child is running now
		case let e: doserr => return fail(m, e);
		};
	case 0x4C => terminate(m, al, false, 0);
	case 0x4D => // return code of the last program
		c.r[x86::AX] = m.last_code;
		m.last_code = 0;
		return ok(m);
	case 0x4E => // find first
		match (find_first(m, ds, dx, x86::get8(c, 1))) {
		case void => return ok(m);
		case let e: doserr => return fail(m, e);
		};
	case 0x4F => // find next
		match (find_next(m)) {
		case void => return ok(m);
		case let e: doserr => return fail(m, e);
		};
	case 0x50 => m.psp = c.r[x86::BX]; // set PSP
	case 0x51, 0x62 => c.r[x86::BX] = m.psp; // get PSP
	case 0x52 => // list of lists (first MCB at ES:BX-2)
		c.s[x86::ES] = DOSSEG;
		c.r[x86::BX] = 0x10;
	case 0x54 => x86::set8(c, 0, 0); // verify flag
	case 0x56 => return rename(m);
	case 0x57 => // file date and time
		const f = match (handle_file(m, c.r[x86::BX])) {
		case let f: *openfile => yield f;
		case let e: doserr => return fail(m, e);
		};
		if (al == 0) {
			if (f.kind == devkind::FILE) {
				match (os::fstat(f.f)) {
				case let st: fs::filestat =>
					const (t, d) = dos_time(st);
					c.r[x86::CX] = t;
					c.r[x86::DX] = d;
				case => void;
				};
			};
		};
		return ok(m);
	case 0x58 => // allocation strategy
		if (al == 0 || al == 2) c.r[x86::AX] = 0;
		return ok(m);
	case 0x59 => // extended error
		c.r[x86::AX] = m.last_error;
		c.r[x86::BX] = 0x0104;
		x86::set8(c, 5, 1);
	case 0x5A => return temp_file(m);
	case 0x5B => // create a new file
		return result(m, create_file(m, ds, dx, true));
	case 0x5C => return ok(m); // record locks
	case 0x60 => return truename(m);
	case 0x63 => // DBCS table: empty
		c.s[x86::DS] = DOSSEG;
		c.r[x86::SI] = 0x20;
		x86::set8(c, 0, 0);
		return ok(m);
	case 0x66 => // code page 865 (Nordic)
		c.r[x86::BX] = 865;
		c.r[x86::DX] = 865;
		return ok(m);
	case 0x67, 0x68, 0x6A => return ok(m); // handle count, commit
	case 0x6C => return ext_open(m);
	case =>
		missing(m, 0x21, ah);
		return fail(m, 1);
	};
	return true;
};

// Ends a call that returns a handle in AX.
fn result(m: *machine, r: (u16 | doserr)) bool = {
	match (r) {
	case let h: u16 =>
		m.cpu.r[x86::AX] = h;
		return ok(m);
	case let e: doserr =>
		return fail(m, e);
	};
};

fn read_handle(m: *machine) bool = {
	const c = m.cpu;
	const f = match (handle_file(m, c.r[x86::BX])) {
	case let f: *openfile => yield f;
	case let e: doserr => return fail(m, e);
	};
	const n = c.r[x86::CX];
	const ds = c.s[x86::DS], dx = c.r[x86::DX];
	switch (f.kind) {
	case devkind::CON =>
		// Cooked input: a whole line, then hand it out.
		if (len(m.con_in) == 0) {
			match (line_input(m, 128)) {
			case let fin: bool =>
				if (!fin) return false;
			case void =>
				ctrl_c(m);
				return true;
			};
			tty_out(m, 0x0A);
			append(m.con_in, m.line...)!;
			append(m.con_in, [0x0D, 0x0A]...)!;
		};
		const k = if (n: size < len(m.con_in)) n: size else len(m.con_in);
		write_bytes(m, ds, dx, m.con_in[..k]);
		delete(m.con_in[..k]);
		c.r[x86::AX] = k: u16;
	case devkind::HOSTIN =>
		let buf: []u8 = alloc([0u8...], n)!;
		defer free(buf);
		const got = host_read(m, f.f, buf);
		write_bytes(m, ds, dx, buf[..got]);
		c.r[x86::AX] = got: u16;
	case devkind::FILE =>
		let buf: []u8 = alloc([0u8...], n)!;
		defer free(buf);
		let got = 0z;
		for (got < len(buf)) {
			match (io::read(f.f, buf[got..])) {
			case let k: size => got += k;
			case io::EOF => break;
			case io::error => return fail(m, 5);
			};
		};
		write_bytes(m, ds, dx, buf[..got]);
		c.r[x86::AX] = got: u16;
	case =>
		c.r[x86::AX] = 0;
	};
	return ok(m);
};

fn write_handle(m: *machine) bool = {
	const c = m.cpu;
	const f = match (handle_file(m, c.r[x86::BX])) {
	case let f: *openfile => yield f;
	case let e: doserr => return fail(m, e);
	};
	const n = c.r[x86::CX];
	const ds = c.s[x86::DS], dx = c.r[x86::DX];
	switch (f.kind) {
	case devkind::CON =>
		for (let i = 0u16; i < n; i += 1) {
			const ch = x86::read8(c, ds, dx + i);
			if (ch == '\t') {
				for (true) {
					tty_out(m, ' ');
					if (cursor(m).0 % 8 == 0) break;
				};
			} else {
				tty_out(m, ch);
			};
		};
	case devkind::HOSTOUT =>
		for (let i = 0u16; i < n; i += 1) host_write(m, x86::read8(c, ds, dx + i));
	case devkind::FILE =>
		if (n == 0) {
			// Writing 0 bytes cuts the file at the current position.
			match (io::seek(f.f, 0, io::whence::CUR)) {
			case let pos: io::off => truncate(f.f, pos);
			case => void;
			};
			c.r[x86::AX] = 0;
			return ok(m);
		};
		let buf: []u8 = alloc([0u8...], n)!;
		defer free(buf);
		for (let i = 0u16; i < n; i += 1) buf[i] = x86::read8(c, ds, dx + i);
		match (io::writeall(f.f, buf)) {
		case size => void;
		case => return fail(m, 5);
		};
	case => void;
	};
	c.r[x86::AX] = n;
	return ok(m);
};

fn seek_handle(m: *machine) bool = {
	const c = m.cpu;
	const f = match (handle_file(m, c.r[x86::BX])) {
	case let f: *openfile => yield f;
	case let e: doserr => return fail(m, e);
	};
	if (f.kind != devkind::FILE) {
		c.r[x86::AX] = 0;
		c.r[x86::DX] = 0;
		return ok(m);
	};
	const off = (c.r[x86::CX]: u32 << 16 | c.r[x86::DX]: u32): i32: io::off;
	const w = switch (x86::get8(c, 0)) {
	case 0 => yield io::whence::SET;
	case 1 => yield io::whence::CUR;
	case 2 => yield io::whence::END;
	case => return fail(m, 1);
	};
	match (io::seek(f.f, off, w)) {
	case let pos: io::off =>
		c.r[x86::AX] = pos: u16;
		c.r[x86::DX] = (pos >> 16): u16;
		return ok(m);
	case => return fail(m, 0x19);
	};
};

fn ioctl(m: *machine) bool = {
	const c = m.cpu;
	const al = x86::get8(c, 0);
	switch (al) {
	case 0x00, 0x01, 0x06, 0x07 =>
		const f = match (handle_file(m, c.r[x86::BX])) {
		case let f: *openfile => yield f;
		case let e: doserr => return fail(m, e);
		};
		const dev = f.kind != devkind::FILE;
		switch (al) {
		case 0x00 =>
			c.r[x86::DX] = switch (f.kind) {
			case devkind::CON => yield 0x80D3;
			case devkind::NUL => yield 0x8084;
			case devkind::FILE, devkind::HOSTIN, devkind::HOSTOUT =>
				yield 0x0002; // a file on drive C:
			case => yield 0x80C0;
			};
		case 0x06 => // input ready?
			const ready = switch (f.kind) {
			case devkind::CON => yield key_ready(m);
			case devkind::HOSTIN =>
				fill_in(m, f.f);
				yield len(m.in_buf) > 0;
			case => yield true;
			};
			x86::set8(c, 0, if (ready) 0xFF else 0);
			if (!ready) m.idle = true;
		case 0x07 => x86::set8(c, 0, 0xFF);
		case => void;
		};
		if (!dev && al == 0x01) return ok(m);
		return ok(m);
	case 0x08 => // removable? no
		c.r[x86::AX] = 1;
		return ok(m);
	case 0x09 => // remote? no
		c.r[x86::DX] = 0;
		return ok(m);
	case 0x0E => // drive map
		x86::set8(c, 0, 0);
		return ok(m);
	case =>
		return fail(m, 1);
	};
};

fn dir_call(m: *machine, ah: u8) bool = {
	const c = m.cpu;
	const raw = read_asciiz(m, c.s[x86::DS], c.r[x86::DX]);
	defer free(raw);
	const comps = match (dos_split(m, raw)) {
	case let p: [][]u8 => yield p;
	case let e: doserr => return fail(m, e);
	};
	defer free(comps);
	const (host, exists) = match (host_path(m, comps)) {
	case let r: (str, bool) => yield r;
	case let e: doserr => return fail(m, e);
	};
	defer free(host);
	switch (ah) {
	case 0x39 => // mkdir
		if (exists) return fail(m, 5);
		match (os::mkdir(host, 0o755)) {
		case void => void;
		case let e: fs::error => return fail(m, fserr(e));
		};
	case 0x3A => // rmdir
		if (!exists) return fail(m, 3);
		match (os::rmdir(host)) {
		case void => void;
		case let e: fs::error => return fail(m, fserr(e));
		};
	case 0x3B => // chdir
		if (!exists) return fail(m, 3);
		match (os::stat(host)) {
		case let st: fs::filestat =>
			if (!fs::isdir(st.mode)) return fail(m, 3);
		case => return fail(m, 3);
		};
		free(m.cwd);
		m.cwd = dos_join(comps);
	case => abort();
	};
	return ok(m);
};

fn rename(m: *machine) bool = {
	const c = m.cpu;
	const (from, ok1) = match (resolve(m, c.s[x86::DS], c.r[x86::DX])) {
	case let r: (str, bool) => yield r;
	case let e: doserr => return fail(m, e);
	};
	defer free(from);
	const (to, ok2) = match (resolve(m, c.s[x86::ES], c.r[x86::DI])) {
	case let r: (str, bool) => yield r;
	case let e: doserr => return fail(m, e);
	};
	defer free(to);
	if (!ok1) return fail(m, 2);
	if (ok2) return fail(m, 5);
	match (os::rename(from, to)) {
	case void => return ok(m);
	case let e: fs::error => return fail(m, fserr(e));
	};
};

// AH=5Ah: a new file with a unique name in the folder at DS:DX.
fn temp_file(m: *machine) bool = {
	const c = m.cpu;
	const ds = c.s[x86::DS], dx = c.r[x86::DX];
	let end = 0u16;
	for (x86::read8(c, ds, dx + end) != 0) end += 1;
	for (let n = 0u32; n < 1000; n += 1) {
		const name = strings::toutf8(fmt_temp(n));
		write_bytes(m, ds, dx + end, name);
		x86::write8(c, ds, dx + end + len(name): u16, 0);
		match (create_file(m, ds, dx, true)) {
		case let h: u16 =>
			c.r[x86::AX] = h;
			return ok(m);
		case let e: doserr =>
			if (e != 0x50) return fail(m, e);
		};
	};
	return fail(m, 5);
};

let tmpbuf: [12]u8 = [0...];

fn fmt_temp(n: u32) str = {
	const s = "SHIFU000.TMP";
	tmpbuf[..] = strings::toutf8(s);
	tmpbuf[5] = '0' + (n / 100 % 10): u8;
	tmpbuf[6] = '0' + (n / 10 % 10): u8;
	tmpbuf[7] = '0' + (n % 10): u8;
	return strings::fromutf8_unsafe(tmpbuf);
};

// AH=60h: the full name of a path, C:\...
fn truename(m: *machine) bool = {
	const c = m.cpu;
	const raw = read_asciiz(m, c.s[x86::DS], c.r[x86::SI]);
	defer free(raw);
	const comps = match (dos_split(m, raw)) {
	case let p: [][]u8 => yield p;
	case let e: doserr => return fail(m, e);
	};
	defer free(comps);
	const j = dos_join(comps);
	defer free(j);
	write_bytes(m, c.s[x86::ES], c.r[x86::DI], strings::toutf8("C:\\"));
	write_bytes(m, c.s[x86::ES], c.r[x86::DI] + 3, j);
	x86::write8(c, c.s[x86::ES], c.r[x86::DI] + 3 + len(j): u16, 0);
	return ok(m);
};

// AH=6Ch: extended open/create.
fn ext_open(m: *machine) bool = {
	const c = m.cpu;
	const ds = c.s[x86::DS], si = c.r[x86::SI];
	const action = c.r[x86::DX];
	const mode = x86::get8(c, 3);
	const exists = match (resolve(m, ds, si)) {
	case let r: (str, bool) =>
		free(r.0);
		yield r.1;
	case let e: doserr => return fail(m, e);
	};
	if (exists) {
		switch (action & 0x0F) {
		case 1 =>
			c.r[x86::CX] = 1;
			return result(m, open_file(m, ds, si, mode));
		case 2 =>
			c.r[x86::CX] = 3;
			return result(m, create_file(m, ds, si, false));
		case => return fail(m, 0x50);
		};
	};
	if (action & 0xF0 == 0x10) {
		c.r[x86::CX] = 2;
		return result(m, create_file(m, ds, si, false));
	};
	return fail(m, 2);
};

// AH=29h: parses a file name at DS:SI into the FCB at ES:DI.
fn parse_name(m: *machine) void = {
	const c = m.cpu;
	let si = c.r[x86::SI];
	for (true) {
		const ch = x86::read8(c, c.s[x86::DS], si);
		if (ch != ' ' && ch != '\t') break;
		si += 1;
	};
	let word: []u8 = [];
	defer free(word);
	for (true) {
		const ch = x86::read8(c, c.s[x86::DS], si);
		if (ch <= ' ' || ch == '/' || ch == ',' || ch == ';' ||
			ch == '=' || ch == '+') break;
		append(word, ch)!;
		si += 1;
	};
	parse_fcb(m, c.s[x86::ES], c.r[x86::DI], word);
	c.r[x86::SI] = si;
	let wild = false;
	for (let ch .. word) if (ch == '*' || ch == '?') wild = true;
	x86::set8(c, 0, if (wild) 1 else 0);
};

// AH=38h: country information for Denmark (dd-mm-yyyy, 1.234,56 kr).
fn country(m: *machine) void = {
	const c = m.cpu;
	const s = c.s[x86::DS], o = c.r[x86::DX];
	for (let i = 0u16; i < 34; i += 1) x86::write8(c, s, o + i, 0);
	x86::write16(c, s, o, 1);                      // date: d-m-y
	write_bytes(m, s, o + 2, strings::toutf8("kr")); // currency
	x86::write8(c, s, o + 7, '.');                 // thousands
	x86::write8(c, s, o + 9, ',');                 // decimals
	x86::write8(c, s, o + 11, '-');                // date separator
	x86::write8(c, s, o + 13, ':');                // time separator
	x86::write8(c, s, o + 15, 2);                  // "kr 1,00"
	x86::write8(c, s, o + 16, 2);                  // 2 decimals
	x86::write8(c, s, o + 17, 1);                  // 24-hour clock
	x86::write8(c, s, o + 22, ';');                // list separator
};

fn truncate(f: io::file, pos: io::off) void = {
	match (rt::ftruncate(f: int, pos: rt::off_t)) {
	case void => void;
	case rt::errno => void;
	};
};
