# ==============================================================
#  Makefile — Snake OS
#  Produz uma imagem de disco bootável (os_snake.img)
# ==============================================================
#
#  Dependências:
#    nasm  — montador x86  (sudo apt install nasm)
#    qemu  — emulador      (sudo apt install qemu-system-x86)
#
#  Targets:
#    make          → compilar e gerar a imagem
#    make run      → rodar no QEMU
#    make run-dbg  → rodar no QEMU com monitor de debug
#    make clean    → remover arquivos gerados
# ==============================================================

NASM    = nasm
QEMU    = qemu-system-i386

BUILD   = build
SRC     = src

BOOT    = $(BUILD)/boot.bin
KERNEL  = $(BUILD)/kernel.bin
IMG     = os_snake.img

# Tamanho da imagem: 1.44MB (floppy padrão, compatível com QEMU)
IMG_SIZE = 1474560

.PHONY: all run run-dbg clean

all: $(IMG)

# ── Compilar bootloader (512 bytes exatos) ──────────────────
$(BOOT): $(SRC)/boot.asm | $(BUILD)
	$(NASM) -f bin $< -o $@
	@SIZE=$$(wc -c < $@); \
	if [ $$SIZE -ne 512 ]; then \
	  echo "ERRO: boot.bin tem $$SIZE bytes (deve ter 512)"; exit 1; \
	fi
	@echo "[OK] boot.bin = 512 bytes"

# ── Compilar kernel ─────────────────────────────────────────
$(KERNEL): $(SRC)/kernel.asm | $(BUILD)
	$(NASM) -f bin $< -o $@
	@SIZE=$$(wc -c < $@); \
	echo "[OK] kernel.bin = $$SIZE bytes ($$(( $$SIZE / 512 + 1 )) setores)"

# ── Montar imagem bootável ───────────────────────────────────
$(IMG): $(BOOT) $(KERNEL)
	# Criar imagem zerada de 1.44MB
	dd if=/dev/zero of=$(IMG) bs=512 count=2880 status=none
	# Gravar boot sector no setor 0
	dd if=$(BOOT) of=$(IMG) bs=512 count=1 conv=notrunc status=none
	# Gravar kernel a partir do setor 1 (offset 512)
	dd if=$(KERNEL) of=$(IMG) bs=512 seek=1 conv=notrunc status=none
	@echo "[OK] $(IMG) pronto — $$(du -h $(IMG) | cut -f1)"

# ── Criar diretório de build ─────────────────────────────────
$(BUILD):
	mkdir -p $(BUILD)

# ── Rodar no QEMU ───────────────────────────────────────────
run: $(IMG)
	$(QEMU) \
	  -drive format=raw,file=$(IMG),if=floppy \
	  -boot a \
	  -display sdl \
	  -no-reboot \
	  -name "Snake OS"

# ── Rodar com console de debug (Ctrl+Alt+2 no QEMU) ─────────
run-dbg: $(IMG)
	$(QEMU) \
	  -drive format=raw,file=$(IMG),if=floppy \
	  -boot a \
	  -display sdl \
	  -monitor stdio \
	  -no-reboot \
	  -name "Snake OS [DEBUG]"

# ── Rodar no DOSBox (alternativa, menos fiel ao hardware real)
run-dosbox: $(IMG)
	dosbox -c "boot $(IMG)"

# ── Limpar ──────────────────────────────────────────────────
clean:
	rm -rf $(BUILD) $(IMG)
	@echo "[OK] limpo"
