[VISUAL-01B] Assets fotorrealistas — minigame de ADULTERAR NÚMERO DE SÉRIE
========================================================================

O renderer (html/app.js -> buildSerialPanel) consome estes 2 arquivos.
Enquanto NÃO existirem, o painel usa a plaqueta desenhada em CSS (fallback
gracioso) e o minigame continua 100% funcional.

Arquivos esperados (nomes exatos, minúsculo):

  serial_plate.png    -- plaqueta de metal oxidado com 4 rebites (VAZIA).
                         É o FUNDO do painel; o número de série é renderizado
                         POR CIMA em <div class="serial-code">.
  serial_sander.png   -- almofada de lixa (grão vermelho/marrom). Segue o
                         cursor enquanto o jogador esfrega sobre a faixa.

Especificação:

  serial_plate.png
    - PNG (alpha opcional). Proporção ~2:1 (paisagem). ~1400x740 px.
    - plaqueta CENTRADA, com margem transparente/neutra em volta.
    - sem texto, sem número, sem UI. Só a chapa + rebites.

  serial_sander.png
    - PNG com alpha (fundo TRANSPARENTE). ~420x420 px.
    - a almofada de lixa vista de cima, leve rotação (~-15deg ok).
    - sem sombra dura recortada; sem fundo branco.

Comportamento em runtime:
  - serial_plate.png entra como background do .serial-part (classe
    .plate-photo-ok some com a textura CSS).
  - serial_sander.png aparece no mousedown de uma faixa, segue o cursor no
    mousemove enquanto o jogador esfrega, some no mouseup/conclusão.
  - o <div class="serial-code"> desgasta (blur + opacidade) conforme
    pt.progress das faixas GRAVAÇÃO/RESÍDUO — inalterado.

Fonte de referência: fotos enviadas (chapa riveted + almofada de lixa).
