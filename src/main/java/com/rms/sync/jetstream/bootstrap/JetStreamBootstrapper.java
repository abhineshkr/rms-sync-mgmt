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
import java.util.*;

/**
 * =====================================================================
 * JetStreamBootstrapper
 * =====================================================================
 *
 * PURPOSE
 * -------
 * Ensures that **required JetStream streams exist and conform exactly**
 * to the platform's expected configuration.
 *
 * This component is part of the **control plane**, not the data plane.
 *
 * WHEN THIS RUNS
 * --------------
 * - Runs once during Spring Boot startup
 * - BEFORE consumers are created
 * - AFTER JetStream connection is established
 *
 * WHO SHOULD ENABLE THIS
 * ---------------------
 * ONLY stream-owner nodes.
 *
 * Examples:
 *  - Central node  → creates CENTRAL_STREAM
 *  - Zone node     → creates ZONE_STREAM
 *  - Leaf node     → creates LEAF_STREAM
 *
 * NEVER enable this on:
 *  - Read-only consumers
 *  - Edge replay-only nodes
 *
 * WHY THIS EXISTS
 * ---------------
 * JetStream streams are **infrastructure**, not application state.
 *
 * Once created:
 *  - Retention policy MUST NOT drift
 *  - Storage type MUST NOT change
 *  - Subjects MUST NOT diverge
 *
 * Silent drift = data loss or replay corruption.
 *
 * Therefore:
 *  - This class validates immutability
 *  - Fails fast (optionally) on mismatch
 *  - Emits a lifecycle signal when safe
 */
@Component
@ConditionalOnProperty(
        prefix = "syncmgmt.bootstrap",
        name = "enabled",
        havingValue = "true",
        matchIfMissing = false
)
public class JetStreamBootstrapper implements ApplicationRunner {

    private static final Logger log =
            LoggerFactory.getLogger(JetStreamBootstrapper.class);

    /**
     * JetStream API error code indicating "stream not found".
     *
     * NOTE:
     * We intentionally do NOT rely on message text,
     * only stable numeric API codes.
     */
    private static final int JS_STREAM_NOT_FOUND_ERR = 10059;

    /** JetStream management interface (admin-level operations) */
    private final JetStreamManagement jsm;

    /** Declarative stream definitions (YAML-driven) */
    private final JetStreamStreamsProperties streamsProps;

    /** Bootstrap behavior flags (fail-fast vs warn-only) */
    private final JetStreamBootstrapProperties bootstrapProps;

    /**
     * Spring event publisher used to signal
     * "JetStream infrastructure is ready".
     */
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

    /**
     * ApplicationRunner entry point.
     *
     * EXECUTION ORDER GUARANTEE
     * ------------------------
     * Spring ensures this runs:
     *  - After context initialization
     *  - Before normal application traffic
     *
     * FLOW
     * ----
     * 1. Iterate through all declared stream specs
     * 2. Ensure each stream exists & matches config
     * 3. Publish bootstrap-complete event
     */
    @Override
    public void run(ApplicationArguments args) throws Exception {
        var selected = streamsProps.selectByKeys(bootstrapProps.getStreamKeys());
        if (bootstrapProps.getStreamKeys() != null && !bootstrapProps.getStreamKeys().isEmpty()) {
            log.info("JetStream bootstrap: streamKeys={} (bootstrapping {} streams)", bootstrapProps.getStreamKeys(), selected.size());
        } else {
            log.info("JetStream bootstrap: streamKeys not set (bootstrapping all configured streams: {})", selected.size());
        }

        for (JetStreamStreamsProperties.StreamSpec spec : selected) {
            ensureStream(spec);
        }

        // Signals downstream beans (consumers, publishers)
        // that JetStream is now safe to use.
        publisher.publishEvent(new JetStreamBootstrapCompleteEvent());

        log.info("JetStream bootstrap complete (published JetStreamBootstrapCompleteEvent)");
    }

    /**
     * Ensures a single stream exists and matches expectations.
     *
     * BEHAVIOR
     * --------
     * - If stream exists:
     *     → Validate immutability
     * - If stream does not exist:
     *     → Create it
     *
     * FAILURE MODEL
     * -------------
     * - Auth errors → fail immediately
     * - Connectivity issues → fail immediately
     * - Config drift:
     *     → fail OR warn depending on bootstrapProps
     */
    private void ensureStream(JetStreamStreamsProperties.StreamSpec spec) throws Exception {
        StreamConfiguration desired = toStreamConfig(spec);

        try {
            StreamInfo existing = jsm.getStreamInfo(desired.getName());
            validateExisting(desired, existing);
            return;
        } catch (JetStreamApiException e) {

            // Only create stream if it truly does not exist.
            // Do NOT mask permission or infrastructure failures.
            if (!isStreamNotFound(e)) {
                throw e;
            }
        }

        // Stream does not exist → create it
        jsm.addStream(desired);

        log.info(
                "Created JetStream stream: {} (subjects={}, maxAge={}, retention={}, storage={}, replicas={}, placementTags={})",
                desired.getName(),
                desired.getSubjects(),
                desired.getMaxAge(),
                desired.getRetentionPolicy(),
                desired.getStorageType(),
                desired.getReplicas(),
                desired.getPlacement() == null
                        ? List.of()
                        : desired.getPlacement().getTags()
        );
    }

    /**
     * Validates that an existing stream configuration
     * matches the expected immutable configuration.
     *
     * WHY STRICT
     * ----------
     * Changing stream properties after data exists can:
     *  - Break replay guarantees
     *  - Orphan messages
     *  - Invalidate consumer semantics
     *
     * Therefore:
     *  - Differences are explicitly detected
     *  - Operator chooses: FAIL or WARN
     */
    private void validateExisting(StreamConfiguration desired, StreamInfo existing) {

        StreamConfiguration actual = existing.getConfiguration();
        List<String> diffs = new ArrayList<>();

        if (!Objects.equals(actual.getRetentionPolicy(), desired.getRetentionPolicy())) {
            diffs.add("retentionPolicy actual=" + actual.getRetentionPolicy()
                    + " expected=" + desired.getRetentionPolicy());
        }

        if (!Objects.equals(actual.getStorageType(), desired.getStorageType())) {
            diffs.add("storageType actual=" + actual.getStorageType()
                    + " expected=" + desired.getStorageType());
        }

        if (!Objects.equals(actual.getMaxAge(), desired.getMaxAge())) {
            diffs.add("maxAge actual=" + actual.getMaxAge()
                    + " expected=" + desired.getMaxAge());
        }

        if (actual.getReplicas() != desired.getReplicas()) {
            diffs.add("replicas actual=" + actual.getReplicas()
                    + " expected=" + desired.getReplicas());
        }

        if (!setEquals(actual.getSubjects(), desired.getSubjects())) {
            diffs.add("subjects actual=" + actual.getSubjects()
                    + " expected=" + desired.getSubjects());
        }

        List<String> actualTags =
                actual.getPlacement() == null ? List.of() : actual.getPlacement().getTags();
        List<String> desiredTags =
                desired.getPlacement() == null ? List.of() : desired.getPlacement().getTags();

        if (!setEquals(actualTags, desiredTags)) {
            diffs.add("placementTags actual=" + actualTags
                    + " expected=" + desiredTags);
        }

        if (diffs.isEmpty()) {
            log.info("JetStream stream exists and matches config: {} (subjects={}, placement={})",
                    desired.getName(),
                    actual.getSubjects(),
                    actual.getPlacement());
            return;
        }

        String msg =
                "JetStream stream exists but differs from expected: "
                        + desired.getName()
                        + " :: "
                        + String.join("; ", diffs);

        if (bootstrapProps.isFailOnMismatch()) {
            throw new IllegalStateException(msg);
        }

        log.warn(msg);
    }

    /**
     * Determines whether an exception indicates
     * a missing stream vs a real failure.
     */
    private static boolean isStreamNotFound(JetStreamApiException e) {
        return e.getApiErrorCode() == JS_STREAM_NOT_FOUND_ERR;
    }

    /**
     * Order-insensitive list comparison.
     *
     * Used for:
     *  - Subjects
     *  - Placement tags
     */
    private static boolean setEquals(List<String> a, List<String> b) {
        Set<String> sa = new HashSet<>(a == null ? List.of() : a);
        Set<String> sb = new HashSet<>(b == null ? List.of() : b);
        return sa.equals(sb);
    }

    /**
     * Converts declarative StreamSpec → JetStream StreamConfiguration.
     *
     * This is the ONLY place where configuration translation occurs.
     */
    private static StreamConfiguration toStreamConfig(
            JetStreamStreamsProperties.StreamSpec spec) {

        String name = require(spec.getName(), "name");

        List<String> subjects = spec.getSubjects();
        if (subjects == null || subjects.isEmpty()) {
            throw new IllegalArgumentException(
                    "subjects is required for stream " + name);
        }

        Duration maxAge =
                Objects.requireNonNull(spec.getMaxAge(),
                        "maxAge is required for stream " + name);

        RetentionPolicy rp =
                parseRetentionPolicy(spec.getRetentionPolicy());
        StorageType st =
                parseStorageType(spec.getStorageType());

        StreamConfiguration.Builder b =
                StreamConfiguration.builder()
                        .name(name)
                        .subjects(subjects.toArray(String[]::new))
                        .retentionPolicy(rp)
                        .storageType(st)
                        .maxAge(maxAge)
                        .replicas(spec.getReplicas());

        List<String> tags = spec.getPlacementTags();
        if (tags != null && !tags.isEmpty()) {
            b.placement(
                    Placement.builder()
                            .tags(tags.toArray(String[]::new))
                            .build()
            );
        }

        return b.build();
    }

    /** Simple non-null, non-blank guard */
    private static String require(String value, String fieldName) {
        if (value == null || value.isBlank()) {
            throw new IllegalArgumentException(fieldName + " is required");
        }
        return value;
    }

    /**
     * Parses retention policy with safe defaults.
     *
     * Default: WorkQueue (MANDATORY for SYNC_MGMT)
     */
    private static RetentionPolicy parseRetentionPolicy(String value) {
        if (value == null || value.isBlank()) {
            return RetentionPolicy.WorkQueue;
        }
        String v = value.trim().toLowerCase();
        return switch (v) {
            case "workqueue", "work_queue", "work-queue" -> RetentionPolicy.WorkQueue;
            case "limits" -> RetentionPolicy.Limits;
            case "interest" -> RetentionPolicy.Interest;
            default -> throw new IllegalArgumentException(
                    "Unsupported retentionPolicy: " + value);
        };
    }

    /**
     * Parses storage type with safe defaults.
     *
     * Default: File (durability-first)
     */
    private static StorageType parseStorageType(String value) {
        if (value == null || value.isBlank()) {
            return StorageType.File;
        }
        String v = value.trim().toLowerCase();
        return switch (v) {
            case "file" -> StorageType.File;
            case "memory" -> StorageType.Memory;
            default -> throw new IllegalArgumentException(
                    "Unsupported storageType: " + value);
        };
    }
}
