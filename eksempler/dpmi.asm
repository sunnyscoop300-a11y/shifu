; dpmi.com — et 32-bit DPMI-program, som dem DOS-extendere laver: finder
; DPMI-værten (INT 2Fh AX=1687h), går i protected mode og bruger INT 31h
; til deskriptorer, hukommelse over 1 MB, kald til DOS i real mode, en
; timer-handler, en undtagelseshandler og en real mode-callback.
;	nasm -f bin dpmi.asm -o dpmi.com
	cpu 386
	org 100h

	[bits 16]
start:	mov ah, 4Ah		; kun 64 KB, så DOS har hukommelse til overs
	mov bx, 1000h
	int 21h
	mov [rmseg], cs
	mov ax, 1687h		; er der en DPMI-vært?
	int 2Fh
	or ax, ax
	jnz ingen
	mov [indgang], di
	mov [indgang + 2], es
	mov ax, 1		; et 32-bit program
	call far [indgang]
	jc ingen

	; Protected mode, men stadig 16-bit kode. DS (= SS) er vores segment.
	mov [sel_ds], ds
	xor ax, ax		; et 32-bit kodesegment over det samme
	mov cx, 1
	int 31h
	mov [sel_c32], ax
	mov bx, ax
	movzx eax, word [rmseg]
	shl eax, 4
	mov dx, ax
	shr eax, 16
	mov cx, ax
	mov ax, 7		; base
	int 31h
	mov ax, 8		; grænse 64 KB
	xor cx, cx
	mov dx, 0FFFFh
	int 31h
	mov ax, 9		; kode, ring 3, 32 bit
	mov cx, 40FAh
	int 31h
	xor ax, ax		; og et fladt datasegment: base 0, 4 GB
	mov cx, 1
	int 31h
	mov [sel_flad], ax
	mov bx, ax
	mov ax, 8
	mov cx, 0FFFFh
	mov dx, 0FFFFh
	int 31h
	mov ax, 9
	mov cx, 0C0F2h
	int 31h
	push word [sel_c32]
	push word pm32
	retf

ingen:	mov dx, ingentekst
	mov ah, 9
	int 21h
	mov ax, 4C01h
	int 21h

; ---------------------------------------------------------------------
	[bits 32]
pm32:	mov edx, intro
	call skriv

	; 1. Versionen.
	mov ax, 400h
	int 31h
	mov [v_ver], ax

	; 2. 1 MB over 1 MB-grænsen, gennem det flade segment.
	mov ax, 501h
	mov bx, 10h		; BX:CX = 100000h byte
	xor cx, cx
	int 31h
	jc .ingen_mem
	shl ebx, 16
	mov bx, cx
	mov [v_lin], ebx
	mov fs, [sel_flad]
	mov dword [fs:ebx], 55AA1234h
	mov dword [fs:ebx + 0FFFFCh], 87654321h
	mov eax, [fs:ebx]
	add eax, [fs:ebx + 0FFFFCh]
	mov [v_mem], eax
	cmp ebx, 110000h
	setae byte [v_over1mb]
.ingen_mem:

	; 3. INT 21h direkte (spejlet til real mode): et tegn.
	mov edx, direkte
	call skriv
	mov ah, 2
	mov dl, '*'
	int 21h
	mov edx, nl
	call skriv

	; 4. Timerens IRQ 0 (vektor 8) til vores egen handler.
	mov ax, 204h
	mov bl, 8
	int 31h
	mov [gl_sel], cx
	mov [gl_off], edx
	mov ax, 205h
	mov bl, 8
	mov cx, [sel_c32]
	mov edx, irq0
	int 31h
	sti
	mov ecx, 10000000
.vent:	cmp dword [v_tik], 3
	jae .nok
	loop .vent
.nok:	mov ax, 205h		; den gamle handler tilbage
	mov bl, 8
	mov cx, [gl_sel]
	mov edx, [gl_off]
	int 31h

	; 5. En undtagelseshandler for #GP, og en #GP.
	mov ax, 203h
	mov bl, 13
	mov cx, [sel_c32]
	mov edx, gp_handler
	int 31h
	mov ax, 0FFF8h
	mov gs, ax		; (2 byte, som handleren springer over)
	mov ax, 0
	mov gs, ax

	; 6. En real mode-callback, kaldt fra real mode med 0301h.
	push ds
	push es
	mov ax, ds
	mov es, ax
	mov edi, cb_regs
	mov ax, [sel_c32]
	mov ds, ax
	mov esi, callback
	mov ax, 303h
	int 31h
	pop es
	pop ds
	jc .ingen_cb
	mov [rm_regs + 2Ch], cx	; CS:IP = callbackens adresse
	mov [rm_regs + 2Ah], dx
	mov word [rm_regs + 2Eh], 0
	mov word [rm_regs + 30h], 0
	push es
	mov ax, ds
	mov es, ax
	mov edi, rm_regs
	mov ax, 301h
	xor bx, bx
	xor cx, cx
	int 31h
	pop es
	setnc byte [v_cbret]
.ingen_cb:

	; 7. DOS-hukommelse: et segment og en selektor til det.
	mov ax, 100h
	mov bx, 1
	int 31h
	jc .ingen_dos
	mov gs, dx
	mov byte [gs:0], 77
	movzx eax, ax
	shl eax, 4
	mov fs, [sel_flad]
	movzx eax, byte [fs:eax]
	mov [v_dos], eax
	mov ax, 101h
	int 31h
.ingen_dos:

	; Resultaterne.
	mov esi, tests
.test:	lodsd
	or eax, eax
	jz .slut
	mov ebx, eax
	lodsd
	mov ebp, eax
	mov edx, esi
	push esi
	call skriv
	pop esi
	cmp ebp, [ebx]
	mov edx, ok
	je .ok
	mov edx, fejl
.ok:	push esi
	call skriv
	pop esi
.naeste:
	lodsb
	cmp al, '$'
	jne .naeste
	jmp .test
.slut:	mov edx, slut
	call skriv
	mov ax, 4C00h		; slut, fra protected mode
	int 21h

; Skriver $-teksten ved EDX i vores segment, med DOS i real mode (0300h).
skriv:	pushad
	mov [rm_regs + 14h], edx
	mov dword [rm_regs + 1Ch], 0900h
	mov ax, [rmseg]
	mov [rm_regs + 24h], ax
	mov word [rm_regs + 20h], 0
	mov dword [rm_regs + 2Eh], 0
	push es
	mov ax, ds
	mov es, ax
	mov edi, rm_regs
	mov ax, 300h
	mov bx, 21h
	xor cx, cx
	int 31h
	pop es
	popad
	ret

irq0:	push ds
	push eax
	mov ds, [cs:sel_ds_c]
	inc dword [v_tik]
	mov al, 20h		; EOI
	out 20h, al
	pop eax
	pop ds
	iretd

; DPMI-undtagelsesrammen: returadresse (8), fejlkode, EIP, CS, EFLAGS...
gp_handler:
	push ds
	mov ds, [cs:sel_ds_c]
	inc dword [v_gp]
	push eax
	mov eax, [esp + 8 + 8]	; fejlkoden
	mov [v_gpfejl], eax
	add dword [esp + 8 + 12], 2 ; spring instruktionen over
	pop eax
	pop ds
	retf

; Callbacken: DS:ESI = real mode-stakken, ES:EDI = registrene. Vi lader
; som om den returnerer med RETF.
callback:
	inc dword [es:v_cb]
	mov ax, [esi]
	mov [es:edi + 2Ah], ax
	mov ax, [esi + 2]
	mov [es:edi + 2Ch], ax
	add word [es:edi + 2Eh], 4
	iretd

ingentekst db "Ingen DPMI-vaert.", 13, 10, "$"
intro	db "DPMI i 32-bit protected mode:", 13, 10, "$"
direkte	db "  INT 21h direkte (et '*'): $"
nl	db 13, 10, "$"
ok	db " OK", 13, 10, "$"
fejl	db " FEJL", 13, 10, "$"
slut	db "Tilbage til DOS fra protected mode.", 13, 10, "$"

tests	dd v_ver
	dd 5Ah
	db "  DPMI 0.90 (0400h) ...........$"
	dd v_over1mb
	dd 1
	db "  1 MB over 1 MB-graensen .....$"
	dd v_mem
	dd 55AA1234h + 87654321h
	db "  Skrevet og laest igen .......$"
	dd v_tik
	dd 3
	db "  Timer-IRQ til vores handler .$"
	dd v_gp
	dd 1
	db "  #GP til undtagelseshandler ..$"
	dd v_gpfejl
	dd 0FFF8h
	db "  #GP med fejlkode 0FFF8h .....$"
	dd v_cb
	dd 1
	db "  Real mode-callback ..........$"
	dd v_cbret
	dd 1
	db "  ... og tilbage igen .........$"
	dd v_dos
	dd 77
	db "  DOS-hukommelse (0100h) ......$"
	dd 0

	align 4
v_ver	dd 0
v_lin	dd 0
v_mem	dd 0
v_over1mb dd 0
v_tik	dd 0
v_gp	dd 0
v_gpfejl dd 0
v_cb	dd 0
v_cbret	dd 0
v_dos	dd 0
gl_off	dd 0
gl_sel	dw 0
indgang	dd 0
rmseg	dw 0
sel_ds	dw 0
sel_ds_c equ sel_ds
sel_c32	dw 0
sel_flad dw 0
	align 4
rm_regs	times 32h db 0
cb_regs	times 32h db 0
