package com.rms.sync.core.publisher;

import com.rms.sync.core.model.OutboxEvent;
import reactor.core.publisher.Mono;

/**
 * =====================================================================
 * SyncPublisher
 * =====================================================================
 *
 * PURPOSE
 * -------
 * Defines the **transport-facing contract** for publishing outbox events
 * to the underlying messaging system.
 *
 * In SYNC_MGMT, the primary implementation targets **NATS JetStream**,
 * but this interface remains:
 *  - Transport-agnostic
 *  - Test-friendly
 *  - Replaceable (if needed)
 *
 * ROLE IN ARCHITECTURE
 * --------------------
 * This interface sits between:
 *
 *   [ Outbox Table ]
 *          │
 *          ▼
 *   [ SyncPublisher ]  ← YOU ARE HERE
 *          │
 *          ▼
 *   [ JetStream / Transport ]
 *
 * It deliberately knows NOTHING about:
 *  - Database transactions
 *  - Retry scheduling
 *  - Consumer acknowledgements
 *
 * Those responsibilities live elsewhere.
 *
 * REACTIVE CONTRACT
 * -----------------
 * Uses Reactor {@link Mono} to:
 *  - Support non-blocking IO
 *  - Integrate with R2DBC
 *  - Enable backpressure-aware pipelines
 *
 * A completed Mono indicates that the transport
 * has **accepted** the message.
 *
 * FAILURE SEMANTICS
 * -----------------
 * - Mono completes successfully:
 *     → message accepted by transport
 * - Mono errors:
 *     → message NOT guaranteed to be published
 *
 * IMPORTANT:
 * ----------
 * Success here means:
 *  - JetStream persisted the message
 *  - Deduplication applied (Msg-Id)
 *
 * It does NOT mean:
 *  - Consumers received it
 *  - Consumers acknowledged it
 *
 * IDENTITY & DEDUPLICATION
 * -----------------------
 * Implementations MUST:
 *  - Use {@link OutboxEvent#id()} as the transport-level message ID
 *  - Rely on transport deduplication for idempotency
 *
 * SUBJECT HANDLING
 * ----------------
 * Implementations MUST:
 *  - Publish to {@link OutboxEvent#subject()}
 *  - NOT rewrite subjects dynamically
 *
 * THREAD SAFETY
 * -------------
 * Implementations MUST be:
 *  - Stateless OR
 *  - Internally thread-safe
 *
 * Typical implementations are singletons.
 */
public interface SyncPublisher {

    /**
     * Publishes a single outbox event to the transport.
     *
     * CONTRACT
     * --------
     * - This method MUST be idempotent
     * - It MUST NOT mutate the {@link OutboxEvent}
     * - It MUST propagate failures via Mono.error(...)
     *
     * CALLERS EXPECT
     * --------------
     * - No blocking
     * - Deterministic completion
     * - Clear failure signaling
     *
     * @param event immutable outbox event to publish
     * @return Mono that completes when publish succeeds
     */
    Mono<Void> publish(OutboxEvent event);
}
