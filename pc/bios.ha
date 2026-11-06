// Shifu — the BIOS: text screen (INT 10h), keyboard (INT 16h), clock
// (INT 1Ah) and the small stuff. State lives in the BIOS data area at
// 0040:0000, like on a real PC, because programs read it directly.
use time;
use time::date;
use x86;


fn bda8(m: *machine, off: u16) u8 = x86::read8(m.cpu, 0x40, off);
fn bda16(m: *machine, off: u16) u16 = x86::read16(m.cpu, 0x40, off);
fn set_bda8(m: *machine, off: u16, v: u8) void = x86::write8(m.cpu, 0x40, off, v);
fn set_bda16(m: *machine, off: u16, v: u16) void = x86::write16(m.cpu, 0x40, off, v);

fn bios_init(m: *machine) void = {
	set_bda16(m, 0x10, 0x0021); // equipment: floppy, 80x25 colour
	set_bda16(m, 0x13, 640);    // KiB of conventional memory
	// Keyboard buffer: 16 words at 0040:001E.
	set_bda16(m, 0x1A, 0x1E);
	set_bda16(m, 0x1C, 0x1E);
	set_bda16(m, 0x80, 0x1E);
	set_bda16(m, 0x82, 0x3E);
	// Video: mode 3, 80x25 colour text.
	set_bda16(m, 0x63, 0x3D4);
	set_mode(m, 3, true);
	// The tick count starts at the time of day, like after DOS's TIME.
	const now = time::now(time::clock::REALTIME);
	const secs = (now.sec + utc_offset()) % 86400;
	const ticks = (secs: u64 * PIT_HZ + now.nsec: u64 / 1000000 * PIT_HZ / 1000) / 65536;
	set_bda16(m, 0x6C, ticks: u16);
	set_bda16(m, 0x6E, (ticks >> 16): u16);
};

// Seconds the local time is ahead of UTC.
fn utc_offset() i64 = {
	const d = date::localnow();
	return date::zone(&d).zoff / time::SECOND;
};

// IRQ 0, 18.2 times a second: the BIOS clock (INT 08h). The ROM then
// calls INT 1Ch, which programs hook for their own timing.
fn timer_tick(m: *machine) void = {
	let t = bda16(m, 0x6C): u32 | bda16(m, 0x6E): u32 << 16;
	t += 1;
	if (t >= 0x1800B0) { // midnight
		t = 0;
		set_bda8(m, 0x70, 1);
	};
	set_bda16(m, 0x6C, t: u16);
	set_bda16(m, 0x6E, (t >> 16): u16);
};

// IRQ 1: the BIOS keyboard handler (INT 09h). It reads the scan code from
// port 60h, keeps track of Shift, Ctrl, Alt and Caps Lock, and puts keys
// in the keyboard buffer. Programs that hook INT 9 (games) often read port
// 60h themselves and then chain here.
fn keyboard_irq(m: *machine) void = {
	const scan = kbd_read(m);
	const key = m.kbd_key;
	pic_eoi(m);
	if (scan == 0xE0 || scan == 0xE1) {
		set_bda8(m, 0x96, bda8(m, 0x96) | 0x02);
		return;
	};
	set_bda8(m, 0x96, bda8(m, 0x96) & ~0x02);
	const make = scan & 0x80 == 0;
	let flags = bda8(m, 0x17);
	const f: u8 = switch (scan & 0x7F) {
	case 0x2A => yield 0x02; // left shift
	case 0x36 => yield 0x01; // right shift
	case 0x1D => yield 0x04; // ctrl
	case 0x38 => yield 0x08; // alt
	case => yield 0;
	};
	if (f != 0) {
		if (make) flags |= f else flags &= ~f;
	} else if (make) {
		switch (scan) {
		case 0x3A => flags ^= 0x40; // Caps Lock
		case 0x45 => flags ^= 0x20; // Num Lock
		case 0x46 => flags ^= 0x10; // Scroll Lock
		case => void;
		};
	};
	set_bda8(m, 0x17, flags);
	if (make && key != 0) bios_key(m, key);
};

// ---- Keyboard ----

// Queues a key (scan code << 8 | ASCII) for the program. Keys go into
// the BIOS keyboard buffer (15 keys) as the program makes room, so a
// pasted line isn't cut off.
export fn push_key(m: *machine, key: u16) void = {
	append(m.key_queue, key)!;
	key_pump(m);
};

fn key_pump(m: *machine) void = {
	for (len(m.key_queue) > 0 && bios_key(m, m.key_queue[0])) {
		delete(m.key_queue[0]);
	};
};

// Puts a key in the BIOS keyboard buffer; false when it is full.
fn bios_key(m: *machine, key: u16) bool = {
	const tail = bda16(m, 0x1C);
	let next = tail + 2;
	if (next >= bda16(m, 0x82)) next = bda16(m, 0x80);
	if (next == bda16(m, 0x1A)) return false;
	set_bda16(m, tail, key);
	set_bda16(m, 0x1C, next);
	return true;
};

fn key_ready(m: *machine) bool = {
	key_pump(m);
	return bda16(m, 0x1A) != bda16(m, 0x1C);
};

fn peek_key(m: *machine) u16 = bda16(m, bda16(m, 0x1A));

fn pop_key(m: *machine) u16 = {
	const head = bda16(m, 0x1A);
	const k = bda16(m, head);
	let next = head + 2;
	if (next >= bda16(m, 0x82)) next = bda16(m, 0x80);
	set_bda16(m, 0x1A, next);
	return k;
};

fn int16(m: *machine) bool = {
	const c = m.cpu;
	switch (x86::get8(c, 4)) {
	case 0x00, 0x10 => // wait for a key
		if (!key_ready(m)) return false;
		c.r[x86::AX] = pop_key(m);
	case 0x01, 0x11 => // is a key waiting?
		if (key_ready(m)) {
			c.r[x86::AX] = peek_key(m);
			ret_flag(m, x86::ZF, false);
		} else {
			ret_flag(m, x86::ZF, true);
			m.idle = true;
		};
	case 0x02, 0x12 => // shift state
		c.r[x86::AX] = bda8(m, 0x17);
	case 0x05 => // store a key
		x86::set8(c, 0, if (bios_key(m, c.r[x86::CX])) 0 else 1);
	case => missing(m, 0x16, x86::get8(c, 4));
	};
	return true;
};

// ---- Clock and the rest ----

fn int1a(m: *machine) bool = {
	const c = m.cpu;
	switch (x86::get8(c, 4)) {
	case 0x00 => // ticks since midnight
		c.r[x86::DX] = bda16(m, 0x6C);
		c.r[x86::CX] = bda16(m, 0x6E);
		x86::set8(c, 0, bda8(m, 0x70));
		set_bda8(m, 0x70, 0);
	case 0x01 => // set the tick count
		set_bda16(m, 0x6C, c.r[x86::DX]);
		set_bda16(m, 0x6E, c.r[x86::CX]);
	case 0x02 => // RTC time in BCD
		const d = date::localnow();
		x86::set8(c, 5, bcd(date::hour(&d)));
		x86::set8(c, 1, bcd(date::minute(&d)));
		x86::set8(c, 6, bcd(date::second(&d)));
		x86::set8(c, 2, 0);
		ret_flag(m, x86::CF, false);
	case 0x04 => // RTC date in BCD
		const d = date::localnow();
		x86::set8(c, 5, bcd(date::year(&d) / 100));
		x86::set8(c, 1, bcd(date::year(&d) % 100));
		x86::set8(c, 6, bcd(date::month(&d)));
		x86::set8(c, 2, bcd(date::day(&d)));
		ret_flag(m, x86::CF, false);
	case => void;
	};
	return true;
};

fn bcd(v: int) u8 = ((v / 10) << 4 | v % 10): u8;

// INT 13h (disks: there are none) and INT 15h (system services).
fn int13_15(m: *machine, n: u8) bool = {
	const c = m.cpu;
	const ah = x86::get8(c, 4);
	if (n == 0x13) {
		x86::set8(c, 4, if (ah == 0) 0 else 1);
		ret_flag(m, x86::CF, ah != 0);
		return true;
	};
	switch (ah) {
	case 0x88 => // extended memory: none
		c.r[x86::AX] = 0;
		ret_flag(m, x86::CF, false);
	case 0x86 => ret_flag(m, x86::CF, false); // wait
	case 0x24 => // the A20 gate (AT BIOSes)
		const al = x86::get8(c, 0);
		switch (al) {
		case 0, 1 => gate_a20(m, al == 1);
		case 2 => x86::set8(c, 0, if (x86::a20(c)) 1 else 0);
		case 3 => c.r[x86::BX] = 3; // keyboard controller and port 92h
		case => void;
		};
		x86::set8(c, 4, 0);
		ret_flag(m, x86::CF, false);
	case =>
		x86::set8(c, 4, 0x86);
		ret_flag(m, x86::CF, true);
	};
	return true;
};

// INT 2Fh: the multiplex interrupt. Nothing is installed.
fn int2f(m: *machine) void = {
	const c = m.cpu;
	switch (c.r[x86::AX]) {
	case 0x4300 => // is there an XMS driver?
		x86::set8(c, 0, if (xms_present(m)) 0x80 else 0);
	case 0x4310 => // its entry point
		if (xms_present(m)) {
			c.s[x86::ES] = ROMSEG;
			c.r[x86::BX] = XMS_ENTRY;
		};
	case 0x1687 => // is there a DPMI host?
		if (dpmi_present(m)) {
			c.r[x86::AX] = 0;
			c.r[x86::BX] = 1;        // 32-bit programs too
			x86::set8(c, 1, 3);      // a 386
			c.r[x86::DX] = 0x005A;   // DPMI 0.90
			c.r[x86::SI] = 0;        // no memory needed for the host
			c.s[x86::ES] = ROMSEG;
			c.r[x86::DI] = RM_ENTRY;
		};
	case 0x1600, 0x1689 =>
		x86::set8(c, 0, 0);
	case => void;
	};
};
