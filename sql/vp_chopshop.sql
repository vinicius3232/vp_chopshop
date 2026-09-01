-- =============================================================
-- vp_chopshop — install.sql  (v1.6.4)
-- Executar UMA vez na base do servidor (fresh install).
--   HeidiSQL / phpMyAdmin: importar este arquivo
--   CLI: mysql -u USER -p DBNAME < vp_chopshop.sql
--
-- Tabelas:
--   vp_chopshop_benches      — bancadas de desmanche colocadas no mundo
--   vp_chopshop_welders      — soldadoras colocadas no mundo
--   vp_chop_vin_scratched    — registros de VIN adulterado (heat system)
--   vp_chop_fence_trust      — economia de confiança com o receptador
--   vp_chop_fence_orders     — pedidos ativos do receptador (expirados purgados a cada 6h)
--   vp_chop_progression      — XP e tier do jogador
--   vp_chop_fake_plates      — [FASE2 placas] mapa placa FALSA → placa REAL (disfarce MDT)
--   vp_chop_legit_serials    — [SERIAL] registro de números de série LEGÍTIMOS (perícia)
-- =============================================================

-- ─── Bancadas de desmanche ───────────────────────────────────────────────────
-- position: JSON compacto de vector3 (~40 chars); VARCHAR(100) mantém inline no
--           B-tree (evita leitura off-page do InnoDB gerada por TEXT).
-- heading:  armazenado como inteiro (math.floor); 0-359 cabe em SMALLINT UNSIGNED.
-- placed_by: VARCHAR(60) cobre license2: (49 chars) com margem.

CREATE TABLE IF NOT EXISTS `vp_chopshop_benches` (
  `id`        INT UNSIGNED      NOT NULL AUTO_INCREMENT,
  `position`  VARCHAR(100)      NOT NULL COMMENT 'JSON {x,y,z}',
  `heading`   SMALLINT UNSIGNED NOT NULL DEFAULT 0,
  `placed_by` VARCHAR(60)       DEFAULT NULL COMMENT 'license:... do jogador',
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ─── Soldadoras ──────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS `vp_chopshop_welders` (
  `id`        INT UNSIGNED      NOT NULL AUTO_INCREMENT,
  `position`  VARCHAR(100)      NOT NULL COMMENT 'JSON {x,y,z}',
  `heading`   SMALLINT UNSIGNED NOT NULL DEFAULT 0,
  `placed_by` VARCHAR(60)       DEFAULT NULL COMMENT 'license:... do jogador',
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ─── VINs adulterados (heat system) ──────────────────────────────────────────
-- Consultada apenas por plate (PK) — sem índices adicionais necessários.
-- Verificação de existência usa SELECT EXISTS (mais eficiente que COUNT(*)).

CREATE TABLE IF NOT EXISTS `vp_chop_vin_scratched` (
  `plate`        VARCHAR(12) NOT NULL COMMENT 'placa GTA V (max 8 chars, 12 por segurança)',
  `scratched_by` VARCHAR(60) DEFAULT NULL,
  `scratched_at` TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`plate`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ─── Trust com o receptador ──────────────────────────────────────────────────
-- trust_level: 0-4  → TINYINT UNSIGNED (1 byte)
-- trust_xp:    0-~10 000 → MEDIUMINT UNSIGNED (3 bytes, máx 16M)

CREATE TABLE IF NOT EXISTS `vp_chop_fence_trust` (
  `identifier`  VARCHAR(60)        NOT NULL,
  `trust_level` TINYINT UNSIGNED   NOT NULL DEFAULT 0,
  `trust_xp`    MEDIUMINT UNSIGNED NOT NULL DEFAULT 0,
  `last_seen`   TIMESTAMP          NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`identifier`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ─── Pedidos do receptador ───────────────────────────────────────────────────
-- order_data: JSON com lista de itens + deadline; TEXT (max 65 KB) é suficiente.
-- Índice composto cobre os dois padrões de acesso:
--   SELECT ... WHERE for_identifier=? AND fulfilled_at IS NULL ORDER BY created_at DESC
--   UPDATE ... WHERE id=? AND for_identifier=? AND fulfilled_at IS NULL  (usa PK primeiro)
-- Ordens fulfilled há >7 dias são purgadas automaticamente a cada 6h (server/fence.lua).

CREATE TABLE IF NOT EXISTS `vp_chop_fence_orders` (
  `id`             INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `for_identifier` VARCHAR(60)  NOT NULL,
  `order_data`     TEXT         NOT NULL,
  `created_at`     TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `fulfilled_at`   TIMESTAMP    NULL     DEFAULT NULL,
  PRIMARY KEY (`id`),
  INDEX `idx_orders_active` (`for_identifier`, `fulfilled_at`, `created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ─── Progressão do jogador ───────────────────────────────────────────────────
-- tier:        1-4  → TINYINT UNSIGNED
-- xp / chops:  0-~50 000 realistas → MEDIUMINT UNSIGNED (3 bytes cada)

CREATE TABLE IF NOT EXISTS `vp_chop_progression` (
  `identifier`        VARCHAR(60)        NOT NULL,
  `tier`              TINYINT UNSIGNED   NOT NULL DEFAULT 1,
  `xp`                MEDIUMINT UNSIGNED NOT NULL DEFAULT 0,
  `total_chops`       MEDIUMINT UNSIGNED NOT NULL DEFAULT 0,
  `last_car_delivery` TIMESTAMP          NULL     DEFAULT NULL,
  `updated_at`        TIMESTAMP          NOT NULL DEFAULT CURRENT_TIMESTAMP
                                                  ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`identifier`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ─── [FASE2 placas] Mapa placa FALSA → placa REAL ─────────────────────────────
-- Disfarce de consulta MDT: o veículo passa a EXIBIR `fake_plate`; o crime (heat,
-- VIN scratch, contagem de peças) continua seguindo a `real_plate` via resolver.
-- fake_plate é PK → garante que duas falsas iguais não coexistem (colisão rejeitada).
-- [F2 persist] real_plate é UNIQUE → cada placa REAL tem no MÁX 1 disfarce ativo
--   (evita linhas stale ao reaplicar uma falsa nova sobre uma real já disfarçada).
-- PERSISTÊNCIA TOTAL: a placa falsa dura até a POLÍCIA remover ou remoção manual.
--   Sobrevive a restart e é re-aplicada quando o veículo (owned) reaparece (server/plates.lua).

CREATE TABLE IF NOT EXISTS `vp_chop_fake_plates` (
  `fake_plate` VARCHAR(12) NOT NULL COMMENT 'placa exibida (falsa), max 8 chars',
  `real_plate` VARCHAR(12) NOT NULL COMMENT 'placa real do veiculo (alvo do crime)',
  `applied_by` VARCHAR(60) DEFAULT NULL COMMENT 'identifier de quem aplicou',
  `applied_at` TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`fake_plate`),
  UNIQUE KEY `uq_real_plate` (`real_plate`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ─── [SERIAL] Números de série LEGÍTIMOS de car_parts ─────────────────────────
-- Camada forense: SÓ entram aqui as séries de peças de procedência LEGAL (fonte legal /
-- vendedor). A perícia da polícia (forensic_kit) consulta "esta série consta como
-- legítima?". Uma série FORJADA pelo bandido NÃO é registrada aqui → passa no scan
-- normal como "Registrada" mas a perícia a flagra como FALSA (não consta).
--   serial:  PK, ≤16 chars (gerado em runtime; A-Z0-9).
--   source:  origem ('legal_supply', 'legal_vendor', etc.) — auditoria.

CREATE TABLE IF NOT EXISTS `vp_chop_legit_serials` (
  `serial`     VARCHAR(16) NOT NULL COMMENT 'numero de serie legitimo (A-Z0-9)',
  `source`     VARCHAR(40) DEFAULT NULL COMMENT 'origem da peca legal',
  `created_at` TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`serial`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ─── [v1.17 BROKER] Snapshot de Mercado Dinâmico (Dynamic Broker Market) ──────
-- commodity: PK, nome técnico ('catalytic_converter', 'adv_engine', 'tyre', etc.)
-- demand_index: índice de demanda atual (0.4000 a 1.3000, equilíbrio = 1.0000)
-- recent_volume: volume acumulado de unidades vendidas
-- last_recovery: timestamp da última atualização/recuperação temporal

CREATE TABLE IF NOT EXISTS `vp_chop_broker_market` (
  `commodity`     VARCHAR(64)          NOT NULL,
  `demand_index`  DECIMAL(5, 4)        NOT NULL DEFAULT 1.0000,
  `recent_volume` INT UNSIGNED         NOT NULL DEFAULT 0,
  `last_recovery` TIMESTAMP            NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`commodity`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- [F2 persist] MIGRAÇÃO de bases vindas da v1.9.0 (que usavam INDEX idx_fake_real não-único).
-- Rode APENAS se você já tinha a tabela antes desta versão. O db.lua faz isto automaticamente
-- no boot (idempotente); este bloco é o equivalente manual:
-- DELETE t1 FROM `vp_chop_fake_plates` t1
--   INNER JOIN `vp_chop_fake_plates` t2
--   ON t1.real_plate = t2.real_plate AND t1.applied_at < t2.applied_at;
-- ALTER TABLE `vp_chop_fake_plates` DROP INDEX `idx_fake_real`;
-- ALTER TABLE `vp_chop_fake_plates` ADD UNIQUE KEY `uq_real_plate` (`real_plate`);
