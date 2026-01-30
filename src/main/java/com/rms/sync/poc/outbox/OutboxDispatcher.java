package com.rms.sync.poc.outbox;

import com.rms.sync.core.model.OutboxEvent;
import com.rms.sync.core.publisher.SyncPublisher;
import com.rms.sync.r2dbc.store.OutboxEventStore;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.DisposableBean;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.stereotype.Component;
import reactor.core.Disposable;
import reactor.core.publisher.Flux;

import java.time.Duration;

/**
 * Polls the outbox and publishes to JetStream outside of the business transaction.
 *
 * Publishing rule (LOCKED): Msg-Id == outbox_event.id, relying on JetStream dedup.
 */
@Component
@ConditionalOnProperty(prefix = "syncmgmt.outbox", name = "enabled", havingValue = "true", matchIfMissing = true)
public class OutboxDispatcher implements DisposableBean {

    private static final Logger log = LoggerFactory.getLogger(OutboxDispatcher.class);

    private final OutboxEventStore store;
    private final SyncPublisher publisher;
    private final int batchSize;
    private final Duration pollInterval;
    private final int maxRetries;

    private final Disposable subscription;

    public OutboxDispatcher(
            OutboxEventStore store,
            SyncPublisher publisher,
            @Value("${syncmgmt.outbox.batch-size:50}") int batchSize,
            @Value("${syncmgmt.outbox.poll-interval:2s}") Duration pollInterval,
            @Value("${syncmgmt.outbox.max-retries:5}") int maxRetries
    ) {
        this.store = store;
        this.publisher = publisher;
        this.batchSize = batchSize;
        this.pollInterval = pollInterval;
        this.maxRetries = maxRetries;

        this.subscription = Flux.interval(this.pollInterval)
                .flatMap(tick -> store.findPending(this.batchSize))
                .concatMap(this::publishOne)
                .onErrorContinue((err, o) -> log.warn("Outbox dispatcher error: {}", err.getMessage(), err))
                .subscribe();
    }

    private Flux<Void> publishOne(OutboxEvent e) {
        return publisher.publish(e)
                .then(store.markPublished(e.id()))
                .doOnError(err -> log.warn("Publish failed id={} subject={} err={}", e.id(), e.subject(), err.toString()))
                .onErrorResume(err -> {
                    int nextRetry = e.retryCount() + 1;
                    // Retry policy:
                    // - max-retries <= 0: retry forever (recommended for offline buffering tests)
                    // - max-retries  > 0: mark FAILED after exceeding the configured limit
                    if (maxRetries <= 0 || nextRetry <= maxRetries) {
                        return store.markPending(e.id(), nextRetry);
                    }
                    return store.markFailed(e.id(), nextRetry);
                })
                .flux();
    }

    @Override
    public void destroy() {
        if (subscription != null && !subscription.isDisposed()) {
            subscription.dispose();
        }
    }
}
