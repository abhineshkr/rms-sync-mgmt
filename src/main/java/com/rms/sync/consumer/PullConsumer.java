package com.rms.sync.consumer;

import com.rms.sync.jetstream.bootstrap.JetStreamBootstrapCompleteEvent;
import com.rms.sync.jetstream.config.SyncMgmtProperties;
import com.rms.sync.jetstream.naming.ConsumerName;
import io.nats.client.*;
import io.nats.client.api.*;
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
import reactor.core.publisher.Mono;
import reactor.core.scheduler.Schedulers;

import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Production-grade pull consumer that:
 * <ul>
 *   <li>Uses a <b>durable</b> consumer name derived from node identity.</li>
 *   <li>Uses <b>explicit ACK</b> for reliable progress tracking and redelivery on failure.</li>
 *   <li>Uses <b>pull-based consumption</b> to control backpressure and avoid push overload.</li>
 *   <li>Starts only after the application is ready, and will <b>retry safely</b> until the stream exists.</li>
 * </ul>
 *
 * <h2>Operational behavior</h2>
 * <ul>
 *   <li>Never crashes the Spring context if JetStream resources are not ready.</li>
 *   <li>Retries subscription creation with a bounded, logged backoff.</li>
 *   <li>Cleans up on shutdown.</li>
 * </ul>
 *
 * <h2>Notes</h2>
 * <ul>
 *   <li>Do not subscribe in the constructor (avoids startup ordering races).</li>
 *   <li>Subscription is created lazily and recreated on recoverable failures.</li>
 * </ul>
 */
@Component
@ConditionalOnProperty(prefix = "syncmgmt.consumer", name = "enabled", havingValue = "true", matchIfMissing = false)
public class PullConsumer implements DisposableBean {

    private static final Logger log = LoggerFactory.getLogger(PullConsumer.class);

    /**
     * JetStream API error code for "stream not found".
     * Used to classify failures as recoverable during startup / provisioning windows.
     */
    private static final int JS_STREAM_NOT_FOUND_ERR = 10059;

    /**
     * Time between subscription creation attempts while waiting for stream/consumer availability.
     */
    private static final Duration SUBSCRIBE_RETRY_INTERVAL = Duration.ofSeconds(2);

    /**
     * Max time to wait on each nextMessage() poll before looping.
     * Short polling keeps shutdown responsive and avoids long blocking.
     */
    private static final Duration NEXT_MESSAGE_POLL = Duration.ofMillis(250);

    private final JetStream js;
    private final SyncMgmtProperties props;

    private final String stream;
    private final String filterSubject;
    private final Duration pollInterval;
    private final int batchSize;

    /**
     * Holds the running Reactor subscription so start/stop is idempotent and thread-safe.
     */
    private final AtomicReference<Disposable> running = new AtomicReference<>();

    public PullConsumer(
            JetStream js,
            SyncMgmtProperties props,
            @Value("${syncmgmt.consumer.stream:UP_LEAF_STREAM}") String stream,
            @Value("${syncmgmt.consumer.filter-subject:up.leaf.>}") String filterSubject,
            @Value("${syncmgmt.consumer.poll-interval:1s}") Duration pollInterval,
            @Value("${syncmgmt.consumer.batch-size:10}") int batchSize
    ) {
        this.js = js;
        this.props = props;
        this.stream = stream;
        this.filterSubject = filterSubject;
        this.pollInterval = pollInterval;
        this.batchSize = batchSize;
    }

    /**
     * Starts the consumer when the application is ready.
     *
     * <p>We also start when a JetStream bootstrap completion event is observed (if the app publishes it),
     * but we do not rely solely on it—production deployments may disable bootstrapping.</p>
     */
    @EventListener(ApplicationReadyEvent.class)
    public void onAppReady() {
        startIfNotStarted();
    }

    /**
     * Optional hook if the application publishes a "bootstrap complete" event.
     * Safe to call multiple times; start is idempotent.
     */
    @EventListener(JetStreamBootstrapCompleteEvent.class)
    public void onBootstrapComplete() {
        startIfNotStarted();
    }

    /**
     * Idempotently starts the reactive consumption loop.
     *
     * <p>Design goals:</p>
     * <ul>
     *   <li>No duplicate loops</li>
     *   <li>No startup crashes if resources aren't ready</li>
     *   <li>Recoverable retries with logging</li>
     * </ul>
     */
    private void startIfNotStarted() {
        if (running.get() != null) {
            return;
        }

        // Durable consumer name derived from node identity.
        final String durable = ConsumerName.of(
                props.getTier(),
                props.getZone(),
                props.getSubzone(),
                props.getNodeId()
        );

        // Consumer configuration:
        // - Durable: stable identity for idempotency and resume
        // - Explicit ACK: ensures server tracks progress and redelivers on failure
        // - DeliverPolicy.All: replay from the beginning for a newly created consumer
        final ConsumerConfiguration consumerConfig = ConsumerConfiguration.builder()
                .durable(durable)
                .deliverPolicy(DeliverPolicy.All)
                .replayPolicy(ReplayPolicy.Instant)
                .ackPolicy(AckPolicy.Explicit)
                .filterSubject(filterSubject)
                .build();

        final PullSubscribeOptions pso = PullSubscribeOptions.builder()
                .stream(stream)
                .configuration(consumerConfig)
                .build();

        // Single top-level loop:
        // - Try to subscribe (recoverable errors => retry)
        // - Once subscribed, run a poll loop pulling batches at pollInterval
        // - On recoverable failure, go back to subscribe
        Disposable d = Flux.interval(Duration.ZERO, SUBSCRIBE_RETRY_INTERVAL)
                .publishOn(Schedulers.boundedElastic()) // isolate blocking NATS calls
                .concatMap(tick -> subscribeAndConsumeOnce(pso, durable)
                        // If we successfully subscribed, we don't want another subscribe attempt in parallel.
                        // So we complete this Mono only when the subscription ends or errors.
                        .onErrorResume(err -> {
                            // If consumption ends due to error, log and allow outer loop to retry.
                            log.warn("Consumer loop ended with error. Will retry subscription. stream={} durable={} err={}",
                                    stream, durable, err.toString());
                            return Mono.empty();
                        }))
                .subscribe(
                        v -> { /* nothing; consumption side-effects happen inside */ },
                        err -> log.error("Consumer supervisor terminated unexpectedly: {}", err.toString(), err)
                );

        running.compareAndSet(null, d);
    }

    /**
     * Subscribes (creating/updating the durable consumer if needed), then runs the pull/ack loop.
     * Returns a Mono that completes only when the subscription is terminated.
     *
     * <p>This design makes it easy for an outer retry loop to re-enter on recoverable errors.</p>
     */
    private Mono<Void> subscribeAndConsumeOnce(PullSubscribeOptions pso, String durable) {
        return Mono.fromCallable(() -> {
                    try {
                        JetStreamSubscription sub = js.subscribe(filterSubject, pso);
                        log.info("Subscribed: stream={} filter={} durable={}", stream, filterSubject, durable);
                        return sub;
                    } catch (JetStreamApiException jse) {
                        // Stream not found: typical during provisioning windows -> recoverable
                        if (jse.getApiErrorCode() == JS_STREAM_NOT_FOUND_ERR) {
                            log.warn("Waiting for stream to exist: stream={}. Will retry...", stream);
                            return null; // handled below as "no subscription"
                        }
                        throw jse;
                    }
                })
                .flatMap(sub -> {
                    if (sub == null) {
                        // No subscription created (recoverable). Complete so outer loop retries.
                        return Mono.empty();
                    }

                    // Consume until error or cancellation; always ensure unsubscribe.
                    return consumePullLoop(sub)
                            .doFinally(sig -> {
                                try {
                                    sub.unsubscribe();
                                } catch (Exception e) {
                                    log.debug("Unsubscribe failed (ignored): {}", e.toString());
                                }
                            });
                });
    }

    /**
     * Runs the pull loop for an existing subscription:
     * - periodically requests a batch via pull(batchSize)
     * - drains messages using short nextMessage polls
     * - ACKs each successfully processed message
     *
     * <p><b>Error handling policy</b></p>
     * <ul>
     *   <li>If processing of an individual message fails, we log it and continue.</li>
     *   <li>If the subscription fails (e.g., connection issue), the error propagates to trigger resubscribe.</li>
     * </ul>
     */
    private Mono<Void> consumePullLoop(JetStreamSubscription sub) {
        return Flux.interval(pollInterval)
                .publishOn(Schedulers.boundedElastic()) // nextMessage() is blocking
                .doOnNext(t -> {
                    try {
                        sub.pull(batchSize);
                    } catch (Exception e) {
                        // Fail fast: let resubscribe happen.
                        throw new RuntimeException("pull() failed: " + e.getMessage(), e);
                    }
                })
                .concatMap(t -> Flux.generate(sink -> {
                    try {
                        Message m = sub.nextMessage(NEXT_MESSAGE_POLL);
                        if (m == null) {
                            sink.complete(); // end this drain cycle; next interval triggers another pull
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
                    // Keep message handling minimal and robust; treat failures per-message.
                    try {
                        String subject = msg.getSubject();
                        String body = new String(msg.getData(), StandardCharsets.UTF_8);

                        log.info("Consumed subject={} bytes={} body={}", subject, msg.getData().length, body);

                        // Explicit ACK: marks the message as processed and advances the consumer state.
                        msg.ack();
                    } catch (Exception e) {
                        // We intentionally do NOT ack on failure, so the server can redeliver later.
                        log.warn("Message handling failed; message not acked. err={}", e.toString(), e);
                    }
                })
                .then();
    }

    /**
     * Called during Spring shutdown.
     * Ensures the reactive loop is cancelled and resources can be released quickly.
     */
    @Override
    public void destroy() {
        Disposable d = running.getAndSet(null);
        if (d != null && !d.isDisposed()) {
            d.dispose();
        }
    }
}
