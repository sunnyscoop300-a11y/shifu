; vga.com — VGA mode 13h: 320x200 i 256 farver. Tegner alle farverne og
; lader paletten rotere i takt med skærmen (port 3DAh). En tast slutter.
;	nasm -f bin vga.asm -o vga.com
	cpu 8086
	org 100h
	mov ax, 13h		; mode 13h
	int 10h
	mov ax, 0A000h
	mov es, ax

	xor bp, bp		; farve 0..255
.felt:	mov ax, bp		; x = (farve % 16) * 20
	and ax, 15
	mov bx, 20
	mul bx
	mov di, ax
	mov ax, bp		; y = 20 + (farve / 16) * 11
	mov cl, 4
	shr ax, cl
	mov bx, 11
	mul bx
	add ax, 20
	mov bx, 320
	mul bx
	add di, ax
	mov ax, bp
	mov dx, 10		; 10 linjer
.linje:	mov cx, 19
	rep stosb
	add di, 320 - 19
	dec dx
	jnz .linje
	inc bp
	cmp bp, 256
	jb .felt

	mov ah, 02h		; titel
	xor bh, bh
	mov dx, 0006h
	int 10h
	mov si, titel
.t:	lodsb
	or al, al
	jz .rotér
	mov ah, 0Eh
	mov bl, 15
	int 10h
	jmp .t

.rotér:	mov dx, 3DAh		; vent på næste lodrette retrace
.v1:	in al, dx
	test al, 8
	jnz .v1
.v2:	in al, dx
	test al, 8
	jz .v2
	mov dx, 3C7h		; læs farve 32-247 fra DAC'en
	mov al, 32
	out dx, al
	mov dx, 3C9h
	mov di, pal
	mov cx, 216 * 3
.læs:	in al, dx
	mov [di], al
	inc di
	loop .læs
	mov dx, 3C8h		; og skriv dem tilbage, én forskudt
	mov al, 32
	out dx, al
	mov dx, 3C9h
	mov si, pal + 3
	mov cx, 215 * 3
.skriv:	lodsb
	out dx, al
	loop .skriv
	mov si, pal
	mov cx, 3
.sidste:
	lodsb
	out dx, al
	loop .sidste
	mov ah, 01h		; en tast?
	int 16h
	jz .rotér
	xor ah, ah
	int 16h
	mov ax, 3		; tilbage til tekst
	int 10h
	mov ax, 4C00h
	int 21h

titel	db 'Shifu: VGA 256 farver', 0
pal	times 216 * 3 db 0
