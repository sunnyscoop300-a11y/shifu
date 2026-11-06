// Shifu — the 386's protected mode: segment descriptors (GDT, LDT),
// privilege levels, the IDT with interrupt and trap gates, call gates, the
// TSS's stacks and I/O permission bitmap, and paging with a small TLB.
//
// Every memory access goes segment -> linear address (base + offset,
// checked against the segment's limit and rights) -> physical address
// (through the page tables when paging is on). In real mode the base is
// selector * 16 and only the limit counts.

// Exceptions with an error code.
def EX_DF: u8 = 8;
def EX_TS: u8 = 10;
def EX_NP: u8 = 11;
def EX_PF: u8 = 14;

// Descriptor attribute bits (access byte | flags << 8).
def A_ACCESSED: u16 = 0x01;
def A_RW: u16 = 0x02;       // data: writable, code: readable
def A_DC: u16 = 0x04;       // data: expand-down, code: conforming
def A_CODE: u16 = 0x08;
def A_S: u16 = 0x10;        // code or data (not a system descriptor)
def A_P: u16 = 0x80;
def A_DB: u16 = 0x4000;     // 32-bit code / big stack
def A_G: u16 = 0x8000;

// Kinds of interrupt.
type intkind = enum {
	EXC,   // an exception
	SOFT,  // INT n, INT3, INTO (checked against the gate's DPL)
	HW,    // a hardware interrupt
};

export fn protected(c: *cpu) bool = c.cr0 & 1 != 0;

fn paging(c: *cpu) bool = c.cr0 & 0x80000001 == 0x80000001;

fn seg_base(c: *cpu, i: size) u32 = {
	if (c.cr0 & 1 != 0) return c.sbase[i];
	if (c.stale != 0 && c.stale & (1 << i: u8) != 0 && c.s[i] == c.stale_sel[i]) {
		return c.sbase[i];
	};
	return c.s[i]: u32 << 4;
};

fn code32(c: *cpu) bool = c.sattr[CS] & A_DB != 0;
fn stack32(c: *cpu) bool = c.sattr[SS] & A_DB != 0;
fn iopl(c: *cpu) u8 = ((c.flags >> 12) & 3): u8;

// Raises an exception with an error code.
fn raise_ec(c: *cpu, n: u8, code: u32) void = {
	if (c.fault < 0) {
		c.fault = n: int;
		c.fault_code = code;
	};
};

// #GP(0), and friends with a selector as the error code.
fn gp(c: *cpu, code: u32) void = raise_ec(c, EX_GP, code);

fn has_code(n: u8) bool = switch (n) {
case 8, 10, 11, 12, 13, 14, 17 => yield true;
case => yield false;
};

// ---- Segment checks ----

// Whether sz bytes at off may be read (or written) through segment sreg;
// raises #GP(0), or #SS(0) for the stack, if not.
fn seg_check(c: *cpu, sreg: size, off: u32, sz: u32, write: bool) bool = {
	const lim = c.slimit[sreg];
	if (c.cr0 & 1 == 0) {
		// Real mode: only the limit.
		if (lim >= sz - 1 && off <= lim - (sz - 1)) return true;
		raise(c, if (sreg == SS) EX_SS else EX_GP);
		return false;
	};
	const a = c.sattr[sreg];
	let ok = a & A_P != 0;
	if (ok && a & A_CODE != 0) {
		// Code: never writable, readable only with R (fetches don't
		// come through here).
		ok = !write && a & A_RW != 0;
	} else if (ok && write) {
		ok = a & A_RW != 0;
	};
	if (ok) {
		if (a & (A_CODE | A_DC) == A_DC) {
			// Expand-down: valid offsets are above the limit.
			const top: u32 = if (a & A_DB != 0) 0xFFFFFFFF else 0xFFFF;
			ok = off > lim && off <= top - (sz - 1);
		} else {
			ok = lim >= sz - 1 && off <= lim - (sz - 1);
		};
	};
	if (ok) return true;
	if (sreg == SS) raise_ec(c, EX_SS, 0) else gp(c, 0);
	return false;
};

// ---- Paging ----

export fn tlb_flush(c: *cpu) void = {
	c.tlb_tag = [0...];
};

// TLB entry bits beside the page frame.
def T_VALID: u32 = 1;
def T_WRITE: u32 = 2;
def T_USER: u32 = 4;
def T_DIRTY: u32 = 8;

fn pread32(c: *cpu, a: u32) u32 =
	rb(c, a): u32 | rb(c, a + 1): u32 << 8 | rb(c, a + 2): u32 << 16 |
	rb(c, a + 3): u32 << 24;

fn pwrite32(c: *cpu, a: u32, v: u32) void = {
	for (let i = 0u32; i < 4; i += 1) wb(c, a + i, (v >> (i * 8): u8): u8);
};

// The physical address of a linear one. Raises #PF (with CR2) and returns
// void when the page isn't there or may not be used this way.
fn xlate(c: *cpu, lin: u32, write: bool, user: bool) (u32 | void) = {
	if (c.cr0 & 0x80000001 != 0x80000001) return lin;
	const idx = (lin >> 12) & 0xFF;
	const tag = (lin & 0xFFFFF000) | 1;
	if (c.tlb_tag[idx] == tag) {
		const v = c.tlb_val[idx];
		const allowed = (!user || v & T_USER != 0) &&
			(!user || !write || v & T_WRITE != 0);
		if (allowed && (!write || v & T_DIRTY != 0)) {
			return (v & 0xFFFFF000) | (lin & 0xFFF);
		};
	};
	const ec: u32 = (if (write) 2u32 else 0u32) | (if (user) 4u32 else 0u32);
	const pde_a = (c.cr3 & 0xFFFFF000) + (lin >> 22) * 4;
	const pde = pread32(c, pde_a);
	if (pde & 1 == 0) {
		c.cr2 = lin;
		raise_ec(c, EX_PF, ec);
		return;
	};
	const pte_a = (pde & 0xFFFFF000) + ((lin >> 12) & 0x3FF) * 4;
	const pte = pread32(c, pte_a);
	if (pte & 1 == 0) {
		c.cr2 = lin;
		raise_ec(c, EX_PF, ec);
		return;
	};
	const us = pde & pte & 4 != 0, rw = pde & pte & 2 != 0;
	// The 386 has no write protection for the supervisor (that came
	// with the 486's CR0.WP).
	if (user && (!us || (write && !rw))) {
		c.cr2 = lin;
		raise_ec(c, EX_PF, ec | 1);
		return;
	};
	if (pde & 0x20 == 0) pwrite32(c, pde_a, pde | 0x20);
	const npte = pte | 0x20 | (if (write) 0x40u32 else 0u32);
	if (npte != pte) pwrite32(c, pte_a, npte);
	c.tlb_tag[idx] = tag;
	c.tlb_val[idx] = (pte & 0xFFFFF000) | T_VALID |
		(if (rw) T_WRITE else 0u32) | (if (us) T_USER else 0u32) |
		(if (npte & 0x40 != 0) T_DIRTY else 0u32);
	return (pte & 0xFFFFF000) | (lin & 0xFFF);
};

fn user_mode(c: *cpu) bool = c.cpl == 3 && c.cr0 & 1 != 0;

// Linear memory, as the CPU's own structures (descriptor tables, the
// TSS) are read: with supervisor rights.
fn lin_read(c: *cpu, lin: u32, sz: u32) u32 = {
	let v = 0u32;
	for (let i = 0u32; i < sz; i += 1) {
		match (xlate(c, lin + i, false, false)) {
		case let p: u32 => v |= rb(c, p): u32 << (i * 8): u8;
		case void => return 0;
		};
	};
	return v;
};

fn lin_write(c: *cpu, lin: u32, v: u32, sz: u32) void = {
	for (let i = 0u32; i < sz; i += 1) {
		match (xlate(c, lin + i, true, false)) {
		case let p: u32 => wb(c, p, (v >> (i * 8): u8): u8);
		case void => return;
		};
	};
};

// ---- Memory through a segment ----

fn mread(c: *cpu, sreg: size, off: u32, sz: u32) u32 = {
	if (c.fault >= 0) return 0;
	let lin = 0u32;
	if (c.cr0 & 1 == 0 && c.stale == 0) {
		// Real mode, the common case: only the limit to check.
		const lim = c.slimit[sreg];
		if (lim < sz - 1 || off > lim - (sz - 1)) {
			raise(c, if (sreg == SS) EX_SS else EX_GP);
			return 0;
		};
		lin = (c.s[sreg]: u32 << 4) + off;
	} else if (c.cr0 & 1 != 0 && c.sattr[sreg] & (A_P | A_CODE | A_DC) == A_P &&
			c.slimit[sreg] >= sz - 1 && off <= c.slimit[sreg] - (sz - 1)) {
		// Protected mode, a present expand-up data segment: the
		// common case, checked inline.
		lin = c.sbase[sreg] + off;
	} else {
		if (!seg_check(c, sreg, off, sz, false)) return 0;
		lin = seg_base(c, sreg) + off;
	};
	let a = lin;
	if (c.cr0 & 0x80000001 == 0x80000001) {
		if ((lin & 0xFFF) + sz > 0x1000) {
			// Across two pages: byte by byte.
			let v = 0u32;
			for (let i = 0u32; i < sz; i += 1) {
				match (xlate(c, lin + i, false, user_mode(c))) {
				case let p: u32 => v |= rb(c, p): u32 << (i * 8): u8;
				case void => return 0;
				};
			};
			return v;
		};
		a = match (xlate(c, lin, false, user_mode(c))) {
		case let p: u32 => yield p;
		case void => return 0;
		};
	};
	// Plain memory: straight from the array.
	a &= c.amask;
	if (a + sz <= c.amask && (a >> 16) != 0xA) {
		// x86 itself doesn't mind unaligned loads: one load each.
		const p = &c.memp[a];
		switch (sz) {
		case 1 => return *p;
		case 2 => return *(p: *u16);
		case => return *(p: *u32);
		};
	};
	let v = 0u32;
	for (let i = 0u32; i < sz; i += 1) {
		v |= rb(c, a + i): u32 << (i * 8): u8;
	};
	return v;
};

fn mwrite(c: *cpu, sreg: size, off: u32, v: u32, sz: u32) void = {
	if (c.fault >= 0) return;
	let lin = 0u32;
	if (c.cr0 & 1 == 0 && c.stale == 0) {
		const lim = c.slimit[sreg];
		if (lim < sz - 1 || off > lim - (sz - 1)) {
			raise(c, if (sreg == SS) EX_SS else EX_GP);
			return;
		};
		lin = (c.s[sreg]: u32 << 4) + off;
	} else if (c.cr0 & 1 != 0 &&
			c.sattr[sreg] & (A_P | A_CODE | A_DC | A_RW) == A_P | A_RW &&
			c.slimit[sreg] >= sz - 1 && off <= c.slimit[sreg] - (sz - 1)) {
		lin = c.sbase[sreg] + off;
	} else {
		if (!seg_check(c, sreg, off, sz, true)) return;
		lin = seg_base(c, sreg) + off;
	};
	let a = lin;
	if (c.cr0 & 0x80000001 == 0x80000001) {
		if ((lin & 0xFFF) + sz > 0x1000) {
			// Check both pages before writing anything.
			const u = user_mode(c);
			if (xlate(c, lin, true, u) is void) return;
			if (xlate(c, lin + sz - 1, true, u) is void) return;
			for (let i = 0u32; i < sz; i += 1) {
				const p = xlate(c, lin + i, true, u) as u32;
				wb(c, p, (v >> (i * 8): u8): u8);
			};
			return;
		};
		a = match (xlate(c, lin, true, user_mode(c))) {
		case let p: u32 => yield p;
		case void => return;
		};
	};
	a &= c.amask;
	if (a + sz <= c.amask && (a >> 16) != 0xA && !c.log_writes) {
		const p = &c.memp[a];
		switch (sz) {
		case 1 => *p = v: u8;
		case 2 => *(p: *u16) = v: u16;
		case => *(p: *u32) = v;
		};
		return;
	};
	for (let i = 0u32; i < sz; i += 1) {
		wb(c, a + i, (v >> (i * 8): u8): u8);
	};
};

// Instruction bytes: past the end of the code segment is #GP, and so is
// an instruction longer than 15 bytes.
fn ifetch(c: *cpu, sz: u32) u32 = {
	const e = c.eip;
	if (e + sz <= c.fend && e + sz > e) {
		const p = &c.memp[(c.cbase + e) & 0xFFFFFF];
		c.eip = e + sz;
		if (sz == 4) return *(p: *u32);
		if (sz == 2) return *(p: *u16);
		return *p;
	};
	if (c.cfast && c.fault < 0 && e - c.start_eip + sz <= 15 &&
			c.slimit[CS] >= sz - 1 && e <= c.slimit[CS] - (sz - 1)) {
		const a = (c.cbase + e) & c.amask;
		if (a >> 16 != 0xA && a + sz <= c.amask) {
			c.eip = e + sz;
			const m = c.mem;
			if (sz == 2) return m[a]: u32 | m[a + 1]: u32 << 8;
			if (sz == 4) return m[a]: u32 | m[a + 1]: u32 << 8 |
				m[a + 2]: u32 << 16 | m[a + 3]: u32 << 24;
			return m[a];
		};
	};
	if (c.eip - c.start_eip + sz > 15) {
		gp(c, 0);
		return 0;
	};
	if (c.fault >= 0) return 0;
	const lim = c.slimit[CS];
	if (lim < sz - 1 || c.eip > lim - (sz - 1)) {
		gp(c, 0);
		return 0;
	};
	const lin = seg_base(c, CS) + c.eip;
	let v = 0u32;
	for (let i = 0u32; i < sz; i += 1) {
		match (xlate(c, lin + i, false, user_mode(c))) {
		case let p: u32 => v |= rb(c, p): u32 << (i * 8): u8;
		case void => return 0;
		};
	};
	c.eip += sz;
	return v;
};

fn ifetch8(c: *cpu) u8 = {
	const e = c.eip;
	if (e < c.fend) {
		c.eip = e + 1;
		return c.memp[(c.cbase + e) & 0xFFFFFF];
	};
	return ifetch(c, 1): u8;
};

// ---- The stack: SP or ESP, by the stack segment's B bit ----

fn sp_get(c: *cpu) u32 = if (stack32(c)) get32(c, SP) else c.r[SP];

fn sp_set(c: *cpu, v: u32) void = {
	if (stack32(c)) set32(c, SP, v) else c.r[SP] = v: u16;
};

// SP moved by d, wrapping as the stack's size does.
fn sp_add(c: *cpu, sp: u32, d: u32) u32 =
	if (stack32(c)) sp + d else (sp + d) & 0xFFFF;

fn push386(c: *cpu, v: u32, sz: u32) void = {
	const sp = sp_add(c, sp_get(c), -sz);
	mwrite(c, SS, sp, v, sz);
	if (c.fault < 0) sp_set(c, sp);
};

fn pop386(c: *cpu, sz: u32) u32 = {
	const sp = sp_get(c);
	const v = mread(c, SS, sp, sz);
	if (c.fault < 0) sp_set(c, sp_add(c, sp, sz));
	return v;
};

// POP of a segment register reads a word, even when it takes 4 bytes
// off the stack.
fn pop_seg(c: *cpu, sz: u32) u16 = {
	const sp = sp_get(c);
	const v = mread(c, SS, sp, 2): u16;
	if (c.fault < 0) sp_set(c, sp_add(c, sp, sz));
	return v;
};

// ---- Descriptors ----

type desc = struct {
	lo: u32,
	hi: u32,
};

fn desc_base(d: desc) u32 = (d.lo >> 16) | (d.hi & 0xFF) << 16 | (d.hi & 0xFF000000);

fn desc_limit(d: desc) u32 = {
	const l = (d.lo & 0xFFFF) | (d.hi & 0xF0000);
	return if (d.hi & 0x800000 != 0) l << 12 | 0xFFF else l;
};

fn desc_attr(d: desc) u16 = (((d.hi >> 8) & 0xFF) | ((d.hi >> 8) & 0xF000)): u16;

fn dpl_of(a: u16) u8 = ((a >> 5) & 3): u8;

// Where selector sel's descriptor is, or void past the table's limit.
fn desc_addr(c: *cpu, sel: u16) (u32 | void) = {
	const off = (sel & 0xFFF8): u32;
	if (sel & 4 != 0) {
		if (c.ldtr & 0xFFFC == 0 || off + 7 > c.ldt_limit) return;
		return c.ldt_base + off;
	};
	if (off + 7 > c.gdt_limit) return;
	return c.gdt_base + off;
};

fn read_desc(c: *cpu, sel: u16) (desc | void) = {
	const a = match (desc_addr(c, sel)) {
	case let a: u32 => yield a;
	case void => return;
	};
	return desc { lo = lin_read(c, a, 4), hi = lin_read(c, a + 4, 4) };
};

fn set_accessed(c: *cpu, sel: u16, d: desc) void = {
	if (d.hi & 0x100 != 0) return;
	match (desc_addr(c, sel)) {
	case let a: u32 => lin_write(c, a + 5, ((d.hi >> 8) | 1) & 0xFF, 1);
	case void => void;
	};
};

// Saves the segment caches the first time an instruction changes them.
fn seg_save(c: *cpu) void = {
	if (c.seg_dirty) return;
	c.seg_saved = segsnap {
		s = c.s,
		sbase = c.sbase,
		slimit = c.slimit,
		sattr = c.sattr,
		cpl = c.cpl,
	};
	c.seg_dirty = true;
};

fn seg_restore(c: *cpu) void = {
	if (!c.seg_dirty) return;
	c.s = c.seg_saved.s;
	c.sbase = c.seg_saved.sbase;
	c.slimit = c.seg_saved.slimit;
	c.sattr = c.seg_saved.sattr;
	c.cpl = c.seg_saved.cpl;
	c.seg_dirty = false;
};

fn set_seg(c: *cpu, i: size, sel: u16, base: u32, limit: u32, attr: u16) void = {
	seg_save(c);
	c.s[i] = sel;
	c.sbase[i] = base;
	c.slimit[i] = limit;
	c.sattr[i] = attr;
};

// Loads a data or stack segment register (MOV, POP, LDS...), with the
// checks protected mode makes. Returns false after raising a fault.
fn load_seg(c: *cpu, i: size, sel: u16) bool = {
	if (c.cr0 & 1 == 0) {
		c.s[i] = sel;
		c.stale &= ~(1 << i: u8);
		if (i == SS) c.inhibit = true;
		return true;
	};
	const ec = (sel & 0xFFFC): u32;
	if (i == SS) {
		if (sel & 0xFFFC == 0 || sel & 3 != c.cpl) {
			gp(c, ec);
			return false;
		};
	} else if (sel & 0xFFFC == 0) {
		// A null selector can be loaded; using it faults.
		set_seg(c, i, sel, 0, 0, 0);
		return true;
	};
	const d = match (read_desc(c, sel)) {
	case let d: desc => yield d;
	case void =>
		gp(c, ec);
		return false;
	};
	if (c.fault >= 0) return false;
	const a = desc_attr(d), dpl = dpl_of(a);
	if (i == SS) {
		if (a & (A_S | A_CODE | A_RW) != A_S | A_RW || dpl != c.cpl) {
			gp(c, ec);
			return false;
		};
		if (a & A_P == 0) {
			raise_ec(c, EX_SS, ec);
			return false;
		};
		c.inhibit = true;
	} else {
		const rpl = sel & 3;
		const maxpl = if (rpl > c.cpl) rpl: u8 else c.cpl;
		if (a & A_S == 0 || (a & A_CODE != 0 && a & A_RW == 0) ||
				((a & (A_CODE | A_DC) != A_CODE | A_DC) && dpl < maxpl)) {
			gp(c, ec);
			return false;
		};
		if (a & A_P == 0) {
			raise_ec(c, EX_NP, ec);
			return false;
		};
	};
	set_accessed(c, sel, d);
	set_seg(c, i, sel, desc_base(d), desc_limit(d), a | A_ACCESSED);
	return true;
};

// Loads CS with a checked code descriptor, at privilege level pl.
fn set_cs(c: *cpu, sel: u16, d: desc, pl: u8) void = {
	set_accessed(c, sel, d);
	set_seg(c, CS, (sel & 0xFFFC) | pl, desc_base(d), desc_limit(d),
		desc_attr(d) | A_ACCESSED);
	c.cpl = pl;
};

// After a return to an outer level, data segments the new level may not
// see are made null.
fn null_inner_segments(c: *cpu) void = {
	const regs: [4]size = [ES, DS, FS, GS];
	for (let i .. regs) {
		const a = c.sattr[i];
		if (a & A_P == 0) continue;
		const conforming = a & (A_CODE | A_DC) == A_CODE | A_DC;
		if (!conforming && dpl_of(a) < c.cpl) set_seg(c, i, 0, 0, 0, 0);
	};
};

// The stack for privilege level pl, from the TSS.
fn tss_stack(c: *cpu, pl: u8) (u16, u32) = {
	const t = c.tr_attr & 0xF;
	if (t == 0x9 || t == 0xB) {
		const at = 4 + pl: u32 * 8;
		if (at + 5 > c.tr_limit) {
			raise_ec(c, EX_TS, c.tr & 0xFFFC);
			return (0, 0);
		};
		return (lin_read(c, c.tr_base + at + 4, 2): u16,
			lin_read(c, c.tr_base + at, 4));
	};
	if (t == 0x1 || t == 0x3) {
		const at = 2 + pl: u32 * 4;
		if (at + 3 > c.tr_limit) {
			raise_ec(c, EX_TS, c.tr & 0xFFFC);
			return (0, 0);
		};
		return (lin_read(c, c.tr_base + at + 2, 2): u16,
			lin_read(c, c.tr_base + at, 2));
	};
	raise_ec(c, EX_TS, c.tr & 0xFFFC);
	return (0, 0);
};

// Switches to the stack for level pl (SS checked as the CPU does).
fn switch_stack(c: *cpu, pl: u8) bool = {
	const (ss, esp) = tss_stack(c, pl);
	if (c.fault >= 0) return false;
	const ec = (ss & 0xFFFC): u32;
	if (ss & 0xFFFC == 0 || ss & 3 != pl) {
		raise_ec(c, EX_TS, ec);
		return false;
	};
	const d = match (read_desc(c, ss)) {
	case let d: desc => yield d;
	case void =>
		raise_ec(c, EX_TS, ec);
		return false;
	};
	const a = desc_attr(d);
	if (a & (A_S | A_CODE | A_RW) != A_S | A_RW || dpl_of(a) != pl) {
		raise_ec(c, EX_TS, ec);
		return false;
	};
	if (a & A_P == 0) {
		raise_ec(c, EX_SS, ec);
		return false;
	};
	set_accessed(c, ss, d);
	set_seg(c, SS, ss, desc_base(d), desc_limit(d), a | A_ACCESSED);
	if (stack32(c)) set32(c, SP, esp) else c.r[SP] = esp: u16;
	return true;
};

// ---- Interrupts and exceptions ----

// Takes interrupt n: through the real-mode vector table (at IDTR's base)
// or the protected-mode IDT. ret is the EIP to come back to.
fn deliver(c: *cpu, n: u8, ret: u32, kind: intkind) void = {
	if (c.cr0 & 1 == 0) {
		const sp = c.r[SP];
		const a = c.idt_base + n: u32 * 4;
		const off = rb(c, a): u16 | rb(c, a + 1): u16 << 8;
		const seg = rb(c, a + 2): u16 | rb(c, a + 3): u16 << 8;
		fsync(c);
		push386(c, c.flags, 2);
		push386(c, c.s[CS], 2);
		push386(c, ret: u16, 2);
		if (c.fault >= 0) {
			c.r[SP] = sp;
			return;
		};
		c.flags &= ~(IF | TF);
		c.s[CS] = seg;
		c.stale &= ~(1u8 << CS: u8);
		c.eip = off;
		c.halted = false;
		return;
	};
	const ec = n: u32 * 8 + 2 + (if (kind == intkind::SOFT) 0u32 else 1u32);
	if (n: u32 * 8 + 7 > c.idt_limit) {
		gp(c, ec);
		return;
	};
	const g = desc {
		lo = lin_read(c, c.idt_base + n: u32 * 8, 4),
		hi = lin_read(c, c.idt_base + n: u32 * 8 + 4, 4),
	};
	if (c.fault >= 0) return;
	const ga = desc_attr(g);
	const gtype = ga & 0x1F;
	if (gtype != 0x06 && gtype != 0x07 && gtype != 0x0E && gtype != 0x0F) {
		// Task gates aren't done; anything else isn't a gate.
		gp(c, ec);
		return;
	};
	if (kind == intkind::SOFT && dpl_of(ga) < c.cpl) {
		gp(c, ec);
		return;
	};
	if (ga & A_P == 0) {
		raise_ec(c, EX_NP, ec);
		return;
	};
	const gate32 = gtype & 8 != 0;
	const sel = (g.lo >> 16): u16;
	let off = (g.lo & 0xFFFF) | (g.hi & 0xFFFF0000);
	if (!gate32) off &= 0xFFFF;
	const sec = (sel & 0xFFFC): u32;
	if (sel & 0xFFFC == 0) {
		gp(c, 0);
		return;
	};
	const d = match (read_desc(c, sel)) {
	case let d: desc => yield d;
	case void =>
		gp(c, sec);
		return;
	};
	const a = desc_attr(d);
	if (a & (A_S | A_CODE) != A_S | A_CODE || dpl_of(a) > c.cpl) {
		gp(c, sec);
		return;
	};
	if (a & A_P == 0) {
		raise_ec(c, EX_NP, sec);
		return;
	};
	const sz: u32 = if (gate32) 4 else 2;
	const fl = eflags(c);
	const old_cs = c.s[CS], old_ss = c.s[SS], old_sp = sp_get(c);
	let pl = c.cpl;
	if (a & A_DC == 0 && dpl_of(a) < c.cpl) {
		// To a more privileged level, on its own stack.
		pl = dpl_of(a);
		if (!switch_stack(c, pl)) return;
		push386(c, old_ss, sz);
		push386(c, old_sp, sz);
	};
	push386(c, fl, sz);
	push386(c, old_cs, sz);
	push386(c, ret, sz);
	if (kind == intkind::EXC && has_code(n)) push386(c, c.fault_code, sz);
	if (c.fault >= 0) return;
	if (off > desc_limit(d)) {
		gp(c, 0);
		return;
	};
	set_cs(c, sel, d, pl);
	c.eip = off;
	c.int_kind = switch (kind) {
	case intkind::EXC => yield 0;
	case intkind::SOFT => yield 1;
	case intkind::HW => yield 2;
	};
	c.int_err = kind == intkind::EXC && has_code(n);
	c.flags &= ~(TF | 0x4000); // TF and NT
	if (gtype & 1 == 0) c.flags &= ~IF; // an interrupt gate
	c.flagsh &= ~3; // RF, VM
	c.halted = false;
};

// IRET: back from an interrupt, maybe to an outer level.
fn iret386(c: *cpu, sz: u32) void = {
	if (c.cr0 & 1 == 0) {
		const off = pop386(c, sz);
		const seg = pop386(c, sz): u16;
		const f = pop386(c, sz);
		if (c.fault >= 0) return;
		far_jump(c, seg, off);
		set_flags(c, f: u16);
		return;
	};
	if (c.flags & 0x4000 != 0) {
		gp(c, 0); // NT: a task return, which isn't done
		return;
	};
	const off = pop386(c, sz);
	const sel = pop386(c, sz): u16;
	const f = pop386(c, sz);
	if (c.fault >= 0) return;
	if (sz == 4 && f & 0x20000 != 0 && c.cpl == 0) {
		gp(c, 0); // back to virtual-8086 mode: not done
		return;
	};
	const rpl = (sel & 3): u8;
	if (!check_return_cs(c, sel, rpl)) return;
	const d = read_desc(c, sel) as desc;
	if (off > desc_limit(d)) {
		gp(c, 0);
		return;
	};
	let ss = 0u16, esp = 0u32;
	if (rpl > c.cpl) {
		esp = pop386(c, sz);
		ss = pop386(c, sz): u16;
		if (c.fault >= 0) return;
	};
	// Which flags may change depends on the level we are at now.
	const old_cpl = c.cpl;
	let keep: u16 = 0;
	if (old_cpl > 0) keep |= 0x3000; // IOPL
	if (old_cpl > iopl(c)) keep |= IF;
	set_cs(c, sel, d, rpl);
	c.eip = off;
	const nf = (f: u16 & 0x7FD5 & ~keep) | (c.flags & keep) | 2;
	c.lz_op = 0;
	c.flags = nf;
	if (sz == 4) c.flagsh = (c.flagsh & ~1u16) | ((f >> 16): u16 & 1);
	if (rpl > old_cpl) {
		if (!load_seg(c, SS, ss)) return;
		sp_set(c, esp);
		null_inner_segments(c);
	};
};

// The checks for a CS that RETF or IRET goes back to.
fn check_return_cs(c: *cpu, sel: u16, rpl: u8) bool = {
	const ec = (sel & 0xFFFC): u32;
	if (sel & 0xFFFC == 0) {
		gp(c, 0);
		return false;
	};
	if (rpl < c.cpl) {
		gp(c, ec);
		return false;
	};
	const d = match (read_desc(c, sel)) {
	case let d: desc => yield d;
	case void =>
		gp(c, ec);
		return false;
	};
	const a = desc_attr(d);
	const conforming = a & A_DC != 0;
	if (a & (A_S | A_CODE) != A_S | A_CODE ||
			(conforming && dpl_of(a) > rpl) ||
			(!conforming && dpl_of(a) != rpl)) {
		gp(c, ec);
		return false;
	};
	if (a & A_P == 0) {
		raise_ec(c, EX_NP, ec);
		return false;
	};
	return true;
};

// RETF (with n bytes of parameters to drop).
fn retf386(c: *cpu, sz: u32, n: u32) void = {
	const off = pop386(c, sz);
	const sel = pop386(c, sz): u16;
	if (c.fault >= 0) return;
	if (c.cr0 & 1 == 0) {
		far_jump(c, sel, off);
		sp_set(c, sp_add(c, sp_get(c), n));
		return;
	};
	const rpl = (sel & 3): u8;
	if (!check_return_cs(c, sel, rpl)) return;
	const d = read_desc(c, sel) as desc;
	if (off > desc_limit(d)) {
		gp(c, 0);
		return;
	};
	sp_set(c, sp_add(c, sp_get(c), n));
	if (rpl == c.cpl) {
		set_cs(c, sel, d, rpl);
		c.eip = off;
		return;
	};
	// Back to an outer level, and its stack.
	const esp = pop386(c, sz);
	const ss = pop386(c, sz): u16;
	if (c.fault >= 0) return;
	set_cs(c, sel, d, rpl);
	c.eip = off;
	if (!load_seg(c, SS, ss)) return;
	sp_set(c, esp + n);
	null_inner_segments(c);
};

// A far JMP or CALL to sel:off (call: push the return address with
// operand size sz first).
fn far_transfer(c: *cpu, sel: u16, off: u32, call: bool, sz: u32) void = {
	if (c.cr0 & 1 == 0) {
		if (call) {
			push386(c, c.s[CS], sz);
			push386(c, c.eip, sz);
		};
		far_jump(c, sel, off);
		return;
	};
	const ec = (sel & 0xFFFC): u32;
	if (sel & 0xFFFC == 0) {
		gp(c, 0);
		return;
	};
	const d = match (read_desc(c, sel)) {
	case let d: desc => yield d;
	case void =>
		gp(c, ec);
		return;
	};
	const a = desc_attr(d), dpl = dpl_of(a), rpl = (sel & 3): u8;
	if (a & (A_S | A_CODE) == A_S | A_CODE) {
		const ok = if (a & A_DC != 0) dpl <= c.cpl
			else rpl <= c.cpl && dpl == c.cpl;
		if (!ok) {
			gp(c, ec);
			return;
		};
		if (a & A_P == 0) {
			raise_ec(c, EX_NP, ec);
			return;
		};
		if (off > desc_limit(d)) {
			gp(c, 0);
			return;
		};
		if (call) {
			push386(c, c.s[CS], sz);
			push386(c, c.eip, sz);
			if (c.fault >= 0) return;
		};
		set_cs(c, sel, d, c.cpl);
		c.eip = off;
		return;
	};
	// A call gate (4: 16-bit, 0Ch: 32-bit).
	const t = a & 0x1F;
	if (t != 0x04 && t != 0x0C) {
		gp(c, ec); // TSSs and task gates: task switches aren't done
		return;
	};
	if (dpl < c.cpl || dpl < rpl) {
		gp(c, ec);
		return;
	};
	if (a & A_P == 0) {
		raise_ec(c, EX_NP, ec);
		return;
	};
	const gate32 = t == 0x0C;
	const tsel = (d.lo >> 16): u16;
	let toff = (d.lo & 0xFFFF) | (d.hi & 0xFFFF0000);
	if (!gate32) toff &= 0xFFFF;
	const params = d.hi & 0x1F;
	const tec = (tsel & 0xFFFC): u32;
	if (tsel & 0xFFFC == 0) {
		gp(c, 0);
		return;
	};
	const td = match (read_desc(c, tsel)) {
	case let d: desc => yield d;
	case void =>
		gp(c, tec);
		return;
	};
	const ta = desc_attr(td), tdpl = dpl_of(ta);
	if (ta & (A_S | A_CODE) != A_S | A_CODE || tdpl > c.cpl) {
		gp(c, tec);
		return;
	};
	if (ta & A_P == 0) {
		raise_ec(c, EX_NP, tec);
		return;
	};
	if (toff > desc_limit(td)) {
		gp(c, 0);
		return;
	};
	const gsz: u32 = if (gate32) 4 else 2;
	if (!call) {
		if (ta & A_DC == 0 && tdpl != c.cpl) {
			gp(c, tec);
			return;
		};
		set_cs(c, tsel, td, c.cpl);
		c.eip = toff;
		return;
	};
	const old_cs = c.s[CS], old_eip = c.eip;
	if (ta & A_DC == 0 && tdpl < c.cpl) {
		// To an inner level: new stack, with the parameters copied.
		const old_ss = c.s[SS], old_sp = sp_get(c);
		const old_base = seg_base(c, SS);
		const oldbig = stack32(c);
		if (!switch_stack(c, tdpl)) return;
		push386(c, old_ss, gsz);
		push386(c, old_sp, gsz);
		for (let i = params; i > 0; i -= 1) {
			const at = old_sp + (i - 1) * gsz;
			const at = if (oldbig) at else at & 0xFFFF;
			push386(c, lin_read(c, old_base + at, gsz), gsz);
		};
		push386(c, old_cs, gsz);
		push386(c, old_eip, gsz);
		if (c.fault >= 0) return;
		set_cs(c, tsel, td, tdpl);
		c.eip = toff;
		return;
	};
	push386(c, old_cs, gsz);
	push386(c, old_eip, gsz);
	if (c.fault >= 0) return;
	set_cs(c, tsel, td, c.cpl);
	c.eip = toff;
};

// ---- I/O permission ----

// Whether the program may use ports p..p+sz-1: always at CPL <= IOPL,
// otherwise as the TSS's I/O bitmap says.
fn io_ok(c: *cpu, p: u16, sz: u32) bool = {
	if (c.cr0 & 1 == 0 || c.cpl <= iopl(c)) return true;
	const t = c.tr_attr & 0xF;
	if (t == 0x9 || t == 0xB) {
		if (c.tr_limit >= 0x67) {
			const map = lin_read(c, c.tr_base + 0x66, 2);
			const at = map + p: u32 / 8;
			if (at + 1 <= c.tr_limit) {
				const bits = lin_read(c, c.tr_base + at, 2);
				const m = ((1u32 << sz: u8) - 1) << (p & 7): u8;
				if (bits & m == 0) return true;
			};
		};
	};
	gp(c, 0);
	return false;
};

// Instructions only the kernel (CPL 0) may use.
fn privileged(c: *cpu) bool = {
	if (c.cr0 & 1 == 0 || c.cpl == 0) return true;
	gp(c, 0);
	return false;
};

// ---- 0F 00: SLDT, STR, LLDT, LTR, VERR, VERW ----

fn group6(c: *cpu) void = {
	modrm386(c);
	if (c.cr0 & 1 == 0) return raise(c, EX_UD);
	switch (c.reg) {
	case 0, 1 => // SLDT, STR
		const v = if (c.reg == 0) c.ldtr else c.tr;
		if (c.md == 3) setreg(c, c.rm, v, osz(c)) else rm_set(c, v, 2);
	case 2 => // LLDT
		if (!privileged(c)) return;
		const sel = rm_get(c, 2): u16;
		if (c.fault >= 0) return;
		if (sel & 0xFFFC == 0) {
			c.ldtr = sel;
			c.ldt_base = 0;
			c.ldt_limit = 0;
			return;
		};
		const ec = (sel & 0xFFFC): u32;
		if (sel & 4 != 0) return gp(c, ec);
		const d = match (read_desc(c, sel)) {
		case let d: desc => yield d;
		case void => return gp(c, ec);
		};
		const a = desc_attr(d);
		if (a & 0x1F != 0x02) return gp(c, ec);
		if (a & A_P == 0) return raise_ec(c, EX_NP, ec);
		c.ldtr = sel;
		c.ldt_base = desc_base(d);
		c.ldt_limit = desc_limit(d);
	case 3 => // LTR: an available TSS, which becomes busy
		if (!privileged(c)) return;
		const sel = rm_get(c, 2): u16;
		if (c.fault >= 0) return;
		const ec = (sel & 0xFFFC): u32;
		if (sel & 0xFFFC == 0) return gp(c, 0);
		if (sel & 4 != 0) return gp(c, ec);
		const d = match (read_desc(c, sel)) {
		case let d: desc => yield d;
		case void => return gp(c, ec);
		};
		const a = desc_attr(d);
		if (a & 0x1F != 0x01 && a & 0x1F != 0x09) return gp(c, ec);
		if (a & A_P == 0) return raise_ec(c, EX_NP, ec);
		match (desc_addr(c, sel)) {
		case let at: u32 => lin_write(c, at + 5, ((a | 2) & 0xFF): u32, 1);
		case void => void;
		};
		c.tr = sel;
		c.tr_base = desc_base(d);
		c.tr_limit = desc_limit(d);
		c.tr_attr = a | 2;
	case 4, 5 => // VERR, VERW
		const sel = rm_get(c, 2): u16;
		if (c.fault >= 0) return;
		let ok = false;
		if (sel & 0xFFFC != 0) match (read_desc(c, sel)) {
		case let d: desc =>
			const a = desc_attr(d), rpl = (sel & 3): u8;
			const maxpl = if (rpl > c.cpl) rpl else c.cpl;
			const conforming = a & (A_CODE | A_DC) == A_CODE | A_DC;
			if (a & A_S != 0 && (conforming || dpl_of(a) >= maxpl)) {
				ok = if (c.reg == 4) a & A_CODE == 0 || a & A_RW != 0
					else a & A_CODE == 0 && a & A_RW != 0;
			};
		case void => void;
		};
		setf(c, ZF, ok);
	case => raise(c, EX_UD);
	};
};

// LAR and LSL: a descriptor's rights or limit, if the program may see it.
fn lar_lsl(c: *cpu, lsl: bool) void = {
	modrm386(c);
	if (c.cr0 & 1 == 0) return raise(c, EX_UD);
	const sel = rm_get(c, 2): u16;
	if (c.fault >= 0) return;
	const sz = osz(c);
	setf(c, ZF, false);
	if (sel & 0xFFFC == 0) return;
	const d = match (read_desc(c, sel)) {
	case let d: desc => yield d;
	case void => return;
	};
	const a = desc_attr(d), rpl = (sel & 3): u8;
	if (a & A_S == 0) {
		// System descriptors: TSSs and LDTs for both, gates for LAR.
		const t = a & 0xF;
		const valid = switch (t) {
		case 1, 2, 3, 9, 0xB => yield true;
		case 4, 5, 0xC => yield !lsl;
		case => yield false;
		};
		if (!valid) return;
	};
	const conforming = a & (A_CODE | A_DC) == A_CODE | A_DC;
	const maxpl = if (rpl > c.cpl) rpl else c.cpl;
	if (!conforming && dpl_of(a) < maxpl) return;
	setf(c, ZF, true);
	if (lsl) {
		setreg(c, c.reg, desc_limit(d), sz);
	} else {
		setreg(c, c.reg, d.hi & 0x00FFFF00, sz);
	};
};

// ARPL: raise a selector's RPL to at least another's.
fn arpl(c: *cpu) void = {
	modrm386(c);
	if (c.cr0 & 1 == 0) return raise(c, EX_UD);
	const v = rm_get(c, 2);
	if (c.fault >= 0) return;
	const r = c.r[c.reg] & 3;
	if (v & 3 < r) {
		rm_set(c, (v & ~3u32) | r, 2);
		setf(c, ZF, true);
	} else {
		setf(c, ZF, false);
	};
};

// A write to CR0: entering protected mode takes the segment bases from
// the real-mode selectors; paging on or off empties the TLB.
fn set_cr0(c: *cpu, v: u32) void = {
	const old = c.cr0;
	if (old & 1 == 0 && v & 1 != 0) {
		for (let i = 0z; i < 6; i += 1) c.sbase[i] = seg_base(c, i);
		c.stale = 0;
		c.cpl = 0;
	} else if (old & 1 != 0 && v & 1 == 0) {
		// The caches stay as they are until each segment is loaded.
		c.stale = 0x3F;
		c.stale_sel = c.s;
		c.cpl = 0;
	};
	c.cr0 = v | 0x10;
	if ((old ^ c.cr0) & 0x80000001 != 0) tlb_flush(c);
};

// The PC's hardware interrupts come through here on a 386.
fn hw_interrupt386(c: *cpu, n: u8) void = {
	if (c.eip: u16 != c.ip) c.eip = c.ip;
	c.fault = -1;
	c.seg_dirty = false;
	deliver(c, n, c.eip, intkind::HW);
	if (c.fault >= 0) {
		const n = c.fault: u8;
		c.fault = -1;
		seg_restore(c);
		deliver(c, n, c.eip, intkind::EXC);
		c.fault = -1;
	};
	c.seg_dirty = false;
	c.ip = c.eip: u16;
};

// An immediate of the operand size.
fn imm(c: *cpu, sz: u32) u32 = ifetch(c, sz);

// Loads a segment register as MOV would (for a DPMI host switching
// modes); false after a fault, which is then cleared.
export fn load_segment(c: *cpu, sreg: size, sel: u16) bool = {
	c.fault = -1;
	const ok = load_seg(c, sreg, sel);
	c.fault = -1;
	c.seg_dirty = false;
	return ok;
};
