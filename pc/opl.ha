// Shifu — the AdLib card: a Yamaha YM3812 (OPL2) FM synthesizer at ports
// 388h/389h. Nine channels of two operators each (a modulator and a
// carrier), envelopes, four waveforms, tremolo, vibrato, feedback, the
// five rhythm instruments, and the two timers programs use to find the
// card. The sound is a model of the chip, not a bit-exact copy.
use math;

def OPL_CLOCK: f64 = 49716.0;
def RATE: f64 = 44100.0;

const MULT: [16]f64 = [0.5, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0,
	10.0, 10.0, 12.0, 12.0, 15.0, 15.0];
// Attack times (0 to full) and decay/release times (to silence) in ms,
// from the YM3812 data sheet, for rates 0-15 (0 = never).
const ATTACK_MS: [16]f64 = [0.0, 2826.24, 1413.12, 706.56, 353.28, 176.64,
	88.32, 44.16, 22.08, 11.04, 5.52, 2.76, 1.38, 0.69, 0.35, 0.0];
const DECAY_MS: [16]f64 = [0.0, 39280.64, 19640.32, 9820.16, 4910.08,
	2455.04, 1227.52, 613.76, 306.88, 153.44, 76.72, 38.36, 19.18, 9.59,
	4.79, 2.40];
// Key scaling: attenuation (dB) by the top 4 F-number bits, octave 7.
const KSL_DB: [16]f64 = [0.0, 9.0, 12.0, 13.875, 15.0, 16.125, 16.875,
	17.625, 18.0, 18.75, 19.125, 19.5, 19.875, 20.25, 20.625, 21.0];

export type egstage = enum u8 {
	OFF,
	ATTACK,
	DECAY,
	SUSTAIN,
	RELEASE,
};

export type oplop = struct {
	phase: f64,   // in cycles
	env: f64,     // attenuation in dB (0 loud, 96 silent)
	st: egstage,
	out1: f64,    // the last two outputs, for feedback
	out2: f64,
};

export type opl = struct {
	// The chip as programs see it: address latch, registers, timers.
	addr: u8,
	regs: [256]u8,
	t1_start: u64,
	t2_start: u64,
	flags: u8,
	// The synthesizer, which follows the register writes in time.
	sregs: [256]u8,
	ops: [22]oplop,   // by register slot (0-21; 6, 7, 14, 15 unused)
	noise: u32,
	lfo: f64,         // seconds
	ready: bool,
};

let SIN: [1024]f64 = [0.0...];
let AMP: [1024]f64 = [0.0...]; // attenuation in 1/8 dB -> amplitude

fn opl_init(o: *opl) void = {
	for (let i = 0z; i < 1024; i += 1) {
		SIN[i] = math::sinf64(i: f64 * 2.0 * math::PI / 1024.0);
		AMP[i] = math::powf64(10.0, -(i: f64 / 8.0) / 20.0);
	};
	for (let i = 0z; i < len(o.ops); i += 1) {
		o.ops[i].env = 96.0;
		o.ops[i].st = egstage::OFF;
	};
	o.noise = 1;
	o.ready = true;
};

// Register slots of a channel's modulator and carrier.
fn slots(c: size) (size, size) = {
	const s = (c / 3) * 8 + c % 3;
	return (s, s + 3);
};

// ---- What programs see (ports 388h/389h) ----

fn opl_status(m: *machine) u8 = {
	const o = &m.opl;
	const t = now(m);
	const ctl = o.regs[4];
	if (ctl & 0x01 != 0 && ctl & 0x40 == 0) {
		const period = (256 - o.regs[2]: u64) * PIT_HZ * 80 / 1000000;
		if (t - o.t1_start >= period) o.flags |= 0x40;
	};
	if (ctl & 0x02 != 0 && ctl & 0x20 == 0) {
		const period = (256 - o.regs[3]: u64) * PIT_HZ * 320 / 1000000;
		if (t - o.t2_start >= period) o.flags |= 0x20;
	};
	// Bits 1-2 are set on an OPL2 (an OPL3 has them clear).
	return (if (o.flags != 0) o.flags | 0x80 else 0u8) | 0x06;
};

fn opl_write(m: *machine, v: u8) void = {
	const o = &m.opl;
	const r = o.addr;
	if (r == 4) {
		if (v & 0x80 != 0) { // reset the timer flags only
			o.flags = 0;
			return;
		};
		const old = o.regs[4];
		const t = now(m);
		if (v & 1 != 0 && old & 1 == 0) o.t1_start = t;
		if (v & 2 != 0 && old & 2 == 0) o.t2_start = t;
	};
	o.regs[r] = v;
	if (r >= 0x20) append(m.opl_ev, oplwrite { t = m.vtime, reg = r, val = v })!;
	if (r == 1) append(m.opl_ev, oplwrite { t = m.vtime, reg = r, val = v })!;
};

// ---- The synthesizer ----

fn key_on(op: *oplop) void = {
	op.st = egstage::ATTACK;
	op.phase = 0.0;
};

fn key_off(op: *oplop) void = {
	if (op.st != egstage::OFF) op.st = egstage::RELEASE;
};

fn opl_synth_write(o: *opl, reg: u8, val: u8) void = {
	if (!o.ready) opl_init(o);
	const old = o.sregs[reg];
	o.sregs[reg] = val;
	if (reg >= 0xB0 && reg <= 0xB8) {
		const (a, b) = slots((reg - 0xB0): size);
		if (val & 0x20 != 0 && old & 0x20 == 0) {
			key_on(&o.ops[a]);
			key_on(&o.ops[b]);
		} else if (val & 0x20 == 0 && old & 0x20 != 0) {
			key_off(&o.ops[a]);
			key_off(&o.ops[b]);
		};
	} else if (reg == 0xBD) {
		// The rhythm instruments: BD, SD, TT, CY, HH (bits 4-0).
		const drums: [5](u8, size, size) = [
			(0x10, 16, 19), (0x08, 20, 20), (0x04, 18, 18),
			(0x02, 21, 21), (0x01, 17, 17),
		];
		for (let (bit, a, b) .. drums) {
			const on = val & 0x20 != 0 && val & bit != 0;
			const was = old & 0x20 != 0 && old & bit != 0;
			if (on && !was) {
				key_on(&o.ops[a]);
				if (b != a) key_on(&o.ops[b]);
			} else if (!on && was) {
				key_off(&o.ops[a]);
				if (b != a) key_off(&o.ops[b]);
			};
		};
	};
};

fn wave(o: *opl, ws: u8, p: f64) f64 = {
	const f = p - math::floorf64(p);
	const s = SIN[(f * 1024.0): size & 1023];
	if (o.sregs[1] & 0x20 == 0) return s; // waveforms not enabled
	switch (ws & 3) {
	case 0 => return s;
	case 1 => return if (s > 0.0) s else 0.0;
	case 2 => return math::absf64(s);
	case => return if (f < 0.25 || (f >= 0.5 && f < 0.75)) math::absf64(s) else 0.0;
	};
};

// Moves an operator's envelope on by one sample.
fn envelope(o: *opl, op: *oplop, slot: size, fnum: u16, block: u8) void = {
	const r20 = o.sregs[0x20 + slot], r60 = o.sregs[0x60 + slot],
		r80 = o.sregs[0x80 + slot];
	// Key scale rate: higher notes have faster envelopes.
	const rof = if (r20 & 0x10 != 0) block * 2 + ((fnum >> 9) & 1): u8 else block >> 1;
	const speed = math::powf64(2.0, rof: f64 / 4.0);
	const ar = r60 >> 4, dr = r60 & 0x0F, rr = r80 & 0x0F;
	const sl = if (r80 >> 4 == 15) 93.0 else (r80 >> 4): f64 * 3.0;
	switch (op.st) {
	case egstage::OFF => op.env = 96.0;
	case egstage::ATTACK =>
		if (ar == 0) return;
		if (ar == 15 || ATTACK_MS[ar] / speed < 0.05) {
			op.env = 0.0;
			op.st = egstage::DECAY;
			return;
		};
		// Exponential, like the chip: from 96 dB to 0 in the attack time.
		const k = 4.57 / (ATTACK_MS[ar] / speed / 1000.0 * RATE);
		op.env = (op.env + 1.0) * (1.0 - k) - 1.0;
		if (op.env <= 0.0) {
			op.env = 0.0;
			op.st = egstage::DECAY;
		};
	case egstage::DECAY =>
		if (dr != 0) op.env += 96.0 / (DECAY_MS[dr] / speed / 1000.0 * RATE);
		if (op.env >= sl) {
			op.env = sl;
			op.st = egstage::SUSTAIN;
		};
	case egstage::SUSTAIN =>
		// Sustaining sounds hold; the others fade at the release rate.
		if (r20 & 0x20 == 0) release(op, rr, speed);
	case egstage::RELEASE =>
		release(op, rr, speed);
	};
};

fn release(op: *oplop, rr: u8, speed: f64) void = {
	if (rr == 0) return;
	op.env += 96.0 / (DECAY_MS[rr] / speed / 1000.0 * RATE);
	if (op.env >= 96.0) {
		op.env = 96.0;
		op.st = egstage::OFF;
	};
};

// One operator's output for this sample (pm: phase modulation, cycles).
fn operator(o: *opl, slot: size, fnum: u16, block: u8, pm: f64, am: f64,
	vib: f64) f64 = {
	const op = &o.ops[slot];
	const r20 = o.sregs[0x20 + slot], r40 = o.sregs[0x40 + slot];
	let freq = fnum: f64 * OPL_CLOCK / math::powf64(2.0, (20 - block): f64) *
		MULT[r20 & 0x0F];
	if (r20 & 0x40 != 0) freq *= vib;
	op.phase += freq / RATE;
	op.phase -= math::floorf64(op.phase);
	envelope(o, op, slot, fnum, block);
	if (op.st == egstage::OFF) return 0.0;
	// Total level, key scale level and tremolo on top of the envelope.
	let att = op.env + (r40 & 0x3F): f64 * 0.75;
	const ksl = r40 >> 6;
	if (ksl != 0) {
		let k = KSL_DB[fnum >> 6] - 3.0 * (7 - block): f64;
		if (k > 0.0) att += k * (switch (ksl) {
		case 1 => yield 1.0;
		case 2 => yield 0.5;
		case => yield 2.0;
		});
	};
	if (r20 & 0x80 != 0) att += am;
	if (att >= 127.0) return 0.0;
	return wave(o, o.sregs[0xE0 + slot], op.phase + pm) * AMP[(att * 8.0): size];
};

// The next sample of all nine channels (about -1..1).
fn opl_sample(o: *opl) f64 = {
	if (!o.ready) return 0.0;
	o.lfo += 1.0 / RATE;
	const bd = o.sregs[0xBD];
	// Tremolo: 3.7 Hz, 1 or 4.8 dB. Vibrato: 6.1 Hz, 7 or 14 cents.
	const tri = math::absf64(2.0 * (o.lfo * 3.7 - math::floorf64(o.lfo * 3.7)) - 1.0);
	const am = (if (bd & 0x80 != 0) 4.8 else 1.0) * tri;
	const cents = (if (bd & 0x40 != 0) 14.0 else 7.0) *
		math::sinf64(2.0 * math::PI * 6.1 * o.lfo);
	const vib = math::powf64(2.0, cents / 1200.0);
	// Noise for the drums (23-bit LFSR).
	const bit = ((o.noise >> 22) ^ (o.noise >> 8)) & 1;
	o.noise = (o.noise << 1 | bit) & 0x7FFFFF;
	const noise = if (o.noise & 1 != 0) 1.0 else -1.0;

	const rhythm = bd & 0x20 != 0;
	let sum = 0.0;
	for (let c = 0z; c < 9; c += 1) {
		if (rhythm && c >= 7) break;
		const fnum = o.sregs[0xA0 + c]: u16 | (o.sregs[0xB0 + c] & 3): u16 << 8;
		const block = (o.sregs[0xB0 + c] >> 2) & 7;
		const c0 = o.sregs[0xC0 + c];
		const (s1, s2) = slots(c);
		const op1 = &o.ops[s1];
		const fb = (c0 >> 1) & 7;
		const pm1 = if (fb == 0) 0.0
			else (op1.out1 + op1.out2) * math::powf64(2.0, fb: f64 - 7.0);
		const a = operator(o, s1, fnum, block, pm1, am, vib);
		op1.out2 = op1.out1;
		op1.out1 = a;
		const out = if (c0 & 1 == 0) {
			yield operator(o, s2, fnum, block, a * 4.0, am, vib);
		} else {
			yield a + operator(o, s2, fnum, block, 0.0, am, vib);
		};
		sum += if (rhythm && c == 6) out * 2.0 else out;
	};
	if (rhythm) {
		// Channels 7 and 8 become hi-hat, snare, tom-tom and cymbal.
		const f7 = o.sregs[0xA7]: u16 | (o.sregs[0xB7] & 3): u16 << 8;
		const b7 = (o.sregs[0xB7] >> 2) & 7;
		const f8 = o.sregs[0xA8]: u16 | (o.sregs[0xB8] & 3): u16 << 8;
		const b8 = (o.sregs[0xB8] >> 2) & 7;
		const hh = operator(o, 17, f7, b7, 0.0, am, vib);
		const sd = operator(o, 20, f7, b7, 0.0, am, vib);
		const tt = operator(o, 18, f8, b8, 0.0, am, vib);
		const cy = operator(o, 21, f8, b8, 0.0, am, vib);
		// The noisy ones: keep the envelope, swap the tone for noise.
		sum += 2.0 * (tt + math::absf64(hh) * noise * 0.7 +
			sd * 0.5 + math::absf64(sd) * noise * 0.5 +
			(if (o.ops[21].phase < 0.5) 1.0 else -1.0) * math::absf64(cy) * 0.6);
	};
	return sum * 0.25;
};
