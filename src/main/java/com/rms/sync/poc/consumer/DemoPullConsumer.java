package com.rms.sync.poc.consumer;

import com.rms.sync.jetstream.bootstrap.JetStreamBootstrapCompleteEvent;
import com.rms.sync.jetstream.config.SyncMgmtProperties;
import com.rms.sync.jetstream.naming.ConsumerName;
import io.nats.client.JetStream;
import io.nats.client.JetStreamApiException;
import io.nats.client.JetStreamSubscription;
import io.nats.client.Message;
import io.nats.client.PullSubscribeOptions;
import io.nats.client.api.AckPolicy;
import io.nats.client.api.ConsumerConfiguration;
import io.nats.client.api.DeliverPolicy;
import io.nats.client.api.ReplayPolicy;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.DisposableBean;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.event.EventListener;
import org.springframework.stereotype.Component;
import reactor.core.Disposable;
import reactor.core.publisher.Flux;
import reactor.core.scheduler.Schedulers;

import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Demonstrates the LOCKED consumer model:
 * - Durable consumer
 * - Explicit ACK
 * - Pull-based only
 *
 * IMPORTANT:
 * - Do not subscribe in constructor (startup race with stream creation).
 * - Start after JetStreamBootstrapCompleteEvent, or retry safely.
 */
@Component
@ConditionalOnProperty(prefix = "syncmgmt.demo-consumer", name = "enabled", havingValue = "true", matchIfMissing = false)
public class DemoPullConsumer implements DisposableBean {

    private static final Logger log = LoggerFactory.getLogger(DemoPullConsumer.class);

    // JetStream API error code for "stream not found"
    private static final int JS_STREAM_NOT_FOUND_ERR = 10059;

    private final JetStream js;
    private final SyncMgmtProperties props;

    private final String stream;
    private final String filterSubject;
    private final Duration pollInterval;
    private final int batchSize;

    private final AtomicReference<Disposable> running = new AtomicReference<>();

    public DemoPullConsumer(
            JetStream js,
            SyncMgmtProperties props,
            @Value("${syncmgmt.demo-consumer.stream:UP_LEAF_STREAM}") String stream,
            @Value("${syncmgmt.demo-consumer.filter-subject:up.leaf.>}") String filterSubject,
            @Value("${syncmgmt.demo-consumer.poll-interval:1s}") Duration pollInterval,
            @Value("${syncmgmt.demo-consumer.batch-size:10}") int batchSize
    ) {
        this.js = js;
        this.props = props;
        this.stream = stream;
        this.filterSubject = filterSubject;
        this.pollInterval = pollInterval;
        this.batchSize = batchSize;
    }

    /**
     * Start only after the bootstrapper has ensured streams exist.
     * If bootstrap is disabled/misconfigured, we still retry safely rather than crash.
     */
    @EventListener(JetStreamBootstrapCompleteEvent.class)
    public void onBootstrapComplete() {
        startIfNotStarted();
    }

    /**
     * Also start on normal app startup.
     *
     * This eliminates the failure mode where bootstrap is disabled and the
     * {@link JetStreamBootstrapCompleteEvent} never fires, leaving no durable
     * consumer created. The subscribe loop is already safe and will retry until
     * the stream exists, so it is safe to start here.
     */
    @EventListener(ApplicationReadyEvent.class)
    public void onAppReady() {
        startIfNotStarted();
    }

    private void startIfNotStarted() {
        if (running.get() != null) {
            return;
        }

        String durable = ConsumerName.of(props.getTier(), props.getZone(), props.getSubzone(), props.getNodeId());
        ConsumerConfiguration cc = ConsumerConfiguration.builder()
                .durable(durable)
                .deliverPolicy(DeliverPolicy.All)
                .replayPolicy(ReplayPolicy.Instant)
                .ackPolicy(AckPolicy.Explicit)
                .build();

        PullSubscribeOptions pso = PullSubscribeOptions.builder()
                .stream(stream)
                .configuration(cc)
                .build();

        // Retry subscribe every 2s until stream exists; never fail the Spring context.
        Disposable d = Flux.interval(Duration.ZERO, Duration.ofSeconds(2))
                .publishOn(Schedulers.boundedElastic())
                .flatMap(tick -> Flux.defer(() -> {
                    try {
                        JetStreamSubscription sub = js.subscribe(filterSubject, pso);
                        log.info("DemoPullConsumer subscribed: stream={} filter={} durable={}", stream, filterSubject, durable);

                        // Poll loop
                        return Flux.interval(pollInterval)
                                .doOnNext(x -> sub.pull(batchSize))
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
                                .doOnNext(msg -> {
                                    String subject = msg.getSubject();
                                    String body = new String(msg.getData(), StandardCharsets.UTF_8);
                                    log.info("Consumed subject={} bytes={} body={}", subject, msg.getData().length, body);
                                    msg.ack();
                                })
                                .onErrorContinue((err, o) -> log.warn("DemoPullConsumer message handling error: {}", err.getMessage(), err));
                    } catch (JetStreamApiException jse) {
                        if (jse.getApiErrorCode() == JS_STREAM_NOT_FOUND_ERR) {
                            log.warn("DemoPullConsumer waiting: stream not found (stream={}). Will retry...", stream);
                            return Flux.empty();
                        }
                        return Flux.error(jse);
                    } catch (Exception e) {
                        return Flux.error(e);
                    }
                }))
                .subscribe(
                        v -> { },
                        err -> log.error("DemoPullConsumer failed permanently: {}", err.getMessage(), err)
                );

        running.compareAndSet(null, d);
    }

    @Override
    public void destroy() {
        Disposable d = running.getAndSet(null);
        if (d != null && !d.isDisposed()) {
            d.dispose();
        }
    }
}
