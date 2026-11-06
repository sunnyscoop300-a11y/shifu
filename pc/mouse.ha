// Shifu — a mouse driver (INT 33h), like MOUSE.COM: position, buttons,
// ranges, motion counters (mickeys), the text and graphics cursors, and
// the user handler programs install with AX=000Ch. The frontend tells it
// where the host's pointer is; the driver then behaves like a PS/2 mouse.
//
// Coordinates are "virtual" like in Microsoft's driver: always 640 wide
// (in 320-pixel modes every pixel is two units), and as high as the
// screen in graphics modes, or 8 units per text row.
use x86;

// The interrupt routine that calls a program's handler (F000:1000), and
// where it finds the handler's address (F000:1080).
def MOUSE_ISR: u16 = 0x1000;
def MOUSE_HANDLER: u16 = 0x1080;

// The handler's event bits (AX=000Ch, CX).
def EV_MOVE: u16 = 0x01;
def EV_WHEEL: u16 = 0x80;

export type mevent = struct {
	cond: u16,
	buttons: u8,
	wheel: i8,
	x: i16,
	y: i16,
};

export type mousestate = struct {
	used: bool,      // the program reset the driver (it uses the mouse)
	enabled: bool,   // AX=001Fh turns the driver off, 0020h on again
	x: f64,          // virtual position
	y: f64,
	buttons: u8,     // bit 0 left, 1 right, 2 middle
	level: i16,      // the cursor shows when this is 0
	minx: i32,
	maxx: i32,
	miny: i32,
	maxy: i32,
	mick_x: f64,     // motion since AX=000Bh last read it
	mick_y: f64,
	ratio_x: u16,    // mickeys per 8 pixels
	ratio_y: u16,
	presses: [3]u16,
	press_pos: [3](i16, i16),
	releases: [3]u16,
	release_pos: [3](i16, i16),
	wheel: i16,      // steps since AX=0003h last read it (+ = down)
	scr_mask: u16,   // text cursor
	cur_mask: u16,
	gmask: [32]u16,  // graphics cursor: 16 screen-mask words, 16 cursor
	hot_x: i16,
	hot_y: i16,
	h_mask: u16,     // user handler
	h_seg: u16,
	h_off: u16,
	queue: []mevent,
	busy: bool,      // the handler is running
	sens: [3]u16,
	speed: u16,
	page: u16,
	saved: mousestate_copy,
	has_saved: bool,
};

export type mousestate_copy = struct {
	x: f64, y: f64, level: i16,
	minx: i32, maxx: i32, miny: i32, maxy: i32,
	h_mask: u16, h_seg: u16, h_off: u16,
	scr_mask: u16, cur_mask: u16, gmask: [32]u16, hot_x: i16, hot_y: i16,
};

// Microsoft's arrow.
const ARROW: [32]u16 = [
	0x3FFF, 0x1FFF, 0x0FFF, 0x07FF, 0x03FF, 0x01FF, 0x00FF, 0x007F,
	0x003F, 0x001F, 0x01FF, 0x00FF, 0x30FF, 0xF87F, 0xF87F, 0xFCFF,
	0x0000, 0x4000, 0x6000, 0x7000, 0x7800, 0x7C00, 0x7E00, 0x7F00,
	0x7F80, 0x7C00, 0x6C00, 0x4600, 0x0600, 0x0300, 0x0300, 0x0000,
];

fn mouse_init(m: *machine) void = {
	const c = m.cpu;
	// The routine the "mouse interrupt" runs: save everything, let the
	// driver set up AX-DI, call the handler if there is one, restore.
	let a = x86::linear(ROMSEG, MOUSE_ISR);
	const code: [_]u8 = [
		0x06, 0x1E, 0x55, 0x57, 0x56, 0x52, 0x51, 0x53, 0x50, // push es..ax
		0xFE, 0x38, 0x0B, 0x01,             // callback 10Bh
		0x85, 0xC0,                         // test ax, ax
		0x74, 0x05,                         // jz +5
		0x2E, 0xFF, 0x1E,                   // call far [cs:...]
		(MOUSE_HANDLER & 0xFF): u8, (MOUSE_HANDLER >> 8): u8,
		0xFE, 0x38, 0x0C, 0x01,             // callback 10Ch
		0x58, 0x5B, 0x59, 0x5A, 0x5E, 0x5F, 0x5D, 0x1F, 0x07, // pop
		0xCF,                               // iret
	];
	c.mem[a..a + len(code)] = code;
	set_vector(m, MOUSE_VEC, ROMSEG, MOUSE_ISR);
	m.mouse.enabled = true;
	mouse_reset(m);
};

fn mouse_free(m: *machine) void = free(m.mouse.queue);

// The virtual screen's size for the current mode.
fn mouse_virtual(m: *machine) (i32, i32) = {
	const info = m.vga.info;
	if (info.kind == vkind::TEXT) {
		const (_, rows) = text_size(m);
		return (640, rows: i32 * 8);
	};
	return (640, info.h: i32);
};

fn mouse_reset(m: *machine) void = {
	const s = &m.mouse;
	const (w, h) = mouse_virtual(m);
	s.minx = 0;
	s.maxx = w - 1;
	s.miny = 0;
	s.maxy = h - 1;
	s.x = (w / 2): f64;
	s.y = (h / 2): f64;
	s.level = -1;
	s.mick_x = 0.0;
	s.mick_y = 0.0;
	s.ratio_x = 8;
	s.ratio_y = 16;
	s.presses = [0...];
	s.releases = [0...];
	s.wheel = 0;
	s.scr_mask = 0x77FF;
	s.cur_mask = 0x7700;
	s.gmask = ARROW;
	s.hot_x = 0;
	s.hot_y = 0;
	s.h_mask = 0;
	s.queue = s.queue[..0];
	s.sens = [50, 50, 50];
	s.speed = 64;
	s.page = 0;
};

// The video mode changed: the virtual screen goes with it.
fn mouse_new_mode(m: *machine) void = {
	const s = &m.mouse;
	const (w, h) = mouse_virtual(m);
	s.minx = 0;
	s.maxx = w - 1;
	s.miny = 0;
	s.maxy = h - 1;
	mouse_clamp(m);
};

fn mouse_clamp(m: *machine) void = {
	const s = &m.mouse;
	if (s.x < s.minx: f64) s.x = s.minx: f64;
	if (s.x > s.maxx: f64) s.x = s.maxx: f64;
	if (s.y < s.miny: f64) s.y = s.miny: f64;
	if (s.y > s.maxy: f64) s.y = s.maxy: f64;
};

fn mouse_xy(m: *machine) (i16, i16) = {
	return ((m.mouse.x: i32): i16, (m.mouse.y: i32): i16);
};

// ---- From the frontend ----

// Whether the program uses the mouse (it has reset the driver): the
// frontend can hide the host's pointer then.
export fn mouse_used(m: *machine) bool = m.mouse.used && m.mouse.enabled;

// The host's pointer is at fx, fy across the picture (0 to 1).
export fn mouse_move(m: *machine, fx: f64, fy: f64) void = {
	const s = &m.mouse;
	const (w, h) = mouse_virtual(m);
	const nx = fx * w: f64, ny = fy * h: f64;
	// Motion as mickeys, before the range clips the position.
	let dx = nx - s.x, dy = ny - s.y;
	if (dx == 0.0 && dy == 0.0) return;
	s.mick_x += dx * s.ratio_x: f64 / 8.0;
	s.mick_y += dy * s.ratio_y: f64 / 8.0;
	const old = mouse_xy(m);
	s.x = nx;
	s.y = ny;
	mouse_clamp(m);
	if (mouse_xy(m).0 != old.0 || mouse_xy(m).1 != old.1) {
		mouse_event(m, EV_MOVE, 0);
	};
};

// The buttons held now (bit 0 left, 1 right, 2 middle).
export fn mouse_buttons(m: *machine, b: u8) void = {
	const s = &m.mouse;
	const old = s.buttons;
	if (b == old) return;
	s.buttons = b;
	const (x, y) = mouse_xy(m);
	let cond = 0u16;
	for (let i = 0u8; i < 3; i += 1) {
		const bit = 1u8 << i;
		if (b & bit != 0 && old & bit == 0) {
			s.presses[i] += 1;
			s.press_pos[i] = (x, y);
			cond |= 2u16 << (i * 2);
		} else if (b & bit == 0 && old & bit != 0) {
			s.releases[i] += 1;
			s.release_pos[i] = (x, y);
			cond |= 4u16 << (i * 2);
		};
	};
	mouse_event(m, cond, 0);
};

// The wheel turned (+ = up, like ViperGui).
export fn mouse_wheel(m: *machine, steps: int) void = {
	if (steps == 0) return;
	m.mouse.wheel -= steps: i16;
	mouse_event(m, EV_WHEEL, -steps: i8);
};

// Queues a mouse interrupt. Like a PS/2 mouse, every change interrupts
// (so a program waiting in HLT wakes up); the driver then calls the
// program's handler if it asked for this kind of event.
fn mouse_event(m: *machine, cond: u16, wheel: i8) void = {
	const s = &m.mouse;
	if (!s.enabled || !s.used) return;
	const (x, y) = mouse_xy(m);
	const ev = mevent { cond = cond, buttons = s.buttons, wheel = wheel, x = x, y = y };
	const n = len(s.queue);
	if (cond == EV_MOVE && n > 0 && s.queue[n - 1].cond == EV_MOVE) {
		s.queue[n - 1] = ev; // moves in a row: only the last counts
		return;
	};
	if (n < 64) append(s.queue, ev)!;
};

// Called from run_until: starts the mouse "interrupt" when one is due.
// The mouse interrupt: IRQ 12's vector (74h), as for a PS/2 mouse, so it
// goes the right way in protected mode too (a DPMI host reflects it to
// the driver in real mode, or gives it to the client's own handler).
def MOUSE_VEC: u8 = 0x74;

fn mouse_irq(m: *machine) bool = {
	const s = &m.mouse;
	if (len(s.queue) == 0 || s.busy || !x86::irq_ready(m.cpu)) return false;
	const c = m.cpu;
	s.busy = true;
	if (!dpmi_rm_irq(m, MOUSE_VEC)) x86::interrupt(c, MOUSE_VEC);
	c.halted = false;
	return true;
};

// Callback 10Bh: registers for the handler (AX = 0: don't call it).
fn mouse_isr_begin(m: *machine) void = {
	const s = &m.mouse;
	const c = m.cpu;
	c.r[x86::AX] = 0;
	if (len(s.queue) == 0) return;
	const ev = s.queue[0];
	delete(s.queue[0]);
	const cond = ev.cond & s.h_mask;
	if (cond == 0 || s.h_seg == 0 && s.h_off == 0) return;
	x86::write16(c, ROMSEG, MOUSE_HANDLER, s.h_off);
	x86::write16(c, ROMSEG, MOUSE_HANDLER + 2, s.h_seg);
	c.r[x86::AX] = cond;
	c.r[x86::BX] = ev.buttons: u16 | (ev.wheel: u8: u16) << 8;
	c.r[x86::CX] = ev.x: u16;
	c.r[x86::DX] = ev.y: u16;
	c.r[x86::SI] = (s.mick_x: i32): u16;
	c.r[x86::DI] = (s.mick_y: i32): u16;
};

// Callback 10Ch: the handler is done.
fn mouse_isr_end(m: *machine) void = {
	m.mouse.busy = false;
};

// ---- INT 33h ----

fn int33(m: *machine) bool = {
	const c = m.cpu;
	const s = &m.mouse;
	const ax = c.r[x86::AX];
	const bx = c.r[x86::BX], cx = c.r[x86::CX], dx = c.r[x86::DX];
	if (!s.enabled && ax != 0x20) {
		if (ax == 0) c.r[x86::AX] = 0;
		return true;
	};
	switch (ax) {
	case 0x00 => // reset and status
		mouse_reset(m);
		s.used = true;
		c.r[x86::AX] = 0xFFFF;
		c.r[x86::BX] = 2;
	case 0x21 => // software reset
		mouse_reset(m);
		s.used = true;
		c.r[x86::AX] = 0xFFFF;
		c.r[x86::BX] = 2;
	case 0x01 => // show the cursor
		if (s.level < 0) s.level += 1;
	case 0x02, 0x10 => // hide it (10h: hide in a region; here: hide)
		s.level -= 1;
	case 0x03 => // position and buttons
		const (x, y) = mouse_xy(m);
		c.r[x86::BX] = s.buttons: u16 | (s.wheel: i8: u8: u16) << 8;
		c.r[x86::CX] = x: u16;
		c.r[x86::DX] = y: u16;
		s.wheel = 0;
	case 0x04 => // set the position
		s.x = (cx: i16): f64;
		s.y = (dx: i16): f64;
		mouse_clamp(m);
	case 0x05, 0x06 => // presses / releases of a button since last asked
		const b = if (bx < 3) bx: size else 0z;
		c.r[x86::AX] = s.buttons;
		if (ax == 5) {
			c.r[x86::BX] = s.presses[b];
			c.r[x86::CX] = s.press_pos[b].0: u16;
			c.r[x86::DX] = s.press_pos[b].1: u16;
			s.presses[b] = 0;
		} else {
			c.r[x86::BX] = s.releases[b];
			c.r[x86::CX] = s.release_pos[b].0: u16;
			c.r[x86::DX] = s.release_pos[b].1: u16;
			s.releases[b] = 0;
		};
	case 0x07, 0x08 => // horizontal / vertical range
		let lo = (cx: i16): i32, hi = (dx: i16): i32;
		if (lo > hi) { const t = lo; lo = hi; hi = t; };
		if (ax == 7) { s.minx = lo; s.maxx = hi; }
		else { s.miny = lo; s.maxy = hi; };
		mouse_clamp(m);
	case 0x09 => // graphics cursor: hot spot BX, CX; masks at ES:DX
		s.hot_x = bx: i16;
		s.hot_y = cx: i16;
		for (let i = 0u16; i < 32; i += 1) {
			s.gmask[i] = x86::read16(c, c.s[x86::ES], dx + i * 2);
		};
	case 0x0A => // text cursor: BX 0 = software (CX screen, DX cursor mask)
		if (bx == 0) {
			s.scr_mask = cx;
			s.cur_mask = dx;
		};
	case 0x0B => // motion counters, then zero them
		const mx = s.mick_x: i32, my = s.mick_y: i32;
		c.r[x86::CX] = mx: u16;
		c.r[x86::DX] = my: u16;
		s.mick_x -= mx: f64;
		s.mick_y -= my: f64;
	case 0x0C => // user handler: mask CX, ES:DX
		s.h_mask = cx;
		s.h_seg = c.s[x86::ES];
		s.h_off = dx;
		s.queue = s.queue[..0];
	case 0x14 => // swap handlers
		const (om, os, oo) = (s.h_mask, s.h_seg, s.h_off);
		s.h_mask = cx;
		s.h_seg = c.s[x86::ES];
		s.h_off = dx;
		c.r[x86::CX] = om;
		c.s[x86::ES] = os;
		c.r[x86::DX] = oo;
	case 0x0D, 0x0E => void; // light pen
	case 0x0F => // mickeys per 8 pixels
		if (cx != 0) s.ratio_x = cx;
		if (dx != 0) s.ratio_y = dx;
	case 0x11 => // CuteMouse WheelAPI: yes, there is a wheel
		c.r[x86::AX] = 0x574D;
		c.r[x86::CX] = 1;
	case 0x13 => s.speed = dx;
	case 0x15 => c.r[x86::BX] = 64; // state size
	case 0x16 => // save state (kept in the driver)
		s.has_saved = true;
		s.saved = mousestate_copy {
			x = s.x, y = s.y, level = s.level,
			minx = s.minx, maxx = s.maxx, miny = s.miny, maxy = s.maxy,
			h_mask = s.h_mask, h_seg = s.h_seg, h_off = s.h_off,
			scr_mask = s.scr_mask, cur_mask = s.cur_mask,
			gmask = s.gmask, hot_x = s.hot_x, hot_y = s.hot_y,
		};
	case 0x17 => // restore state
		if (s.has_saved) {
			const v = s.saved;
			s.x = v.x; s.y = v.y; s.level = v.level;
			s.minx = v.minx; s.maxx = v.maxx; s.miny = v.miny; s.maxy = v.maxy;
			s.h_mask = v.h_mask; s.h_seg = v.h_seg; s.h_off = v.h_off;
			s.scr_mask = v.scr_mask; s.cur_mask = v.cur_mask;
			s.gmask = v.gmask; s.hot_x = v.hot_x; s.hot_y = v.hot_y;
		};
	case 0x1A => s.sens = [bx, cx, dx];
	case 0x1B =>
		c.r[x86::BX] = s.sens[0];
		c.r[x86::CX] = s.sens[1];
		c.r[x86::DX] = s.sens[2];
	case 0x1D => s.page = bx;
	case 0x1E => c.r[x86::BX] = s.page;
	case 0x1F => // disable the driver; ES:BX = the INT 33h it replaced
		s.enabled = false;
		c.s[x86::ES] = ROMSEG;
		c.r[x86::BX] = stub_off(0x33);
	case 0x20 => // enable it again
		s.enabled = true;
		c.r[x86::AX] = 0xFFFF;
	case 0x22 => void; // language
	case 0x23 => c.r[x86::BX] = 0; // English
	case 0x24 => // version 8.05, PS/2 mouse
		c.r[x86::BX] = 0x0805;
		c.r[x86::CX] = 0x0400;
	case 0x26 => // largest coordinates
		const (w, h) = mouse_virtual(m);
		c.r[x86::BX] = 0;
		c.r[x86::CX] = (w - 1): u16;
		c.r[x86::DX] = (h - 1): u16;
	case 0x2A => // cursor level and hot spot
		c.r[x86::AX] = s.level: u16;
		c.r[x86::BX] = s.hot_x: u16;
		c.r[x86::CX] = s.hot_y: u16;
		c.r[x86::DX] = 4; // PS/2
	case =>
		missing(m, 0x33, ax: u8);
	};
	return true;
};

// ---- Drawing the cursor (on the picture, not in video memory) ----

fn mouse_visible(m: *machine) bool =
	m.mouse.enabled && m.mouse.used && m.mouse.level >= 0;

// The text cell the cursor is on, if it shows in a text mode.
fn mouse_text_cell(m: *machine, cols: u8) (u8, u8) = {
	const (x, y) = mouse_xy(m);
	const cw: i16 = 640 / cols: i16;
	return ((x / cw): u8, (y / 8): u8);
};

// Draws the graphics cursor onto a rendered picture.
fn mouse_overlay(m: *machine, pix: []u32, pic: picture) void = {
	if (!mouse_visible(m) || m.vga.info.kind == vkind::TEXT) return;
	const s = &m.mouse;
	const (x, y) = mouse_xy(m);
	const sx = x: int * pic.w: int / 640 - s.hot_x: int;
	const sy = y: int - s.hot_y: int;
	for (let r = 0; r < 16; r += 1) {
		const py = sy + r;
		if (py < 0 || py >= pic.h: int) continue;
		const and = s.gmask[r], xor = s.gmask[16 + r];
		for (let k = 0; k < 16; k += 1) {
			const px = sx + k;
			if (px < 0 || px >= pic.w: int) continue;
			const bit = 0x8000u16 >> k: u8;
			const p = &pix[py: size * MAX_W + px: size];
			if (and & bit == 0) {
				*p = if (xor & bit != 0) 0xFFFFFFFF else 0xFF000000;
			} else if (xor & bit != 0) {
				*p ^= 0x00FFFFFF;
			};
		};
	};
};
