// Shifu — the 387 maths coprocessor that sits beside the 386: eight
// floating-point registers used as a stack, the control word (rounding,
// precision), the status word (condition codes C0-C3, the stack top) and
// the instructions behind the escape opcodes D8h-DFh.
//
// Values are kept as f64, not the chip's 80-bit format: games use the FPU
// for single and double precision, and the difference doesn't show.
// Exceptions are always masked (as programs leave them): an invalid
// operation gives the "indefinite" NaN, a division by zero infinity.

use math;

def FC0: u16 = 0x0100;
def FC1: u16 = 0x0200;
def FC2: u16 = 0x0400;
def FC3: u16 = 0x4000;
def FCC: u16 = FC0 | FC1 | FC2 | FC3;

export type fpu = struct {
	st: [8]f64,     // by physical register
	top: u8,
	empty: u8,      // a bit per physical register
	cw: u16,
	sw: u16,        // without TOP (bits 11-13)
};

export fn fpu_reset(f: *fpu) void = {
	f.top = 0;
	f.empty = 0xFF;
	f.cw = 0x037F;
	f.sw = 0;
};

fn fsw(f: *fpu) u16 = (f.sw & ~0x3800u16) | (f.top: u16 << 11);

fn phys(f: *fpu, i: u8) u8 = (f.top + i) & 7;

fn st(f: *fpu, i: u8) f64 = {
	const p = phys(f, i);
	if (f.empty & (1 << p) != 0) {
		f.sw |= 0x41; // stack fault, invalid
		return math::f64frombits(0xFFF8000000000000);
	};
	return f.st[p];
};

fn setst(f: *fpu, i: u8, v: f64) void = {
	const p = phys(f, i);
	f.st[p] = v;
	f.empty &= ~(1u8 << p);
};

fn fpush(f: *fpu, v: f64) void = {
	f.top = (f.top - 1) & 7;
	if (f.empty & (1 << f.top) == 0) f.sw |= 0x241; // overflow
	f.st[f.top] = v;
	f.empty &= ~(1u8 << f.top);
};

fn fpop(f: *fpu) void = {
	f.empty |= 1u8 << f.top;
	f.top = (f.top + 1) & 7;
};

fn indefinite() f64 = math::f64frombits(0xFFF8000000000000);

// ---- Conversions ----

// Rounds as the control word says.
fn fround(f: *fpu, x: f64) f64 = {
	if (math::isnan(x) || math::isinf(x)) return x;
	switch ((f.cw >> 10) & 3) {
	case 1 => return math::floorf64(x);
	case 2 => return math::ceilf64(x);
	case 3 => return math::truncf64(x);
	case =>
		// To nearest, ties to even.
		const fl = math::floorf64(x);
		const d = x - fl;
		if (d < 0.5) return fl;
		if (d > 0.5) return fl + 1.0;
		return if (math::modf64(fl, 2.0) == 0.0) fl else fl + 1.0;
	};
};

// An integer of n bytes, or the integer indefinite (the smallest one) when
// it doesn't fit.
fn to_int(f: *fpu, x: f64, n: u32) u64 = {
	const r = fround(f, x);
	const lim = (1u64 << (n * 8 - 1)): f64;
	if (math::isnan(r) || r >= lim || r < -lim) {
		f.sw |= 0x01;
		return 1u64 << (n * 8 - 1);
	};
	return r: i64: u64;
};

fn from_int(v: u64, n: u32) f64 = switch (n) {
case 2 => yield v: u16: i16: f64;
case 4 => yield v: u32: i32: f64;
case => yield v: i64: f64;
};

fn f80_to_f64(lo: u64, hi: u16) f64 = {
	const neg = hi & 0x8000 != 0;
	const e = hi & 0x7FFF;
	let v = 0.0f64;
	if (e == 0x7FFF) {
		v = if (lo << 1 == 0) math::f64frombits(0x7FF0000000000000)
			else math::f64frombits(0x7FF8000000000000);
	} else if (lo != 0) {
		v = math::ldexpf64(lo: f64, e: i64 - 16383 - 63);
	};
	return if (neg) -v else v;
};

fn f64_to_f80(x: f64) (u64, u16) = {
	const bits = math::f64bits(x);
	const sign = if (bits >> 63 != 0) 0x8000u16 else 0u16;
	if (math::isnan(x)) return (0xC000000000000000, sign | 0x7FFF);
	if (math::isinf(x)) return (0x8000000000000000, sign | 0x7FFF);
	if (x == 0.0) return (0, sign);
	const (m, e) = math::frexpf64(math::absf64(x)); // m in [0.5, 1)
	const mant = math::ldexpf64(m, 64): u64;
	return (mant, sign | (e - 1 + 16383): u64: u16);
};

// ---- Memory ----

fn fmaddr(c: *cpu, k: u32) u32 = (c.ea + k) & amask_ea(c);

fn fread(c: *cpu, n: u32) u64 = {
	let v = 0u64;
	for (let i = 0u32; i < n; i += 4) {
		const part = if (n - i >= 4) 4u32 else n - i;
		v |= mread(c, c.sreg, fmaddr(c, i), part): u64 << (i * 8): u64;
	};
	return v;
};

fn fwrite(c: *cpu, v: u64, n: u32) void = {
	for (let i = 0u32; i < n; i += 4) {
		const part = if (n - i >= 4) 4u32 else n - i;
		mwrite(c, c.sreg, fmaddr(c, i), (v >> (i * 8): u64): u32, part);
	};
};

fn fread_real(c: *cpu, n: u32) f64 = switch (n) {
case 4 => yield math::f32frombits(fread(c, 4): u32): f64;
case 8 => yield math::f64frombits(fread(c, 8));
case =>
	const lo = fread(c, 8);
	const hi = mread(c, c.sreg, fmaddr(c, 8), 2): u16;
	yield f80_to_f64(lo, hi);
};

fn fwrite_real(c: *cpu, x: f64, n: u32) void = switch (n) {
case 4 => fwrite(c, math::f32bits(x: f32), 4);
case 8 => fwrite(c, math::f64bits(x), 8);
case =>
	const (lo, hi) = f64_to_f80(x);
	fwrite(c, lo, 8);
	mwrite(c, c.sreg, fmaddr(c, 8), hi, 2);
};

// ---- Arithmetic and comparison ----

// The arithmetic group (reg field 0-7): ADD MUL COM COMP SUB SUBR DIV DIVR.
fn farith(f: *fpu, op: size, a: f64, b: f64) f64 = switch (op) {
case 0 => yield a + b;
case 1 => yield a * b;
case 4 => yield a - b;
case 5 => yield b - a;
case 6 =>
	if (b == 0.0 && !math::isnan(a)) f.sw |= 0x04;
	yield a / b;
case 7 =>
	if (a == 0.0 && !math::isnan(b)) f.sw |= 0x04;
	yield b / a;
case => abort();
};

fn fcompare(f: *fpu, a: f64, b: f64) void = {
	f.sw &= ~FCC;
	if (math::isnan(a) || math::isnan(b)) {
		f.sw |= FC0 | FC2 | FC3;
	} else if (a < b) {
		f.sw |= FC0;
	} else if (a == b) {
		f.sw |= FC3;
	};
};

fn fxam(f: *fpu) void = {
	f.sw &= ~FCC;
	const p = phys(f, 0);
	const x = f.st[p];
	if (math::f64bits(x) >> 63 != 0) f.sw |= FC1;
	if (f.empty & (1 << p) != 0) {
		f.sw |= FC3 | FC0;
	} else if (math::isnan(x)) {
		f.sw |= FC0;
	} else if (math::isinf(x)) {
		f.sw |= FC2 | FC0;
	} else if (x == 0.0) {
		f.sw |= FC3;
	} else if (math::issubnormalf64(x)) {
		f.sw |= FC3 | FC2;
	} else {
		f.sw |= FC2;
	};
};

// FPREM (truncating) and FPREM1 (to nearest).
fn fprem(f: *fpu, nearest: bool) void = {
	const a = st(f, 0), b = st(f, 1);
	f.sw &= ~FCC;
	if (math::isnan(a) || math::isnan(b) || math::isinf(a) || b == 0.0) {
		setst(f, 0, indefinite());
		f.sw |= 0x01;
		return;
	};
	const qf = a / b;
	let q = if (nearest) {
		const r = math::floorf64(qf + 0.5);
		yield if (r - qf == 0.5 && math::modf64(r, 2.0) != 0.0) r - 1.0 else r;
	} else math::truncf64(qf);
	setst(f, 0, a - q * b);
	const qi = math::absf64(q): u64;
	if (qi & 1 != 0) f.sw |= FC1;
	if (qi & 2 != 0) f.sw |= FC3;
	if (qi & 4 != 0) f.sw |= FC0;
};

// ---- Environment ----

// The tag word: 2 bits a register (valid, zero, special, empty).
fn ftagword(f: *fpu) u16 = {
	let tw = 0u16;
	for (let p = 0u8; p < 8; p += 1) {
		const x = f.st[p];
		const t: u16 = if (f.empty & (1 << p) != 0) 3
			else if (x == 0.0) 1
			else if (math::isnan(x) || math::isinf(x) ||
				math::issubnormalf64(x)) 2
			else 0;
		tw |= t << (p * 2);
	};
	return tw;
};

fn env_size(c: *cpu) u32 = if (c.o32) 28 else 14;

fn fstenv(c: *cpu) void = {
	const f = &c.fpu;
	const big = c.o32;
	const step = if (big) 4u32 else 2u32;
	const words: [_]u32 = [f.cw, fsw(f), ftagword(f), 0, 0, 0, 0];
	for (let i = 0u32; i < 7; i += 1) {
		mwrite(c, c.sreg, fmaddr(c, i * step), words[i], step);
	};
};

fn fldenv(c: *cpu) void = {
	const f = &c.fpu;
	const step = if (c.o32) 4u32 else 2u32;
	const cw = mread(c, c.sreg, fmaddr(c, 0), 2): u16;
	const sw = mread(c, c.sreg, fmaddr(c, step), 2): u16;
	const tw = mread(c, c.sreg, fmaddr(c, step * 2), 2): u16;
	if (c.fault >= 0) return;
	f.cw = cw;
	f.sw = sw & ~0x3800u16;
	f.top = ((sw >> 11) & 7): u8;
	f.empty = 0;
	for (let p = 0u8; p < 8; p += 1) {
		if ((tw >> (p * 2)) & 3 == 3) f.empty |= 1u8 << p;
	};
};

fn fsave(c: *cpu) void = {
	fstenv(c);
	const base = env_size(c);
	const f = &c.fpu;
	for (let i = 0u8; i < 8; i += 1) {
		const (lo, hi) = f64_to_f80(f.st[phys(f, i)]);
		const at = base + i: u32 * 10;
		mwrite(c, c.sreg, fmaddr(c, at), lo: u32, 4);
		mwrite(c, c.sreg, fmaddr(c, at + 4), (lo >> 32): u32, 4);
		mwrite(c, c.sreg, fmaddr(c, at + 8), hi, 2);
	};
	if (c.fault < 0) fpu_reset(f);
};

fn frstor(c: *cpu) void = {
	fldenv(c);
	const base = env_size(c);
	const f = &c.fpu;
	for (let i = 0u8; i < 8; i += 1) {
		const at = base + i: u32 * 10;
		const lo = mread(c, c.sreg, fmaddr(c, at), 4): u64 |
			mread(c, c.sreg, fmaddr(c, at + 4), 4): u64 << 32;
		const hi = mread(c, c.sreg, fmaddr(c, at + 8), 2): u16;
		f.st[phys(f, i)] = f80_to_f64(lo, hi);
	};
};

// Packed BCD: 18 digits and a sign byte.
fn fbld(c: *cpu) f64 = {
	let v = 0.0f64;
	for (let i = 9u32; i > 0; i -= 1) {
		const b = mread(c, c.sreg, fmaddr(c, i - 1), 1);
		v = v * 100.0 + ((b >> 4) * 10 + (b & 0xF)): f64;
	};
	const s = mread(c, c.sreg, fmaddr(c, 9), 1);
	return if (s & 0x80 != 0) -v else v;
};

fn fbstp(c: *cpu, x: f64) void = {
	const f = &c.fpu;
	let r = fround(f, x);
	const neg = r < 0.0;
	if (neg) r = -r;
	let n = r: u64;
	for (let i = 0u32; i < 9; i += 1) {
		const lo = n % 10;
		n /= 10;
		const hi = n % 10;
		n /= 10;
		mwrite(c, c.sreg, fmaddr(c, i), (hi << 4 | lo): u32, 1);
	};
	mwrite(c, c.sreg, fmaddr(c, 9), if (neg) 0x80 else 0, 1);
};

// ---- The instructions ----

// One escape instruction (the ModR/M byte has been read).
fn fpu_exec(c: *cpu, op: u8) void = {
	if (c.cr0 & 0xC != 0) { // EM or TS: the system emulates it
		raise(c, 7);
		return;
	};
	const f = &c.fpu;
	const g = c.reg, i = c.rm: u8;
	if (c.md != 3) {
		fpu_mem(c, f, op, g);
		return;
	};
	switch (op) {
	case 0xD8 => // ST0 = ST0 op ST(i)
		const a = st(f, 0), b = st(f, i);
		if (g == 2 || g == 3) {
			fcompare(f, a, b);
			if (g == 3) fpop(f);
		} else {
			setst(f, 0, farith(f, g, a, b));
		};
	case 0xD9 => fpu_d9(c, f, g, i);
	case 0xDA =>
		if (g == 5 && i == 1) { // FUCOMPP
			fcompare(f, st(f, 0), st(f, 1));
			fpop(f);
			fpop(f);
		} else raise(c, EX_UD);
	case 0xDB =>
		if (g != 4) return raise(c, EX_UD);
		switch (i) {
		case 0, 1, 4 => void; // FENI, FDISI, FSETPM
		case 2 => f.sw &= ~0x80FFu16; // FCLEX
		case 3 => fpu_reset(f);       // FINIT
		case => raise(c, EX_UD);
		};
	case 0xDC, 0xDE => // ST(i) = ST(i) op ST0 (DE pops)
		if (g == 2 || g == 3) { // FCOM aliases / FCOMPP
			if (op == 0xDE && !(g == 3 && i == 1)) return raise(c, EX_UD);
			fcompare(f, st(f, 0), st(f, i));
			if (op == 0xDE) {
				fpop(f);
				fpop(f);
			} else if (g == 3) fpop(f);
			return;
		};
		const gg = if (g >= 4) g ^ 1 else g;
		setst(f, i, farith(f, gg, st(f, i), st(f, 0)));
		if (op == 0xDE) fpop(f);
	case 0xDD =>
		switch (g) {
		case 0 => f.empty |= 1u8 << phys(f, i); // FFREE
		case 1 => // FXCH alias
			const a = st(f, 0);
			setst(f, 0, st(f, i));
			setst(f, i, a);
		case 2, 3 => // FST, FSTP ST(i)
			setst(f, i, st(f, 0));
			if (g == 3) fpop(f);
		case 4, 5 => // FUCOM, FUCOMP
			fcompare(f, st(f, 0), st(f, i));
			if (g == 5) fpop(f);
		case => raise(c, EX_UD);
		};
	case 0xDF =>
		switch (g) {
		case 4 =>
			if (i != 0) return raise(c, EX_UD);
			c.r[AX] = fsw(f); // FSTSW AX
		case 0 => // FFREEP
			f.empty |= 1u8 << phys(f, i);
			fpop(f);
		case 1 => // FXCH alias
			const a = st(f, 0);
			setst(f, 0, st(f, i));
			setst(f, i, a);
		case 2, 3 => // FSTP aliases
			setst(f, i, st(f, 0));
			fpop(f);
		case => raise(c, EX_UD);
		};
	case => abort();
	};
};

fn fpu_d9(c: *cpu, f: *fpu, g: size, i: u8) void = {
	switch (g) {
	case 0 => fpush(f, st(f, i)); // FLD ST(i)
	case 1 => // FXCH
		const a = st(f, 0);
		setst(f, 0, st(f, i));
		setst(f, i, a);
	case 2 => if (i != 0) raise(c, EX_UD); // FNOP
	case 3 => // FSTP ST(i) alias
		setst(f, i, st(f, 0));
		fpop(f);
	case 4 =>
		switch (i) {
		case 0 => setst(f, 0, -st(f, 0));                // FCHS
		case 1 => setst(f, 0, math::absf64(st(f, 0)));   // FABS
		case 4 => fcompare(f, st(f, 0), 0.0);             // FTST
		case 5 => fxam(f);                                // FXAM
		case => raise(c, EX_UD);
		};
	case 5 =>
		const k: f64 = switch (i) {
		case 0 => yield 1.0;
		case 1 => yield 3.321928094887362347870;  // log2(10)
		case 2 => yield 1.442695040888963407360;  // log2(e)
		case 3 => yield 3.141592653589793238463;  // pi
		case 4 => yield 0.301029995663981195214;  // log10(2)
		case 5 => yield 0.693147180559945309417;  // ln(2)
		case 6 => yield 0.0;
		case => return raise(c, EX_UD);
		};
		fpush(f, k);
	case 6 =>
		switch (i) {
		case 0 => setst(f, 0, math::exp2f64(st(f, 0)) - 1.0); // F2XM1
		case 1 => // FYL2X
			const v = st(f, 1) * math::log2f64(st(f, 0));
			fpop(f);
			setst(f, 0, v);
		case 2 => // FPTAN
			setst(f, 0, math::tanf64(st(f, 0)));
			fpush(f, 1.0);
			f.sw &= ~FC2;
		case 3 => // FPATAN
			const v = math::atan2f64(st(f, 1), st(f, 0));
			fpop(f);
			setst(f, 0, v);
		case 4 => // FXTRACT
			const x = st(f, 0);
			if (x == 0.0) {
				setst(f, 0, -math::f64frombits(0x7FF0000000000000));
				fpush(f, x);
				f.sw |= 0x04;
			} else {
				const (m, e) = math::frexpf64(x);
				setst(f, 0, (e - 1): f64);
				fpush(f, m * 2.0);
			};
		case 5 => fprem(f, true);       // FPREM1
		case 6 => f.top = (f.top - 1) & 7; // FDECSTP
		case 7 => f.top = (f.top + 1) & 7; // FINCSTP
		case => abort();
		};
	case 7 =>
		switch (i) {
		case 0 => fprem(f, false); // FPREM
		case 1 => // FYL2XP1
			const v = st(f, 1) * math::log2f64(st(f, 0) + 1.0);
			fpop(f);
			setst(f, 0, v);
		case 2 => // FSQRT
			const x = st(f, 0);
			if (x < 0.0) f.sw |= 0x01;
			setst(f, 0, math::sqrtf64(x));
		case 3 => // FSINCOS
			const x = st(f, 0);
			setst(f, 0, math::sinf64(x));
			fpush(f, math::cosf64(x));
			f.sw &= ~FC2;
		case 4 => setst(f, 0, fround(f, st(f, 0))); // FRNDINT
		case 5 => // FSCALE
			const s = math::truncf64(st(f, 1));
			const n = if (s > 100000.0) 100000i64
				else if (s < -100000.0) -100000i64
				else s: i64;
			setst(f, 0, math::ldexpf64(st(f, 0), n));
		case 6 => // FSIN
			setst(f, 0, math::sinf64(st(f, 0)));
			f.sw &= ~FC2;
		case 7 => // FCOS
			setst(f, 0, math::cosf64(st(f, 0)));
			f.sw &= ~FC2;
		case => abort();
		};
	case => abort();
	};
};

// The forms with a memory operand.
fn fpu_mem(c: *cpu, f: *fpu, op: u8, g: size) void = {
	switch (op) {
	case 0xD8, 0xDA, 0xDC, 0xDE => // arithmetic with m32r, m32i, m64r, m16i
		const b = switch (op) {
		case 0xD8 => yield fread_real(c, 4);
		case 0xDA => yield from_int(fread(c, 4), 4);
		case 0xDC => yield fread_real(c, 8);
		case => yield from_int(fread(c, 2), 2);
		};
		if (c.fault >= 0) return;
		const a = st(f, 0);
		if (g == 2 || g == 3) {
			fcompare(f, a, b);
			if (g == 3) fpop(f);
		} else {
			setst(f, 0, farith(f, g, a, b));
		};
	case 0xD9 =>
		switch (g) {
		case 0 => // FLD m32
			const v = fread_real(c, 4);
			if (c.fault < 0) fpush(f, v);
		case 2, 3 =>
			fwrite_real(c, st(f, 0), 4);
			if (g == 3 && c.fault < 0) fpop(f);
		case 4 => fldenv(c);
		case 5 => // FLDCW
			const v = mread(c, c.sreg, c.ea, 2);
			if (c.fault < 0) f.cw = v: u16;
		case 6 => fstenv(c);
		case 7 => mwrite(c, c.sreg, c.ea, f.cw, 2); // FSTCW
		case => raise(c, EX_UD);
		};
	case 0xDB =>
		switch (g) {
		case 0 => // FILD m32
			const v = fread(c, 4);
			if (c.fault < 0) fpush(f, from_int(v, 4));
		case 2, 3 => // FIST, FISTP m32
			fwrite(c, to_int(f, st(f, 0), 4), 4);
			if (g == 3 && c.fault < 0) fpop(f);
		case 5 => // FLD m80
			const v = fread_real(c, 10);
			if (c.fault < 0) fpush(f, v);
		case 7 => // FSTP m80
			fwrite_real(c, st(f, 0), 10);
			if (c.fault < 0) fpop(f);
		case => raise(c, EX_UD);
		};
	case 0xDD =>
		switch (g) {
		case 0 => // FLD m64
			const v = fread_real(c, 8);
			if (c.fault < 0) fpush(f, v);
		case 2, 3 =>
			fwrite_real(c, st(f, 0), 8);
			if (g == 3 && c.fault < 0) fpop(f);
		case 4 => frstor(c);
		case 6 => fsave(c);
		case 7 => mwrite(c, c.sreg, c.ea, fsw(f), 2); // FSTSW m16
		case => raise(c, EX_UD);
		};
	case 0xDF =>
		switch (g) {
		case 0 => // FILD m16
			const v = fread(c, 2);
			if (c.fault < 0) fpush(f, from_int(v, 2));
		case 2, 3 =>
			fwrite(c, to_int(f, st(f, 0), 2), 2);
			if (g == 3 && c.fault < 0) fpop(f);
		case 4 => // FBLD
			const v = fbld(c);
			if (c.fault < 0) fpush(f, v);
		case 5 => // FILD m64
			const v = fread(c, 8);
			if (c.fault < 0) fpush(f, from_int(v, 8));
		case 6 => // FBSTP
			fbstp(c, st(f, 0));
			if (c.fault < 0) fpop(f);
		case 7 => // FISTP m64
			fwrite(c, to_int(f, st(f, 0), 8), 8);
			if (c.fault < 0) fpop(f);
		case => raise(c, EX_UD);
		};
	case => abort();
	};
};
