# vp_chopshop — Gameplay

> **Atualização pendente.** Este documento descreve o gameplay como era em **v1.6.7**. O fluxo
> para o jogador (macaco → desmontar peça por peça → vender ao fence) continua igual, mas a partir
> de `v1.16-dev` a definição de cada peça (ferramenta, dependências, gates, recompensa) passou a
> vir do **Part Registry** (`shared/registry/parts.lua`), não de fases hardcoded. Regras
> server-authoritative canônicas: [`../AGENTS.md`](../AGENTS.md) e `docs/audit/`. Rework completo
> deste doc está agendado para o release da v1.16.

---

## Visão Geral

Sistema de desmanche ilegal, peça por peça. O jogador obtém um veículo, usa o macaco hidráulico
para levantá-lo e desmonta cada peça com a ferramenta exigida. Os materiais e peças resultantes
são vendidos a um NPC fence rotativo que exige confiança acumulada. *(A organização em "4 fases
progressivas" descrita abaixo é o modelo pré-Registry; ver nota no topo.)*

---

## Itens Necessários

| Item | Função |
|---|---|
| `chopshop_jackstand` | Levanta o veículo — obrigatório para tudo |
| `chopshop_bench` | Bancada de trabalho — necessária para crafting |
| `chopshop_welder` | Soldadora — deve estar a ≤8m da bancada para usar receitas |
| `metal_saw` (ou `saw_pro` / `mechanic_drill`) | Ferramenta de desmanche — obrigatória para as fases 2 e 3 |
| `screwdriver` | Chave de fenda — obrigatória para a fase 3 (motor) |

> O veículo também precisa de **chaves** (ESX). Configure seu sistema em `Config.VehicleKeys` ou desative em `Config.RequireVehicleKeys`.

---

## Ferramentas de Desmanche

Cada ferramenta tem durabilidade e influencia a velocidade e o risco de despacho policial:

| Item | Usos | Despacho | Velocidade |
|---|---|---|---|
| `saw_cheap` | 2 | 100% | ×1.4 (mais lento) |
| `saw_pro` | 6 | 25% | ×1.0 (normal) |
| `mechanic_drill` | 10 | 0% | ×0.7 (mais rápido) |

Quando a ferramenta se esgota, o jogador recebe a notificação **"Sua serra quebrou de tanto uso!"** e precisa de outra para continuar.

---

## Fluxo Principal

```
1. Usar item chopshop_jackstand perto do carro
        ↓
   Animação de colocação dos macacos (8s)
   Carro sobe 18cm — trava no ar
        ↓
2. Targets de ox_target aparecem em cada peça
        ↓
3. Desmontar peças (Fases 2 → 3 → 4)
        ↓
4. Craftear materiais na bancada (opcional)
        ↓
5. Vender ao fence NPC
```

---

## Fase 2 — Desmanche Estrutural

**Requer:** `metal_saw` (ou equivalente) + veículo levantado no macaco

Targets aparecem em cada peça estrutural do carro:

| Peça | Recompensa | Duração |
|---|---|---|
| Capô | `car_parts ×1` | 6s |
| Porta-malas | `car_parts ×1` | 6s |
| Porta dianteira esq. | `car_parts ×1` | 6s |
| Porta dianteira dir. | `car_parts ×1` | 6s |
| Porta traseira esq. | `car_parts ×1` | 6s |
| Porta traseira dir. | `car_parts ×1` | 6s |

> **Máximo:** 6× `car_parts` nesta fase.

**Alarme:** ao remover a primeira peça, há chance de o alarme do veículo disparar (varia por classe — Super=80%, Motos=10%). O jogador tem **30 segundos** para desarmá-lo com um `screwdriver` + skill check. Se não desarmar, a polícia é chamada via dispatch.

---

## Fase 3 — Motor

**Requer:** capô removido (Fase 2) + `screwdriver` no inventário

- Target **"Remover motor"** aparece após o capô ser desmontado
- Duração: 8s com animação de chave de impacto
- Recompensa: **`car_parts ×5`** de uma vez

---

## Fase 4 — Carcaça

**Requer:** motor removido (Fase 3) + `chopshop_welder` posicionada a ≤8m do veículo

- Target **"Cortar carcaça"** aparece após o motor ser removido
- Duração: 10s com animação de serra
- Recompensas (com chance):

| Item | Quantidade | Chance |
|---|---|---|
| `metalscrap` | 8 | 100% |
| `plastic` | 5 | 80% |
| `glass` | 2 | 70% |
| `rubber` | 3 | 60% |

---

## Pneus — Sistema Paralelo

O roubo de pneus é **independente** das fases de desmanche. Pode ser feito em qualquer carro na rua.

**Fluxo:**
1. Usar `chopshop_jackstand` em qualquer carro estacionado
2. Minigame por pneu: 4 parafusos (bolt minigame 3D ou lib.skillCheck como fallback)
3. Pneu vai para o inventário como `chopshop_tyre`
4. Guardar pneus na caçamba de uma **pickup truck** (máx. 4)
5. Levar ao NPC comprador → **$400 por pneu**

**Trucks aceitas:** bison, sandking, rebel, kamacho, crusader, rancherxl e outras.

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
