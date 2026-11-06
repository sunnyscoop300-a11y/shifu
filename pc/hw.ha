// Shifu — the PC's chips: the 8259 interrupt controller (PIC), the 8253
// timer (PIT), the keyboard controller (port 60h/64h), port 61h and the
// video card's CRTC and status registers. Time is emulated: it moves on
// with every instruction (see machine.ha), so timing is the same however
// fast the host is.
use x86;

// PIT input clock: 1.193182 MHz.
export def PIT_HZ: u64 = 1193182;

export type pic = struct {
	irr: u8,   // requested
	isr: u8,   // in service
	imr: u8,   // masked
	base: u8,  // vector of IRQ 0
	init: u8,  // which ICW comes next (0 = none)
	icw4: bool,
	single: bool,
	read_isr: bool,
};

export type pitchan = struct {
	reload: u64,  // 1-65536
	mode: u8,
	access: u8,   // 1 low byte, 2 high byte, 3 low then high
	write_hi: bool,
	read_hi: bool,
	latched: bool,
	latch: u16,
	low: u8,      // low byte written, waiting for the high one
	start: u64,   // PIT tick when counting started
	counting: bool,
};

// The emulated time in PIT ticks.
fn now(m: *machine) u64 = m.vtime >> 16;

fn hw_init(m: *machine) void = {
	m.pic.base = 8;
	m.pic.imr = 0xB8; // like a BIOS: timer, keyboard, IRQ2 and IRQ6 on
	for (let i = 0z; i < 3; i += 1) {
		m.pit[i] = pitchan { reload = 65536, mode = 3, access = 3, ... };
	};
	m.pit[0].counting = true; // the BIOS starts it at 18.2 Hz
	m.next_timer = 65536;
	m.crtc[0x0A] = 0x0D;
	m.crtc[0x0B] = 0x0E;
	m.port61 = 0x30;
	m.cpu.port_in = &port_in;
	m.cpu.port_out = &port_out;
};

// ---- 8259 PIC ----

// An interrupt request line goes active (edge-triggered).
export fn raise_irq(m: *machine, n: u8) void = {
	m.pic.irr |= 1 << n;
};

// The vector of the interrupt the PIC wants the CPU to take now, if any;
// it moves from "requested" to "in service".
fn pic_take(m: *machine) (u8 | void) = {
	const req = m.pic.irr & ~m.pic.imr;
	if (req == 0) return;
	for (let i = 0u8; i < 8; i += 1) {
		const bit = 1u8 << i;
		if (m.pic.isr & bit != 0) return; // same or higher priority busy
		if (req & bit != 0) {
			m.pic.irr &= ~bit;
			m.pic.isr |= bit;
			return m.pic.base + i;
		};
	};
};

// End of interrupt: the highest-priority one in service is done.
fn pic_eoi(m: *machine) void = {
	for (let i = 0u8; i < 8; i += 1) {
		if (m.pic.isr & (1 << i) != 0) {
			m.pic.isr &= ~(1 << i);
			return;
		};
	};
};

fn pic_write(m: *machine, port: u16, v: u8) void = {
	const p = &m.pic;
	if (port & 1 == 0) {
		if (v & 0x10 != 0) { // ICW1: start initialising
			p.init = 2;
			p.icw4 = v & 1 != 0;
			p.single = v & 2 != 0;
			p.imr = 0;
			p.isr = 0;
			p.irr = 0;
		} else if (v & 0x18 == 0) { // OCW2
			switch (v & 0xE0) {
			case 0x20 => pic_eoi(m); // non-specific EOI
			case 0x60 => p.isr &= ~(1 << (v & 7)); // specific EOI
			case => void;
			};
		} else if (v & 0x18 == 0x08) { // OCW3
			if (v & 2 != 0) p.read_isr = v & 1 != 0;
		};
		return;
	};
	switch (p.init) {
	case 2 => // ICW2: vector base
		p.base = v & 0xF8;
		p.init = if (!p.single) 3 else if (p.icw4) 4 else 0;
	case 3 => p.init = if (p.icw4) 4 else 0; // ICW3
	case 4 => p.init = 0; // ICW4
	case => p.imr = v; // OCW1: the mask
	};
};

fn pic_read(m: *machine, port: u16) u8 = {
	if (port & 1 != 0) return m.pic.imr;
	return if (m.pic.read_isr) m.pic.isr else m.pic.irr;
};

// ---- 8253 PIT ----

fn pit_count(ch: *pitchan, t: u64) u16 = {
	if (!ch.counting) return ch.reload: u16;
	const el = t - ch.start;
	switch (ch.mode) {
	case 2 =>
		return (ch.reload - el % ch.reload): u16;
	case 3 =>
		// Counts down by two, twice per period.
		const half = if (ch.reload < 2) 1u64 else ch.reload / 2;
		return ((ch.reload - (el % half) * 2) & 0xFFFE): u16;
	case =>
		return (ch.reload - el): u16;
	};
};

// The output of a channel (channel 2's shows on port 61h bit 5).
fn pit_out(ch: *pitchan, t: u64) bool = {
	if (!ch.counting) return true;
	const el = t - ch.start;
	switch (ch.mode) {
	case 0 => return el >= ch.reload;
	case 3 => return el % ch.reload < ch.reload / 2;
	case => return true;
	};
};

// When channel 0 next fires IRQ 0 (in PIT ticks; never for a stopped
// one-shot).
fn schedule_timer(m: *machine) void = {
	const ch = &m.pit[0];
	const t = now(m);
	if (!ch.counting) {
		m.next_timer = 0xFFFFFFFFFFFF;
		return;
	};
	switch (ch.mode) {
	case 0, 1, 4, 5 =>
		const at = ch.start + ch.reload;
		m.next_timer = if (at > t) at else 0xFFFFFFFFFFFF;
	case =>
		const periods = (t - ch.start) / ch.reload + 1;
		m.next_timer = ch.start + periods * ch.reload;
	};
};

fn timer_event(m: *machine) void = {
	raise_irq(m, 0);
	schedule_timer(m);
};

fn pit_write(m: *machine, port: u16, v: u8) void = {
	const t = now(m);
	if (port == 0x43) {
		const n = (v >> 6): size;
		if (n == 3) return; // 8254 read-back: not on a PC/XT
		const ch = &m.pit[n];
		const access = (v >> 4) & 3;
		if (access == 0) { // latch the count
			ch.latch = pit_count(ch, t);
			ch.latched = true;
			return;
		};
		ch.access = access;
		ch.mode = (v >> 1) & 7;
		if (ch.mode > 5) ch.mode -= 4;
		ch.write_hi = false;
		ch.read_hi = false;
		ch.latched = false;
		return;
	};
	const n = (port - 0x40): size;
	const ch = &m.pit[n];
	let val = 0u16;
	switch (ch.access) {
	case 1 => val = v;
	case 2 => val = v: u16 << 8;
	case =>
		if (!ch.write_hi) {
			ch.low = v;
			ch.write_hi = true;
			return;
		};
		ch.write_hi = false;
		val = v: u16 << 8 | ch.low;
	};
	ch.reload = if (val == 0) 65536 else val;
	ch.start = t;
	ch.counting = true;
	if (n == 0) schedule_timer(m);
	if (n == 2) speaker_changed(m);
};

fn pit_read(m: *machine, port: u16) u8 = {
	const ch = &m.pit[(port - 0x40): size];
	const v = if (ch.latched) ch.latch else pit_count(ch, now(m));
	switch (ch.access) {
	case 1 =>
		ch.latched = false;
		return v: u8;
	case 2 =>
		ch.latched = false;
		return (v >> 8): u8;
	case =>
		if (!ch.read_hi) {
			ch.read_hi = true;
			return v: u8;
		};
		ch.read_hi = false;
		ch.latched = false;
		return (v >> 8): u8;
	};
};

// ---- Keyboard controller ----

// Moves the next scan code from the queue to port 60h and raises IRQ 1,
// once the program has had time to read the previous one.
fn kbd_pump(m: *machine) void = {
	if (m.kbd_full || len(m.kbd_q) == 0 || now(m) < m.kbd_next) return;
	const (scan, key) = m.kbd_q[0];
	delete(m.kbd_q[0]);
	m.kbd_data = scan;
	m.kbd_key = key;
	m.kbd_full = true;
	raise_irq(m, 1);
};

fn kbd_read(m: *machine) u8 = {
	if (m.kbd_full) {
		m.kbd_full = false;
		m.kbd_next = now(m) + PIT_HZ / 1000; // the next one in 1 ms
	};
	return m.kbd_data;
};

// The keyboard answers ACK (FAh) to commands, e.g. setting the LEDs.
fn kbd_ack(m: *machine) void = {
	insert(m.kbd_q[0], (0xFA, 0))!;
};

// ---- Video card registers ----

// VGA text mode: 70 frames a second; vertical retrace is the last bit.
def FRAME_TICKS: u64 = PIT_HZ / 70;
def RETRACE_TICKS: u64 = 1000;

fn video_status(m: *machine) u8 = {
	const t = now(m);
	const pos = t % FRAME_TICKS;
	const vr = pos >= FRAME_TICKS - RETRACE_TICKS;
	// 31.5 kHz lines (38 PIT ticks), the display off for about a third
	// of each: long enough for the four reads in a row that Wolfenstein
	// 3D makes to be sure it is between lines (each takes ~1 µs).
	const hblank = t % 38 < 13;
	m.vga.attr_data = false; // reading 3DAh resets the attribute flip-flop
	return (if (vr) 0x08u8 else 0u8) | (if (vr || hblank) 0x01u8 else 0u8);
};

// The cursor position the video card shows (CRTC registers 0Eh/0Fh).
fn hw_cursor_set(m: *machine, col: u8, row: u8) void = {
	const start = m.crtc[0x0C]: u16 << 8 | m.crtc[0x0D];
	const pos = start + row: u16 * tcols(m) + col;
	m.crtc[0x0E] = (pos >> 8): u8;
	m.crtc[0x0F] = pos: u8;
};

// ---- Port dispatch ----

// An I/O access takes about 1 µs on the ISA bus, however fast the CPU:
// programs time short waits with port reads (the AdLib check reads its
// status port 100 times to wait the 80 µs its timer needs).
def ISA_IO: u64 = PIT_HZ * 65536 / 1000000;

fn port_in(c: *x86::cpu, port: u16) u8 = {
	const m = c.user: *machine;
	m.vtime += ISA_IO;
	switch (port) {
	case 0x20, 0x21 => return pic_read(m, port);
	case 0xA1 => return m.pic2_imr;
	case 0x40, 0x41, 0x42 => return pit_read(m, port);
	case 0x60 => return kbd_read(m);
	case 0x61 =>
		// Bit 4 toggles with memory refresh (~15 µs), bit 5 is timer 2.
		const t = now(m);
		const refresh: u8 = if ((t / 18) % 2 == 0) 0x10 else 0;
		const out2: u8 = if (pit_out(&m.pit[2], t)) 0x20 else 0;
		return (m.port61 & 0x0F) | refresh | out2;
	case 0x64 => return (if (m.kbd_full) 1u8 else 0u8) | 0x14;
	case 0x3D5, 0x3B5 => return m.crtc[m.crtc_index & 0x1F];
	case 0x3D4, 0x3B4 => return m.crtc_index;
	case 0x3DA, 0x3BA => return video_status(m);
	case 0x3C0, 0x3C1, 0x3C4, 0x3C5, 0x3C6, 0x3C7, 0x3C8, 0x3C9, 0x3CC,
		0x3CE, 0x3CF => return vga_port_in(m, port);
	case 0x3D8 => return m.vga.cga_mode;
	case 0x388, 0x228 => return opl_status(m);
	case 0x389, 0x229 => return 0xFF;
	case 0x226, 0x22A, 0x22C, 0x22E => return sb_read(m, port);
	case 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
		0x81, 0x82, 0x83, 0x87 => return dma_read(m, port);
	case 0x201 => return 0xF0; // no joystick
	case 0x92 => return if (x86::a20(m.cpu)) 2 else 0;
	case => return 0xFF;       // nothing there
	};
};

fn port_out(c: *x86::cpu, port: u16, v: u8) void = {
	const m = c.user: *machine;
	m.vtime += ISA_IO;
	switch (port) {
	case 0x20, 0x21 => pic_write(m, port, v);
	case 0xA1 => m.pic2_imr = v;
	case 0x40, 0x41, 0x42, 0x43 => pit_write(m, port, v);
	case 0x60 =>
		if (m.kbc_cmd == 0xD1) {
			// The controller's output port: bit 1 is the A20 gate.
			gate_a20(m, v & 2 != 0);
			m.kbc_cmd = 0;
		} else {
			kbd_ack(m);
		};
	case 0x92 => gate_a20(m, v & 2 != 0); // "fast A20"
	case 0x61 =>
		const t = now(m);
		// Timer 2's gate (bit 0) restarts its count when it goes on.
		if (v & 1 != 0 && m.port61 & 1 == 0) m.pit[2].start = t;
		const spk = (v ^ m.port61) & 3 != 0;
		m.port61 = v;
		if (spk) speaker_changed(m);
	case 0x388, 0x228 => m.opl.addr = v;
	case 0x389, 0x229 => opl_write(m, v);
	case 0x226, 0x22C => sb_write(m, port, v);
	case 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x0A, 0x0B, 0x0C,
		0x0D, 0x0F, 0x81, 0x82, 0x83, 0x87 => dma_write(m, port, v);
	case 0x64 =>
		switch (v) {
		case 0xAA => append(m.kbd_q, (0x55, 0))!; // self test passed
		case 0xD1 => m.kbc_cmd = 0xD1;
		case 0xD0 => // read the output port
			append(m.kbd_q, (if (x86::a20(m.cpu)) 0xDF else 0xDD, 0))!;
		case 0xDD => gate_a20(m, false);
		case 0xDF => gate_a20(m, true);
		case => void;
		};
	case 0x3C0, 0x3C2, 0x3C4, 0x3C5, 0x3C6, 0x3C7, 0x3C8, 0x3C9, 0x3CE,
		0x3CF, 0x3D8, 0x3D9 => vga_port_out(m, port, v);
	case 0x3D4, 0x3B4 => m.crtc_index = v;
	case 0x3D5, 0x3B5 => m.crtc[m.crtc_index & 0x1F] = v;
	case => void;
	};
};
