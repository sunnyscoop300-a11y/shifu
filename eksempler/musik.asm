; musik.com — "Mester Jakob" på alle tre lydchips: PC-højttaleren (timer
; 2), AdLib (FM-syntese) og Sound Blaster (samples via DMA og IRQ 7).
;	nasm -f bin musik.asm -o musik.com
	cpu 8086
	org 100h
	mov dx, t_hej
	call puts

	; ---- 1. PC-højttaleren ----
	mov dx, t_pc
	call puts
	mov si, sang
.pc:	lodsw			; AL = node, AH = ottendedele
	cmp al, 0FFh
	je .pc_slut
	mov bl, al
	xor bh, bh
	shl bx, 1
	mov al, 0B6h		; timer 2, mode 3
	out 43h, al
	mov ax, [deler + bx]
	out 42h, al
	mov al, ah
	out 42h, al
	in al, 61h		; højttaleren til
	or al, 3
	out 61h, al
	mov al, [si - 1]
	call varighed		; vent på tonen, kort pause til sidst
	in al, 61h
	and al, 0FCh
	out 61h, al
	call tik
	jmp .pc
.pc_slut:

	; ---- 2. AdLib ----
	call adlib_findes
	jc .ingen_adlib
	mov dx, t_adlib
	call puts
	mov si, instrument	; klaverlyd på kanal 0
.instr:	lodsw
	or al, al
	jz .spil
	call opl
	jmp .instr
.spil:	mov si, sang
.node:	lodsw
	cmp al, 0FFh
	je .adlib_slut
	mov bl, al
	xor bh, bh
	shl bx, 1
	mov cx, [fnum + bx]
	mov al, 0A0h		; F-nummer, lav byte
	mov ah, cl
	call opl
	mov al, 0B0h		; tast ned: oktav 4 + F-nummer høj
	mov ah, ch
	or ah, 20h | (4 << 2)
	call opl
	mov al, [si - 1]
	push cx
	call varighed
	pop cx
	mov al, 0B0h		; tast op
	mov ah, ch
	or ah, 4 << 2
	call opl
	call tik
	jmp .node
.adlib_slut:
	jmp .sb
.ingen_adlib:
	mov dx, t_ingen_adlib
	call puts

	; ---- 3. Sound Blaster ----
.sb:	call sb_findes
	jc .ingen_sb
	mov dx, t_sb
	call puts
	call sb_klar
	mov si, sang
.sb_node:
	lodsw
	cmp al, 0FFh
	je .sb_slut
	call sb_tone
	jmp .sb_node
.sb_slut:
	call sb_luk
	jmp .slut
.ingen_sb:
	mov dx, t_ingen_sb
	call puts
.slut:	mov dx, t_farvel
	call puts
	mov ax, 4C00h
	int 21h

; ---- Hjælpere ----

puts:	mov ah, 09h
	int 21h
	ret

; Venter til BIOS'ens ur tikker (55 ms).
tik:	push ax
	push es
	xor ax, ax
	mov es, ax
	mov ax, [es:046Ch]
.v:	sti
	hlt
	cmp ax, [es:046Ch]
	je .v
	pop es
	pop ax
	ret

; AL ottendedele: 3 tik hver, minus et til pausen.
varighed:
	xor ah, ah
	mov cx, ax
	add cx, ax
	add cx, ax
	dec cx
.l:	call tik
	loop .l
	ret

; AL = register, AH = værdi.
opl:	push ax
	push cx
	push dx
	mov dx, 388h
	out dx, al
	mov cx, 6		; registeret skal have tid
.a:	in al, dx
	loop .a
	inc dx
	mov al, ah
	out dx, al
	dec dx
	mov cx, 35
.b:	in al, dx
	loop .b
	pop dx
	pop cx
	pop ax
	ret

; CF=0 hvis der er et AdLib-kort (timer 1 skal løbe over).
adlib_findes:
	mov ax, 6004h
	call opl
	mov ax, 8004h
	call opl
	mov dx, 388h
	in al, dx
	mov bl, al
	mov ax, 0FF02h
	call opl
	mov ax, 2104h
	call opl
	mov cx, 200
.vent:	in al, dx
	loop .vent
	in al, dx
	mov bh, al
	mov ax, 6004h
	call opl
	mov ax, 8004h
	call opl
	and bx, 0E0E0h
	cmp bx, 0C000h
	je .ja
	stc
	ret
.ja:	mov ax, 2001h		; bølgeformer til
	call opl
	clc
	ret

; CF=0 hvis der er en Sound Blaster på 220h.
sb_findes:
	mov dx, 226h
	mov al, 1
	out dx, al
	mov cx, 50
.v1:	in al, dx
	loop .v1
	xor al, al
	out dx, al
	mov cx, 1000
	mov dx, 22Eh
.v2:	in al, dx
	test al, 80h
	jnz .data
	loop .v2
	stc
	ret
.data:	mov dx, 22Ah
	in al, dx
	cmp al, 0AAh
	je .ok
	stc
	ret
.ok:	clc
	ret

dsp:	push dx			; skriv AL til DSP'en
	push ax
	mov dx, 22Ch
.v:	in al, dx
	test al, 80h
	jnz .v
	pop ax
	out dx, al
	pop dx
	ret

; IRQ 7 til vores handler, højttaleren til, 11025 Hz.
sb_klar:
	mov ax, 350Fh
	int 21h
	mov [gammel_irq], bx
	mov [gammel_irq + 2], es
	mov dx, irq7
	mov ax, 250Fh
	int 21h
	in al, 21h
	and al, 7Fh
	out 21h, al
	mov al, 0D1h
	call dsp
	mov al, 40h
	call dsp
	mov al, 165		; 256 - 1000000/11025
	call dsp
	; En buffer der ikke krydser en 64K-side (DMA'en kan ikke det).
	mov ax, ds
	mov cl, 4
	rol ax, cl
	mov bx, ax
	and ax, 0FFF0h
	and bx, 000Fh		; side
	add ax, buf
	adc bx, 0
	cmp ax, 0 - 8192
	jb .ok
	xor ax, ax		; næste side
	inc bx
.ok:	mov [dma_adr], ax
	mov [dma_side], bl
	; Hvor ligger det i vores segment?
	mov di, ax
	mov ax, ds
	mov cl, 4
	shl ax, cl
	sub di, ax
	mov [buf_off], di
	ret

sb_luk:	mov al, 0D3h
	call dsp
	in al, 21h
	or al, 80h
	out 21h, al
	push ds
	lds dx, [gammel_irq]
	mov ax, 250Fh
	int 21h
	pop ds
	ret

irq7:	push ax
	push dx
	mov dx, 22Eh		; kvittér til DSP'en
	in al, dx
	mov al, 20h
	out 20h, al
	mov byte [cs:færdig], 1
	pop dx
	pop ax
	iret

; Spiller node AL i AH ottendedele som firkantbølge.
sb_tone:
	push si
	mov bl, al
	xor bh, bh
	shl bx, 1
	mov bp, [sb_periode + bx] ; halv periode i samples
	mov al, ah
	xor ah, ah
	mov cx, 1800		; samples pr. ottendedel (11025 * 0,165)
	mul cx
	sub ax, 600		; lidt stille til sidst
	mov [antal], ax
	mov cx, ax
	mov di, [buf_off]
	push es
	push ds
	pop es
	mov dx, bp
	mov al, 0A0h		; højt
.fyld:	stosb
	dec dx
	jnz .næste
	mov dx, bp
	xor al, 0A0h ^ 60h	; skift mellem A0h og 60h
.næste:	loop .fyld
	mov cx, 600
	mov al, 80h		; stilhed
	rep stosb
	pop es
	add word [antal], 600
	; DMA kanal 1: enkelt overførsel, hukommelse til kortet.
	mov al, 05h
	out 0Ah, al
	mov al, 49h
	out 0Bh, al
	out 0Ch, al
	mov ax, [dma_adr]
	out 02h, al
	mov al, ah
	out 02h, al
	mov ax, [antal]
	dec ax
	out 03h, al
	mov al, ah
	out 03h, al
	mov al, [dma_side]
	out 83h, al
	mov al, 01h
	out 0Ah, al
	mov byte [færdig], 0
	mov al, 14h		; 8-bit DMA
	call dsp
	mov ax, [antal]
	dec ax
	call dsp
	mov al, ah
	call dsp
.vent:	sti
	hlt
	cmp byte [færdig], 0
	je .vent
	pop si
	ret

; Noderne: C D E F G A og G i oktaven under.
;               C     D     E     F     G     A     G3
deler	dw	4554, 4058, 3615, 3419, 3044, 2712, 6087
fnum	dw	345, 388, 435, 460, 517, 580, 258
sb_periode dw	21, 19, 17, 16, 14, 13, 28

C equ 0
D equ 1
E equ 2
F equ 3
G equ 4
A equ 5
G3 equ 6
; Mester Jakob (node, ottendedele)
sang	db C,2, D,2, E,2, C,2,  C,2, D,2, E,2, C,2
	db E,2, F,2, G,4,  E,2, F,2, G,4
	db G,1, A,1, G,1, F,1, E,2, C,2,  G,1, A,1, G,1, F,1, E,2, C,2
	db C,2, G3,2, C,4,  C,2, G3,2, C,4
	db 0FFh, 0

; Klaver: modulator og bærer på kanal 0 (register, værdi).
instrument:
	db 20h, 01h,  40h, 10h,  60h, 0F2h,  80h, 77h,  0E0h, 00h
	db 23h, 01h,  43h, 00h,  63h, 0F2h,  83h, 55h,  0E3h, 00h
	db 0C0h, 0Ah
	dw 0

t_hej	db 'Mester Jakob p', 86h, ' tre lydkort:', 13, 10, '$'
t_pc	db '  1. PC-h', 9Bh, 'jttaleren', 13, 10, '$'
t_adlib	db '  2. AdLib (FM-syntese)', 13, 10, '$'
t_ingen_adlib db '  2. (intet AdLib-kort)', 13, 10, '$'
t_sb	db '  3. Sound Blaster (samples via DMA)', 13, 10, '$'
t_ingen_sb db '  3. (ingen Sound Blaster)', 13, 10, '$'
t_farvel db 'Sover du, sover du, Mester Jakob?', 13, 10, '$'
gammel_irq dd 0
færdig	db 0
antal	dw 0
dma_adr	dw 0
dma_side db 0
buf_off	dw 0
buf	times 16384 db 0
