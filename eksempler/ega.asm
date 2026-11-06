; ega.com — VGA mode 12h: 640x480 i 16 farver, i fire bitplaner. Tegner
; direkte i planerne med VGA'ens skrivemode 2 (port 3CEh/3C4h).
;	nasm -f bin ega.asm -o ega.com
	cpu 8086
	org 100h
	mov ax, 12h
	int 10h
	mov ax, 0A000h
	mov es, ax
	mov dx, 3CEh		; grafikcontrolleren: skrivemode 2
	mov ax, 0205h
	out dx, ax
	; 16 lodrette striber á 40 pixels (5 bytes), linje 60-419.
	xor bx, bx		; farve
.stribe:
	mov ax, bx
	mov cx, 5
	mul cx
	mov di, ax		; første byte
	add di, 60 * 80
	mov dx, 360		; linjer
.linje:	mov cx, 5
.byte:	mov al, [es:di]		; fyld latcherne
	mov al, bl
	stosb
	loop .byte
	add di, 80 - 5
	dec dx
	jnz .linje
	inc bx
	cmp bx, 16
	jb .stribe
	mov dx, 3CEh		; tilbage til skrivemode 0
	mov ax, 0005h
	out dx, ax
	mov ah, 02h
	xor bh, bh
	mov dx, 011Bh
	int 10h
	mov si, tekst
.t:	lodsb
	or al, al
	jz .vent
	mov ah, 0Eh
	mov bl, 14
	int 10h
	jmp .t
.vent:	xor ah, ah
	int 16h
	mov ax, 3
	int 10h
	mov ax, 4C00h
	int 21h
tekst	db 'VGA 640x480 i 16 farver', 0
