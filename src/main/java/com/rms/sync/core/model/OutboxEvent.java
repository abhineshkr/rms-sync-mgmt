package com.rms.sync.core.model;

import java.time.Instant;
import java.util.Map;
import java.util.UUID;

/**
 * =====================================================================
 * OutboxEvent
 * =====================================================================
 *
 * PURPOSE ------- Represents a **logical outbox record** used to reliably
 * publish domain events to JetStream using the **Outbox Pattern**.
 *
 * This model is: - Transport-neutral (no JetStream classes) -
 * Persistence-friendly (maps 1:1 to DB schema) - Immutable (safe for retries
 * and replays)
 *
 * WHY THIS EXISTS --------------- Direct publishing to JetStream inside a DB
 * transaction is unsafe.
 *
 * Failure scenarios: - DB commit succeeds, publish fails → data loss - Publish
 * succeeds, DB commit fails → phantom event
 *
 * The outbox pattern guarantees: - Atomic persistence of intent - At-least-once
 * delivery - Replay on crash or restart
 *
 * LIFECYCLE --------- 1. Business transaction commits 2. OutboxEvent is
 * inserted with status = NEW 3. Publisher reads pending events 4. Event is
 * published to JetStream 5. Status transitions to PUBLISHED or FAILED
 *
 * DEDUPLICATION ------------- The {@link #id} is used as: - Database primary
 * key - JetStream Msg-Id
 *
 * This enables JetStream-side de-duplication even during retries or restarts.
 *
 * IMMUTABILITY ------------ This is a Java record: - No setters - No partial
 * mutation - Safe to cache, retry, and reprocess
 */
public record OutboxEvent(

		/**
		 * Unique identifier of the outbox record.
		 *
		 * GUARANTEES ---------- - Globally unique - Stable across retries - Used as 
		 * JetStream Msg-Id
		 */
		UUID id,

		/**
		 * Canonical subject to which this event will be published.
		 *
		 * FORMAT ------ Must conform to the canonical subject model defined in:
		 * com.rms.sync.core.subject.SyncSubject
		 *
		 * IMPORTANT --------- This value MUST be finalized at creation time. Publishers
		 * MUST NOT rewrite subjects in-flight.
		 */
		String subject,

		/**
		 * Serialized event payload.
		 *
		 * FORMAT ------ Typically JSON (JSONB in Postgres), but remains
		 * transport-neutral.
		 *
		 * DESIGN CHOICE ------------- Stored as String to: - Avoid coupling to
		 * serialization libraries - Allow schema evolution without recompilation
		 */
		String payloadJson,

		/**
		 * Optional message headers.
		 *
		 * USAGE ----- May include: - Correlation IDs - Trace IDs - Tenant identifiers -
		 * Schema version
		 *
		 * NOTE ---- Headers are NOT used for routing. Routing is subject-driven only.
		 */
		Map<String, Object> headers,

		/**
		 * Current lifecycle status of this outbox event.
		 *
		 * EXPECTED STATES --------------- - NEW → ready for publish - PUBLISHED →
		 * successfully sent to JetStream - FAILED → exceeded retry policy
		 *
		 * State transitions MUST be monotonic.
		 */
		OutboxStatus status,

		/**
		 * Number of publish attempts made so far.
		 *
		 * USED FOR -------- - Retry backoff - Circuit-breaking - Dead-letter escalation
		 */
		int retryCount,

		/**
		 * Timestamp when the outbox record was created.
		 *
		 * SOURCE ------ Set at DB insert time. Used for: - Ordering - Lag measurement -
		 * Operational diagnostics
		 */
		Instant createdAt,

		/**
		 * Timestamp when the event was successfully published.
		 *
		 * NULLABLE -------- - null → not yet published or failed - non-null → publish
		 * confirmed
		 *
		 * IMPORTANT --------- This timestamp reflects **publish success**, not consumer
		 * acknowledgment.
		 */
		Instant publishedAt) {
}
