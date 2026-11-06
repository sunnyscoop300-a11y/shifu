; mzdemo.exe — et rigtigt .EXE-program: relokering, hukommelse,
; kommandolinje, environment og EXEC af HEJ.COM.
;	nasm -f bin mzdemo.asm -o mzdemo.exe
	cpu 8086
	bits 16
section hdr start=0
	db 'MZ'
	dw (20h + image_len) % 512
	dw (20h + image_len + 511) / 512
	dw 1			; én relokering
	dw 2			; headeren fylder 2 paragraffer
	dw 40h			; mindst 1 KiB ekstra (stak)
	dw 0FFFFh		; og gerne det hele
	dw (image_len + 15) / 16 ; SS
	dw 400h			; SP
	dw 0			; checksum
	dw start		; IP
	dw 0			; CS
	dw 1Ch			; relokeringstabellen
	dw 0
	dw fix + 1, 0		; ordet i "mov ax, 0" nedenfor

section code follows=hdr vstart=0
start:	mov [cs:psp], es	; DOS giver os PSP'en i ES
fix:	mov ax, 0		; bliver til vores segment
	mov ds, ax
	mov dx, t_reloc
	call puts
	mov ax, ds
	call puthex
	mov dx, crlf
	call puts

	; Skrump til det vi bruger, og bed om 16 KiB mere.
	mov es, [psp]
	mov bx, (image_len + 15) / 16 + 10h + 40h + 10h
	mov ah, 4Ah
	int 21h
	jc fejl
	mov bx, 400h
	mov ah, 48h
	int 21h
	jc fejl
	push ax
	mov dx, t_mem
	call puts
	pop ax
	call puthex
	mov dx, crlf
	call puts

	; Kommandolinjen fra PSP:80h.
	mov dx, t_args
	call puts
	push ds
	mov ds, [cs:psp]
	mov si, 81h
	mov cl, [80h]
	xor ch, ch
	jcxz .ingen
.a:	lodsb
	call putc
	loop .a
.ingen:	pop ds
	mov dx, t_slut
	call puts

	; Vores eget navn står efter environment-strengene.
	mov dx, t_navn
	call puts
	push ds
	mov es, [psp]
	mov ds, [es:2Ch]
	xor si, si
.env:	lodsb
	or al, al
	jnz .env
	lodsb
	or al, al
	jnz .env		; dobbelt nul = slut
	lodsw			; ordet 1
.n:	lodsb
	or al, al
	jz .nd
	call putc
	jmp .n
.nd:	pop ds
	mov dx, crlf
	call puts

	; Kør HEJ.COM som underprogram.
	mov dx, t_exec
	call puts
	mov ax, ds
	mov [pb_tail + 2], ax
	push ds
	pop es
	mov bx, pb
	mov dx, hejnavn
	mov ax, 4B00h
	int 21h
	mov bx, cs		; EXEC ødelægger registrene
	mov ds, bx
	jc fejl
	mov ah, 4Dh		; hvordan gik det?
	int 21h
	push ax
	mov dx, t_kode
	call puts
	pop ax
	xor ah, ah
	call puthex
	mov dx, t_farvel
	call puts
	mov ax, 4C07h		; slut med kode 7
	int 21h

fejl:	push cs
	pop ds
	mov dx, t_fejl
	call puts
	mov ax, 4C01h
	int 21h

puts:	mov ah, 09h
	int 21h
	ret
putc:	push ax
	push dx
	mov dl, al
	mov ah, 02h
	int 21h
	pop dx
	pop ax
	ret
puthex:	mov cx, 4		; AX som 4 hex-cifre
.h:	rol ax, 1
	rol ax, 1
	rol ax, 1
	rol ax, 1
	push ax
	and al, 0Fh
	add al, '0'
	cmp al, '9'
	jbe .p
	add al, 7
.p:	call putc
	pop ax
	loop .h
	ret

psp	dw 0
pb	dw 0			; EXEC-parametre: arv environment
pb_tail	dw tail, 0
	dd 0, 0
tail	db 0, 13
hejnavn	db 'HEJ.COM', 0
t_reloc	db 'MZDEMO.EXE k', 9Bh, 'rer! Relokeret til segment $'
t_mem	db 'Fik 16 KiB hukommelse i segment $'
t_args	db 'Kommandolinje: [$'
t_slut	db ']', 13, 10, '$'
t_navn	db 'Mit fulde navn: $'
t_exec	db 'Starter HEJ.COM...', 13, 10, '$'
t_kode	db 'HEJ.COM sluttede med kode $'
t_farvel db '. Farvel!', 13, 10, '$'
t_fejl	db 'Fejl!', 13, 10, '$'
crlf	db 13, 10, '$'
image_len equ $ - start
