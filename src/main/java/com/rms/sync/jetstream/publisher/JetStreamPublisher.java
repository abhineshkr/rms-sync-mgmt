package com.rms.sync.jetstream.publisher;

import com.rms.sync.core.model.OutboxEvent;
import com.rms.sync.core.publisher.SyncPublisher;
import io.nats.client.JetStream;
import io.nats.client.PublishOptions;
import io.nats.client.api.PublishAck;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;
import reactor.core.publisher.Mono;
import reactor.core.scheduler.Schedulers;

import java.nio.charset.StandardCharsets;

/**
 * Reactive JetStream publisher implementation.
 *
 * <h2>Purpose</h2>
 * Bridges the application's outbox/event model to NATS JetStream by:
 * <ul>
 *   <li>Publishing events to a JetStream subject.</li>
 *   <li>Enforcing a strict de-duplication rule using JetStream message-id semantics.</li>
 *   <li>Exposing a non-blocking {@link Mono} API compatible with reactive pipelines.</li>
 * </ul>
 *
 * <h2>De-duplication rule (LOCKED)</h2>
 * <ul>
 *   <li>{@code Msg-Id == outbox_event.id}</li>
 *   <li>Implemented by setting {@link PublishOptions#messageId} to {@code event.id().toString()}.</li>
 * </ul>
 *
 * <p><b>Why this matters</b></p>
 * JetStream can treat publishes with the same message-id as duplicates (within its server-side de-dup window),
 * which helps keep publishing idempotent when the application retries (e.g., transient network failures,
 * process restarts after partial completion, at-least-once outbox dispatch).
 *
 * <h2>Threading / Reactive behavior</h2>
 * {@link JetStream#publish(String, byte[], PublishOptions)} is a blocking call (network round trip).
 * To avoid blocking Reactor event loop threads, the publish is executed on {@link Schedulers#boundedElastic()}.
 *
 * <h2>Logging</h2>
 * Logs the publish acknowledgment (stream name and sequence) for traceability and operational debugging.
 */
@Component
public class JetStreamPublisher implements SyncPublisher {

    private static final Logger log = LoggerFactory.getLogger(JetStreamPublisher.class);

    /**
     * The JetStream context used to publish messages.
     *
     * <p>Provided by Spring configuration and backed by a shared {@code Connection}.</p>
     */
    private final JetStream js;

    /**
     * Constructor injection to ensure this publisher is created with a ready-to-use JetStream context.
     */
    public JetStreamPublisher(JetStream js) {
        this.js = js;
    }

    /**
     * Publishes a single outbox event to JetStream.
     *
     * <p><b>Behavior</b></p>
     * <ul>
     *   <li>Uses {@code event.subject()} as the target subject.</li>
     *   <li>Uses {@code event.payloadJson()} as the message body (UTF-8).</li>
     *   <li>If payload is {@code null}, publishes an empty payload (zero-length byte array).</li>
     *   <li>Sets PublishOptions.messageId to {@code event.id().toString()} for server-side de-dup.</li>
     *   <li>Returns a {@code Mono<Void>} that completes when the publish succeeds.</li>
     * </ul>
     *
     * <p><b>Error handling</b></p>
     * Any exception thrown by the NATS client publish call will error the returned {@link Mono}.
     * Upstream layers can handle retry/backoff policies as appropriate.
     *
     * @param event the outbox event containing subject, id, and JSON payload
     * @return a Mono that completes when publishing finishes
     */
    @Override
    public Mono<Void> publish(OutboxEvent event) {
        return Mono.fromCallable(() -> {
                    // Build publish options with a deterministic message id.
                    // This is the core idempotency mechanism: retries with the same id become duplicates.
                    PublishOptions opts = PublishOptions.builder()
                            .messageId(event.id().toString())
                            .build();

                    // Convert JSON payload to bytes. JetStream accepts arbitrary bytes; UTF-8 is standard for JSON.
                    // If payload is null, we publish an empty body rather than failing.
                    byte[] payload = event.payloadJson() == null
                            ? new byte[0]
                            : event.payloadJson().getBytes(StandardCharsets.UTF_8);

                    // Blocking network call: publishes message and waits for server acknowledgment.
                    PublishAck ack = js.publish(event.subject(), payload, opts);

                    // Ack contains which stream accepted the message and its assigned sequence number.
                    // Useful for traceability and debugging.
                    log.info("Published event id={} subject={} stream={} seq={}",
                            event.id(), event.subject(), ack.getStream(), ack.getSeqno());

                    return ack;
                })
                // Ensure the blocking call does not run on Reactor event-loop threads.
                .subscribeOn(Schedulers.boundedElastic())
                // Convert Mono<PublishAck> to Mono<Void>, exposing only completion semantics to callers.
                .then();
    }
}
