-- Migration 2026-07-19: sync with mock schema drift (applied to BOTH schemas)
ALTER TABLE accounts       ADD COLUMN IF NOT EXISTS recovery_email text;
ALTER TABLE users          ADD COLUMN IF NOT EXISTS role text;
ALTER TABLE vehicles       ADD COLUMN IF NOT EXISTS modified_at timestamptz;
ALTER TABLE vehicles       ADD COLUMN IF NOT EXISTS modified_by_account_id integer;
ALTER TABLE saved_reports  ADD COLUMN IF NOT EXISTS snapshot jsonb;
