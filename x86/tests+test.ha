// Quick unit tests for the CPU (the full check is the SingleStepTests
// suite: make cputest).

// Puts code at 1000:0100 and returns a CPU ready to run it.
fn with_code(code: []u8) *cpu = {
	const c = new()!;
	c.s = [0x1000...];
	c.ip = 0x100;
	c.r[SP] = 0xFFFE;
	const a = linear(0x1000, 0x100);
	c.mem[a..a + len(code)] = code;
	return c;
};

@test fn add_sets_flags() void = {
	const c = with_code([0xB0, 0xFF, 0x04, 0x01]); // mov al, FFh; add al, 1
	defer destroy(c);
	step(c);
	step(c);
	assert(get8(c, 0) == 0);
	assert(flag(c, CF) && flag(c, ZF) && flag(c, AF) && flag(c, PF));
	assert(!flag(c, SF) && !flag(c, OF));
};

@test fn push_sp_pushes_new_value() void = {
	const c = with_code([0x54]); // push sp
	defer destroy(c);
	step(c);
	assert(c.r[SP] == 0xFFFC);
	assert(read16(c, 0x1000, 0xFFFC) == 0xFFFC);
};

@test fn word_wraps_inside_segment() void = {
	const c = with_code([]);
	defer destroy(c);
	write16(c, 0x2000, 0xFFFF, 0xBEEF);
	assert(read8(c, 0x2000, 0xFFFF) == 0xEF);
	assert(read8(c, 0x2000, 0x0000) == 0xBE);
	// and the address space wraps at 1 MiB (with the A20 gate closed)
	c.mem[0] = 0x5A;
	assert(read8(c, 0xFFFF, 0x0010) == 0x5A);
};

@test fn rep_movsb_copies() void = {
	// mov cx, 5; rep movsb
	const c = with_code([0xB9, 0x05, 0x00, 0xF3, 0xA4]);
	defer destroy(c);
	c.s[ES] = 0x3000;
	c.r[SI] = 0x200;
	c.r[DI] = 0x10;
	for (let i = 0u16; i < 5; i += 1) write8(c, 0x1000, 0x200 + i, 'a' + i: u8);
	step(c);
	step(c);
	assert(c.in_rep); // one round per step, so interrupts can get in
	step_full(c);
	assert(!c.in_rep && c.r[CX] == 0 && c.ip == 0x105);
	assert(read8(c, 0x3000, 0x10) == 'a' && read8(c, 0x3000, 0x14) == 'e');
};

@test fn divide_error_goes_through_vector_0() void = {
	// div bl with BL = 0
	const c = with_code([0xF6, 0xF3]);
	defer destroy(c);
	write16(c, 0, 0, 0x0400);
	write16(c, 0, 2, 0x0000);
	step(c);
	assert(c.s[CS] == 0 && c.ip == 0x0400);
	// the 8088 returns to the next instruction
	assert(read16(c, 0x1000, c.r[SP]) == 0x102);
};

@test fn rep_idiv_flips_the_quotient() void = {
	// mov ax, 100; mov bl, 7; rep idiv bl
	const c = with_code([0xB8, 100, 0, 0xB3, 7, 0xF3, 0xF6, 0xFB]);
	defer destroy(c);
	step(c);
	step(c);
	step(c);
	assert(get8(c, 0) == (-14i8): u8);
	assert(get8(c, 4) == 2);
};

let hooked: u8 = 0;

fn hook(c: *cpu, n: u8) bool = {
	hooked = n;
	return true;
};

@test fn int_hook_takes_interrupts() void = {
	const c = with_code([0xCD, 0x21]); // int 21h
	defer destroy(c);
	c.int_hook = &hook;
	step(c);
	assert(hooked == 0x21 && c.ip == 0x102 && c.r[SP] == 0xFFFE);
};

// The 386: 32-bit registers with 66h, and a limit fault (#GP) for a word
// at offset FFFFh, where the 8088 wraps.
@test fn i386_basics() void = {
	const c = with_code([
		0x66, 0xB8, 0x78, 0x56, 0x34, 0x12, // mov eax, 12345678h
		0x66, 0xC1, 0xC0, 0x08,             // rol eax, 8
		0xBB, 0xFF, 0xFF,                   // mov bx, FFFFh
		0x8B, 0x07,                         // mov ax, [bx]
	]);
	defer destroy(c);
	set_model(c, model::I386);
	c.s = [0x1000...];
	c.ip = 0x100;
	c.r[SP] = 0xFFFE;
	// The #GP handler at 0:0D*4 points to 2000:0000.
	write16(c, 0, 13 * 4, 0);
	write16(c, 0, 13 * 4 + 2, 0x2000);
	step(c);
	assert(get32(c, AX) == 0x12345678);
	step(c);
	assert(get32(c, AX) == 0x34567812);
	step(c);
	step(c);
	assert(c.s[CS] == 0x2000 && c.ip == 0);
	// It returns to the faulting instruction, with AX untouched.
	assert(read16(c, 0x1000, 0xFFF8) == 0x10D);
	assert(c.r[AX] == 0x7812);
};

// Writes a segment descriptor (base, limit, access byte, flags nibble).
fn put_desc(c: *cpu, at: u32, base: u32, limit: u32, access: u8, flags: u8) void = {
	c.mem[at] = limit: u8;
	c.mem[at + 1] = (limit >> 8): u8;
	c.mem[at + 2] = base: u8;
	c.mem[at + 3] = (base >> 8): u8;
	c.mem[at + 4] = (base >> 16): u8;
	c.mem[at + 5] = access;
	c.mem[at + 6] = (flags << 4) | ((limit >> 16): u8 & 0xF);
	c.mem[at + 7] = (base >> 24): u8;
};

// Ring 3 calls ring 0 through a call gate with one parameter, which is
// copied to ring 0's stack (from the TSS); RETF 4 goes back out.
@test fn call_gate_to_ring0_and_back() void = {
	const c = new()!;
	defer destroy(c);
	set_model(c, model::I386);
	set_a20(c, true);
	const gdt = 0x1000u32;
	put_desc(c, gdt + 0x08, 0, 0xFFFFF, 0x9A, 0xC); // ring 0 code
	put_desc(c, gdt + 0x10, 0, 0xFFFFF, 0x92, 0xC); // ring 0 data
	put_desc(c, gdt + 0x18, 0, 0xFFFFF, 0xFA, 0xC); // ring 3 code
	put_desc(c, gdt + 0x20, 0, 0xFFFFF, 0xF2, 0xC); // ring 3 data
	put_desc(c, gdt + 0x30, 0x2000, 103, 0x89, 0);  // TSS
	// 28: a 32-bit call gate, DPL 3, to 08:3000, one parameter.
	const g: [8]u8 = [0x00, 0x30, 0x08, 0x00, 0x01, 0xEC, 0x00, 0x00];
	c.mem[gdt + 0x28..gdt + 0x30] = g;
	c.gdt_base = gdt;
	c.gdt_limit = 0x37;
	// TSS: ring 0's stack is 10:9000.
	c.mem[0x2004] = 0x00;
	c.mem[0x2005] = 0x90;
	c.mem[0x2008] = 0x10;
	c.tr = 0x30;
	c.tr_base = 0x2000;
	c.tr_limit = 103;
	c.tr_attr = 0x8B;
	// Ring 3: push 1234h; call 2B:0; jmp $
	const r3: [_]u8 = [0x68, 0x34, 0x12, 0x00, 0x00,
		0x9A, 0x00, 0x00, 0x00, 0x00, 0x2B, 0x00, 0xEB, 0xFE];
	c.mem[0x4000..0x4000 + len(r3)] = r3;
	// Ring 0: mov eax, [esp+8]; retf 4
	const r0: [_]u8 = [0x8B, 0x44, 0x24, 0x08, 0xCA, 0x04, 0x00];
	c.mem[0x3000..0x3000 + len(r0)] = r0;

	c.cr0 = 0x11;
	c.s[CS] = 0x1B;
	c.sbase[CS] = 0;
	c.slimit[CS] = 0xFFFFFFFF;
	c.sattr[CS] = 0x40FB;
	c.s[SS] = 0x23;
	c.sbase[SS] = 0;
	c.slimit[SS] = 0xFFFFFFFF;
	c.sattr[SS] = 0x40F3;
	c.cpl = 3;
	set32(c, SP, 0x8000);
	c.ip = 0x4000;
	c.eip = 0x4000;

	step(c); // push
	step(c); // call through the gate
	assert(c.s[CS] == 0x08 && c.cpl == 0 && c.s[SS] == 0x10);
	assert(get32(c, SP) == 0x9000 - 20);
	assert(read16(c, 0, 0x9000 - 12) == 0x1234); // the copied parameter
	step(c); // mov eax, [esp+8]
	assert(get32(c, AX) == 0x1234);
	step(c); // retf 4
	assert(c.s[CS] == 0x1B && c.cpl == 3 && c.s[SS] == 0x23);
	assert(get32(c, SP) == 0x8000);
	assert(c.eip == 0x400C);
};
