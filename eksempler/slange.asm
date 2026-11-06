; slange.com — Snake i VGA mode 13h. Piletasterne styrer, Esc slutter.
; Spis de røde æbler; slangen bliver længere og hurtigere.
;	nasm -f bin slange.asm -o slange.com
	cpu 8086
	org 100h
B	equ 64			; banen: 64 x 40 felter á 5x5 pixels
H	equ 40
FELTER	equ B * H

start:	mov ax, 13h
	int 10h
	mov ax, 0A000h
	mov es, ax

	mov di, bane		; tom bane
	mov cx, FELTER
	xor al, al
.ryd:	mov [di], al
	inc di
	loop .ryd
	xor bx, bx		; mure: række 2 og 39, søjle 0 og 63
.mur_v:	mov ax, 2 * B
	add ax, bx
	call mur
	mov ax, (H - 1) * B
	add ax, bx
	call mur
	inc bx
	cmp bx, B
	jb .mur_v
	mov bx, 2
.mur_l:	mov ax, bx
	mov cl, 6
	shl ax, cl
	push ax
	call mur
	pop ax
	add ax, B - 1
	call mur
	inc bx
	cmp bx, H
	jb .mur_l

	call tik		; æblerne afhænger af klokken
	mov [frø], ax
	mov cx, 4		; slangen: 4 felter i række 20
	mov ax, 20 * B + 10
.krop:	call hoved_til
	inc ax
	loop .krop
	call nyt_æble
	call vis_point
	call tik
	mov [næste], ax

spil:	call tik		; vent til det er tid til et skridt
	cmp ax, [næste]
	js spil
	add ax, [fart]
	mov [næste], ax

	mov ah, 01h		; taster
	int 16h
	jz .flyt
	xor ah, ah
	int 16h
	cmp ah, 01h		; Esc
	je slut
	mov bx, -B
	cmp ah, 48h
	je .ny_retning
	mov bx, B
	cmp ah, 50h
	je .ny_retning
	mov bx, -1
	cmp ah, 4Bh
	je .ny_retning
	mov bx, 1
	cmp ah, 4Dh
	jne .flyt
.ny_retning:
	mov ax, bx		; ikke lige tilbage
	add ax, [retning]
	jz .flyt
	mov [retning], bx

.flyt:	mov si, [hoved]
	shl si, 1
	mov ax, [krop + si]
	add ax, [retning]
	mov bx, ax
	cmp byte [bane + bx], 0	; mur eller slange?
	je .fri
	cmp byte [bane + bx], 3	; æble?
	jne game_over
	call hoved_til
	inc word [point]
	cmp word [fart], 1	; hurtigere for hvert 5. æble
	je .ingen
	mov ax, [point]
	mov bl, 5
	div bl
	or ah, ah
	jnz .ingen
	dec word [fart]
.ingen:	call vis_point
	call nyt_æble
	jmp spil
.fri:	call hoved_til
	mov si, [hale]		; halen væk
	shl si, 1
	mov bx, [krop + si]
	mov byte [bane + bx], 0
	mov ax, bx
	xor dl, dl
	call felt
	inc word [hale]
	and word [hale], 4095
	jmp spil

game_over:
	mov ah, 02h
	xor bh, bh
	mov dx, 0C0Eh
	int 10h
	mov si, t_slut
	call tekst
	mov cx, 18		; 1 sekund, så man ikke trykker den væk
.pause:	push cx
	call tik
	mov dx, ax
.p2:	call tik
	cmp ax, dx
	je .p2
	pop cx
	loop .pause
.tøm:	mov ah, 01h
	int 16h
	jz .vent
	xor ah, ah
	int 16h
	jmp .tøm
.vent:	xor ah, ah
	int 16h
slut:	mov ax, 3
	int 10h
	mov dx, t_farvel
	mov ah, 09h
	int 21h
	mov ax, [point]
	call tal
	mov dx, t_point
	mov ah, 09h
	int 21h
	mov ax, 4C00h
	int 21h

; AX = felt: nyt hoved der.
hoved_til:
	push ax
	push si
	inc word [hoved]
	and word [hoved], 4095
	mov si, [hoved]
	shl si, 1
	mov [krop + si], ax
	mov si, ax
	mov byte [bane + si], 2
	mov dl, 2		; grøn
	call felt
	pop si
	pop ax
	ret

mur:	mov si, ax
	mov byte [bane + si], 1
	mov dl, 8		; grå
	jmp felt

nyt_æble:
	mov ax, [frø]		; tilfældigt tal (LCG)
	mov bx, 25173
	mul bx
	add ax, 13849
	mov [frø], ax
	xor dx, dx
	mov bx, FELTER
	div bx
	mov bx, dx
	cmp byte [bane + bx], 0
	jne nyt_æble
	mov byte [bane + bx], 3
	mov ax, bx
	mov dl, 12		; rød
	; fall through

; AX = felt (y * 64 + x), DL = farve: tegner 5x5 pixels.
felt:	push ax
	push bx
	push cx
	push di
	mov bx, ax
	and bx, B - 1		; x
	mov cl, 6
	shr ax, cl		; y
	mov cx, 1600		; y * 5 * 320
	push dx
	mul cx
	pop dx
	mov di, ax
	mov ax, bx
	mov cx, 5
	push dx
	mul cx
	pop dx
	add di, ax
	mov al, dl
	mov bx, 5
.r:	mov cx, 5
	rep stosb
	add di, 315
	dec bx
	jnz .r
	pop di
	pop cx
	pop bx
	pop ax
	ret

vis_point:
	mov ah, 02h
	xor bh, bh
	xor dx, dx
	int 10h
	mov si, t_point_titel
	call tekst
	mov ax, [point]
	; fall through
tal:	push ax			; AX som decimaltal (via INT 10h)
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
	mov ah, 0Eh
	mov bl, 14
	int 10h
	loop .u
	pop ax
	ret

tekst:	lodsb
	or al, al
	jz .s
	mov ah, 0Eh
	mov bl, 15
	int 10h
	jmp tekst
.s:	ret

tik:	push es			; BIOS'ens ur (18,2 i sekundet)
	xor ax, ax
	mov es, ax
	mov ax, [es:046Ch]
	mov [frø + 2], ax
	pop es
	ret

retning	dw 1
hoved	dw 4095
hale	dw 0
point	dw 0
fart	dw 3
næste	dw 0
frø	dw 12345, 0
t_point_titel db 'SLANGE    Point: ', 0
t_slut	db ' GAME OVER ', 0
t_farvel db 'Tak for spillet! Du fik $'
t_point	db ' point.', 13, 10, '$'
bane	times FELTER db 0
krop	times 4096 dw 0
