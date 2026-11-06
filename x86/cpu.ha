// Shifu — an Intel 8086/8088 or 80386 CPU in pure Hare.
//
// The 8088 is the original IBM PC's: 1 MiB of memory addressed as
// segment * 16 + offset, wrapping at 0xFFFFF. The 386 (i386.ha) adds 32-bit
// registers and operands, FS and GS, the 186/286/386 instructions and the
// exceptions a 386 raises in real mode. One call to [[step]] runs one
// instruction (or one round of a REP string instruction, so interrupts can
// get in between rounds, like on the real chip).

use fmt;

// Flag bits.
export def CF: u16 = 0x0001;
export def PF: u16 = 0x0004;
export def AF: u16 = 0x0010;
export def ZF: u16 = 0x0040;
export def SF: u16 = 0x0080;
export def TF: u16 = 0x0100;
export def IF: u16 = 0x0200;
export def DF: u16 = 0x0400;
export def OF: u16 = 0x0800;

// Word registers, in the order the instruction encoding numbers them.
export def AX: size = 0;
export def CX: size = 1;
export def DX: size = 2;
export def BX: size = 3;
export def SP: size = 4;
export def BP: size = 5;
export def SI: size = 6;
export def DI: size = 7;

// Segment registers, in encoding order (FS and GS are the 386's).
export def ES: size = 0;
export def CS: size = 1;
export def SS: size = 2;
export def DS: size = 3;
export def FS: size = 4;
export def GS: size = 5;

// The memory: 16 MiB, as much as a 386SX or a 286 AT can address. The
// 8088 (and a 386 with the A20 gate closed) sees the first 1 MiB, wrapping.
export def MEMSIZE: size = 0x1000000;

// Which CPU this is.
export type model = enum {
	I8088,
	I386,
};

// Reads one byte from an I/O port.
export type port_in_fn = fn(c: *cpu, port: u16) u8;
// Writes one byte to an I/O port.
export type port_out_fn = fn(c: *cpu, port: u16, v: u8) void;
// Called for INT n before the CPU takes the interrupt itself. Return true
// when the interrupt was handled in Hare (that is how Shifu will do DOS
// and BIOS services), false to let the CPU jump through the vector table.
export type int_fn = fn(c: *cpu, n: u8) bool;
// Called by the emulator-only instruction FE 38 nn nn ("callback nnnn"),
// which ROM code uses to call into Hare. FE /7 is an undefined opcode on
// the real 8088, so no real program uses it.
export type callback_fn = fn(c: *cpu, n: u16) void;
// Memory-mapped hardware in A0000-AFFFF (the EGA/VGA planes): when set,
// reads and writes there go through these instead of plain memory.
export type mmio_read_fn = fn(c: *cpu, a: u32) u8;
export type mmio_write_fn = fn(c: *cpu, a: u32, v: u8) void;

export type cpu = struct {
	model: model,
	ip: u16,
	// r, rh, s, flags and flagsh lie together, like [[snapshot]], so a
	// 386 instruction can save them quickly (see step386).
	r: [8]u16,     // the 16-bit registers (low halves of EAX...)
	rh: [8]u16,    // the 386's high halves
	s: [6]u16,
	flags: u16,
	flagsh: u16,   // EFLAGS bits 16-31
	// Lazy flags (the 386): the last ALU operation (LZ_*), its operands
	// and result. While lz_op isn't 0 the arithmetic flags in flags are
	// stale; [[fsync]] works them out when something reads them.
	lz_op: u32,
	lz_a: u32,
	lz_b: u32,
	lz_c: u32,
	lz_res: u32,
	lz_sz: u32,
	mem: []u8,
	// The same memory without bounds checks, for the hot paths (they
	// mask addresses to 16 MiB themselves).
	memp: *[*]u8,
	// Bytes of the current instruction that can be fetched straight
	// from memory: EIP below this (0: always the slow way).
	fend: u32,
	// Physical addresses wrap at this mask: 0xFFFFF on an 8088 or with
	// the A20 gate closed, 0xFFFFFF with it open.
	amask: u32,
	// 386 control and system registers.
	cr0: u32,
	cr2: u32,
	cr3: u32,
	dr: [8]u32,
	gdt_base: u32,
	gdt_limit: u16,
	idt_base: u32,
	idt_limit: u16,

	// The 386's segment descriptor caches (see pmode.ha): base, limit in
	// bytes, and the descriptor's access byte | flags << 8. In real mode
	// the base is always selector * 16; the limit still counts (that is
	// how "unreal mode" works).
	sbase: [6]u32,
	slimit: [6]u32,
	sattr: [6]u16,
	// Back in real mode, a segment keeps its protected-mode base until
	// it is loaded again (bit i set while s[i] is still stale_sel[i]).
	stale: u8,
	stale_sel: [6]u16,
	cpl: u8,
	ldtr: u16,
	ldt_base: u32,
	ldt_limit: u32,
	tr: u16,
	tr_base: u32,
	tr_limit: u32,
	tr_attr: u16,
	// The caches before this instruction changed them (to undo a fault).
	seg_saved: segsnap,
	seg_dirty: bool,
	// The error code of the exception being raised.
	fault_code: u32,
	// Delivering an exception (a fault now is a double fault).
	delivering: int,
	// Shut down after a triple fault.
	shutdown: bool,
	// How the last protected-mode interrupt came (0 an exception, 1 INT n,
	// 2 hardware) and whether it pushed an error code: a DPMI host's
	// handlers need to know, as IRQ 0-7 share vectors with exceptions.
	int_kind: u8,
	int_err: bool,
	// Paging: a small TLB of linear page -> physical page | rights.
	tlb_tag: [256]u32,
	tlb_val: [256]u32,

	// HLT was executed; [[step]] does nothing until an interrupt.
	halted: bool,
	// The last step was one round of a REP instruction with more to go.
	in_rep: bool,
	// No hardware interrupt before the next instruction (after STI, or
	// after loading SS so the SP load that follows is safe).
	inhibit: bool,
	// Instructions executed so far.
	count: u64,
	// The 387 beside the 386 (fpu.ha).
	fpu: fpu,

	port_in: nullable *port_in_fn,
	port_out: nullable *port_out_fn,
	int_hook: nullable *int_fn,
	callback: nullable *callback_fn,
	mmio_read: nullable *mmio_read_fn,
	mmio_write: nullable *mmio_write_fn,
	// Free for the program that owns the CPU (the PC around it).
	user: nullable *opaque,

	// For the test runner: when set, every memory write is logged as
	// (address << 8 | old value).
	log_writes: bool,
	writes: []u32,
	// For debugging: writes to [watch_lo, watch_hi) are printed with the
	// instruction that made them (set log_writes too).
	watch_lo: u32,
	watch_hi: u32,
	// A second range (no dump), and memory to show at the first dump.
	watch2_lo: u32,
	watch2_hi: u32,
	peek_lo: u32,
	peek_n: u32,
	watch_dumped: int,
	// For debugging: the last 64 instructions' CS and EIP.
	ring_on: bool,
	// For debugging: the last 16 changes of CS (from CS:EIP, to CS:EIP,
	// protected mode or not).
	jumps: [16](u16, u32, u16, u32, bool),
	jump_n: size,
	last_cs: u16,
	last_eip: u32,
	exc_logged: int,
	ring_n: size,
	ring: [64]u64,

	// Decoding state for the current instruction.
	start_ip: u16,
	seg_ovr: int,
	rep: u8,
	md: size,
	reg: size,
	rm: size,
	ea_seg: u16,
	ea_off: u16,

	// The 386's decoding state.
	eip: u32,
	start_eip: u32,
	// The code segment's base, and whether fetches can go straight to
	// memory (no paging), worked out once per instruction.
	cbase: u32,
	cfast: bool,
	o32: bool,      // operand size 32 (66h prefix in real mode)
	a32: bool,      // address size 32 (67h)
	lock: bool,
	sreg: size,     // the memory operand's segment register
	ea: u32,        // its offset
	fault: int,     // an exception raised by this instruction, or -1
	saved: snapshot,
};

export type segsnap = struct {
	s: [6]u16,
	sbase: [6]u32,
	slimit: [6]u32,
	sattr: [6]u16,
	cpl: u8,
};

// The registers at the start of an instruction, put back when it faults.
export type snapshot = struct {
	r: [8]u16,
	rh: [8]u16,
	s: [6]u16,
	flags: u16,
	flagsh: u16,
	lz_op: u32,
	lz_a: u32,
	lz_b: u32,
	lz_c: u32,
	lz_res: u32,
	lz_sz: u32,
};

// Makes an 8088 with zeroed memory, in the state the 8086 has after reset
// (CS:IP = FFFF:0000). See [[set_model]] for a 386.
export fn new() (*cpu | nomem) = {
	let mem: []u8 = alloc([0u8...], MEMSIZE)?;
	let c = match (alloc(cpu { mem = mem, memp = &mem[0]: *[*]u8,
		amask = 0xFFFFF, fault = -1, ... })) {
	case let c: *cpu => yield c;
	case nomem =>
		free(mem);
		return nomem;
	};
	reset(c);
	return c;
};

export fn destroy(c: *cpu) void = {
	free(c.mem);
	free(c.writes);
	free(c);
};

// Resets the registers (memory is left alone).
export fn reset(c: *cpu) void = {
	c.r = [0...];
	c.rh = [0...];
	c.s = [0...];
	c.s[CS] = 0xFFFF;
	c.ip = 0;
	c.flags = if (c.model == model::I386) 0x0002 else 0xF002;
	c.flagsh = 0;
	c.lz_op = 0;
	c.cr0 = if (c.model == model::I386) 0x10 else 0;
	c.idt_base = 0;
	c.idt_limit = 0x3FF;
	c.gdt_base = 0;
	c.gdt_limit = 0xFFFF;
	c.sbase = [0...];
	c.sbase[CS] = 0xFFFF0;
	c.slimit = [0xFFFF...];
	c.sattr = [0x93...];   // present, writable data, accessed
	c.sattr[CS] = 0x9B;    // present, readable code, accessed
	c.stale = 0;
	c.cpl = 0;
	c.ldtr = 0;
	c.tr = 0;
	c.tr_attr = 0;
	c.tr_limit = 0;
	c.delivering = 0;
	c.shutdown = false;
	tlb_flush(c);
	c.fault = -1;
	c.halted = false;
	c.in_rep = false;
	fpu_reset(&c.fpu);
};

// Makes the CPU an 8088 or a 386 (and resets it).
export fn set_model(c: *cpu, m: model) void = {
	c.model = m;
	reset(c);
};

// Opens or closes the A20 gate: with it closed, addresses wrap at 1 MiB
// like on an 8088 (some old programs need that).
export fn set_a20(c: *cpu, on: bool) void = {
	c.amask = if (on) 0xFFFFFF else 0xFFFFF;
};

export fn a20(c: *cpu) bool = c.amask == 0xFFFFFF;

// Sets the flags register the way the CPU stores it. On the 8086 bits
// 12-15 and bit 1 always read as 1, bits 3 and 5 as 0; on a 386 in real
// mode IOPL and NT (bits 12-14) can be set, and bit 15 is always 0 (that
// is how programs tell them apart).
export fn set_flags(c: *cpu, v: u16) void = {
	c.lz_op = 0;
	if (c.model == model::I386) {
		c.flags = (v & 0x7FD5) | 0x0002;
	} else {
		c.flags = (v & 0x0FD5) | 0xF002;
	};
};

// ---- Memory ----

// The physical address of seg:off.
// (Up to 10FFEFh: [[rb]] and [[wb]] wrap it at 1 MiB unless A20 is open.)
export fn linear(seg: u16, off: u16) u32 = (seg: u32 << 4) + off: u32;

export fn rb(c: *cpu, a: u32) u8 = {
	const a = a & c.amask;
	if (a >> 16 == 0xA) match (c.mmio_read) {
	case null => void;
	case let f: *mmio_read_fn => return f(c, a);
	};
	return c.mem[a];
};

export fn wb(c: *cpu, a: u32, v: u8) void = {
	const a = a & c.amask;
	if (a >> 16 == 0xA) match (c.mmio_write) {
	case null => void;
	case let f: *mmio_write_fn =>
		f(c, a, v);
		return;
	};
	if (c.log_writes) {
		if (c.watch_hi > 0) {
			if (a >= c.watch_lo && a < c.watch_hi) watch_hit(c, a, v);
			if (a >= c.watch2_lo && a < c.watch2_hi) watch_hit(c, a, v);
		} else {
			append(c.writes, a << 8 | c.mem[a]: u32)!;
		};
	};
	c.mem[a] = v;
};

fn watch_hit(c: *cpu, a: u32, v: u8) void = {
	const ch: rune = if (v >= 0x20 && v < 0x7F) v: rune else '.';
	fmt::errorf("SKRIV {:_05X} = {:_02X} '{}' fra {:_04X}:{:_04X} kode:",
		a, v, ch, c.s[CS], c.start_eip)!;
	const base = c.cbase + c.start_eip;
	for (let i = 0u32; i < 48; i += 1) {
		fmt::errorf(" {:_02X}", c.mem[(base - 16 + i) & 0xFFFFFF])!;
	};
	fmt::errorln()!;
	// The first time: everything, so we see where it came from.
	if (c.watch_dumped < 300 && a == c.watch_lo) {
		c.watch_dumped += 1;
		dump(c);
		if (c.peek_n > 0 && c.watch_dumped == 1) {
			fmt::errorf("PEEK {:_06X}:", c.peek_lo)!;
			for (let i = 0u32; i < c.peek_n; i += 1) {
				if (i % 4 == 0) fmt::errorf(" ")!;
				fmt::errorf("{:_02X}", c.mem[(c.peek_lo + i) & 0xFFFFFF])!;
			};
			fmt::errorln()!;
		};
	};
};

// Prints the registers, the last instructions run and the code at CS:EIP
// to stderr (for debugging).
export fn dump(c: *cpu) void = {
	fsync(c);
	fmt::errorfln("CPU: CS:EIP={:_04X}:{:_08X} cr0={:_08X} cpl={} flag={:_04X}",
		c.s[CS], c.eip, c.cr0, c.cpl, c.flags)!;
	const names = ["EAX", "ECX", "EDX", "EBX", "ESP", "EBP", "ESI", "EDI"];
	for (let i = 0z; i < 8; i += 1) {
		fmt::errorf("{}={:_08X} ", names[i], c.rh[i]: u32 << 16 | c.r[i])!;
	};
	fmt::errorln()!;
	const sn = ["ES", "CS", "SS", "DS", "FS", "GS"];
	for (let i = 0z; i < 6; i += 1) {
		fmt::errorf("{}={:_04X}(base {:_08X}) ", sn[i], c.s[i], c.sbase[i])!;
	};
	fmt::errorln()!;
	const base = if (c.cr0 & 1 == 0) c.s[CS]: u32 << 4 else c.sbase[CS];
	fmt::errorf("kode fra -16:")!;
	for (let i = 0u32; i < 64; i += 1) {
		fmt::errorf(" {:_02X}", c.mem[(base + c.eip - 16 + i) & 0xFFFFFF])!;
	};
	fmt::errorln()!;
	if (c.ring_on) {
		fmt::errorf("sidste:")!;
		const n = if (c.ring_n < 64) c.ring_n else 64z;
		for (let i = c.ring_n - n; i < c.ring_n; i += 1) {
			const e = c.ring[i & 63];
			fmt::errorf(" {:_04X}:{:_04X}", (e >> 32): u16, e: u32)!;
		};
		fmt::errorln()!;
		fmt::errorf("CS-skift:")!;
		const n = if (c.jump_n < 16) c.jump_n else 16z;
		for (let i = c.jump_n - n; i < c.jump_n; i += 1) {
			const (fc, fe, tc, te, pm) = c.jumps[i & 15];
			fmt::errorf(" {:_04X}:{:_04X}->{:_04X}:{:_04X}{}", fc, fe, tc, te,
				if (pm) "" else "r")!;
		};
		fmt::errorln()!;
	};
};

// Reads a byte at seg:off.
export fn read8(c: *cpu, seg: u16, off: u16) u8 = rb(c, linear(seg, off));

// Reads a word at seg:off. The high byte comes from off + 1 in the same
// segment, so a word at offset FFFF wraps to offset 0.
export fn read16(c: *cpu, seg: u16, off: u16) u16 =
	rb(c, linear(seg, off)): u16 | rb(c, linear(seg, off + 1)): u16 << 8;

export fn write8(c: *cpu, seg: u16, off: u16, v: u8) void =
	wb(c, linear(seg, off), v);

export fn write16(c: *cpu, seg: u16, off: u16, v: u16) void = {
	wb(c, linear(seg, off), v: u8);
	wb(c, linear(seg, off + 1), (v >> 8): u8);
};

fn fetch8(c: *cpu) u8 = {
	const v = read8(c, c.s[CS], c.ip);
	c.ip += 1;
	return v;
};

fn fetch16(c: *cpu) u16 = {
	const v = read16(c, c.s[CS], c.ip);
	c.ip += 2;
	return v;
};

// A sign-extended 8-bit displacement or immediate.
fn fetch8s(c: *cpu) u16 = fetch8(c): i8: i16: u16;

// ---- Registers ----

// 8-bit registers: 0-3 are AL CL DL BL, 4-7 are AH CH DH BH.
export fn get8(c: *cpu, r: size) u8 = {
	if (r < 4) return c.r[r]: u8;
	return (c.r[r - 4] >> 8): u8;
};

export fn set8(c: *cpu, r: size, v: u8) void = {
	if (r < 4) {
		c.r[r] = (c.r[r] & 0xFF00) | v: u16;
	} else {
		c.r[r - 4] = (c.r[r - 4] & 0x00FF) | v: u16 << 8;
	};
};

fn flag(c: *cpu, f: u16) bool = {
	if (c.lz_op != 0 && f & 0x08D5 != 0) fsync(c);
	return c.flags & f != 0;
};

fn setf(c: *cpu, f: u16, on: bool) void = {
	if (c.lz_op != 0 && f & 0x08D5 != 0) fsync(c);
	if (on) {
		c.flags |= f;
	} else {
		c.flags &= ~f;
	};
};

// ---- Stack and interrupts ----

export fn push(c: *cpu, v: u16) void = {
	c.r[SP] -= 2;
	write16(c, c.s[SS], c.r[SP], v);
};

export fn pop(c: *cpu) u16 = {
	const v = read16(c, c.s[SS], c.r[SP]);
	c.r[SP] += 2;
	return v;
};

// Takes interrupt n through the vector table at 0000:0000, returning to
// the current CS:IP.
export fn interrupt(c: *cpu, n: u8) void = {
	if (c.model == model::I386) return hw_interrupt386(c, n);
	fsync(c);
	push(c, c.flags);
	c.flags &= ~(IF | TF);
	push(c, c.s[CS]);
	push(c, c.ip);
	c.ip = read16(c, 0, n: u16 * 4);
	c.s[CS] = read16(c, 0, n: u16 * 4 + 2);
	c.halted = false;
};

// A software interrupt (INT n, INT3, INTO): the hook gets the first go.
fn soft_int(c: *cpu, n: u8) void = {
	match (c.int_hook) {
	case null => void;
	case let f: *int_fn =>
		if (f(c, n)) return;
	};
	interrupt(c, n);
};

// ---- Decoding ----

// The segment a memory operand uses: the override prefix if there is one.
fn dseg(c: *cpu, default: size) u16 = {
	if (c.seg_ovr >= 0) return c.s[c.seg_ovr: size];
	return c.s[default];
};

// Reads a ModR/M byte and any displacement, working out the effective
// address for memory operands.
fn modrm(c: *cpu) void = {
	const b = fetch8(c);
	c.md = (b >> 6): size;
	c.reg = ((b >> 3) & 7): size;
	c.rm = (b & 7): size;
	if (c.md == 3) return;

	let off = 0u16;
	let seg = DS;
	switch (c.rm) {
	case 0 => off = c.r[BX] + c.r[SI];
	case 1 => off = c.r[BX] + c.r[DI];
	case 2 =>
		off = c.r[BP] + c.r[SI];
		seg = SS;
	case 3 =>
		off = c.r[BP] + c.r[DI];
		seg = SS;
	case 4 => off = c.r[SI];
	case 5 => off = c.r[DI];
	case 6 =>
		if (c.md == 0) {
			off = fetch16(c);
		} else {
			off = c.r[BP];
			seg = SS;
		};
	case 7 => off = c.r[BX];
	case => abort();
	};
	if (c.md == 1) {
		off += fetch8s(c);
	} else if (c.md == 2) {
		off += fetch16(c);
	};
	c.ea_off = off;
	c.ea_seg = dseg(c, seg);
};

fn get_rm8(c: *cpu) u8 = {
	if (c.md == 3) return get8(c, c.rm);
	return read8(c, c.ea_seg, c.ea_off);
};

fn get_rm16(c: *cpu) u16 = {
	if (c.md == 3) return c.r[c.rm];
	return read16(c, c.ea_seg, c.ea_off);
};

fn set_rm8(c: *cpu, v: u8) void = {
	if (c.md == 3) {
		set8(c, c.rm, v);
	} else {
		write8(c, c.ea_seg, c.ea_off, v);
	};
};

fn set_rm16(c: *cpu, v: u16) void = {
	if (c.md == 3) {
		c.r[c.rm] = v;
	} else {
		write16(c, c.ea_seg, c.ea_off, v);
	};
};

// Runs one instruction.
export fn step(c: *cpu) void = {
	if (c.halted) return;
	if (c.model == model::I386) return step386(c);
	c.in_rep = false;
	c.inhibit = false;
	const trap = c.flags & TF != 0;
	c.start_ip = c.ip;
	c.seg_ovr = -1;
	c.rep = 0;
	let op = fetch8(c);
	for (true) {
		switch (op) {
		case 0x26, 0x2E, 0x36, 0x3E =>
			c.seg_ovr = ((op >> 3) & 3): int;
		case 0xF2, 0xF3 =>
			c.rep = op;
		case 0xF0, 0xF1 => void; // LOCK
		case =>
			break;
		};
		op = fetch8(c);
	};
	exec(c, op);
	c.count += 1;
	// Trap flag: single-step interrupt after the instruction (DEBUG's T).
	if (trap && !c.in_rep) interrupt(c, 1);
};

// Whether the CPU would take a hardware interrupt right now (IF set, and
// not just after STI or a load of SS). The 8259 PIC supplies the vector.
export fn irq_ready(c: *cpu) bool = c.flags & IF != 0 && !c.inhibit;

// Runs a whole instruction, including every round of a REP prefix.
export fn step_full(c: *cpu) void = {
	step(c);
	for (c.in_rep) step(c);
};
