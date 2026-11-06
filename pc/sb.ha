// Shifu — a Sound Blaster 2.0 at 220h, IRQ 7, DMA 1 (BLASTER=A220 I7 D1):
// the DSP plays 8-bit samples that the 8237 DMA controller fetches from
// memory, and interrupts at the end of each block. Each block is copied
// when it starts playing, so a game can refill its buffer behind it, the
// way double buffering works on the real card.

def SB_IRQ: u8 = 7;
def SB_DMA: size = 1;
def NEVER: u64 = 0xFFFFFFFFFFFF;

export type dma = struct {
	base: [4]u16,
	count: [4]u16,
	page: [4]u8,
	mode: [4]u8,
	pos: [4]u32,   // bytes done in the current pass
	mask: u8,
	flip: bool,    // high byte next
};

// A block of samples that started playing at t (vtime).
export type sbblock = struct {
	t: u64,
	rate: u32,
	data: []u8,
};

export type sb = struct {
	reset_hi: bool,
	out: []u8,       // bytes waiting at 22Ah
	cmd: u8,
	args: [3]u8,
	nargs: size,
	need: size,
	rate: u32,
	blocksize: u32,
	speaker: bool,
	autoinit: bool,
	playing: bool,
	paused: bool,
	exit_auto: bool,
	next_irq: u64,   // PIT ticks
	test: u8,
	direct: [](u64, u8),  // direct-mode samples (vtime, value)
	blocks: []sbblock,
	level: f32,      // last direct sample
};

fn sb_init(m: *machine) void = {
	m.sb.rate = 11025;
	m.sb.next_irq = NEVER;
	m.dma.mask = 0x0F;
};

fn sb_free(m: *machine) void = {
	free(m.sb.out);
	free(m.sb.direct);
	for (let b .. m.sb.blocks) free(b.data);
	free(m.sb.blocks);
};

// ---- 8237 DMA controller (channels 0-3) ----

fn dma_write(m: *machine, port: u16, v: u8) void = {
	const d = &m.dma;
	switch (port) {
	case 0x00, 0x02, 0x04, 0x06 =>
		const ch = (port / 2): size;
		d.base[ch] = if (d.flip) (d.base[ch] & 0xFF) | v: u16 << 8
			else (d.base[ch] & 0xFF00) | v;
		d.flip = !d.flip;
		d.pos[ch] = 0;
	case 0x01, 0x03, 0x05, 0x07 =>
		const ch = (port / 2): size;
		d.count[ch] = if (d.flip) (d.count[ch] & 0xFF) | v: u16 << 8
			else (d.count[ch] & 0xFF00) | v;
		d.flip = !d.flip;
		d.pos[ch] = 0;
	case 0x0A => // single mask bit
		const bit = 1u8 << (v & 3);
		if (v & 4 != 0) d.mask |= bit else d.mask &= ~bit;
	case 0x0B => // mode
		d.mode[v & 3] = v;
	case 0x0C => d.flip = false;
	case 0x0D => // master clear
		d.flip = false;
		d.mask = 0x0F;
	case 0x0F => d.mask = v & 0x0F;
	case 0x87 => d.page[0] = v;
	case 0x83 => d.page[1] = v;
	case 0x81 => d.page[2] = v;
	case 0x82 => d.page[3] = v;
	case => void;
	};
};

fn dma_read(m: *machine, port: u16) u8 = {
	const d = &m.dma;
	switch (port) {
	case 0x00, 0x02, 0x04, 0x06 =>
		// The current address (programs read it to see which part of
		// the buffer is playing).
		const ch = (port / 2): size;
		const at = (d.base[ch]: u32 + d.pos[ch] % (d.count[ch]: u32 + 1)): u16;
		const v = if (d.flip) (at >> 8): u8 else at: u8;
		d.flip = !d.flip;
		return v;
	case 0x87 => return d.page[0];
	case 0x83 => return d.page[1];
	case 0x81 => return d.page[2];
	case 0x82 => return d.page[3];
	case 0x01, 0x03, 0x05, 0x07 =>
		// Count left (programs poll it to see where playback is).
		const ch = (port / 2): size;
		const left = (d.count[ch]: u32 - d.pos[ch] % (d.count[ch]: u32 + 1)): u16;
		const v = if (d.flip) (left >> 8): u8 else left: u8;
		d.flip = !d.flip;
		return v;
	case 0x08 => return 0; // status
	case => return 0xFF;
	};
};

// Fetches n bytes through a DMA channel (wrapping in auto-init mode).
fn dma_fetch(m: *machine, ch: size, n: u32) []u8 = {
	const d = &m.dma;
	let out: []u8 = alloc([0u8...], n)!;
	if (d.mask & (1 << ch: u8) != 0) return out; // masked: silence
	const total = d.count[ch]: u32 + 1;
	for (let i = 0u32; i < n; i += 1) {
		if (d.pos[ch] >= total) {
			if (d.mode[ch] & 0x10 == 0) break; // single: done
			d.pos[ch] = 0;
		};
		const a = d.page[ch]: u32 << 16 | ((d.base[ch]: u32 + d.pos[ch]) & 0xFFFF);
		out[i] = m.cpu.mem[a & 0xFFFFF];
		d.pos[ch] += 1;
	};
	return out;
};

// ---- The DSP (ports 226h, 22Ah, 22Ch, 22Eh) ----

fn sb_read(m: *machine, port: u16) u8 = {
	const s = &m.sb;
	switch (port & 0x0F) {
	case 0x0A => // read data
		if (len(s.out) == 0) return 0xFF;
		const v = s.out[0];
		delete(s.out[0]);
		return v;
	case 0x0C => return 0x7F; // write status: always ready
	case 0x0E => // read status; reading it acknowledges the interrupt
		return if (len(s.out) > 0) 0xFF else 0x7F;
	case => return 0xFF;
	};
};

fn sb_write(m: *machine, port: u16, v: u8) void = {
	const s = &m.sb;
	switch (port & 0x0F) {
	case 0x06 => // reset: 1 then 0, then the DSP says AAh
		if (v & 1 != 0) {
			s.reset_hi = true;
		} else if (s.reset_hi) {
			s.reset_hi = false;
			sb_stop(m);
			s.out = s.out[..0];
			append(s.out, 0xAA)!;
			s.need = 0;
			s.nargs = 0;
			s.speaker = false;
		};
	case 0x0C =>
		if (s.nargs < s.need) {
			s.args[s.nargs] = v;
			s.nargs += 1;
			if (s.nargs == s.need) dsp_command(m);
			return;
		};
		s.cmd = v;
		s.nargs = 0;
		s.need = switch (v) {
		case 0x10, 0x40, 0xE0, 0xE4, 0x38 => yield 1;
		case 0x14, 0x16, 0x17, 0x24, 0x41, 0x42, 0x48, 0x74, 0x75, 0x76, 0x77 => yield 2;
		case => yield 0;
		};
		if (s.need == 0) dsp_command(m);
	case => void;
	};
};

fn dsp_command(m: *machine) void = {
	const s = &m.sb;
	const a = s.args;
	const len16 = a[0]: u32 | a[1]: u32 << 8;
	switch (s.cmd) {
	case 0x10 => // one sample, straight to the speaker
		append(s.direct, (m.vtime, a[0]))!;
	case 0x14, 0x16, 0x17, 0x74, 0x75, 0x76, 0x77 => // 8-bit DMA, one block
		s.autoinit = false;
		sb_start(m, len16 + 1);
	case 0x1C => // auto-init 8-bit DMA
		s.autoinit = true;
		s.exit_auto = false;
		sb_start(m, s.blocksize);
	case 0x90 => // high-speed auto-init
		s.autoinit = true;
		s.exit_auto = false;
		sb_start(m, s.blocksize);
	case 0x91 => // high-speed single block
		s.autoinit = false;
		sb_start(m, s.blocksize);
	case 0x40 => // time constant: rate = 1 MHz / (256 - tc)
		s.rate = 1000000 / (256 - a[0]: u32);
	case 0x41, 0x42 => // SB16: rate in Hz
		s.rate = a[1]: u32 | a[0]: u32 << 8;
	case 0x48 => s.blocksize = len16 + 1;
	case 0xD0 => // pause
		s.paused = true;
		s.next_irq = NEVER;
	case 0xD4 => // continue
		if (s.paused && s.playing) {
			s.paused = false;
			sb_start(m, s.blocksize);
		};
	case 0xD1 => s.speaker = true;
	case 0xD3 => s.speaker = false;
	case 0xD8 => append(s.out, if (s.speaker) 0xFF else 0x00)!;
	case 0xDA => s.exit_auto = true; // stop after this block
	case 0xE0 => append(s.out, ~a[0])!;
	case 0xE1 => // version: 2.01
		append(s.out, 2)!;
		append(s.out, 1)!;
	case 0xE4 => s.test = a[0];
	case 0xE8 => append(s.out, s.test)!;
	case 0xF2 => raise_irq(m, SB_IRQ); // force an interrupt
	case 0x20 => append(s.out, 0x80)!; // direct input: silence
	case => void;
	};
};

// Starts playing a block of n bytes now.
fn sb_start(m: *machine, n: u32) void = {
	const s = &m.sb;
	if (n == 0 || s.rate == 0) return;
	s.playing = true;
	s.paused = false;
	s.blocksize = n;
	const data = dma_fetch(m, SB_DMA, n);
	if (m.audio_on) {
		append(s.blocks, sbblock { t = m.vtime, rate = s.rate, data = data })!;
	} else {
		free(data);
	};
	s.next_irq = now(m) + n: u64 * PIT_HZ / s.rate;
};

fn sb_stop(m: *machine) void = {
	m.sb.playing = false;
	m.sb.next_irq = NEVER;
};

// A block finished: interrupt, and in auto-init mode go on with the next.
fn sb_block_done(m: *machine) void = {
	const s = &m.sb;
	raise_irq(m, SB_IRQ);
	if (s.autoinit && !s.exit_auto) {
		const n = s.blocksize;
		s.next_irq = NEVER;
		sb_start(m, n);
	} else {
		sb_stop(m);
	};
};

// The digital sound at vtime t (-1..1).
fn sb_sample(m: *machine, t: u64) f32 = {
	const s = &m.sb;
	for (let i = len(s.blocks); i > 0; i -= 1) {
		const b = &s.blocks[i - 1];
		if (b.t > t) continue;
		const k = ((t - b.t) >> 16) * b.rate: u64 / PIT_HZ;
		if (k < len(b.data): u64) return (b.data[k]: f32 - 128.0) / 128.0;
		break;
	};
	for (let (dt, v) .. s.direct) {
		if (dt > t) break;
		s.level = (v: f32 - 128.0) / 128.0;
	};
	return s.level;
};

// Drops what has been played by vtime t.
fn sb_forget(m: *machine, t: u64) void = {
	const s = &m.sb;
	let n = 0z;
	for (n < len(s.direct) && s.direct[n].0 <= t) {
		s.level = (s.direct[n].1: f32 - 128.0) / 128.0;
		n += 1;
	};
	delete(s.direct[..n]);
	for (len(s.blocks) > 0) {
		const b = &s.blocks[0];
		const end = b.t + (len(b.data): u64 * PIT_HZ / b.rate: u64) << 16;
		if (end > t && len(s.blocks) == 1) break;
		if (end > t) break;
		free(b.data);
		delete(s.blocks[0]);
	};
};
