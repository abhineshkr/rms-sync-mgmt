package com.rms.sync.poc.consumer;

import com.rms.sync.jetstream.config.SyncMgmtProperties;
import com.rms.sync.jetstream.naming.ConsumerName;
import io.nats.client.JetStream;
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
import org.springframework.stereotype.Component;
import reactor.core.Disposable;
import reactor.core.publisher.Flux;
import reactor.core.scheduler.Schedulers;

import java.nio.charset.StandardCharsets;
import java.time.Duration;

/**
 * Demonstrates the LOCKED consumer model:
 * - Durable consumer
 * - Explicit ACK
 * - Pull-based only
 */
@Component
@ConditionalOnProperty(prefix = "syncmgmt.demo-consumer", name = "enabled", havingValue = "true", matchIfMissing = true)
public class DemoPullConsumer implements DisposableBean {

    private static final Logger log = LoggerFactory.getLogger(DemoPullConsumer.class);

    private final Disposable subscription;

    public DemoPullConsumer(
            JetStream js,
            SyncMgmtProperties props,
            @Value("${syncmgmt.demo-consumer.stream:LEAF_STREAM}") String stream,
            @Value("${syncmgmt.demo-consumer.filter-subject:leaf.>}") String filterSubject,
            @Value("${syncmgmt.demo-consumer.poll-interval:1s}") Duration pollInterval,
            @Value("${syncmgmt.demo-consumer.batch-size:10}") int batchSize
    ) throws Exception {

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

        JetStreamSubscription sub = js.subscribe(filterSubject, pso);
        log.info("Demo pull-consumer started: stream={} filter={} durable={}", stream, filterSubject, durable);

        this.subscription = Flux.interval(pollInterval)
                .publishOn(Schedulers.boundedElastic())
                .doOnNext(tick -> sub.pull(batchSize))
                .flatMap(tick -> Flux.generate(sink -> {
                    try {
                        Message m = sub.nextMessage(Duration.ofMillis(100));
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
                .onErrorContinue((err, o) -> log.warn("Consumer error: {}", err.getMessage(), err))
                .subscribe();
    }

    @Override
    public void destroy() {
        if (subscription != null && !subscription.isDisposed()) {
            subscription.dispose();
        }
    }
}
