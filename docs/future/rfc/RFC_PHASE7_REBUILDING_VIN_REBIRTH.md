# RFC — Fase 7: Parts Lifecycle, Vehicle Compatibility & VIN Rebirth

> **Status:** CANONICAL SPECIFICATION / RFC  
> **Fase:** FASE 7 (v1.21) — Parts Lifecycle & Vehicle Rebuilding  
> **Dependências:** `P5.4 Persistent Physical Part`, `Part Registry` (v1.15)  
> **Escopo:** Motor de compatibilidade mecânica, recondicionamento na bancada, montagem veicular e renascimento civil de VIN

---

## 1. Visão Geral da Cadeia de Montagem

A Fase 7 completa o ciclo mecânico do jogo: o jogador pode coletar componentes roubados ou recuperados, recondicioná-los na bancada, montá-los em uma carcaça legalmente adquirida e emitir um novo registro civil veicular no `qbx_vehicles`.

```
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│ CADEIA DE VALIDAÇÃO DE MONTAGEM & LEGALIZAÇÃO                                              │
│                                                                                             │
│  [ Peças Roubadas ] ──▶ [ Recondicionamento Físico ] ──▶ [ Verificação de Compatibilidade ]│
│                                (Retífica / Limpeza)                 (Família / Chassi)      │
│                                                                             │               │
│  [ Carcaça de Leilão ] ─────────────────────────────────────────────────────▼               │
│  (Rolling Chassis)     ───────────────────────────────────────▶ [ Montagem Sequencial ]     │
│                                                                   (Transação Terminal)      │
│                                                                             │               │
│                                                                             ▼               │
│                                                                   [ VIN Rebirth Civil ]     │
│                                                                   (Emissão no qbx_vehicles) │
└─────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Motor de Compatibilidade Mecânica (P7.2)

Nem toda peça cabe em qualquer carro. O `vp_chopshop` gerencia a matriz canônica de compatibilidade:

```lua
Config.PartCompatibility = {
    EngineFamilies = {
        ['v8_heavy'] = {
            models = { 'sultanrs', 'banshee', 'buffalo4', 'dominator' },
            classes = { 4, 7 }, -- Muscle, Sports
            minChassisStrength = 80.0,
        },
        ['i4_compact'] = {
            models = { 'blista', 'panto', 'asbo', 'prairie' },
            classes = { 0, 1 }, -- Compacts, Sedans
            minChassisStrength = 40.0,
        },
        ['v6_suv'] = {
            models = { 'baller', 'bison', 'granger', 'cavalcade' },
            classes = { 2, 9 }, -- SUVs, Off-road
            minChassisStrength = 65.0,
        }
    }
}
```

- **Validação Server-Side:** A compatibilidade é avaliada estritamente no servidor ao tentar acoplar a peça na carcaça. O client não pode injetar metadados forçando um motor V8 em um compacto não suportado.

---

## 3. Processamento & Recondicionamento Físico (P7.3)

O recondicionamento na bancada (`chopshop_bench`) restaura a saúde da peça física:
- **Retífica de Bloco de Motor:** Consome `metalscrap` nobre, `steel` e ferramentas de solda para elevar `condition_pct` de 40% para 95%+.
- **Descaracterização Física (*Refurbishment*) $\neq$ Legalização:**
  - Uma peça recondicionada ganha o estado `legal_state = 'refurbished'`.
  - Ela funciona perfeitamente em termos mecânicos, mas seu histórico de procedência ainda aponta para um número de série original, a menos que passe pelo processo de raspagem/forja ou legalização civil.

---

## 4. Montagem Sequencial Completa (P7.6)

A montagem exige uma carcaça base documentada (**Rolling Chassis / Salvage Title** — `P7.5`) em um elevador de oficina:

1. **Checklist de Componentes Obrigatórios:**
   - 1x Bloco de Motor Compatível (`adv_engine`) com `condition_pct >= 70.0`.
   - 4x Rodas/Pneus de Classe Adequada (`chopshop_tyre`).
   - 4x Portas / Painéis Estruturais (`door_dside_f`, `door_pside_f`, `bonnet`, `boot`).
   - 1x Sistema de Exaustão / Catalisador (`catalytic_converter`).
2. **Invariante de Destino Terminal (Anti-Dupe):**
   - Ao confirmar a montagem, todas as peças do inventário/mundo são **destruídas terminalmente** na tabela `vp_chop_physical_parts`.
   - É matematicamente impossível vender a peça para o Broker e instalar a mesma peça no carro simultaneamente.

---

## 5. Renascimento de VIN & Registro Civil (P7.7)

Após a montagem física ser homologada:

1. O `vp_chopshop` gera um novo VIN civil oficial e uma placa limpa.
2. Registra o veículo diretamente na tabela do framework (`qbx_vehicles` / `player_vehicles`) associado ao `citizenid` do proprietário.
3. O veículo montado nasce como uma entidade 100% legalizada no mundo, com histórico de montagem arquivado para auditoria policial.
