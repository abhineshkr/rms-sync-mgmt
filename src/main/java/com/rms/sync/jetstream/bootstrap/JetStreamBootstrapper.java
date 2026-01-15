package com.rms.sync.jetstream.bootstrap;

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
import org.springframework.stereotype.Component;

import java.time.Duration;

/**
 * Ensures the standard streams exist (LOCKED):
 * - LEAF_STREAM    -> leaf.>
 * - ZONE_STREAM    -> zone.>
 * - CENTRAL_STREAM -> central.>
 *
 * Retention is WorkQueue (until all consumers ACK), with max ages per spec.
 *
 * Phase 3 (POC) guidance:
 * - Streams are tagged/placed to keep tier data "close" to tier nodes.
 * - This also makes the partition tests deterministic (e.g., LEAF_STREAM leadership
 *   stays in the leaf/subzone side when the Zone/Central link is cut).
 */
@Component
@ConditionalOnProperty(prefix = "syncmgmt.bootstrap", name = "enabled", havingValue = "true", matchIfMissing = true)
public class JetStreamBootstrapper implements ApplicationRunner {

    private static final Logger log = LoggerFactory.getLogger(JetStreamBootstrapper.class);

    private final JetStreamManagement jsm;

    public JetStreamBootstrapper(JetStreamManagement jsm) {
        this.jsm = jsm;
    }

    @Override
    public void run(ApplicationArguments args) throws Exception {
        ensureStream("LEAF_STREAM", "leaf.>", Duration.ofDays(30), "leaf");
        ensureStream("ZONE_STREAM", "zone.>", Duration.ofDays(60), "zone");
        ensureStream("CENTRAL_STREAM", "central.>", Duration.ofDays(90), "central");
    }

    private void ensureStream(String name, String subjectFilter, Duration maxAge, String placementTag) throws Exception {
        try {
            StreamInfo existing = jsm.getStreamInfo(name);
            log.info("JetStream stream exists: {} (subjects={}, placement={})",
                    name, existing.getConfiguration().getSubjects(), existing.getConfiguration().getPlacement());
            return;
        } catch (Exception ignored) {
            // create
        }

        StreamConfiguration cfg = StreamConfiguration.builder()
                .name(name)
                .subjects(subjectFilter)
                .retentionPolicy(RetentionPolicy.WorkQueue)
                .storageType(StorageType.File)
                .maxAge(maxAge)
                // POC: keep replicas=1 (matches the doc for LEAF; simplifies the 1x zone / 1x central topology)
                .replicas(1)
                .placement(Placement.builder().tags(placementTag).build())
                .build();

        jsm.addStream(cfg);
        log.info("Created JetStream stream: {} (subjects={}, maxAge={}, retention=WorkQueue, placementTag={})",
                name, subjectFilter, maxAge, placementTag);
    }
}
