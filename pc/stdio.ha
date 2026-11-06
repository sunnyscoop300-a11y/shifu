// Shifu — redirection: DOS standard input/output to the host's stdin and
// stdout, like "SORT < FIL.TXT" or "FIND ... | MORE" on a real PC.
// Text is translated between the PC character set and UTF-8, and between
// DOS (CR LF) and Unix (LF) line ends.
use io;
use strings;
use x86;

// Makes the host's stdin the first program's standard input.
export fn redirect_stdin(m: *machine, f: io::file) void = redirect(m, 0, devkind::HOSTIN, f);

// Makes the host's stdout the first program's standard output.
export fn redirect_stdout(m: *machine, f: io::file) void = {
	m.host_out = f;
	redirect(m, 1, devkind::HOSTOUT, f);
};

// Whether the program wrote anything to the host's stdout.
export fn stdout_used(m: *machine) bool = m.out_used;

fn redirect(m: *machine, h: u16, kind: devkind, f: io::file) void = {
	close_handle(m, h): void;
	const (seg, off, _) = jft(m);
	let slot = len(m.sft);
	for (let i = 0z; i < len(m.sft); i += 1) {
		if (m.sft[i] is null) {
			slot = i;
			break;
		};
	};
	const e = alloc(openfile { kind = kind, f = f, refs = 1 })!;
	if (slot == len(m.sft)) append(m.sft, e)! else m.sft[slot] = e;
	x86::write8(m.cpu, seg, off + h, slot: u8);
};

// What a handle of the current program is connected to.
fn kind_of(m: *machine, h: u16) devkind = {
	match (handle_file(m, h)) {
	case let f: *openfile => return f.kind;
	case doserr => return devkind::NUL;
	};
};

// ---- Host stdin ----

// Fills m.in_buf from the host, as PC characters with CR LF line ends.
fn fill_in(m: *machine, f: io::file) void = {
	if (m.in_eof || len(m.in_buf) > 0) return;
	let raw: [512]u8 = [0...];
	const n = match (io::read(f, raw)) {
	case let n: size => yield n;
	case => yield 0z;
	};
	if (n == 0) {
		m.in_eof = true;
		return;
	};
	append(m.in_part, raw[..n]...)!;
	// Decode whole UTF-8 characters; keep a cut-off one for next time.
	let i = 0z;
	for (i < len(m.in_part)) {
		const b = m.in_part[i];
		const need: size = if (b >= 0xF0) 4 else if (b >= 0xE0) 3
			else if (b >= 0xC0) 2 else 1;
		if (i + need > len(m.in_part)) break;
		if (need == 1) {
			if (b == '\n' && (len(m.in_buf) == 0 ||
				m.in_buf[len(m.in_buf) - 1] != '\r')) {
				append(m.in_buf, '\r')!;
			};
			append(m.in_buf, b)!;
		} else {
			const ch = match (strings::fromutf8(m.in_part[i..i + need])) {
			case let s: str =>
				let it = strings::iter(s);
				yield match (strings::next(&it)) {
				case let r: rune =>
					yield match (from_unicode(r)) {
					case let c: u8 => yield c;
					case void => yield 0x3Fu8;
					};
				case done => yield 0x3Fu8;
				};
			case => yield 0x3Fu8;
			};
			append(m.in_buf, ch)!;
		};
		i += need;
	};
	delete(m.in_part[..i]);
};

// Reads up to len(buf) bytes of redirected input; 0 at the end.
fn host_read(m: *machine, f: io::file, buf: []u8) size = {
	fill_in(m, f);
	const n = if (len(buf) < len(m.in_buf)) len(buf) else len(m.in_buf);
	buf[..n] = m.in_buf[..n];
	delete(m.in_buf[..n]);
	return n;
};

// ---- Host stdout ----

fn host_write(m: *machine, ch: u8) void = {
	m.out_used = true;
	switch (ch) {
	case '\r', 0x1A => return;
	case '\n', '\t', 7, 8 =>
		append(m.out_buf, ch)!;
	case =>
		if (ch < 0x80) {
			append(m.out_buf, ch)!;
		} else {
			const s = strings::fromrunes([CHARSET[ch]])!;
			append(m.out_buf, strings::toutf8(s)...)!;
			free(s);
		};
	};
	if (len(m.out_buf) >= 4096) flush(m);
};

// Writes what the program printed to the host's stdout.
export fn flush(m: *machine) void = {
	if (len(m.out_buf) == 0) return;
	match (io::writeall(m.host_out, m.out_buf)) {
	case size => void;
	case io::error => void;
	};
	m.out_buf = m.out_buf[..0];
};
