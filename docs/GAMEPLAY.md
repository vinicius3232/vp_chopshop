# vp_chopshop — Gameplay (v1.16)

---

## Visão Geral

Sistema de desmanche ilegal server-authoritative em **4 fases físicas e interativas**. O jogador obtém um veículo, usa o macaco hidráulico para levantá-lo e desmonta peça por peça através de minigames físicos contextuais com câmeras dinâmicas e ferramentas específicas. Os materiais e peças resultantes possuem rastreabilidade serial e são negociados com a rede de receptadores (fence).

---

## Itens e Estações de Trabalho

| Item | Tipo | Função |
|---|---|---|
| `chopshop_jackstand` | Estação | Levanta o veículo — obrigatório para iniciar o desmanche |
| `chopshop_bench` | Estação | Bancada de trabalho para processamento de peças e forja de placas/séries |
| `chopshop_welder` | Estação | Máquina de solda física — necessária próxima ao carro para cortar a carcaça e na bancada para forja |
| `saw_cheap` | Ferramenta | Serra amadora (2 usos, corte rápido, 100% de ruído/despacho) |
| `saw_pro` | Ferramenta | Serra profissional (6 usos, 25% de despacho) para portas, capô e porta-malas |
| `mechanic_drill` | Ferramenta | Parafusadeira mecânica de alto torque (10 usos) para desacoplamento do motor |
| `screwdriver` | Ferramenta | Chave de fenda para desarme de alarmes e remoção de placas |
| `parts_scanner` | Forense | Scanner policial para leitura de séries de peças em suspeitos |
| `forensic_kit` | Forense | Kit pericial avançado — revela números de série forjados |
| `gloves` | Crime | Luvas que evitam deixar impressões digitais na cena do crime |

---

## Ferramentas de Desmanche (Mecânica e Durabilidade)

Cada ferramenta tem durabilidade autoritativa e influencia a velocidade de interação:

| Ferramenta | Usos | Despacho Policial | Multiplicador de Velocidade | Prop Visual |
|---|---|---|---|---|
| `saw_cheap` | 2 | 100% | ×1.4 (mais lento) | `prop_tool_consaw` |
| `saw_pro` | 6 | 25% | ×1.0 (padrão) | `prop_tool_consaw` |
| `mechanic_drill` | 10 | 0% (silenciosa) | ×0.7 (alta rotação) | `prop_tool_drill` |

---

## Fluxo Principal de Desmanche (v1.16)

```
1. Usar item chopshop_jackstand perto do carro
        ↓
   Animação de colocação dos macacos (8s)
   Carro sobe e trava no ar com física server-side
        ↓
2. Targets contextuais aparecem em cada peça via ox_target
        ↓
3. Desmanche Físico Interativo:
   • Pneus (5 parafusos - Rotação física 360°)
   • Painéis (3 pontos de corte - Dobradiças e fechadura)
   • Motor (4 calços de chassi - Parafusadeira mecânica)
   • Carcaça (5 linhas estruturais - Traçado com maçarico de solda)
        ↓
4. Processamento / Adulteração na bancada (opcional)
        ↓
5. Venda de peças seriadas e contratos de entrega terminal
```

---

## 1. Roubo de Pneus (Wheel Minigame)

**Requer:** Veículo levantado no macaco.

- **Gameplay:** A câmera aproxima na roda selecionada (`wheel_lf`, `wheel_rf`, `wheel_lr`, `wheel_rr`). A NUI exibe os **5 parafusos da roda**.
- **Interação:** O jogador clica em cada parafuso e gira o mouse em arco (rotação contínua) para soltá-lo.
- **Conclusão:** Somente após os 5 parafusos soltos (5/5), o ped executa a puxada física da roda.
- **Recompensa:** Gera 1x `TyreEntitlement` para carregar o pneu (`chopshop_tyre`).

---

## 2. Painéis da Carroceria (Body Panels)

**Requer:** `saw_cheap` ou `saw_pro` no inventário + veículo no macaco.

- **Peças:** Portas dianteiras, portas traseiras, capô (`bonnet`) e porta-malas (`boot`).
- **Gameplay:** A câmera enquadra a peça em ângulo lateral/frontal. O ped saca a serra elétrica e surgem **3 pontos de corte** (dobradiça superior, dobradiça inferior e fechadura).
- **Interação:** O jogador clica e segura sobre cada ponto até romper o metal.
- **Recompensa:** `car_parts ×1` com número de série comitado no servidor.

---

## 3. Motor (Engine Removal)

**Requer:** Capô já removido (`hood_first`) + `mechanic_drill` no inventário.

- **Gameplay:** Câmera mergulha no cofre do motor. O ped empunha a parafusadeira mecânica `prop_tool_drill`.
- **Interação:** Surgem **4 calços de fixação** nos cantos do cofre. O jogador aciona a parafusadeira em cada ponto com feedback elétrico de alto torque.
- **Recompensa:** `car_parts ×5` seriadas e motor entra em estado `REMOVED`.

---

## 4. Corte Estrutural da Carcaça (Carcass Structural Trace)

**Requer:** Motor removido (`engine_first`) + `chopshop_welder` física posicionada no chão a $\le 8.0\text{m}$ do veículo (sem necessidade de serra).

- **Gameplay:** Câmera 3/4 isométrica elevada. O ped saca o maçarico de corte `prop_weld_torch` com animação contínua de soldagem.
- **Interação (Primitive `trace`):** A NUI projeta 5 linhas estruturais do chassi (Travessa Dianteira, Colunas Laterais, Túnel do Assoalho e Longarinas Traseiras). O jogador clica no início da linha e conduz o maçarico continuamente ao longo do traçado com faíscas incandescentes.
- **Anti-Cheat:** Sistema anti-salto com velocidade física limitada e validação de retomada.
- **Conclusão:** 5/5 seções concluídas liberam o chassi para o descarte/entrega terminal e entrega dos materiais recicláveis.

---

## Descarte do Veículo

Após remover no mínimo **4 peças**, o target **"Descartar veículo"** aparece.

- O veículo é destruído
- Jogador recebe **$1.500 base** em cash
- Alguns modelos têm payout fixo configurado em `Config.Discard.PayoutByModel`

---

## Bancada — Crafting de Materiais

Com a `chopshop_bench` e a `chopshop_welder` posicionadas (soldadora a ≤8m da bancada), o jogador acessa o menu de receitas via ox_target:

| Receita | Inputs | Output | Tempo |
|---|---|---|---|
| Compactar sucata | `metalscrap ×25` | `steel ×3` | 8s |
| Separar cobre | `metalscrap ×15` + `plastic ×10` | `copper ×8` | 10s |
| Montar kit de reparo *(QS)* | `car_parts ×5` + `metalscrap ×10` | `repairkit ×1` | 12s |
| Trançar corda *(QS)* | `rubber ×8` + `plastic ×5` | `rope ×1` | 8s |

> As receitas com *(QS)* integram com o `qs-mechanic-creator` — os itens `repairkit` e `rope` são usados nas oficinas legítimas.

---

## Fence NPC — Venda de Materiais

O fence aparece em **4 locais rotativos** que mudam a cada **45 minutos**:
- Sandy Shores, LSIA, La Mesa, Paleto Bay

Para ter acesso ao fence, o jogador precisa do item `fence_referral` (drop de NPCs de emboscada com 15% de chance) para se apresentar pela primeira vez.

### Sistema de Confiança (Trust 0 → 4)

| Nível | Nome | XP necessário | Benefícios |
|---|---|---|---|
| 0 | — | — | Precisa de `fence_referral` |
| 1 | Conhecido | 100 XP | Vender materiais e pneus |
| 2 | Confiável | 300 XP | Comprar bancada no fence |
| 3 | Parceiro | 600 XP | Receber encomendas com bônus (×1.35–1.5) |
| 4 | Sócio | 1.000 XP | Entregar carros inteiros por $8.000+ |

XP é ganho por cada entrega concluída (+20) e encomendas no prazo (+80). Confiança decai após **7 dias** sem aparecer.

### Preços Base por Item

| Item | Preço base |
|---|---|
| `metalscrap` | $80 |
| `steel` | $100 |
| `plastic` | $70 |
| `glass` | $90 |
| `rubber` | $120 |
| `aluminum` | $130 |
| `copper` | $150 |
| `car_parts` | $400 |
| `chopshop_tyre` | $400 |

**Multiplicadores aplicados sobre o preço base:**
- Trust level do jogador
- Tier de progressão (Tier 4 = +10%)
- Heat do veículo entregue (penalidade se quente)
- Bônus noturno (×1.3 entre 21h–6h)

### Encomendas (Trust ≥ 3)

O fence gera contratos com lista de itens, prazo e multiplicador de preço. Exemplos:
- `metalscrap ×20` + `copper ×8` + `rubber ×5` → bônus ×1.4 / prazo 6h
- `car_parts ×5` + `steel ×15` → bônus ×1.5 / prazo 8h

---

## Heat System

Cada veículo tem um nível de "calor" (0–100) baseado em recência do roubo.

| Nível | Efeito no fence |
|---|---|
| Frio | Preço normal |
| Morno | Aviso ao jogador, pequena penalidade |
| Quente | Fence paga menos |
| Queimando | Fence recusa o veículo |

**VIN Scratch** (desbloqueado no Tier 3): remove o calor do veículo.
- Se o veículo estiver acima de 75 de heat: 40% de chance de falha.

---

## Progressão (Tier 1 → 4)

XP ganho por cada peça desmontada com sucesso.

| Tier | Nome | XP total | Velocidade | Materiais | Fence | Desbloqueios |
|---|---|---|---|---|---|---|
| 1 | Novato | 0 | ×1.0 | ×1.0 | ×1.0 | — |
| 2 | Mecânico | 500 | ×1.10 | ×1.05 | ×1.0 | — |
| 3 | Especialista | 2.000 | ×1.20 | ×1.10 | ×1.0 | VIN scratch + encomendas |
| 4 | Mestre | 5.000 | ×1.30 | ×1.15 | ×1.10 | Entrega de carro inteiro |

---

## Sistemas Opcionais (desligados por padrão)

| Sistema | Config | Estado |
|---|---|---|
| Alarme veicular | `Config.Alarm.Enable` | ✅ Ativo |
| Emboscada aleatória | `Config.Ambush.RandomOnDismantle` | ❌ Desligado |
| NPC fixo (loja/missão) | `Config.NPC.Enable` | ❌ Desligado |
| Missões de roubo de pneus | `Config.TyreMission.Enable` | ❌ Desligado |
| Bônus policial no descarte | `Config.Discard.CopsBonus.Enable` | ❌ Desligado |
| Log Discord | `Config.Discord.Webhook` | ❌ Sem webhook |

---

## Resumo do Fluxo Completo

```
Obter veículo + chaves
    │
    ▼
Usar chopshop_jackstand → carro sobe
    │
    ├─ Fase 2: desmontar capô / portas / porta-malas (metal_saw) → car_parts ×1 cada
    │
    ├─ Fase 3: remover motor (screwdriver, capô já removido) → car_parts ×5
    │
    └─ Fase 4: cortar carcaça (welder a ≤8m, motor já removido) → recicláveis
    │
    ├─ Descarte do veículo (≥4 peças removidas) → $1.500 cash
    │
    ├─ Bancada + Welder: converter materiais → steel / copper / repairkit / rope
    │
    └─ Fence NPC: vender car_parts + materiais → cash
               (preço sobe com trust + tier + noite)
```
