-- Server-side refresh-token store for FleetBack auth (Remember-me).
-- Shared across F01/F02 + survives restart (an in-memory map would fail behind
-- the load balancer). Written/read by FleetBack AuthController (/auth/login issues,
-- /auth/refresh validates + rotates). Owned by the `telematics` role.
CREATE TABLE IF NOT EXISTS telematics.auth_refresh_tokens (
    token       text PRIMARY KEY,          -- opaque "rt-<uuid><uuid>"
    user_id     bigint NOT NULL,           -- telematics.users.id
    expires_at  timestamptz NOT NULL,      -- 30d if rememberMe, else the access-token TTL
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS auth_refresh_tokens_expires_idx ON telematics.auth_refresh_tokens (expires_at);
ALTER TABLE telematics.auth_refresh_tokens OWNER TO telematics;

-- Optional periodic cleanup of expired rows (rotation already deletes on use):
--   DELETE FROM telematics.auth_refresh_tokens WHERE expires_at < now();
