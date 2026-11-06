// Shifu — arithmetic, logic, shifts, multiply/divide and BCD, with the
// flags the 8088 really produces.

fn mask_of(w: bool) u32 = if (w) 0xFFFF else 0xFF;
fn sign_of(w: bool) u32 = if (w) 0x8000 else 0x80;

fn parity(v: u32) bool = {
	let b = v & 0xFF;
	b ^= b >> 4;
	b ^= b >> 2;
	b ^= b >> 1;
	return b & 1 == 0;
};

// Sets SF, ZF and PF from a result.
fn szp(c: *cpu, r: u32, w: bool) void = {
	const r = r & mask_of(w);
	setf(c, ZF, r == 0);
	setf(c, SF, r & sign_of(w) != 0);
	setf(c, PF, parity(r));
};

fn add(c: *cpu, a: u32, b: u32, cin: u32, w: bool) u32 = {
	const r = a + b + cin;
	const m = mask_of(w);
	setf(c, CF, r > m);
	setf(c, OF, (a ^ r) & (b ^ r) & sign_of(w) != 0);
	setf(c, AF, (a ^ b ^ r) & 0x10 != 0);
	szp(c, r, w);
	return r & m;
};

fn sub(c: *cpu, a: u32, b: u32, bin: u32, w: bool) u32 = {
	const r = (a - b - bin) & mask_of(w);
	setf(c, CF, b + bin > a);
	setf(c, OF, (a ^ b) & (a ^ r) & sign_of(w) != 0);
	setf(c, AF, (a ^ b ^ r) & 0x10 != 0);
	szp(c, r, w);
	return r;
};

fn logic(c: *cpu, r: u32, w: bool) u32 = {
	setf(c, CF, false);
	setf(c, OF, false);
	setf(c, AF, false);
	szp(c, r, w);
	return r & mask_of(w);
};

// The eight classic ALU operations, numbered as in the opcode map:
// ADD OR ADC SBB AND SUB XOR CMP.
fn alu(c: *cpu, op: u8, a: u16, b: u16, w: bool) u16 = {
	const a = a: u32, b = b: u32;
	const carry: u32 = if (flag(c, CF)) 1 else 0;
	let r = 0u32;
	switch (op) {
	case 0 => r = add(c, a, b, 0, w);
	case 1 => r = logic(c, a | b, w);
	case 2 => r = add(c, a, b, carry, w);
	case 3 => r = sub(c, a, b, carry, w);
	case 4 => r = logic(c, a & b, w);
	case 5, 7 => r = sub(c, a, b, 0, w);
	case 6 => r = logic(c, a ^ b, w);
	case => abort();
	};
	return r: u16;
};

// INC and DEC leave CF alone.
fn incdec(c: *cpu, v: u16, dec: bool, w: bool) u16 = {
	const cf = flag(c, CF);
	const r = if (dec) sub(c, v, 1, 0, w) else add(c, v, 1, 0, w);
	setf(c, CF, cf);
	return r: u16;
};

// Shifts and rotates (group 2). The 8086 does not mask the count, and it
// works one bit at a time, so OF comes from the last single-bit step.
fn shift(c: *cpu, op: size, v: u16, count: u8, w: bool) u16 = {
	if (count == 0) return v;
	const m = mask_of(w), s = sign_of(w);
	let v = v: u32;
	for (let i = 0u8; i < count; i += 1) {
		switch (op) {
		case 0 => // ROL
			const cf = v & s != 0;
			v = ((v << 1) | (if (cf) 1u32 else 0u32)) & m;
			setf(c, CF, cf);
			setf(c, OF, (v & s != 0) != cf);
		case 1 => // ROR
			const cf = v & 1 != 0;
			v = (v >> 1) | (if (cf) s else 0u32);
			setf(c, CF, cf);
			setf(c, OF, (v & s != 0) != (v & (s >> 1) != 0));
		case 2 => // RCL
			const old: u32 = if (flag(c, CF)) 1 else 0;
			const cf = v & s != 0;
			v = ((v << 1) | old) & m;
			setf(c, CF, cf);
			setf(c, OF, (v & s != 0) != cf);
		case 3 => // RCR
			const old = flag(c, CF);
			setf(c, CF, v & 1 != 0);
			v = (v >> 1) | (if (old) s else 0u32);
			setf(c, OF, (v & s != 0) != (v & (s >> 1) != 0));
		case 4 => // SHL
			const cf = v & s != 0;
			v = (v << 1) & m;
			setf(c, CF, cf);
			setf(c, OF, (v & s != 0) != cf);
		case 5 => // SHR
			setf(c, OF, v & s != 0);
			setf(c, CF, v & 1 != 0);
			v >>= 1;
		case 6 => // SETMO (undocumented): all ones
			v = m;
			setf(c, CF, false);
			setf(c, OF, false);
		case 7 => // SAR
			setf(c, CF, v & 1 != 0);
			v = (v >> 1) | (v & s);
			setf(c, OF, false);
		case => abort();
		};
	};
	if (op >= 4) {
		szp(c, v, w);
		setf(c, AF, false);
	};
	return v: u16;
};

// Divide error: interrupt 0. On the 8088 the return address is the next
// instruction.
fn div_error(c: *cpu) void = interrupt(c, 0);

// Group 3: MUL, IMUL, DIV, IDIV on AL/AX (and AH/DX).
fn muldiv8(c: *cpu, op: size, v: u8) void = {
	switch (op) {
	case 4 => // MUL
		const r = (c.r[AX] & 0xFF) * v: u16;
		c.r[AX] = r;
		setf(c, CF, r & 0xFF00 != 0);
		setf(c, OF, r & 0xFF00 != 0);
		szp(c, r: u32 >> 8, false);
	case 5 => // IMUL
		const r = (c.r[AX]: u8: i8: i16) * (v: i8: i16);
		c.r[AX] = r: u16;
		const big = r != (r: i8: i16);
		setf(c, CF, big);
		setf(c, OF, big);
		szp(c, r: u16: u32 >> 8, false);
	case 6 => // DIV
		if (v == 0) return div_error(c);
		const q = c.r[AX] / v: u16;
		if (q > 0xFF) return div_error(c);
		const rem = c.r[AX] % v: u16;
		c.r[AX] = rem << 8 | q;
	case 7 => // IDIV
		if (v == 0) return div_error(c);
		const a = c.r[AX]: i16: i32, b = v: i8: i32;
		let q = a / b;
		const rem = a % b;
		if (c.rep != 0) q = -q; // REP prefix flips the quotient (8088 quirk)
		if (q > 127 || q < -127) return div_error(c);
		c.r[AX] = (rem: u8: u16) << 8 | (q: u8: u16);
	case => abort();
	};
};

fn muldiv16(c: *cpu, op: size, v: u16) void = {
	switch (op) {
	case 4 => // MUL
		const r = c.r[AX]: u32 * v: u32;
		c.r[AX] = r: u16;
		c.r[DX] = (r >> 16): u16;
		setf(c, CF, c.r[DX] != 0);
		setf(c, OF, c.r[DX] != 0);
		szp(c, c.r[DX], true);
	case 5 => // IMUL
		const r = c.r[AX]: i16: i32 * v: i16: i32;
		c.r[AX] = r: u16;
		c.r[DX] = (r >> 16): u16;
		const big = r != (r: i16: i32);
		setf(c, CF, big);
		setf(c, OF, big);
		szp(c, c.r[DX], true);
	case 6 => // DIV
		if (v == 0) return div_error(c);
		const a = c.r[DX]: u32 << 16 | c.r[AX]: u32;
		const q = a / v: u32;
		if (q > 0xFFFF) return div_error(c);
		c.r[AX] = q: u16;
		c.r[DX] = (a % v: u32): u16;
	case 7 => // IDIV
		if (v == 0) return div_error(c);
		const a = (c.r[DX]: u32 << 16 | c.r[AX]: u32): i32: i64;
		const b = v: i16: i64;
		let q = a / b;
		const rem = a % b;
		if (c.rep != 0) q = -q;
		if (q > 32767 || q < -32767) return div_error(c);
		c.r[AX] = q: u16;
		c.r[DX] = rem: u16;
	case => abort();
	};
};

// ---- BCD adjustments ----

fn daa(c: *cpu) void = {
	const al = get8(c, 0);
	const cf = flag(c, CF), af = flag(c, AF);
	const hi: u8 = if (af) 0x9F else 0x99;
	let r = al;
	if (al & 0x0F > 9 || af) {
		r += 6;
		setf(c, AF, true);
	} else {
		setf(c, AF, false);
	};
	if (al > hi || cf) {
		r += 0x60;
		setf(c, CF, true);
	} else {
		setf(c, CF, false);
	};
	set8(c, 0, r);
	szp(c, r, false);
};

fn das(c: *cpu) void = {
	const al = get8(c, 0);
	const cf = flag(c, CF), af = flag(c, AF);
	const hi: u8 = if (af) 0x9F else 0x99;
	let r = al;
	if (al & 0x0F > 9 || af) {
		r -= 6;
		setf(c, AF, true);
	} else {
		setf(c, AF, false);
	};
	if (al > hi || cf) {
		r -= 0x60;
		setf(c, CF, true);
	} else {
		setf(c, CF, false);
	};
	set8(c, 0, r);
	szp(c, r, false);
};

// AAA/AAS: the 8086 adds 1 to AH on its own (no carry from AL into AH).
fn aaa(c: *cpu, subtract: bool) void = {
	let al = get8(c, 0), ah = get8(c, 4);
	if (al & 0x0F > 9 || flag(c, AF)) {
		if (subtract) {
			al -= 6;
			ah -= 1;
		} else {
			al += 6;
			ah += 1;
		};
		setf(c, AF, true);
		setf(c, CF, true);
	} else {
		setf(c, AF, false);
		setf(c, CF, false);
	};
	szp(c, al, false);
	set8(c, 0, al & 0x0F);
	set8(c, 4, ah);
};

fn aam(c: *cpu, base: u8) void = {
	if (base == 0) {
		// The real chip leaves the flags as for a zero result.
		szp(c, 0, false);
		return div_error(c);
	};
	const al = get8(c, 0);
	set8(c, 4, al / base);
	set8(c, 0, al % base);
	szp(c, al % base, false);
	setf(c, CF, false);
	setf(c, OF, false);
	setf(c, AF, false);
};

fn aad(c: *cpu, base: u8) void = {
	const al = get8(c, 0), ah = get8(c, 4);
	const r = add(c, al, ah * base, 0, false);
	c.r[AX] = r: u8: u16;
};
