package com.rms.sync.core.publisher;

import com.rms.sync.core.model.OutboxEvent;
import reactor.core.publisher.Mono;

/**
 * Publishes events to the underlying transport (JetStream for this project).
 */
public interface SyncPublisher {
    Mono<Void> publish(OutboxEvent event);
}
