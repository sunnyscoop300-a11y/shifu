; xms.com — bruger XMS-driveren (som HIMEM.SYS): finder den via INT 2Fh,
; viser versionen og den frie hukommelse, låner 1 MB over 1 MB-grænsen,
; flytter en tekst derop og hjem igen, og låser blokken for at se dens
; fysiske adresse.
;	nasm -f bin xms.asm -o xms.com
	cpu 386
	org 100h

start:	mov ax, 4300h		; er der en XMS-driver?
	int 2Fh
	cmp al, 80h
	je .fundet
	mov dx, ingen
	call skriv
	mov ax, 4C01h
	int 21h
.fundet:
	mov ax, 4310h		; dens indgang: ES:BX
	int 2Fh
	mov [xms], bx
	mov [xms + 2], es

	mov ah, 0		; version
	call far [xms]
	push ax
	mov dx, version
	call skriv
	pop ax
	push ax
	mov al, ah
	call hex2
	mov dl, '.'
	call tegn
	pop ax
	call hex2
	call nl

	mov ah, 8		; fri hukommelse i KB
	call far [xms]
	push dx
	mov dx, fri
	call skriv
	pop ax
	call tal
	mov dx, kb
	call skriv

	mov ah, 9		; lån 1024 KB
	mov dx, 1024
	call far [xms]
	or ax, ax
	jz fejl
	mov [handle], dx
	mov [flyt_ind + 10], dx	; destination: blokken
	mov [flyt_ud + 4], dx	; kilde: blokken
	mov [flyt_ind + 8], cs	; kilde: teksten her (segment:offset)
	mov [flyt_ud + 14], cs	; destination: bufferen her

	mov ah, 0Bh		; teksten op i blokken (1000 bytes inde)
	mov si, flyt_ind
	call far [xms]
	or ax, ax
	jz fejl
	mov ah, 0Bh		; og hjem igen til en anden buffer
	mov si, flyt_ud
	call far [xms]
	or ax, ax
	jz fejl
	mov dx, hjem
	call skriv
	mov dx, buffer
	call skriv

	mov ah, 0Ch		; lås: DX:BX er den fysiske adresse
	mov dx, [handle]
	call far [xms]
	or ax, ax
	jz fejl
	push bx
	push dx
	mov dx, adresse
	call skriv
	pop ax
	call hex4
	pop ax
	call hex4
	mov dx, h
	call skriv
	mov ah, 0Dh		; lås op
	mov dx, [handle]
	call far [xms]

	mov ah, 8
	call far [xms]
	push dx
	mov dx, fri
	call skriv
	pop ax
	call tal
	mov dx, kb
	call skriv

	mov ah, 0Ah		; giv den tilbage
	mov dx, [handle]
	call far [xms]
	mov ah, 8
	call far [xms]
	push dx
	mov dx, fri
	call skriv
	pop ax
	call tal
	mov dx, kb
	call skriv
	mov ax, 4C00h
	int 21h

fejl:	mov dx, fejltekst
	call skriv
	mov ax, 4C01h
	int 21h

; AX som decimaltal.
tal:	xor cx, cx
	mov bx, 10
.del:	xor dx, dx
	div bx
	push dx
	inc cx
	or ax, ax
	jnz .del
.ud:	pop dx
	add dl, '0'
	call tegn
	loop .ud
	ret

hex4:	push ax
	mov al, ah
	call hex2
	pop ax
hex2:	push ax
	shr al, 4
	call ciffer
	pop ax
	and al, 0Fh
ciffer:	add al, '0'
	cmp al, '9'
	jbe .ok
	add al, 7
.ok:	mov dl, al
tegn:	mov ah, 2
	int 21h
	ret

nl:	mov dx, linje
skriv:	mov ah, 9
	int 21h
	ret

ingen	db "Ingen XMS-driver.", 13, 10, "$"
version	db "XMS version $"
fri	db "Fri udvidet hukommelse: $"
kb	db " KB", 13, 10, "$"
hjem	db "Hjem fra blokken: $"
adresse	db "Blokken ligger fysisk p", 86h, " $"
h	db "h", 13, 10, "$"
fejltekst db "XMS-kaldet fejlede.", 13, 10, "$"
linje	db 13, 10, "$"

xms	dd 0
handle	dw 0
; Flyt-strukturer: længde, kilde-handle, kilde-offset, mål-handle, mål-offset.
flyt_ind:
	dd tekst_slut - tekst
	dw 0
	dd tekst		; (segmentet sættes ind)
	dw 0
	dd 1000
flyt_ud:
	dd tekst_slut - tekst
	dw 0
	dd 1000
	dw 0
	dd buffer		; (segmentet sættes ind)

tekst	db "Hej fra hukommelsen over 1 MB!", 13, 10, "$", 0
tekst_slut:
buffer	times 40 db "?"
