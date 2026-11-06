// Shifu — what the monitor shows: [[render]] turns the video card's state
// into 0xAARRGGBB pixels for the frontends, in every mode.
use x86;

// The largest picture: 640x480.
export def MAX_W: size = 640;
export def MAX_H: size = 480;

// A rendered picture: w x h pixels, each shown xrep x yrep times (so a
// 320x200 mode fills 640x400, like on a VGA monitor).
export type picture = struct {
	w: u16,
	h: u16,
	xrep: u16,
	yrep: u16,
};

// The 16 CGA colours (with the brown fix).
const CGA_RGB: [16]u32 = [
	0x000000, 0x0000AA, 0x00AA00, 0x00AAAA, 0xAA0000, 0xAA00AA, 0xAA5500, 0xAAAAAA,
	0x555555, 0x5555FF, 0x55FF55, 0x55FFFF, 0xFF5555, 0xFF55FF, 0xFFFF55, 0xFFFFFF,
];

fn dac_rgb(v: *vga, i: u8) u32 = {
	const e = &v.dac[i & v.pel_mask];
	const r = (e[0] << 2) | (e[0] >> 4), g = (e[1] << 2) | (e[1] >> 4),
		b = (e[2] << 2) | (e[2] >> 4);
	return 0xFF000000 | r: u32 << 16 | g: u32 << 8 | b: u32;
};

// The colours of the 16 attribute indexes (through the attribute
// controller's palette into the DAC).
fn palette16(v: *vga) [16]u32 = {
	let pal: [16]u32 = [0...];
	for (let i = 0u8; i < 16; i += 1) {
		let idx = v.attr[i] & 0x3F;
		if (v.attr[0x10] & 0x80 != 0) {
			idx = (idx & 0x0F) | (v.attr[0x14] & 3) << 4;
		};
		idx |= (v.attr[0x14] & 0x0C) << 4;
		pal[i] = dac_rgb(v, idx);
	};
	return pal;
};

// Renders the screen into pix (at least MAX_W * MAX_H). frame counts
// frames (about 60 a second), for blinking text and the cursor.
export fn render(m: *machine, pix: []u32, frame: u64) picture = {
	const info = m.vga.info;
	const pic = switch (info.kind) {
	case vkind::TEXT => yield render_text(m, pix, frame);
	case vkind::CGA4 => yield render_cga(m, pix, false);
	case vkind::CGA2 => yield render_cga(m, pix, true);
	case vkind::PLANAR => yield render_planar(m, pix);
	case vkind::VGA256 => yield render_256(m, pix);
	};
	mouse_overlay(m, pix, pic);
	return pic;
};

fn render_text(m: *machine, pix: []u32, frame: u64) picture = {
	const v = &m.vga;
	const pal = palette16(v);
	const (cols, rows) = text_size(m);
	const chh = v.info.ch: size;
	const cw: size = if (cols == 40) 16 else 8;
	const seg = text_seg(m);
	const start = (m.crtc[0x0C]: u16 << 8 | m.crtc[0x0D]) * 2;
	const blink = blink_enabled(m);
	const text_on = frame / 32 % 2 == 0;
	const cursor_on = cursor_visible(m) && frame / 16 % 2 == 0;
	const (ccol, crow) = screen_cursor(m);
	const (cs, ce) = cursor_shape(m);
	const mshow = mouse_visible(m);
	const (mcol, mrow) = mouse_text_cell(m, cols);
	for (let row = 0u8; row < rows; row += 1) for (let col = 0u8; col < cols; col += 1) {
		const off = start + (row: u16 * cols + col) * 2;
		let ch = x86::read8(m.cpu, seg, off);
		let attr = x86::read8(m.cpu, seg, off + 1);
		if (mshow && col == mcol && row == mrow) {
			// The mouse's text cursor: the cell through its two masks.
			const w = ((attr: u16 << 8 | ch) & m.mouse.scr_mask) ^ m.mouse.cur_mask;
			ch = w: u8;
			attr = (w >> 8): u8;
		};
		let fg = pal[attr & 0x0F], bg = pal[attr >> 4];
		let hide = false;
		if (blink) {
			bg = pal[(attr >> 4) & 7];
			hide = attr & 0x80 != 0 && !text_on;
		};
		const cur = cursor_on && col == ccol && row == crow;
		for (let gy = 0z; gy < chh; gy += 1) {
			let bits = if (hide) 0u8 else switch (chh) {
			case 8 => yield FONT8[ch][gy];
			case 14 => yield FONT16[ch][gy + 1];
			case => yield FONT16[ch][gy];
			};
			// The cursor's lines, scaled to the character height.
			if (cur && gy * 16 / chh >= cs && gy * 16 / chh <= ce) bits = 0xFF;
			let p = (row: size * chh + gy) * MAX_W + col: size * cw;
			for (let gx = 0z; gx < 8; gx += 1) {
				const c = if (bits & (0x80u8 >> gx: u8) != 0) fg else bg;
				pix[p] = c;
				if (cw == 16) {
					pix[p + 1] = c;
					p += 2;
				} else {
					p += 1;
				};
			};
		};
	};
	return picture { w = 640, h = (rows: size * chh): u16, xrep = 1, yrep = 1 };
};

fn render_cga(m: *machine, pix: []u32, mono: bool) picture = {
	const v = &m.vga;
	const mem = m.cpu.mem[0xB8000..0xBC000];
	if (mono) {
		const fg = 0xFF000000 | CGA_RGB[v.cga_color & 0x0F];
		const bg = 0xFF000000u32;
		for (let y = 0z; y < 200; y += 1) {
			const line = (y & 1) * 0x2000 + (y >> 1) * 80;
			for (let x = 0z; x < 640; x += 1) {
				const on = mem[line + x / 8] & (0x80u8 >> (x & 7): u8) != 0;
				pix[y * MAX_W + x] = if (on) fg else bg;
			};
		};
		return picture { w = 640, h = 200, xrep = 1, yrep = 2 };
	};
	// 320x200: background, then palette 0 (green, red, brown) or 1 (cyan,
	// magenta, white), bright with the intensity bit. Mode 5 (no colour
	// burst) shows cyan, red, white.
	const sel = v.cga_color & 0x20 != 0;
	const bright: u8 = if (v.cga_color & 0x10 != 0) 8 else 0;
	const cols: [3]u8 = if (v.cga_mode & 0x04 != 0) [3, 4, 7]
		else if (sel) [3, 5, 7] else [2, 4, 6];
	const pal: [4]u32 = [
		0xFF000000 | CGA_RGB[v.cga_color & 0x0F],
		0xFF000000 | CGA_RGB[cols[0] | bright],
		0xFF000000 | CGA_RGB[cols[1] | bright],
		0xFF000000 | CGA_RGB[cols[2] | bright],
	];
	for (let y = 0z; y < 200; y += 1) {
		const line = (y & 1) * 0x2000 + (y >> 1) * 80;
		for (let x = 0z; x < 320; x += 1) {
			const b = mem[line + x / 4];
			pix[y * MAX_W + x] = pal[(b >> (6 - (x & 3) * 2): u8) & 3];
		};
	};
	return picture { w = 320, h = 200, xrep = 2, yrep = 2 };
};

fn render_planar(m: *machine, pix: []u32) picture = {
	const v = &m.vga;
	const info = v.info;
	const pal = palette16(v);
	const enable = v.attr[0x12] & 0x0F;
	const linew = m.crtc[0x13]: size * 2;
	const start = m.crtc[0x0C]: size << 8 | m.crtc[0x0D];
	const pan = (v.attr[0x13] & 7): size;
	const p0 = v.planes[0..0x10000], p1 = v.planes[0x10000..0x20000],
		p2 = v.planes[0x20000..0x30000], p3 = v.planes[0x30000..0x40000];
	for (let y = 0z; y < info.h: size; y += 1) {
		const base = start + y * linew;
		for (let x = 0z; x < info.w: size; x += 1) {
			const px = x + pan;
			const i = (base + px / 8) & 0xFFFF;
			const sh = (7 - px % 8): u8;
			const c = ((p0[i] >> sh) & 1) | ((p1[i] >> sh) & 1) << 1 |
				((p2[i] >> sh) & 1) << 2 | ((p3[i] >> sh) & 1) << 3;
			pix[y * MAX_W + x] = pal[c & enable];
		};
	};
	const xrep: u16 = if (info.w == 320) 2 else 1;
	const yrep: u16 = if (info.h == 200) 2 else 1;
	return picture { w = info.w, h = info.h, xrep = xrep, yrep = yrep };
};

fn render_256(m: *machine, pix: []u32) picture = {
	const v = &m.vga;
	let rgb: [256]u32 = [0...];
	for (let i = 0z; i < 256; i += 1) rgb[i] = dac_rgb(v, i: u8);
	if (v.unchained) {
		// Mode X: plane x & 3, from the CRTC's start address and line
		// length (the page the program flipped to).
		const start = m.crtc[0x0C]: size << 8 | m.crtc[0x0D];
		const linew = m.crtc[0x13]: size * 2;
		for (let y = 0z; y < 200; y += 1) {
			const base = start + y * linew;
			for (let x = 0z; x < 320; x += 1) {
				const i = (x & 3) << 16 | ((base + (x >> 2)) & 0xFFFF);
				pix[y * MAX_W + x] = rgb[v.planes[i]];
			};
		};
		return picture { w = 320, h = 200, xrep = 2, yrep = 2 };
	};
	const mem = m.cpu.mem[0xA0000..0xAFA00];
	for (let y = 0z; y < 200; y += 1) for (let x = 0z; x < 320; x += 1) {
		pix[y * MAX_W + x] = rgb[mem[y * 320 + x]];
	};
	return picture { w = 320, h = 200, xrep = 2, yrep = 2 };
};
