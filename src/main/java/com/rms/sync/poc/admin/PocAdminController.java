package com.rms.sync.poc.admin;

import io.nats.client.JetStream;
import io.nats.client.JetStreamManagement;
import io.nats.client.JetStreamSubscription;
import io.nats.client.Message;
import io.nats.client.PullSubscribeOptions;
import io.nats.client.PublishOptions;
import io.nats.client.api.AckPolicy;
import io.nats.client.api.ConsumerConfiguration;
import io.nats.client.api.ConsumerInfo;
import io.nats.client.api.DeliverPolicy;
import io.nats.client.api.PublishAck;
import io.nats.client.api.ReplayPolicy;
import io.nats.client.api.StreamInfo;
import io.nats.client.api.StreamState;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.*;

import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.HashMap;
import java.util.Map;
import java.util.UUID;

/**
 * Phase 3 (POC) admin endpoints to support automated partition/offline replay tests.
 *
 * Enabled by default; disable via:
 *   syncmgmt.poc-admin.enabled=false
 */
@RestController
@RequestMapping(path = "/poc", produces = MediaType.APPLICATION_JSON_VALUE)
@ConditionalOnProperty(prefix = "syncmgmt.poc-admin", name = "enabled", havingValue = "true", matchIfMissing = true)
public class PocAdminController {

    private final JetStream js;
    private final JetStreamManagement jsm;

    public PocAdminController(JetStream js, JetStreamManagement jsm) {
        this.js = js;
        this.jsm = jsm;
    }

    @GetMapping("/ping")
    public Map<String, Object> ping() {
        return Map.of("status", "ok");
    }

    /**
     * Publish a message directly to JetStream.
     * - If messageId is provided, it is used as JetStream Msg-Id (dedup key).
     * - If omitted, a random UUID is used.
     */
    @PostMapping(path = "/publish", consumes = MediaType.APPLICATION_JSON_VALUE)
    public Map<String, Object> publish(@RequestBody PublishRequest req) throws Exception {
        String msgId = (req.messageId() == null || req.messageId().isBlank())
                ? UUID.randomUUID().toString()
                : req.messageId();

        PublishOptions opts = PublishOptions.builder()
                .messageId(msgId)
                .build();

        byte[] payload = req.payload() == null
                ? new byte[0]
                : req.payload().getBytes(StandardCharsets.UTF_8);

        PublishAck ack = js.publish(req.subject(), payload, opts);

        Map<String, Object> out = new HashMap<>();
        out.put("subject", req.subject());
        out.put("messageId", msgId);
        out.put("stream", ack.getStream());
        out.put("seq", ack.getSeqno());
        try {
            // present on newer client versions
            out.put("duplicate", ack.isDuplicate());
        } catch (Throwable ignored) {
            // not available on some versions
        }
        return out;
    }

    @GetMapping("/stream/{name}")
    public Map<String, Object> streamInfo(@PathVariable String name) throws Exception {
        StreamInfo si = jsm.getStreamInfo(name);

        // IMPORTANT: jnats uses getStreamState(), not getState()
        StreamState ss = si.getStreamState();

        Map<String, Object> out = new HashMap<>();
        out.put("name", si.getConfiguration().getName());
        out.put("subjects", si.getConfiguration().getSubjects());
        out.put("retention", si.getConfiguration().getRetentionPolicy().name());
        out.put("maxAge", si.getConfiguration().getMaxAge());

        // state fields (guarded just in case)
        if (ss != null) {
            out.put("messages", ss.getMsgCount());
            out.put("bytes", ss.getByteCount());
            out.put("firstSeq", ss.getFirstSequence());
            out.put("lastSeq", ss.getLastSequence());
            out.put("consumerCount", ss.getConsumerCount());
        } else {
            out.put("messages", null);
            out.put("bytes", null);
            out.put("firstSeq", null);
            out.put("lastSeq", null);
            out.put("consumerCount", null);
        }

        return out;
    }

    @GetMapping("/consumer/{stream}/{durable}")
    public Map<String, Object> consumerInfo(@PathVariable String stream, @PathVariable String durable) throws Exception {
        ConsumerInfo ci = jsm.getConsumerInfo(stream, durable);
        Map<String, Object> out = new HashMap<>();
        out.put("stream", stream);
        out.put("durable", durable);
        out.put("filterSubject", ci.getConsumerConfiguration().getFilterSubject());
        out.put("ackPolicy", ci.getConsumerConfiguration().getAckPolicy().name());
        out.put("numPending", ci.getNumPending());
        out.put("numAckPending", ci.getNumAckPending());
        out.put("numWaiting", ci.getNumWaiting());
        out.put("delivered", ci.getDelivered());
        out.put("ackFloor", ci.getAckFloor());
        return out;
    }

    /**
     * Ensure a durable pull consumer exists for the given stream/filter.
     * This uses a pull-subscription with a supplied ConsumerConfiguration.
     */
    @PostMapping(path = "/consumer/ensure", consumes = MediaType.APPLICATION_JSON_VALUE)
    public Map<String, Object> ensureConsumer(@RequestBody EnsureConsumerRequest req) throws Exception {
        ConsumerConfiguration cc = ConsumerConfiguration.builder()
                .durable(req.durable())
                .deliverPolicy(DeliverPolicy.All)
                .replayPolicy(ReplayPolicy.Instant)
                .ackPolicy(AckPolicy.Explicit)
                .filterSubject(req.filterSubject())
                .build();

        PullSubscribeOptions pso = PullSubscribeOptions.builder()
                .stream(req.stream())
                .configuration(cc)
                .build();

        // Creating the subscription will create/update the durable consumer.
        JetStreamSubscription sub = js.subscribe(req.filterSubject(), pso);
        sub.unsubscribe();

        return Map.of(
                "stream", req.stream(),
                "durable", req.durable(),
                "filterSubject", req.filterSubject(),
                "status", "ok"
        );
    }

    /**
     * Pull and ACK messages for a durable pull consumer.
     */
    @PostMapping(path = "/consumer/pull", consumes = MediaType.APPLICATION_JSON_VALUE)
    public Map<String, Object> pullAndAck(@RequestBody PullRequest req) throws Exception {
        PullSubscribeOptions pso = PullSubscribeOptions.builder()
                .stream(req.stream())
                .durable(req.durable())
                .build();

        JetStreamSubscription sub = js.subscribe(req.filterSubject(), pso);
        sub.pull(req.batchSize());

        int acked = 0;
        long deadlineMs = System.currentTimeMillis() + req.timeout().toMillis();
        while (acked < req.batchSize() && System.currentTimeMillis() < deadlineMs) {
            Message m = sub.nextMessage(Duration.ofMillis(250));
            if (m == null) {
                continue;
            }
            m.ack();
            acked++;
        }
        sub.unsubscribe();

        return Map.of(
                "stream", req.stream(),
                "durable", req.durable(),
                "acked", acked
        );
    }

    public record PublishRequest(String subject, String payload, String messageId) {
        public PublishRequest {
            if (subject == null || subject.isBlank()) {
                throw new IllegalArgumentException("subject is required");
            }
        }
    }

    public record EnsureConsumerRequest(String stream, String durable, String filterSubject) {
        public EnsureConsumerRequest {
            if (stream == null || stream.isBlank()) throw new IllegalArgumentException("stream is required");
            if (durable == null || durable.isBlank()) throw new IllegalArgumentException("durable is required");
            if (filterSubject == null || filterSubject.isBlank()) throw new IllegalArgumentException("filterSubject is required");
        }
    }

    public record PullRequest(String stream, String durable, String filterSubject, int batchSize, Duration timeout) {
        public PullRequest {
            if (stream == null || stream.isBlank()) throw new IllegalArgumentException("stream is required");
            if (durable == null || durable.isBlank()) throw new IllegalArgumentException("durable is required");
            if (filterSubject == null || filterSubject.isBlank()) throw new IllegalArgumentException("filterSubject is required");
            if (batchSize <= 0) throw new IllegalArgumentException("batchSize must be > 0");
            if (timeout == null) timeout = Duration.ofSeconds(5);
        }
    }
}
