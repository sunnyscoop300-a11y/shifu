use fmt;
// Shifu — the 80386 (protected mode and paging: pmode.ha): 32-bit registers and operands (66h),
// 32-bit addressing with SIB bytes (67h), FS and GS, the 186, 286 and 386
// instructions, and the exceptions a 386 raises: invalid opcode (6),
// segment limit (13, or 12 on the stack), divide error (0) and BOUND (5).
// An instruction that faults is undone and the exception taken with the
// faulting instruction's address, as the real chip does.

// Exception numbers.
def EX_DE: u8 = 0;
def EX_BR: u8 = 5;
def EX_UD: u8 = 6;
def EX_SS: u8 = 12;
def EX_GP: u8 = 13;

// (Arithmetic, not a switch: switches are chains of comparisons.)
fn mask(sz: u32) u32 = 0xFFFFFFFFu32 >> ((32 - sz * 8) & 31): u8;

fn sign(sz: u32) u32 = 1u32 << ((sz * 8 - 1) & 31): u8;

// Sign-extends v of size sz to 32 bits.
fn sext(v: u32, sz: u32) u32 = switch (sz) {
case 1 => yield v: u8: i8: i32: u32;
case 2 => yield v: u16: i16: i32: u32;
case => yield v;
};

// The operand size of the current instruction, in bytes.
fn osz(c: *cpu) u32 = if (c.o32) 4 else 2;

// ---- Registers ----

export fn get32(c: *cpu, r: size) u32 = c.r[r]: u32 | c.rh[r]: u32 << 16;

export fn set32(c: *cpu, r: size, v: u32) void = {
	c.r[r] = v: u16;
	c.rh[r] = (v >> 16): u16;
};

// Register r of size sz (1: AL..BH, 2: AX..DI, 4: EAX..EDI).
fn reg(c: *cpu, r: size, sz: u32) u32 = switch (sz) {
case 1 => yield get8(c, r);
case 2 => yield c.r[r];
case => yield get32(c, r);
};

fn setreg(c: *cpu, r: size, v: u32, sz: u32) void = switch (sz) {
case 1 => set8(c, r, v: u8);
case 2 => c.r[r] = v: u16;
case => set32(c, r, v);
};

export fn eflags(c: *cpu) u32 = {
	fsync(c);
	return c.flags: u32 | c.flagsh: u32 << 16;
};

// ---- Exceptions ----

// Notes an exception; the first one counts. The instruction carries on
// harmlessly (reads give 0, writes are dropped) and is undone afterwards.
fn raise(c: *cpu, n: u8) void = {
	if (c.fault < 0) {
		c.fault = n: int;
		c.fault_code = 0;
	};
};

fn faulted(c: *cpu) bool = c.fault >= 0;

// Memory, instruction fetches and the stack: see pmode.ha.

// ---- ModR/M and SIB ----

// The default segment and override for a memory operand.
fn useg(c: *cpu, default: size) size =
	if (c.seg_ovr >= 0) c.seg_ovr: size else default;

fn modrm386(c: *cpu) void = {
	const b = ifetch8(c);
	c.md = (b >> 6): size;
	c.reg = ((b >> 3) & 7): size;
	c.rm = (b & 7): size;
	if (c.md == 3) return;
	let seg = DS;
	let off = 0u32;
	if (!c.a32) {
		let o = 0u16;
		switch (c.rm) {
		case 0 => o = c.r[BX] + c.r[SI];
		case 1 => o = c.r[BX] + c.r[DI];
		case 2 => o = c.r[BP] + c.r[SI]; seg = SS;
		case 3 => o = c.r[BP] + c.r[DI]; seg = SS;
		case 4 => o = c.r[SI];
		case 5 => o = c.r[DI];
		case 6 =>
			if (c.md == 0) {
				o = ifetch(c, 2): u16;
			} else {
				o = c.r[BP];
				seg = SS;
			};
		case 7 => o = c.r[BX];
		case => abort();
		};
		if (c.md == 1) o += ifetch8(c): i8: i16: u16;
		if (c.md == 2) o += ifetch(c, 2): u16;
		off = o;
	} else {
		if (c.rm == 4) {
			const sib = ifetch8(c);
			const scale = (sib >> 6): u8, idx = ((sib >> 3) & 7): size,
				base = (sib & 7): size;
			if (base == 5 && c.md == 0) {
				off = ifetch(c, 4);
			} else {
				off = get32(c, base);
				if (base == ESP_ || base == EBP_) seg = SS;
			};
			if (idx != 4) {
				off += get32(c, idx) << scale;
			} else if (scale != 0 && !(base == 5 && c.md == 0)) {
				// No index but a scale: the 386 scales the base.
				off = get32(c, base) << scale;
			};
		} else if (c.rm == 5 && c.md == 0) {
			off = ifetch(c, 4);
		} else {
			off = get32(c, c.rm);
			if (c.rm == EBP_) seg = SS;
		};
		if (c.md == 1) off += ifetch8(c): i8: i32: u32;
		if (c.md == 2) off += ifetch(c, 4);
	};
	c.ea = off;
	c.sreg = useg(c, seg);
};

def ESP_: size = 4;
def EBP_: size = 5;

fn rm_get(c: *cpu, sz: u32) u32 = {
	if (c.md == 3) return reg(c, c.rm, sz);
	return mread(c, c.sreg, c.ea, sz);
};

fn rm_set(c: *cpu, v: u32, sz: u32) void = {
	if (c.md == 3) {
		setreg(c, c.rm, v, sz);
	} else {
		mwrite(c, c.sreg, c.ea, v, sz);
	};
};

// ---- The ALU, for 8, 16 and 32 bits ----

// Parity of each byte value: PF set for an even number of 1 bits.
const PARITY: [256]u16 = [
	4, 0, 0, 4, 0, 4, 4, 0, 0, 4, 4, 0, 4, 0, 0, 4, 0, 4, 4, 0, 4, 0, 0, 4, 4, 0, 0, 4, 0, 4, 4, 0,
	0, 4, 4, 0, 4, 0, 0, 4, 4, 0, 0, 4, 0, 4, 4, 0, 4, 0, 0, 4, 0, 4, 4, 0, 0, 4, 4, 0, 4, 0, 0, 4,
	0, 4, 4, 0, 4, 0, 0, 4, 4, 0, 0, 4, 0, 4, 4, 0, 4, 0, 0, 4, 0, 4, 4, 0, 0, 4, 4, 0, 4, 0, 0, 4,
	4, 0, 0, 4, 0, 4, 4, 0, 0, 4, 4, 0, 4, 0, 0, 4, 0, 4, 4, 0, 4, 0, 0, 4, 4, 0, 0, 4, 0, 4, 4, 0,
	0, 4, 4, 0, 4, 0, 0, 4, 4, 0, 0, 4, 0, 4, 4, 0, 4, 0, 0, 4, 0, 4, 4, 0, 0, 4, 4, 0, 4, 0, 0, 4,
	4, 0, 0, 4, 0, 4, 4, 0, 0, 4, 4, 0, 4, 0, 0, 4, 0, 4, 4, 0, 4, 0, 0, 4, 4, 0, 0, 4, 0, 4, 4, 0,
	4, 0, 0, 4, 0, 4, 4, 0, 0, 4, 4, 0, 4, 0, 0, 4, 0, 4, 4, 0, 4, 0, 0, 4, 4, 0, 0, 4, 0, 4, 4, 0,
	0, 4, 4, 0, 4, 0, 0, 4, 4, 0, 0, 4, 0, 4, 4, 0, 4, 0, 0, 4, 0, 4, 4, 0, 0, 4, 4, 0, 4, 0, 0, 4,
];

// SF, ZF and PF of a result, as flag bits.
fn szpbits(r: u32, sz: u32) u16 = {
	const r = r & mask(sz);
	return PARITY[r & 0xFF] | (if (r == 0) ZF else 0u16) |
		(if (r & sign(sz) != 0) SF else 0u16);
};

def ARITH: u16 = 0x08D5; // OF SF ZF AF PF CF

// Kinds of pending flag computations (cpu.lz_op).
def LZ_ADD: u32 = 1;   // a + b + c
def LZ_SUB: u32 = 2;   // a - b - c
def LZ_LOGIC: u32 = 3; // AND, OR, XOR, TEST: CF = OF = AF = 0
def LZ_INC: u32 = 4;   // a + 1, CF kept (in c)
def LZ_DEC: u32 = 5;   // a - 1, CF kept (in c)

// Works out the arithmetic flags of the last ALU operation, if they're
// still pending (lazy flags: most are never read).
export fn fsync(c: *cpu) void = {
	const op = c.lz_op;
	if (op == 0) return;
	c.lz_op = 0;
	const a = c.lz_a, b = c.lz_b, k = c.lz_c, r = c.lz_res, sz = c.lz_sz;
	const sg = sign(sz);
	let f = szpbits(r, sz);
	switch (op) {
	case LZ_ADD, LZ_INC =>
		f |= (a ^ b ^ r): u16 & AF;
		if ((a ^ r) & (b ^ r) & sg != 0) f |= OF;
		if (op == LZ_INC) {
			if (k != 0) f |= CF;
		} else if (a: u64 + b: u64 + k: u64 > mask(sz): u64) f |= CF;
	case LZ_SUB, LZ_DEC =>
		f |= (a ^ b ^ r): u16 & AF;
		if ((a ^ b) & (a ^ r) & sg != 0) f |= OF;
		if (op == LZ_DEC) {
			if (k != 0) f |= CF;
		} else if (b: u64 + k: u64 > a: u64) f |= CF;
	case => void; // LZ_LOGIC
	};
	c.flags = (c.flags & ~ARITH) | f;
};

// CF alone, without working out the rest.
fn cf_now(c: *cpu) bool = switch (c.lz_op) {
case 0 => yield c.flags & CF != 0;
case LZ_ADD => yield c.lz_a: u64 + c.lz_b: u64 + c.lz_c: u64 > mask(c.lz_sz): u64;
case LZ_SUB => yield c.lz_b: u64 + c.lz_c: u64 > c.lz_a: u64;
case LZ_INC, LZ_DEC => yield c.lz_c != 0;
case => yield false;
};

fn lazy(c: *cpu, op: u32, a: u32, b: u32, k: u32, r: u32, sz: u32) void = {
	c.lz_op = op;
	c.lz_a = a;
	c.lz_b = b;
	c.lz_c = k;
	c.lz_res = r;
	c.lz_sz = sz;
};

fn szp3(c: *cpu, r: u32, sz: u32) void = {
	fsync(c);
	c.flags = (c.flags & ~(SF | ZF | PF)) | szpbits(r, sz);
};

fn add3(c: *cpu, a: u32, b: u32, cin: u32, sz: u32) u32 = {
	const r = (a + b + cin) & mask(sz);
	lazy(c, LZ_ADD, a, b, cin, r, sz);
	return r;
};

fn sub3(c: *cpu, a: u32, b: u32, bin: u32, sz: u32) u32 = {
	const r = (a - b - bin) & mask(sz);
	lazy(c, LZ_SUB, a, b, bin, r, sz);
	return r;
};

fn logic3(c: *cpu, r: u32, sz: u32) u32 = {
	const r = r & mask(sz);
	lazy(c, LZ_LOGIC, 0, 0, 0, r, sz);
	return r;
};

fn alu3(c: *cpu, op: u8, a: u32, b: u32, sz: u32) u32 = {
	switch (op) {
	case 0 => return add3(c, a, b, 0, sz);
	case 5, 7 => return sub3(c, a, b, 0, sz);
	case 4 => return logic3(c, a & b, sz);
	case 1 => return logic3(c, a | b, sz);
	case 6 => return logic3(c, a ^ b, sz);
	case 2 => return add3(c, a, b, if (cf_now(c)) 1 else 0, sz);
	case 3 => return sub3(c, a, b, if (cf_now(c)) 1 else 0, sz);
	case => abort();
	};
};

fn incdec3(c: *cpu, v: u32, dec: bool, sz: u32) u32 = {
	const cf: u32 = if (cf_now(c)) 1 else 0;
	const v = v & mask(sz);
	const r = (if (dec) v - 1 else v + 1) & mask(sz);
	lazy(c, if (dec) LZ_DEC else LZ_INC, v, 1, cf, r, sz);
	return r;
};

// Shifts and rotates: the 386 masks the count to 5 bits.
fn shift3(c: *cpu, op: size, v: u32, count: u32, sz: u32) u32 = {
	const count = count & 0x1F;
	if (count == 0) return v;
	const m = mask(sz), s = sign(sz);
	const bits = sz * 8;
	let v = v & m;
	switch (op) {
	case 0 => // ROL
		const n = count % bits;
		if (n != 0) v = ((v << n: u8) | (v >> (bits - n): u8)) & m;
		setf(c, CF, v & 1 != 0);
		setf(c, OF, (v & s != 0) != (v & 1 != 0));
	case 1 => // ROR
		const n = count % bits;
		if (n != 0) v = ((v >> n: u8) | (v << (bits - n): u8)) & m;
		setf(c, CF, v & s != 0);
		setf(c, OF, (v & s != 0) != (v & (s >> 1) != 0));
	case 2 => // RCL
		const n = count % (bits + 1);
		for (let i = 0u32; i < n; i += 1) {
			const old: u32 = if (flag(c, CF)) 1 else 0;
			setf(c, CF, v & s != 0);
			v = ((v << 1) | old) & m;
		};
		setf(c, OF, (v & s != 0) != flag(c, CF));
	case 3 => // RCR
		const n = count % (bits + 1);
		for (let i = 0u32; i < n; i += 1) {
			const old = flag(c, CF);
			setf(c, CF, v & 1 != 0);
			v = (v >> 1) | (if (old) s else 0u32);
		};
		setf(c, OF, (v & s != 0) != (v & (s >> 1) != 0));
	case 4, 6 => // SHL (6 is an alias)
		// A byte shifted by 16 or 24 gives CF as if by 8.
		const count = if (sz == 1 && count > 8 && count & 7 == 0) 8u32 else count;
		const r = v: u64 << count: u8;
		setf(c, CF, r & (s: u64 << 1) != 0);
		v = r: u32 & m;
		setf(c, OF, (v & s != 0) != flag(c, CF));
		szp3(c, v, sz);
		setf(c, AF, false);
	case 5 => // SHR: OF as for the last single-bit step
		const count = if (sz == 1 && count > 8 && count & 7 == 0) 8u32 else count;
		setf(c, OF, (v: u64 >> (count - 1): u8) & s: u64 != 0);
		setf(c, CF, (v: u64 >> (count - 1): u8) & 1 != 0);
		v = (v: u64 >> count: u8): u32;
		szp3(c, v, sz);
		setf(c, AF, false);
	case 7 => // SAR
		// Shift the sign-extended value as unsigned 64 bits.
		const sv = sext(v, sz): i32: i64: u64;
		setf(c, CF, (sv >> (count - 1): u8) & 1 != 0);
		v = (sv >> count: u8): u32 & m;
		setf(c, OF, false);
		szp3(c, v, sz);
		setf(c, AF, false);
	case => abort();
	};
	return v;
};

// DAA and DAS as the 386 does them (the 8088 differs in when it adds 60h).
fn daa386(c: *cpu, subtract: bool) void = {
	const al = get8(c, 0);
	const cf = flag(c, CF);
	let r = al;
	setf(c, CF, false);
	if (al & 0x0F > 9 || flag(c, AF)) {
		if (subtract) {
			setf(c, CF, cf || al < 6);
			r -= 6;
		} else {
			setf(c, CF, cf || al > 0xF9);
			r += 6;
		};
		setf(c, AF, true);
	} else {
		setf(c, AF, false);
	};
	if (al > 0x99 || cf) {
		r = if (subtract) r - 0x60 else r + 0x60;
		setf(c, CF, true);
	};
	set8(c, 0, r);
	szp3(c, r, 1);
};

// ---- Interrupts ----

fn softint386(c: *cpu, n: u8) void = {
	match (c.int_hook) {
	case null => void;
	case let f: *int_fn =>
		c.ip = c.eip: u16;
		fsync(c);
		if (f(c, n)) {
			c.eip = c.ip;
			return;
		};
	};
	deliver(c, n, c.eip, intkind::SOFT);
};

// ---- Running ----

fn step386(c: *cpu) void = {
	c.in_rep = false;
	c.inhibit = false;
	const trap = c.flags & TF != 0;
	// The registers and pending flags, in case the instruction faults:
	// 72 bytes copied as nine words (a struct copy goes byte by byte).
	const from = &c.r: *[9]u64, to = &c.saved: *[9]u64;
	to[0] = from[0]; to[1] = from[1]; to[2] = from[2];
	to[3] = from[3]; to[4] = from[4]; to[5] = from[5];
	to[6] = from[6]; to[7] = from[7]; to[8] = from[8];
	// EIP can be 10000h after the last instruction in a segment (the
	// next fetch then faults); otherwise it follows IP, which the PC
	// around the CPU may have changed.
	if (c.eip: u16 != c.ip) c.eip = c.ip;
	c.start_eip = c.eip;
	c.start_ip = c.ip;
	if (c.ring_on) {
		c.ring[c.ring_n & 63] = c.s[CS]: u64 << 32 | c.eip;
		c.ring_n += 1;
		if (c.s[CS] != c.last_cs) {
			c.jumps[c.jump_n & 15] = (c.last_cs, c.last_eip, c.s[CS],
				c.eip, c.cr0 & 1 != 0);
			c.jump_n += 1;
			c.last_cs = c.s[CS];
		};
		c.last_eip = c.eip;
	};
	c.cbase = if (c.cr0 & 1 != 0) c.sbase[CS]
		else if (c.stale == 0) c.s[CS]: u32 << 4
		else seg_base(c, CS);
	c.cfast = c.cr0 & 0x80000000 == 0;
	// The fast fetch window: up to 15 bytes, within the code segment's
	// limit, in plain memory (not near the VGA window at A0000h-BFFFFh,
	// not wrapping round the top).
	c.fend = 0;
	if (c.cfast) {
		const e = c.eip;
		const a0 = c.cbase + e;
		if (a0 - 0x9FFF1 > 0x2000F && a0 <= c.amask - 15 && a0 >= c.cbase) {
			const lim = c.slimit[CS];
			if (lim >= e) c.fend = if (lim - e >= 14) e + 15 else lim + 1;
		};
	};
	c.seg_ovr = -1;
	c.rep = 0;
	// The default sizes come from the code segment (32-bit in a 32-bit
	// protected-mode segment); 66h and 67h switch to the other.
	const big = c.sattr[CS] & A_DB != 0;
	c.o32 = big;
	c.a32 = big;
	c.lock = false;
	c.fault = -1;
	c.seg_dirty = false;
	let op = ifetch8(c);
	for (c.fault < 0 && PREFIX[op]) {
		switch (op) {
		case 0x26, 0x2E, 0x36, 0x3E =>
			c.seg_ovr = ((op >> 3) & 3): int;
		case 0x64, 0x65 =>
			c.seg_ovr = (op - 0x60): int;
		case 0x66 => c.o32 = !big;
		case 0x67 => c.a32 = !big;
		case 0xF2, 0xF3 => c.rep = op;
		case 0xF0 => c.lock = true;
		case => break;
		};
		op = ifetch8(c);
	};
	if (c.fault < 0) {
		if (c.lock && !lockable(c, op)) {
			raise(c, EX_UD);
		} else {
			exec386(c, op);
		};
	};
	if (c.fault >= 0) {
		// Undo the instruction and take the exception.
		const from = &c.saved: *[9]u64, to = &c.r: *[9]u64;
		to[0] = from[0]; to[1] = from[1]; to[2] = from[2];
		to[3] = from[3]; to[4] = from[4]; to[5] = from[5];
		to[6] = from[6]; to[7] = from[7]; to[8] = from[8];
		seg_restore(c);
		c.in_rep = false;
		c.inhibit = false;
		c.halted = false;
		exception(c);
	};
	c.seg_dirty = false;
	c.ip = c.eip: u16;
	c.count += 1;
	if (trap && !c.in_rep) {
		deliver(c, 1, c.eip, intkind::EXC);
		c.fault = -1;
		c.seg_dirty = false;
		c.ip = c.eip: u16;
	};
};

// Takes the exception the instruction raised (c.fault). A fault while
// doing so is a double fault; a fault in that shuts the CPU down.
fn exception(c: *cpu) void = {
	let n = c.fault: u8;
	// With SHIFU_DEBUG: the first protection faults and invalid opcodes.
	if (c.ring_on && (n == 6 || n == 12 || n == 13) && c.exc_logged < 20) {
		c.exc_logged += 1;
		fmt::errorf("UNDTAGELSE {:_02X} fejlkode {:_04X} ved {:_04X}:{:_08X} (base {:_08X}) kode:",
			n, c.fault_code, c.s[CS], c.start_eip, c.cbase)!;
		for (let i = 0u32; i < 24; i += 1) {
			fmt::errorf(" {:_02X}", c.mem[(c.cbase + c.start_eip + i) & 0xFFFFFF])!;
		};
		fmt::errorln()!;
		dump(c);
	};
	for (let tries = 0; tries < 3; tries += 1) {
		c.fault = -1;
		c.seg_dirty = false;
		deliver(c, n, c.start_eip, intkind::EXC);
		if (c.fault < 0) {
			c.seg_dirty = false;
			return;
		};
		seg_restore(c);
		const from = &c.saved: *[9]u64, to = &c.r: *[9]u64;
		to[0] = from[0]; to[1] = from[1]; to[2] = from[2];
		to[3] = from[3]; to[4] = from[4]; to[5] = from[5];
		to[6] = from[6]; to[7] = from[7]; to[8] = from[8];
		if (n == EX_DF) break;
		n = EX_DF;
		c.fault_code = 0;
		c.fault = EX_DF: int;
	};
	// Triple fault.
	c.fault = -1;
	c.shutdown = true;
	c.halted = true;
};

// The prefix bytes.
const PREFIX: [256]bool = [
	false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false,
	false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false,
	false, false, false, false, false, false, true, false, false, false, false, false, false, false, true, false,
	false, false, false, false, false, false, true, false, false, false, false, false, false, false, true, false,
	false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false,
	false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false,
	false, false, false, false, true, true, true, true, false, false, false, false, false, false, false, false,
	false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false,
	false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false,
	false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false,
	false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false,
	false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false,
	false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false,
	false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false,
	false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false,
	true, false, true, true, false, false, false, false, false, false, false, false, false, false, false, false,
];

// Which instructions the LOCK prefix may go on: read-modify-write ones
// with a memory operand.
fn lockable(c: *cpu, op: u8) bool = {
	if (c.eip > c.slimit[CS]) return false;
	let m = mread(c, CS, c.eip, 1): u8;
	if (op == 0x0F) {
		const op2 = m;
		if (c.eip + 1 > c.slimit[CS]) return false;
		m = mread(c, CS, c.eip + 1, 1): u8;
		const memop = m >> 6 != 3;
		switch (op2) {
		case 0xAB, 0xB3, 0xBB => return memop;
		case 0xBA => return memop && (m >> 3) & 7 >= 5;
		case => return false;
		};
	};
	const memop = m >> 6 != 3;
	const r = (m >> 3) & 7;
	switch (op) {
	case 0x00, 0x01, 0x08, 0x09, 0x10, 0x11, 0x18, 0x19, 0x20, 0x21,
		0x28, 0x29, 0x30, 0x31, 0x86, 0x87 =>
		return memop;
	case 0x80, 0x81, 0x82, 0x83 => return memop && r != 7;
	case 0xF6, 0xF7 => return memop && (r == 2 || r == 3);
	case 0xFE, 0xFF => return memop && r < 2;
	case => return false;
	};
};

// Jumps within the code segment: past its limit is #GP. A 16-bit
// operand size cuts the target to 16 bits.
fn jump(c: *cpu, target: u32) void = {
	const t = if (c.o32) target else target & 0xFFFF;
	if (t > c.slimit[CS]) {
		gp(c, 0);
		return;
	};
	c.eip = t;
};

// A far jump in real mode (the CS limit stays what it was).
fn far_jump(c: *cpu, seg: u16, off: u32) void = {
	if (off > c.slimit[CS]) {
		raise(c, EX_GP);
		return;
	};
	c.s[CS] = seg;
	c.stale &= ~(1u8 << CS: u8);
	c.eip = off;
};

fn cnt_reg(c: *cpu) u32 = if (c.a32) get32(c, CX) else c.r[CX];
fn set_cnt(c: *cpu, v: u32) void = {
	if (c.a32) set32(c, CX, v) else c.r[CX] = v: u16;
};

fn exec386(c: *cpu, op: u8) void = OPS[op](c, op, osz(c));

type group_fn = fn(c: *cpu, op: u8, sz: u32) void;

// One handler for each opcode: an array lookup instead of a chain of
// comparisons (which is what a switch compiles to).
const OPS: [256]*group_fn = [
	&alu_rm_r, &alu_rm_r, &alu_r_rm, &alu_r_rm,
	&alu_al_imm, &alu_ax_imm, &op0_0, &op0_1,
	&alu_rm_r, &alu_rm_r, &alu_r_rm, &alu_r_rm,
	&alu_al_imm, &alu_ax_imm, &op0_0, &op0_2,
	&alu_rm_r, &alu_rm_r, &alu_r_rm, &alu_r_rm,
	&alu_al_imm, &alu_ax_imm, &op1_0, &op1_1,
	&alu_rm_r, &alu_rm_r, &alu_r_rm, &alu_r_rm,
	&alu_al_imm, &alu_ax_imm, &op1_0, &op1_1,
	&alu_rm_r, &alu_rm_r, &alu_r_rm, &alu_r_rm,
	&alu_al_imm, &alu_ax_imm, &op2_1, &op2_0,
	&alu_rm_r, &alu_rm_r, &alu_r_rm, &alu_r_rm,
	&alu_al_imm, &alu_ax_imm, &op2_1, &op2_0,
	&alu_rm_r, &alu_rm_r, &alu_r_rm, &alu_r_rm,
	&alu_al_imm, &alu_ax_imm, &op3_2, &op3_0,
	&alu_rm_r, &alu_rm_r, &alu_r_rm, &alu_r_rm,
	&alu_al_imm, &alu_ax_imm, &op3_2, &op3_1,
	&op4_0, &op4_0, &op4_0, &op4_0,
	&op4_0, &op4_0, &op4_0, &op4_0,
	&op4_1, &op4_1, &op4_1, &op4_1,
	&op4_1, &op4_1, &op4_1, &op4_1,
	&op5_0, &op5_0, &op5_0, &op5_0,
	&op5_0, &op5_0, &op5_0, &op5_0,
	&op5_1, &op5_1, &op5_1, &op5_1,
	&op5_1, &op5_1, &op5_1, &op5_1,
	&op6_0, &op6_1, &op6_3, &op6_2,
	&op6_8, &op6_8, &op6_8, &op6_8,
	&op6_4, &op6_6, &op6_5, &op6_6,
	&op6_7, &op6_7, &op6_7, &op6_7,
	&op7_0, &op7_0, &op7_0, &op7_0,
	&op7_0, &op7_0, &op7_0, &op7_0,
	&op7_0, &op7_0, &op7_0, &op7_0,
	&op7_0, &op7_0, &op7_0, &op7_0,
	&op8_0, &op8_0, &op8_0, &op8_0,
	&op8_1, &op8_1, &op8_2, &op8_2,
	&op8_3, &op8_3, &op8_4, &op8_4,
	&op8_5, &op8_6, &op8_7, &op8_8,
	&op9_0, &op9_1, &op9_1, &op9_1,
	&op9_1, &op9_1, &op9_1, &op9_1,
	&op9_2, &op9_3, &op9_4, &op9_5,
	&op9_6, &op9_7, &op9_8, &op9_9,
	&opA_0, &opA_0, &opA_0, &opA_0,
	&opA_1, &opA_1, &opA_1, &opA_1,
	&opA_2, &opA_3, &opA_1, &opA_1,
	&opA_1, &opA_1, &opA_1, &opA_1,
	&opB_0, &opB_0, &opB_0, &opB_0,
	&opB_0, &opB_0, &opB_0, &opB_0,
	&opB_1, &opB_1, &opB_1, &opB_1,
	&opB_1, &opB_1, &opB_1, &opB_1,
	&opC_0, &opC_0, &opC_1, &opC_1,
	&opC_2, &opC_2, &opC_3, &opC_3,
	&opC_4, &opC_5, &opC_6, &opC_6,
	&opC_7, &opC_8, &opC_9, &opC_10,
	&opD_0, &opD_0, &opD_0, &opD_0,
	&opD_1, &opD_2, &opD_3, &opD_4,
	&opD_5, &opD_5, &opD_5, &opD_5,
	&opD_5, &opD_5, &opD_5, &opD_5,
	&opE_0, &opE_0, &opE_0, &opE_1,
	&opE_2, &opE_2, &opE_3, &opE_3,
	&opE_4, &opE_5, &opE_6, &opE_7,
	&opE_8, &opE_8, &opE_9, &opE_9,
	&opF_12, &opF_0, &opF_12, &opF_12,
	&opF_1, &opF_2, &opF_3, &opF_3,
	&opF_4, &opF_5, &opF_6, &opF_7,
	&opF_8, &opF_9, &opF_10, &opF_11,
];

// The eight ALU operations (00h-3Fh) in their four common forms.
fn alu_rm_r(c: *cpu, op: u8, sz: u32) void = {
	const s: u32 = if (op & 1 == 0) 1 else sz;
	modrm386(c);
	const a = rm_get(c, s);
	if (c.fault >= 0) return;
	const r = alu3(c, op >> 3, a, reg(c, c.reg, s), s);
	if (op >> 3 != 7) rm_set(c, r, s);
};

fn alu_r_rm(c: *cpu, op: u8, sz: u32) void = {
	const s: u32 = if (op & 1 == 0) 1 else sz;
	modrm386(c);
	const b = rm_get(c, s);
	if (c.fault >= 0) return;
	const r = alu3(c, op >> 3, reg(c, c.reg, s), b, s);
	if (op >> 3 != 7) setreg(c, c.reg, r, s);
};

fn alu_al_imm(c: *cpu, op: u8, sz: u32) void = {
	const b = ifetch8(c);
	if (c.fault >= 0) return;
	const r = alu3(c, op >> 3, get8(c, 0), b, 1);
	if (op >> 3 != 7) set8(c, 0, r: u8);
};

fn alu_ax_imm(c: *cpu, op: u8, sz: u32) void = {
	const b = imm(c, sz);
	if (c.fault >= 0) return;
	const r = alu3(c, op >> 3, reg(c, AX, sz), b, sz);
	if (op >> 3 != 7) setreg(c, AX, r, sz);
};

fn op0_0(c: *cpu, op: u8, sz: u32) void = {
	// PUSH seg
	push386(c, c.s[(op >> 3): size], sz);
};

fn op0_1(c: *cpu, op: u8, sz: u32) void = {
	// POP seg
	const v = pop_seg(c, sz);
	if (c.fault >= 0) return;
	load_seg(c, (op >> 3): size, v);
};

fn op0_2(c: *cpu, op: u8, sz: u32) void = {
	exec0f(c);
};

fn op0_3(c: *cpu, op: u8, sz: u32) void = {
	raise(c, EX_UD);
};

fn op1_0(c: *cpu, op: u8, sz: u32) void = {
	// PUSH seg
	push386(c, c.s[(op >> 3): size], sz);
};

fn op1_1(c: *cpu, op: u8, sz: u32) void = {
	// POP seg
	const v = pop_seg(c, sz);
	if (c.fault >= 0) return;
	load_seg(c, (op >> 3): size, v);
};

fn op1_2(c: *cpu, op: u8, sz: u32) void = {
	raise(c, EX_UD);
};

fn op2_0(c: *cpu, op: u8, sz: u32) void = {
	daa386(c, op == 0x2F);
};

fn op2_1(c: *cpu, op: u8, sz: u32) void = {
	raise(c, EX_UD);
};

fn op3_0(c: *cpu, op: u8, sz: u32) void = {
	// AAA: the 386 adds to AX as a whole
	if (get8(c, 0) & 0x0F > 9 || flag(c, AF)) {
		c.r[AX] += 0x106;
		setf(c, AF, true);
		setf(c, CF, true);
	} else {
		setf(c, AF, false);
		setf(c, CF, false);
	};
	set8(c, 0, get8(c, 0) & 0x0F);
};

fn op3_1(c: *cpu, op: u8, sz: u32) void = {
	// AAS
	if (get8(c, 0) & 0x0F > 9 || flag(c, AF)) {
		c.r[AX] -= 6;
		set8(c, 4, get8(c, 4) - 1);
		setf(c, AF, true);
		setf(c, CF, true);
	} else {
		setf(c, AF, false);
		setf(c, CF, false);
	};
	set8(c, 0, get8(c, 0) & 0x0F);
};

fn op3_2(c: *cpu, op: u8, sz: u32) void = {
	raise(c, EX_UD);
};

fn op4_0(c: *cpu, op: u8, sz: u32) void = {
	// INC r
	const r = (op & 7): size;
	setreg(c, r, incdec3(c, reg(c, r, sz), false, sz), sz);
};

fn op4_1(c: *cpu, op: u8, sz: u32) void = {
	// DEC r
	const r = (op & 7): size;
	setreg(c, r, incdec3(c, reg(c, r, sz), true, sz), sz);
};

fn op4_2(c: *cpu, op: u8, sz: u32) void = {
	raise(c, EX_UD);
};

fn op5_0(c: *cpu, op: u8, sz: u32) void = {
	// PUSH r
	push386(c, reg(c, (op & 7): size, sz), sz); // PUSH SP: the old SP
};

fn op5_1(c: *cpu, op: u8, sz: u32) void = {
	// POP r
	const v = pop386(c, sz);
	if (c.fault < 0) setreg(c, (op & 7): size, v, sz);
};

fn op5_2(c: *cpu, op: u8, sz: u32) void = {
	raise(c, EX_UD);
};

fn op6_0(c: *cpu, op: u8, sz: u32) void = {
	// PUSHA: written from the lowest address up, so the
	// ones below a limit fault still happen
	const sp = reg(c, SP, sz);
	const base = sp_add(c, sp_get(c), -(8 * sz));
	for (let i = 0z; i < 8; i += 1) {
		const r = 7 - i;
		const v = if (r == SP) sp else reg(c, r, sz);
		mwrite(c, SS, sp_add(c, base, i: u32 * sz), v, sz);
	};
	if (c.fault < 0) sp_set(c, base);
};

fn op6_1(c: *cpu, op: u8, sz: u32) void = {
	// POPA (SP is skipped)
	for (let i = 8z; i > 0; i -= 1) {
		const v = pop386(c, sz);
		if (c.fault >= 0) {
			// The registers popped before the fault stay popped.
			const sp = c.saved.r[SP], sph = c.saved.rh[SP];
			c.saved.r = c.r;
			c.saved.rh = c.rh;
			c.saved.r[SP] = sp;
			c.saved.rh[SP] = sph;
			break;
		};
		if (i - 1 != SP) {
			setreg(c, i - 1, v, sz);
		} else if (sz == 4 && !stack32(c)) {
			// A 386 quirk: POPAD with a 16-bit stack takes the
			// top half of ESP from the stack.
			c.rh[SP] = (v >> 16): u16;
		};
	};
};

fn op6_2(c: *cpu, op: u8, sz: u32) void = {
	arpl(c);
};

fn op6_3(c: *cpu, op: u8, sz: u32) void = {
	// BOUND
	modrm386(c);
	if (c.md == 3) return raise(c, EX_UD);
	const lo = mread(c, c.sreg, c.ea, sz);
	const hi = mread(c, c.sreg, (c.ea + sz) & amask_ea(c), sz);
	if (c.fault >= 0) return;
	const v = sext(reg(c, c.reg, sz), sz): i32;
	if (v < sext(lo, sz): i32 || v > sext(hi, sz): i32) raise(c, EX_BR);
};

fn op6_4(c: *cpu, op: u8, sz: u32) void = {
	// PUSH imm
	const v = imm(c, sz);
	if (c.fault < 0) push386(c, v, sz);
};

fn op6_5(c: *cpu, op: u8, sz: u32) void = {
	const v = sext(ifetch8(c), 1);
	if (c.fault < 0) push386(c, v, sz);
};

fn op6_6(c: *cpu, op: u8, sz: u32) void = {
	// IMUL r, r/m, imm
	modrm386(c);
	const a = rm_get(c, sz);
	const b = if (op == 0x69) imm(c, sz) else sext(ifetch8(c), 1);
	if (c.fault >= 0) return;
	setreg(c, c.reg, imul3(c, a, b, sz), sz);
};

fn op6_7(c: *cpu, op: u8, sz: u32) void = {
	string386(c, op);
};

fn op6_8(c: *cpu, op: u8, sz: u32) void = {
	raise(c, EX_UD);
};

fn op7_0(c: *cpu, op: u8, sz: u32) void = {
	// Jcc short
	const d = sext(ifetch8(c), 1);
	if (c.fault < 0 && cond(c, op & 0xF)) jump(c, c.eip + d);
};

fn op7_1(c: *cpu, op: u8, sz: u32) void = {
	raise(c, EX_UD);
};

fn op8_0(c: *cpu, op: u8, sz: u32) void = {
	// ALU r/m, imm
	const s: u32 = if (op & 1 == 0) 1 else sz;
	modrm386(c);
	const a = rm_get(c, s);
	const b = if (op == 0x81) imm(c, sz) else if (op == 0x83)
		sext(ifetch8(c), 1) else ifetch8(c): u32;
	if (c.fault >= 0) return;
	const r = alu3(c, c.reg: u8, a, b & mask(s), s);
	if (c.reg != 7) rm_set(c, r, s);
};

fn op8_1(c: *cpu, op: u8, sz: u32) void = {
	// TEST r/m, r
	const s: u32 = if (op == 0x84) 1 else sz;
	modrm386(c);
	const a = rm_get(c, s);
	if (c.fault < 0) alu3(c, 4, a, reg(c, c.reg, s), s);
};

fn op8_2(c: *cpu, op: u8, sz: u32) void = {
	// XCHG r/m, r
	const s: u32 = if (op == 0x86) 1 else sz;
	modrm386(c);
	const a = rm_get(c, s);
	if (c.fault >= 0) return;
	rm_set(c, reg(c, c.reg, s), s);
	if (c.fault < 0) setreg(c, c.reg, a, s);
};

fn op8_3(c: *cpu, op: u8, sz: u32) void = {
	// MOV r/m, r
	const s: u32 = if (op == 0x88) 1 else sz;
	modrm386(c);
	if (c.fault < 0) rm_set(c, reg(c, c.reg, s), s);
};

fn op8_4(c: *cpu, op: u8, sz: u32) void = {
	// MOV r, r/m
	const s: u32 = if (op == 0x8A) 1 else sz;
	modrm386(c);
	const v = rm_get(c, s);
	if (c.fault < 0) setreg(c, c.reg, v, s);
};

fn op8_5(c: *cpu, op: u8, sz: u32) void = {
	// MOV r/m, sreg
	modrm386(c);
	if (c.reg > 5) return raise(c, EX_UD);
	if (c.md == 3) {
		setreg(c, c.rm, c.s[c.reg], sz);
	} else {
		rm_set(c, c.s[c.reg], 2);
	};
};

fn op8_6(c: *cpu, op: u8, sz: u32) void = {
	// LEA
	modrm386(c);
	if (c.md == 3) return raise(c, EX_UD);
	setreg(c, c.reg, c.ea, sz);
};

fn op8_7(c: *cpu, op: u8, sz: u32) void = {
	// MOV sreg, r/m
	modrm386(c);
	if (c.reg > 5 || c.reg == CS) return raise(c, EX_UD);
	const v = rm_get(c, 2);
	if (c.fault >= 0) return;
	load_seg(c, c.reg, v: u16);
};

fn op8_8(c: *cpu, op: u8, sz: u32) void = {
	// POP r/m
	modrm386(c);
	if (c.reg != 0) return raise(c, EX_UD);
	// The address is worked out with SP already moved on.
	const old = sp_get(c);
	const v = mread(c, SS, old, sz);
	if (c.fault >= 0) return;
	sp_set(c, sp_add(c, old, sz));
	if (c.md != 3) {
		rm_readdress(c);
	};
	rm_set(c, v, sz);
	if (c.fault >= 0) sp_set(c, old);
};

fn op8_9(c: *cpu, op: u8, sz: u32) void = {
	raise(c, EX_UD);
};

fn op9_0(c: *cpu, op: u8, sz: u32) void = {
	void; // NOP
};

fn op9_1(c: *cpu, op: u8, sz: u32) void = {
	// XCHG eAX, r
	const r = (op & 7): size;
	const t = reg(c, AX, sz);
	setreg(c, AX, reg(c, r, sz), sz);
	setreg(c, r, t, sz);
};

fn op9_2(c: *cpu, op: u8, sz: u32) void = {
	// CBW, CWDE
	if (c.o32) set32(c, AX, sext(c.r[AX], 2))
	else c.r[AX] = sext(get8(c, 0), 1): u16;
};

fn op9_3(c: *cpu, op: u8, sz: u32) void = {
	// CWD, CDQ
	const neg = reg(c, AX, sz) & sign(sz) != 0;
	setreg(c, DX, if (neg) 0xFFFFFFFF else 0, sz);
};

fn op9_4(c: *cpu, op: u8, sz: u32) void = {
	// CALL far
	const off = imm(c, sz);
	const seg = ifetch(c, 2): u16;
	if (c.fault >= 0) return;
	far_transfer(c, seg, off, true, sz);
};

fn op9_5(c: *cpu, op: u8, sz: u32) void = {
	void; // WAIT
};

fn op9_6(c: *cpu, op: u8, sz: u32) void = {
	// PUSHF(D): VM and RF are not pushed
	fsync(c);
	push386(c, c.flags, sz);
};

fn op9_7(c: *cpu, op: u8, sz: u32) void = {
	// POPF(D)
	const v = pop386(c, sz);
	if (c.fault >= 0) return;
	popf(c, v: u16);
};

fn op9_8(c: *cpu, op: u8, sz: u32) void = {
	// SAHF
	fsync(c);
	c.flags = (c.flags & 0xFF00) | (get8(c, 4): u16 & 0xD5) | 0x02;
};

fn op9_9(c: *cpu, op: u8, sz: u32) void = {
	// LAHF
	fsync(c);
	set8(c, 4, c.flags: u8);
};

fn op9_10(c: *cpu, op: u8, sz: u32) void = {
	raise(c, EX_UD);
};

fn opA_0(c: *cpu, op: u8, sz: u32) void = {
	// MOV between eAX and [moffs]
	const s: u32 = if (op & 1 == 0) 1 else sz;
	const a = ifetch(c, if (c.a32) 4 else 2);
	const sr = useg(c, DS);
	if (c.fault >= 0) return;
	if (op < 0xA2) {
		const v = mread(c, sr, a, s);
		if (c.fault < 0) setreg(c, AX, v, s);
	} else {
		mwrite(c, sr, a, reg(c, AX, s), s);
	};
};

fn opA_1(c: *cpu, op: u8, sz: u32) void = {
	string386(c, op);
};

fn opA_2(c: *cpu, op: u8, sz: u32) void = {
	// TEST AL, imm8
	const b = ifetch8(c);
	if (c.fault < 0) alu3(c, 4, get8(c, 0), b, 1);
};

fn opA_3(c: *cpu, op: u8, sz: u32) void = {
	const b = imm(c, sz);
	if (c.fault < 0) alu3(c, 4, reg(c, AX, sz), b, sz);
};

fn opA_4(c: *cpu, op: u8, sz: u32) void = {
	raise(c, EX_UD);
};

fn opB_0(c: *cpu, op: u8, sz: u32) void = {
	// MOV r8, imm8
	const v = ifetch8(c);
	if (c.fault < 0) set8(c, (op & 7): size, v);
};

fn opB_1(c: *cpu, op: u8, sz: u32) void = {
	// MOV r, imm
	const v = imm(c, sz);
	if (c.fault < 0) setreg(c, (op & 7): size, v, sz);
};

fn opB_2(c: *cpu, op: u8, sz: u32) void = {
	raise(c, EX_UD);
};

fn opC_0(c: *cpu, op: u8, sz: u32) void = {
	// shifts and rotates
	const s: u32 = if (op & 1 == 0) 1 else sz;
	modrm386(c);
	const v = rm_get(c, s);
	const n: u32 = if (op < 0xC2) ifetch8(c) else if (op < 0xD2) 1
		else get8(c, 1);
	if (c.fault >= 0) return;
	rm_set(c, shift3(c, c.reg, v, n, s), s);
};

fn opC_1(c: *cpu, op: u8, sz: u32) void = {
	// RET (imm16)
	const n: u16 = if (op == 0xC2) ifetch(c, 2): u16 else 0;
	const t = pop386(c, sz);
	if (c.fault >= 0) return;
	jump(c, t);
	if (c.fault < 0) sp_set(c, sp_add(c, sp_get(c), n));
};

fn opC_2(c: *cpu, op: u8, sz: u32) void = {
	// LES, LDS
	load_far(c, if (op == 0xC4) ES else DS);
};

fn opC_3(c: *cpu, op: u8, sz: u32) void = {
	// MOV r/m, imm
	const s: u32 = if (op == 0xC6) 1 else sz;
	modrm386(c);
	if (c.reg != 0) return raise(c, EX_UD);
	const v = imm(c, s);
	if (c.fault < 0) rm_set(c, v, s);
};

fn opC_4(c: *cpu, op: u8, sz: u32) void = {
	// ENTER
	const n = ifetch(c, 2): u16;
	const level = ifetch8(c) & 0x1F;
	if (c.fault >= 0) return;
	push386(c, reg(c, BP, sz), sz);
	const frame = sp_get(c);
	let bp = if (stack32(c)) get32(c, BP) else c.r[BP]: u32;
	for (let i = 1u8; i < level; i += 1) {
		bp = sp_add(c, bp, -sz);
		const v = mread(c, SS, bp, sz);
		push386(c, v, sz);
	};
	if (level > 0) push386(c, frame, sz);
	if (c.fault >= 0) return;
	// Room for the locals must fit too.
	const sp = sp_add(c, sp_get(c), -(n: u32));
	mwrite(c, SS, sp, mread(c, SS, sp, 1), 1);
	if (c.fault >= 0) return;
	setreg(c, BP, frame, sz);
	sp_set(c, sp);
};

fn opC_5(c: *cpu, op: u8, sz: u32) void = {
	// LEAVE
	const old = sp_get(c);
	sp_set(c, if (stack32(c)) get32(c, BP) else c.r[BP]: u32);
	const v = pop386(c, sz);
	if (c.fault >= 0) {
		sp_set(c, old);
		return;
	};
	setreg(c, BP, v, sz);
};

fn opC_6(c: *cpu, op: u8, sz: u32) void = {
	// RETF (imm16)
	const n: u32 = if (op == 0xCA) ifetch(c, 2) else 0;
	if (c.fault < 0) retf386(c, sz, n);
};

fn opC_7(c: *cpu, op: u8, sz: u32) void = {
	softint386(c, 3);
};

fn opC_8(c: *cpu, op: u8, sz: u32) void = {
	const n = ifetch8(c);
	if (c.fault < 0) softint386(c, n);
};

fn opC_9(c: *cpu, op: u8, sz: u32) void = {
	// INTO
	if (flag(c, OF)) softint386(c, 4);
};

fn opC_10(c: *cpu, op: u8, sz: u32) void = {
	iret386(c, sz); // IRET(D)
};

fn opC_11(c: *cpu, op: u8, sz: u32) void = {
	raise(c, EX_UD);
};

fn opD_0(c: *cpu, op: u8, sz: u32) void = {
	// shifts and rotates
	const s: u32 = if (op & 1 == 0) 1 else sz;
	modrm386(c);
	const v = rm_get(c, s);
	const n: u32 = if (op < 0xC2) ifetch8(c) else if (op < 0xD2) 1
		else get8(c, 1);
	if (c.fault >= 0) return;
	rm_set(c, shift3(c, c.reg, v, n, s), s);
};

fn opD_1(c: *cpu, op: u8, sz: u32) void = {
	// AAM
	const base = ifetch8(c);
	if (c.fault >= 0) return;
	if (base == 0) {
		// The flags it leaves are part of the pushed state.
		c.saved.flags = (c.saved.flags & ~(OF | SF | ZF | AF | CF)) | PF;
		c.saved.lz_op = 0;
		return raise(c, EX_DE);
	};
	const al = get8(c, 0);
	set8(c, 4, al / base);
	set8(c, 0, al % base);
	szp3(c, al % base, 1);
};

fn opD_2(c: *cpu, op: u8, sz: u32) void = {
	// AAD
	const base = ifetch8(c);
	if (c.fault >= 0) return;
	const r = add3(c, get8(c, 0), get8(c, 4) * base, 0, 1);
	c.r[AX] = r: u8: u16;
};

fn opD_3(c: *cpu, op: u8, sz: u32) void = {
	// SALC
	set8(c, 0, if (flag(c, CF)) 0xFF else 0);
};

fn opD_4(c: *cpu, op: u8, sz: u32) void = {
	// XLAT
	const off = (if (c.a32) get32(c, BX) else c.r[BX]: u32) + get8(c, 0);
	const v = mread(c, useg(c, DS), off & amask_ea(c), 1);
	if (c.fault < 0) set8(c, 0, v: u8);
};

fn opD_5(c: *cpu, op: u8, sz: u32) void = {
	modrm386(c);
	if (c.fault < 0) fpu_exec(c, op);
};

fn opD_6(c: *cpu, op: u8, sz: u32) void = {
	raise(c, EX_UD);
};

fn opE_0(c: *cpu, op: u8, sz: u32) void = {
	// LOOPNZ, LOOPZ, LOOP
	const d = sext(ifetch8(c), 1);
	if (c.fault >= 0) return;
	const n = cnt_reg(c) - 1;
	set_cnt(c, n);
	let go = n != 0;
	if (op == 0xE0) go = go && !flag(c, ZF);
	if (op == 0xE1) go = go && flag(c, ZF);
	if (go) jump(c, c.eip + d);
};

fn opE_1(c: *cpu, op: u8, sz: u32) void = {
	// JCXZ, JECXZ
	const d = sext(ifetch8(c), 1);
	if (c.fault < 0 && cnt_reg(c) == 0) jump(c, c.eip + d);
};

fn opE_2(c: *cpu, op: u8, sz: u32) void = {
	// IN eAX, imm8
	const p = ifetch8(c): u16;
	if (c.fault >= 0) return;
	const s: u32 = if (op == 0xE4) 1 else sz;
	if (io_ok(c, p, s)) setreg(c, AX, port_in(c, p, s), s);
};

fn opE_3(c: *cpu, op: u8, sz: u32) void = {
	// OUT imm8, eAX
	const p = ifetch8(c): u16;
	if (c.fault >= 0) return;
	const s: u32 = if (op == 0xE6) 1 else sz;
	if (io_ok(c, p, s)) port_out(c, p, reg(c, AX, s), s);
};

fn opE_4(c: *cpu, op: u8, sz: u32) void = {
	// CALL near
	const d = if (c.o32) imm(c, 4) else sext(imm(c, 2), 2);
	if (c.fault >= 0) return;
	const t = c.eip + d;
	if ((if (c.o32) t else t & 0xFFFF) > c.slimit[CS]) return gp(c, 0);
	push386(c, c.eip, sz);
	jump(c, t);
};

fn opE_5(c: *cpu, op: u8, sz: u32) void = {
	// JMP near
	const d = if (c.o32) imm(c, 4) else sext(imm(c, 2), 2);
	if (c.fault < 0) jump(c, c.eip + d);
};

fn opE_6(c: *cpu, op: u8, sz: u32) void = {
	// JMP far
	const off = imm(c, sz);
	const seg = ifetch(c, 2): u16;
	if (c.fault < 0) far_transfer(c, seg, off, false, sz);
};

fn opE_7(c: *cpu, op: u8, sz: u32) void = {
	// JMP short
	const d = sext(ifetch8(c), 1);
	if (c.fault < 0) jump(c, c.eip + d);
};

fn opE_8(c: *cpu, op: u8, sz: u32) void = {
	// IN eAX, DX
	const s: u32 = if (op == 0xEC) 1 else sz;
	if (io_ok(c, c.r[DX], s)) setreg(c, AX, port_in(c, c.r[DX], s), s);
};

fn opE_9(c: *cpu, op: u8, sz: u32) void = {
	// OUT DX, eAX
	const s: u32 = if (op == 0xEE) 1 else sz;
	if (io_ok(c, c.r[DX], s)) port_out(c, c.r[DX], reg(c, AX, s), s);
};

fn opE_10(c: *cpu, op: u8, sz: u32) void = {
	raise(c, EX_UD);
};

fn opF_0(c: *cpu, op: u8, sz: u32) void = {
	deliver(c, 1, c.eip, intkind::EXC); // ICEBP
};

fn opF_1(c: *cpu, op: u8, sz: u32) void = {
	if (privileged(c)) c.halted = true;
};

fn opF_2(c: *cpu, op: u8, sz: u32) void = {
	setf(c, CF, !flag(c, CF));
};

fn opF_3(c: *cpu, op: u8, sz: u32) void = {
	group3_386(c, if (op == 0xF6) 1 else sz);
};

fn opF_4(c: *cpu, op: u8, sz: u32) void = {
	setf(c, CF, false);
};

fn opF_5(c: *cpu, op: u8, sz: u32) void = {
	setf(c, CF, true);
};

fn opF_6(c: *cpu, op: u8, sz: u32) void = {
	if (if_ok(c)) setf(c, IF, false);
};

fn opF_7(c: *cpu, op: u8, sz: u32) void = {
	if (!if_ok(c)) return;
	if (!flag(c, IF)) c.inhibit = true;
	setf(c, IF, true);
};

fn opF_8(c: *cpu, op: u8, sz: u32) void = {
	setf(c, DF, false);
};

fn opF_9(c: *cpu, op: u8, sz: u32) void = {
	setf(c, DF, true);
};

fn opF_10(c: *cpu, op: u8, sz: u32) void = {
	// INC/DEC r/m8, and Shifu's callback (FE 38 nn nn)
	modrm386(c);
	if (c.reg == 7 && c.md == 0 && c.rm == 0 && !c.a32) {
		match (c.callback) {
		case null => void;
		case let f: *callback_fn =>
			const n = ifetch(c, 2): u16;
			c.ip = c.eip: u16;
			fsync(c);
			f(c, n);
			// The callback may have moved IP (real-mode services),
			// or set a whole EIP (switching modes).
			if (c.eip: u16 != c.ip) c.eip = c.ip;
			return;
		};
	};
	if (c.reg > 1) return raise(c, EX_UD);
	const v = rm_get(c, 1);
	if (c.fault < 0) rm_set(c, incdec3(c, v, c.reg == 1, 1), 1);
};

fn opF_11(c: *cpu, op: u8, sz: u32) void = {
	group5_386(c);
};

fn opF_12(c: *cpu, op: u8, sz: u32) void = {
	raise(c, EX_UD);
};

















// The mask for offsets with the current address size.
fn amask_ea(c: *cpu) u32 = if (c.a32) 0xFFFFFFFF else 0xFFFF;

// POP r/m works out the address after SP has moved: decode it again.
fn rm_readdress(c: *cpu) void = {
	const save = c.eip;
	c.eip = c.start_eip;
	for (true) {
		const b = mread(c, CS, c.eip, 1): u8;
		c.eip += 1;
		if (b == 0x8F) break;
	};
	modrm386(c);
	c.eip = save;
};

// LES, LDS, LSS, LFS, LGS: an offset and a segment from memory.
fn load_far(c: *cpu, sr: size) void = {
	const sz = osz(c);
	modrm386(c);
	if (c.md == 3) return raise(c, EX_UD);
	const off = mread(c, c.sreg, c.ea, sz);
	const seg = mread(c, c.sreg, (c.ea + sz) & amask_ea(c), 2);
	if (c.fault >= 0) return;
	if (load_seg(c, sr, seg: u16)) setreg(c, c.reg, off, sz);
};

fn port_in(c: *cpu, p: u16, sz: u32) u32 = {
	let v = 0u32;
	for (let i = 0u32; i < sz; i += 1) {
		v |= port_read(c, p + i: u16): u32 << (i * 8): u8;
	};
	return v;
};

fn port_out(c: *cpu, p: u16, v: u32, sz: u32) void = {
	for (let i = 0u32; i < sz; i += 1) {
		port_write(c, p + i: u16, (v >> (i * 8): u8): u8);
	};
};

fn imul3(c: *cpu, a: u32, b: u32, sz: u32) u32 = {
	const r = sext(a, sz): i32: i64 * sext(b, sz): i32: i64;
	const t = r: u32 & mask(sz);
	const big = r != sext(t, sz): i32: i64;
	setf(c, CF, big);
	setf(c, OF, big);
	szp3(c, t, sz);
	return t;
};

fn group3_386(c: *cpu, sz: u32) void = {
	modrm386(c);
	switch (c.reg) {
	case 0, 1 => // TEST r/m, imm
		const a = rm_get(c, sz);
		const b = imm(c, sz);
		if (c.fault < 0) alu3(c, 4, a, b, sz);
	case 2 => // NOT
		const v = rm_get(c, sz);
		if (c.fault < 0) rm_set(c, ~v, sz);
	case 3 => // NEG
		const v = rm_get(c, sz);
		if (c.fault < 0) rm_set(c, sub3(c, 0, v, 0, sz), sz);
	case 4, 5 => // MUL, IMUL
		const v = rm_get(c, sz);
		if (c.fault >= 0) return;
		const a = reg(c, AX, sz);
		let lo = 0u32, hi = 0u32, big = false;
		if (c.reg == 4) {
			const r = a: u64 * v: u64;
			lo = r: u32 & mask(sz);
			hi = (r >> (sz * 8): u8): u32 & mask(sz);
			big = hi != 0;
		} else {
			const r = sext(a, sz): i32: i64 * sext(v, sz): i32: i64;
			lo = r: u32 & mask(sz);
			hi = (r: u64 >> (sz * 8): u8): u32 & mask(sz);
			big = r != sext(lo, sz): i32: i64;
		};
		if (sz == 1) {
			c.r[AX] = (hi << 8 | lo): u16;
		} else {
			setreg(c, AX, lo, sz);
			setreg(c, DX, hi, sz);
		};
		setf(c, CF, big);
		setf(c, OF, big);
		szp3(c, lo, sz);
	case 6, 7 => // DIV, IDIV
		const v = rm_get(c, sz);
		if (c.fault >= 0) return;
		if (v == 0) return raise(c, EX_DE);
		const bits = (sz * 8): u8;
		const a: u64 = if (sz == 1) c.r[AX]
			else reg(c, DX, sz): u64 << bits | reg(c, AX, sz);
		let q = 0u64, rem = 0u64;
		if (c.reg == 6) {
			q = a / v: u64;
			rem = a % v: u64;
			if (q > mask(sz)) return raise(c, EX_DE);
		} else {
			// The dividend, signed, at twice the operand size.
			const da: i64 = if (sz == 4) a: i64
				else if (sz == 2) a: u32: i32: i64 else a: u16: i16: i64;
			const dv = sext(v, sz): i32: i64;
			if (da == -0x7FFFFFFFFFFFFFFF - 1 && dv == -1) {
				return raise(c, EX_DE);
			};
			const sq = da / dv, sr = da % dv;
			const lim = sign(sz): i64;
			if (sq >= lim || sq < -lim) return raise(c, EX_DE);
			q = sq: u64;
			rem = sr: u64;
		};
		if (sz == 1) {
			c.r[AX] = ((rem: u16 & 0xFF) << 8) | (q: u16 & 0xFF);
		} else {
			setreg(c, AX, q: u32, sz);
			setreg(c, DX, rem: u32, sz);
		};
	case => abort();
	};
};

fn group5_386(c: *cpu) void = {
	const sz = osz(c);
	modrm386(c);
	switch (c.reg) {
	case 0, 1 => // INC, DEC
		const v = rm_get(c, sz);
		if (c.fault < 0) rm_set(c, incdec3(c, v, c.reg == 1, sz), sz);
	case 2 => // CALL near r/m
		const t = rm_get(c, sz);
		if (c.fault >= 0) return;
		if ((if (c.o32) t else t & 0xFFFF) > c.slimit[CS]) return gp(c, 0);
		push386(c, c.eip, sz);
		jump(c, t);
	case 3, 5 => // CALL far [m], JMP far [m]
		if (c.md == 3) return raise(c, EX_UD);
		const off = mread(c, c.sreg, c.ea, sz);
		const seg = mread(c, c.sreg, (c.ea + sz) & amask_ea(c), 2): u16;
		if (c.fault >= 0) return;
		far_transfer(c, seg, off, c.reg == 3, sz);
	case 4 => // JMP near r/m
		const t = rm_get(c, sz);
		if (c.fault < 0) jump(c, t);
	case 6 => // PUSH r/m
		const v = rm_get(c, sz);
		if (c.fault < 0) push386(c, v, sz);
	case => raise(c, EX_UD);
	};
};

// String instructions, one round per step with REP. 67h makes them use
// ESI, EDI and ECX.
fn string386(c: *cpu, op: u8) void = {
	if (c.rep != 0 && cnt_reg(c) == 0) return;
	const sz: u32 = if (op & 1 == 0) 1 else osz(c);
	const step: u32 = if (flag(c, DF)) -sz else sz;
	const am = amask_ea(c);
	const si = if (c.a32) get32(c, SI) else c.r[SI]: u32;
	const di = if (c.a32) get32(c, DI) else c.r[DI]: u32;
	const src = useg(c, DS);
	let compares = false;
	let nsi = si, ndi = di;
	switch (op & 0xFE) {
	case 0x6C => // INS
		if (!io_ok(c, c.r[DX], sz)) return;
		const v = port_in(c, c.r[DX], sz);
		mwrite(c, ES, di, v, sz);
		ndi = di + step;
	case 0x6E => // OUTS
		if (!io_ok(c, c.r[DX], sz)) return;
		const v = mread(c, src, si, sz);
		if (c.fault < 0) port_out(c, c.r[DX], v, sz);
		nsi = si + step;
	case 0xA4 => // MOVS
		const v = mread(c, src, si, sz);
		mwrite(c, ES, di, v, sz);
		nsi = si + step;
		ndi = di + step;
	case 0xA6 => // CMPS
		const a = mread(c, src, si, sz);
		const b = mread(c, ES, di, sz);
		if (c.fault < 0) sub3(c, a, b, 0, sz);
		nsi = si + step;
		ndi = di + step;
		compares = true;
	case 0xAA => // STOS
		mwrite(c, ES, di, reg(c, AX, sz), sz);
		ndi = di + step;
	case 0xAC => // LODS
		const v = mread(c, src, si, sz);
		if (c.fault < 0) setreg(c, AX, v, sz);
		nsi = si + step;
	case 0xAE => // SCAS
		const b = mread(c, ES, di, sz);
		if (c.fault < 0) sub3(c, reg(c, AX, sz), b, 0, sz);
		ndi = di + step;
		compares = true;
	case => abort();
	};
	if (c.fault >= 0) return;
	if (c.a32) {
		set32(c, SI, nsi);
		set32(c, DI, ndi);
	} else {
		c.r[SI] = nsi: u16;
		c.r[DI] = ndi: u16;
	};
	if (c.rep == 0) return;
	const n = (cnt_reg(c) - 1) & am;
	set_cnt(c, n);
	if (n == 0) return;
	if (compares) {
		if (c.rep == 0xF3 && !flag(c, ZF)) return;
		if (c.rep == 0xF2 && flag(c, ZF)) return;
	};
	c.eip = c.start_eip;
	c.in_rep = true;
};

// ---- Two-byte opcodes (0F xx) ----

fn exec0f(c: *cpu) void = {
	const op = ifetch8(c);
	if (c.fault >= 0) return;
	OPS0F[op](c, op, osz(c));
};

// The two-byte opcodes (0Fh xx), one handler each.
const OPS0F: [256]*group_fn = [
	&of_1, &of_0, &of_2, &of_2,
	&of_22, &of_22, &of_3, &of_22,
	&of_4, &of_4, &of_22, &of_22,
	&of_22, &of_22, &of_22, &of_22,
	&of_22, &of_22, &of_22, &of_22,
	&of_22, &of_22, &of_22, &of_22,
	&of_22, &of_22, &of_22, &of_22,
	&of_22, &of_22, &of_22, &of_22,
	&of_8, &of_8, &of_8, &of_8,
	&of_22, &of_22, &of_22, &of_22,
	&of_22, &of_22, &of_22, &of_22,
	&of_22, &of_22, &of_22, &of_22,
	&of_22, &of_22, &of_22, &of_22,
	&of_22, &of_22, &of_22, &of_22,
	&of_22, &of_22, &of_22, &of_22,
	&of_22, &of_22, &of_22, &of_22,
	&of_22, &of_22, &of_22, &of_22,
	&of_22, &of_22, &of_22, &of_22,
	&of_22, &of_22, &of_22, &of_22,
	&of_22, &of_22, &of_22, &of_22,
	&of_22, &of_22, &of_22, &of_22,
	&of_22, &of_22, &of_22, &of_22,
	&of_22, &of_22, &of_22, &of_22,
	&of_22, &of_22, &of_22, &of_22,
	&of_22, &of_22, &of_22, &of_22,
	&of_22, &of_22, &of_22, &of_22,
	&of_22, &of_22, &of_22, &of_22,
	&of_22, &of_22, &of_22, &of_22,
	&of_22, &of_22, &of_22, &of_22,
	&of_22, &of_22, &of_22, &of_22,
	&of_22, &of_22, &of_22, &of_22,
	&of_22, &of_22, &of_22, &of_22,
	&of_9, &of_9, &of_9, &of_9,
	&of_9, &of_9, &of_9, &of_9,
	&of_9, &of_9, &of_9, &of_9,
	&of_9, &of_9, &of_9, &of_9,
	&of_10, &of_10, &of_10, &of_10,
	&of_10, &of_10, &of_10, &of_10,
	&of_10, &of_10, &of_10, &of_10,
	&of_10, &of_10, &of_10, &of_10,
	&of_11, &of_12, &of_22, &of_13,
	&of_15, &of_15, &of_22, &of_22,
	&of_11, &of_12, &of_22, &of_13,
	&of_15, &of_15, &of_22, &of_16,
	&of_5, &of_5, &of_17, &of_13,
	&of_18, &of_19, &of_20, &of_20,
	&of_22, &of_22, &of_14, &of_13,
	&of_21, &of_21, &of_20, &of_20,
	&of_6, &of_6, &of_22, &of_22,
	&of_22, &of_22, &of_22, &of_22,
	&of_7, &of_7, &of_7, &of_7,
	&of_7, &of_7, &of_7, &of_7,
	&of_22, &of_22, &of_22, &of_22,
	&of_22, &of_22, &of_22, &of_22,
	&of_22, &of_22, &of_22, &of_22,
	&of_22, &of_22, &of_22, &of_22,
	&of_22, &of_22, &of_22, &of_22,
	&of_22, &of_22, &of_22, &of_22,
	&of_22, &of_22, &of_22, &of_22,
	&of_22, &of_22, &of_22, &of_22,
	&of_22, &of_22, &of_22, &of_22,
	&of_22, &of_22, &of_22, &of_22,
	&of_22, &of_22, &of_22, &of_22,
	&of_22, &of_22, &of_22, &of_22,
];

fn of_0(c: *cpu, op: u8, sz: u32) void = {
	// SGDT, SIDT, LGDT, LIDT, SMSW, LMSW
	modrm386(c);
	switch (c.reg) {
	case 0, 1, 2, 3 =>
		if (c.md == 3) return raise(c, EX_UD);
		const a2 = (c.ea + 2) & amask_ea(c);
		if (c.reg < 2) {
			const (lim, base) = if (c.reg == 0) (c.gdt_limit, c.gdt_base)
				else (c.idt_limit, c.idt_base);
			mwrite(c, c.sreg, c.ea, lim, 2);
			// A 386 stores the top byte as FF with a 16-bit operand.
			mwrite(c, c.sreg, a2, if (c.o32) base else base | 0xFF000000, 4);
		} else {
			if (!privileged(c)) return;
			const lim = mread(c, c.sreg, c.ea, 2): u16;
			let base = mread(c, c.sreg, a2, 4);
			if (c.fault >= 0) return;
			if (!c.o32) base &= 0xFFFFFF;
			if (c.reg == 2) {
				c.gdt_limit = lim;
				c.gdt_base = base;
			} else {
				c.idt_limit = lim;
				c.idt_base = base;
			};
		};
	case 4 => // SMSW
		if (c.md == 3) setreg(c, c.rm, c.cr0, sz) else rm_set(c, c.cr0, 2);
	case 6 => // LMSW: can set PE but not clear it
		if (!privileged(c)) return;
		const v = rm_get(c, 2);
		if (c.fault >= 0) return;
		set_cr0(c, (c.cr0 & ~0xEu32) | (v & 0xF) | (c.cr0 & 1));
	case 7 => // INVLPG (486)
		if (c.md == 3) return raise(c, EX_UD);
		if (privileged(c)) tlb_flush(c);
	case => raise(c, EX_UD);
	};
};

fn of_1(c: *cpu, op: u8, sz: u32) void = {
	group6(c);
};

fn of_2(c: *cpu, op: u8, sz: u32) void = {
	lar_lsl(c, op == 0x03);
};

fn of_3(c: *cpu, op: u8, sz: u32) void = {
	if (privileged(c)) c.cr0 &= ~8u32; // CLTS
};

fn of_4(c: *cpu, op: u8, sz: u32) void = {
	if (privileged(c)) void; // INVD, WBINVD (486)
};

// The 486's additions, which compilers use when told to target it
// (Watcom's -4r/-5r, as in Duke Nukem 3D).
fn of_5(c: *cpu, op: u8, sz: u32) void = {
	// CMPXCHG r/m, r
	const s: u32 = if (op == 0xB0) 1 else sz;
	modrm386(c);
	const d = rm_get(c, s);
	if (c.fault >= 0) return;
	sub3(c, reg(c, AX, s), d, 0, s);
	if (flag(c, ZF)) {
		rm_set(c, reg(c, c.reg, s), s);
	} else {
		rm_set(c, d, s);
		if (c.fault < 0) setreg(c, AX, d, s);
	};
};

fn of_6(c: *cpu, op: u8, sz: u32) void = {
	// XADD r/m, r
	const s: u32 = if (op == 0xC0) 1 else sz;
	modrm386(c);
	const d = rm_get(c, s);
	if (c.fault >= 0) return;
	const r = add3(c, d, reg(c, c.reg, s), 0, s);
	setreg(c, c.reg, d, s);
	rm_set(c, r, s);
};

fn of_7(c: *cpu, op: u8, sz: u32) void = {
	// BSWAP r32
	const r = (op & 7): size;
	const v = get32(c, r);
	set32(c, r, v >> 24 | (v >> 8) & 0xFF00 | (v << 8) & 0xFF0000 | v << 24);
};

fn of_8(c: *cpu, op: u8, sz: u32) void = {
	// MOV r32, CRn / DRn and back
	const b = ifetch8(c);
	if (c.fault >= 0 || !privileged(c)) return;
	const r = ((b >> 3) & 7): size, g = (b & 7): size;
	switch (op) {
	case 0x20 =>
		switch (r) {
		case 0 => set32(c, g, c.cr0);
		case 2 => set32(c, g, c.cr2);
		case 3 => set32(c, g, c.cr3);
		case => raise(c, EX_UD);
		};
	case 0x22 =>
		switch (r) {
		case 0 => set_cr0(c, get32(c, g));
		case 2 => c.cr2 = get32(c, g);
		case 3 =>
			c.cr3 = get32(c, g);
			tlb_flush(c);
		case => raise(c, EX_UD);
		};
	case 0x21 => set32(c, g, c.dr[r]);
	case 0x23 => c.dr[r] = get32(c, g);
	case => abort();
	};
};

fn of_9(c: *cpu, op: u8, sz: u32) void = {
	// Jcc near
	const d = if (c.o32) imm(c, 4) else sext(imm(c, 2), 2);
	if (c.fault < 0 && cond(c, op & 0xF)) jump(c, c.eip + d);
};

fn of_10(c: *cpu, op: u8, sz: u32) void = {
	// SETcc
	modrm386(c);
	if (c.fault < 0) rm_set(c, if (cond(c, op & 0xF)) 1 else 0, 1);
};

fn of_11(c: *cpu, op: u8, sz: u32) void = {
	push386(c, c.s[if (op == 0xA0) FS else GS], sz);
};

fn of_12(c: *cpu, op: u8, sz: u32) void = {
	const v = pop_seg(c, sz);
	if (c.fault < 0) load_seg(c, if (op == 0xA1) FS else GS, v);
};

fn of_13(c: *cpu, op: u8, sz: u32) void = {
	// BT, BTS, BTR, BTC r/m, r
	modrm386(c);
	bit_op(c, (op >> 3) & 3, reg(c, c.reg, sz), true);
};

fn of_14(c: *cpu, op: u8, sz: u32) void = {
	// BT, BTS, BTR, BTC r/m, imm8
	modrm386(c);
	if (c.reg < 4) return raise(c, EX_UD);
	const n = ifetch8(c);
	if (c.fault < 0) bit_op(c, (c.reg - 4): u8, n, false);
};

fn of_15(c: *cpu, op: u8, sz: u32) void = {
	// SHLD, SHRD
	modrm386(c);
	const a = rm_get(c, sz);
	const n: u32 = if (op & 1 == 0) ifetch8(c) else get8(c, 1);
	if (c.fault >= 0) return;
	const r = double_shift(c, a, reg(c, c.reg, sz), n, sz, op < 0xA8);
	rm_set(c, r, sz);
};

fn of_16(c: *cpu, op: u8, sz: u32) void = {
	// IMUL r, r/m
	modrm386(c);
	const b = rm_get(c, sz);
	if (c.fault < 0) setreg(c, c.reg, imul3(c, reg(c, c.reg, sz), b, sz), sz);
};

fn of_17(c: *cpu, op: u8, sz: u32) void = {
	load_far(c, SS);
};

fn of_18(c: *cpu, op: u8, sz: u32) void = {
	load_far(c, FS);
};

fn of_19(c: *cpu, op: u8, sz: u32) void = {
	load_far(c, GS);
};

fn of_20(c: *cpu, op: u8, sz: u32) void = {
	// MOVZX, MOVSX
	const s: u32 = if (op & 1 == 0) 1 else 2;
	modrm386(c);
	let v = rm_get(c, s);
	if (c.fault >= 0) return;
	if (op >= 0xBE) v = sext(v, s);
	setreg(c, c.reg, v, sz);
};

fn of_21(c: *cpu, op: u8, sz: u32) void = {
	// BSF, BSR
	modrm386(c);
	const v = rm_get(c, sz);
	if (c.fault >= 0) return;
	if (v == 0) {
		setf(c, ZF, true);
		return;
	};
	setf(c, ZF, false);
	let i = 0u32;
	if (op == 0xBC) {
		for (v >> i: u8 & 1 == 0) i += 1;
	} else {
		i = sz * 8 - 1;
		for (v >> i: u8 & 1 == 0) i -= 1;
	};
	setreg(c, c.reg, i, sz);
};

fn of_22(c: *cpu, op: u8, sz: u32) void = {
	raise(c, EX_UD);
};

// BT/BTS/BTR/BTC. With a register bit offset and a memory operand, the
// offset can reach beyond the operand, anywhere in a bit string.
fn bit_op(c: *cpu, op: u8, n: u32, reg_offset: bool) void = {
	const sz = osz(c);
	const bits = sz * 8;
	let bit = n & (bits - 1);
	if (c.md != 3 && reg_offset) {
		// Which operand-sized unit the bit is in (rounding down).
		const sn = sext(n, sz): i32: i64, b = bits: i64;
		const unit = if (sn < 0) (sn - (b - 1)) / b else sn / b;
		const d = unit * sz: i64;
		c.ea = (c.ea + d: u32) & amask_ea(c);
	};
	const v = rm_get(c, sz);
	if (c.fault >= 0) return;
	const m = 1u32 << bit: u8;
	setf(c, CF, v & m != 0);
	switch (op) {
	case 0 => void;
	case 1 => rm_set(c, v | m, sz);
	case 2 => rm_set(c, v & ~m, sz);
	case 3 => rm_set(c, v ^ m, sz);
	case => abort();
	};
};

fn double_shift(c: *cpu, a: u32, b: u32, n: u32, sz: u32, left: bool) u32 = {
	const n = n & 0x1F;
	if (n == 0) return a;
	const bits = sz * 8;
	let r = 0u32;
	if (sz == 4) {
		if (left) {
			const t = a: u64 << 32 | b: u64;
			r = (t << n: u8 >> 32): u32;
			setf(c, CF, (t >> (64 - n): u8) & 1 != 0);
		} else {
			const t = b: u64 << 32 | a: u64;
			r = (t >> n: u8): u32;
			setf(c, CF, (t >> (n - 1): u8) & 1 != 0);
		};
	} else {
		// Past 16, the 386 shifts src:src by n - 16.
		const a = a & 0xFFFF, b = b & 0xFFFF;
		const (hi, lo, k) = if (n > 16) (b, b, n - 16) else (a, b, n);
		if (left) {
			const t = hi << 16 | lo;
			r = ((t << k: u8) >> 16) & 0xFFFF;
			setf(c, CF, (t >> (32 - k): u8) & 1 != 0);
		} else {
			const t = lo << 16 | hi;
			r = (t >> k: u8) & 0xFFFF;
			setf(c, CF, (t >> (k - 1): u8) & 1 != 0);
		};
	};
	const s = sign(sz);
	if (left) {
		setf(c, OF, (r & s != 0) != flag(c, CF));
	} else {
		setf(c, OF, (r & s != 0) != (r & (s >> 1) != 0));
	};
	szp3(c, r, sz);
	return r;
};

// CLI and STI: in protected mode only at CPL <= IOPL.
fn if_ok(c: *cpu) bool = {
	if (c.cr0 & 1 == 0 || c.cpl <= iopl(c)) return true;
	gp(c, 0);
	return false;
};

// POPF: in protected mode IOPL changes only at CPL 0, and IF only at
// CPL <= IOPL.
fn popf(c: *cpu, v: u16) void = {
	if (c.cr0 & 1 == 0 || c.cpl == 0) {
		set_flags(c, v);
		return;
	};
	let keep: u16 = 0x3000;
	if (c.cpl > iopl(c)) keep |= IF;
	c.lz_op = 0;
	c.flags = (v & 0x7FD5 & ~keep) | (c.flags & keep) | 2;
};
