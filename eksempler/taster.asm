; taster.com — hooker INT 9 og viser tastaturets scankoder fra port 60h,
; både når tasten trykkes (make) og slippes (break, +80h). Esc slutter.
;	nasm -f bin taster.asm -o taster.com
	cpu 8086
	org 100h
	mov dx, t_hej
	mov ah, 09h
	int 21h
	mov ax, 3509h
	int 21h
	mov [gammel], bx
	mov [gammel + 2], es
	mov dx, tast
	mov ax, 2509h
	int 21h
.loop:	hlt
	mov bx, [hale]
	cmp bx, [hoved]
	je .loop
	mov al, [buf + bx]
	inc bx
	and bx, 63
	mov [hale], bx
	push ax
	call puthex
	mov dl, ' '
	mov ah, 02h
	int 21h
	pop ax
	cmp al, 01h		; Esc trykket?
	jne .loop
	lds dx, [gammel]
	mov ax, 2509h
	int 21h
	mov ax, 4C00h
	int 21h

tast:	push ax			; INT 9: læs koden og send den videre
	push bx
	in al, 60h
	mov bx, [cs:hoved]
	mov [cs:buf + bx], al
	inc bx
	and bx, 63
	mov [cs:hoved], bx
	pop bx
	pop ax
	jmp far [cs:gammel]	; BIOS'en vil også have den

puthex:	push ax
	mov cl, 4
	shr al, cl
	call .ciffer
	pop ax
	and al, 0Fh
.ciffer:
	add al, '0'
	cmp al, '9'
	jbe .p
	add al, 7
.p:	mov dl, al
	mov ah, 02h
	int 21h
	ret

gammel	dd 0
hoved	dw 0
hale	dw 0
buf	times 64 db 0
t_hej	db 'Tryk p', 86h, ' taster (Esc slutter). Scankoder:', 13, 10, '$'
