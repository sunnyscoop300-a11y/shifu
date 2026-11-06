// Shifu — the PC character set. Shifu uses code page 865 (Nordic), what
// Danish PCs had: IBM's code page 437 with ø and Ø in place of ¢ and ¥
// (and ¤ for »).

// What each character byte looks like, as Unicode. 0 shows as a space.
export const CHARSET: [256]rune = [
	' ', '☺', '☻', '♥', '♦', '♣', '♠', '•', '◘', '○', '◙', '♂', '♀', '♪', '♫', '☼',
	'►', '◄', '↕', '‼', '¶', '§', '▬', '↨', '↑', '↓', '→', '←', '∟', '↔', '▲', '▼',
	' ', '!', '"', '#', '$', '%', '&', '\'', '(', ')', '*', '+', ',', '-', '.', '/',
	'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', ':', ';', '<', '=', '>', '?',
	'@', 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O',
	'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', '[', '\\', ']', '^', '_',
	'`', 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o',
	'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z', '{', '|', '}', '~', '⌂',
	'Ç', 'ü', 'é', 'â', 'ä', 'à', 'å', 'ç', 'ê', 'ë', 'è', 'ï', 'î', 'ì', 'Ä', 'Å',
	'É', 'æ', 'Æ', 'ô', 'ö', 'ò', 'û', 'ù', 'ÿ', 'Ö', 'Ü', 'ø', '£', 'Ø', '₧', 'ƒ',
	'á', 'í', 'ó', 'ú', 'ñ', 'Ñ', 'ª', 'º', '¿', '⌐', '¬', '½', '¼', '¡', '«', '¤',
	'░', '▒', '▓', '│', '┤', '╡', '╢', '╖', '╕', '╣', '║', '╗', '╝', '╜', '╛', '┐',
	'└', '┴', '┬', '├', '─', '┼', '╞', '╟', '╚', '╔', '╩', '╦', '╠', '═', '╬', '╧',
	'╨', '╤', '╥', '╙', '╘', '╒', '╓', '╫', '╪', '┘', '┌', '█', '▄', '▌', '▐', '▀',
	'α', 'ß', 'Γ', 'π', 'Σ', 'σ', 'µ', 'τ', 'Φ', 'Θ', 'Ω', 'δ', '∞', 'φ', 'ε', '∩',
	'≡', '±', '≥', '≤', '⌠', '⌡', '÷', '≈', '°', '∙', '·', '√', 'ⁿ', '²', '■', ' ',
];

// The CHARSET byte for a Unicode character (letters, digits and the
// 128 characters above ASCII), or void if it has none.
export fn from_unicode(r: rune) (u8 | void) = {
	if (r: u32 >= 0x20 && r: u32 <= 0x7E) return r: u32: u8;
	for (let i = 0x80z; i < 0xFF; i += 1) {
		if (CHARSET[i] == r) return i: u8;
	};
};

// Uppercase in CP865, the way DOS does it for file names.
export fn upper(b: u8) u8 = {
	if (b >= 'a' && b <= 'z') return b - 32;
	switch (b) {
	case 0x91 => return 0x92; // æ Æ
	case 0x9B => return 0x9D; // ø Ø
	case 0x86 => return 0x8F; // å Å
	case 0x84 => return 0x8E; // ä Ä
	case 0x94 => return 0x99; // ö Ö
	case 0x81 => return 0x9A; // ü Ü
	case 0x82 => return 0x90; // é É
	case 0x87 => return 0x80; // ç Ç
	case 0xA4 => return 0xA5; // ñ Ñ
	case => return b;
	};
};
