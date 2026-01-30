package com.rms.sync.jetstream.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Node identity and NATS configuration for subject + consumer naming and bootstrapping.
 */
@ConfigurationProperties(prefix = "syncmgmt")
public class SyncMgmtProperties {
    private String tier = "leaf";      // leaf | subzone | zone | central
    private String zone = "z1";        // central or z1..zN
    private String subzone = "none";   // sz1..szN or none
    private String nodeId = "node01";  // unique node ID

    private String natsUrl = "nats://localhost:4222";

    // optional auth/TLS (production-like test)
    private String natsUser;
    private String natsPassword;
    private String natsToken;
    private String natsCreds; // path to .creds file (NKey/JWT)
    private boolean natsTls = false;

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

    public String getNatsUser() { return natsUser; }
    public void setNatsUser(String natsUser) { this.natsUser = natsUser; }

    public String getNatsPassword() { return natsPassword; }
    public void setNatsPassword(String natsPassword) { this.natsPassword = natsPassword; }

    public String getNatsToken() { return natsToken; }
    public void setNatsToken(String natsToken) { this.natsToken = natsToken; }

    public String getNatsCreds() { return natsCreds; }
    public void setNatsCreds(String natsCreds) { this.natsCreds = natsCreds; }

    public boolean isNatsTls() { return natsTls; }
    public void setNatsTls(boolean natsTls) { this.natsTls = natsTls; }
}
