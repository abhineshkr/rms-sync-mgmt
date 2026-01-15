-- Outbox table schema (LOCKED by SYNC_MGMT spec)
CREATE TABLE IF NOT EXISTS sync_outbox_event (
  id UUID PRIMARY KEY,
  subject TEXT NOT NULL,
  payload JSONB NOT NULL,
  headers JSONB,
  status VARCHAR(20) NOT NULL,
  retry_count INT DEFAULT 0,
  created_at TIMESTAMP NOT NULL,
  published_at TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_sync_outbox_status_created
  ON sync_outbox_event(status, created_at);

CREATE INDEX IF NOT EXISTS idx_sync_outbox_subject
  ON sync_outbox_event(subject);
