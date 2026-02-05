package com.rms.sync.jetstream.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Application-level configuration that captures:
 * <ul>
 *   <li><b>Node identity</b> (tier/zone/subzone/nodeId) used to consistently derive subjects,
 *       consumer names, and other identity-scoped resources.</li>
 *   <li><b>NATS connection settings</b> (URL + optional auth/TLS) used to establish the client connection.</li>
 * </ul>
 *
 * <h2>Purpose</h2>
 * <ul>
 *   <li>Provide a single source of truth for "who am I?" in a distributed deployment.</li>
 *   <li>Make naming deterministic so that bootstrapping is repeatable across restarts.</li>
 *   <li>Keep connection configuration externalized and environment-specific (dev/test/prod).</li>
 * </ul>
 *
 * <h2>Binding</h2>
 * Properties are bound from Spring Boot config using the prefix {@code syncmgmt}, e.g.:
 * <pre>
 * syncmgmt:
 *   tier: leaf
 *   zone: z1
 *   subzone: sz1
 *   nodeId: node01
 *   natsUrl: nats://localhost:4222
 *   natsUser: ...
 *   natsPassword: ...
 *   natsToken: ...
 *   natsCreds: /path/to/user.creds
 *   natsTls: false
 * </pre>
 *
 * <h2>Operational notes</h2>
 * <ul>
 *   <li>These values are not validated here. Validation (allowed tiers, required zone naming, etc.)
 *       should be enforced by a validator or at bootstrap time.</li>
 *   <li>Secrets (password/token) should be sourced from a secrets manager or environment variables
 *       rather than committed config files.</li>
 * </ul>
 */
@ConfigurationProperties(prefix = "syncmgmt")
public class SyncMgmtProperties {

    // ---------------------------------------------------------------------
    // Node identity (used for naming subjects, streams, consumers, etc.)
    // ---------------------------------------------------------------------

    /**
     * The logical tier of this node in the deployment.
     *
     * <p><b>Purpose</b></p>
     * <ul>
     *   <li>Used to decide which streams/consumers to bootstrap for this node.</li>
     *   <li>Commonly included in derived resource names (consumer durable names, queue groups, etc.).</li>
     * </ul>
     *
     * <p><b>Expected values</b>: {@code leaf | subzone | zone | central}</p>
     *
     * <p><b>Default</b>: {@code leaf}</p>
     */
    private String tier = "leaf";

    /**
     * The zone identifier the node belongs to.
     *
     * <p><b>Purpose</b></p>
     * <ul>
     *   <li>Provides a stable grouping key for multi-zone deployments.</li>
     *   <li>Often included in subject namespaces and durable consumer naming.</li>
     * </ul>
     *
     * <p><b>Examples</b>: {@code central}, {@code z1}, {@code z2}, ...</p>
     *
     * <p><b>Default</b>: {@code z1}</p>
     */
    private String zone = "z1";

    /**
     * The subzone identifier for the node, if applicable.
     *
     * <p><b>Purpose</b></p>
     * <ul>
     *   <li>Allows further partitioning within a zone for scaling/segmentation.</li>
     *   <li>Used in naming when tier-specific resources require subzone uniqueness.</li>
     * </ul>
     *
     * <p><b>Examples</b>: {@code sz1}, {@code sz2}, ... or {@code none} when not used.</p>
     *
     * <p><b>Default</b>: {@code none}</p>
     */
    private String subzone = "none";

    /**
     * Unique node identifier within its operational scope.
     *
     * <p><b>Purpose</b></p>
     * <ul>
     *   <li>Ensures consumer durable names and other node-scoped resources do not collide.</li>
     *   <li>Helps correlate logs/metrics with a specific runtime instance.</li>
     * </ul>
     *
     * <p><b>Default</b>: {@code node01}</p>
     */
    private String nodeId = "node01";

    // ---------------------------------------------------------------------
    // NATS connectivity
    // ---------------------------------------------------------------------

    /**
     * NATS server URL to connect to.
     *
     * <p><b>Purpose</b></p>
     * <ul>
     *   <li>Determines which NATS server/cluster this application instance attaches to.</li>
     * </ul>
     *
     * <p><b>Examples</b>: {@code nats://localhost:4222}, {@code tls://nats.example.com:4222}</p>
     *
     * <p><b>Default</b>: {@code nats://localhost:4222}</p>
     */
    private String natsUrl = "nats://localhost:4222";

    // ---------------------------------------------------------------------
    // Optional authentication / TLS
    // ---------------------------------------------------------------------

    /**
     * Optional username for user/password authentication.
     *
     * <p>Used only when provided (non-blank). If you are using token or creds auth,
     * this may remain unset.</p>
     */
    private String natsUser;

    /**
     * Optional password for user/password authentication.
     *
     * <p><b>Security</b>: treat as a secret; do not log it and do not commit to source control.</p>
     */
    private String natsPassword;

    /**
     * Optional token for token-based authentication.
     *
     * <p>Some NATS deployments use tokens instead of user/password. If set, connection logic
     * should pass this token to the client options.</p>
     */
    private String natsToken;

    /**
     * Optional path to a {@code .creds} file used for NKey/JWT authentication.
     *
     * <p><b>Purpose</b></p>
     * <ul>
     *   <li>Supports secure authentication without embedding passwords/tokens in configuration.</li>
     *   <li>Common in deployments using NATS operator mode/accounts with JWTs.</li>
     * </ul>
     */
    private String natsCreds;

    /**
     * Enables TLS at the client level.
     *
     * <p><b>Purpose</b></p>
     * <ul>
     *   <li>When {@code true}, connection logic should enable TLS/secure mode.</li>
     *   <li>This may be used in combination with a {@code tls://} URL (depending on client behavior).</li>
     * </ul>
     *
     * <p><b>Default</b>: {@code false}</p>
     */
    private boolean natsTls = false;

    // ---------------------------------------------------------------------
    // Getters / setters for Spring Boot binding
    // ---------------------------------------------------------------------

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
