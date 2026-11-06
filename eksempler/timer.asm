; timer.com — stiller timeren (PIT) til 1000 Hz og hooker INT 8, som spil
; gør. Tæller 2000 tik (2 sekunder) og kalder BIOS'ens ur hver 55. gang,
; så klokken stadig går rigtigt.	nasm -f bin timer.asm -o timer.com
	cpu 8086
	org 100h
	mov dx, t_start
	mov ah, 09h
	int 21h
	mov ax, 3508h		; gem den gamle INT 8
	int 21h
	mov [gammel], bx
	mov [gammel + 2], es
	mov dx, tik		; og sæt vores egen
	mov ax, 2508h
	int 21h
	cli
	mov al, 36h		; kanal 0, lav+høj byte, mode 3
	out 43h, al
	mov ax, 1193		; 1193182 / 1193 = 1000 Hz
	out 40h, al
	mov al, ah
	out 40h, al
	sti
.vent:	hlt			; sov til næste interrupt
	cmp word [antal], 2000
	jb .vent
	cli
	mov al, 36h		; timeren tilbage til 18,2 Hz
	out 43h, al
	xor al, al
	out 40h, al
	out 40h, al
	lds dx, [gammel]	; og INT 8 tilbage
	mov ax, 2508h
	int 21h
	sti
	push cs
	pop ds
	mov ax, [antal]
	call putnum
	mov dx, t_slut
	mov ah, 09h
	int 21h
	mov ax, 4C00h
	int 21h

tik:	inc word [cs:antal]
	dec byte [cs:del]
	jnz .eoi
	mov byte [cs:del], 55	; hver 55. tik: BIOS'ens ur (18,2 Hz)
	jmp far [cs:gammel]
.eoi:	push ax
	mov al, 20h		; ellers selv EOI til PIC'en
	out 20h, al
	pop ax
	iret

putnum:	mov bx, 10
	xor cx, cx
.d:	xor dx, dx
	div bx
	push dx
	inc cx
	or ax, ax
	jnz .d
.u:	pop dx
	add dl, '0'
	mov ah, 02h
	int 21h
	loop .u
	ret

gammel	dd 0
antal	dw 0
del	db 55
t_start	db 'Timeren k', 9Bh, 'rer 1000 gange i sekundet...', 13, 10, '$'
t_slut	db ' tik. F', 91h, 'rdig!', 13, 10, '$'
