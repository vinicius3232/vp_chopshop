-- =============================================================
-- vp_chopshop — migrate_v1.6.0.sql
-- Migração para servidores existentes (v1.5.x → v1.6.0).
-- Seguro de rodar múltiplas vezes (MODIFY COLUMN é idempotente se já correto).
--
-- O que muda:
--   VARCHAR(50) → VARCHAR(60) em colunas de identifier/placed_by em todas as tabelas.
--   Motivo: license2: identifiers têm até 49 chars; margem mínima com 50.
-- =============================================================

ALTER TABLE `vp_chopshop_benches`
    MODIFY COLUMN `placed_by` VARCHAR(60) DEFAULT NULL COMMENT 'license:... do jogador';

ALTER TABLE `vp_chopshop_welders`
    MODIFY COLUMN `placed_by` VARCHAR(60) DEFAULT NULL;

ALTER TABLE `vp_chop_vin_scratched`
    MODIFY COLUMN `scratched_by` VARCHAR(60) DEFAULT NULL;

ALTER TABLE `vp_chop_fence_trust`
    MODIFY COLUMN `identifier` VARCHAR(60) NOT NULL;

ALTER TABLE `vp_chop_fence_orders`
    MODIFY COLUMN `for_identifier` VARCHAR(60) NOT NULL;

ALTER TABLE `vp_chop_progression`
    MODIFY COLUMN `identifier` VARCHAR(60) NOT NULL;

-- Purga inicial de ordens cumpridas antigas (opcional, mas recomendada).
-- Remove ordens fulfilled há mais de 7 dias.
DELETE FROM `vp_chop_fence_orders`
WHERE `fulfilled_at` IS NOT NULL
  AND `fulfilled_at` < DATE_SUB(NOW(), INTERVAL 7 DAY);
