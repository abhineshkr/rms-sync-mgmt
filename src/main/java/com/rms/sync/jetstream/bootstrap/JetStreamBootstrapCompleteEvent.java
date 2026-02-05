package com.rms.sync.jetstream.bootstrap;

/**
 * =====================================================================
 * JetStreamBootstrapCompleteEvent
 * =====================================================================
 *
 * PURPOSE
 * -------
 * Signals that **JetStream infrastructure is fully initialized and safe**
 * for runtime components (consumers, publishers) to start operating.
 *
 * This event is published exactly once by {@link JetStreamBootstrapper}
 * after all configured streams have been:
 *  - Created (if missing)
 *  - Validated (if already existing)
 *
 * WHY THIS EVENT EXISTS
 * ---------------------
 * JetStream stream creation and validation is:
 *  - An administrative operation
 *  - Potentially slow
 *  - Subject to transient failures
 *
 * If consumers start subscribing BEFORE streams are ready:
 *  - Consumer creation may fail
 *  - Pull subscriptions may error
 *  - Replay semantics may break
 *
 * This event establishes a **hard lifecycle boundary**:
 *
 *   ┌────────────────────┐
 *   │ JetStream Bootstrap │
 *   └─────────┬──────────┘
 *             │ publishes
 *             ▼
 *   ┌────────────────────┐
 *   │ Consumers Subscribe │
 *   └────────────────────┘
 *
 * DESIGN CHOICES
 * --------------
 * - Uses Spring's event mechanism (loose coupling)
 * - Immutable record (no state, pure signal)
 * - No payload (presence == readiness)
 *
 * USAGE CONTRACT
 * --------------
 * - Consumers MUST listen for this event
 * - Consumers MUST NOT subscribe during @PostConstruct
 * - Publisher components MAY ignore this event
 *   (publishing before consumers is safe)
 *
 * THREADING / DELIVERY
 * --------------------
 * - Delivered synchronously by default (Spring)
 * - Runs on the same thread that completed bootstrap
 *
 * EXTENSION
 * ---------
 * If future requirements arise, this event may be extended to:
 *  - include stream names
 *  - include bootstrap duration
 *  - include node identity
 *
 * Until then, it remains intentionally minimal.
 */
public record JetStreamBootstrapCompleteEvent() {
}
