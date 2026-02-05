package com.rms.sync.core.subject;

/**
 * =====================================================================
 * SyncDirection
 * =====================================================================
 *
 * PURPOSE
 * -------
 * Defines the **direction of message propagation** within the
 * SYNC_MGMT hierarchical topology.
 *
 * This value is embedded directly into the canonical subject and
 * therefore influences:
 *  - Routing
 *  - Stream partitioning
 *  - Consumer filters
 *  - Access control rules
 *
 * DIRECTION MODEL
 * ---------------
 *
 *   up   : child → parent
 *          Leaf → Subzone → Zone → Central
 *
 *   down : parent → child
 *          Central → Zone → Subzone → Leaf
 *
 * WHY THIS IS EXPLICIT
 * -------------------
 * Direction is NOT inferred from tier ordering because:
 *  - Replay paths differ
 *  - Retention differs
 *  - ACLs differ
 *
 * Making direction explicit ensures:
 *  - Deterministic routing
 *  - Safe fan-out
 *  - Predictable security boundaries
 *
 * LOCKED SEMANTICS
 * ---------------
 * These values are part of the subject contract.
 *
 * Therefore:
 *  - Names MUST NOT change
 *  - Case MUST NOT change
 *  - New values MUST NOT be added casually
 *
 * ENUM VALUES
 * -----------
 */
public enum SyncDirection {

    /**
     * Upstream propagation.
     *
     * FLOW
     * ----
     * Events move from data-producing nodes toward
     * aggregation and control tiers.
     *
     * TYPICAL USE CASES
     * -----------------
     * - Business events (orders, telemetry, metrics)
     * - State changes originating at the edge
     *
     * OPERATIONAL CHARACTERISTICS
     * ---------------------------
     * - High volume
     * - Fan-in behavior
     * - Shorter retention at lower tiers
     */
    up,

    /**
     * Downstream propagation.
     *
     * FLOW
     * ----
     * Events move from control tiers toward
     * execution and enforcement nodes.
     *
     * TYPICAL USE CASES
     * -----------------
     * - Configuration updates
     * - Policy changes
     * - Feature flags
     *
     * OPERATIONAL CHARACTERISTICS
     * ---------------------------
     * - Lower volume
     * - Fan-out behavior
     * - Longer retention at higher tiers
     */
    down
}
