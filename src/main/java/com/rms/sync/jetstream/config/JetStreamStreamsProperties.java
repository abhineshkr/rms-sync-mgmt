package com.rms.sync.jetstream.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

import java.time.Duration;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * JetStream stream configuration bound from Spring Boot configuration properties.
 *
 * <p><b>Purpose</b></p>
 * <ul>
 *   <li>Centralizes stream definitions (names, subjects, retention, storage, replicas, placement).</li>
 *   <li>Provides safe defaults so a deployment can start with zero configuration.</li>
 *   <li>Allows operators to override any stream property via application configuration.</li>
 * </ul>
 *
 * <p><b>Conceptual model</b></p>
 * <ul>
 *   <li><b>Upstream streams</b> carry events from outer tiers toward an aggregation/core tier.
 *       They typically use {@code WorkQueue} retention to ensure each message is processed by
 *       exactly one durable consumer (per stream) in a competing-consumer pattern.</li>
 *   <li><b>Downstream streams</b> carry events from a core tier toward outer tiers.
 *       They typically use {@code Interest} retention so messages are retained only while there
 *       is consumer interest, preventing unbounded growth when no subscribers exist.</li>
 * </ul>
 *
 * <p>
 * Configuration prefix: {@code syncmgmt.jetstream}
 * </p>
 */
@ConfigurationProperties(prefix = "syncmgmt.jetstream")
public class JetStreamStreamsProperties {

    /**
     * Container for all stream specs.
     *
     * <p>Spring binds nested properties under {@code syncmgmt.jetstream.streams.*} into this object.</p>
     */
    private Streams streams = new Streams();

    public Streams getStreams() {
        return streams;
    }

    public void setStreams(Streams streams) {
        this.streams = streams;
    }

    /**
     * Returns all configured and enabled stream specifications.
     *
     * <p><b>Purpose</b></p>
     * <ul>
     *   <li>Provides a single list used by bootstrap/initializer logic to create or validate streams.</li>
     *   <li>Respects {@link StreamSpec#isEnabled()} so streams can be selectively turned off.</li>
     * </ul>
     *
     * <p><b>Ordering note</b></p>
     * <p>
     * The list is constructed in a stable order (upstream first, then downstream). This makes logs,
     * diffs, and any deterministic bootstrap behavior easier to reason about.
     * </p>
     */
    public List<StreamSpec> all() {
        List<StreamSpec> out = new ArrayList<>();
        if (streams != null) {
            // Upstream streams (outer tiers -> core tier)
            if (streams.getUpLeaf() != null && streams.getUpLeaf().isEnabled()) out.add(streams.getUpLeaf());
            if (streams.getUpSubzone() != null && streams.getUpSubzone().isEnabled()) out.add(streams.getUpSubzone());
            if (streams.getUpZone() != null && streams.getUpZone().isEnabled()) out.add(streams.getUpZone());

            // Downstream streams (core tier -> outer tiers)
            if (streams.getDownCentral() != null && streams.getDownCentral().isEnabled()) out.add(streams.getDownCentral());
            if (streams.getDownZone() != null && streams.getDownZone().isEnabled()) out.add(streams.getDownZone());
            if (streams.getDownSubzone() != null && streams.getDownSubzone().isEnabled()) out.add(streams.getDownSubzone());
        }
        return out;
    }

    /**
     * Returns a stable map of logical stream keys to configured stream specs.
     *
     * <p>Keys match the YAML object keys under {@code syncmgmt.jetstream.streams}.</p>
     */
    public Map<String, StreamSpec> byKey() {
        Map<String, StreamSpec> out = new LinkedHashMap<>();
        if (streams == null) {
            return out;
        }
        out.put("up-leaf", streams.getUpLeaf());
        out.put("up-subzone", streams.getUpSubzone());
        out.put("up-zone", streams.getUpZone());
        out.put("down-central", streams.getDownCentral());
        out.put("down-zone", streams.getDownZone());
        out.put("down-subzone", streams.getDownSubzone());
        return out;
    }

    /**
     * Select a subset of streams by logical keys.
     *
     * <p>This is used to bootstrap only the streams relevant to a given deployment
     * (central/zone/subzone/leaf).</p>
     */
    public List<StreamSpec> selectByKeys(List<String> keys) {
        if (keys == null || keys.isEmpty()) {
            return all();
        }
        Map<String, StreamSpec> map = byKey();
        List<StreamSpec> out = new ArrayList<>();
        for (String rawKey : keys) {
            if (rawKey == null || rawKey.isBlank()) {
                continue;
            }
            String key = rawKey.trim().toLowerCase(Locale.ROOT);
            StreamSpec spec = map.get(key);
            if (spec == null) {
                throw new IllegalArgumentException("Unknown stream key: " + rawKey + ". Valid keys=" + map.keySet());
            }
            if (!spec.isEnabled()) {
                throw new IllegalStateException("Stream key '" + key + "' is configured but disabled (enabled=false)");
            }
            out.add(spec);
        }
        return out;
    }

    /**
     * Grouping of all stream specs that this service knows how to bootstrap/manage.
     *
     * <p><b>Purpose</b></p>
     * <ul>
     *   <li>Keeps the property tree readable: {@code syncmgmt.jetstream.streams.up-leaf.*}, etc.</li>
     *   <li>Provides defaults for each stream via {@link StreamSpec#defaultsUpLeaf()} and friends.</li>
     * </ul>
     *
     * <p><b>Override behavior</b></p>
     * <p>
     * Any field can be overridden via configuration. If a stream is disabled, it will not be included
     * in {@link #all()} and should not be created/validated by bootstrap logic.
     * </p>
     */
    public static class Streams {
        // Upstream specs
        private StreamSpec upLeaf = StreamSpec.defaultsUpLeaf();
        private StreamSpec upSubzone = StreamSpec.defaultsUpSubzone();
        private StreamSpec upZone = StreamSpec.defaultsUpZone();

        // Downstream specs
        private StreamSpec downCentral = StreamSpec.defaultsDownCentral();
        private StreamSpec downZone = StreamSpec.defaultsDownZone();
        private StreamSpec downSubzone = StreamSpec.defaultsDownSubzone();

        public StreamSpec getUpLeaf() { return upLeaf; }
        public void setUpLeaf(StreamSpec upLeaf) { this.upLeaf = upLeaf; }

        public StreamSpec getUpSubzone() { return upSubzone; }
        public void setUpSubzone(StreamSpec upSubzone) { this.upSubzone = upSubzone; }

        public StreamSpec getUpZone() { return upZone; }
        public void setUpZone(StreamSpec upZone) { this.upZone = upZone; }

        public StreamSpec getDownCentral() { return downCentral; }
        public void setDownCentral(StreamSpec downCentral) { this.downCentral = downCentral; }

        public StreamSpec getDownZone() { return downZone; }
        public void setDownZone(StreamSpec downZone) { this.downZone = downZone; }

        public StreamSpec getDownSubzone() { return downSubzone; }
        public void setDownSubzone(StreamSpec downSubzone) { this.downSubzone = downSubzone; }
    }

    /**
     * Specification for a single JetStream stream.
     *
     * <p><b>Purpose</b></p>
     * <ul>
     *   <li>Captures the minimum set of attributes needed to create/validate a JetStream stream.</li>
     *   <li>Acts as a configuration DTO (data transfer object) for bootstrap components.</li>
     * </ul>
     *
     * <p><b>Implementation notes</b></p>
     * <ul>
     *   <li>Retention/storage are represented as Strings to keep property binding simple.
     *       Bootstrap code can map these to NATS client enums as needed.</li>
     *   <li>{@code subjects} is a list to allow multiple subject filters per stream.
     *       In most deployments it is a single entry (e.g., {@code "up.leaf.>"}).</li>
     * </ul>
     */
    public static class StreamSpec {

        /** Stream name as registered in JetStream (e.g., {@code UP_ZONE_STREAM}). */
        private String name;

        /**
         * Feature toggle for this stream.
         *
         * <p>When {@code false}, this spec should be ignored by bootstrap logic.</p>
         */
        private boolean enabled = true;

        /**
         * One or more subject filters that belong to this stream.
         *
         * <p><b>How it works</b></p>
         * <ul>
         *   <li>JetStream stores only messages whose subject matches one of these filters.</li>
         *   <li>Filters commonly use wildcards:
         *       <ul>
         *         <li>{@code *} matches a single token</li>
         *         <li>{@code >} matches the remainder of the subject</li>
         *       </ul>
         *   </li>
         * </ul>
         */
        private List<String> subjects = new ArrayList<>();

        /**
         * Maximum age for messages retained in the stream.
         *
         * <p>After this duration, messages are eligible for eviction (subject to retention policy).</p>
         */
        private Duration maxAge;

        /**
         * Retention policy for the stream (e.g., {@code "WorkQueue"} or {@code "Interest"}).
         *
         * <p><b>Operational intent</b></p>
         * <ul>
         *   <li>{@code WorkQueue}: messages are removed as they are acknowledged by consumers;
         *       used for reliable processing with competing consumers.</li>
         *   <li>{@code Interest}: messages are retained while there is consumer interest;
         *       used for fan-out style delivery where storage should not grow without subscribers.</li>
         * </ul>
         */
        private String retentionPolicy = "WorkQueue";

        /**
         * Storage type (e.g., {@code "File"} or {@code "Memory"}).
         *
         * <p>File storage is typical when replay across restarts is required.</p>
         */
        private String storageType = "File";

        /**
         * Replication factor for the stream in a JetStream clustered deployment.
         *
         * <p>Set to {@code 1} for single-node or non-HA use; increase to tolerate node failures.</p>
         */
        private int replicas = 1;

        /**
         * Placement tags influence stream leader placement in clustered JetStream.
         *
         * <p><b>Purpose</b></p>
         * <ul>
         *   <li>Allows pinning/affinity: ensure a given stream is led by nodes labeled for a role/tier.</li>
         *   <li>Can reduce cross-zone chatter by keeping stream leadership close to its producers/consumers.</li>
         * </ul>
         */
        private List<String> placementTags = new ArrayList<>();

        /**
         * Default upstream stream for leaf-originated events.
         *
         * <p><b>Intent</b>: durable processing toward an upstream tier with WorkQueue semantics.</p>
         */
        public static StreamSpec defaultsUpLeaf() {
            StreamSpec s = new StreamSpec();
            s.name = "UP_LEAF_STREAM";
            s.subjects = List.of("up.leaf.>");
            s.maxAge = Duration.ofDays(30);
            s.retentionPolicy = "WorkQueue";
            s.storageType = "File";
            s.replicas = 1;
            s.placementTags = List.of("leaf");
            return s;
        }

        /**
         * Default upstream stream for subzone-originated (or subzone-aggregated) events.
         *
         * <p><b>Intent</b>: retain longer than leaf to accommodate longer disruption windows in mid-tiers.</p>
         */
        public static StreamSpec defaultsUpSubzone() {
            StreamSpec s = new StreamSpec();
            s.name = "UP_SUBZONE_STREAM";
            s.subjects = List.of("up.subzone.>");
            s.maxAge = Duration.ofDays(60);
            s.retentionPolicy = "WorkQueue";
            s.storageType = "File";
            s.replicas = 1;
            s.placementTags = List.of("zone");
            return s;
        }

        /**
         * Default upstream stream for zone-originated (or zone-aggregated) events.
         *
         * <p><b>Intent</b>: longest upstream retention window to support higher fan-in and replay needs.</p>
         */
        public static StreamSpec defaultsUpZone() {
            StreamSpec s = new StreamSpec();
            s.name = "UP_ZONE_STREAM";
            s.subjects = List.of("up.zone.>");
            s.maxAge = Duration.ofDays(90);
            s.retentionPolicy = "WorkQueue";
            s.storageType = "File";
            s.replicas = 1;
            s.placementTags = List.of("central");
            return s;
        }

        /**
         * Default downstream stream for core-originated events targeting zones and beyond.
         *
         * <p><b>Intent</b>: downstream distribution with Interest retention to avoid unbounded storage.</p>
         */
        public static StreamSpec defaultsDownCentral() {
            StreamSpec s = new StreamSpec();
            s.name = "DOWN_CENTRAL_STREAM";
            s.subjects = List.of("down.central.>");
            s.maxAge = Duration.ofDays(90);
            s.retentionPolicy = "Interest";
            s.storageType = "File";
            s.replicas = 1;
            s.placementTags = List.of("central");
            return s;
        }

        /**
         * Default downstream stream for zone-level distribution.
         *
         * <p><b>Intent</b>: mid-tier fan-out with a moderate retention window.</p>
         */
        public static StreamSpec defaultsDownZone() {
            StreamSpec s = new StreamSpec();
            s.name = "DOWN_ZONE_STREAM";
            s.subjects = List.of("down.zone.>");
            s.maxAge = Duration.ofDays(60);
            s.retentionPolicy = "Interest";
            s.storageType = "File";
            s.replicas = 1;
            s.placementTags = List.of("zone");
            return s;
        }

        /**
         * Default downstream stream for subzone/leaf-level distribution.
         *
         * <p><b>Intent</b>: edge-facing fan-out with a shorter retention window to limit storage footprint.</p>
         */
        public static StreamSpec defaultsDownSubzone() {
            StreamSpec s = new StreamSpec();
            s.name = "DOWN_SUBZONE_STREAM";
            s.subjects = List.of("down.subzone.>");
            s.maxAge = Duration.ofDays(30);
            s.retentionPolicy = "Interest";
            s.storageType = "File";
            s.replicas = 1;
            s.placementTags = List.of("leaf");
            return s;
        }

        // --- Standard JavaBean accessors for Spring property binding ---

        public boolean isEnabled() { return enabled; }
        public void setEnabled(boolean enabled) { this.enabled = enabled; }

        public String getName() { return name; }
        public void setName(String name) { this.name = name; }

        public List<String> getSubjects() { return subjects; }
        public void setSubjects(List<String> subjects) { this.subjects = subjects; }

        public Duration getMaxAge() { return maxAge; }
        public void setMaxAge(Duration maxAge) { this.maxAge = maxAge; }

        public String getRetentionPolicy() { return retentionPolicy; }
        public void setRetentionPolicy(String retentionPolicy) { this.retentionPolicy = retentionPolicy; }

        public String getStorageType() { return storageType; }
        public void setStorageType(String storageType) { this.storageType = storageType; }

        public int getReplicas() { return replicas; }
        public void setReplicas(int replicas) { this.replicas = replicas; }

        public List<String> getPlacementTags() { return placementTags; }
        public void setPlacementTags(List<String> placementTags) { this.placementTags = placementTags; }
    }
}
