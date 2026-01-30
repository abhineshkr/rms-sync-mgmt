package com.rms.sync.jetstream.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

import java.time.Duration;
import java.util.ArrayList;
import java.util.List;

/**
 * JetStream stream configuration.
 *
 * Defaults follow the POC spec, but everything can be overridden via configuration.
 */
@ConfigurationProperties(prefix = "syncmgmt.jetstream")
public class JetStreamStreamsProperties {

    private Streams streams = new Streams();

    public Streams getStreams() {
        return streams;
    }

    public void setStreams(Streams streams) {
        this.streams = streams;
    }

    /**
     * Returns the configured stream specs.
     *
     * Phase-3 adjacency model uses directional streams:
     * - Upstream streams (child -> parent): WorkQueue retention
     * - Downstream streams (parent -> child): Interest retention
     */
    public List<StreamSpec> all() {
        List<StreamSpec> out = new ArrayList<>();
        if (streams != null) {
            if (streams.getUpLeaf() != null && streams.getUpLeaf().isEnabled()) out.add(streams.getUpLeaf());
            if (streams.getUpSubzone() != null && streams.getUpSubzone().isEnabled()) out.add(streams.getUpSubzone());
            if (streams.getUpZone() != null && streams.getUpZone().isEnabled()) out.add(streams.getUpZone());
            if (streams.getDownCentral() != null && streams.getDownCentral().isEnabled()) out.add(streams.getDownCentral());
            if (streams.getDownZone() != null && streams.getDownZone().isEnabled()) out.add(streams.getDownZone());
            if (streams.getDownSubzone() != null && streams.getDownSubzone().isEnabled()) out.add(streams.getDownSubzone());
        }
        return out;
    }

    public static class Streams {
        private StreamSpec upLeaf = StreamSpec.defaultsUpLeaf();
        private StreamSpec upSubzone = StreamSpec.defaultsUpSubzone();
        private StreamSpec upZone = StreamSpec.defaultsUpZone();

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

    public static class StreamSpec {
        private String name;
        private boolean enabled = true;
        /**
         * One or more subject filters. For this POC typically one entry (e.g., "leaf.>").
         */
        private List<String> subjects = new ArrayList<>();
        private Duration maxAge;
        private String retentionPolicy = "WorkQueue";
        private String storageType = "File";
        private int replicas = 1;
        /**
         * Placement tags influence stream leader placement in clustered JetStream.
         */
        private List<String> placementTags = new ArrayList<>();

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
