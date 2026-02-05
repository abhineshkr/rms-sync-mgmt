package com.rms.sync.core.subject;

/**
 * =====================================================================
 * OriginTier
 * =====================================================================
 *
 * PURPOSE
 * -------
 * Defines the **originating tier** of an event within the SYNC_MGMT
 * distributed topology.
 *
 * This enum is a **canonical vocabulary**, not a convenience type.
 * Its values are embedded directly into JetStream subjects and are
 * therefore:
 *  - Persistent
 *  - User-visible
 *  - Backward-compatibility sensitive
 *
 * TIER MODEL (PHASE-3)
 * -------------------
 *
 *   central
 *      │
 *      ▼
 *     zone
 *      │
 *      ▼
 *   subzone
 *      │
 *      ▼
 *     leaf
 *
 * Each tier:
 *  - Runs its own JetStream server
 *  - Can produce events
 *  - Can consume from adjacent tiers
 *
 * WHY THESE VALUES ARE LOCKED
 * ---------------------------
 * - Tier tokens appear in every subject
 * - Streams are partitioned by tier
 * - ACLs are written against these tokens
 *
 * Changing or renaming a tier would:
 *  - Break stream bindings
 *  - Invalidate retention guarantees
 *  - Require full cluster migration
 *
 * Therefore:
 *  - Values MUST NOT change
 *  - Order MUST NOT change
 *  - Case MUST NOT change
 *
 * ENUM VALUES
 * -----------
 */
public enum OriginTier {

    /**
     * Leaf tier.
     *
     * ROLE
     * ----
     * - Closest to the data source
     * - Highest event volume
     * - Lowest retention scope
     *
     * CHARACTERISTICS
     * ---------------
     * - Typically 10–500 nodes per subzone
     * - Intermittent connectivity expected
     * - Primary producers of business events
     */
    leaf,

    /**
     * Subzone aggregation tier.
     *
     * ROLE
     * ----
     * - Aggregates leaf events
     * - Acts as a buffering and fan-in layer
     *
     * CHARACTERISTICS
     * ---------------
     * - Fewer nodes than leaf
     * - More stable connectivity
     * - May enrich or rebroadcast events
     */
    subzone,

    /**
     * Zone aggregation tier.
     *
     * ROLE
     * ----
     * - Regional aggregation point
     * - Enforces zone-level policies
     *
     * CHARACTERISTICS
     * ---------------
     * - Strong durability
     * - Long retention
     * - Often runs multi-replica JetStream
     */
    zone,

    /**
     * Central tier.
     *
     * ROLE
     * ----
     * - Global aggregation and control plane
     * - Configuration and policy source
     *
     * CHARACTERISTICS
     * ---------------
     * - Highest durability
     * - Longest retention
     * - Downstream broadcaster
     */
    central
}
