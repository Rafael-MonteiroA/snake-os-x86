; ==============================================================
;  kernel.asm — Snake Game, bare metal x86 (sem OS, sem DOS)
;  Carregado pelo boot.asm em 0x1000:0x0000
; ==============================================================
;
;  Técnicas:
;    • Modo texto VGA 80×25 (segmento 0xB800) — escrita direta
;    • Hook de INT 8h (IRQ0, timer a 18.2 Hz) para mover a cobra
;    • Hook de INT 9h (IRQ1, teclado) lendo porta 0x60 diretamente
;    • Ring buffer de 256 posições para o corpo da cobra
;    • LCG (Linear Congruential Generator) para posição da comida
;    • Caracteres CP437 para gráficos (box-drawing, blocos)
;
;  Controles: W/A/S/D  ou  setas  para mover
;             ENTER    para reiniciar após game over
;             ESC      para reiniciar o jogo
; ==============================================================

    bits 16
    org  0x0000         ; carregado em 0x1000:0x0000, offsets a partir de 0

; ── Constantes de vídeo ────────────────────────────────────
VID_SEG     equ 0xB800  ; segmento do framebuffer de texto VGA
SCR_W       equ 80
SCR_H       equ 25

; ── Área de jogo (dentro da borda) ─────────────────────────
;   Col 0    : margem
;   Col 1    : borda esquerda
;   Cols 2-77: área de jogo (76 cols)
;   Col 78   : borda direita
;   Col 79   : margem
;
;   Row 0    : placar / UI
;   Row 1    : título
;   Row 2    : borda superior
;   Rows 3-22: área de jogo (20 linhas)
;   Row 23   : borda inferior
;   Row 24   : instrução de teclas

PX1         equ 2       ; coluna inicial do jogo
PX2         equ 77      ; coluna final do jogo
PY1         equ 3       ; linha inicial do jogo
PY2         equ 22      ; linha final do jogo
PW          equ 76      ; largura (PX2 - PX1 + 1)
PH          equ 20      ; altura  (PY2 - PY1 + 1)

; ── Caracteres CP437 ───────────────────────────────────────
CH_HEAD     equ 0x01    ; ☺ cabeça da cobra
CH_BODY     equ 0xB2    ; ▓ corpo
CH_FOOD     equ 0x04    ; ♦ comida
CH_EMPTY    equ 0x20    ; espaço
CH_TL       equ 0xC9    ; ╔ canto superior-esquerdo
CH_TR       equ 0xBB    ; ╗ canto superior-direito
CH_BL       equ 0xC8    ; ╚ canto inferior-esquerdo
CH_BR       equ 0xBC    ; ╝ canto inferior-direito
CH_HL       equ 0xCD    ; ═ horizontal
CH_VL       equ 0xBA    ; ║ vertical

; ── Atributos de cor (bg<<4 | fg, valores 0-15) ─────────────
AT_BORDER   equ 0x0A    ; verde brilhante
AT_HEAD     equ 0x0B    ; ciano brilhante
AT_BODY     equ 0x02    ; verde escuro
AT_FOOD     equ 0x0C    ; vermelho brilhante
AT_UI       equ 0x0F    ; branco brilhante
AT_TITLE    equ 0x0E    ; amarelo
AT_BLANK    equ 0x00    ; preto em preto
AT_GAMEOVER equ 0x4F    ; branco em vermelho

; ── Direções ───────────────────────────────────────────────
DIR_R       equ 0
DIR_D       equ 1
DIR_L       equ 2
DIR_U       equ 3

; ── Velocidade inicial (ticks do timer por movimento) ──────
SPEED_INIT  equ 9       ; 18.2 Hz / 9 ≈ 2 movimentos/segundo

; ── Entry point ────────────────────────────────────────────
kernel_entry:
    cli
    mov  ax, cs         ; CS = 0x1000 (definido pelo far jump do bootloader)
    mov  ds, ax
    mov  es, ax
    mov  ss, ax
    mov  sp, 0xFFF0     ; stack no topo do nosso segmento de 64KB
    sti

    call init_vars
    call setup_interrupts
    call clear_screen
    call draw_border
    call draw_initial_snake
    call seed_rng
    call spawn_food
    call draw_food
    call draw_ui

    ; ── Loop principal ──────────────────────────────────────
    ; Toda a lógica acontece nas ISRs (timer move a cobra,
    ; teclado muda direção). O main loop só monitora flags.
.loop:
    hlt                 ; dorme até o próximo interrupt (≈55ms)
    cmp  byte [f_quit], 1
    je   .do_quit
    cmp  byte [f_over], 1
    je   .do_gameover
    jmp  .loop

.do_gameover:
    call show_gameover
    mov  byte [f_restart], 0
.wait_restart:
    hlt
    cmp  byte [f_restart], 1
    jne  .wait_restart
    ; Reiniciar: teardown + recomeçar do zero
    call teardown_interrupts
    jmp  kernel_entry

.do_quit:
    call teardown_interrupts
    mov  ax, 0x0003     ; INT 10h: voltar ao modo texto padrão
    int  0x10
    ; Escrever "Tchau!" e travar (estamos em bare metal, sem OS para retornar)
    mov  si, str_bye
    xor  bx, bx
    mov  ah, 0x0E
.bye_print:
    lodsb
    test al, al
    jz   .freeze
    int  0x10
    jmp  .bye_print
.freeze:
    cli
    hlt
    jmp  .freeze

; ──────────────────────────────────────────────────────────
;  ISR: Timer  INT 8h / IRQ0 (~18.2 Hz)
; ──────────────────────────────────────────────────────────
timer_isr:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    push ds

    mov  ax, 0x1000
    mov  ds, ax

    ; Enviar EOI ao PIC master (obrigatório)
    mov  al, 0x20
    out  0x20, al

    cmp  byte [f_over], 1
    je   .t_done

    inc  byte [tick]
    mov  al, [tick]
    cmp  al, [speed]
    jb   .t_done

    mov  byte [tick], 0
    call move_snake

.t_done:
    pop  ds
    pop  es
    pop  di
    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    iret

; ──────────────────────────────────────────────────────────
;  ISR: Teclado  INT 9h / IRQ1
; ──────────────────────────────────────────────────────────
kbd_isr:
    push ax
    push ds

    mov  ax, 0x1000
    mov  ds, ax

    in   al, 0x60           ; ler scancode do controlador de teclado

    ; Ignorar break codes (tecla solta = bit 7 setado)
    test al, 0x80
    jnz  .k_eoi

    ; ESC (0x01): sinalizar saída
    cmp  al, 0x01
    jne  .k_not_esc
    mov  byte [f_quit], 1
    jmp  .k_eoi

.k_not_esc:
    ; ENTER (0x1C): reiniciar durante game over
    cmp  al, 0x1C
    jne  .k_not_enter
    cmp  byte [f_over], 1
    jne  .k_not_enter
    mov  byte [f_restart], 1
    jmp  .k_eoi

.k_not_enter:
    ; Mapear scancode → direção
    cmp  al, 0x11           ; W
    je   .dir_u
    cmp  al, 0x48           ; seta ↑
    je   .dir_u
    cmp  al, 0x1F           ; S
    je   .dir_d
    cmp  al, 0x50           ; seta ↓
    je   .dir_d
    cmp  al, 0x1E           ; A
    je   .dir_l
    cmp  al, 0x4B           ; seta ←
    je   .dir_l
    cmp  al, 0x20           ; D
    je   .dir_r
    cmp  al, 0x4D           ; seta →
    je   .dir_r
    jmp  .k_eoi

.dir_u:  mov ah, DIR_U  ;  jmp .set_dir
         jmp .set_dir
.dir_d:  mov ah, DIR_D
         jmp .set_dir
.dir_l:  mov ah, DIR_L
         jmp .set_dir
.dir_r:  mov ah, DIR_R

.set_dir:
    ; Não permitir reversão de direção:
    ; DIR_R(0) e DIR_L(2) são opostos → XOR = 2
    ; DIR_D(1) e DIR_U(3) são opostos → XOR = 2
    mov  al, [cur_dir]
    xor  al, ah
    cmp  al, 2
    je   .k_eoi             ; direção oposta → ignorar
    mov  [nxt_dir], ah

.k_eoi:
    mov  al, 0x20
    out  0x20, al           ; EOI ao PIC
    pop  ds
    pop  ax
    iret

; ──────────────────────────────────────────────────────────
;  MOVE_SNAKE
;  Chamada pelo timer ISR a cada N ticks.
; ──────────────────────────────────────────────────────────
move_snake:
    push ax
    push bx
    push cx
    push dx
    push si

    ; ── 1. Atualizar direção ────────────────────────────────
    mov  al, [nxt_dir]
    mov  [cur_dir], al

    ; ── 2. Calcular nova posição da cabeça ─────────────────
    xor  bx, bx
    mov  bl, [head_idx]
    mov  dl, [snake_x + bx]     ; DL = coluna atual da cabeça
    mov  dh, [snake_y + bx]     ; DH = linha atual da cabeça

    mov  al, [cur_dir]
    cmp  al, DIR_R
    jne  .not_r
    inc  dl
    jmp  .dir_done
.not_r:
    cmp  al, DIR_L
    jne  .not_l
    dec  dl
    jmp  .dir_done
.not_l:
    cmp  al, DIR_D
    jne  .not_d
    inc  dh
    jmp  .dir_done
.not_d:
    dec  dh                     ; DIR_U

.dir_done:
    ; ── 3. Colisão com parede ──────────────────────────────
    cmp  dl, PX1
    jl   .wall_hit
    cmp  dl, PX2
    jg   .wall_hit
    cmp  dh, PY1
    jl   .wall_hit
    cmp  dh, PY2
    jg   .wall_hit
    jmp  .no_wall
.wall_hit:
    mov  byte [f_over], 1
    jmp  .ms_ret
.no_wall:

    ; Salvar nova posição
    mov  [new_hx], dl
    mov  [new_hy], dh

    ; ── 4. Colisão com o próprio corpo ─────────────────────
    xor  bx, bx
    mov  bl, [tail_idx]
    mov  cx, [s_len]
    dec  cx                     ; não checar a cabeça atual
.self_loop:
    jcxz .no_self
    mov  al, [snake_x + bx]
    cmp  al, [new_hx]
    jne  .self_next
    mov  al, [snake_y + bx]
    cmp  al, [new_hy]
    je   .self_hit
.self_next:
    inc  bl                     ; BL wraps em 256 automaticamente (byte)
    dec  cx
    jmp  .self_loop
.self_hit:
    mov  byte [f_over], 1
    jmp  .ms_ret
.no_self:

    ; ── 5. Verificar comida ────────────────────────────────
    mov  al, [new_hx]
    cmp  al, [food_x]
    jne  .no_food
    mov  al, [new_hy]
    cmp  al, [food_y]
    jne  .no_food
    ; Comeu!
    mov  byte [f_grow], 1
    add  word [score], 10
    ; Aumentar velocidade a cada 50 pontos
    mov  ax, [score]
    xor  dx, dx
    mov  cx, 50
    div  cx
    test dx, dx
    jnz  .no_speedup
    cmp  byte [speed], 3
    jle  .no_speedup
    dec  byte [speed]
.no_speedup:
    call spawn_food
    call draw_food
    call draw_ui
    jmp  .after_food
.no_food:
    mov  byte [f_grow], 0

.after_food:
    ; ── 6. Remover cauda (se não crescendo) ────────────────
    cmp  byte [f_grow], 1
    je   .keep_tail
    xor  bx, bx
    mov  bl, [tail_idx]
    mov  dl, [snake_x + bx]
    mov  dh, [snake_y + bx]
    mov  al, CH_EMPTY
    mov  ah, AT_BLANK
    call put_char
    inc  byte [tail_idx]
    dec  word [s_len]
.keep_tail:

    ; ── 7. Desenhar corpo no lugar da cabeça atual ─────────
    xor  bx, bx
    mov  bl, [head_idx]
    mov  dl, [snake_x + bx]
    mov  dh, [snake_y + bx]
    mov  al, CH_BODY
    mov  ah, AT_BODY
    call put_char

    ; ── 8. Avançar cabeça e registrar nova posição ─────────
    inc  byte [head_idx]
    inc  word [s_len]
    xor  bx, bx
    mov  bl, [head_idx]
    mov  al, [new_hx]
    mov  [snake_x + bx], al
    mov  al, [new_hy]
    mov  [snake_y + bx], al

    ; ── 9. Desenhar nova cabeça ────────────────────────────
    mov  dl, [new_hx]
    mov  dh, [new_hy]
    mov  al, CH_HEAD
    mov  ah, AT_HEAD
    call put_char

.ms_ret:
    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret

; ──────────────────────────────────────────────────────────
;  PUT_CHAR
;  Escreve um caractere no framebuffer de texto VGA.
;
;  Entrada: DL = coluna (0-79)
;           DH = linha  (0-24)
;           AL = código do caractere (CP437)
;           AH = atributo (bg<<4 | fg)
;  Preserva todos os registradores
; ──────────────────────────────────────────────────────────
put_char:
    push es
    push ax
    push bx
    push di

    push ax                     ; salvar char+attr para dopo
    mov  ax, VID_SEG
    mov  es, ax

    ; DI = (linha * 80 + coluna) * 2
    ; linha * 80 = linha * 64 + linha * 16
    xor  di, di
    xor  bx, bx
    mov  bl, dh                 ; BX = linha
    mov  di, bx
    shl  di, 6                  ; DI = linha * 64
    shl  bx, 4                  ; BX = linha * 16
    add  di, bx                 ; DI = linha * 80
    xor  bx, bx
    mov  bl, dl                 ; BX = coluna
    add  di, bx                 ; DI = linha*80 + coluna
    shl  di, 1                  ; DI *= 2 (cada célula = 2 bytes)

    pop  ax                     ; restaurar char+attr
    stosw                       ; escreve AL=[char], AH=[attr] em ES:[DI]

    pop  di
    pop  bx
    pop  ax
    pop  es
    ret

; ──────────────────────────────────────────────────────────
;  SETUP_INTERRUPTS — Instala nossas ISRs na IVT
; ──────────────────────────────────────────────────────────
setup_interrupts:
    cli
    push es
    push ax

    xor  ax, ax
    mov  es, ax                 ; ES = 0 para acessar a IVT

    ; Salvar INT 8h original (offset em 0x0020, segmento em 0x0022)
    mov  ax, [es:0x0020]
    mov  [old8_off], ax
    mov  ax, [es:0x0022]
    mov  [old8_seg], ax

    ; Instalar nosso timer_isr
    mov  word [es:0x0020], timer_isr
    mov  ax, 0x1000
    mov  [es:0x0022], ax

    ; Salvar INT 9h original (offset em 0x0024, segmento em 0x0026)
    mov  ax, [es:0x0024]
    mov  [old9_off], ax
    mov  ax, [es:0x0026]
    mov  [old9_seg], ax

    ; Instalar nosso kbd_isr
    mov  word [es:0x0024], kbd_isr
    mov  ax, 0x1000
    mov  [es:0x0026], ax

    pop  ax
    pop  es
    sti
    ret

; ──────────────────────────────────────────────────────────
;  TEARDOWN_INTERRUPTS — Restaura as ISRs originais do BIOS
; ──────────────────────────────────────────────────────────
teardown_interrupts:
    cli
    push es
    push ax

    xor  ax, ax
    mov  es, ax

    mov  ax, [old8_off]
    mov  [es:0x0020], ax
    mov  ax, [old8_seg]
    mov  [es:0x0022], ax

    mov  ax, [old9_off]
    mov  [es:0x0024], ax
    mov  ax, [old9_seg]
    mov  [es:0x0026], ax

    pop  ax
    pop  es
    sti
    ret

; ──────────────────────────────────────────────────────────
;  INIT_VARS — Zerar e inicializar todas as variáveis do jogo
; ──────────────────────────────────────────────────────────
init_vars:
    push ax

    ; Cobra inicia com 3 segmentos em (38,12) (39,12) (40,12) →
    ; tail_idx=0 (mais antigo=cauda), head_idx=2 (mais novo=cabeça)
    mov  byte [snake_x + 0], 38
    mov  byte [snake_y + 0], 12
    mov  byte [snake_x + 1], 39
    mov  byte [snake_y + 1], 12
    mov  byte [snake_x + 2], 40
    mov  byte [snake_y + 2], 12

    mov  byte [tail_idx], 0
    mov  byte [head_idx], 2
    mov  word [s_len],    3

    mov  byte [cur_dir], DIR_R
    mov  byte [nxt_dir], DIR_R
    mov  byte [f_grow],  0
    mov  word [score],   0
    mov  byte [speed],   SPEED_INIT
    mov  byte [tick],    0
    mov  byte [f_over],  0
    mov  byte [f_quit],  0
    mov  byte [f_restart], 0

    pop  ax
    ret

; ──────────────────────────────────────────────────────────
;  CLEAR_SCREEN — Preencher tela com espaços pretos
; ──────────────────────────────────────────────────────────
clear_screen:
    push es
    push di
    push ax
    push cx

    mov  ax, VID_SEG
    mov  es, ax
    xor  di, di
    mov  cx, SCR_W * SCR_H
    mov  ax, 0x0020             ; AH=0x00 (preto), AL=0x20 (espaço)
    rep  stosw

    pop  cx
    pop  ax
    pop  di
    pop  es
    ret

; ──────────────────────────────────────────────────────────
;  DRAW_BORDER — Desenhar moldura com box-drawing CP437
; ──────────────────────────────────────────────────────────
draw_border:
    push ax
    push cx
    push dx

    ; ── Canto TL ───────────────────────────────────────────
    mov  dl, 1
    mov  dh, 2
    mov  al, CH_TL
    mov  ah, AT_BORDER
    call put_char

    ; ── Linha superior (═) cols 2..77 ─────────────────────
    mov  dl, 2
    mov  dh, 2
    mov  cx, PW             ; 76 células
.top_h:
    mov  al, CH_HL
    mov  ah, AT_BORDER
    call put_char
    inc  dl
    dec  cx
    jnz  .top_h

    ; ── Canto TR ───────────────────────────────────────────
    mov  dl, 78
    mov  dh, 2
    mov  al, CH_TR
    mov  ah, AT_BORDER
    call put_char

    ; ── Linhas verticais (║) rows 3..22 ───────────────────
    mov  dh, 3
.vert:
    cmp  dh, 23
    jge  .vert_done
    mov  dl, 1
    mov  al, CH_VL
    mov  ah, AT_BORDER
    call put_char
    mov  dl, 78
    call put_char
    inc  dh
    jmp  .vert
.vert_done:

    ; ── Canto BL ───────────────────────────────────────────
    mov  dl, 1
    mov  dh, 23
    mov  al, CH_BL
    mov  ah, AT_BORDER
    call put_char

    ; ── Linha inferior (═) cols 2..77 ─────────────────────
    mov  dl, 2
    mov  dh, 23
    mov  cx, PW
.bot_h:
    mov  al, CH_HL
    mov  ah, AT_BORDER
    call put_char
    inc  dl
    dec  cx
    jnz  .bot_h

    ; ── Canto BR ───────────────────────────────────────────
    mov  dl, 78
    mov  dh, 23
    mov  al, CH_BR
    mov  ah, AT_BORDER
    call put_char

    pop  dx
    pop  cx
    pop  ax
    ret

; ──────────────────────────────────────────────────────────
;  DRAW_INITIAL_SNAKE — Pintar os 3 segmentos iniciais
; ──────────────────────────────────────────────────────────
draw_initial_snake:
    push ax
    push dx

    ; Cauda (38,12) e corpo (39,12) = CH_BODY
    mov  dh, 12
    mov  dl, 38
    mov  al, CH_BODY
    mov  ah, AT_BODY
    call put_char
    mov  dl, 39
    call put_char

    ; Cabeça (40,12) = CH_HEAD
    mov  dl, 40
    mov  al, CH_HEAD
    mov  ah, AT_HEAD
    call put_char

    pop  dx
    pop  ax
    ret

; ──────────────────────────────────────────────────────────
;  DRAW_UI — Placar na linha 0, instruções na linha 24
; ──────────────────────────────────────────────────────────
draw_ui:
    push es
    push di
    push ax
    push cx
    push si

    mov  ax, VID_SEG
    mov  es, ax

    ; ── Linha 0: placar ────────────────────────────────────
    xor  di, di             ; início da linha 0
    mov  cx, SCR_W
    mov  ax, (AT_BLANK << 8) | CH_EMPTY
    rep  stosw              ; limpar linha 0

    xor  di, di
    mov  si, str_score
.ui_score_lbl:
    lodsb
    test al, al
    jz   .ui_score_num
    mov  ah, AT_TITLE
    stosw
    jmp  .ui_score_lbl

.ui_score_num:
    mov  ax, [score]
    call write_number       ; escreve em ES:DI, avança DI

    ; "  NIVEL: N" a partir da coluna 20
    mov  di, 20 * 2
    mov  si, str_nivel
.ui_nivel_lbl:
    lodsb
    test al, al
    jz   .ui_nivel_num
    mov  ah, AT_TITLE
    stosw
    jmp  .ui_nivel_lbl
.ui_nivel_num:
    ; Nível = SPEED_INIT - speed + 1
    mov  al, SPEED_INIT
    sub  al, [speed]
    inc  al
    xor  ah, ah
    call write_number

    ; ── Linha 1: título ────────────────────────────────────
    mov  di, SCR_W * 2      ; linha 1
    mov  si, str_title
.ui_title:
    lodsb
    test al, al
    jz   .ui_done
    mov  ah, AT_TITLE
    stosw
    jmp  .ui_title

.ui_done:
    pop  si
    pop  cx
    pop  ax
    pop  di
    pop  es
    ret

; ──────────────────────────────────────────────────────────
;  WRITE_NUMBER  (helper para draw_ui)
;  Escreve AX como decimal em ES:DI, avança DI.
;  Atributo fixo = AT_UI (branco brilhante)
; ──────────────────────────────────────────────────────────
write_number:
    push ax
    push bx
    push cx
    push dx

    xor  bx, bx             ; BX = contador de dígitos empilhados

    test ax, ax
    jnz  .wn_loop
    ; Caso especial: 0
    mov  al, '0'
    mov  ah, AT_UI
    stosw
    jmp  .wn_done

.wn_loop:
    xor  dx, dx
    mov  cx, 10
    div  cx                 ; AX = quociente, DX = resto
    push dx                 ; empilhar dígito (LSD primeiro)
    inc  bx
    test ax, ax
    jnz  .wn_loop

.wn_write:
    pop  dx
    mov  al, dl
    add  al, '0'
    mov  ah, AT_UI
    stosw
    dec  bx
    jnz  .wn_write

.wn_done:
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret

; ──────────────────────────────────────────────────────────
;  SPAWN_FOOD — Sortear posição aleatória para a comida
; ──────────────────────────────────────────────────────────
spawn_food:
    push ax
    push cx
    push dx

    call get_rng
    xor  dx, dx
    mov  cx, PW             ; módulo pela largura do jogo
    div  cx                 ; DX = AX % PW
    mov  al, dl
    add  al, PX1
    mov  [food_x], al

    call get_rng
    xor  dx, dx
    mov  cx, PH             ; módulo pela altura do jogo
    div  cx
    mov  al, dl
    add  al, PY1
    mov  [food_y], al

    pop  dx
    pop  cx
    pop  ax
    ret

; ──────────────────────────────────────────────────────────
;  DRAW_FOOD — Renderizar a comida na tela
; ──────────────────────────────────────────────────────────
draw_food:
    push ax
    push dx

    mov  dl, [food_x]
    mov  dh, [food_y]
    mov  al, CH_FOOD
    mov  ah, AT_FOOD
    call put_char

    pop  dx
    pop  ax
    ret

; ──────────────────────────────────────────────────────────
;  SHOW_GAMEOVER — Exibir mensagem de game over
; ──────────────────────────────────────────────────────────
show_gameover:
    push es
    push di
    push si
    push ax

    mov  ax, VID_SEG
    mov  es, ax

    ; Linha 12: "  *** GAME OVER ***  "
    mov  di, (12 * SCR_W + 28) * 2
    mov  si, str_over
.go_line:
    lodsb
    test al, al
    jz   .go_next
    mov  ah, AT_GAMEOVER
    stosw
    jmp  .go_line

.go_next:
    ; Linha 13: "   Pontos: NNNN   ENTER = reiniciar"
    mov  di, (13 * SCR_W + 28) * 2
    mov  si, str_pontos
.pts_lbl:
    lodsb
    test al, al
    jz   .pts_num
    mov  ah, AT_TITLE
    stosw
    jmp  .pts_lbl
.pts_num:
    mov  ax, [score]
    call write_number

    mov  si, str_enter
.enter_lbl:
    lodsb
    test al, al
    jz   .go_done
    mov  ah, AT_UI
    stosw
    jmp  .enter_lbl

.go_done:
    pop  ax
    pop  si
    pop  di
    pop  es
    ret

; ──────────────────────────────────────────────────────────
;  SEED_RNG — Semear o gerador com o contador de ticks do BIOS
; ──────────────────────────────────────────────────────────
seed_rng:
    push ax
    push cx
    push dx

    xor  ah, ah
    int  0x1A           ; INT 1Ah AH=0: CX:DX = ticks desde meia-noite
    add  dx, cx
    inc  dx             ; garantir seed != 0
    mov  [rng], dx

    pop  dx
    pop  cx
    pop  ax
    ret

; ──────────────────────────────────────────────────────────
;  GET_RNG — Próximo número pseudoaleatório
;  Saída: AX = número 16-bit
;  LCG: state = state * 25173 + 13849
; ──────────────────────────────────────────────────────────
get_rng:
    push cx
    push dx

    mov  ax, [rng]
    mov  cx, 25173
    mul  cx             ; DX:AX = ax * 25173 (usar só AX = módulo 65536)
    add  ax, 13849
    mov  [rng], ax
    ; AX = novo estado (e valor retornado)

    pop  dx
    pop  cx
    ret

; ──────────────────────────────────────────────────────────
;  DADOS
; ──────────────────────────────────────────────────────────

; Ring buffer da cobra: 256 posições máximas (índices são bytes → wrap automático)
snake_x     times 256 db 0   ; colunas
snake_y     times 256 db 0   ; linhas

; Estado da cobra
head_idx    db 0        ; índice da cabeça no ring buffer
tail_idx    db 0        ; índice da cauda no ring buffer
s_len       dw 0        ; comprimento atual

; Direções
cur_dir     db DIR_R    ; direção atual
nxt_dir     db DIR_R    ; direção bufferizada (input do teclado)

; Flags
f_grow      db 0        ; 1 = cobriu comida neste tick → crescer
f_over      db 0        ; 1 = game over
f_quit      db 0        ; 1 = ESC pressionado
f_restart   db 0        ; 1 = ENTER pressionado no game over

; Jogo
score       dw 0
speed       db SPEED_INIT
tick        db 0        ; contador de ticks do timer

; Comida
food_x      db 0
food_y      db 0

; Temporários (usados em move_snake, evitar reentrância)
new_hx      db 0
new_hy      db 0

; RNG
rng         dw 0xBEEF   ; estado do LCG (sobrescrito por seed_rng)

; Vetores originais das ISRs (para restaurar no teardown)
old8_off    dw 0
old8_seg    dw 0
old9_off    dw 0
old9_seg    dw 0

; Strings (terminadas em 0)
str_score   db "PONTUACAO: ", 0
str_nivel   db "  NIVEL: ", 0
str_title   db " [SNAKE OS] - W/A/S/D ou setas para mover | ESC = sair", 0
str_over    db "  *** GAME OVER ***  ", 0
str_pontos  db "  Pontos: ", 0
str_enter   db "    ENTER = reiniciar", 0
str_bye     db 13, 10, "Ate logo!", 0
