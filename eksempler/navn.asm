; navn.com — spørger om dit navn (INT 21h AH=0Ah) og hilser.
	cpu 8086
	org 100h
	mov dx, spm
	mov ah, 09h
	int 21h
	mov dx, buf
	mov ah, 0Ah
	int 21h
	mov bl, [buf + 1]	; antal tegn
	xor bh, bh
	mov byte [buf + 2 + bx], '$'
	mov dx, hej
	mov ah, 09h
	int 21h
	mov dx, buf + 2
	int 21h
	mov dx, slut
	int 21h
	mov ah, 08h		; vent på en tast
	int 21h
	mov ax, 4C00h
	int 21h
spm	db 'Hvad hedder du? $'
hej	db 13, 10, 'Hej, $'
slut	db '! Velkommen til Shifu.', 13, 10, 'Tryk p', 86h, ' en tast...$'
buf	db 30, 0
	times 31 db 0
