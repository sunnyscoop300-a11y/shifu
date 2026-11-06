// Shifu — sound: the PC speaker, the AdLib (opl.ha) and the Sound Blaster
// (sb.ha), mixed to 44.1 kHz mono. Programs change the sound chips at
// exact moments in emulated time; those changes are logged with their
// time, and [[sound_render]] plays them back sample by sample, so the
// sound is as exact as the timing.

export def AUDIO_RATE: u64 = 44100;

// The speaker's state at a moment: port 61h and PIT channel 2.
export type spkstate = struct {
	t: u64,       // PIT ticks
	port61: u8,
	reload: u64,
	mode: u8,
	start: u64,
	counting: bool,
};

export type oplwrite = struct {
	t: u64,       // vtime (PIT ticks << 16)
	reg: u8,
	val: u8,
};

// Turns sound on or off. With it off (tests, pipes), nothing is
// synthesized, but the chips still answer programs the same way.
export fn enable_audio(m: *machine, on: bool) void = {
	m.audio_on = on;
	m.snd_t = m.vtime;
};

// The samples made since the last call (valid until the PC runs again).
export fn take_audio(m: *machine) []f32 = {
	const s = m.audio_out;
	m.audio_out = m.audio_out[..0];
	return s;
};

// Notes the speaker's state now (after port 61h or timer 2 changed).
fn speaker_changed(m: *machine) void = {
	const ch = &m.pit[2];
	const st = spkstate {
		t = now(m),
		port61 = m.port61,
		reload = ch.reload,
		mode = ch.mode,
		start = ch.start,
		counting = ch.counting,
	};
	if (!m.audio_on) {
		m.spk = st;
		return;
	};
	append(m.spk_ev, st)!;
};

// The speaker cone: in (1) or out (0) at PIT tick t.
fn speaker_level(st: *spkstate, t: u64) f32 = {
	if (st.port61 & 2 == 0) return 0.0;
	if (st.port61 & 1 == 0 || !st.counting) return 1.0; // gate off: OUT2 high
	const el = if (t > st.start) t - st.start else 0u64;
	switch (st.mode) {
	case 3 => return if (el % st.reload < st.reload / 2) 1.0 else 0.0;
	case 0 => return if (el >= st.reload) 1.0 else 0.0;
	case 2 => return if (el % st.reload == st.reload - 1) 0.0 else 1.0;
	case => return 1.0;
	};
};

// Makes the samples for the emulated time since the last call.
fn sound_render(m: *machine) void = {
	if (!m.audio_on) {
		free_events(m);
		m.snd_t = m.vtime;
		return;
	};
	// One sample every PIT_HZ / 44100 ticks (in 16.16 fixed point).
	const step = (PIT_HZ << 16) / AUDIO_RATE;
	let ospk = 0z, oopl = 0z;
	for (m.snd_t + step <= m.vtime) {
		const ts = m.snd_t;
		// Speaker: the average of 4 points across the sample, so tones
		// above the sample rate don't alias badly.
		let lvl = 0.0f32;
		for (let k = 0u64; k < 4; k += 1) {
			const tk = (ts + step * k / 4) >> 16;
			for (ospk < len(m.spk_ev) && m.spk_ev[ospk].t <= tk) {
				m.spk = m.spk_ev[ospk];
				ospk += 1;
			};
			lvl += speaker_level(&m.spk, tk);
		};
		lvl /= 4.0;
		// Take the DC away (a real speaker can't hold a level).
		const hp = lvl - m.hp_in + 0.995 * m.hp_out;
		m.hp_in = lvl;
		m.hp_out = hp;

		for (oopl < len(m.opl_ev) && m.opl_ev[oopl].t <= ts) {
			opl_synth_write(&m.opl, m.opl_ev[oopl].reg, m.opl_ev[oopl].val);
			oopl += 1;
		};
		const fm = opl_sample(&m.opl);
		const dig = sb_sample(m, ts);

		let s = hp * 0.25 + fm: f32 * 0.6 + dig * 0.7;
		if (s > 1.0) s = 1.0;
		if (s < -1.0) s = -1.0;
		append(m.audio_out, s)!;
		m.snd_t += step;
	};
	delete(m.spk_ev[..ospk]);
	delete(m.opl_ev[..oopl]);
	sb_forget(m, m.snd_t);
};

fn free_events(m: *machine) void = {
	if (len(m.spk_ev) > 0) m.spk = m.spk_ev[len(m.spk_ev) - 1];
	m.spk_ev = m.spk_ev[..0];
	// The synthesizer still follows the registers (no sound is made).
	for (let w .. m.opl_ev) opl_synth_write(&m.opl, w.reg, w.val);
	m.opl_ev = m.opl_ev[..0];
	sb_forget(m, m.vtime);
};

fn sound_free(m: *machine) void = {
	free(m.spk_ev);
	free(m.opl_ev);
	free(m.audio_out);
	sb_free(m);
};
