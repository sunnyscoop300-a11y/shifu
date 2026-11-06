// Shifu — the 8086 opcode map.

fn exec(c: *cpu, op: u8) void = {
	// 00-3F: the eight ALU operations in six forms each.
	if (op < 0x40 && op & 7 < 6) {
		const aop = op >> 3;
		const store = aop != 7;
		switch (op & 7) {
		case 0 =>
			modrm(c);
			const r = alu(c, aop, get_rm8(c), get8(c, c.reg), false);
			if (store) set_rm8(c, r: u8);
		case 1 =>
			modrm(c);
			const r = alu(c, aop, get_rm16(c), c.r[c.reg], true);
			if (store) set_rm16(c, r);
		case 2 =>
			modrm(c);
			const r = alu(c, aop, get8(c, c.reg), get_rm8(c), false);
			if (store) set8(c, c.reg, r: u8);
		case 3 =>
			modrm(c);
			const r = alu(c, aop, c.r[c.reg], get_rm16(c), true);
			if (store) c.r[c.reg] = r;
		case 4 =>
			const r = alu(c, aop, get8(c, 0), fetch8(c), false);
			if (store) set8(c, 0, r: u8);
		case 5 =>
			const r = alu(c, aop, c.r[AX], fetch16(c), true);
			if (store) c.r[AX] = r;
		case => abort();
		};
		return;
	};

	switch (op) {
	case 0x06, 0x0E, 0x16, 0x1E => // PUSH seg
		push(c, c.s[(op >> 3): size]);
	case 0x07, 0x0F, 0x17, 0x1F => // POP seg (0F is POP CS on the 8088)
		c.s[(op >> 3): size] = pop(c);
		if (op == 0x17) c.inhibit = true;
	case 0x27 => daa(c);
	case 0x2F => das(c);
	case 0x37 => aaa(c, false);
	case 0x3F => aaa(c, true);
	case 0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47 => // INC r16
		const r = (op & 7): size;
		c.r[r] = incdec(c, c.r[r], false, true);
	case 0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F => // DEC r16
		const r = (op & 7): size;
		c.r[r] = incdec(c, c.r[r], true, true);
	case 0x50, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57 => // PUSH r16
		const r = (op & 7): size;
		if (r == SP) {
			// The 8086 pushes SP's new value.
			c.r[SP] -= 2;
			write16(c, c.s[SS], c.r[SP], c.r[SP]);
		} else {
			push(c, c.r[r]);
		};
	case 0x58, 0x59, 0x5A, 0x5B, 0x5C, 0x5D, 0x5E, 0x5F => // POP r16
		const v = pop(c);
		c.r[(op & 7): size] = v;
	case => // 60-6F mirror 70-7F on the 8088: conditional jumps
		if (op >= 0x60 && op < 0x80) {
			const d = fetch8s(c);
			if (cond(c, op & 0xF)) c.ip += d;
		} else {
			exec2(c, op);
		};
	};
};

// Jump conditions 0-F, as in Jcc.
fn cond(c: *cpu, cc: u8) bool = {
	let r = false;
	switch (cc >> 1) {
	case 0 => r = flag(c, OF);
	case 1 => r = flag(c, CF);
	case 2 => r = flag(c, ZF);
	case 3 => r = flag(c, CF) || flag(c, ZF);
	case 4 => r = flag(c, SF);
	case 5 => r = flag(c, PF);
	case 6 => r = flag(c, SF) != flag(c, OF);
	case 7 => r = flag(c, ZF) || flag(c, SF) != flag(c, OF);
	case => abort();
	};
	return if (cc & 1 == 1) !r else r;
};

fn exec2(c: *cpu, op: u8) void = {
	switch (op) {
	case 0x80, 0x82 => // ALU r/m8, imm8
		modrm(c);
		const a = get_rm8(c);
		const r = alu(c, c.reg: u8, a, fetch8(c), false);
		if (c.reg != 7) set_rm8(c, r: u8);
	case 0x81 => // ALU r/m16, imm16
		modrm(c);
		const a = get_rm16(c);
		const r = alu(c, c.reg: u8, a, fetch16(c), true);
		if (c.reg != 7) set_rm16(c, r);
	case 0x83 => // ALU r/m16, sign-extended imm8
		modrm(c);
		const a = get_rm16(c);
		const r = alu(c, c.reg: u8, a, fetch8s(c), true);
		if (c.reg != 7) set_rm16(c, r);
	case 0x84 => // TEST r/m8, r8
		modrm(c);
		alu(c, 4, get_rm8(c), get8(c, c.reg), false);
	case 0x85 =>
		modrm(c);
		alu(c, 4, get_rm16(c), c.r[c.reg], true);
	case 0x86 => // XCHG r/m8, r8
		modrm(c);
		const a = get_rm8(c);
		set_rm8(c, get8(c, c.reg));
		set8(c, c.reg, a);
	case 0x87 =>
		modrm(c);
		const a = get_rm16(c);
		set_rm16(c, c.r[c.reg]);
		c.r[c.reg] = a;
	case 0x88 => // MOV r/m8, r8
		modrm(c);
		set_rm8(c, get8(c, c.reg));
	case 0x89 =>
		modrm(c);
		set_rm16(c, c.r[c.reg]);
	case 0x8A =>
		modrm(c);
		set8(c, c.reg, get_rm8(c));
	case 0x8B =>
		modrm(c);
		c.r[c.reg] = get_rm16(c);
	case 0x8C => // MOV r/m16, sreg (only two bits of reg count)
		modrm(c);
		set_rm16(c, c.s[c.reg & 3]);
	case 0x8D => // LEA
		modrm(c);
		c.r[c.reg] = c.ea_off;
	case 0x8E => // MOV sreg, r/m16
		modrm(c);
		c.s[c.reg & 3] = get_rm16(c);
		if (c.reg & 3 == SS) c.inhibit = true;
	case 0x8F => // POP r/m16
		modrm(c);
		set_rm16(c, pop(c));
	case 0x90 => void; // NOP (XCHG AX, AX)
	case 0x91, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97 => // XCHG AX, r16
		const r = (op & 7): size;
		const t = c.r[AX];
		c.r[AX] = c.r[r];
		c.r[r] = t;
	case 0x98 => // CBW
		c.r[AX] = c.r[AX]: u8: i8: i16: u16;
	case 0x99 => // CWD
		c.r[DX] = if (c.r[AX] & 0x8000 != 0) 0xFFFF else 0;
	case 0x9A => // CALL far
		const off = fetch16(c);
		const seg = fetch16(c);
		push(c, c.s[CS]);
		push(c, c.ip);
		c.s[CS] = seg;
		c.ip = off;
	case 0x9B => void; // WAIT: no coprocessor to wait for
	case 0x9C => push(c, c.flags); // PUSHF
	case 0x9D => set_flags(c, pop(c)); // POPF
	case 0x9E => // SAHF
		c.flags = (c.flags & 0xFF00) | (get8(c, 4): u16 & 0xD5) | 0x02;
	case 0x9F => set8(c, 4, c.flags: u8); // LAHF
	case 0xA0 => // MOV AL, [addr]
		const a = fetch16(c);
		set8(c, 0, read8(c, dseg(c, DS), a));
	case 0xA1 =>
		const a = fetch16(c);
		c.r[AX] = read16(c, dseg(c, DS), a);
	case 0xA2 =>
		const a = fetch16(c);
		write8(c, dseg(c, DS), a, get8(c, 0));
	case 0xA3 =>
		const a = fetch16(c);
		write16(c, dseg(c, DS), a, c.r[AX]);
	case 0xA4, 0xA5, 0xA6, 0xA7, 0xAA, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF =>
		string_op(c, op);
	case 0xA8 => // TEST AL, imm8
		alu(c, 4, get8(c, 0), fetch8(c), false);
	case 0xA9 =>
		alu(c, 4, c.r[AX], fetch16(c), true);
	case 0xB0, 0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7 => // MOV r8, imm8
		set8(c, (op & 7): size, fetch8(c));
	case 0xB8, 0xB9, 0xBA, 0xBB, 0xBC, 0xBD, 0xBE, 0xBF => // MOV r16, imm16
		c.r[(op & 7): size] = fetch16(c);
	case 0xC0, 0xC2 => // RET imm16 (C0 is an alias on the 8088)
		const n = fetch16(c);
		c.ip = pop(c);
		c.r[SP] += n;
	case 0xC1, 0xC3 => // RET
		c.ip = pop(c);
	case 0xC4, 0xC5 => // LES, LDS
		modrm(c);
		c.r[c.reg] = read16(c, c.ea_seg, c.ea_off);
		c.s[if (op == 0xC4) ES else DS] = read16(c, c.ea_seg, c.ea_off + 2);
	case 0xC6 => // MOV r/m8, imm8 (reg is ignored)
		modrm(c);
		set_rm8(c, fetch8(c));
	case 0xC7 =>
		modrm(c);
		set_rm16(c, fetch16(c));
	case 0xC8, 0xCA => // RETF imm16
		const n = fetch16(c);
		c.ip = pop(c);
		c.s[CS] = pop(c);
		c.r[SP] += n;
	case 0xC9, 0xCB => // RETF
		c.ip = pop(c);
		c.s[CS] = pop(c);
	case 0xCC => soft_int(c, 3);
	case 0xCD =>
		const n = fetch8(c);
		soft_int(c, n);
	case 0xCE => // INTO
		if (flag(c, OF)) soft_int(c, 4);
	case 0xCF => // IRET
		c.ip = pop(c);
		c.s[CS] = pop(c);
		set_flags(c, pop(c));
	case 0xD0 =>
		modrm(c);
		set_rm8(c, shift(c, c.reg, get_rm8(c), 1, false): u8);
	case 0xD1 =>
		modrm(c);
		set_rm16(c, shift(c, c.reg, get_rm16(c), 1, true));
	case 0xD2 =>
		modrm(c);
		set_rm8(c, shift(c, c.reg, get_rm8(c), get8(c, 1), false): u8);
	case 0xD3 =>
		modrm(c);
		set_rm16(c, shift(c, c.reg, get_rm16(c), get8(c, 1), true));
	case 0xD4 => aam(c, fetch8(c));
	case 0xD5 => aad(c, fetch8(c));
	case 0xD6 => // SALC (undocumented)
		set8(c, 0, if (flag(c, CF)) 0xFF else 0);
	case 0xD7 => // XLAT
		set8(c, 0, read8(c, dseg(c, DS), c.r[BX] + get8(c, 0)));
	case 0xD8, 0xD9, 0xDA, 0xDB, 0xDC, 0xDD, 0xDE, 0xDF =>
		// ESC: an 8087 instruction. Without one there is nothing to do.
		modrm(c);
	case 0xE0, 0xE1, 0xE2 => // LOOPNZ, LOOPZ, LOOP
		const d = fetch8s(c);
		c.r[CX] -= 1;
		let go = c.r[CX] != 0;
		if (op == 0xE0) go = go && !flag(c, ZF);
		if (op == 0xE1) go = go && flag(c, ZF);
		if (go) c.ip += d;
	case 0xE3 => // JCXZ
		const d = fetch8s(c);
		if (c.r[CX] == 0) c.ip += d;
	case 0xE4 => // IN AL, imm8
		const p = fetch8(c);
		set8(c, 0, port_read(c, p));
	case 0xE5 =>
		const p = fetch8(c): u16;
		c.r[AX] = port_read(c, p): u16 | port_read(c, p + 1): u16 << 8;
	case 0xE6 => // OUT imm8, AL
		const p = fetch8(c);
		port_write(c, p, get8(c, 0));
	case 0xE7 =>
		const p = fetch8(c): u16;
		port_write(c, p, get8(c, 0));
		port_write(c, p + 1, get8(c, 4));
	case 0xE8 => // CALL near
		const d = fetch16(c);
		push(c, c.ip);
		c.ip += d;
	case 0xE9 => // JMP near
		const d = fetch16(c);
		c.ip += d;
	case 0xEA => // JMP far
		const off = fetch16(c);
		c.s[CS] = fetch16(c);
		c.ip = off;
	case 0xEB => // JMP short
		const d = fetch8s(c);
		c.ip += d;
	case 0xEC => set8(c, 0, port_read(c, c.r[DX])); // IN AL, DX
	case 0xED =>
		c.r[AX] = port_read(c, c.r[DX]): u16 |
			port_read(c, c.r[DX] + 1): u16 << 8;
	case 0xEE => port_write(c, c.r[DX], get8(c, 0)); // OUT DX, AL
	case 0xEF =>
		port_write(c, c.r[DX], get8(c, 0));
		port_write(c, c.r[DX] + 1, get8(c, 4));
	case 0xF4 => // HLT
		c.halted = true;
	case 0xF5 => setf(c, CF, !flag(c, CF)); // CMC
	case 0xF6 => group3(c, false);
	case 0xF7 => group3(c, true);
	case 0xF8 => setf(c, CF, false);
	case 0xF9 => setf(c, CF, true);
	case 0xFA => setf(c, IF, false);
	case 0xFB => // STI: interrupts from after the next instruction
		if (!flag(c, IF)) c.inhibit = true;
		setf(c, IF, true);
	case 0xFC => setf(c, DF, false);
	case 0xFD => setf(c, DF, true);
	case 0xFE => // INC/DEC r/m8
		modrm(c);
		if (c.reg == 7 && c.md == 0 && c.rm == 0) {
			const n = fetch16(c);
			match (c.callback) {
			case null => void;
			case let f: *callback_fn => f(c, n);
			};
			return;
		};
		const v = get_rm8(c);
		set_rm8(c, incdec(c, v, c.reg & 1 == 1, false): u8);
	case 0xFF => group5(c);
	case => abort("unreachable opcode");
	};
};

fn port_read(c: *cpu, port: u16) u8 = {
	match (c.port_in) {
	case null => return 0xFF; // nothing on the bus
	case let f: *port_in_fn => return f(c, port);
	};
};

fn port_write(c: *cpu, port: u16, v: u8) void = {
	match (c.port_out) {
	case null => void;
	case let f: *port_out_fn => f(c, port, v);
	};
};

fn group3(c: *cpu, w: bool) void = {
	modrm(c);
	switch (c.reg) {
	case 0, 1 => // TEST r/m, imm
		if (w) {
			const a = get_rm16(c);
			alu(c, 4, a, fetch16(c), true);
		} else {
			const a = get_rm8(c);
			alu(c, 4, a, fetch8(c), false);
		};
	case 2 => // NOT
		if (w) set_rm16(c, ~get_rm16(c)) else set_rm8(c, ~get_rm8(c));
	case 3 => // NEG
		if (w) {
			set_rm16(c, sub(c, 0, get_rm16(c), 0, true): u16);
		} else {
			set_rm8(c, sub(c, 0, get_rm8(c), 0, false): u8);
		};
	case =>
		if (w) muldiv16(c, c.reg, get_rm16(c)) else muldiv8(c, c.reg, get_rm8(c));
	};
};

fn group5(c: *cpu) void = {
	modrm(c);
	switch (c.reg) {
	case 0, 1 => // INC, DEC
		set_rm16(c, incdec(c, get_rm16(c), c.reg == 1, true));
	case 2 => // CALL near r/m
		const t = get_rm16(c);
		push(c, c.ip);
		c.ip = t;
	case 3 => // CALL far [m]
		const off = read16(c, c.ea_seg, c.ea_off);
		const seg = read16(c, c.ea_seg, c.ea_off + 2);
		push(c, c.s[CS]);
		push(c, c.ip);
		c.s[CS] = seg;
		c.ip = off;
	case 4 => // JMP near r/m
		c.ip = get_rm16(c);
	case 5 => // JMP far [m]
		const off = read16(c, c.ea_seg, c.ea_off);
		c.s[CS] = read16(c, c.ea_seg, c.ea_off + 2);
		c.ip = off;
	case 6, 7 => // PUSH r/m
		if (c.md == 3 && c.rm == SP) {
			c.r[SP] -= 2;
			write16(c, c.s[SS], c.r[SP], c.r[SP]);
		} else {
			push(c, get_rm16(c));
		};
	case => abort();
	};
};

// MOVS, CMPS, STOS, LODS, SCAS. With a REP prefix, one call does one
// round and rewinds IP to the prefix while there are rounds left.
fn string_op(c: *cpu, op: u8) void = {
	if (c.rep != 0 && c.r[CX] == 0) return;
	const w = op & 1 == 1;
	const n: u16 = if (w) 2 else 1;
	const d: u16 = if (flag(c, DF)) -n else n;
	const src = dseg(c, DS);
	const es = c.s[ES];
	let compares = false;

	switch (op & 0xFE) {
	case 0xA4 => // MOVS
		if (w) {
			write16(c, es, c.r[DI], read16(c, src, c.r[SI]));
		} else {
			write8(c, es, c.r[DI], read8(c, src, c.r[SI]));
		};
		c.r[SI] += d;
		c.r[DI] += d;
	case 0xA6 => // CMPS
		if (w) {
			const a = read16(c, src, c.r[SI]);
			sub(c, a, read16(c, es, c.r[DI]), 0, true);
		} else {
			const a = read8(c, src, c.r[SI]);
			sub(c, a, read8(c, es, c.r[DI]), 0, false);
		};
		c.r[SI] += d;
		c.r[DI] += d;
		compares = true;
	case 0xAA => // STOS
		if (w) {
			write16(c, es, c.r[DI], c.r[AX]);
		} else {
			write8(c, es, c.r[DI], get8(c, 0));
		};
		c.r[DI] += d;
	case 0xAC => // LODS
		if (w) {
			c.r[AX] = read16(c, src, c.r[SI]);
		} else {
			set8(c, 0, read8(c, src, c.r[SI]));
		};
		c.r[SI] += d;
	case 0xAE => // SCAS
		if (w) {
			sub(c, c.r[AX], read16(c, es, c.r[DI]), 0, true);
		} else {
			sub(c, get8(c, 0), read8(c, es, c.r[DI]), 0, false);
		};
		c.r[DI] += d;
		compares = true;
	case => abort();
	};

	if (c.rep == 0) return;
	c.r[CX] -= 1;
	if (c.r[CX] == 0) return;
	if (compares) {
		// REPE stops on a difference, REPNE on a match.
		if (c.rep == 0xF3 && !flag(c, ZF)) return;
		if (c.rep == 0xF2 && flag(c, ZF)) return;
	};
	c.ip = c.start_ip;
	c.in_rep = true;
};
