; farver.com — tegner direkte i skærmhukommelsen på B800h.
	cpu 8086
	org 100h
	mov ax, 0B800h
	mov es, ax
	xor di, di
	mov ax, 1F20h		; blå baggrund, hvid tekst, mellemrum
	mov cx, 80 * 25
	rep stosw

	; En dobbelt ramme fra (20,3) til (59,13).
	mov di, (3 * 80 + 20) * 2
	mov ax, 1EC9h		; ╔
	stosw
	mov al, 0CDh		; ═
	mov cx, 38
	rep stosw
	mov al, 0BBh		; ╗
	stosw
	mov bx, 4
.side:	mov ax, bx
	mov dx, 160
	mul dx
	mov di, ax
	add di, 20 * 2
	mov ax, 1EBAh		; ║
	stosw
	add di, 38 * 2
	stosw
	inc bx
	cmp bx, 13
	jne .side
	mov di, (13 * 80 + 20) * 2
	mov ax, 1EC8h		; ╚
	stosw
	mov al, 0CDh
	mov cx, 38
	rep stosw
	mov al, 0BCh		; ╝
	stosw

	; Titlen.
	mov si, titel
	mov di, (5 * 80 + 31) * 2
	mov ah, 1Eh
.t:	lodsb
	or al, al
	jz .farver
	stosw
	jmp .t

	; Alle 16 farver som blokke.
.farver:
	mov di, (8 * 80 + 24) * 2
	xor ah, ah
	mov cx, 16
.f:	mov al, 0DBh		; █
	stosw
	stosw
	inc ah
	loop .f
	mov di, (10 * 80 + 24) * 2
	mov si, tekst
	mov ah, 1Bh
.x:	lodsb
	or al, al
	jz .vent
	stosw
	jmp .x

.vent:	mov ah, 02h		; markøren ned under rammen
	xor bh, bh
	mov dx, 1500h
	int 10h
	xor ah, ah		; vent på en tast (INT 16h)
	int 16h
	mov ax, 4C00h
	int 21h
titel	db 'S H I F U', 0
tekst	db 'Direkte i videohukommelsen', 0
