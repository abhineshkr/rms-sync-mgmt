package com.rms.sync.core.subject;

/**
 * Tier tokens are LOCKED by the SYNC_MGMT spec.
 *
 * Phase-3 adjacency model includes an explicit subzone tier.
 */
public enum OriginTier {
    leaf, subzone, zone, central
}
