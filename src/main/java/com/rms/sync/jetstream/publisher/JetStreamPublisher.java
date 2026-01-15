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
 * Publishes to JetStream with deduplication (LOCKED rule):
 * - Msg-Id == outbox_event.id (uses PublishOptions.messageId)
 */
@Component
public class JetStreamPublisher implements SyncPublisher {

    private static final Logger log = LoggerFactory.getLogger(JetStreamPublisher.class);

    private final JetStream js;

    public JetStreamPublisher(JetStream js) {
        this.js = js;
    }

    @Override
    public Mono<Void> publish(OutboxEvent event) {
        return Mono.fromCallable(() -> {
                    PublishOptions opts = PublishOptions.builder()
                            .messageId(event.id().toString())
                            .build();

                    byte[] payload = event.payloadJson() == null
                            ? new byte[0]
                            : event.payloadJson().getBytes(StandardCharsets.UTF_8);

                    PublishAck ack = js.publish(event.subject(), payload, opts);
                    log.info("Published event id={} subject={} stream={} seq={}",
                            event.id(), event.subject(), ack.getStream(), ack.getSeqno());
                    return ack;
                })
                .subscribeOn(Schedulers.boundedElastic())
                .then();
    }
}
