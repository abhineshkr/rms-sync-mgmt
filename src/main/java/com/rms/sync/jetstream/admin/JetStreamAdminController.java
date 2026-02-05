package com.rms.sync.jetstream.admin;

import com.fasterxml.jackson.databind.annotation.JsonDeserialize;
import com.rms.sync.jetstream.admin.FlexibleDurationDeserializer;

import io.nats.client.*;
import io.nats.client.api.*;
import jakarta.validation.Valid;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.validation.annotation.Validated;
import org.springframework.web.bind.annotation.*;

import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Locale;
import java.util.UUID;

/**
 * Administrative JetStream endpoints intended for operational support and
 * controlled automation.
 *
 * Production posture: - Disabled by default (must be explicitly enabled via
 * config). - Should be protected by authentication/authorization (e.g., Spring
 * Security) and/or network controls. - Uses stable DTO responses (not ad-hoc
 * maps) for forward-compatible clients.
 *
 * Enable explicitly: syncmgmt.admin.enabled=true
 */
@RestController
@RequestMapping(path = "/admin/jetstream", produces = MediaType.APPLICATION_JSON_VALUE)
@ConditionalOnProperty(prefix = "syncmgmt.admin", name = "enabled", havingValue = "true", matchIfMissing = false)
@Validated
public class JetStreamAdminController {

	private static final Logger log = LoggerFactory.getLogger(JetStreamAdminController.class);

	/**
	 * Hard safety caps to avoid accidental abuse (e.g., someone pulling huge
	 * batches with long timeouts). Tune these based on your operational
	 * requirements.
	 */
	private static final int MAX_BATCH_SIZE = 5_000;
	private static final Duration MAX_TIMEOUT = Duration.ofSeconds(30);
	private static final Duration DEFAULT_TIMEOUT = Duration.ofSeconds(5);

	private final JetStream js;
	private final JetStreamManagement jsm;

	public JetStreamAdminController(JetStream js, JetStreamManagement jsm) {
		this.js = js;
		this.jsm = jsm;
	}

	/**
	 * Lightweight endpoint for verifying that the admin controller is enabled and
	 * responding. (For deeper health reporting, prefer Spring Boot Actuator health
	 * endpoints.)
	 */
	@GetMapping("/health")
	public HealthResponse health() {
		return new HealthResponse("ok", Instant.now().toString());
	}

	/**
	 * Publish a message directly to JetStream.
	 *
	 * Production characteristics: - Deterministic message-id supported (for
	 * idempotent replays if operators choose). - Payload is treated as UTF-8 bytes;
	 * null becomes empty payload (zero-length). - Returns acknowledgment details
	 * (stream, sequence, duplicate when available).
	 */
	@PostMapping(path = "/publish", consumes = MediaType.APPLICATION_JSON_VALUE)
	public ResponseEntity<PublishResponse> publish(@Valid @RequestBody PublishRequest req) throws Exception {
		String msgId = (req.messageId() == null || req.messageId().isBlank()) ? UUID.randomUUID().toString()
				: req.messageId().trim();

		PublishOptions opts = PublishOptions.builder().messageId(msgId).build();

		byte[] payload = (req.payload() == null) ? new byte[0] : req.payload().getBytes(StandardCharsets.UTF_8);

		PublishAck ack = js.publish(req.subject(), payload, opts);

		Boolean duplicate = null;
		try {
			// Some client versions expose duplicate status.
			duplicate = ack.isDuplicate();
		} catch (Throwable ignored) {
			// Keep response compatible across versions.
		}

		log.info("Admin publish subject={} msgId={} stream={} seq={} dup={}", req.subject(), msgId, ack.getStream(),
				ack.getSeqno(), duplicate);

		PublishResponse body = new PublishResponse(req.subject(), msgId, ack.getStream(), ack.getSeqno(), duplicate);

		// If it was a new message, 201 is reasonable; duplicates can remain 200.
		return ResponseEntity.status(Boolean.TRUE.equals(duplicate) ? 200 : 201).body(body);
	}

	/**
	 * Returns stream configuration and current state.
	 *
	 * Production characteristics: - Stable response DTO. - Uses the official
	 * StreamInfo / StreamState fields from the server.
	 */
	@GetMapping("/streams/{name}")
	public StreamInfoResponse streamInfo(@PathVariable("name") String name) throws Exception {
		String streamName = requireNonBlank(name, "name");

		StreamInfo si = jsm.getStreamInfo(streamName);
		StreamConfiguration cfg = si.getConfiguration();
		StreamState ss = si.getStreamState();

		return new StreamInfoResponse(cfg.getName(), cfg.getSubjects() == null ? List.of() : cfg.getSubjects(),
				cfg.getRetentionPolicy() == null ? null : cfg.getRetentionPolicy().name(), cfg.getMaxAge(),
				ss == null ? null : ss.getMsgCount(), ss == null ? null : ss.getByteCount(),
				ss == null ? null : ss.getFirstSequence(), ss == null ? null : ss.getLastSequence(),
				ss == null ? null : ss.getConsumerCount());
	}

	/**
	 * Returns consumer configuration and current delivery/ack state for a given
	 * durable.
	 */
	@GetMapping("/streams/{stream}/consumers/{durable}")
	public ConsumerInfoResponse consumerInfo(@PathVariable String stream, @PathVariable String durable)
			throws Exception {
		String streamName = requireNonBlank(stream, "stream");
		String durableName = requireNonBlank(durable, "durable");

		ConsumerInfo ci = jsm.getConsumerInfo(streamName, durableName);
		ConsumerConfiguration cc = ci.getConsumerConfiguration();

		return new ConsumerInfoResponse(streamName, durableName, cc == null ? null : cc.getFilterSubject(),
				cc == null ? null : safeEnumName(cc.getAckPolicy()), ci.getNumPending(), ci.getNumAckPending(),
				ci.getNumWaiting(), ci.getDelivered(), ci.getAckFloor());
	}

	/**
	 * Ensures a durable pull consumer exists for a stream + filter subject.
	 *
	 * Production characteristics: - Uses an explicit consumer configuration. -
	 * Ensures idempotency by using a durable name. - Returns the effective consumer
	 * details after creation/update.
	 *
	 * Notes: - The most direct production approach is using the management API to
	 * create/update the consumer. - To remain compatible across client versions,
	 * this implementation uses subscription creation as the "ensure" mechanism (it
	 * causes the server to create/update the durable consumer).
	 */
	@PostMapping(path = "/consumers/ensure", consumes = MediaType.APPLICATION_JSON_VALUE)
	public EnsureConsumerResponse ensureConsumer(@Valid @RequestBody EnsureConsumerRequest req) throws Exception {

		ConsumerConfiguration cc = ConsumerConfiguration.builder()
				// Durable name makes the operation idempotent across restarts.
				.durable(req.durable())

				// Deliver all available messages for the filter (typical for pull consumers).
				.deliverPolicy(DeliverPolicy.All)

				// Replay immediately (no pacing delays).
				.replayPolicy(ReplayPolicy.Instant)

				// Explicit ack ensures server tracks progress and can redeliver when needed.
				.ackPolicy(AckPolicy.Explicit)

				// Restrict to a specific subject filter to avoid accidental broad consumption.
				.filterSubject(req.filterSubject()).build();

		PullSubscribeOptions pso = PullSubscribeOptions.builder().stream(req.stream()).configuration(cc).build();

		JetStreamSubscription sub = null;
		try {
			// Creating the pull subscription will create/update the durable consumer on the
			// server.
			sub = js.subscribe(req.filterSubject(), pso);
		} finally {
			// Ensure we do not leak subscriptions.
			if (sub != null) {
				try {
					sub.unsubscribe();
				} catch (Exception ignored) {
				}
			}
		}

		// Return authoritative details from the server.
		ConsumerInfo ci = jsm.getConsumerInfo(req.stream(), req.durable());
		return new EnsureConsumerResponse(req.stream(), req.durable(), req.filterSubject(),
				ci.getConsumerConfiguration() == null ? null
						: safeEnumName(ci.getConsumerConfiguration().getAckPolicy()),
				ci.getNumPending());
	}

	/**
	 * Pulls up to {@code batchSize} messages and optionally ACKs them.
	 *
	 * Production characteristics: - Applies safety caps to batch size and timeout.
	 * - Uses bounded polling to avoid blocking indefinitely. - Ensures the
	 * subscription is always cleaned up.
	 */
	@PostMapping(path = "/consumers/pull", consumes = MediaType.APPLICATION_JSON_VALUE)
	public PullResponse pull(@Valid @RequestBody PullRequest req) throws Exception {
		Duration timeout = clampTimeout(req.timeout() == null ? DEFAULT_TIMEOUT : req.timeout());
		int batch = clampBatchSize(req.batchSize());

		// Durable pull subscription for the named consumer on the stream.
		PullSubscribeOptions pso = PullSubscribeOptions.builder().stream(req.stream()).durable(req.durable()).build();

		JetStreamSubscription sub = null;
		int received = 0;
		int acked = 0;
		long deadlineMs = System.currentTimeMillis() + timeout.toMillis();

		try {
			sub = js.subscribe(req.filterSubject(), pso);

			// Request a batch from the server.
			sub.pull(batch);

			// Poll in short intervals until batch received or timeout occurs.
			while (received < batch && System.currentTimeMillis() < deadlineMs) {
				long remainingMs = deadlineMs - System.currentTimeMillis();
				long pollMs = Math.min(250L, Math.max(1L, remainingMs));

				Message m = sub.nextMessage(Duration.ofMillis(pollMs));
				if (m == null) {
					continue;
				}

				received++;

				if (req.ack()) {
					// Explicit ack to advance the consumer and prevent redelivery.
					m.ack();
					acked++;
				}
			}

			boolean timedOut = received < batch;
			return new PullResponse(req.stream(), req.durable(), req.filterSubject(), batch, timeout, received, acked,
					timedOut);

		} finally {
			if (sub != null) {
				try {
					sub.unsubscribe();
				} catch (Exception ignored) {
				}
			}
		}
	}

	// ---------------------------------------------------------------------
	// DTOs (stable API contracts)
	// ---------------------------------------------------------------------

	public record HealthResponse(String status, String timestamp) {
	}

	public record PublishRequest(@NotBlank String subject, String payload, String messageId) {
	}

	public record PublishResponse(String subject, String messageId, String stream, long seq, Boolean duplicate) {
	}

	public record StreamInfoResponse(String name, List<String> subjects, String retention, Duration maxAge,
			Long messages, Long bytes, Long firstSeq, Long lastSeq, Long consumerCount) {
	}

	public record ConsumerInfoResponse(String stream, String durable, String filterSubject, String ackPolicy,
			long numPending, long numAckPending, long numWaiting, SequenceInfo delivered, SequenceInfo ackFloor) {
	}

	public record EnsureConsumerRequest(@NotBlank String stream, @NotBlank String durable,
			@NotBlank String filterSubject) {
	}

	public record EnsureConsumerResponse(String stream, String durable, String filterSubject, String ackPolicy,
			long numPending) {
	}

	public record PullRequest(@NotBlank String stream, @NotBlank String durable, @NotBlank String filterSubject,

			@Min(1) @Max(MAX_BATCH_SIZE) int batchSize,

			@JsonDeserialize(using = FlexibleDurationDeserializer.class) @NotNull Duration timeout,

			/**
			 * Whether to ack pulled messages. Default: true (safer for operational "drain"
			 * style actions).
			 */
			Boolean ack) {
		public PullRequest {
			// Defensive defaults in case validation is not active for some reason.
			if (timeout == null)
				timeout = DEFAULT_TIMEOUT;
			if (ack == null)
				ack = true;
		}

		public boolean isAckEnabled() {
			return Boolean.TRUE.equals(ack);
		}
	}

	public record PullResponse(String stream, String durable, String filterSubject, int requestedBatch,
			Duration timeout, int received, int acked, boolean timedOut) {
	}

	// ---------------------------------------------------------------------
	// Small helpers
	// ---------------------------------------------------------------------

	private static int clampBatchSize(int requested) {
		if (requested <= 0)
			return 1;
		return Math.min(requested, MAX_BATCH_SIZE);
	}

	private static Duration clampTimeout(Duration requested) {
		if (requested == null || requested.isNegative() || requested.isZero()) {
			return DEFAULT_TIMEOUT;
		}
		// Clamp to avoid very long blocking calls.
		if (requested.compareTo(MAX_TIMEOUT) > 0) {
			return MAX_TIMEOUT;
		}
		return requested;
	}

	private static String requireNonBlank(String v, String field) {
		if (v == null || v.isBlank()) {
			throw new IllegalArgumentException(field + " is required");
		}
		return v.trim();
	}

	private static String safeEnumName(Enum<?> e) {
		return e == null ? null : e.name().toUpperCase(Locale.ROOT);
	}
}

/**
 * Centralized exception mapping for the admin API.
 *
 * Production characteristics: - Avoids leaking internal stack traces to
 * callers. - Provides a consistent error shape clients can parse.
 *
 * If you already have a global exception handler in your application, merge
 * this logic there.
 */
@RestControllerAdvice
class JetStreamAdminExceptionHandler {

	private static final Logger log = LoggerFactory.getLogger(JetStreamAdminExceptionHandler.class);

	@ExceptionHandler(IllegalArgumentException.class)
	public ResponseEntity<ApiError> badRequest(IllegalArgumentException e) {
		return ResponseEntity.badRequest().body(new ApiError("bad_request", e.getMessage()));
	}

	@ExceptionHandler(Exception.class)
	public ResponseEntity<ApiError> internal(Exception e) {
		// Log full detail server-side; return a safe message to clients.
		log.error("Admin endpoint failure", e);
		return ResponseEntity.status(500).body(new ApiError("internal_error", "Request failed"));
	}

	record ApiError(String code, String message) {
	}
}
