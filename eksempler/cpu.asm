; cpu.com — finder ud af hvilken CPU den kører på, som 90'er-programmer
; gjorde det, og regner med 32-bit registre hvis det er en 386.
;	nasm -f bin cpu.asm -o cpu.com
	cpu 386
	org 100h

start:	mov dx, hvad
	call skriv
	; 8086/8088: flagbit 12-15 er altid 1.
	pushf
	pop ax
	and ax, 0FFFh
	push ax
	popf
	pushf
	pop ax
	and ax, 0F000h
	cmp ax, 0F000h
	jne .ikke86
	mov dx, i8086
	call skriv
	jmp slut
	; 286 i real mode: bit 12-15 er altid 0.
.ikke86:
	pushf
	pop ax
	or ax, 0F000h
	push ax
	popf
	pushf
	pop ax
	test ax, 0F000h
	jnz .er386
	mov dx, i286
	call skriv
	jmp slut
	; 386 eller nyere. En 486 kan sætte AC-flaget (bit 18) i EFLAGS.
.er386:	pushfd
	pop eax
	mov ecx, eax
	xor eax, 40000h
	push eax
	popfd
	pushfd
	pop eax
	push ecx
	popfd
	xor eax, ecx
	mov dx, i386
	test eax, 40000h
	jz .skriv
	mov dx, i486
.skriv:	call skriv

	; Fakultet 1! til 12! med 32-bit gange.
	mov dx, fak
	call skriv
	mov eax, 1
	mov ebx, 1
.fak:	mul ebx
	push eax
	push ebx
	movzx eax, bl
	call tal32
	mov dx, udraab
	call skriv
	pop ebx
	pop eax
	push eax
	push ebx
	call tal32
	mov dx, nl
	call skriv
	pop ebx
	pop eax
	inc ebx
	cmp ebx, 12
	jbe .fak

	; Bits i et 32-bit tal med BSF og BSR.
	mov dx, bitstr
	call skriv
	mov eax, 00F0F000h
	bsf ecx, eax
	movzx eax, cl
	call tal32
	mov dx, og
	call skriv
	mov eax, 00F0F000h
	bsr ecx, eax
	movzx eax, cl
	call tal32
	mov dx, nl
	call skriv

slut:	mov ax, 4C00h
	int 21h

; EAX som decimaltal.
tal32:	xor cx, cx
	mov ebx, 10
.del:	xor edx, edx
	div ebx
	push dx
	inc cx
	or eax, eax
	jnz .del
.ud:	pop dx
	add dl, '0'
	mov ah, 2
	int 21h
	loop .ud
	ret

skriv:	mov ah, 9
	int 21h
	ret

hvad	db "Din CPU er en $"
i8086	db "8086 eller 8088 (en IBM PC).", 13, 10, "$"
i286	db "80286.", 13, 10, "$"
i386	db "80386.", 13, 10, "$"
i486	db "80486 eller nyere.", 13, 10, "$"
fak	db 13, 10, "Fakulteter med 32-bit registre:", 13, 10, "$"
udraab	db "! = $"
bitstr	db 13, 10, "00F0F000h: laveste bit er nr. $"
og	db ", h", 9Bh, "jeste nr. $"
nl	db 13, 10, "$"
