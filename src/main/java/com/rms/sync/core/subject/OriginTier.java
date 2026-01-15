package com.rms.sync.core.subject;

/**
 * Tier tokens are LOCKED by the SYNC_MGMT spec: leaf | zone | central.
 */
public enum OriginTier {
    leaf, zone, central
}
