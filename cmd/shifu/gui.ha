// shifu — the ViperGui frontend: whatever the PC's video card shows (text
// with the CP865 font, CGA, EGA/VGA 16 colours, mode 13h), scaled into a
// 4:3 window, the keyboard as real PC keys, and the mouse.
use pc;
use viper;

type gscreen = struct {
	buf: []u32,   // what pc::render made
	prev: []u32,  // what is in the window
	last: pc::picture,
	frames: u64,
};

// Runs the program in a window. Returns true if stopped with Ctrl-] or by
// closing the window before the program ended.
fn window(m: *pc::machine, title: str, scale: int, clock: *pacer) (bool | viper::error | nomem) = {
	const win = viper::open(title, pc::MAX_W: int * scale, pc::MAX_H: int * scale)?;
	defer viper::close(win);
	let scr = gscreen {
		buf = alloc([0u32...], pc::MAX_W * pc::MAX_H)?,
		prev = alloc([0u32...], pc::MAX_W * pc::MAX_H)?,
		...
	};
	defer free(scr.buf);
	defer free(scr.prev);
	let ended = false;

	for (viper::frame(win)) {
		const ctrl = viper::key_down(win, 224: viper::key) ||
			viper::key_down(win, 228: viper::key);
		for (let ev .. viper::key_events(win)) {
			if (ctrl && ev.down && ev.hid == 48) return true; // Ctrl-]
			if (ended) {
				// Any key closes the window once the program is done.
				if (ev.down && !ev.repeat && ev.hid != 0 && ev.hid < 224) {
					return false;
				};
				continue;
			};
			if (ev.hid == 0) continue;
			pc::key_event(m, ev.hid, ev.down, ev.text);
		};

		if (!m.exited) {
			feed_mouse(win, m, &scr, scale);
			pace(m, clock);
			if (m.exited) {
				ended = true;
				scr.last = pc::picture { ... }; // redraw under the banner
				viper::show_cursor(win, true);
			};
		};

		draw_screen(win, m, &scr, scale);
		if (ended) banner(win, scale);
		viper::present(win);
		scr.frames += 1;
	};
	return !ended;
};

// Gives the PC's mouse driver the host's pointer, mapped onto the picture
// as it sits in the window, and the buttons and wheel.
fn feed_mouse(win: *viper::window, m: *pc::machine, scr: *gscreen, scale: int) void = {
	const pic = scr.last;
	const (mx, my) = viper::mouse(win);
	if (mx >= 0 && pic.w != 0) {
		const pw = pic.w: int * pic.xrep: int * scale;
		const ph = pic.h: int * pic.yrep: int * scale;
		const ox = (pc::MAX_W: int * scale - pw) / 2;
		const oy = (pc::MAX_H: int * scale - ph) / 2;
		pc::mouse_move(m, (mx - ox): f64 / pw: f64, (my - oy): f64 / ph: f64);
	};
	// A click that started and ended between two frames still counts:
	// down now, up next frame.
	pc::mouse_buttons(m, viper::mouse_buttons(win) | viper::mouse_clicks(win));
	pc::mouse_wheel(m, viper::wheel(win));
	// A program that uses the mouse draws its own pointer.
	viper::show_cursor(win, !pc::mouse_used(m));
};

// Draws the picture, only the rows that changed since the last frame.
fn draw_screen(win: *viper::window, m: *pc::machine, scr: *gscreen, scale: int) void = {
	const pic = pc::render(m, scr.buf, scr.frames);
	let fresh = false;
	if (pic.w != scr.last.w || pic.h != scr.last.h || pic.xrep != scr.last.xrep ||
		pic.yrep != scr.last.yrep) {
		viper::clear(win, viper::rgb(0, 0, 0));
		scr.last = pic;
		fresh = true;
	};
	const w = pic.w: size, h = pic.h: size;
	const sx = pic.xrep: int * scale, sy = pic.yrep: int * scale;
	const ox = (pc::MAX_W: int * scale - w: int * sx) / 2;
	const oy = (pc::MAX_H: int * scale - h: int * sy) / 2;
	for (let y = 0z; y < h; y += 1) {
		const row = scr.buf[y * pc::MAX_W..y * pc::MAX_W + w];
		const old = scr.prev[y * pc::MAX_W..y * pc::MAX_W + w];
		if (!fresh && same(row, old)) continue;
		old[..] = row;
		for (let r = 0; r < sy; r += 1) {
			let p = (oy + y: int * sy + r) * win.width + ox;
			for (let x = 0z; x < w; x += 1) {
				const c = row[x];
				for (let k = 0; k < sx; k += 1) {
					win.pixels[p] = c;
					p += 1;
				};
			};
		};
	};
};

fn same(a: []u32, b: []u32) bool = {
	for (let i = 0z; i < len(a); i += 1) if (a[i] != b[i]) return false;
	return true;
};

// A note at the bottom once the program has ended.
fn banner(win: *viper::window, scale: int) void = {
	const msg = "Programmet er slut - tryk en tast for at lukke";
	const w = viper::text_width(msg, scale) + 16 * scale;
	const h = 20 * scale;
	const x = win.width - w - 8 * scale, y = win.height - h - 8 * scale;
	viper::rect(win, x, y, w, h, viper::rgb(170, 0, 0));
	viper::text_scaled(win, x + 8 * scale, y + 2 * scale, msg,
		viper::rgb(255, 255, 85), scale);
};
