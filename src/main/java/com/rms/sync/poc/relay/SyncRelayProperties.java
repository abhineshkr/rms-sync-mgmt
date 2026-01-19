package com.rms.sync.poc.relay;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Configuration for Phase-3 adjacency relay.
 *
 * The relay runs on intermediate tiers (subzone, zone) to:
 * - consume from the direct-neighbor stream (child or parent)
 * - republish to the next hop stream with a rewritten subject
 * - ACK only after successful publish
 */
@ConfigurationProperties(prefix = "syncmgmt.relay")
public class SyncRelayProperties {

    /** Enable/disable relay component. */
    private boolean enabled = false;

    /** For zone tier: whether this zone has subzones (if false, zone consumes upstream directly from leaf). */
    private boolean zoneHasSubzones = true;

    /** Batch size per pull. */
    private int batchSize = 50;

    /** Poll interval milliseconds. */
    private long pollIntervalMs = 500;

    public boolean isEnabled() { return enabled; }
    public void setEnabled(boolean enabled) { this.enabled = enabled; }

    public boolean isZoneHasSubzones() { return zoneHasSubzones; }
    public void setZoneHasSubzones(boolean zoneHasSubzones) { this.zoneHasSubzones = zoneHasSubzones; }

    public int getBatchSize() { return batchSize; }
    public void setBatchSize(int batchSize) { this.batchSize = batchSize; }

    public long getPollIntervalMs() { return pollIntervalMs; }
    public void setPollIntervalMs(long pollIntervalMs) { this.pollIntervalMs = pollIntervalMs; }
}
