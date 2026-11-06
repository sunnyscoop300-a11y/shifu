; cga.com — CGA 320x200 i 4 farver (mode 4) via BIOS'en: pixels med
; INT 10h AH=0Ch, tekst i grafik, og paletterne skiftes med mellemrum.
;	nasm -f bin cga.asm -o cga.com
	cpu 8086
	org 100h
	mov ax, 4
	int 10h
	; Tre rammer i farve 1, 2 og 3.
	mov bl, 1
	mov si, 10
.ramme:	mov cx, si		; vandret top/bund: x = si..319-si
.vand:	mov dx, si
	call pixel
	mov dx, 199
	sub dx, si
	call pixel
	inc cx
	mov ax, 319
	sub ax, si
	cmp cx, ax
	jbe .vand
	mov dx, si		; lodret
.lod:	mov cx, si
	call pixel
	mov cx, 319
	sub cx, si
	call pixel
	inc dx
	mov ax, 199
	sub ax, si
	cmp dx, ax
	jbe .lod
	add si, 12
	inc bl
	cmp bl, 4
	jb .ramme
	; Diagonaler.
	xor cx, cx
.diag:	mov dx, cx
	shr dx, 1
	add dx, 20
	mov bl, 3
	call pixel
	push cx
	neg cx
	add cx, 319
	mov bl, 2
	call pixel
	pop cx
	inc cx
	cmp cx, 320
	jb .diag
	mov ah, 02h
	xor bh, bh
	mov dx, 0B0Ah
	int 10h
	mov si, tekst
.t:	lodsb
	or al, al
	jz .vent
	mov ah, 0Eh
	mov bl, 3
	int 10h
	jmp .t
.vent:	xor ah, ah
	int 16h
	cmp al, ' '
	jne .slut
	xor byte [palette], 1	; mellemrum: den anden palette
	mov ah, 0Bh
	mov bh, 1
	mov bl, [palette]
	int 10h
	jmp .vent
.slut:	mov ax, 3
	int 10h
	mov ax, 4C00h
	int 21h

pixel:	push ax			; CX=x, DX=y, BL=farve
	mov ah, 0Ch
	mov al, bl
	int 10h
	pop ax
	ret

palette	db 1
tekst	db 'CGA mode 4', 13, 10
	db '           Mellemrum: palette', 0
