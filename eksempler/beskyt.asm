; beskyt.com — en tur i 386'erens protected mode og tilbage:
;   GDT med 16- og 32-bit segmenter, hukommelse over 1 MB, en IDT med
;   handlere for #GP, sidefejl og softwareafbrydelser, paging med en
;   omflyttet side, en sidefejl der bliver rettet, ring 3 med en TSS
;   (HLT er forbudt dér) og hjem til real mode igen.
;	nasm -f bin beskyt.asm -o beskyt.com
	cpu 386
	org 100h

CODE16	equ 08h
DATA16	equ 10h
CODE32	equ 18h
FLAT	equ 20h
CODE3	equ 28h
DATA3	equ 30h
TSSSEL	equ 38h
PDIR	equ 300000h		; sidekatalog og sidetabel (3 MB)
PTAB	equ 301000h
MEM2M	equ 200000h

	[bits 16]
start:	mov dx, intro
	mov ah, 9
	int 21h
	in al, 92h		; A20 til, så vi kan nå over 1 MB
	or al, 2
	out 92h, al

	; Segmenternes base er der hvor programmet ligger: CS * 16.
	xor ebx, ebx
	mov bx, cs
	shl ebx, 4
	mov eax, ebx
	mov di, gdt + CODE16
	call setbase
	mov di, gdt + DATA16
	call setbase
	mov di, gdt + CODE32
	call setbase
	mov di, gdt + CODE3
	call setbase
	lea eax, [ebx + tss]
	mov di, gdt + TSSSEL
	call setbase
	lea eax, [ebx + gdt]
	mov [gdtr + 2], eax
	lea eax, [ebx + idt]
	mov [idtr + 2], eax
	mov [tilbage + 3], cs	; hoppet hjem til real mode

	; IDT: alle 50 vektorer til "uventet", så de vi bruger.
	mov di, idt
	mov cx, 50
.idt:	mov ax, uventet
	call gate
	add di, 8
	loop .idt
	mov di, idt + 13 * 8
	mov ax, gp_handler
	call gate
	mov di, idt + 14 * 8
	mov ax, pf_handler
	call gate
	mov di, idt + 30h * 8
	mov ax, int30
	call gate
	mov di, idt + 8 * 8
	mov ax, irq0
	call gate
	mov di, idt + 31h * 8
	mov ax, int31
	call gate
	mov byte [idt + 31h * 8 + 5], 0EEh	; DPL 3: må kaldes fra ring 3

	cli
	sidt [realidt]
	lgdt [gdtr]
	lidt [idtr]
	mov eax, cr0
	or al, 1
	mov cr0, eax
	jmp dword CODE32:pm32	; ind i 32-bit kode

; ---------------------------------------------------------------------
	[bits 32]
pm32:	mov ax, FLAT
	mov ds, ax
	mov es, ax
	mov fs, ax
	mov gs, ax
	mov ss, ax
	lea esp, [ebx + stak0]

	; 1. Hukommelse over 1 MB.
	mov dword [MEM2M], 12345678h
	mov eax, [MEM2M]
	mov [ebx + v_mem], eax

	; 2. En ugyldig selektor: #GP med selektoren som fejlkode.
	mov byte [ebx + gp_skip], 2
	mov ax, 0FF8h
	mov ds, ax		; (2 byte, som handleren springer over)
	mov ax, FLAT
	mov ds, ax

	; 3. INT 30h.
	int 30h

	; 3b. Timerens IRQ 0 (vektor 8) i protected mode: vent på to tik.
	sti
.vent:	hlt
	cmp dword [ebx + v_ticks], 2
	jb .vent
	cli

	; 4. LSL: grænsen på det flade segment.
	mov ax, FLAT
	lsl eax, ax
	mov [ebx + v_lsl], eax

	; 5. Paging: de første 4 MB som de er, men side 3FF000h viser
	; 200000h, og side 3FE000h er der ikke (endnu).
	mov edi, PDIR
	mov ecx, 1024
	xor eax, eax
	rep stosd
	mov dword [PDIR], PTAB | 7
	mov edi, PTAB
	mov eax, 7
	mov ecx, 1024
.pt:	stosd
	add eax, 1000h
	loop .pt
	mov dword [PTAB + 3FFh * 4], MEM2M | 7
	mov dword [PTAB + 3FEh * 4], 0
	mov eax, PDIR
	mov cr3, eax
	mov eax, cr0
	or eax, 80000000h
	mov cr0, eax
	jmp .pg			; (som på en rigtig 386)
.pg:	mov eax, [3FF000h]
	mov [ebx + v_page], eax
	mov eax, [3FE000h]	; sidefejl; handleren sætter siden ind
	mov [ebx + v_pf], eax
	mov eax, cr0
	and eax, 7FFFFFFFh
	mov cr0, eax

	; 6. Ring 3 via IRETD, med ring 0's stak i TSS'en.
	lea eax, [ebx + stak0]
	mov [ebx + tss + 4], eax
	mov dword [ebx + tss + 8], FLAT
	mov word [ebx + tss + 66h], 104
	mov ax, TSSSEL
	ltr ax
	mov byte [ebx + gp_skip], 1
	push dword DATA3 | 3
	lea eax, [ebx + stak3]
	push eax
	pushfd
	push dword CODE3 | 3
	push dword ring3
	iretd

ring3:	mov ax, DATA3 | 3
	mov ds, ax
	mov es, ax
	mov ax, cs
	and eax, 3
	mov [ebx + v_cpl], eax
	hlt			; forbudt i ring 3: #GP
	int 31h			; tilbage til ring 0
	jmp $

int31:	; Her er vi i ring 0 igen, på TSS'ens stak.
	mov eax, [esp + 4]	; den CS vi kom fra
	mov [ebx + v_r3cs], eax
	mov ax, FLAT
	mov ds, ax
	mov es, ax
	lea esp, [ebx + stak0]

	; Hjem: 16-bit segmenter med 64 KB grænse, så real mode.
	mov ax, DATA16
	mov ds, ax
	mov es, ax
	mov fs, ax
	mov gs, ax
	mov ss, ax
	mov esp, stak0
	jmp CODE16:pm16

gp_handler:
	push eax
	mov eax, [esp + 4]	; fejlkoden
	cmp dword [ebx + v_gps], 0
	jne .igen
	mov [ebx + v_gp1], eax
.igen:	mov [ebx + v_gpcode], eax
	inc dword [ebx + v_gps]
	movzx eax, byte [ebx + gp_skip]
	add [esp + 8], eax	; spring instruktionen over
	pop eax
	add esp, 4
	iretd

pf_handler:
	push eax
	mov eax, cr2
	mov [ebx + v_cr2], eax
	mov eax, [esp + 4]
	mov [ebx + v_pfcode], eax
	mov dword [PTAB + 3FEh * 4], MEM2M | 7
	mov eax, cr3		; tøm TLB'en
	mov cr3, eax
	pop eax
	add esp, 4
	iretd			; og prøv igen

int30:	inc dword [ebx + v_int30]
	iretd

irq0:	inc dword [ebx + v_ticks]
	push eax
	mov al, 20h		; EOI til interrupt-controlleren
	out 20h, al
	pop eax
	iretd

uventet:
	inc dword [ebx + v_uventet]
	cli
	hlt
	jmp uventet

; ---------------------------------------------------------------------
	[bits 16]
pm16:	mov eax, cr0
	and al, 0FEh
	mov cr0, eax
tilbage:
	jmp 0:real		; (segmentet sættes ind ved start)
real:	mov ax, cs
	mov ds, ax
	mov es, ax
	mov ss, ax
	mov sp, stak0
	lidt [realidt]
	sti

	mov si, tests
.test:	lodsw			; adressen på værdien
	or ax, ax
	jz .slut
	mov bx, ax
	lodsd			; den værdi den skal have
	mov ebp, eax
	mov dx, si		; navnet
	mov ah, 9
	int 21h
	cmp ebp, [bx]
	mov dx, ok
	je .ok
	mov dx, fejl
.ok:	mov ah, 9
	int 21h
.naeste:
	lodsb			; videre efter navnets '$'
	cmp al, '$'
	jne .naeste
	jmp .test
.slut:	mov dx, slut
	mov ah, 9
	int 21h
	mov ax, 4C00h
	int 21h

; DI = deskriptoren, EAX = base.
setbase:
	mov [di + 2], ax
	push eax
	shr eax, 16
	mov [di + 4], al
	mov [di + 7], ah
	pop eax
	ret

; DI = gaten, AX = offset (selektor CODE32, 32-bit interrupt gate).
gate:	mov [di], ax
	mov word [di + 2], CODE32
	mov word [di + 4], 8E00h
	mov word [di + 6], 0
	ret

intro	db "Til protected mode og tilbage:", 13, 10, "$"
ok	db " OK", 13, 10, "$"
fejl	db " FEJL", 13, 10, "$"
slut	db "Tilbage i real mode.", 13, 10, "$"

; adresse, forventet værdi, navn
tests	dw v_mem
	dd 12345678h
	db "  Hukommelse over 1 MB ........$"
	dw v_gp1
	dd 0FF8h
	db "  #GP med selektor 0FF8h ......$"
	dw v_gpcode
	dd 0
	db "  #GP fra ring 3 (HLT) ........$"
	dw v_gps
	dd 2
	db "  #GP to gange ................$"
	dw v_int30
	dd 1
	db "  INT 30h .....................$"
	dw v_ticks
	dd 2
	db "  Timer-IRQ i protected mode ..$"
	dw v_lsl
	dd 0FFFFFFFFh
	db "  LSL paa 4 GB-segment ........$"
	dw v_page
	dd 12345678h
	db "  Omflyttet side ..............$"
	dw v_cr2
	dd 3FE000h
	db "  Sidefejl (CR2) ..............$"
	dw v_pf
	dd 12345678h
	db "  Siden efter fejlen ..........$"
	dw v_cpl
	dd 3
	db "  Kode i ring 3 ...............$"
	dw v_r3cs
	dd CODE3 | 3
	db "  Tilbage til ring 0 ..........$"
	dw v_uventet
	dd 0
	db "  Ingen uventede afbrydelser ..$"
	dw 0

	align 4
v_mem	dd 0
v_gp1	dd -1
v_gpcode dd -1
v_gps	dd 0
v_int30	dd 0
v_ticks	dd 0
v_lsl	dd 0
v_page	dd 0
v_cr2	dd 0
v_pfcode dd -1
v_pf	dd 0
v_cpl	dd 0
v_r3cs	dd 0
v_uventet dd 0
gp_skip	db 0

	align 8
gdt	dq 0
	dw 0FFFFh, 0		; 08 CODE16
	db 0, 9Ah, 00h, 0
	dw 0FFFFh, 0		; 10 DATA16
	db 0, 92h, 00h, 0
	dw 0FFFFh, 0		; 18 CODE32 (4 GB, 32 bit)
	db 0, 9Ah, 0CFh, 0
	dw 0FFFFh, 0		; 20 FLAT (base 0, 4 GB)
	db 0, 92h, 0CFh, 0
	dw 0FFFFh, 0		; 28 CODE3 (ring 3)
	db 0, 0FAh, 0CFh, 0
	dw 0FFFFh, 0		; 30 DATA3 (ring 3, flad)
	db 0, 0F2h, 0CFh, 0
	dw 103, 0		; 38 TSS (32 bit, ledig)
	db 0, 89h, 00h, 0
gdt_slut:
gdtr	dw gdt_slut - gdt - 1
	dd 0
idtr	dw 50 * 8 - 1
	dd 0
realidt	dw 0
	dd 0

	align 8
tss	times 104 db 0
idt	times 50 * 8 db 0
	times 256 db 0
stak3:
	times 512 db 0
stak0:
