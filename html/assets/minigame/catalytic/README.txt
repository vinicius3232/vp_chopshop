[VISUAL-01] Assets fotorrealistas da fixação do escapamento — minigame do catalisador
======================================================================================

O renderer (html/app.js → buildExhaustBolt / updateExhaustBoltVisual) consome
EXATAMENTE estes 4 arquivos. Enquanto eles NÃO existirem, o minigame continua
100% funcional no visual genérico (círculo) — fallback gracioso via .xbolt-ready.

STATUS: os 4 arquivos JÁ estão instalados (256x256 RGBA, gerados a partir dos
recortes enviados pelo usuário em 2026-09-04; o 'hole' foi sintetizado da
arruela + furo central preto). Para trocar por versões melhores, basta
sobrescrever mantendo o nome, o tamanho quadrado e o fundo transparente.

Arquivos esperados (nomes exatos, minúsculo):

  exhaust_bolt_head.png    — cabeça sextavada do parafuso (vista de topo/leve 3/4)
  exhaust_bolt_thread.png  — corpo roscado do parafuso (revelado de cima p/ baixo)
  exhaust_washer.png       — arruela sob a cabeça
  exhaust_bolt_hole.png    — furo vazio na flange (estado 100%, parafuso removido)

Especificação de cada recorte:
  - PNG com canal alpha (fundo TRANSPARENTE)
  - quadrado, 256x256 px (recomendado; qualquer quadrado serve, o CSS escala p/ 96px)
  - SEM texto, SEM seta, SEM glow, SEM círculo de UI, SEM fundo cinza/marrom
  - todas as 4 imagens na MESMA escala e MESMA perspectiva
  - a "cabeça" e a "arruela" centradas no frame; o "corpo roscado" alinhado
    verticalmente com a cabeça (o topo da rosca encosta na base da cabeça)
  - visual automotivo oxidado/fotorrealista

Composição em runtime (z-order de baixo p/ cima):
  hole (oculto) → thread (clip-path revela) → washer → head (gira + sobe)

Progresso (pt.progress 0..100, dirigido pelo mousemove 'rotate' já existente):
  head:   translateY(-progress * 0.15 px) + rotate(pt.accumulatedDeg)
  washer: translateY(-progress * 0.04 px)
  thread: clip-path inset((100-progress)% 0 0 0) + opacity 0.15→1.0
  100%:   fly-out curto da cabeça → mostra exhaust_bolt_hole.png

Fonte de referência: sprite sheet gerada (parafusos/porcas/arruelas/flange
oxidados). Recortar SEM os elementos azuis (eram só marcação de referência).

──────────────────────────────────────────────────────────────────────────────
[VISUAL-02] Painel "catalisador na bancada" (profile bench_catalytic → panel='catalytic')

  catalytic_body.png    -- catalisador fechado, vista de cima (fundo do painel).
                           proporção ~16:10, ~1400x875, plaqueta centrada.
  catalytic_open.png     -- o mesmo catalisador ABERTO (colmeia/miolo visível).
                           mesmo enquadramento; trocado ao concluir.
  catalytic_wrench.png   -- chave/catraca, alpha, ~600x600. Segue o cursor
                           enquanto há porca pendente.
  catalytic_hammer.png   -- marreta, alpha, ~600x600. (legado)
  catalytic_torch.png    -- maçarico de corte, alpha, 720x720. Segue o cursor no
                           minigame de contorno (bench_catalytic). O BICO fica
                           em ~x10% / y68% da imagem = ponto do cursor (ajuste
                           em style.css .cat-torch transform). Sem o arquivo ->
                           fallback pro ponto incandescente.

Sem esses PNGs: o painel usa um cilindro desenhado em CSS (fallback) e o
minigame de contorno continua funcional (linha SVG + ponto do cursor).
