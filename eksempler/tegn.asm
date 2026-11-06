; tegn.com — et lille tegneprogram med musen (INT 33h) i VGA mode 13h.
; Venstre knap tegner, højre knap skifter farve, klik på paletten for at
; vælge en farve. C rydder, Esc slutter.
;	nasm -f bin tegn.asm -o tegn.com
	cpu 8086
	org 100h
TOP	equ 14			; tegnefladen starter under paletten

start:	xor ax, ax		; er der en musedriver?
	int 33h
	cmp ax, 0FFFFh
	je .mus
	mov dx, ingen
	mov ah, 9
	int 21h
	mov ax, 4C01h
	int 21h

.mus:	mov ax, 13h
	int 10h
	mov ax, 0A000h
	mov es, ax
	xor ax, ax		; nulstil igen: driveren følger skærmtilstanden
	int 33h
	call tegn_palet
	call vis_hjaelp

	mov ax, 0Ch		; handler for venstre (2) og højre (8) tryk
	mov cx, 0Ah
	push es
	push cs
	pop es
	mov dx, handler
	int 33h
	pop es

	mov ax, 1		; vis markøren
	int 33h

loop_:	mov ax, 3		; position og knapper
	int 33h
	shr cx, 1		; 640 virtuelle enheder -> 320 pixels
	test bl, 1
	jz .op
	cmp dx, TOP
	jb .palet
	cmp byte [nede], 0
	jne .streg
	mov [fx], cx		; første punkt i en ny streg
	mov [fy], dx
.streg:	mov byte [nede], 1
	push cx
	push dx
	mov ax, 2		; skjul markøren mens vi tegner
	int 33h
	pop dx
	pop cx
	call linje
	mov ax, 1
	int 33h
	jmp .tast
.palet:	mov ax, cx		; farve = x / 20
	mov bl, 20
	div bl
	mov [farve], al
	mov [farve_ny], al
	call vis_farve
.op:	mov byte [nede], 0

.tast:	mov al, [farve_ny]	; højre klik i handleren?
	cmp al, [farve]
	je .tast2
	mov [farve], al
	call vis_farve
.tast2:	mov ah, 1
	int 16h
	jz .vent
	xor ah, ah
	int 16h
	cmp al, 27
	je slut
	or al, 20h
	cmp al, 'c'
	jne .vent
	mov ax, 2
	int 33h
	call ryd
	mov ax, 1
	int 33h
.vent:	jmp loop_		; (INT 16h AH=1 lader Shifu hvile imens)

slut:	xor ax, ax		; driveren slipper handleren
	int 33h
	mov ax, 3
	int 10h
	mov dx, tak
	mov ah, 9
	int 21h
	mov ax, [klik]		; antal klik som decimaltal
	call tal
	mov dx, nl
	mov ah, 9
	int 21h
	mov ax, 4C00h
	int 21h

; Musedriveren kalder den her ved tryk. AX = hvad der skete,
; BX = knapper, CX, DX = position. DS er ikke vores: sæt det selv.
handler:
	push ds
	push cs
	pop ds
	inc word [klik]
	test al, 8		; højre knap: næste farve
	jz .ud
	mov al, [farve_ny]	; hovedløkken ser ændringen og tegner rammen
	inc al
	and al, 15
	mov [farve_ny], al
.ud:	pop ds
	retf

; En streg fra (fx, fy) til (cx, dx) med Bresenham, 2x2 pixels tyk.
linje:	mov [tx], cx
	mov [ty], dx
	mov ax, cx
	sub ax, [fx]
	mov si, 1
	jge .dx
	neg ax
	neg si
.dx:	mov [ddx], ax
	mov [sx], si
	mov ax, [ty]
	sub ax, [fy]
	mov si, 1
	jge .dy
	neg ax
	neg si
.dy:	neg ax			; dy er negativ i algoritmen
	mov [ddy], ax
	mov [sy], si
	mov ax, [ddx]
	add ax, [ddy]
	mov [fejl], ax
.trin:	mov cx, [fx]
	mov dx, [fy]
	call plot
	mov ax, [fx]
	cmp ax, [tx]
	jne .ikke
	mov ax, [fy]
	cmp ax, [ty]
	je .faerdig
.ikke:	mov ax, [fejl]
	shl ax, 1
	cmp ax, [ddy]
	jl .ingen_x
	mov bx, [ddy]
	add [fejl], bx
	mov bx, [sx]
	add [fx], bx
.ingen_x:
	cmp ax, [ddx]
	jg .trin
	mov bx, [ddx]
	add [fejl], bx
	mov bx, [sy]
	add [fy], bx
	jmp .trin
.faerdig:
	ret

; 2x2 pixels ved (cx, dx) i den valgte farve, inden for tegnefladen.
plot:	cmp cx, 318
	ja .ud
	cmp dx, TOP
	jb .ud
	cmp dx, 198
	ja .ud
	mov ax, 320
	push dx
	mul dx
	pop dx
	add ax, cx
	mov di, ax
	mov al, [farve]
	mov ah, al
	mov [es:di], ax
	mov [es:di + 320], ax
.ud:	ret

; Paletten: 16 felter á 20 x 12 pixels øverst.
tegn_palet:
	xor di, di
	xor dx, dx		; række
.r:	xor cx, cx		; søjle
.s:	mov ax, cx
	mov bl, 20
	div bl
	mov [es:di], al
	inc di
	inc cx
	cmp cx, 320
	jb .s
	inc dx
	cmp dx, 12
	jb .r
	call vis_farve
	ret

; En hvid ramme under den valgte farve i paletten.
vis_farve:
	mov ax, 2
	int 33h
	mov di, 12 * 320	; ryd stregen under paletten
	mov cx, 2 * 320
	xor al, al
	rep stosb
	mov al, [farve]
	mov bl, 20
	mul bl
	mov di, 12 * 320
	add di, ax
	mov cx, 20
	mov al, 15
.l:	mov [es:di], al
	mov [es:di + 320], al
	inc di
	loop .l
	mov ax, 1
	int 33h
	ret

ryd:	mov di, TOP * 320
	mov cx, (200 - TOP) * 320
	xor al, al
	rep stosb
	call vis_hjaelp
	ret

; Hjælpeteksten nederst (BIOS-tekst i mode 13h).
vis_hjaelp:
	mov ah, 2
	xor bh, bh
	mov dx, 24 * 256 + 1	; række 24, søjle 1
	int 10h
	mov si, hjaelp
.t:	lodsb
	or al, al
	jz .ud
	mov ah, 0Eh
	mov bl, 7
	int 10h
	jmp .t
.ud:	ret

; AX som decimaltal.
tal:	xor cx, cx
	mov bx, 10
.del:	xor dx, dx
	div bx
	push dx
	inc cx
	or ax, ax
	jnz .del
.skriv:	pop dx
	add dl, '0'
	mov ah, 2
	int 21h
	loop .skriv
	ret

ingen	db "Ingen musedriver fundet.", 13, 10, "$"
tak	db "Tak for tegningen! Klik: $"
nl	db 13, 10, "$"
hjaelp	db "Venstre: tegn  H", 9Bh, "jre: farve  C: ryd", 0
farve	db 15
farve_ny db 15
nede	db 0
klik	dw 0
fx	dw 0
fy	dw 0
tx	dw 0
ty	dw 0
ddx	dw 0
ddy	dw 0
sx	dw 0
sy	dw 0
fejl	dw 0
