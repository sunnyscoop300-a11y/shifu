// Shifu — a DPMI 0.9 host, like CWSDPMI or HDPMI: DOS programs switch
// to protected mode through it (INT 2Fh AX=1687h) and then use INT 31h
// for descriptors, memory, interrupt vectors and calls to real mode. All
// other software interrupts, and hardware interrupts the program hasn't
// taken over, go down to the real-mode handlers (DOS and the BIOS) and
// back. Programs run in ring 3 with IOPL 3; the host's own handlers are
// short stubs in ring 0 that call into Hare.
use fmt;
use x86;

// The host's tables, at the top of memory (the XMS pool stops below).
def HOST: u32 = 0xFC0000;
def H_GDT: u32 = HOST;
def H_TSS: u32 = HOST + 0x400;
def H_IDT: u32 = HOST + 0x800;
def H_STUB0: u32 = HOST + 0x1000;  // ring 0: callback 200h+n; IRETD
def H_STUB3: u32 = HOST + 0x1800;  // ring 3: default handlers and returns
def H_LDT: u32 = HOST + 0x3000;
def H_EXCSTACK: u32 = HOST + 0x7000;  // top of the exception stack
def H_IRQSTACK: u32 = HOST + 0x9000;  // top of the stack for IRQs from RM
def H_STACK0: u32 = HOST + 0x10000;   // top of ring 0's stack

def LDT_ENTRIES: u16 = 1024;

// GDT selectors.
def SEL_HCODE: u16 = 0x08;   // ring 0 stubs (16-bit code)
def SEL_HDATA: u16 = 0x10;   // ring 0 flat data, the host stack
def SEL_LDT: u16 = 0x18;
def SEL_TSS: u16 = 0x20;
def SEL_H3CODE: u16 = 0x2B;  // ring 3 stubs (16-bit code, RPL 3)
// The BIOS data area (0040:0000) for clients: Windows, DOS/4GW's own host
// and most others have it, and programs use it without asking.
def SEL_BIOS: u16 = 0x40;

// Ring 3 stubs past the 256 default handlers.
def S3_IRQRET: u16 = 0x800;  // a client's IRQ handler called from RM returns
def S3_EXCRET: u16 = 0x808;  // a client's exception handler returns (RETF)
def S3_RAW: u16 = 0x810;     // raw switch to real mode
def S3_CBRET: u16 = 0x818;   // a real-mode callback's procedure returns
def S3_RETF: u16 = 0x820;    // just RETF (save/restore state)
def S3_PMIRQRET: u16 = 0x828; // a client's IRQ handler called from PM returns

// Real-mode addresses (F000:...): the entry point, the return from a
// real-mode call, the raw switch to protected mode, a plain RETF, the
// real-mode callbacks, and the stack for calls down to real mode.
def RM_ENTRY: u16 = 0x1180;
def RM_RETURN: u16 = 0x1200;
def RM_RAW: u16 = 0x1210;
def RM_RETF: u16 = 0x1220;
def RM_CALLBACKS: u16 = 0x1300;
def RM_CALLBACK_N: size = 32;
def RM_STACK_TOP: u16 = 0x8FF0;

// Saved protected-mode state while real-mode code runs for it.
export type pmstate = struct {
	r: [8]u16,
	rh: [8]u16,
	s: [6]u16,
	sbase: [6]u32,
	slimit: [6]u32,
	sattr: [6]u16,
	flags: u16,
	flagsh: u16,
	eip: u32,
	cpl: u8,
	// What to do on return: 0 copy the registers back (a reflected
	// software interrupt), 1 fill in a real-mode call structure
	// (0300h-0302h), 2 nothing (a reflected hardware interrupt: the
	// interrupted code gets everything back as it was).
	kind: u8,
	// Where the client's interrupt frame is (to give it the flags), and
	// whether it is a 32-bit one; or where the call structure is.
	frame: u32,
	frame32: bool,
	esp0: u32,
	rm_sp: u16,
};

// Saved real-mode state while protected-mode code runs for it (an IRQ
// handler or a real-mode callback).
export type rmstate = struct {
	r: [8]u16,
	rh: [8]u16,
	s: [6]u16,
	flags: u16,
	ip: u16,
	kind: u8,        // 0 IRQ, 1 callback
	cb: size,
	rm_sp: u16,
};

export type rmcallback = struct {
	used: bool,
	pm_sel: u16,
	pm_off: u32,
	st_sel: u16,
	st_off: u32,
};

export type dpmi = struct {
	active: bool,
	big: bool,             // a 32-bit client
	psp: u16,
	env_seg: u16,          // PSP:2Ch before it became a selector
	ldt_used: [LDT_ENTRIES]bool,
	// Where the next search for free descriptors starts.
	ldt_next: u16,
	pm_vec: [256](u16, u32),   // the client's handlers (0 = none)
	exc_vec: [32](u16, u32),
	rm_vec_sel: [256]u16,      // 0002h: segments already mapped
	memblocks: []u16,          // XMS handles of 0501h blocks
	pmsaves: []pmstate,
	rmsaves: []rmstate,
	callbacks: [RM_CALLBACK_N]rmcallback,
	rm_sp: u16,
	sel_exc: u16,              // the exception stack
	sel_irq: u16,              // the locked stack for IRQs and callbacks
	// How many handlers are on it now (each gets its own 1 KiB).
	irq_depth: u32,
	// Where IRQs taken in protected mode go back to: SS, ESP, CS, EIP,
	// EFLAGS of the interrupted code.
	pmirqs: [](u16, u32, u16, u32, u32),
	// The real-mode vectors when the client started: an IRQ in real
	// mode goes up to the client's protected-mode handler only while
	// its real-mode vector is still the one it found (if the client
	// hooked it there too, 0201h, its real-mode handler gets it).
	ivt0: [256]u32,
};

// The top of the next free part of the locked stack, and claims it.
fn irq_stack(m: *machine) u32 = {
	const d = m.dpmi.irq_depth;
	m.dpmi.irq_depth = d + 1;
	return 0x2000 - (if (d < 7) d else 7u32) * 0x400;
};

fn irq_stack_done(m: *machine) void = {
	if (m.dpmi.irq_depth > 0) m.dpmi.irq_depth -= 1;
};

fn dpmi_init(m: *machine) void = {
	const c = m.cpu;
	const rom = x86::linear(ROMSEG, 0);
	const stubs: [_](u16, u16) = [
		(RM_ENTRY, 0x110), (RM_RETURN, 0x113), (RM_RAW, 0x116),
	];
	for (let (off, n) .. stubs) {
		const a = rom + off;
		c.mem[a] = 0xFE;
		c.mem[a + 1] = 0x38;
		c.mem[a + 2] = n: u8;
		c.mem[a + 3] = (n >> 8): u8;
		c.mem[a + 4] = 0xCB; // (RETF, for the entry: never reached)
	};
	c.mem[rom + RM_RETF] = 0xCB;
	for (let i = 0z; i < RM_CALLBACK_N; i += 1) {
		const a = rom + RM_CALLBACKS + i: u32 * 8;
		const n = 0x300 + i: u16;
		c.mem[a] = 0xFE;
		c.mem[a + 1] = 0x38;
		c.mem[a + 2] = n: u8;
		c.mem[a + 3] = (n >> 8): u8;
	};
};

fn dpmi_free(m: *machine) void = {
	free(m.dpmi.memblocks);
	free(m.dpmi.pmsaves);
	free(m.dpmi.rmsaves);
	free(m.dpmi.pmirqs);
};

fn dpmi_present(m: *machine) bool = m.cpu.model == x86::model::I386 && !m.no_dpmi;

// ---- Memory and descriptors ----

fn put8(m: *machine, a: u32, v: u8) void = m.cpu.mem[a] = v;
fn put16(m: *machine, a: u32, v: u16) void = {
	m.cpu.mem[a] = v: u8;
	m.cpu.mem[a + 1] = (v >> 8): u8;
};
fn put32(m: *machine, a: u32, v: u32) void = {
	put16(m, a, v: u16);
	put16(m, a + 2, (v >> 16): u16);
};
fn get16(m: *machine, a: u32) u16 = m.cpu.mem[a]: u16 | m.cpu.mem[a + 1]: u16 << 8;
fn get32(m: *machine, a: u32) u32 = get16(m, a): u32 | get16(m, a + 2): u32 << 16;

fn put_desc(m: *machine, a: u32, base: u32, limit: u32, access: u8, flags: u8) void = {
	let lim = limit, fl = flags;
	if (lim > 0xFFFFF) {
		lim >>= 12;
		fl |= 0x8; // G
	};
	put16(m, a, lim: u16);
	put16(m, a + 2, base: u16);
	put8(m, a + 4, (base >> 16): u8);
	put8(m, a + 5, access);
	put8(m, a + 6, (fl << 4) | ((lim >> 16): u8 & 0xF));
	put8(m, a + 7, (base >> 24): u8);
};

// Where a selector's descriptor is (GDT or LDT).
fn desc_at(m: *machine, sel: u16) u32 =
	(if (sel & 4 != 0) H_LDT else H_GDT) + (sel & 0xFFF8): u32;

fn desc_base(m: *machine, sel: u16) u32 = {
	const a = desc_at(m, sel);
	return get16(m, a + 2): u32 | m.cpu.mem[a + 4]: u32 << 16 |
		m.cpu.mem[a + 7]: u32 << 24;
};

fn desc_limit(m: *machine, sel: u16) u32 = {
	const a = desc_at(m, sel);
	const l = get16(m, a): u32 | (m.cpu.mem[a + 6] & 0xF): u32 << 16;
	return if (m.cpu.mem[a + 6] & 0x80 != 0) l << 12 | 0xFFF else l;
};

// Loads a segment register's cache straight from its descriptor, as the
// host may (no privilege checks).
fn cache(m: *machine, sreg: size, sel: u16) void = {
	const c = m.cpu;
	c.s[sreg] = sel;
	if (sel & 0xFFFC == 0) {
		c.sbase[sreg] = 0;
		c.slimit[sreg] = 0;
		c.sattr[sreg] = 0;
		return;
	};
	const a = desc_at(m, sel);
	c.sbase[sreg] = desc_base(m, sel);
	c.slimit[sreg] = desc_limit(m, sel);
	c.sattr[sreg] = c.mem[a + 5]: u16 | (c.mem[a + 6] & 0xF0): u16 << 8;
};

fn ldt_sel(i: u16) u16 = i * 8 | 7;

fn ldt_valid(m: *machine, sel: u16) bool =
	sel & 4 != 0 && sel >> 3 < LDT_ENTRIES && m.dpmi.ldt_used[sel >> 3];

// Allocates n contiguous LDT descriptors (data, base 0, limit 0).
// Next fit, like DOS/4GW's own host: a freed selector isn't handed out
// again straight away (DOS/4GW keeps using far pointers through a
// selector for a moment after freeing it).
fn ldt_alloc(m: *machine, n: u16) (u16 | void) = {
	if (n == 0 || n >= LDT_ENTRIES) return;
	let start = m.dpmi.ldt_next;
	if (start < 1 || start + n > LDT_ENTRIES) start = 1;
	for (let pass = 0; pass < 2; pass += 1) {
		const from = if (pass == 0) start else 1u16;
		for (let i = from; i + n <= LDT_ENTRIES; i += 1) {
			let room = true;
			for (let k = 0u16; k < n; k += 1) {
				if (m.dpmi.ldt_used[i + k]) {
					room = false;
					break;
				};
			};
			if (!room) continue;
			for (let k = 0u16; k < n; k += 1) {
				m.dpmi.ldt_used[i + k] = true;
				put_desc(m, H_LDT + (i + k): u32 * 8, 0, 0, 0xF2, 0);
			};
			m.dpmi.ldt_next = i + n;
			return ldt_sel(i);
		};
		if (start == 1) break;
	};
};

// ---- The CPU's state ----

fn set_eip(c: *x86::cpu, v: u32) void = {
	c.eip = v;
	c.ip = v: u16;
};

fn save_pm(m: *machine, kind: u8, frame: u32, frame32: bool) void = {
	const c = m.cpu;
	append(m.dpmi.pmsaves, pmstate {
		r = c.r, rh = c.rh, s = c.s, sbase = c.sbase, slimit = c.slimit,
		sattr = c.sattr, flags = c.flags, flagsh = c.flagsh, eip = c.eip,
		cpl = c.cpl, kind = kind, frame = frame, frame32 = frame32,
		esp0 = get32(m, H_TSS + 4), rm_sp = m.dpmi.rm_sp,
	})!;
	// Nested entries to ring 0 must not overwrite a frame still in use.
	if (c.cpl == 0) put32(m, H_TSS + 4, x86::get32(c, x86::SP) - 16);
};

fn restore_pm(m: *machine, st: *pmstate) void = {
	const c = m.cpu;
	c.r = st.r;
	c.rh = st.rh;
	c.s = st.s;
	c.sbase = st.sbase;
	c.slimit = st.slimit;
	c.sattr = st.sattr;
	c.flags = st.flags;
	c.flagsh = st.flagsh;
	c.cpl = st.cpl;
	put32(m, H_TSS + 4, st.esp0);
	m.dpmi.rm_sp = st.rm_sp;
	to_pm(m);
	set_eip(c, st.eip);
};

fn to_pm(m: *machine) void = {
	const c = m.cpu;
	c.cr0 |= 1;
	c.stale = 0;
	c.idt_base = H_IDT;
	c.idt_limit = 0x7FF;
	c.gdt_base = H_GDT;
	c.gdt_limit = 0x47;
};

// Into real mode, with real-mode segment caches.
fn to_rm(m: *machine) void = {
	const c = m.cpu;
	c.cr0 &= ~1u32;
	c.stale = 0;
	c.cpl = 0;
	c.slimit = [0xFFFF...];
	c.sattr = [0x93...];
	c.sattr[x86::CS] = 0x9B;
	c.idt_base = 0;
	c.idt_limit = 0x3FF;
};

fn rm_push(m: *machine, v: u16) void = {
	const c = m.cpu;
	c.r[x86::SP] -= 2;
	x86::write16(c, c.s[x86::SS], c.r[x86::SP], v);
};

fn rm_pop(m: *machine) u16 = {
	const c = m.cpu;
	const v = x86::read16(c, c.s[x86::SS], c.r[x86::SP]);
	c.r[x86::SP] += 2;
	return v;
};

// The ring 0 stub's frame (EIP, CS, EFLAGS, ESP, SS) on the host stack.
fn frame0(m: *machine) u32 = x86::get32(m.cpu, x86::SP);

fn set_cf(m: *machine, on: bool) void = {
	const f = frame0(m) + 8;
	put16(m, f, (get16(m, f) & ~x86::CF) | (if (on) x86::CF else 0u16));
};

// A pointer from the client: seg:offset with the client's offset size.
fn ptr(m: *machine, sreg: size, r: size) u32 = {
	const c = m.cpu;
	const off = if (m.dpmi.big) x86::get32(c, r) else c.r[r]: u32;
	return c.sbase[sreg] + off;
};

// ---- Down to real mode and back ----

// Runs real-mode code at seg:off for protected mode: an interrupt
// handler (iret: an IRET frame) or a far procedure, returning through
// F000:RM_RETURN. The PM state is saved and comes back afterwards.
fn rm_call(m: *machine, seg: u16, off: u16, iret: bool, kind: u8,
		frame: u32, frame32: bool) void = {
	const c = m.cpu;
	save_pm(m, kind, frame, frame32);
	to_rm(m);
	c.s[x86::SS] = ROMSEG;
	c.r[x86::SP] = m.dpmi.rm_sp;
	if (iret) rm_push(m, c.flags);
	rm_push(m, ROMSEG);
	rm_push(m, RM_RETURN);
	if (iret) c.flags &= ~(x86::IF | x86::TF);
	m.dpmi.rm_sp = c.r[x86::SP] - 0x100;
	c.s[x86::CS] = seg;
	set_eip(c, off);
};

// Reflects interrupt n to its real-mode handler, with the registers as
// they are; the flags come back into the client's frame at frame.
fn reflect(m: *machine, n: u8, frame: u32, frame32: bool, hw: bool) void = {
	const c = m.cpu;
	const off = x86::read16(c, 0, n: u16 * 4);
	const seg = x86::read16(c, 0, n: u16 * 4 + 2);
	rm_call(m, seg, off, true, if (hw) 2 else 0, frame, frame32);
	// Segment registers aren't translated: DS and ES point nowhere
	// useful in real mode (programs use 0300h with real segments).
	c.s[x86::DS] = 0;
	c.s[x86::ES] = 0;
	c.s[x86::FS] = 0;
	c.s[x86::GS] = 0;
};

// Callback 113h: real-mode code returned to F000:RM_RETURN.
fn rm_returned(m: *machine) void = {
	const c = m.cpu;
	const n = len(m.dpmi.pmsaves);
	if (n == 0) return;
	let st = m.dpmi.pmsaves[n - 1];
	delete(m.dpmi.pmsaves[n - 1]);
	const r = c.r, rh = c.rh, s = c.s, flags = c.flags;
	restore_pm(m, &st);
	if (st.kind == 2) {
		// A hardware interrupt: restore_pm put everything back.
		void;
	} else if (st.kind == 0) {
		// A reflected interrupt: its results go to the client (all but
		// the stack pointer, which is protected mode's own).
		const sp = c.r[x86::SP], sph = c.rh[x86::SP];
		c.r = r;
		c.rh = rh;
		c.r[x86::SP] = sp;
		c.rh[x86::SP] = sph;
		const f = st.frame + (if (st.frame32) 8u32 else 4u32);
		put16(m, f, (get16(m, f) & ~0x8D5u16) | (flags & 0x8D5));
	} else {
		// A call with a register structure: fill it in.
		const a = st.frame;
		const regs: [8]size = [x86::DI, x86::SI, x86::BP, x86::SP,
			x86::BX, x86::DX, x86::CX, x86::AX];
		for (let i = 0z; i < 8; i += 1) {
			if (i == 3) continue;
			put32(m, a + i: u32 * 4, r[regs[i]]: u32 | rh[regs[i]]: u32 << 16);
		};
		put16(m, a + 0x20, flags);
		put16(m, a + 0x22, s[x86::ES]);
		put16(m, a + 0x24, s[x86::DS]);
		put16(m, a + 0x26, s[x86::FS]);
		put16(m, a + 0x28, s[x86::GS]);
		set_cf(m, false);
	};
};

// 0300h-0302h: a real-mode interrupt or far call with registers from a
// structure at ES:(E)DI; CX words of the client's stack are copied.
fn rm_call_struct(m: *machine, how: u8) void = {
	const c = m.cpu;
	const a = ptr(m, x86::ES, x86::DI);
	const words = c.r[x86::CX];
	const n = c.r[x86::BX]: u8;
	let seg = get16(m, a + 0x2C), off = get16(m, a + 0x2A);
	if (how == 0) {
		off = x86::read16(c, 0, n: u16 * 4);
		seg = x86::read16(c, 0, n: u16 * 4 + 2);
	};
	// The client's stack, for the words to copy (its return frame
	// from INT 31h is on the host stack, not there).
	const f = frame0(m);
	const csp = get32(m, f + 12), css = get16(m, f + 16);
	const sbase = desc_base(m, css);
	const big = desc_limit(m, css) > 0xFFFF;
	rm_call(m, seg, off, how != 1, 1, a, m.dpmi.big);
	// The registers from the structure; its own stack if it has one.
	const regs: [8]size = [x86::DI, x86::SI, x86::BP, x86::SP,
		x86::BX, x86::DX, x86::CX, x86::AX];
	for (let i = 0z; i < 8; i += 1) {
		if (i == 3) continue;
		x86::set32(c, regs[i], get32(m, a + i: u32 * 4));
	};
	const ss = get16(m, a + 0x30), sp = get16(m, a + 0x2E);
	const ret_ip = rm_pop(m), ret_cs = rm_pop(m);
	const ret_f = if (how != 1) rm_pop(m) else 0u16;
	if (ss != 0 || sp != 0) {
		c.s[x86::SS] = ss;
		c.r[x86::SP] = sp;
	};
	for (let i = words; i > 0; i -= 1) {
		const at = csp + (i - 1): u32 * 2;
		rm_push(m, get16(m, sbase + (if (big) at else at & 0xFFFF)));
	};
	if (how != 1) rm_push(m, ret_f);
	rm_push(m, ret_cs);
	rm_push(m, ret_ip);
	c.flags = (get16(m, a + 0x20) & 0x0FD5) | 2;
	c.s[x86::ES] = get16(m, a + 0x22);
	c.s[x86::DS] = get16(m, a + 0x24);
	c.s[x86::FS] = get16(m, a + 0x26);
	c.s[x86::GS] = get16(m, a + 0x28);
	c.s[x86::CS] = seg;
	set_eip(c, off);
};

// ---- Calling the client's handlers ----

// Switches to ring 3 code at cs:eip on the stack ss:esp (no checks: the
// host does this).
fn enter_client(m: *machine, cs: u16, eip: u32, ss: u16, esp: u32) void = {
	const c = m.cpu;
	cache(m, x86::CS, cs);
	cache(m, x86::SS, ss);
	x86::set32(c, x86::SP, esp);
	c.cpl = 3;
	set_eip(c, eip);
};

// Pushes on the client stack at ss:esp, as the client's size.
fn cpush(m: *machine, ss: u16, esp: *u32, v: u32) void = {
	const base = desc_base(m, ss);
	if (m.dpmi.big) {
		*esp -= 4;
		put32(m, base + *esp, v);
	} else {
		*esp = (*esp - 2) & 0xFFFF | (*esp & 0xFFFF0000);
		put16(m, base + (*esp & 0xFFFF), v: u16);
	};
};

// From the ring 0 stub, hands interrupt n to the client's own handler:
// the frame moves from the host stack to the client's.
fn to_client_handler(m: *machine, n: u8) void = {
	const c = m.cpu;
	const f = frame0(m);
	const eip = get32(m, f), cs = get16(m, f + 4), fl = get32(m, f + 8);
	let esp = get32(m, f + 12);
	const ss = get16(m, f + 16);
	x86::set32(c, x86::SP, f + 20);
	if (c.int_kind == 2) {
		// A hardware interrupt: like every DPMI host, on the locked
		// stack (the client may be on a big 32-bit stack its 16-bit
		// handlers can't use), and back through S3_PMIRQRET.
		append(m.dpmi.pmirqs, (ss, esp, cs, eip, fl))!;
		const irqs = m.dpmi.sel_irq;
		let sp = irq_stack(m);
		cpush(m, irqs, &sp, fl);
		cpush(m, irqs, &sp, SEL_H3CODE);
		cpush(m, irqs, &sp, S3_PMIRQRET);
		const (hs, ho) = m.dpmi.pm_vec[n];
		c.flags = (fl: u16 & ~(x86::IF | x86::TF)) | 2;
		enter_client(m, hs, ho, irqs, sp);
		return;
	};
	if (!m.dpmi.big) esp &= 0xFFFF;
	cpush(m, ss, &esp, fl);
	cpush(m, ss, &esp, cs);
	cpush(m, ss, &esp, eip);
	const (hs, ho) = m.dpmi.pm_vec[n];
	c.flags = (fl: u16 & ~(x86::IF | x86::TF)) | 2;
	enter_client(m, hs, ho, ss, esp);
};

// Callback 119h: a client's handler for an IRQ taken in protected mode
// returned (IRET) to S3_PMIRQRET: back to the interrupted code, with the
// registers the handler left and the flags as they were.
fn pm_irq_returned(m: *machine) void = {
	const c = m.cpu;
	const n = len(m.dpmi.pmirqs);
	if (n == 0) return;
	const (ss, esp, cs, eip, fl) = m.dpmi.pmirqs[n - 1];
	delete(m.dpmi.pmirqs[n - 1]);
	irq_stack_done(m);
	c.flags = (fl: u16 & 0x0FD5) | 0x3002 | (fl: u16 & x86::IF);
	enter_client(m, cs, eip, ss, esp);
	if (!m.dpmi.big) c.eip &= 0xFFFF;
};

// ---- The interrupt stubs ----

// Callback 200h+n: interrupt n came to the host in protected mode.
fn pm_interrupt(m: *machine, n: u8) void = {
	const c = m.cpu;
	const kind = c.int_kind;
	if (kind == 0) {
		// An exception: drop the error code, then the client's handler
		// or the end of the program.
		const err = if (c.int_err) get32(m, frame0(m)) else 0u32;
		if (c.int_err) x86::set32(c, x86::SP, frame0(m) + 4);
		if (n < 32 && m.dpmi.exc_vec[n].0 != 0) {
			to_exception_handler(m, n, err);
			return;
		};
		const f = frame0(m);
		fmt::errorfln("shifu: DPMI-programmet fik undtagelse {:_02X} (fejlkode {:x}) ved {:_04X}:{:_08X}",
			n, err, get16(m, f + 4), get32(m, f))!;
		dpmi_exit(m, 0xFF);
		return;
	};
	if (kind == 1) {
		switch (n) {
		case 0x31 =>
			int31(m);
			if (m.debug) {
				const c = m.cpu;
				fmt::errorfln("  -> AX={:_04X} BX={:_04X} CX={:_04X} DX={:_04X} SI={:_04X} DI={:_04X} CF={}",
					c.r[x86::AX], c.r[x86::BX], c.r[x86::CX], c.r[x86::DX],
					c.r[x86::SI], c.r[x86::DI], c.flags & 1)!;
			};
			return;
		case 0x2F =>
			if (c.r[x86::AX] == 0x1686) {
				c.r[x86::AX] = 0; // yes, in protected mode
				return;
			};
		case 0x21 =>
			if (x86::get8(c, 4) == 0x4C) {
				dpmi_exit(m, x86::get8(c, 0));
				return;
			};
		case => void;
		};
	};
	if (m.dpmi.pm_vec[n].0 != 0) {
		to_client_handler(m, n);
		return;
	};
	reflect(m, n, frame0(m), true, kind == 2);
};

fn ivt_entry(m: *machine, v: u8) u32 =
	x86::read16(m.cpu, 0, v: u16 * 4): u32 |
	x86::read16(m.cpu, 0, v: u16 * 4 + 2): u32 << 16;

// The vectors of IRQ 0-7 and 8-15 in real mode.
fn irq_vector(n: u8) bool = (n >= 0x08 && n <= 0x0F) || (n >= 0x70 && n <= 0x77);

// Callback 400h+n: the client chained to the default handler for n
// (the frame, of its own size, is on its stack).
fn pm_default(m: *machine, n: u8) void = {
	const c = m.cpu;
	reflect(m, n, c.sbase[x86::SS] + (if (m.dpmi.big) x86::get32(c, x86::SP)
		else c.r[x86::SP]: u32), m.dpmi.big, irq_vector(n));
};

// The DPMI exception frame on the exception stack, and the client's
// handler, which returns with RETF to S3_EXCRET.
fn to_exception_handler(m: *machine, n: u8, err: u32) void = {
	const c = m.cpu;
	const f = frame0(m);
	const eip = get32(m, f), cs = get16(m, f + 4), fl = get32(m, f + 8);
	const esp = get32(m, f + 12), ss = get16(m, f + 16);
	x86::set32(c, x86::SP, f + 20);
	const xs = m.dpmi.sel_exc;
	let sp = 0x2000u32;
	cpush(m, xs, &sp, ss);
	cpush(m, xs, &sp, esp);
	cpush(m, xs, &sp, fl);
	cpush(m, xs, &sp, cs);
	cpush(m, xs, &sp, eip);
	cpush(m, xs, &sp, err);
	cpush(m, xs, &sp, SEL_H3CODE);
	cpush(m, xs, &sp, S3_EXCRET);
	c.flags = (fl: u16 & ~(x86::IF | x86::TF)) | 2;
	const (hs, ho) = m.dpmi.exc_vec[n];
	enter_client(m, hs, ho, xs, sp);
};

// Callback 115h: back from the client's exception handler; carry on as
// the (maybe changed) frame says.
fn exception_returned(m: *machine) void = {
	const c = m.cpu;
	const base = c.sbase[x86::SS];
	let sp = if (m.dpmi.big) x86::get32(c, x86::SP) else c.r[x86::SP]: u32;
	const w: u32 = if (m.dpmi.big) 4 else 2;
	const rd = if (m.dpmi.big) &get32 else &get16w;
	sp += w; // the error code
	const eip = rd(m, base + sp);
	const cs = rd(m, base + sp + w): u16;
	const fl = rd(m, base + sp + w * 2);
	const esp = rd(m, base + sp + w * 3);
	const ss = rd(m, base + sp + w * 4): u16;
	c.flags = (fl: u16 & 0x7FD5) | 0x3002; // IOPL 3
	enter_client(m, cs, eip, ss, esp);
};

fn get16w(m: *machine, a: u32) u32 = get16(m, a);

// ---- Hardware interrupts while in real mode ----

// The PC calls this for an IRQ while the client is down in real mode:
// if the client has a protected-mode handler, it gets it (true).
fn dpmi_rm_irq(m: *machine, v: u8) bool = {
	const c = m.cpu;
	if (!m.dpmi.active || x86::protected(c) || m.dpmi.pm_vec[v].0 == 0) {
		return false;
	};
	if (ivt_entry(m, v) != m.dpmi.ivt0[v]) return false;
	if (len(m.dpmi.pmsaves) == 0) return false;
	append(m.dpmi.rmsaves, rmstate {
		r = c.r, rh = c.rh, s = c.s, flags = c.flags, ip = c.ip,
		kind = 0, cb = 0, rm_sp = m.dpmi.rm_sp,
	})!;
	// Protected mode with the client's segments as they were.
	const st = &m.dpmi.pmsaves[len(m.dpmi.pmsaves) - 1];
	c.s = st.s;
	c.sbase = st.sbase;
	c.slimit = st.slimit;
	c.sattr = st.sattr;
	to_pm(m);
	const irqs = m.dpmi.sel_irq;
	let sp = irq_stack(m);
	cpush(m, irqs, &sp, c.flags);
	cpush(m, irqs, &sp, SEL_H3CODE);
	cpush(m, irqs, &sp, S3_IRQRET);
	c.flags = (c.flags & ~(x86::IF | x86::TF)) | 0x3002;
	const (hs, ho) = m.dpmi.pm_vec[v];
	enter_client(m, hs, ho, irqs, sp);
	c.halted = false;
	return true;
};

// Callback 114h (IRQ) or 118h (real-mode callback): back to real mode.
fn rm_resume(m: *machine) void = {
	const c = m.cpu;
	const n = len(m.dpmi.rmsaves);
	if (n == 0) return;
	const st = m.dpmi.rmsaves[n - 1];
	delete(m.dpmi.rmsaves[n - 1]);
	irq_stack_done(m);
	if (st.kind == 1) {
		// A callback: the registers come from the client's structure.
		const cb = m.dpmi.callbacks[st.cb];
		const a = desc_base(m, cb.st_sel) + cb.st_off;
		to_rm(m);
		const regs: [8]size = [x86::DI, x86::SI, x86::BP, x86::SP,
			x86::BX, x86::DX, x86::CX, x86::AX];
		for (let i = 0z; i < 8; i += 1) {
			if (i == 3) continue;
			x86::set32(c, regs[i], get32(m, a + i: u32 * 4));
		};
		c.flags = (get16(m, a + 0x20) & 0x0FD5) | 2;
		c.s[x86::ES] = get16(m, a + 0x22);
		c.s[x86::DS] = get16(m, a + 0x24);
		c.s[x86::FS] = get16(m, a + 0x26);
		c.s[x86::GS] = get16(m, a + 0x28);
		c.s[x86::SS] = get16(m, a + 0x30);
		c.r[x86::SP] = get16(m, a + 0x2E);
		c.s[x86::CS] = get16(m, a + 0x2C);
		set_eip(c, get16(m, a + 0x2A));
		m.dpmi.rm_sp = st.rm_sp;
		return;
	};
	to_rm(m);
	c.r = st.r;
	c.rh = st.rh;
	c.s = st.s;
	c.flags = st.flags;
	m.dpmi.rm_sp = st.rm_sp;
	set_eip(c, st.ip);
};

// Callback 300h+i: real-mode code called real-mode callback i: the
// client's procedure gets the real-mode registers in its structure and
// DS:(E)SI pointing at the real-mode stack; it returns with IRET.
fn rm_callback(m: *machine, i: size) void = {
	const c = m.cpu;
	const cb = m.dpmi.callbacks[i];
	if (!cb.used || len(m.dpmi.pmsaves) == 0) return;
	const a = desc_base(m, cb.st_sel) + cb.st_off;
	const regs: [8]size = [x86::DI, x86::SI, x86::BP, x86::SP,
		x86::BX, x86::DX, x86::CX, x86::AX];
	for (let k = 0z; k < 8; k += 1) {
		put32(m, a + k: u32 * 4, x86::get32(c, regs[k]));
	};
	put16(m, a + 0x20, c.flags);
	put16(m, a + 0x22, c.s[x86::ES]);
	put16(m, a + 0x24, c.s[x86::DS]);
	put16(m, a + 0x26, c.s[x86::FS]);
	put16(m, a + 0x28, c.s[x86::GS]);
	put16(m, a + 0x2A, c.ip);
	put16(m, a + 0x2C, c.s[x86::CS]);
	put16(m, a + 0x2E, c.r[x86::SP]);
	put16(m, a + 0x30, c.s[x86::SS]);
	append(m.dpmi.rmsaves, rmstate {
		r = c.r, rh = c.rh, s = c.s, flags = c.flags, ip = c.ip,
		kind = 1, cb = i, rm_sp = m.dpmi.rm_sp,
	})!;
	const rmss = c.s[x86::SS], rmsp = c.r[x86::SP];
	const st = &m.dpmi.pmsaves[len(m.dpmi.pmsaves) - 1];
	c.s = st.s;
	c.sbase = st.sbase;
	c.slimit = st.slimit;
	c.sattr = st.sattr;
	to_pm(m);
	// DS:(E)SI = the real-mode stack, ES:(E)DI = the structure.
	const sel = seg_selector(m, rmss);
	cache(m, x86::DS, sel);
	x86::set32(c, x86::SI, rmsp);
	cache(m, x86::ES, cb.st_sel);
	x86::set32(c, x86::DI, cb.st_off);
	const irqs = m.dpmi.sel_irq;
	let sp = irq_stack(m);
	cpush(m, irqs, &sp, c.flags | 0x3002);
	cpush(m, irqs, &sp, SEL_H3CODE);
	cpush(m, irqs, &sp, S3_CBRET);
	c.flags = (c.flags & ~(x86::IF | x86::TF)) | 0x3002;
	enter_client(m, cb.pm_sel, cb.pm_off, irqs, sp);
};

// 0002h: a selector for a real-mode segment (the same one each time).
fn seg_selector(m: *machine, seg: u16) u16 = {
	for (let i = 0z; i < 256; i += 1) {
		const s = m.dpmi.rm_vec_sel[i];
		if (s != 0 && ldt_valid(m, s) && desc_base(m, s) == seg: u32 << 4 &&
				desc_limit(m, s) == 0xFFFF) {
			return s;
		};
	};
	const s = match (ldt_alloc(m, 1)) {
	case let s: u16 => yield s;
	case void => return 0;
	};
	put_desc(m, desc_at(m, s), seg: u32 << 4, 0xFFFF, 0xF2, 0);
	for (let i = 0z; i < 256; i += 1) {
		if (m.dpmi.rm_vec_sel[i] == 0) {
			m.dpmi.rm_vec_sel[i] = s;
			break;
		};
	};
	return s;
};

// ---- Raw mode switches (0306h) ----

// Callback 116h, in real mode: AX=DS CX=ES DX=SS (E)BX=(E)SP SI=CS
// (E)DI=(E)IP (selectors) into protected mode.
fn raw_to_pm(m: *machine) void = {
	const c = m.cpu;
	const ds = c.r[x86::AX], es = c.r[x86::CX], ss = c.r[x86::DX];
	const cs = c.r[x86::SI];
	const esp = if (m.dpmi.big) x86::get32(c, x86::BX) else c.r[x86::BX]: u32;
	const eip = if (m.dpmi.big) x86::get32(c, x86::DI) else c.r[x86::DI]: u32;
	to_pm(m);
	cache(m, x86::DS, ds);
	cache(m, x86::ES, es);
	cache(m, x86::FS, 0);
	cache(m, x86::GS, 0);
	c.flags |= 0x3000;
	enter_client(m, cs, eip, ss, esp);
};

// Callback 117h, in protected mode: AX=DS CX=ES DX=SS (E)BX=SP SI=CS
// (E)DI=IP (segments) into real mode.
fn raw_to_rm(m: *machine) void = {
	const c = m.cpu;
	const ds = c.r[x86::AX], es = c.r[x86::CX], ss = c.r[x86::DX];
	const cs = c.r[x86::SI];
	const sp = c.r[x86::BX], ip = c.r[x86::DI];
	to_rm(m);
	c.s[x86::DS] = ds;
	c.s[x86::ES] = es;
	c.s[x86::FS] = 0;
	c.s[x86::GS] = 0;
	c.s[x86::SS] = ss;
	c.r[x86::SP] = sp;
	c.s[x86::CS] = cs;
	c.flags &= 0x0FFF;
	set_eip(c, ip);
};

// ---- Entering protected mode (INT 2Fh AX=1687h's entry point) ----

// Callback 110h: the program called the entry point in real mode with
// AX bit 0 set for a 32-bit client.
fn dpmi_enter(m: *machine) void = {
	const c = m.cpu;
	if (m.dpmi.active) {
		c.flags |= x86::CF; // one client at a time
		return;
	};
	const d = &m.dpmi;
	d.active = true;
	d.big = c.r[x86::AX] & 1 != 0;
	d.psp = m.psp;
	d.ldt_used = [false...];
	d.ldt_next = 1;
	for (let i = 0z; i < 256; i += 1) d.ivt0[i] = ivt_entry(m, i: u8);
	d.pm_vec = [(0, 0)...];
	d.exc_vec = [(0, 0)...];
	d.rm_vec_sel = [0...];
	d.pmsaves = d.pmsaves[..0];
	d.rmsaves = d.rmsaves[..0];
	d.pmirqs = d.pmirqs[..0];
	d.irq_depth = 0;
	d.callbacks = [rmcallback { ... }...];
	d.rm_sp = RM_STACK_TOP;
	build_tables(m);
	// The host's tables are near 16 MiB: A20 stays open from now on.
	m.xms.a20_global = true;
	x86::set_a20(c, true);

	// The far call's return address.
	const ret_ip = rm_pop(m), ret_cs = rm_pop(m);
	// Descriptors for the program's code, data and stack, its PSP and
	// its environment.
	const cs = ldt_alloc(m, 1) as u16;
	put_desc(m, desc_at(m, cs), ret_cs: u32 << 4, 0xFFFF, 0xFA, 0);
	const ds = ldt_alloc(m, 1) as u16;
	put_desc(m, desc_at(m, ds), c.s[x86::DS]: u32 << 4, 0xFFFF, 0xF2, 0);
	const ss = if (c.s[x86::SS] == c.s[x86::DS]) ds else {
		const s = ldt_alloc(m, 1) as u16;
		put_desc(m, desc_at(m, s), c.s[x86::SS]: u32 << 4, 0xFFFF, 0xF2, 0);
		yield s;
	};
	const ps = ldt_alloc(m, 1) as u16;
	put_desc(m, desc_at(m, ps), m.psp: u32 << 4, 0xFF, 0xF2, 0);
	d.env_seg = x86::read16(c, m.psp, 0x2C);
	if (d.env_seg != 0) {
		const es = ldt_alloc(m, 1) as u16;
		put_desc(m, desc_at(m, es), d.env_seg: u32 << 4, 0x7FFF, 0xF2, 0);
		x86::write16(c, m.psp, 0x2C, es);
	};
	d.sel_exc = ldt_alloc(m, 1) as u16;
	put_desc(m, desc_at(m, d.sel_exc), H_EXCSTACK - 0x2000, 0x1FFF, 0xF2,
		if (d.big) 0x4 else 0);
	d.sel_irq = ldt_alloc(m, 1) as u16;
	put_desc(m, desc_at(m, d.sel_irq), H_IRQSTACK - 0x2000, 0x1FFF, 0xF2,
		if (d.big) 0x4 else 0);

	// Into protected mode, ring 3, IOPL 3.
	c.ldtr = SEL_LDT;
	c.ldt_base = H_LDT;
	c.ldt_limit = LDT_ENTRIES: u32 * 8 - 1;
	c.tr = SEL_TSS;
	c.tr_base = H_TSS;
	c.tr_limit = 103;
	c.tr_attr = 0x8B;
	to_pm(m);
	const sp = c.r[x86::SP];
	cache(m, x86::DS, ds);
	cache(m, x86::ES, ps);
	cache(m, x86::FS, 0);
	cache(m, x86::GS, 0);
	c.flags = (c.flags & ~x86::CF & 0x0FFF) | 0x3000;
	enter_client(m, cs, ret_ip, ss, sp);
	if (m.debug) fmt::errorfln("DPMI: {}-bit klient i protected mode", if (d.big) 32 else 16)!;
};

// The host's GDT, TSS, IDT and stubs.
fn build_tables(m: *machine) void = {
	for (let a = HOST; a < HOST + 0x5000; a += 1) m.cpu.mem[a] = 0;
	put_desc(m, H_GDT + SEL_HCODE, H_STUB0, 0x7FF, 0x9A, 0);
	put_desc(m, H_GDT + SEL_HDATA, 0, 0xFFFFFFFF, 0x92, 0x4);
	put_desc(m, H_GDT + SEL_LDT, H_LDT, LDT_ENTRIES: u32 * 8 - 1, 0x82, 0);
	put_desc(m, H_GDT + SEL_TSS, H_TSS, 103, 0x8B, 0);
	put_desc(m, H_GDT + (SEL_H3CODE & 0xFFF8), H_STUB3, 0xFFF, 0xFA, 0);
	put_desc(m, H_GDT + SEL_BIOS, 0x400, 0xFFFF, 0xF2, 0);
	put32(m, H_TSS + 4, H_STACK0);
	put16(m, H_TSS + 8, SEL_HDATA);
	put16(m, H_TSS + 0x66, 104); // no I/O bitmap: IOPL 3 lets them all
	for (let n = 0u32; n < 256; n += 1) {
		// IDT: 32-bit interrupt gates, DPL 3 (so INT n works from the
		// program), to ring 0's stub n.
		const g = H_IDT + n * 8;
		put16(m, g, (n * 8): u16);
		put16(m, g + 2, SEL_HCODE);
		put8(m, g + 4, 0);
		put8(m, g + 5, 0xEE);
		put16(m, g + 6, 0);
		// Ring 0 stub: callback 200h+n; IRETD.
		const s = H_STUB0 + n * 8;
		const cb = 0x200 + n: u16;
		put8(m, s, 0xFE);
		put8(m, s + 1, 0x38);
		put16(m, s + 2, cb);
		put8(m, s + 4, 0x66);
		put8(m, s + 5, 0xCF);
		// Ring 3 default handler: callback 400h+n; IRET(D).
		const t = H_STUB3 + n * 8;
		put8(m, t, 0xFE);
		put8(m, t + 1, 0x38);
		put16(m, t + 2, 0x400 + n: u16);
		put8(m, t + 4, if (m.dpmi.big) 0x66 else 0x90);
		put8(m, t + 5, 0xCF);
	};
	const specials: [_](u16, u16) = [(S3_IRQRET, 0x114), (S3_EXCRET, 0x115),
		(S3_RAW, 0x117), (S3_CBRET, 0x118), (S3_PMIRQRET, 0x119)];
	for (let (off, cb) .. specials) {
		const t = H_STUB3 + off;
		put8(m, t, 0xFE);
		put8(m, t + 1, 0x38);
		put16(m, t + 2, cb);
	};
	put8(m, H_STUB3 + S3_RETF, if (m.dpmi.big) 0x66 else 0x90);
	put8(m, H_STUB3 + S3_RETF + 1, 0xCB);
};

// The program ends (INT 21h AH=4Ch in protected mode, or an exception
// it didn't handle): back to real mode for good, and DOS ends it.
fn dpmi_exit(m: *machine, code: u8) void = {
	const c = m.cpu;
	const d = &m.dpmi;
	for (let h .. d.memblocks) match (find_emb(m, h)) {
	case let i: size => delete(m.xms.blocks[i]);
	case void => void;
	};
	d.memblocks = d.memblocks[..0];
	if (d.env_seg != 0) x86::write16(c, d.psp, 0x2C, d.env_seg);
	d.active = false;
	d.pmsaves = d.pmsaves[..0];
	d.rmsaves = d.rmsaves[..0];
	to_rm(m);
	c.ldtr = 0;
	c.tr = 0;
	c.tr_attr = 0;
	c.flags &= 0x0FFF;
	// DOS needs a real-mode stack to work on.
	c.s[x86::SS] = ROMSEG;
	c.r[x86::SP] = RM_STACK_TOP;
	terminate(m, code, false, 0);
};

// ---- INT 31h ----

fn dpmi_ok(m: *machine) void = set_cf(m, false);

fn dpmi_err(m: *machine, code: u16) void = {
	m.cpu.r[x86::AX] = code;
	set_cf(m, true);
};

fn reg32(m: *machine, r: size) u32 =
	if (m.dpmi.big) x86::get32(m.cpu, r) else m.cpu.r[r]: u32;

fn int31(m: *machine) void = {
	const c = m.cpu;
	const ax = c.r[x86::AX], bx = c.r[x86::BX];
	const cx = c.r[x86::CX], dx = c.r[x86::DX];
	if (m.debug) fmt::errorfln("INT 31 AX={:_04X} BX={:_04X} CX={:_04X} DX={:_04X}", ax, bx, cx, dx)!;
	dpmi_ok(m);
	switch (ax) {
	case 0x0000 => // allocate descriptors
		match (ldt_alloc(m, cx)) {
		case let s: u16 => c.r[x86::AX] = s;
		case void => dpmi_err(m, 0x8011);
		};
	case 0x0001 => // free a descriptor
		if (!ldt_valid(m, bx)) return dpmi_err(m, 0x8022);
		m.dpmi.ldt_used[bx >> 3] = false;
		// Segment registers holding it become null.
		for (let i = 0z; i < 6; i += 1) {
			if (i != x86::CS && i != x86::SS && c.s[i] & 0xFFF8 == bx & 0xFFF8) {
				cache(m, i, 0);
			};
		};
	case 0x0002 => // a segment as a selector
		const s = seg_selector(m, bx);
		if (s == 0) return dpmi_err(m, 0x8011);
		c.r[x86::AX] = s;
	case 0x0003 => c.r[x86::AX] = 8; // selector increment
	case 0x0006 => // get base
		if (!ldt_valid(m, bx) && bx & 4 != 0) return dpmi_err(m, 0x8022);
		const b = desc_base(m, bx);
		c.r[x86::CX] = (b >> 16): u16;
		c.r[x86::DX] = b: u16;
	case 0x0007 => // set base
		if (!ldt_valid(m, bx)) return dpmi_err(m, 0x8022);
		const a = desc_at(m, bx), b = cx: u32 << 16 | dx;
		put16(m, a + 2, b: u16);
		put8(m, a + 4, (b >> 16): u8);
		put8(m, a + 7, (b >> 24): u8);
		refresh(m, bx);
	case 0x0008 => // set limit
		if (!ldt_valid(m, bx)) return dpmi_err(m, 0x8022);
		let lim = cx: u32 << 16 | dx;
		const a = desc_at(m, bx);
		let fl = c.mem[a + 6] & 0x70;
		if (lim > 0xFFFFF) {
			if (lim & 0xFFF != 0xFFF) return dpmi_err(m, 0x8021);
			lim >>= 12;
			fl |= 0x80;
		};
		put16(m, a, lim: u16);
		put8(m, a + 6, fl | ((lim >> 16): u8 & 0xF));
		refresh(m, bx);
	case 0x0009 => // set access rights (CL), and CH: G, D/B, AVL
		if (!ldt_valid(m, bx)) return dpmi_err(m, 0x8022);
		const cl = x86::get8(c, 1), ch = x86::get8(c, 5);
		if (cl & 0x60 != 0x60 || cl & 0x10 == 0) return dpmi_err(m, 0x8021);
		const a = desc_at(m, bx);
		put8(m, a + 5, cl);
		put8(m, a + 6, (c.mem[a + 6] & 0x0F) | (ch & 0xD0));
		refresh(m, bx);
	case 0x000A => // a data alias of a descriptor
		if (!ldt_valid(m, bx)) return dpmi_err(m, 0x8022);
		const s = match (ldt_alloc(m, 1)) {
		case let s: u16 => yield s;
		case void => return dpmi_err(m, 0x8011);
		};
		const from = desc_at(m, bx), to = desc_at(m, s);
		for (let i = 0u32; i < 8; i += 1) c.mem[to + i] = c.mem[from + i];
		put8(m, to + 5, 0xF2);
		c.r[x86::AX] = s;
	case 0x000B => // get the descriptor (8 bytes at ES:(E)DI)
		if (bx & 0xFFF8 == 0) return dpmi_err(m, 0x8022);
		const from = desc_at(m, bx), to = ptr(m, x86::ES, x86::DI);
		for (let i = 0u32; i < 8; i += 1) c.mem[to + i] = c.mem[from + i];
	case 0x000C => // set it
		if (!ldt_valid(m, bx)) return dpmi_err(m, 0x8022);
		const from = ptr(m, x86::ES, x86::DI), to = desc_at(m, bx);
		if (c.mem[from + 5] & 0x60 != 0x60) return dpmi_err(m, 0x8021);
		for (let i = 0u32; i < 8; i += 1) c.mem[to + i] = c.mem[from + i];
		refresh(m, bx);
	case 0x000D => // a specific descriptor (BX: one of the first 16)
		const i = bx >> 3;
		if (bx & 4 == 0 || i == 0 || i >= 16 || m.dpmi.ldt_used[i]) {
			return dpmi_err(m, 0x8011);
		};
		m.dpmi.ldt_used[i] = true;
		put_desc(m, desc_at(m, bx), 0, 0, 0xF2, 0);
	case 0x0100 => // DOS memory: BX paragraphs
		match (mem_alloc(m, bx, m.psp)) {
		case let seg: u16 =>
			const s = match (ldt_alloc(m, 1)) {
			case let s: u16 => yield s;
			case void =>
				mem_free(m, seg): void;
				return dpmi_err(m, 0x8011);
			};
			put_desc(m, desc_at(m, s), seg: u32 << 4, bx: u32 * 16 - 1, 0xF2, 0);
			c.r[x86::AX] = seg;
			c.r[x86::DX] = s;
		case let e: (u16, doserr) =>
			c.r[x86::BX] = e.0;
			dpmi_err(m, e.1: u16);
		};
	case 0x0101 => // free DOS memory (DX: its selector)
		if (!ldt_valid(m, dx)) return dpmi_err(m, 0x8022);
		const seg = (desc_base(m, dx) >> 4): u16;
		match (mem_free(m, seg)) {
		case void => m.dpmi.ldt_used[dx >> 3] = false;
		case let e: doserr => dpmi_err(m, e: u16);
		};
	case 0x0102 => // resize it
		if (!ldt_valid(m, dx)) return dpmi_err(m, 0x8022);
		const seg = (desc_base(m, dx) >> 4): u16;
		match (mem_resize(m, seg, bx)) {
		case void =>
			const a = desc_at(m, dx);
			put16(m, a, (bx: u32 * 16 - 1): u16);
			put8(m, a + 6, (c.mem[a + 6] & 0xF0) | ((bx: u32 * 16 - 1) >> 16): u8);
		case let e: (u16, doserr) =>
			c.r[x86::BX] = e.0;
			dpmi_err(m, e.1: u16);
		};
	case 0x0200 => // real-mode interrupt vector BL: CX:DX
		const n = x86::get8(c, 3): u16;
		c.r[x86::DX] = x86::read16(c, 0, n * 4);
		c.r[x86::CX] = x86::read16(c, 0, n * 4 + 2);
	case 0x0201 =>
		const n = x86::get8(c, 3): u16;
		x86::write16(c, 0, n * 4, dx);
		x86::write16(c, 0, n * 4 + 2, cx);
	case 0x0202 => // exception handler BL: CX:(E)DX
		const n = x86::get8(c, 3);
		if (n >= 32) return dpmi_err(m, 0x8021);
		const (s, o) = m.dpmi.exc_vec[n];
		c.r[x86::CX] = if (s == 0) SEL_H3CODE else s;
		x86::set32(c, x86::DX, if (s == 0) S3_RETF else o);
	case 0x0203 =>
		const n = x86::get8(c, 3);
		if (n >= 32) return dpmi_err(m, 0x8021);
		m.dpmi.exc_vec[n] = if (cx == SEL_H3CODE) (0, 0) else (cx, reg32(m, x86::DX));
	case 0x0204 => // protected-mode interrupt vector BL: CX:(E)DX
		const n = x86::get8(c, 3);
		const (s, o) = m.dpmi.pm_vec[n];
		c.r[x86::CX] = if (s == 0) SEL_H3CODE else s;
		x86::set32(c, x86::DX, if (s == 0) n: u32 * 8 else o);
	case 0x0205 =>
		const n = x86::get8(c, 3);
		// Setting it back to the host's default handler.
		m.dpmi.pm_vec[n] = if (cx == SEL_H3CODE) (0, 0) else (cx, reg32(m, x86::DX));
	case 0x0300, 0x0301, 0x0302 => // real mode: INT, RETF call, IRET call
		rm_call_struct(m, (ax & 3): u8);
	case 0x0303 => // allocate a real-mode callback
		for (let i = 0z; i < RM_CALLBACK_N; i += 1) {
			if (m.dpmi.callbacks[i].used) continue;
			m.dpmi.callbacks[i] = rmcallback {
				used = true,
				pm_sel = c.s[x86::DS],
				pm_off = reg32(m, x86::SI),
				st_sel = c.s[x86::ES],
				st_off = reg32(m, x86::DI),
			};
			c.r[x86::CX] = ROMSEG;
			c.r[x86::DX] = RM_CALLBACKS + i: u16 * 8;
			return;
		};
		dpmi_err(m, 0x8015);
	case 0x0304 => // free one
		if (cx != ROMSEG || dx < RM_CALLBACKS) return dpmi_err(m, 0x8024);
		const i = ((dx - RM_CALLBACKS) / 8): size;
		if (i >= RM_CALLBACK_N) return dpmi_err(m, 0x8024);
		m.dpmi.callbacks[i].used = false;
	case 0x0305 => // save/restore state: nothing to save
		c.r[x86::AX] = 0;
		c.r[x86::BX] = ROMSEG;
		c.r[x86::CX] = RM_RETF;
		c.r[x86::SI] = SEL_H3CODE;
		x86::set32(c, x86::DI, S3_RETF);
	case 0x0306 => // raw mode switch addresses
		c.r[x86::BX] = ROMSEG;
		c.r[x86::CX] = RM_RAW;
		c.r[x86::SI] = SEL_H3CODE;
		x86::set32(c, x86::DI, S3_RAW);
	case 0x0400 => // version 0.90, 32-bit, interrupts back to real mode
		c.r[x86::AX] = 0x005A;
		c.r[x86::BX] = 0x0003;
		x86::set8(c, 1, 3); // a 386
		c.r[x86::DX] = 0x0870; // PIC bases
	case 0x0500 => // free memory information
		const a = ptr(m, x86::ES, x86::DI);
		const (largest, total) = xms_free_kb(m);
		for (let i = 0u32; i < 48; i += 4) put32(m, a + i, 0xFFFFFFFF);
		put32(m, a, largest * 1024);
		put32(m, a + 4, largest / 4);
		put32(m, a + 8, largest / 4);
		put32(m, a + 0x0C, (XMS_END_KB - XMS_START_KB) / 4);
		put32(m, a + 0x10, total / 4);
		put32(m, a + 0x14, total / 4);
		put32(m, a + 0x18, (XMS_END_KB - XMS_START_KB) / 4);
		put32(m, a + 0x1C, total / 4);
		put32(m, a + 0x20, 0);
	case 0x0501 => // allocate memory: BX:CX bytes -> BX:CX linear, SI:DI handle
		const n = bx: u32 << 16 | cx;
		if (n == 0) return dpmi_err(m, 0x8021);
		match (xms_alloc(m, (n + 1023) / 1024)) {
		case let h: u16 =>
			append(m.dpmi.memblocks, h)!;
			const a = m.xms.blocks[find_emb(m, h) as size].start * 1024;
			c.r[x86::BX] = (a >> 16): u16;
			c.r[x86::CX] = a: u16;
			c.r[x86::SI] = 0;
			c.r[x86::DI] = h;
		case u8 => dpmi_err(m, 0x8013);
		};
	case 0x0502 => // free it (SI:DI)
		const h = c.r[x86::DI];
		match (find_emb(m, h)) {
		case let i: size =>
			delete(m.xms.blocks[i]);
			for (let k = 0z; k < len(m.dpmi.memblocks); k += 1) {
				if (m.dpmi.memblocks[k] == h) {
					delete(m.dpmi.memblocks[k]);
					break;
				};
			};
		case void => dpmi_err(m, 0x8023);
		};
	case 0x0503 => // resize it: BX:CX bytes, SI:DI handle
		const h = c.r[x86::DI];
		const n = bx: u32 << 16 | cx;
		const e = xms_realloc(m, h, (n + 1023) / 1024);
		if (e != 0) return dpmi_err(m, if (e == 0xA2) 0x8023 else 0x8013);
		const a = m.xms.blocks[find_emb(m, h) as size].start * 1024;
		c.r[x86::BX] = (a >> 16): u16;
		c.r[x86::CX] = a: u16;
	case 0x0600, 0x0601, 0x0602, 0x0603, 0x0702, 0x0703 => void; // locking
	case 0x0604 => // page size
		c.r[x86::BX] = 0;
		c.r[x86::CX] = 4096;
	case 0x0800 => // physical address -> linear: the same here
		void;
	case 0x0801 => void;
	case 0x0900, 0x0901, 0x0902 => // virtual interrupt flag (= the real one)
		const f = frame0(m) + 8;
		const fl = get16(m, f);
		x86::set8(c, 0, if (fl & x86::IF != 0) 1 else 0);
		if (ax == 0x0900) put16(m, f, fl & ~x86::IF);
		if (ax == 0x0901) put16(m, f, fl | x86::IF);
	case 0x0E00 => c.r[x86::AX] = 0x0035; // a 387, MP set, not emulated
	case 0x0E01 => dpmi_err(m, 0x8001);
	case => dpmi_err(m, 0x8001); // not supported
	};
};

// After a descriptor changed, segment registers holding it are loaded
// again (as hosts do, so the change shows at once).
fn refresh(m: *machine, sel: u16) void = {
	const c = m.cpu;
	const regs: [4]size = [x86::DS, x86::ES, x86::FS, x86::GS];
	for (let i .. regs) {
		if (c.s[i] & 0xFFF8 == sel & 0xFFF8 && c.s[i] & 4 != 0) cache(m, i, c.s[i]);
	};
};

// ---- Callbacks ----

// Callbacks 110h-1FFh and 200h-4FFh belong to the DPMI host.
fn dpmi_callback(m: *machine, n: u16) void = {
	switch (n) {
	case 0x110 => dpmi_enter(m);
	case 0x113 => rm_returned(m);
	case 0x114, 0x118 => rm_resume(m);
	case 0x115 => exception_returned(m);
	case 0x116 => raw_to_pm(m);
	case 0x119 => pm_irq_returned(m);
	case 0x117 => raw_to_rm(m);
	case =>
		if (n >= 0x200 && n < 0x300) {
			pm_interrupt(m, (n - 0x200): u8);
		} else if (n >= 0x300 && n < 0x300 + RM_CALLBACK_N: u16) {
			rm_callback(m, (n - 0x300): size);
		} else if (n >= 0x400 && n < 0x500) {
			pm_default(m, (n - 0x400): u8);
		};
	};
};

// For SHIFU_DEBUG: how deep the host's own stacks are.
fn dpmi_status(m: *machine) void = {
	if (!m.dpmi.active) return;
	const d = &m.dpmi;
	fmt::errorfln("DPMI: pmsaves={} rmsaves={} pmirqs={} irq_depth={} rm_sp={:_04X}",
		len(d.pmsaves), len(d.rmsaves), len(d.pmirqs), d.irq_depth, d.rm_sp)!;
	for (let v .. [0x08u8, 0x09, 0x0F, 0x74]) {
		fmt::errorfln("  vektor {:_02X}: RM {:_08X} (start {:_08X}) PM {:_04X}:{:_08X}",
			v, ivt_entry(m, v), d.ivt0[v], d.pm_vec[v].0, d.pm_vec[v].1)!;
	};
};
