// Shifu — DOS memory: a chain of memory control blocks (MCBs) in
// emulated memory, exactly like MS-DOS keeps it, because some programs
// walk the chain themselves.
//
// An MCB is one paragraph just before its block:
//	0  'M' (more follow) or 'Z' (last)
//	1  owner PSP (0 = free, 8 = DOS)
//	3  size in paragraphs, not counting the MCB
//	8  owner name (8 bytes)
use x86;

fn mcb_type(m: *machine, s: u16) u8 = x86::read8(m.cpu, s, 0);
fn mcb_owner(m: *machine, s: u16) u16 = x86::read16(m.cpu, s, 1);
fn mcb_size(m: *machine, s: u16) u16 = x86::read16(m.cpu, s, 3);

fn mcb_set(m: *machine, s: u16, kind: u8, owner: u16, sz: u16) void = {
	x86::write8(m.cpu, s, 0, kind);
	x86::write16(m.cpu, s, 1, owner);
	x86::write16(m.cpu, s, 3, sz);
};

fn mcb_valid(m: *machine, s: u16) bool = {
	const t = mcb_type(m, s);
	return t == 'M' || t == 'Z';
};

fn mem_init(m: *machine) void = {
	mcb_set(m, FIRST_MCB, 'Z', 0, MEM_TOP - FIRST_MCB - 1);
	// List of lists (INT 21h AH=52h) points just past the first MCB's
	// segment, which programs find at [ES:BX-2].
	x86::write16(m.cpu, DOSSEG, 0x0E, FIRST_MCB);
};

// Joins the free blocks that follow the block at MCB s onto it.
fn absorb_free(m: *machine, s: u16) void = {
	for (mcb_type(m, s) == 'M') {
		const next = s + mcb_size(m, s) + 1;
		if (!mcb_valid(m, next) || mcb_owner(m, next) != 0) break;
		mcb_set(m, s, mcb_type(m, next), mcb_owner(m, s),
			mcb_size(m, s) + mcb_size(m, next) + 1);
	};
};

// Cuts the block at MCB s down to n paragraphs, freeing the rest.
fn split(m: *machine, s: u16, n: u16) void = {
	const sz = mcb_size(m, s);
	if (n >= sz) return;
	const rest = s + n + 1;
	mcb_set(m, rest, mcb_type(m, s), 0, sz - n - 1);
	mcb_set(m, s, 'M', mcb_owner(m, s), n);
	absorb_free(m, rest);
};

// Allocates n paragraphs (first fit). On failure returns the largest
// free block as an error: (segment | (largest: doserr)).
fn mem_alloc(m: *machine, n: u16, owner: u16) (u16 | (u16, doserr)) = {
	let s = FIRST_MCB, largest = 0u16;
	for (true) {
		if (!mcb_valid(m, s)) return (0u16, 7: doserr);
		if (mcb_owner(m, s) == 0) {
			absorb_free(m, s);
			const sz = mcb_size(m, s);
			if (sz >= n) {
				x86::write16(m.cpu, s, 1, owner);
				split(m, s, n);
				return s + 1;
			};
			if (sz > largest) largest = sz;
		};
		if (mcb_type(m, s) == 'Z') break;
		s += mcb_size(m, s) + 1;
	};
	return (largest, 8: doserr);
};

fn mem_free(m: *machine, seg: u16) (void | doserr) = {
	const s = seg - 1;
	if (!mcb_valid(m, s)) return 9: doserr;
	x86::write16(m.cpu, s, 1, 0);
};

// Resizes a block. On failure returns the most it can grow to.
fn mem_resize(m: *machine, seg: u16, n: u16) (void | (u16, doserr)) = {
	const s = seg - 1;
	if (!mcb_valid(m, s)) return (0u16, 9: doserr);
	absorb_free(m, s);
	const sz = mcb_size(m, s);
	if (n > sz) return (sz, 8: doserr);
	split(m, s, n);
};

// Frees every block a program owns.
fn mem_free_owner(m: *machine, owner: u16) void = {
	let s = FIRST_MCB;
	for (mcb_valid(m, s)) {
		if (mcb_owner(m, s) == owner) x86::write16(m.cpu, s, 1, 0);
		if (mcb_type(m, s) == 'Z') break;
		s += mcb_size(m, s) + 1;
	};
};

fn mcb_name(m: *machine, seg: u16, name: []u8) void = {
	for (let i = 0u16; i < 8; i += 1) {
		const ch = if (i < len(name)) name[i] else 0u8;
		x86::write8(m.cpu, seg - 1, 8 + i, ch);
	};
};
