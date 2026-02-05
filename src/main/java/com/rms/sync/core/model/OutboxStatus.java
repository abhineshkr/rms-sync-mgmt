package com.rms.sync.core.model;

/**
 * =====================================================================
 * OutboxStatus
 * =====================================================================
 *
 * PURPOSE
 * -------
 * Represents the lifecycle state of an {@link OutboxEvent}
 * in the Outbox Pattern implementation.
 *
 * This enum defines **exactly what the publisher is allowed to do**
 * with a given outbox record at any point in time.
 *
 * WHY THIS IS IMPORTANT
 * ---------------------
 * Incorrect state handling can cause:
 *  - Message loss
 *  - Infinite retry loops
 *  - Duplicate publishing
 *
 * Therefore:
 *  - States are minimal
 *  - Transitions are explicit
 *  - Semantics are strict
 *
 * STATE MACHINE
 * -------------
 *
 *   PENDING  ──publish success──▶  PUBLISHED
 *      │
 *      └─retry exhausted / fatal error──▶  FAILED
 *
 * No other transitions are allowed.
 *
 * ENUM VALUES
 * -----------
 */
public enum OutboxStatus {

    /**
     * Event has been persisted to the outbox table
     * but has NOT yet been successfully published.
     *
     * CHARACTERISTICS
     * ---------------
     * - Eligible for publishing
     * - Safe to retry
     * - May be picked up by multiple publisher instances,
     *   relying on DB locking + JetStream deduplication
     */
    PENDING,

    /**
     * Event has been successfully published to JetStream.
     *
     * GUARANTEES
     * ----------
     * - JetStream accepted the message
     * - Msg-Id deduplication applied
     *
     * NOTE
     * ----
     * This does NOT imply that consumers have processed the message.
     */
    PUBLISHED,

    /**
     * Event could not be published after exhausting
     * the configured retry policy or encountering
     * a non-recoverable error.
     *
     * BEHAVIOR
     * --------
     * - Must NOT be retried automatically
     * - Requires operator intervention
     * - May be re-queued manually if needed
     *
     * COMMON CAUSES
     * -------------
     * - Invalid subject
     * - Serialization errors
     * - Permanent authorization failure
     */
    FAILED
}
