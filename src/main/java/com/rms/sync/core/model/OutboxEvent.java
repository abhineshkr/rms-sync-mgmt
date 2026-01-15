package com.rms.sync.core.model;

import java.time.Instant;
import java.util.Map;
import java.util.UUID;

/**
 * Logical outbox event (transport-neutral).
 */
public record OutboxEvent(
        UUID id,
        String subject,
        String payloadJson,
        Map<String, Object> headers,
        OutboxStatus status,
        int retryCount,
        Instant createdAt,
        Instant publishedAt
) {}
