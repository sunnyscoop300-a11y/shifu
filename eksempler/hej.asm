; hej.com — Shifus første DOS-program.  (nasm -f bin hej.asm -o hej.com)
	cpu 8086
	org 100h
start:	mov dx, hilsen
	mov ah, 09h
	int 21h			; skriv hilsenen
	mov cx, 1
.tal:	mov ax, cx
	mul cx			; AX = CX * CX
	call skriv_tal
	mov dl, ' '
	mov ah, 02h
	int 21h
	inc cx
	cmp cx, 13
	jne .tal
	mov dx, slut
	mov ah, 09h
	int 21h
	mov ax, 4C00h		; afslut med kode 0
	int 21h

; skriver AX som decimaltal (bruger DIV), bevarer CX
skriv_tal:
	push cx
	mov bx, 10
	xor cx, cx
.del:	xor dx, dx
	div bx
	push dx			; resten er det næste ciffer
	inc cx
	test ax, ax
	jnz .del
.ud:	pop dx
	add dl, '0'
	mov ah, 02h
	int 21h
	loop .ud
	pop cx
	ret

hilsen:	db 'Hej fra Shifu! En 8086 skrevet i Hare.', 13, 10
	db 'Kvadrattal: $'
slut:	db 13, 10, 'Mester Shifu er tilfreds.', 13, 10, '$'
