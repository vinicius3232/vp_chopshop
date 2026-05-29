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
