package com.rms.sync.r2dbc.store;

import java.time.Instant;
import java.util.Map;
import java.util.UUID;

import org.springframework.r2dbc.core.DatabaseClient;
import org.springframework.stereotype.Repository;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.rms.sync.core.model.OutboxEvent;
import com.rms.sync.core.model.OutboxStatus;
import com.rms.sync.r2dbc.entity.OutboxEventEntity;

import reactor.core.publisher.Flux;
import reactor.core.publisher.Mono;

/**
 * Database access helper for the sync_outbox_event table.
 *
 * Spring Boot uses Jackson (com.fasterxml.jackson.*) and auto-configures a
 * ObjectMapper bean. JSONB is bound/read as String to avoid driver-specific Json
 * codec types.
 */
@Repository
public class OutboxEventStore {

	private final DatabaseClient db;
	private final ObjectMapper mapper;

	public OutboxEventStore(DatabaseClient db, ObjectMapper mapper) {
		this.db = db;
		this.mapper = mapper;
	}

	public Mono<UUID> insertPending(String subject, String payloadJson, Map<String, Object> headers) {
		UUID id = UUID.randomUUID();
		Instant now = Instant.now();

		String headersJson = (headers == null) ? null : write(headers);

		String sql = "INSERT INTO sync_outbox_event (id, subject, payload, headers, status, retry_count, created_at) "
				+ "VALUES (:id, :subject, :payload::jsonb, :headers::jsonb, :status, 0, :created_at)";

		DatabaseClient.GenericExecuteSpec spec = db.sql(sql).bind("id", id).bind("subject", subject)
				.bind("payload", safeJson(payloadJson)).bind("status", OutboxStatus.PENDING.name())
				.bind("created_at", now);

		if (headersJson == null) {
			spec = spec.bindNull("headers", String.class);
		} else {
			spec = spec.bind("headers", headersJson);
		}

		return spec.fetch().rowsUpdated().thenReturn(id);
	}

	public Flux<OutboxEvent> findPending(int limit) {
		String sql = "SELECT id, subject, payload, headers, status, retry_count, created_at, published_at "
				+ "FROM sync_outbox_event WHERE status = :status ORDER BY created_at ASC LIMIT :limit";

		return db.sql(sql).bind("status", OutboxStatus.PENDING.name()).bind("limit", limit).map((row, meta) -> {
			OutboxEventEntity e = new OutboxEventEntity();
			e.setId(row.get("id", UUID.class));
			e.setSubject(row.get("subject", String.class));

			// read JSONB as String (driver independent)
			e.setPayloadText(asString(row.get("payload")));
			e.setHeadersText(asString(row.get("headers")));

			e.setStatus(row.get("status", String.class));
			e.setRetryCount(row.get("retry_count", Integer.class));
			e.setCreatedAt(row.get("created_at", Instant.class));
			e.setPublishedAt(row.get("published_at", Instant.class));
			return toModel(e);
		}).all();
	}

	public Mono<Void> markPublished(UUID id) {
		String sql = "UPDATE sync_outbox_event SET status = :status, published_at = :published_at WHERE id = :id";
		return db.sql(sql).bind("status", OutboxStatus.PUBLISHED.name()).bind("published_at", Instant.now())
				.bind("id", id).fetch().rowsUpdated().then();
	}

	public Mono<Void> markFailed(UUID id, int retryCount) {
		String sql = "UPDATE sync_outbox_event SET status = :status, retry_count = :retry_count WHERE id = :id";
		return db.sql(sql).bind("status", OutboxStatus.FAILED.name()).bind("retry_count", retryCount).bind("id", id)
				.fetch().rowsUpdated().then();
	}

	public Mono<Void> markPending(UUID id, int retryCount) {
		String sql = "UPDATE sync_outbox_event SET status = :status, retry_count = :retry_count WHERE id = :id";
		return db.sql(sql).bind("status", OutboxStatus.PENDING.name()).bind("retry_count", retryCount).bind("id", id)
				.fetch().rowsUpdated().then();
	}

	private OutboxEvent toModel(OutboxEventEntity e) {
		String payload = (e.getPayloadText() == null || e.getPayloadText().isBlank()) ? "{}" : e.getPayloadText();

		Map<String, Object> headers = null;
		if (e.getHeadersText() != null && !e.getHeadersText().isBlank()) {
			try {
				@SuppressWarnings("unchecked")
				Map<String, Object> parsed = mapper.readValue(e.getHeadersText(), Map.class);
				headers = parsed;
			} catch (Exception ex) {
				headers = Map.of("header_parse_error", ex.getMessage());
			}
		}

		return new OutboxEvent(e.getId(), e.getSubject(), payload, headers, OutboxStatus.valueOf(e.getStatus()),
				e.getRetryCount() == null ? 0 : e.getRetryCount(), e.getCreatedAt(), e.getPublishedAt());
	}

	private String write(Map<String, Object> value) {
		try {
			return mapper.writeValueAsString(value);
		} catch (Exception e) {
			throw new IllegalArgumentException("Failed to serialize headers to JSON", e);
		}
	}

	private static String asString(Object v) {
		if (v == null)
			return null;
		if (v instanceof String s)
			return s;
		return String.valueOf(v);
	}

	private static String safeJson(String json) {
		if (json == null || json.isBlank())
			return "{}";
		return json;
	}
}