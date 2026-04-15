# 🐍 Snake OS — Bare Metal x86 Game

Este é um jogo da cobra (Snake) desenvolvido inteiramente em **Assembly x86 (16-bit real mode)** que corre diretamente no hardware, sem a necessidade de um sistema operativo subjacente (Bare Metal). 

O projeto inclui um bootloader customizado (Stage 1) que prepara o ambiente e carrega o kernel do jogo na memória.

---

## 🛠️ Especificações Técnicas

* **Linguagem:** Assembly x86 (Sintaxe NASM).
* **Arquitetura:** x86 (Real Mode).
* **Bootloader:** MBR customizado (512 bytes) com assinatura `0xAA55`.
* **Vídeo:** Escrita direta no buffer de memória VGA (Segmento `0xB800`) em modo texto 80x25.
* **Interrupções:** Hook das interrupções de hardware `INT 08h` (Timer) e `INT 09h` (Teclado).
* **Lógica:** Gerador de números pseudo-aleatórios (LCG) e Ring Buffer para o corpo da cobra.

---

## 🎮 Como Executar

### Pré-requisitos
Certifica-te de que tens o `nasm` e o `qemu` instalados no teu sistema (Linux/WSL ou macOS).

```bash
# Ubuntu / Debian / WSL
sudo apt update && sudo apt install nasm qemu-system-x86 make
