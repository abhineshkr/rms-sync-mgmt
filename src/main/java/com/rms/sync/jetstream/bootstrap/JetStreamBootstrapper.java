package com.rms.sync.jetstream.bootstrap;

import com.rms.sync.jetstream.config.JetStreamBootstrapProperties;
import com.rms.sync.jetstream.config.JetStreamStreamsProperties;
import io.nats.client.JetStreamApiException;
import io.nats.client.JetStreamManagement;
import io.nats.client.api.Placement;
import io.nats.client.api.RetentionPolicy;
import io.nats.client.api.StorageType;
import io.nats.client.api.StreamConfiguration;
import io.nats.client.api.StreamInfo;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.stereotype.Component;

import java.time.Duration;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Objects;
import java.util.Set;

/**
 * Ensures the configured streams exist.
 *
 * IMPORTANT:
 * - This should be enabled ONLY on stream-owner nodes (e.g., central creates CENTRAL_STREAM, leaf creates LEAF_STREAM).
 * - After completion, publishes JetStreamBootstrapCompleteEvent so consumers can safely subscribe.
 */
@Component
@ConditionalOnProperty(prefix = "syncmgmt.bootstrap", name = "enabled", havingValue = "true", matchIfMissing = false)
public class JetStreamBootstrapper implements ApplicationRunner {

    private static final Logger log = LoggerFactory.getLogger(JetStreamBootstrapper.class);

    // JetStream API error code for "stream not found"
    private static final int JS_STREAM_NOT_FOUND_ERR = 10059;

    private final JetStreamManagement jsm;
    private final JetStreamStreamsProperties streamsProps;
    private final JetStreamBootstrapProperties bootstrapProps;
    private final ApplicationEventPublisher publisher;

    public JetStreamBootstrapper(
            JetStreamManagement jsm,
            JetStreamStreamsProperties streamsProps,
            JetStreamBootstrapProperties bootstrapProps,
            ApplicationEventPublisher publisher
    ) {
        this.jsm = jsm;
        this.streamsProps = streamsProps;
        this.bootstrapProps = bootstrapProps;
        this.publisher = publisher;
    }

    @Override
    public void run(ApplicationArguments args) throws Exception {
        for (JetStreamStreamsProperties.StreamSpec spec : streamsProps.all()) {
            ensureStream(spec);
        }
        publisher.publishEvent(new JetStreamBootstrapCompleteEvent());
        log.info("JetStream bootstrap complete (published JetStreamBootstrapCompleteEvent)");
    }

    private void ensureStream(JetStreamStreamsProperties.StreamSpec spec) throws Exception {
        StreamConfiguration desired = toStreamConfig(spec);

        try {
            StreamInfo existing = jsm.getStreamInfo(desired.getName());
            validateExisting(desired, existing);
            return;
        } catch (JetStreamApiException e) {
            // Only proceed to create if the stream truly does not exist.
            if (!isStreamNotFound(e)) {
                throw e; // do not mask auth/connectivity/other API errors
            }
        }

        jsm.addStream(desired);
        log.info("Created JetStream stream: {} (subjects={}, maxAge={}, retention={}, storage={}, replicas={}, placementTags={})",
                desired.getName(),
                desired.getSubjects(),
                desired.getMaxAge(),
                desired.getRetentionPolicy(),
                desired.getStorageType(),
                desired.getReplicas(),
                desired.getPlacement() == null ? List.of() : desired.getPlacement().getTags());
    }

    private void validateExisting(StreamConfiguration desired, StreamInfo existing) {
        StreamConfiguration actual = existing.getConfiguration();

        List<String> diffs = new ArrayList<>();

        if (!Objects.equals(actual.getRetentionPolicy(), desired.getRetentionPolicy())) {
            diffs.add("retentionPolicy actual=" + actual.getRetentionPolicy() + " expected=" + desired.getRetentionPolicy());
        }
        if (!Objects.equals(actual.getStorageType(), desired.getStorageType())) {
            diffs.add("storageType actual=" + actual.getStorageType() + " expected=" + desired.getStorageType());
        }
        if (!Objects.equals(actual.getMaxAge(), desired.getMaxAge())) {
            diffs.add("maxAge actual=" + actual.getMaxAge() + " expected=" + desired.getMaxAge());
        }
        if (actual.getReplicas() != desired.getReplicas()) {
            diffs.add("replicas actual=" + actual.getReplicas() + " expected=" + desired.getReplicas());
        }

        if (!setEquals(actual.getSubjects(), desired.getSubjects())) {
            diffs.add("subjects actual=" + actual.getSubjects() + " expected=" + desired.getSubjects());
        }

        List<String> actualTags = actual.getPlacement() == null ? List.of() : actual.getPlacement().getTags();
        List<String> desiredTags = desired.getPlacement() == null ? List.of() : desired.getPlacement().getTags();
        if (!setEquals(actualTags, desiredTags)) {
            diffs.add("placementTags actual=" + actualTags + " expected=" + desiredTags);
        }

        if (diffs.isEmpty()) {
            log.info("JetStream stream exists and matches config: {} (subjects={}, placement={})",
                    desired.getName(), actual.getSubjects(), actual.getPlacement());
            return;
        }

        String msg = "JetStream stream exists but differs from expected: " + desired.getName() + " :: " + String.join("; ", diffs);
        if (bootstrapProps.isFailOnMismatch()) {
            throw new IllegalStateException(msg);
        }
        log.warn(msg);
    }

    private static boolean isStreamNotFound(JetStreamApiException e) {
        // Keep your existing API usage; compile-safe with your current dependency.
        return e.getApiErrorCode() == JS_STREAM_NOT_FOUND_ERR;
    }

    private static boolean setEquals(List<String> a, List<String> b) {
        Set<String> sa = new HashSet<>(a == null ? List.of() : a);
        Set<String> sb = new HashSet<>(b == null ? List.of() : b);
        return sa.equals(sb);
    }

    private static StreamConfiguration toStreamConfig(JetStreamStreamsProperties.StreamSpec spec) {
        String name = require(spec.getName(), "name");

        List<String> subjects = spec.getSubjects();
        if (subjects == null || subjects.isEmpty()) {
            throw new IllegalArgumentException("subjects is required for stream " + name);
        }

        Duration maxAge = Objects.requireNonNull(spec.getMaxAge(), "maxAge is required for stream " + name);

        RetentionPolicy rp = parseRetentionPolicy(spec.getRetentionPolicy());
        StorageType st = parseStorageType(spec.getStorageType());

        StreamConfiguration.Builder b = StreamConfiguration.builder()
                .name(name)
                .subjects(subjects.toArray(String[]::new))
                .retentionPolicy(rp)
                .storageType(st)
                .maxAge(maxAge)
                .replicas(spec.getReplicas());

        List<String> tags = spec.getPlacementTags();
        if (tags != null && !tags.isEmpty()) {
            b.placement(Placement.builder().tags(tags.toArray(String[]::new)).build());
        }

        return b.build();
    }

    private static String require(String value, String fieldName) {
        if (value == null || value.isBlank()) {
            throw new IllegalArgumentException(fieldName + " is required");
        }
        return value;
    }

    private static RetentionPolicy parseRetentionPolicy(String value) {
        if (value == null || value.isBlank()) {
            return RetentionPolicy.WorkQueue;
        }
        String v = value.trim().toLowerCase();
        return switch (v) {
            case "workqueue", "work_queue", "work-queue" -> RetentionPolicy.WorkQueue;
            case "limits" -> RetentionPolicy.Limits;
            case "interest" -> RetentionPolicy.Interest;
            default -> throw new IllegalArgumentException("Unsupported retentionPolicy: " + value);
        };
    }

    private static StorageType parseStorageType(String value) {
        if (value == null || value.isBlank()) {
            return StorageType.File;
        }
        String v = value.trim().toLowerCase();
        return switch (v) {
            case "file" -> StorageType.File;
            case "memory" -> StorageType.Memory;
            default -> throw new IllegalArgumentException("Unsupported storageType: " + value);
        };
    }
}
