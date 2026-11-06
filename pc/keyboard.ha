// Shifu — the PC keyboard: physical keys (USB HID codes, as ViperGui
// reports them) become XT scan codes for the keyboard controller, each
// make code carrying the BIOS key it means on the host's layout (so æøå
// and AltGr keys come out right).

// USB HID code -> XT scan code (set 1). 0 = no such key on a PC.
const HID_XT: [232]u8 = [
	0, 0, 0, 0, 0x1E, 0x30, 0x2E, 0x20, 0x12, 0x21, 0x22, 0x23, 0x17, 0x24, 0x25, 0x26, // 0-15
	0x32, 0x31, 0x18, 0x19, 0x10, 0x13, 0x1F, 0x14, 0x16, 0x2F, 0x11, 0x2D, 0x15, 0x2C, 0x02, 0x03, // 16-31
	0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x1C, 0x01, 0x0E, 0x0F, 0x39, 0x0C, 0x0D, 0x1A, // 32-47
	0x1B, 0x2B, 0x2B, 0x27, 0x28, 0x29, 0x33, 0x34, 0x35, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F, 0x40, // 48-63
	0x41, 0x42, 0x43, 0x44, 0x57, 0x58, 0x37, 0x46, 0x45, 0x52, 0x47, 0x49, 0x53, 0x4F, 0x51, 0x4D, // 64-79
	0x4B, 0x50, 0x48, 0x45, 0x35, 0x37, 0x4A, 0x4E, 0x1C, 0x4F, 0x50, 0x51, 0x4B, 0x4C, 0x4D, 0x47, // 80-95
	0x48, 0x49, 0x52, 0x53, 0x56, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 96-111
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 112-127
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 128-143
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 144-159
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 160-175
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 176-191
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 192-207
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 208-223
	0x1D, 0x2A, 0x38, 0, 0x1D, 0x36, 0x38, 0, // 224-231: modifiers
];

// The XT scan code of a USB HID key (0 if there is none).
export fn xt_scan(hid: u16) u8 = if (hid < len(HID_XT)) HID_XT[hid] else 0;

// Modifier keys (host side, like the BIOS shift flags at 0040:0017).
def RSHIFT: u8 = 0x01;
def LSHIFT: u8 = 0x02;
def CTRL: u8 = 0x04;
def ALT: u8 = 0x08;

// Keys that send an E0 prefix: the grey arrows and editing keys, right
// Ctrl and Alt, keypad Enter and /.
fn extended(hid: u16) bool = switch (hid) {
case 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 84, 88, 228, 230 => yield true;
case => yield false;
};

// A key went down or up on the host. text is the character it typed
// ('\0' if none). The PC sees it like a real keyboard: make and break
// scan codes on port 60h with IRQ 1, which the BIOS (or a game's own
// INT 9 handler) turns into keys.
export fn key_event(m: *machine, hid: u16, down: bool, text: rune) void = {
	const f: u8 = switch (hid) {
	case 225 => yield LSHIFT;
	case 229 => yield RSHIFT;
	case 224, 228 => yield CTRL;
	case 226, 230 => yield ALT;
	case => yield 0;
	};
	if (f != 0) {
		if (down) m.host_mods |= f else m.host_mods &= ~f;
	};
	const scan = xt_scan(hid);
	if (scan == 0) return;
	const key = if (down) bios_key_for(m.host_mods, hid, text) else 0u16;
	if (extended(hid)) append(m.kbd_q, (0xE0, 0))!;
	append(m.kbd_q, (if (down) scan else scan | 0x80, key))!;
};

// Types a BIOS key (scan code << 8 | character) as a press and release,
// for frontends that only know characters (the terminal, -k).
export fn type_key(m: *machine, key: u16) void = {
	const scan = (key >> 8): u8;
	if (scan == 0 || scan >= 0x80) {
		push_key(m, key); // no real key for it: straight to the BIOS
		return;
	};
	const ext = key: u8 == 0 && (scan == 0x47 || scan == 0x48 || scan == 0x49 ||
		scan == 0x4B || scan == 0x4D || scan == 0x4F || scan == 0x50 ||
		scan == 0x51 || scan == 0x52 || scan == 0x53);
	if (ext) append(m.kbd_q, (0xE0, 0))!;
	append(m.kbd_q, (scan, key))!;
	if (ext) append(m.kbd_q, (0xE0, 0))!;
	append(m.kbd_q, (scan | 0x80, 0))!;
};

// The BIOS key (scan code << 8 | character) a key press means, given the
// modifiers held. 0 for keys that give none (Shift, Ctrl, Caps Lock...).
fn bios_key_for(mods: u8, hid: u16, text: rune) u16 = {
	const scan = xt_scan(hid);
	const shift = mods & (LSHIFT | RSHIFT) != 0;
	const ctrl = mods & CTRL != 0, alt = mods & ALT != 0;

	// F1-F10: their own codes for Shift, Ctrl and Alt.
	if (scan >= 0x3B && scan <= 0x44) {
		const n = scan - 0x3B;
		const s = if (alt) 0x68 + n else if (ctrl) 0x5E + n
			else if (shift) 0x54 + n else scan;
		return s: u16 << 8;
	};
	switch (hid) {
	case 68 => return if (shift) 0x8700 else 0x8500; // F11
	case 69 => return if (shift) 0x8800 else 0x8600; // F12
	case 40, 88 => return if (ctrl) 0x1C0A else 0x1C0D; // Enter
	case 41 => return 0x011B; // Esc
	case 42 => return if (ctrl) 0x0E7F else 0x0E08; // Backspace
	case 43 => return if (shift) 0x0F00 else 0x0F09; // Tab
	case 57, 83, 71, 72, 224, 225, 226, 228, 229, 230 => return 0;
	case => void;
	};
	// Alt+key: the scan code alone.
	if (alt) return scan: u16 << 8;
	// Ctrl+letter: control characters 1-26.
	if (ctrl && hid >= 4 && hid <= 29) return scan: u16 << 8 | (hid - 3): u16;
	if (text != '\0') {
		match (from_unicode(text)) {
		case let ch: u8 => return scan: u16 << 8 | ch;
		case void => return 0;
		};
	};
	// Keys that type nothing: arrows, Home, End, PgUp, PgDn, Ins, Del.
	switch (scan) {
	case 0x47, 0x48, 0x49, 0x4B, 0x4D, 0x4F, 0x50, 0x51, 0x52, 0x53 =>
		return scan: u16 << 8;
	case => return 0;
	};
};

// Whether attribute bit 7 means blinking text (else a bright background).
export fn blink_enabled(m: *machine) bool = bda8(m, 0x65) & 0x20 != 0;

// The cursor's first and last scan line in a 16-line character cell
// (CRTC registers 0Ah and 0Bh).
export fn cursor_shape(m: *machine) (u8, u8) = {
	const start = m.crtc[0x0A] & 0x1F;
	let end = m.crtc[0x0B] & 0x1F;
	if (end > 15) end = 15;
	return (start, end);
};
