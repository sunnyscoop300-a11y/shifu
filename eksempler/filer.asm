; filer.com — skriver en fil, læser den igen og viser mappen (som DIR).
;	nasm -f bin filer.asm -o filer.com
	cpu 8086
	org 100h
	mov dx, t_skriv
	call puts
	mov ah, 3Ch		; opret TEST.TXT
	xor cx, cx
	mov dx, navn
	int 21h
	jc fejl
	mov bx, ax
	mov ah, 40h		; skriv teksten
	mov cx, tekst_len
	mov dx, tekst
	int 21h
	jc fejl
	mov ah, 3Eh
	int 21h

	mov ah, 3Dh		; åbn den igen
	mov al, 0
	mov dx, navn
	int 21h
	jc fejl
	mov bx, ax
	mov ax, 4202h		; hop til slutningen: DX:AX = størrelse
	xor cx, cx
	xor dx, dx
	int 21h
	push ax
	mov dx, t_str
	call puts
	pop ax
	call putnum
	mov dx, t_bytes
	call puts
	mov ax, 4200h		; tilbage til start
	xor cx, cx
	xor dx, dx
	int 21h
	mov ah, 3Fh		; læs det hele
	mov cx, 200
	mov dx, buf
	int 21h
	mov cx, ax
	mov ah, 3Eh
	int 21h
	mov ah, 40h		; og skriv det til skærmen (handle 1)
	mov bx, 1
	mov dx, buf
	int 21h

	mov ah, 39h		; opret en mappe (fejl hvis den findes: fint)
	mov dx, mappe
	int 21h

	mov dx, t_dir
	call puts
	mov ah, 4Eh		; find første *.*
	mov cx, 10h		; også mapper
	mov dx, alle
	int 21h
	jc .slut
.igen:	mov si, 80h + 1Eh	; navnet i DTA'en (PSP:80h)
	mov cx, 14
.navn:	lodsb
	or al, al
	jz .pad
	call putc
	dec cx
	jmp .navn
.pad:	mov al, ' '
	call putc
	loop .pad
	test byte [80h + 15h], 10h
	jz .fil
	mov dx, t_mappe
	call puts
	jmp .nl
.fil:	mov ax, [80h + 1Ah]
	call putnum
.nl:	mov dx, crlf
	call puts
	mov ah, 4Fh		; find næste
	int 21h
	jnc .igen
.slut:	mov ax, 4C00h
	int 21h

fejl:	mov dx, t_fejl
	call puts
	mov ax, 4C01h
	int 21h

puts:	mov ah, 09h
	int 21h
	ret
putc:	push dx
	push ax
	mov dl, al
	mov ah, 02h
	int 21h
	pop ax
	pop dx
	ret
putnum:	push bx			; AX som decimaltal
	push cx
	mov bx, 10
	xor cx, cx
.d:	xor dx, dx
	div bx
	push dx
	inc cx
	or ax, ax
	jnz .d
.u:	pop ax
	add al, '0'
	call putc
	loop .u
	pop cx
	pop bx
	ret

navn	db 'TEST.TXT', 0
mappe	db 'MAPPE', 0
alle	db '*.*', 0
tekst	db 'Hej fra en DOS-fil! ', 91h, 9Bh, 86h, ' virker ogs', 86h, '.', 13, 10
tekst_len equ $ - tekst
t_skriv	db 'Skriver TEST.TXT...', 13, 10, '$'
t_str	db 'Filen er $'
t_bytes	db ' bytes og indeholder:', 13, 10, '$'
t_dir	db 13, 10, 'Mappen C:\ indeholder:', 13, 10, '$'
t_mappe	db '<MAPPE>$'
t_fejl	db 'Noget gik galt!', 13, 10, '$'
crlf	db 13, 10, '$'
buf	times 200 db 0
