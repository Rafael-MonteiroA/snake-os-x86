; ==============================================================
;  boot.asm — Stage 1 Bootloader (MBR, 512 bytes)
; ==============================================================
;
;  Este código é gravado no setor 0 do disco (MBR).
;  O BIOS o carrega em 0x0000:0x7C00 e transfere controle aqui.
;
;  Missão: carregar os setores 2-16 do disco em 0x1000:0x0000
;  (endereço físico 0x10000) e pular para lá.
;
;  Usa INT 13h AH=02h (LBA via CHS, cilindro 0, cabeça 0).
; ==============================================================

    bits 16
    org  0x7C00         ; BIOS carrega o MBR neste endereço

; ── Entry ──────────────────────────────────────────────────
start:
    cli
    xor  ax, ax
    mov  ds, ax
    mov  es, ax
    mov  ss, ax
    mov  sp, 0x7C00     ; stack cresce para baixo a partir do MBR
    sti

    mov  [boot_drv], dl ; DL = drive de boot (passado pelo BIOS)

    ; ── Carregar kernel em 0x1000:0x0000 ───────────────────
    ; ES:BX = destino
    mov  ax, 0x1000
    mov  es, ax
    xor  bx, bx

    ; INT 13h AH=02h: ler setores do disco
    ;   AL = número de setores a ler
    ;   CH = cilindro (bits 7-0)
    ;   CL = setor (bits 5-0, 1-based) + cilindro bits 9-8 em bits 7-6
    ;   DH = cabeça
    ;   DL = drive
    ;   ES:BX = buffer de destino
    mov  ah, 0x02
    mov  al, 15         ; carregar 15 setores = 7680 bytes (suficiente)
    mov  ch, 0          ; cilindro 0
    mov  cl, 2          ; começar no setor 2 (setor 1 = este bootloader)
    mov  dh, 0          ; cabeça 0
    mov  dl, [boot_drv]
    int  0x13
    jc   disk_err       ; carry = erro

    ; ── Saltar para o kernel ────────────────────────────────
    ; Far jump: CS=0x1000, IP=0x0000
    jmp  0x1000:0x0000

; ── Erro de disco ──────────────────────────────────────────
disk_err:
    mov  si, msg_err
.print:
    lodsb
    test al, al
    jz   .hang
    mov  ah, 0x0E       ; INT 10h: teletype output
    int  0x10
    jmp  .print
.hang:
    cli
    hlt
    jmp  .hang

; ── Dados ──────────────────────────────────────────────────
boot_drv    db 0
msg_err     db "Boot error!", 0

    ; Preencher com zeros até o byte 510, depois assinatura MBR
    times 510-($-$$) db 0
    dw   0xAA55
