package com.rms.sync.poc.relay;

import java.time.Duration;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.event.EventListener;
import org.springframework.stereotype.Component;

import com.rms.sync.core.subject.OriginTier;
import com.rms.sync.core.subject.SyncDirection;
import com.rms.sync.core.subject.SyncSubject;
import com.rms.sync.jetstream.config.JetStreamStreamsProperties;
import com.rms.sync.jetstream.config.SyncMgmtProperties;
import com.rms.sync.jetstream.naming.ConsumerName;

import io.nats.client.JetStream;
import io.nats.client.JetStreamApiException;
import io.nats.client.JetStreamSubscription;
import io.nats.client.Message;
import io.nats.client.PublishOptions;
import io.nats.client.PullSubscribeOptions;
import io.nats.client.api.AckPolicy;
import io.nats.client.api.ConsumerConfiguration;
import io.nats.client.api.DeliverPolicy;
import io.nats.client.api.ReplayPolicy;
import io.nats.client.impl.Headers;
import reactor.core.Disposable;
import reactor.core.publisher.Flux;
import reactor.core.scheduler.Schedulers;

/**
 * Phase-3 adjacency relay.
 *
 * Runs on intermediate tiers (subzone, zone). Each relay link:
 * - pulls from the upstream/downstream neighbor stream
 * - republishes to the next hop stream with a rewritten canonical subject
 * - ACKs the consumed message only after successful publish
 */
@Component
@ConditionalOnProperty(prefix = "syncmgmt.relay", name = "enabled", havingValue = "true", matchIfMissing = false)
public class SyncRelay {

    private static final Logger log = LoggerFactory.getLogger(SyncRelay.class);

    // JetStream API error code for "stream not found"
    private static final int JS_STREAM_NOT_FOUND_ERR = 10059;

    private static final String HDR_MSG_ID = "Nats-Msg-Id";

    private final JetStream js;
    private final SyncMgmtProperties id;
    private final SyncRelayProperties props;
    private final JetStreamStreamsProperties streams;

    /**
     * Bootstrap retry loop. Used only to (re)attempt link startup until the required streams exist.
     * Individual link poll loops are independent and continue running after bootstrap completes.
     */
    private final AtomicReference<Disposable> bootstrapRetry = new AtomicReference<>();

    /** Guard to ensure startOnReady is idempotent even if invoked multiple times. */
    private final AtomicBoolean started = new AtomicBoolean(false);

    /** Tracks links that have been successfully started to prevent duplicate subscriptions/poll loops. */
    private final Set<String> startedLinks = ConcurrentHashMap.newKeySet();

    public SyncRelay(JetStream js, SyncMgmtProperties id, SyncRelayProperties props, JetStreamStreamsProperties streams) {
        this.js = js;
        this.id = id;
        this.props = props;
        this.streams = streams;
    }

    @EventListener(ApplicationReadyEvent.class)
    public void startOnReady() {
        if (!started.compareAndSet(false, true)) {
            return;
        }

        String tier = id.getTier();
        if (!("zone".equalsIgnoreCase(tier) || "subzone".equalsIgnoreCase(tier))) {
            log.info("SyncRelay disabled for tier={} (relay runs only on zone/subzone)", tier);
            return;
        }

        Disposable d = Flux.interval(Duration.ZERO, Duration.ofSeconds(2))
                .publishOn(Schedulers.boundedElastic())
                .flatMap(tick -> Flux.defer(() -> {
                    try {
                        boolean done = runOnce();
                        if (done) {
                            Disposable r = bootstrapRetry.getAndSet(null);
                            if (r != null) {
                                r.dispose();
                            }
                            log.info("SyncRelay bootstrap complete (all required links started)");
                        }
                        return Flux.empty();
                    } catch (JetStreamApiException jse) {
                        if (jse.getApiErrorCode() == JS_STREAM_NOT_FOUND_ERR) {
                            log.warn("SyncRelay waiting: stream not found yet. Will retry...");
                            return Flux.empty();
                        }
                        return Flux.error(jse);
                    } catch (Exception e) {
                        return Flux.error(e);
                    }
                }))
                .subscribe(
                        v -> { },
                        err -> log.error("SyncRelay failed permanently: {}", err.getMessage(), err)
                );

        bootstrapRetry.compareAndSet(null, d);
    }

    /**
     * Attempts to start all links required for this node.
     *
     * @return true when all required links have been started.
     */
    private boolean runOnce() throws Exception {
        String tier = id.getTier().toLowerCase();
        if ("subzone".equals(tier)) {
            startLinkUpFromLeaf();
            startLinkDownFromZone();
            return requiredLinksStarted("up-from-leaf", "down-from-zone");
        }
        if ("zone".equals(tier)) {
	            // A zone can simultaneously have subzones and directly attached leaf nodes.
	            // Always start DOWN from central, and always start the leaf-direct UP link.
	            startLinkDownFromCentral();
	            startLinkUpFromLeafDirect();
	
	            if (props.isZoneHasSubzones()) {
	                startLinkUpFromSubzone();
	                return requiredLinksStarted("up-from-subzone", "up-from-leaf-direct", "down-from-central");
	            }
	            return requiredLinksStarted("up-from-leaf-direct", "down-from-central");
        }
        return true;
    }

    private boolean requiredLinksStarted(String... keys) {
        for (String k : keys) {
            String durable = durableFor(k);
            if (!startedLinks.contains(durable)) {
                return false;
            }
        }
        return true;
    }

    private String durableFor(String linkKey) {
        return switch (linkKey) {
            case "up-from-leaf" -> ConsumerName.ofLink(id.getTier(), id.getZone(), id.getSubzone(), id.getNodeId(), "up", "leaf");
            case "up-from-subzone" -> ConsumerName.ofLink(id.getTier(), id.getZone(), id.getSubzone(), id.getNodeId(), "up", "subzone");
            case "up-from-leaf-direct" -> ConsumerName.ofLink(id.getTier(), id.getZone(), id.getSubzone(), id.getNodeId(), "up", "leaf");
            case "down-from-central" -> ConsumerName.ofLink(id.getTier(), id.getZone(), id.getSubzone(), id.getNodeId(), "down", "central");
            case "down-from-zone" -> ConsumerName.ofLink(id.getTier(), id.getZone(), id.getSubzone(), id.getNodeId(), "down", "zone");
            default -> throw new IllegalArgumentException("Unknown linkKey: " + linkKey);
        };
    }

    private String streamNameOrDefault(JetStreamStreamsProperties.StreamSpec spec, String fallback) {
        if (spec != null && spec.getName() != null && !spec.getName().isBlank()) {
            return spec.getName();
        }
        return fallback;
    }

    private String upLeafStream() {
        return streamNameOrDefault(streams.getStreams().getUpLeaf(), "UP_LEAF_STREAM");
    }

    private String upSubzoneStream() {
        return streamNameOrDefault(streams.getStreams().getUpSubzone(), "UP_SUBZONE_STREAM");
    }

    private String upZoneStream() {
        return streamNameOrDefault(streams.getStreams().getUpZone(), "UP_ZONE_STREAM");
    }

    private String downCentralStream() {
        return streamNameOrDefault(streams.getStreams().getDownCentral(), "DOWN_CENTRAL_STREAM");
    }

    private String downZoneStream() {
        return streamNameOrDefault(streams.getStreams().getDownZone(), "DOWN_ZONE_STREAM");
    }

    private String downSubzoneStream() {
        return streamNameOrDefault(streams.getStreams().getDownSubzone(), "DOWN_SUBZONE_STREAM");
    }

    private void startLinkUpFromLeaf() throws Exception {
        String durable = durableFor("up-from-leaf");
        startLinkOnce(
                durable,
                /*inStream*/ upLeafStream(),
                /*inFilter*/ "up.leaf." + id.getZone() + "." + id.getSubzone() + ".>",
                /*outTier*/ OriginTier.subzone,
                /*outStream*/ upSubzoneStream(),
                /*outDir*/ SyncDirection.up
        );
    }

    private void startLinkUpFromSubzone() throws Exception {
        String durable = durableFor("up-from-subzone");
        startLinkOnce(
                durable,
                /*inStream*/ upSubzoneStream(),
                /*inFilter*/ "up.subzone." + id.getZone() + ".>",
                /*outTier*/ OriginTier.zone,
                /*outStream*/ upZoneStream(),
                /*outDir*/ SyncDirection.up
        );
    }

    private void startLinkUpFromLeafDirect() throws Exception {
        String durable = durableFor("up-from-leaf-direct");
        startLinkOnce(
                durable,
                // Leaf nodes attached at the zone publish into the zone's UP_SUBZONE_STREAM
                // (same stream family for all upstream inputs at the zone).
                /*inStream*/ upSubzoneStream(),
                /*inFilter*/ "up.leaf." + id.getZone() + ".>",
                /*outTier*/ OriginTier.zone,
                /*outStream*/ upZoneStream(),
                /*outDir*/ SyncDirection.up
        );
    }

    private void startLinkDownFromCentral() throws Exception {
        String durable = durableFor("down-from-central");
        startLinkOnce(
                durable,
                /*inStream*/ downCentralStream(),
                /*inFilter*/ "down.central." + id.getZone() + ".>",
                /*outTier*/ OriginTier.zone,
                /*outStream*/ downZoneStream(),
                /*outDir*/ SyncDirection.down
        );
    }

    private void startLinkDownFromZone() throws Exception {
        String durable = durableFor("down-from-zone");
        startLinkOnce(
                durable,
                /*inStream*/ downZoneStream(),
                /*inFilter*/ "down.zone." + id.getZone() + "." + id.getSubzone() + ".>",
                /*outTier*/ OriginTier.subzone,
                /*outStream*/ downSubzoneStream(),
                /*outDir*/ SyncDirection.down
        );
    }

    private void startLinkOnce(String durable,
                              String inStream, String inFilter,
                              OriginTier outTier, String outStream, SyncDirection outDir) throws Exception {

        if (startedLinks.contains(durable)) {
            return;
        }

        startLink(inStream, inFilter, durable, outTier, outStream, outDir);
        startedLinks.add(durable);
    }

    private void startLink(String inStream, String inFilter, String durable,
                           OriginTier outTier, String outStream, SyncDirection outDir) throws Exception {

        ConsumerConfiguration cc = ConsumerConfiguration.builder()
                .durable(durable)
                .deliverPolicy(DeliverPolicy.All)
                .replayPolicy(ReplayPolicy.Instant)
                .ackPolicy(AckPolicy.Explicit)
                .filterSubject(inFilter)
                .build();

        PullSubscribeOptions pso = PullSubscribeOptions.builder()
                .stream(inStream)
                .configuration(cc)
                .build();

        JetStreamSubscription sub = js.subscribe(inFilter, pso);

        log.info("SyncRelay link started: inStream={} inFilter={} durable={} -> outStream={} outTier={} outDir={}",
                inStream, inFilter, durable, outStream, outTier, outDir);

        int batch = Math.max(1, props.getBatchSize());
        Duration poll = Duration.ofMillis(Math.max(100, props.getPollIntervalMs()));

        // Dedicated poll loop per link.
        Flux.interval(poll)
                .publishOn(Schedulers.boundedElastic())
                .doOnNext(x -> sub.pull(batch))
                .flatMap(x -> Flux.generate(sink -> {
                    try {
                        Message m = sub.nextMessage(Duration.ofMillis(150));
                        if (m == null) {
                            sink.complete();
                        } else {
                            sink.next(m);
                        }
                    } catch (InterruptedException ie) {
                        Thread.currentThread().interrupt();
                        sink.complete();
                    } catch (Exception e) {
                        sink.error(e);
                    }
                }))
                .cast(Message.class)
                .flatMap(msg -> Flux.defer(() -> {
                    try {
                        relayOne(msg, outDir, outTier, outStream);
                        return Flux.empty();
                    } catch (Exception e) {
                        return Flux.error(e);
                    }
                }))
                .onErrorContinue((err, o) -> log.warn("SyncRelay link error: {}", err.getMessage(), err))
                .subscribe();
    }

    private void relayOne(Message msg, SyncDirection outDir, OriginTier outTier, String outStream) throws Exception {
        String inSubject = msg.getSubject();

        SyncSubject.Parsed p = SyncSubject.tryParse(inSubject);
        if (p == null) {
            throw new IllegalArgumentException("Relay received non-canonical subject (expected 8 tokens): " + inSubject);
        }

        // For downstream propagation, preserve the destination scope embedded in the subject (zone/subzone).
        // For upstream aggregation, use the local node identity.
        String outZone = (outDir == SyncDirection.down) ? p.zone : id.getZone();
        String outSubzone = (outDir == SyncDirection.down) ? p.subzone : id.getSubzone();

        // Preserve domain/entity/event from the canonical subject.
        String outSubject = SyncSubject.rewrite(
                inSubject,
                outDir,
                outTier,
                outZone,
                outSubzone,
                id.getNodeId()
        );

        Headers h = msg.getHeaders();
        String msgId = null;
        if (h != null) {
            try {
                msgId = h.getFirst(HDR_MSG_ID);
            } catch (Throwable ignored) {
                // older client versions
            }
        }

        PublishOptions.Builder pob = PublishOptions.builder();
        if (msgId != null && !msgId.isBlank()) {
            pob.messageId(msgId);
        }

        js.publish(outSubject, msg.getData(), pob.build());
        msg.ack();

        log.debug("Relayed {} -> {} (outStream={})", inSubject, outSubject, outStream);
    }
}
