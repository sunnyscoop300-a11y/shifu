// Shifu — an XMS 3.0 driver, like HIMEM.SYS: the memory above 1 MiB
// handed out in blocks (EMBs) that programs move data to and from, or
// lock to get a physical address for protected mode; the HMA; and the
// A20 gate. Programs find it through INT 2Fh AX=4310h and call it far.

use x86;

// The driver's entry point (F000:1100): a short jump and three NOPs, so
// others can hook it as the spec allows, then callback 10Dh and RETF.
def XMS_ENTRY: u16 = 0x1100;

// Extended memory from the end of the HMA (1 MiB + 64 KiB) to 16 MiB,
// less the DPMI host's 256 KiB at the top (dpmi.ha).
def XMS_START_KB: u32 = 1088;
def XMS_END_KB: u32 = 16128;
def XMS_HANDLES: size = 64;

export type emb = struct {
	handle: u16,
	start: u32,   // KiB
	kb: u32,      // KiB
	locks: u8,
};

export type xms = struct {
	blocks: []emb,
	next_handle: u16,
	hma_used: bool,
	a20_global: bool,
	a20_local: u32,
};

fn xms_init(m: *machine) void = {
	const c = m.cpu;
	const a = x86::linear(ROMSEG, XMS_ENTRY);
	const code: [_]u8 = [
		0xEB, 0x03, 0x90, 0x90, 0x90,  // jmp short +3; nop; nop; nop
		0xFE, 0x38, 0x0D, 0x01,        // callback 10Dh
		0xCB,                          // retf
	];
	c.mem[a..a + len(code)] = code;
	m.xms.next_handle = 1;
};

fn xms_free(m: *machine) void = free(m.xms.blocks);

fn xms_present(m: *machine) bool = m.cpu.model == x86::model::I386;

fn find_emb(m: *machine, h: u16) (size | void) = {
	for (let i = 0z; i < len(m.xms.blocks); i += 1) {
		if (m.xms.blocks[i].handle == h) return i;
	};
};

// (largest free block, total free), in KiB.
fn xms_free_kb(m: *machine) (u32, u32) = {
	let at = XMS_START_KB, largest = 0u32, total = 0u32;
	for (let b .. m.xms.blocks) {
		const gap = b.start - at;
		if (gap > largest) largest = gap;
		total += gap;
		at = b.start + b.kb;
	};
	const gap = XMS_END_KB - at;
	if (gap > largest) largest = gap;
	total += gap;
	return (largest, total);
};

// Where a block of kb KiB fits (first fit), and the index to keep the
// list sorted.
fn xms_place(m: *machine, kb: u32, skip: (size | void)) ((u32, size) | void) = {
	let at = XMS_START_KB;
	for (let i = 0z; i < len(m.xms.blocks); i += 1) {
		if (skip is size && skip as size == i) continue;
		const b = m.xms.blocks[i];
		if (b.start - at >= kb) return (at, i);
		at = b.start + b.kb;
	};
	if (XMS_END_KB - at >= kb) return (at, len(m.xms.blocks));
};

fn xms_alloc(m: *machine, kb: u32) (u16 | u8) = {
	if (len(m.xms.blocks) >= XMS_HANDLES) return 0xA1u8;
	const (at, i) = match (xms_place(m, kb, void)) {
	case let p: (u32, size) => yield p;
	case void => return 0xA0u8;
	};
	const h = m.xms.next_handle;
	m.xms.next_handle += 1;
	if (m.xms.next_handle == 0) m.xms.next_handle = 1;
	insert(m.xms.blocks[i], emb { handle = h, start = at, kb = kb, locks = 0 })!;
	// New memory reads as zero (like a freshly powered-on machine).
	const c = m.cpu;
	const from = at: size * 1024, to = (at + kb): size * 1024;
	for (let a = from; a < to; a += 1) c.mem[a] = 0;
	return h;
};

fn xms_realloc(m: *machine, h: u16, kb: u32) u8 = {
	const i = match (find_emb(m, h)) {
	case let i: size => yield i;
	case void => return 0xA2u8;
	};
	const b = m.xms.blocks[i];
	if (b.locks > 0) return 0xAB;
	// Room right where it is?
	const limit = if (i + 1 < len(m.xms.blocks)) m.xms.blocks[i + 1].start
		else XMS_END_KB;
	if (b.start + kb <= limit) {
		m.xms.blocks[i].kb = kb;
		return 0;
	};
	// Otherwise move it.
	const (at, j) = match (xms_place(m, kb, i)) {
	case let p: (u32, size) => yield p;
	case void => return 0xA0u8;
	};
	const c = m.cpu;
	const n = b.kb: size * 1024;
	const src = b.start: size * 1024, dst = at: size * 1024;
	if (dst < src) {
		for (let k = 0z; k < n; k += 1) c.mem[dst + k] = c.mem[src + k];
	} else {
		for (let k = n; k > 0; k -= 1) c.mem[dst + k - 1] = c.mem[src + k - 1];
	};
	delete(m.xms.blocks[i]);
	const j = if (j > i) j - 1 else j;
	insert(m.xms.blocks[j], emb { handle = h, start = at, kb = kb, locks = 0 })!;
	return 0;
};

// Function 0Bh: move a block between conventional memory (handle 0,
// offset = segment:offset) and EMBs.
fn xms_move(m: *machine) u8 = {
	const c = m.cpu;
	const ds = c.s[x86::DS], si = c.r[x86::SI];
	const length = fn_rd32(c, ds, si);
	const sh = x86::read16(c, ds, si + 4);
	const so = fn_rd32(c, ds, si + 6);
	const dh = x86::read16(c, ds, si + 10);
	const doff = fn_rd32(c, ds, si + 12);
	const src = match (xms_addr(m, sh, so, length)) {
	case let a: u32 => yield a;
	case let e: u8 => return if (e == 0xA2) 0xA3 else 0xA4;
	};
	const dst = match (xms_addr(m, dh, doff, length)) {
	case let a: u32 => yield a;
	case let e: u8 => return if (e == 0xA2) 0xA5 else 0xA6;
	};
	// Overlapping moves work either way round.
	const n = length: size, s = src: size, d = dst: size;
	if (d < s) {
		for (let k = 0z; k < n; k += 1) c.mem[d + k] = c.mem[s + k];
	} else {
		for (let k = n; k > 0; k -= 1) c.mem[d + k - 1] = c.mem[s + k - 1];
	};
	return 0;
};

fn fn_rd32(c: *x86::cpu, seg: u16, off: u16) u32 =
	x86::read16(c, seg, off): u32 | x86::read16(c, seg, off + 2): u32 << 16;

// The physical address of offset off in a handle's block (handle 0:
// off is a real-mode segment:offset).
fn xms_addr(m: *machine, h: u16, off: u32, n: u32) (u32 | u8) = {
	if (h == 0) {
		const a = (off >> 16) * 16 + (off & 0xFFFF);
		if (a + n > 0x110000) return 0xA4u8;
		return a;
	};
	const i = match (find_emb(m, h)) {
	case let i: size => yield i;
	case void => return 0xA2u8;
	};
	const b = m.xms.blocks[i];
	if (off > b.kb * 1024 || n > b.kb * 1024 - off) return 0xA4u8;
	return b.start * 1024 + off;
};

// Opens or closes the A20 gate for a program (XMS, the keyboard
// controller, port 92h, INT 15h). While a DPMI client runs it stays open:
// a DPMI host keeps it that way, and DOS extenders that still toggle it
// on the way (DOS/4GW's stub, for one) would otherwise fold all memory
// above 1 MiB onto the memory below.
fn gate_a20(m: *machine, on: bool) void =
	x86::set_a20(m.cpu, on || m.dpmi.active);

fn xms_a20(m: *machine) void = {
	gate_a20(m, m.xms.a20_global || m.xms.a20_local > 0);
};

// Callback 10Dh: one XMS call (AH = the function).
fn xms_call(m: *machine) void = {
	const c = m.cpu;
	const ah = x86::get8(c, 4);
	let err = 0u8;
	switch (ah) {
	case 0x00 => // version
		c.r[x86::AX] = 0x0300;
		c.r[x86::BX] = 0x0350;
		c.r[x86::DX] = 1; // there is an HMA
		return;
	case 0x01 => // request the HMA
		if (m.xms.hma_used) err = 0x91 else m.xms.hma_used = true;
	case 0x02 => // release it
		if (!m.xms.hma_used) err = 0x93 else m.xms.hma_used = false;
	case 0x03 => m.xms.a20_global = true; xms_a20(m);
	case 0x04 => m.xms.a20_global = false; xms_a20(m);
	case 0x05 => m.xms.a20_local += 1; xms_a20(m);
	case 0x06 =>
		if (m.xms.a20_local > 0) m.xms.a20_local -= 1;
		xms_a20(m);
	case 0x07 => // query A20
		c.r[x86::AX] = if (x86::a20(c)) 1 else 0;
		x86::set8(c, 3, 0);
		return;
	case 0x08 => // free memory (KiB, 16 bits)
		const (largest, total) = xms_free_kb(m);
		c.r[x86::AX] = if (largest > 0xFFFF) 0xFFFF else largest: u16;
		c.r[x86::DX] = if (total > 0xFFFF) 0xFFFF else total: u16;
		x86::set8(c, 3, if (total == 0) 0xA0 else 0);
		return;
	case 0x88 => // free memory (32 bits)
		const (largest, total) = xms_free_kb(m);
		x86::set32(c, x86::AX, largest);
		x86::set32(c, x86::CX, XMS_END_KB * 1024 - 1);
		x86::set32(c, x86::DX, total);
		x86::set8(c, 3, if (total == 0) 0xA0 else 0);
		return;
	case 0x09, 0x89 => // allocate
		const kb = if (ah == 0x09) c.r[x86::DX]: u32 else x86::get32(c, x86::DX);
		match (xms_alloc(m, kb)) {
		case let h: u16 => c.r[x86::DX] = h;
		case let e: u8 => err = e;
		};
	case 0x0A => // free
		match (find_emb(m, c.r[x86::DX])) {
		case let i: size =>
			if (m.xms.blocks[i].locks > 0) err = 0xAB
			else delete(m.xms.blocks[i]);
		case void => err = 0xA2;
		};
	case 0x0B => err = xms_move(m);
	case 0x0C => // lock: DX:BX = the physical address
		match (find_emb(m, c.r[x86::DX])) {
		case let i: size =>
			const b = &m.xms.blocks[i];
			if (b.locks == 0xFF) {
				err = 0xAC;
			} else {
				b.locks += 1;
				const a = b.start * 1024;
				c.r[x86::DX] = (a >> 16): u16;
				c.r[x86::BX] = a: u16;
			};
		case void => err = 0xA2;
		};
	case 0x0D => // unlock
		match (find_emb(m, c.r[x86::DX])) {
		case let i: size =>
			if (m.xms.blocks[i].locks == 0) err = 0xAA
			else m.xms.blocks[i].locks -= 1;
		case void => err = 0xA2;
		};
	case 0x0E, 0x8E => // handle information
		match (find_emb(m, c.r[x86::DX])) {
		case let i: size =>
			const b = m.xms.blocks[i];
			const free_h = (XMS_HANDLES - len(m.xms.blocks)): u16;
			x86::set8(c, 7, b.locks);
			if (ah == 0x0E) {
				x86::set8(c, 3, free_h: u8);
				c.r[x86::DX] = if (b.kb > 0xFFFF) 0xFFFF else b.kb: u16;
			} else {
				c.r[x86::CX] = free_h;
				x86::set32(c, x86::DX, b.kb);
			};
		case void => err = 0xA2;
		};
	case 0x0F, 0x8F => // reallocate
		const kb = if (ah == 0x0F) c.r[x86::BX]: u32 else x86::get32(c, x86::BX);
		err = xms_realloc(m, c.r[x86::DX], kb);
	case 0x10 => // upper memory blocks: none
		x86::set8(c, 3, 0xB1);
		c.r[x86::DX] = 0;
		c.r[x86::AX] = 0;
		return;
	case 0x11 => err = 0xB2;
	case => err = 0x80; // not implemented
	};
	if (err == 0) {
		c.r[x86::AX] = 1;
		if (ah != 0x0C && ah != 0x0E && ah != 0x8E) x86::set8(c, 3, 0);
	} else {
		c.r[x86::AX] = 0;
		x86::set8(c, 3, err);
	};
};
