package com.rms.sync.core.subject;

import java.util.Objects;
import java.util.regex.Pattern;

/**
 * Canonical subject format (LOCKED):
 * <origin-tier>.<zone>.<subzone>.<origin-node>.<domain>.<entity>.<event>
 *
 * Examples:
 * leaf.z1.sz2.leaf123.order.created
 * zone.z1.sz2.zoneAgg.order.completed
 * central.central.none.centralAgg.audit.logged
 */
public final class SyncSubject {

    private static final Pattern TOKEN = Pattern.compile("^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$");

    private final OriginTier originTier;
    private final String zone;
    private final String subzone;     // use "none" when not applicable
    private final String originNode;
    private final String domain;
    private final String entity;
    private final String event;

    private SyncSubject(Builder b) {
        this.originTier = Objects.requireNonNull(b.originTier, "originTier");
        this.zone = requireToken(b.zone, "zone");
        this.subzone = requireToken(b.subzone, "subzone");
        this.originNode = requireToken(b.originNode, "originNode");
        this.domain = requireToken(b.domain, "domain");
        this.entity = requireToken(b.entity, "entity");
        this.event = requireToken(b.event, "event");
    }

    public static Builder builder() {
        return new Builder();
    }

    public String toSubject() {
        return originTier.name() + "." + zone + "." + subzone + "." + originNode + "." + domain + "." + entity + "." + event;
    }

    private static String requireToken(String value, String name) {
        if (value == null || value.isBlank()) {
            throw new IllegalArgumentException(name + " is required");
        }
        if (!TOKEN.matcher(value).matches()) {
            throw new IllegalArgumentException(name + " must match " + TOKEN.pattern() + " but was: " + value);
        }
        return value;
    }

    public OriginTier originTier() { return originTier; }
    public String zone() { return zone; }
    public String subzone() { return subzone; }
    public String originNode() { return originNode; }
    public String domain() { return domain; }
    public String entity() { return entity; }
    public String event() { return event; }

    public static final class Builder {
        private OriginTier originTier;
        private String zone;
        private String subzone = "none";
        private String originNode;
        private String domain;
        private String entity;
        private String event;

        public Builder originTier(OriginTier originTier) { this.originTier = originTier; return this; }
        public Builder zone(String zone) { this.zone = zone; return this; }
        public Builder subzone(String subzone) { this.subzone = subzone; return this; }
        public Builder originNode(String originNode) { this.originNode = originNode; return this; }
        public Builder domain(String domain) { this.domain = domain; return this; }
        public Builder entity(String entity) { this.entity = entity; return this; }
        public Builder event(String event) { this.event = event; return this; }

        public SyncSubject build() { return new SyncSubject(this); }
    }
}
