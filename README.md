# Snake OS — Jogo bare metal em Assembly x86

Um jogo de Snake que roda **sem sistema operacional** — direto no hardware,
como o primeiro código que a CPU executa ao ligar o computador.

```
┌─────────────────────────────────────────────────────────────────────────┐
│ PONTUACAO: 50   NIVEL: 2                                                │
│ [SNAKE OS] - W/A/S/D ou setas para mover | ESC = sair                   │
│ ╔═════════════════════════════════════════════════════════════════════╗ │
│ ║                                                                     ║ │
│ ║              ▓▓▓▓▓▓▓☺                                               ║ │
│ ║                     ♦                                               ║ │
│ ╚═════════════════════════════════════════════════════════════════════╝ │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Como rodar

### Dependências
```bash
# Ubuntu / Debian / WSL
sudo apt install nasm qemu-system-x86

# macOS (Homebrew)
brew install nasm qemu
```

### Compilar e rodar
```bash
make        # compila boot.asm + kernel.asm → os_snake.img
make run    # abre o QEMU com a imagem
```

### Controles
| Tecla | Ação |
|-------|------|
| `W` / `↑` | Mover para cima |
| `S` / `↓` | Mover para baixo |
| `A` / `←` | Mover para esquerda |
| `D` / `→` | Mover para direita |
| `ENTER` | Reiniciar após game over |
| `ESC` | Sair |

---

## Arquitetura

### Sequência de boot
```
1. BIOS POST
2. BIOS lê setor 0 do disco → carrega em 0x0000:0x7C00
3. boot.asm executa:
     a. Configura registradores de segmento
     b. INT 13h AH=02h: lê 15 setores a partir do setor 2
        → carrega kernel em 0x1000:0x0000 (endereço físico 0x10000)
     c. FAR JMP para 0x1000:0x0000
4. kernel.asm assume controle (sem DOS, sem BIOS além de INT 1Ah e 10h)
```

### Layout de memória em tempo de execução
```
0x00000 - 0x003FF  IVT (Interrupt Vector Table) — 256 vetores × 4 bytes
0x00400 - 0x004FF  BDA (BIOS Data Area)
0x07C00 - 0x07DFF  Boot sector (512 bytes, ainda em memória mas inativo)
0x10000 - 0x11FFF  Kernel (código + dados) — carregado pelo bootloader
0xB8000 - 0xBFFFF  VRAM de texto VGA — escrita direta
```

### Interrupts instalados
O kernel substitui duas entradas da IVT (Interrupt Vector Table em 0x0000:0x0000):

| Interrupt | IRQ | Frequência | O que faz |
|-----------|-----|------------|-----------|
| INT 8h | IRQ0 (PIT timer) | 18.2 Hz | Avança a cobra a cada N ticks |
| INT 9h | IRQ1 (teclado) | por tecla | Lê scancode da porta 0x60 |

Os vetores originais são salvos antes e restaurados ao sair.

### Vídeo (modo texto 80×25)
- Segmento `0xB800`, cada célula = 2 bytes: `[char_CP437][atributo]`
- Atributo: bits 7-4 = cor de fundo, bits 3-0 = cor de frente
- `put_char`: calcula `offset = (linha×80 + coluna) × 2` e usa `STOSW`

### Ring buffer da cobra
```
snake_x[256] e snake_y[256]  — posições (coluna, linha) de cada segmento
head_idx  — índice da cabeça (byte → wrap automático em 256)
tail_idx  — índice da cauda
s_len     — comprimento atual
```
Como os índices são bytes de 8 bits, o overflow natural faz o wrap em 256
sem nenhuma instrução de módulo — a cobra "gira" no buffer automaticamente.

### Detecção de colisão
- **Parede**: comparar nova posição com PX1/PX2/PY1/PY2
- **Corpo**: iterar de `tail_idx` a `head_idx-1` comparando com nova posição
- **Comida**: comparar nova posição com `food_x`/`food_y`

### Gerador pseudoaleatório (LCG)
```
state = state × 25173 + 13849  (módulo 65536 pelo overflow natural de 16 bits)
```
Semeado com o contador de ticks do BIOS (INT 1Ah) no boot, então cada
jogo gera uma sequência diferente de posições para a comida.

---

## Estrutura do projeto
```
os_snake/
├── src/
│   ├── boot.asm     — Bootloader MBR de 512 bytes
│   └── kernel.asm   — Kernel + jogo Snake
├── Makefile
└── README.md
```

---

## O que aprender estudando este código

| Tópico | Onde ver |
|--------|----------|
| Programação de interrupções (PIC, EOI) | `timer_isr`, `kbd_isr` |
| Leitura direta de porta de hardware | `in al, 0x60` no `kbd_isr` |
| Escrita direta no framebuffer VGA | `put_char` |
| Ponteiros far e segmentação real mode | `setup_interrupts`, IVT em 0x0000 |
| Aritmética de ponto fixo / sem biblioteca | toda a lógica do jogo |
| Ring buffer com wrap automático | `snake_x[]`, `head_idx`/`tail_idx` |
| LCG pseudoaleatório sem FPU | `get_rng` |

---

## Curiosidades técnicas

- O arquivo `boot.asm` tem **exatamente 512 bytes** — limitação física do MBR.
  Os últimos 2 bytes são `0xAA55`, a "assinatura mágica" que o BIOS usa para
  confirmar que o setor é bootável.

- A instrução `HLT` no main loop faz a CPU entrar em modo de baixo consumo
  até o próximo interrupt — uma técnica usada em kernels reais para economizar
  energia quando não há nada a fazer.

- O wrap do ring buffer usa a característica dos registradores de 8 bits:
  `inc bl` em `0xFF` vai para `0x00` automaticamente, sem nenhum AND ou MOD.

- `STOSW` escreve o par `[char, attr]` em uma única instrução, avançando `DI`
  automaticamente — ideal para varrer o framebuffer rapidamente.
