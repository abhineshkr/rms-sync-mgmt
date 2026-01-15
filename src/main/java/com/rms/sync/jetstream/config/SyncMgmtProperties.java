package com.rms.sync.jetstream.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Node identity and NATS configuration for subject + consumer naming and bootstrapping.
 */
@ConfigurationProperties(prefix = "syncmgmt")
public class SyncMgmtProperties {
    private String tier = "leaf";      // leaf | zone | central
    private String zone = "z1";        // central or z1..zN
    private String subzone = "none";   // sz1..szN or none
    private String nodeId = "node01";  // unique node ID

    private String natsUrl = "nats://localhost:4222";

    public String getTier() { return tier; }
    public void setTier(String tier) { this.tier = tier; }

    public String getZone() { return zone; }
    public void setZone(String zone) { this.zone = zone; }

    public String getSubzone() { return subzone; }
    public void setSubzone(String subzone) { this.subzone = subzone; }

    public String getNodeId() { return nodeId; }
    public void setNodeId(String nodeId) { this.nodeId = nodeId; }

    public String getNatsUrl() { return natsUrl; }
    public void setNatsUrl(String natsUrl) { this.natsUrl = natsUrl; }
}
