package com.rms.sync.r2dbc.service;

import org.springframework.stereotype.Service;

import com.rms.sync.r2dbc.store.OutboxEventStore;

import reactor.core.publisher.Mono;

import java.util.Map;
import java.util.UUID;

/**
 * Service for writing events to the outbox within a business transaction boundary.
 *
 * Publishing MUST occur outside the DB transaction; see sync-poc-app OutboxDispatcher.
 */
@Service
public class OutboxService {

    private final OutboxEventStore store;

    public OutboxService(OutboxEventStore store) {
        this.store = store;
    }

    public Mono<UUID> enqueue(String subject, String payloadJson, Map<String, Object> headers) {
        return store.insertPending(subject, payloadJson, headers);
    }
}
