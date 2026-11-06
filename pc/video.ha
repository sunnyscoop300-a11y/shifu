// Shifu — the video card, an IBM VGA: text modes, CGA graphics, the EGA/VGA
// 16-colour planar modes and mode 13h (320x200, 256 colours), with the
// VGA's registers and the BIOS video services (INT 10h). See render.ha for
// turning the screen into pixels.
use x86;

export def VSEG: u16 = 0xB800;

// What kind of picture a mode makes.
export type vkind = enum {
	TEXT,
	CGA4,   // 320x200, 4 colours, B800h, interlaced
	CGA2,   // 640x200, 2 colours, B800h, interlaced
	PLANAR, // EGA/VGA 16 colours in 4 bit planes at A000h
	VGA256, // mode 13h: 320x200, one byte per pixel at A000h
};

export type modeinfo = struct {
	kind: vkind,
	w: u16,   // pixels (text: of the whole screen)
	h: u16,
	cols: u8, // text columns and rows
	rows: u8,
	ch: u8,   // character height
};

// The modes Shifu has, or void.
export fn mode_info(mode: u8) (modeinfo | void) = {
	switch (mode) {
	case 0, 1 => return modeinfo { kind = vkind::TEXT, w = 640, h = 400, cols = 40, rows = 25, ch = 16 };
	case 2, 3, 7 => return modeinfo { kind = vkind::TEXT, w = 640, h = 400, cols = 80, rows = 25, ch = 16 };
	case 4, 5 => return modeinfo { kind = vkind::CGA4, w = 320, h = 200, cols = 40, rows = 25, ch = 8 };
	case 6 => return modeinfo { kind = vkind::CGA2, w = 640, h = 200, cols = 80, rows = 25, ch = 8 };
	case 0x0D => return modeinfo { kind = vkind::PLANAR, w = 320, h = 200, cols = 40, rows = 25, ch = 8 };
	case 0x0E => return modeinfo { kind = vkind::PLANAR, w = 640, h = 200, cols = 80, rows = 25, ch = 8 };
	case 0x10 => return modeinfo { kind = vkind::PLANAR, w = 640, h = 350, cols = 80, rows = 25, ch = 14 };
	case 0x11, 0x12 => return modeinfo { kind = vkind::PLANAR, w = 640, h = 480, cols = 80, rows = 30, ch = 16 };
	case 0x13 => return modeinfo { kind = vkind::VGA256, w = 320, h = 200, cols = 40, rows = 25, ch = 8 };
	case => return;
	};
};

export type vga = struct {
	info: modeinfo,
	planes: []u8,   // 4 x 64 KiB
	latch: [4]u8,
	seq: [8]u8,
	seq_i: u8,
	gc: [16]u8,
	gc_i: u8,
	attr: [32]u8,
	attr_i: u8,
	attr_data: bool, // the next write to 3C0h is data (else an index)
	dac: [256][3]u8, // 6 bits per colour
	dac_w: u8,
	dac_r: u8,
	dac_c: u8,
	pel_mask: u8,
	cga_mode: u8,    // 3D8h
	cga_color: u8,   // 3D9h
	misc: u8,
	tty_color: u8,   // colour for text in graphics modes
	// Mode 13h with chain-4 off (sequencer register 4, bit 3): the
	// pixels are in the four planes, x & 3 picking the plane ("mode X",
	// which Doom and many others use for page flipping).
	unchained: bool,
};

// Where the ROM fonts live (F000:...): INT 1Fh/43h and AX=1130h point here.
def FONT8_OFF: u16 = 0x9000;
def FONT16_OFF: u16 = 0xA000;

fn video_init(m: *machine) void = {
	m.vga.planes = alloc([0u8...], 4 * 0x10000)!;
	const c = m.cpu;
	const rom = x86::linear(ROMSEG, 0);
	for (let ch = 0z; ch < 256; ch += 1) {
		for (let y = 0z; y < 8; y += 1) {
			c.mem[rom + FONT8_OFF + ch * 8 + y] = FONT8[ch][y];
			// The PC's 8x8 font for the first 128 characters at F000:FA6E.
			if (ch < 128) c.mem[rom + 0xFA6E + ch * 8 + y] = FONT8[ch][y];
		};
		for (let y = 0z; y < 16; y += 1) {
			c.mem[rom + FONT16_OFF + ch * 16 + y] = FONT16[ch][y];
		};
	};
	set_vector(m, 0x1F, ROMSEG, FONT8_OFF + 128 * 8);
	set_vector(m, 0x43, ROMSEG, FONT8_OFF);
};

fn set_vector(m: *machine, n: u8, seg: u16, off: u16) void = {
	x86::write16(m.cpu, 0, n: u16 * 4, off);
	x86::write16(m.cpu, 0, n: u16 * 4 + 2, seg);
};

// The current mode and what it looks like.
export fn video_mode(m: *machine) u8 = bda8(m, 0x49);
export fn video_info(m: *machine) modeinfo = m.vga.info;

// ---- Palettes ----

// The EGA's 64 colours (rgbRGB bits), as the VGA's DAC holds them in the
// 16-colour modes.
fn ega_colour(i: u8) [3]u8 = [
	(if (i & 4 != 0) 0x2Au8 else 0u8) + (if (i & 0x20 != 0) 0x15u8 else 0u8),
	(if (i & 2 != 0) 0x2Au8 else 0u8) + (if (i & 0x10 != 0) 0x15u8 else 0u8),
	(if (i & 1 != 0) 0x2Au8 else 0u8) + (if (i & 0x08 != 0) 0x15u8 else 0u8),
];

// The VGA BIOS's default 256-colour palette (mode 13h): 16 CGA colours,
// 16 greys, then 9 rings of 24 hues, and 8 blacks.
fn default_256(m: *machine) void = {
	const v = &m.vga;
	const attr16: [16]u8 = [0, 1, 2, 3, 4, 5, 0x14, 7, 0x38, 0x39, 0x3A, 0x3B,
		0x3C, 0x3D, 0x3E, 0x3F];
	for (let i = 0z; i < 16; i += 1) v.dac[i] = ega_colour(attr16[i]);
	const grey: [16]u8 = [0, 5, 8, 11, 14, 17, 20, 24, 28, 32, 36, 40, 45, 50, 56, 63];
	for (let i = 0z; i < 16; i += 1) v.dac[16 + i] = [grey[i]...];
	const rings: [9][5]u8 = [
		[0x00, 0x10, 0x1F, 0x2F, 0x3F], [0x1F, 0x27, 0x2F, 0x37, 0x3F],
		[0x2D, 0x31, 0x36, 0x3A, 0x3F], [0x00, 0x07, 0x0E, 0x15, 0x1C],
		[0x0E, 0x11, 0x15, 0x18, 0x1C], [0x14, 0x16, 0x18, 0x1A, 0x1C],
		[0x00, 0x04, 0x08, 0x0C, 0x10], [0x08, 0x0A, 0x0C, 0x0E, 0x10],
		[0x0B, 0x0C, 0x0D, 0x0F, 0x10],
	];
	// Hue steps around the wheel: which step R, G and B take.
	const hue: [24][3]u8 = [
		[0, 0, 4], [1, 0, 4], [2, 0, 4], [3, 0, 4], [4, 0, 4], [4, 0, 3],
		[4, 0, 2], [4, 0, 1], [4, 0, 0], [4, 1, 0], [4, 2, 0], [4, 3, 0],
		[4, 4, 0], [3, 4, 0], [2, 4, 0], [1, 4, 0], [0, 4, 0], [0, 4, 1],
		[0, 4, 2], [0, 4, 3], [0, 4, 4], [0, 3, 4], [0, 2, 4], [0, 1, 4],
	];
	for (let r = 0z; r < 9; r += 1) for (let h = 0z; h < 24; h += 1) {
		v.dac[32 + r * 24 + h] = [rings[r][hue[h][0]], rings[r][hue[h][1]],
			rings[r][hue[h][2]]];
	};
	for (let i = 248z; i < 256; i += 1) v.dac[i] = [0...];
	for (let i = 0u8; i < 16; i += 1) v.attr[i] = i;
};

// The 16 colours as a CGA monitor shows them (bit 4 is intensity, like
// the EGA in its 200-line modes), with dark yellow made brown.
fn cga_colour(i: u8) [3]u8 = {
	const hi: u8 = if (i & 0x10 != 0) 0x15 else 0;
	let c: [3]u8 = [
		(if (i & 4 != 0) 0x2Au8 else 0u8) + hi,
		(if (i & 2 != 0) 0x2Au8 else 0u8) + hi,
		(if (i & 1 != 0) 0x2Au8 else 0u8) + hi,
	];
	if (i & 0x17 == 6) c[1] = 0x15; // brown
	return c;
};

fn default_16(m: *machine) void = {
	const v = &m.vga;
	if (v.info.h == 200) {
		// 200-line modes: the VGA BIOS sets up the DAC like a CGA
		// monitor, so palette values 10h-17h (and 18h-1Fh, which games
		// like Commander Keen use) are the bright colours.
		for (let i = 0u8; i < 64; i += 1) v.dac[i] = cga_colour(i);
		const attr16: [16]u8 = [0, 1, 2, 3, 4, 5, 6, 7, 0x10, 0x11, 0x12,
			0x13, 0x14, 0x15, 0x16, 0x17];
		v.attr[..16] = attr16;
		return;
	};
	for (let i = 0u8; i < 64; i += 1) v.dac[i] = ega_colour(i);
	const attr16: [16]u8 = [0, 1, 2, 3, 4, 5, 0x14, 7, 0x38, 0x39, 0x3A, 0x3B,
		0x3C, 0x3D, 0x3E, 0x3F];
	v.attr[..16] = attr16;
};

// ---- Setting a mode ----

export fn set_mode(m: *machine, mode: u8, clear: bool) void = {
	const info = match (mode_info(mode)) {
	case let i: modeinfo => yield i;
	case void =>
		missing(m, 0x10, mode); // a mode Shifu doesn't have (yet)
		return;
	};
	const c = m.cpu;
	const v = &m.vga;
	v.info = info;
	set_bda8(m, 0x49, mode);
	set_bda16(m, 0x4A, info.cols);
	set_bda8(m, 0x84, info.rows - 1);
	set_bda16(m, 0x85, info.ch);
	set_bda16(m, 0x4C, switch (info.kind) {
	case vkind::TEXT => yield info.cols: u16 * info.rows * 2 + 0x60;
	case vkind::CGA4, vkind::CGA2 => yield 0x4000;
	case => yield 0xFA00;
	});
	set_bda8(m, 0x62, 0);
	set_bda16(m, 0x4E, 0);
	for (let p = 0u16; p < 8; p += 1) x86::write16(c, 0x40, 0x50 + p * 2, 0);

	// Registers back to the BIOS's values.
	m.crtc[0x0C] = 0;
	m.crtc[0x0D] = 0;
	m.crtc[0x0E] = 0;
	m.crtc[0x0F] = 0;
	m.crtc[0x13] = if (info.kind == vkind::TEXT) info.cols / 2
		else if (info.kind == vkind::VGA256) 40
		else if (info.w == 320) 20 else 40;
	if (info.kind == vkind::TEXT) {
		m.crtc[0x0A] = 0x0D;
		m.crtc[0x0B] = 0x0E;
		set_bda16(m, 0x60, 0x0607);
	} else {
		m.crtc[0x0A] = 0x20; // no cursor in graphics
	};
	v.seq = [0, 3, 0x0F, 0, if (info.kind == vkind::VGA256) 0x0E else 0x06, 0, 0, 0];
	v.unchained = false;
	v.gc = [0...];
	v.gc[5] = if (info.kind == vkind::TEXT) 0x10 else 0;
	v.gc[6] = if (info.kind == vkind::PLANAR || info.kind == vkind::VGA256) 0x05 else 0x0E;
	v.gc[7] = 0x0F;
	v.gc[8] = 0xFF;
	v.attr[0x10] = switch (info.kind) {
	case vkind::TEXT => yield 0x0C;
	case vkind::VGA256 => yield 0x41;
	case => yield 0x01;
	};
	v.attr[0x11] = 0;
	v.attr[0x12] = 0x0F;
	v.attr[0x13] = 0;
	v.attr[0x14] = 0;
	v.pel_mask = 0xFF;
	if (info.kind == vkind::VGA256) default_256(m) else default_16(m);
	v.cga_mode = switch (mode) {
	case 0 => yield 0x2C;
	case 1 => yield 0x28;
	case 2 => yield 0x2D;
	case 4 => yield 0x2A;
	case 5 => yield 0x2E;
	case 6 => yield 0x1E;
	case => yield 0x29;
	};
	v.cga_color = if (mode == 6) 0x3F else 0x30;
	set_bda8(m, 0x65, v.cga_mode);
	set_bda8(m, 0x66, v.cga_color);
	v.tty_color = switch (info.kind) {
	case vkind::CGA4 => yield 3;
	case vkind::CGA2 => yield 1;
	case => yield 15;
	};
	set_vector(m, 0x43, ROMSEG, if (info.ch == 8) FONT8_OFF else FONT16_OFF);

	// The planes are only reached through the VGA's logic.
	if (info.kind == vkind::PLANAR) {
		c.mmio_read = &planar_read;
		c.mmio_write = &planar_write;
	} else {
		c.mmio_read = null;
		c.mmio_write = null;
	};

	if (clear) switch (info.kind) {
	case vkind::TEXT =>
		const seg = text_seg(m);
		for (let i = 0u16; i < 0x4000; i += 2) x86::write16(c, seg, i, 0x0720);
	case vkind::CGA4, vkind::CGA2 =>
		for (let i = 0u32; i < 0x8000; i += 1) c.mem[0xB8000 + i] = 0;
	case vkind::PLANAR =>
		for (let i = 0z; i < len(v.planes); i += 1) v.planes[i] = 0;
	case vkind::VGA256 =>
		for (let i = 0u32; i < 0x10000; i += 1) c.mem[0xA0000 + i] = 0;
	};
	mouse_new_mode(m);
};

fn text_seg(m: *machine) u16 = if (video_mode(m) == 7) 0xB000 else VSEG;

// ---- EGA/VGA planes ----

// Chain-4 on or off in mode 13h: the pixels move between the plain
// memory at A0000h and the planes (pixel i is in plane i & 3 at i >> 2).
fn set_chain4(m: *machine, chained: bool) void = {
	const v = &m.vga;
	if (chained == !v.unchained) return;
	const c = m.cpu;
	if (chained) {
		for (let i = 0z; i < 0x10000; i += 1) {
			c.mem[0xA0000 + i] = v.planes[(i & 3) << 16 | i >> 2];
		};
		c.mmio_read = null;
		c.mmio_write = null;
	} else {
		for (let i = 0z; i < 0x10000; i += 1) {
			v.planes[(i & 3) << 16 | i >> 2] = c.mem[0xA0000 + i];
		};
		c.mmio_read = &planar_read;
		c.mmio_write = &planar_write;
	};
	v.unchained = !chained;
};

fn planar_read(c: *x86::cpu, a: u32) u8 = {
	const m = c.user: *machine;
	const v = &m.vga;
	const off = (a & 0xFFFF): size;
	for (let p = 0z; p < 4; p += 1) v.latch[p] = v.planes[p << 16 | off];
	if (v.gc[5] & 0x08 == 0) return v.latch[v.gc[4] & 3]; // read mode 0
	// Read mode 1: which pixels have the colour in "colour compare".
	let r = 0u8;
	for (let b = 0u8; b < 8; b += 1) {
		let same = true;
		for (let p = 0u8; p < 4; p += 1) {
			if (v.gc[7] & (1 << p) == 0) continue;
			if ((v.latch[p] >> b) & 1 != (v.gc[2] >> p) & 1) same = false;
		};
		if (same) r |= 1 << b;
	};
	return r;
};

fn planar_write(c: *x86::cpu, a: u32, val: u8) void = {
	const m = c.user: *machine;
	const v = &m.vga;
	const off = (a & 0xFFFF): size;
	// The common case (mode X drawing): write mode 0, no rotation,
	// logic, set/reset or bit mask, just the planes in the map mask.
	if (v.gc[5] & 3 == 0 && v.gc[3] == 0 && v.gc[1] == 0 && v.gc[8] == 0xFF) {
		const mm = v.seq[2];
		if (mm & 1 != 0) v.planes[off] = val;
		if (mm & 2 != 0) v.planes[0x10000 | off] = val;
		if (mm & 4 != 0) v.planes[0x20000 | off] = val;
		if (mm & 8 != 0) v.planes[0x30000 | off] = val;
		return;
	};
	const wmode = v.gc[5] & 3;
	const rot = v.gc[3] & 7, op = (v.gc[3] >> 3) & 3;
	const data = (val >> rot) | (val << ((8 - rot) & 7));
	let mask = v.gc[8];
	if (wmode == 3) mask &= data;
	for (let p = 0u8; p < 4; p += 1) {
		const bit = 1u8 << p;
		if (v.seq[2] & bit == 0) continue;
		const i = p: size << 16 | off;
		let d = 0u8;
		switch (wmode) {
		case 0 =>
			d = if (v.gc[1] & bit != 0) (if (v.gc[0] & bit != 0) 0xFF else 0) else data;
		case 1 => // copy the latches (fast blits)
			v.planes[i] = v.latch[p];
			continue;
		case 2 =>
			d = if (val & bit != 0) 0xFF else 0;
		case =>
			d = if (v.gc[0] & bit != 0) 0xFF else 0;
		};
		const l = v.latch[p];
		switch (op) {
		case 1 => d &= l;
		case 2 => d |= l;
		case 3 => d ^= l;
		case => void;
		};
		v.planes[i] = (d & mask) | (l & ~mask);
	};
};

// ---- Registers (ports 3C0h-3CFh, 3D8h, 3D9h) ----

fn vga_port_in(m: *machine, port: u16) u8 = {
	const v = &m.vga;
	switch (port) {
	case 0x3C0 => return v.attr_i;
	case 0x3C1 => return v.attr[v.attr_i & 0x1F];
	case 0x3C4 => return v.seq_i;
	case 0x3C5 => return v.seq[v.seq_i & 7];
	case 0x3C6 => return v.pel_mask;
	case 0x3C7 => return 3; // DAC state: reading
	case 0x3C8 => return v.dac_w;
	case 0x3C9 =>
		const r = v.dac[v.dac_r][v.dac_c];
		v.dac_c += 1;
		if (v.dac_c == 3) {
			v.dac_c = 0;
			v.dac_r += 1;
		};
		return r;
	case 0x3CC => return v.misc;
	case 0x3CE => return v.gc_i;
	case 0x3CF => return v.gc[v.gc_i & 0x0F];
	case => return 0xFF;
	};
};

fn vga_port_out(m: *machine, port: u16, val: u8) void = {
	const v = &m.vga;
	switch (port) {
	case 0x3C0 =>
		if (v.attr_data) {
			v.attr[v.attr_i & 0x1F] = val;
		} else {
			v.attr_i = val;
		};
		v.attr_data = !v.attr_data;
	case 0x3C2 => v.misc = val;
	case 0x3C4 => v.seq_i = val;
	case 0x3C5 =>
		v.seq[v.seq_i & 7] = val;
		if (v.seq_i & 7 == 4 && v.info.kind == vkind::VGA256) {
			set_chain4(m, val & 0x08 != 0);
		};
	case 0x3C6 => v.pel_mask = val;
	case 0x3C7 =>
		v.dac_r = val;
		v.dac_c = 0;
	case 0x3C8 =>
		v.dac_w = val;
		v.dac_c = 0;
	case 0x3C9 =>
		v.dac[v.dac_w][v.dac_c] = val & 0x3F;
		v.dac_c += 1;
		if (v.dac_c == 3) {
			v.dac_c = 0;
			v.dac_w += 1;
		};
	case 0x3CE => v.gc_i = val;
	case 0x3CF => v.gc[v.gc_i & 0x0F] = val;
	case 0x3D8 =>
		v.cga_mode = val;
		set_bda8(m, 0x65, val);
	case 0x3D9 =>
		v.cga_color = val;
		set_bda8(m, 0x66, val);
	case => void;
	};
};

// ---- Pixels (for the BIOS) ----

fn gfx_set(m: *machine, x: u16, y: u16, colour: u8) void = {
	const info = m.vga.info;
	if (x >= info.w || y >= info.h) return;
	const c = m.cpu;
	const xor = colour & 0x80 != 0;
	switch (info.kind) {
	case vkind::CGA4 =>
		const a = 0xB8000 + (y & 1): u32 * 0x2000 + (y >> 1): u32 * 80 + x: u32 / 4;
		const sh = (6 - (x & 3) * 2): u8;
		const bits = (colour & 3) << sh;
		c.mem[a] = if (xor) c.mem[a] ^ bits else (c.mem[a] & ~(3u8 << sh)) | bits;
	case vkind::CGA2 =>
		const a = 0xB8000 + (y & 1): u32 * 0x2000 + (y >> 1): u32 * 80 + x: u32 / 8;
		const bit = 0x80u8 >> (x & 7): u8;
		if (xor) {
			if (colour & 1 != 0) c.mem[a] ^= bit;
		} else {
			c.mem[a] = if (colour & 1 != 0) c.mem[a] | bit else c.mem[a] & ~bit;
		};
	case vkind::PLANAR =>
		const off = y: size * (info.w / 8): size + x: size / 8;
		const bit = 0x80u8 >> (x & 7): u8;
		for (let p = 0u8; p < 4; p += 1) {
			const i = p: size << 16 | (off & 0xFFFF);
			const on = colour & (1 << p) != 0;
			if (xor) {
				if (on) m.vga.planes[i] ^= bit;
			} else {
				m.vga.planes[i] = if (on) m.vga.planes[i] | bit else m.vga.planes[i] & ~bit;
			};
		};
	case vkind::VGA256 =>
		c.mem[0xA0000 + y: u32 * 320 + x] = colour;
	case vkind::TEXT => void;
	};
};

fn gfx_get(m: *machine, x: u16, y: u16) u8 = {
	const info = m.vga.info;
	if (x >= info.w || y >= info.h) return 0;
	const c = m.cpu;
	switch (info.kind) {
	case vkind::CGA4 =>
		const a = 0xB8000 + (y & 1): u32 * 0x2000 + (y >> 1): u32 * 80 + x: u32 / 4;
		return (c.mem[a] >> (6 - (x & 3) * 2): u8) & 3;
	case vkind::CGA2 =>
		const a = 0xB8000 + (y & 1): u32 * 0x2000 + (y >> 1): u32 * 80 + x: u32 / 8;
		return (c.mem[a] >> (7 - (x & 7): u8)) & 1;
	case vkind::PLANAR =>
		const off = (y: size * (info.w / 8): size + x: size / 8) & 0xFFFF;
		let r = 0u8;
		for (let p = 0u8; p < 4; p += 1) {
			if (m.vga.planes[p: size << 16 | off] & (0x80u8 >> (x & 7): u8) != 0) r |= 1 << p;
		};
		return r;
	case vkind::VGA256 =>
		return c.mem[0xA0000 + y: u32 * 320 + x];
	case vkind::TEXT => return 0;
	};
};

// Draws a character in a graphics mode at a text position.
fn gfx_char(m: *machine, col: u8, row: u8, ch: u8, colour: u8) void = {
	const info = m.vga.info;
	const x0 = col: u16 * 8, y0 = row: u16 * info.ch;
	const xor = colour & 0x80 != 0 && info.kind != vkind::VGA256;
	for (let gy = 0u16; gy < info.ch; gy += 1) {
		const bits = switch (info.ch) {
		case 8 => yield FONT8[ch][gy];
		case 14 => yield FONT16[ch][gy + 1];
		case => yield FONT16[ch][gy];
		};
		for (let gx = 0u16; gx < 8; gx += 1) {
			const on = bits & (0x80u8 >> gx: u8) != 0;
			if (xor) {
				if (on) gfx_set(m, x0 + gx, y0 + gy, colour);
			} else {
				gfx_set(m, x0 + gx, y0 + gy, if (on) colour else 0);
			};
		};
	};
};

// ---- Text (in any mode) ----

fn tcols(m: *machine) u8 = bda16(m, 0x4A): u8;
fn trows(m: *machine) u8 = bda8(m, 0x84) + 1;

// The text screen's size (columns, rows).
export fn text_size(m: *machine) (u8, u8) = (tcols(m), trows(m));

// The cursor position (column, row) the BIOS keeps.
export fn cursor(m: *machine) (u8, u8) = (bda8(m, 0x50), bda8(m, 0x51));

// Whether the cursor is visible (cursor start register bit 5 hides it).
export fn cursor_visible(m: *machine) bool = m.crtc[0x0A] & 0x20 == 0;

// The character and attribute at a text position (text modes).
export fn cell(m: *machine, col: u8, row: u8) (u8, u8) = {
	const off = (row: u16 * tcols(m) + col) * 2;
	const seg = text_seg(m);
	return (x86::read8(m.cpu, seg, off), x86::read8(m.cpu, seg, off + 1));
};

fn set_cell(m: *machine, col: u8, row: u8, ch: u8, attr: u8) void = {
	if (m.vga.info.kind != vkind::TEXT) {
		gfx_char(m, col, row, ch, attr);
		return;
	};
	const off = (row: u16 * tcols(m) + col) * 2;
	x86::write8(m.cpu, text_seg(m), off, ch);
	x86::write8(m.cpu, text_seg(m), off + 1, attr);
};

fn set_cursor(m: *machine, col: u8, row: u8) void = {
	set_bda8(m, 0x50, col);
	set_bda8(m, 0x51, row);
	hw_cursor_set(m, col, row);
};

// Where the video card shows the cursor (programs may set it directly).
export fn screen_cursor(m: *machine) (u8, u8) = {
	const pos = m.crtc[0x0E]: u16 << 8 | m.crtc[0x0F];
	const start = m.crtc[0x0C]: u16 << 8 | m.crtc[0x0D];
	const p = pos - start;
	return ((p % tcols(m)): u8, (p / tcols(m)): u8);
};

// Scrolls a window up (or down) by n lines; n = 0 clears it.
fn scroll(m: *machine, top: u8, left: u8, bottom: u8, right: u8, n: u8,
	attr: u8, up: bool) void = {
	const cols = tcols(m), rows = trows(m);
	let bottom = if (bottom >= rows) rows - 1 else bottom;
	let right = if (right >= cols) cols - 1 else right;
	if (top > bottom || left > right) return;
	const h = bottom - top + 1;
	let n = if (n == 0 || n > h) h else n;
	if (m.vga.info.kind != vkind::TEXT) {
		gfx_scroll(m, top, left, bottom, right, n, attr, up);
		return;
	};
	for (let i = 0u8; i < h; i += 1) {
		const r = if (up) top + i else bottom - i;
		for (let c = left; c <= right; c += 1) {
			if (i + n < h) {
				const from = if (up) r + n else r - n;
				const (ch, a) = cell(m, c, from);
				set_cell(m, c, r, ch, a);
			} else {
				set_cell(m, c, r, ' ', attr);
			};
		};
	};
};

fn gfx_scroll(m: *machine, top: u8, left: u8, bottom: u8, right: u8, n: u8,
	fill: u8, up: bool) void = {
	const chh = m.vga.info.ch: u16;
	const x0 = left: u16 * 8, x1 = (right: u16 + 1) * 8;
	const y0 = top: u16 * chh, y1 = (bottom: u16 + 1) * chh;
	const dy = n: u16 * chh;
	const h = y1 - y0;
	const fill = if (m.vga.info.kind == vkind::VGA256) fill else 0u8;
	for (let i = 0u16; i < h; i += 1) {
		const y = if (up) y0 + i else y1 - 1 - i;
		for (let x = x0; x < x1; x += 1) {
			if (i + dy < h) {
				const from = if (up) y + dy else y - dy;
				gfx_set(m, x, y, gfx_get(m, x, from));
			} else {
				gfx_set(m, x, y, fill);
			};
		};
	};
};

// Teletype output (INT 10h AH=0Eh): what DOS uses to print.
export fn tty_out(m: *machine, ch: u8) void = {
	let (col, row) = cursor(m);
	const cols = tcols(m), rows = trows(m);
	switch (ch) {
	case 7 => return; // bell
	case 8 =>
		if (col > 0) col -= 1;
	case 10 =>
		row += 1;
	case 13 =>
		col = 0;
	case =>
		if (m.vga.info.kind == vkind::TEXT) {
			const (_, attr) = cell(m, col, row);
			set_cell(m, col, row, ch, attr);
		} else {
			gfx_char(m, col, row, ch, m.vga.tty_color);
		};
		col += 1;
		if (col >= cols) {
			col = 0;
			row += 1;
		};
	};
	if (row >= rows) {
		const attr = if (m.vga.info.kind == vkind::TEXT) cell(m, 0, rows - 1).1 else 0u8;
		scroll(m, 0, 0, rows - 1, cols - 1, 1, attr, true);
		row = rows - 1;
	};
	set_cursor(m, col, row);
};

// ---- INT 10h ----

fn int10(m: *machine) bool = {
	const c = m.cpu;
	const ah = x86::get8(c, 4), al = x86::get8(c, 0);
	const bl = x86::get8(c, 3), bh = x86::get8(c, 7);
	switch (ah) {
	case 0x00 => set_mode(m, al & 0x7F, al & 0x80 == 0);
	case 0x01 => // cursor shape (CGA-style 8-line values are scaled)
		set_bda16(m, 0x60, c.r[x86::CX]);
		let start = x86::get8(c, 5), end = x86::get8(c, 1) & 0x1F;
		if (start & 0x1F < 8 && end < 8) {
			start = (start & 0x60) | (start & 0x1F) * 2;
			end = end * 2 + 1;
		};
		m.crtc[0x0A] = start;
		m.crtc[0x0B] = end;
	case 0x02 => set_cursor(m, x86::get8(c, 2), x86::get8(c, 6));
	case 0x03 => // get cursor
		const (col, row) = cursor(m);
		x86::set8(c, 2, col);
		x86::set8(c, 6, row);
		c.r[x86::CX] = bda16(m, 0x60);
	case 0x05 => void; // display page: only page 0
	case 0x06, 0x07 => // scroll window
		scroll(m, x86::get8(c, 5), x86::get8(c, 1), x86::get8(c, 6),
			x86::get8(c, 2), al, bh, ah == 0x06);
	case 0x08 => // read character and attribute
		const (col, row) = cursor(m);
		const (ch, a) = cell(m, col, row);
		c.r[x86::AX] = a: u16 << 8 | ch;
	case 0x09, 0x0A => // write character (and attribute) CX times
		let (col, row) = cursor(m);
		const gfx = m.vga.info.kind != vkind::TEXT;
		for (let i = 0u16; i < c.r[x86::CX]; i += 1) {
			if (gfx) {
				gfx_char(m, col, row, al, if (ah == 0x09) bl else m.vga.tty_color);
			} else {
				const (_, old) = cell(m, col, row);
				set_cell(m, col, row, al, if (ah == 0x09) bl else old);
			};
			col += 1;
			if (col >= tcols(m)) {
				col = 0;
				row += 1;
				if (row >= trows(m)) break;
			};
		};
	case 0x0B => // CGA palette: BH=0 background/border, BH=1 palette
		const v = &m.vga;
		if (bh == 0) {
			v.cga_color = (v.cga_color & 0xE0) | (bl & 0x1F);
		} else {
			v.cga_color = (v.cga_color & ~0x20) | (if (bl & 1 != 0) 0x20u8 else 0u8);
		};
		set_bda8(m, 0x66, v.cga_color);
	case 0x0C => gfx_set(m, c.r[x86::CX], c.r[x86::DX], al); // pixel
	case 0x0D => x86::set8(c, 0, gfx_get(m, c.r[x86::CX], c.r[x86::DX]));
	case 0x0E =>
		if (m.vga.info.kind != vkind::TEXT && bl != 0) m.vga.tty_color = bl;
		tty_out(m, al);
	case 0x0F => // get video mode
		x86::set8(c, 0, video_mode(m));
		x86::set8(c, 4, tcols(m));
		x86::set8(c, 7, 0);
	case 0x10 => palette_call(m, al);
	case 0x11 => font_call(m, al);
	case 0x12 => // EGA/VGA info
		if (bl == 0x10) {
			c.r[x86::BX] = 0x0003; // colour, 256 KiB
			c.r[x86::CX] = 0x0009;
		} else if (bl == 0x30 || bl == 0x31 || bl == 0x32 || bl == 0x34) {
			x86::set8(c, 0, 0x12); // supported
		};
	case 0x13 => // write string at ES:BP
		const save = cursor(m);
		set_cursor(m, x86::get8(c, 2), x86::get8(c, 6));
		let p = c.r[x86::BP];
		for (let i = 0u16; i < c.r[x86::CX]; i += 1) {
			const ch = x86::read8(c, c.s[x86::ES], p);
			p += 1;
			let a = bl;
			if (al & 2 != 0) {
				a = x86::read8(c, c.s[x86::ES], p);
				p += 1;
			};
			if (ch == 7 || ch == 8 || ch == 10 || ch == 13) {
				tty_out(m, ch);
			} else {
				const (col, row) = cursor(m);
				set_cell(m, col, row, ch, a);
				let col = col + 1, row = row;
				if (col >= tcols(m)) {
					col = 0;
					row += 1;
				};
				if (row >= trows(m)) {
					scroll(m, 0, 0, trows(m) - 1, tcols(m) - 1, 1, 0x07, true);
					row = trows(m) - 1;
				};
				set_cursor(m, col, row);
			};
		};
		if (al & 1 == 0) set_cursor(m, save.0, save.1);
	case 0x1A => // display combination: VGA colour
		if (al == 0) {
			x86::set8(c, 0, 0x1A);
			c.r[x86::BX] = 0x0008;
		};
	case 0x4F => void; // VESA: not here (AX stays 4Fxx, so "no")
	case => missing(m, 0x10, ah);
	};
	return true;
};

// INT 10h AH=10h: palette registers and the DAC.
fn palette_call(m: *machine, al: u8) void = {
	const c = m.cpu;
	const v = &m.vga;
	const bl = x86::get8(c, 3), bh = x86::get8(c, 7);
	const es = c.s[x86::ES], dx = c.r[x86::DX];
	switch (al) {
	case 0x00 => v.attr[bl & 0x1F] = bh;
	case 0x01 => v.attr[0x11] = bh;
	case 0x02 =>
		for (let i = 0u16; i < 16; i += 1) v.attr[i] = x86::read8(c, es, dx + i);
		v.attr[0x11] = x86::read8(c, es, dx + 16);
	case 0x03 => // blink (BL=1) or bright backgrounds
		const b = bda8(m, 0x65);
		set_bda8(m, 0x65, if (bl == 0) b & ~0x20 else b | 0x20);
	case 0x07 => x86::set8(c, 7, v.attr[bl & 0x1F]);
	case 0x08 => x86::set8(c, 7, v.attr[0x11]);
	case 0x09 =>
		for (let i = 0u16; i < 16; i += 1) x86::write8(c, es, dx + i, v.attr[i]);
		x86::write8(c, es, dx + 16, v.attr[0x11]);
	case 0x10 => // one DAC register: BX, DH=R CH=G CL=B
		v.dac[c.r[x86::BX] & 0xFF] = [x86::get8(c, 6) & 0x3F,
			x86::get8(c, 5) & 0x3F, x86::get8(c, 1) & 0x3F];
	case 0x12 => // a block: BX first, CX count, ES:DX table
		for (let i = 0u16; i < c.r[x86::CX]; i += 1) {
			const n = (c.r[x86::BX] + i) & 0xFF;
			for (let k = 0u16; k < 3; k += 1) {
				v.dac[n][k] = x86::read8(c, es, dx + i * 3 + k) & 0x3F;
			};
		};
	case 0x15 =>
		const e = v.dac[c.r[x86::BX] & 0xFF];
		x86::set8(c, 6, e[0]);
		x86::set8(c, 5, e[1]);
		x86::set8(c, 1, e[2]);
	case 0x17 =>
		for (let i = 0u16; i < c.r[x86::CX]; i += 1) {
			const n = (c.r[x86::BX] + i) & 0xFF;
			for (let k = 0u16; k < 3; k += 1) {
				x86::write8(c, es, dx + i * 3 + k, v.dac[n][k]);
			};
		};
	case 0x1A => // colour page state
		c.r[x86::BX] = 0;
	case => void;
	};
};

// INT 10h AH=11h: fonts. AL=30h tells where the ROM fonts are; AL=x1h,
// x2h, x4h switch text mode to 8x14 (28 rows), 8x8 (50 rows) or 8x16.
fn font_call(m: *machine, al: u8) void = {
	const c = m.cpu;
	switch (al) {
	case 0x30 =>
		const (seg, off) = switch (x86::get8(c, 7)) {
		case 0 => yield (x86::read16(c, 0, 0x1F * 4 + 2), x86::read16(c, 0, 0x1F * 4));
		case 1 => yield (x86::read16(c, 0, 0x43 * 4 + 2), x86::read16(c, 0, 0x43 * 4));
		case 3 => yield (ROMSEG, FONT8_OFF);
		case 4 => yield (ROMSEG, FONT8_OFF + 128 * 8);
		case => yield (ROMSEG, FONT16_OFF);
		};
		c.s[x86::ES] = seg;
		c.r[x86::BP] = off;
		c.r[x86::CX] = bda16(m, 0x85);
		x86::set8(c, 2, trows(m) - 1);
	case 0x01, 0x11, 0x02, 0x12, 0x04, 0x14 =>
		if (m.vga.info.kind != vkind::TEXT) return;
		const ch: u8 = switch (al & 0x0F) {
		case 1 => yield 14;
		case 2 => yield 8;
		case => yield 16;
		};
		const rows = (400 / ch: u16): u8;
		m.vga.info.ch = ch;
		m.vga.info.rows = rows;
		set_bda16(m, 0x85, ch);
		set_bda8(m, 0x84, rows - 1);
		set_bda16(m, 0x4C, tcols(m): u16 * rows * 2);
	case => void;
	};
};
