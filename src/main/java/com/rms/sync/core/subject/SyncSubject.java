package com.rms.sync.core.subject;

import java.util.Objects;
import java.util.regex.Pattern;

/**
 * Canonical subject format (Phase 3 adjacency model):
 *
 * <dir>.<tier>.<zone>.<subzone>.<node>.<domain>.<entity>.<event>
 *
 * Examples:
 *  up.leaf.z1.sz1.leaf01.order.order.created
 *  up.subzone.z1.sz1.subzone01.order.order.created
 *  up.zone.z1.none.zone01.order.order.created
 *  down.central.z1.sz1.all.config.policy.updated
 *  down.zone.z1.sz1.zone01.config.policy.updated
 *  down.subzone.z1.sz1.subzone01.config.policy.updated
 */
public final class SyncSubject {

    private static final Pattern TOKEN = Pattern.compile("^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$");

    private final SyncDirection direction;
    private final OriginTier tier;
    private final String zone;
    private final String subzone;     // use "none" when not applicable
    private final String node;
    private final String domain;
    private final String entity;
    private final String event;

    private SyncSubject(Builder b) {
        this.direction = Objects.requireNonNull(b.direction, "direction");
        this.tier = Objects.requireNonNull(b.tier, "tier");
        this.zone = requireToken(b.zone, "zone");
        this.subzone = requireToken(b.subzone, "subzone");
        this.node = requireToken(b.node, "node");
        this.domain = requireToken(b.domain, "domain");
        this.entity = requireToken(b.entity, "entity");
        this.event = requireToken(b.event, "event");
    }

    public static Builder builder() {
        return new Builder();
    }

    public String toSubject() {
        return direction.name() + "." + tier.name() + "." + zone + "." + subzone + "." + node + "." + domain + "." + entity + "." + event;
    }

    /**
     * Parse a canonical Phase-3 subject into a {@link Parsed} representation.
     * Returns {@code null} if the subject is not in canonical 8-token format.
     */
    public static Parsed tryParse(String subject) {
        if (subject == null) return null;
        String[] t = subject.split("\\.");
        if (t.length != 8) return null;
        try {
            return new Parsed(
                    SyncDirection.valueOf(t[0]),
                    OriginTier.valueOf(t[1]),
                    t[2], t[3], t[4], t[5], t[6], t[7]
            );
        } catch (Exception e) {
            return null;
        }
    }

    /**
     * Rewrite an existing canonical subject to a new direction/tier/identity while
     * preserving domain/entity/event tokens.
     */
    public static String rewrite(String subject, SyncDirection newDir, OriginTier newTier,
                                 String zone, String subzone, String node) {
        Parsed p = tryParse(subject);
        if (p == null) {
            throw new IllegalArgumentException("Cannot rewrite non-canonical subject (expected 8 tokens): " + subject);
        }
        return newDir.name() + "." + newTier.name() + "." + zone + "." + subzone + "." + node + "." + p.domain + "." + p.entity + "." + p.event;
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

    public SyncDirection direction() { return direction; }
    public OriginTier tier() { return tier; }
    public String zone() { return zone; }
    public String subzone() { return subzone; }
    public String node() { return node; }
    public String domain() { return domain; }
    public String entity() { return entity; }
    public String event() { return event; }

    public static final class Builder {
        private SyncDirection direction = SyncDirection.up;
        private OriginTier tier;
        private String zone;
        private String subzone = "none";
        private String node;
        private String domain;
        private String entity;
        private String event;

        public Builder direction(SyncDirection direction) { this.direction = direction; return this; }
        public Builder tier(OriginTier tier) { this.tier = tier; return this; }
        public Builder zone(String zone) { this.zone = zone; return this; }
        public Builder subzone(String subzone) { this.subzone = subzone; return this; }
        public Builder node(String node) { this.node = node; return this; }
        public Builder domain(String domain) { this.domain = domain; return this; }
        public Builder entity(String entity) { this.entity = entity; return this; }
        public Builder event(String event) { this.event = event; return this; }

        public SyncSubject build() { return new SyncSubject(this); }
    }

    public static final class Parsed {
        public final SyncDirection direction;
        public final OriginTier tier;
        public final String zone;
        public final String subzone;
        public final String node;
        public final String domain;
        public final String entity;
        public final String event;

        public Parsed(SyncDirection direction, OriginTier tier, String zone, String subzone, String node,
                      String domain, String entity, String event) {
            this.direction = direction;
            this.tier = tier;
            this.zone = zone;
            this.subzone = subzone;
            this.node = node;
            this.domain = domain;
            this.entity = entity;
            this.event = event;
        }

        @Override
        public String toString() {
            return "Parsed{" +
                    "direction=" + direction +
                    ", tier=" + tier +
                    ", zone='" + zone + '\'' +
                    ", subzone='" + subzone + '\'' +
                    ", node='" + node + '\'' +
                    ", domain='" + domain + '\'' +
                    ", entity='" + entity + '\'' +
                    ", event='" + event + '\'' +
                    '}';
        }
    }
}
