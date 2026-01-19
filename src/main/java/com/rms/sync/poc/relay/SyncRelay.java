package com.rms.sync.poc.relay;

import com.rms.sync.core.subject.OriginTier;
import com.rms.sync.core.subject.SyncDirection;
import com.rms.sync.core.subject.SyncSubject;
import com.rms.sync.jetstream.config.SyncMgmtProperties;
import com.rms.sync.jetstream.naming.ConsumerName;
import io.nats.client.Headers;
import io.nats.client.JetStream;
import io.nats.client.JetStreamApiException;
import io.nats.client.JetStreamSubscription;
import io.nats.client.Message;
import io.nats.client.PullSubscribeOptions;
import io.nats.client.PublishOptions;
import io.nats.client.api.AckPolicy;
import io.nats.client.api.ConsumerConfiguration;
import io.nats.client.api.DeliverPolicy;
import io.nats.client.api.ReplayPolicy;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.event.EventListener;
import org.springframework.stereotype.Component;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import reactor.core.Disposable;
import reactor.core.publisher.Flux;
import reactor.core.scheduler.Schedulers;

import java.time.Duration;
import java.util.Objects;
import java.util.concurrent.atomic.AtomicReference;

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

    private final AtomicReference<Disposable> running = new AtomicReference<>();

    public SyncRelay(JetStream js, SyncMgmtProperties id, SyncRelayProperties props) {
        this.js = js;
        this.id = id;
        this.props = props;
    }

    @EventListener(ApplicationReadyEvent.class)
    public void startOnReady() {
        if (running.get() != null) return;

        String tier = id.getTier();
        if (!("zone".equalsIgnoreCase(tier) || "subzone".equalsIgnoreCase(tier))) {
            log.info("SyncRelay disabled for tier={} (relay runs only on zone/subzone)", tier);
            return;
        }

        Disposable d = Flux.interval(Duration.ZERO, Duration.ofSeconds(2))
                .publishOn(Schedulers.boundedElastic())
                .flatMap(tick -> Flux.defer(() -> {
                    try {
                        runOnce();
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

        running.compareAndSet(null, d);
    }

    private void runOnce() throws Exception {
        // We start link loops once, then keep them running.
        String tier = id.getTier().toLowerCase();
        if ("subzone".equals(tier)) {
            startLinkUpFromLeaf();
            startLinkDownFromZone();
        } else if ("zone".equals(tier)) {
            if (props.isZoneHasSubzones()) {
                startLinkUpFromSubzone();
            } else {
                startLinkUpFromLeafDirect();
            }
            startLinkDownFromCentral();
        }
    }

    private void startLinkUpFromLeaf() throws Exception {
        startLink(
                /*inStream*/ "UP_LEAF_STREAM",
                /*inFilter*/ "up.leaf." + id.getZone() + "." + id.getSubzone() + ".>",
                /*inDurable*/ ConsumerName.ofLink(id.getTier(), id.getZone(), id.getSubzone(), id.getNodeId(), "up", "leaf"),
                /*outTier*/ OriginTier.subzone,
                /*outStream*/ "UP_SUBZONE_STREAM",
                /*outDir*/ SyncDirection.up
        );
    }

    private void startLinkUpFromSubzone() throws Exception {
        startLink(
                /*inStream*/ "UP_SUBZONE_STREAM",
                /*inFilter*/ "up.subzone." + id.getZone() + ".>",
                /*inDurable*/ ConsumerName.ofLink(id.getTier(), id.getZone(), id.getSubzone(), id.getNodeId(), "up", "subzone"),
                /*outTier*/ OriginTier.zone,
                /*outStream*/ "UP_ZONE_STREAM",
                /*outDir*/ SyncDirection.up
        );
    }

    private void startLinkUpFromLeafDirect() throws Exception {
        startLink(
                /*inStream*/ "UP_LEAF_STREAM",
                /*inFilter*/ "up.leaf." + id.getZone() + ".>",
                /*inDurable*/ ConsumerName.ofLink(id.getTier(), id.getZone(), id.getSubzone(), id.getNodeId(), "up", "leaf"),
                /*outTier*/ OriginTier.zone,
                /*outStream*/ "UP_ZONE_STREAM",
                /*outDir*/ SyncDirection.up
        );
    }

    private void startLinkDownFromCentral() throws Exception {
        startLink(
                /*inStream*/ "DOWN_CENTRAL_STREAM",
                /*inFilter*/ "down.central." + id.getZone() + ".>",
                /*inDurable*/ ConsumerName.ofLink(id.getTier(), id.getZone(), id.getSubzone(), id.getNodeId(), "down", "central"),
                /*outTier*/ OriginTier.zone,
                /*outStream*/ "DOWN_ZONE_STREAM",
                /*outDir*/ SyncDirection.down
        );
    }

    private void startLinkDownFromZone() throws Exception {
        startLink(
                /*inStream*/ "DOWN_ZONE_STREAM",
                /*inFilter*/ "down.zone." + id.getZone() + "." + id.getSubzone() + ".>",
                /*inDurable*/ ConsumerName.ofLink(id.getTier(), id.getZone(), id.getSubzone(), id.getNodeId(), "down", "zone"),
                /*outTier*/ OriginTier.subzone,
                /*outStream*/ "DOWN_SUBZONE_STREAM",
                /*outDir*/ SyncDirection.down
        );
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
