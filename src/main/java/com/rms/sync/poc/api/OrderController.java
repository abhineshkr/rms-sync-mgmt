package com.rms.sync.poc.api;

import com.rms.sync.core.subject.OriginTier;
import com.rms.sync.core.subject.SyncSubject;
import com.rms.sync.jetstream.config.SyncMgmtProperties;
import com.rms.sync.r2dbc.service.OutboxService;
import jakarta.validation.Valid;
import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.*;
import reactor.core.publisher.Mono;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.util.Map;

@RestController
@RequestMapping(path = "/api/orders", produces = MediaType.APPLICATION_JSON_VALUE)
public class OrderController {

    private final OutboxService outbox;
    private final SyncMgmtProperties props;
    private final ObjectMapper mapper;

    public OrderController(OutboxService outbox, SyncMgmtProperties props, ObjectMapper mapper) {
        this.outbox = outbox;
        this.props = props;
        this.mapper = mapper;
    }

    @PostMapping(consumes = MediaType.APPLICATION_JSON_VALUE)
    public Mono<Map<String, Object>> create(@Valid @RequestBody OrderCreateRequest req) {
        String subject = SyncSubject.builder()
                .originTier(OriginTier.valueOf(props.getTier()))
                .zone(props.getZone())
                .subzone(props.getSubzone())
                .originNode(props.getNodeId())
                .domain("order")
                .entity("order")
                .event("created")
                .build()
                .toSubject();

        return Mono.fromCallable(() -> mapper.writeValueAsString(req))
                .flatMap(json -> outbox.enqueue(subject, json, Map.of("contentType", "application/json")))
                .map(id -> Map.<String, Object>of("outboxEventId", id, "subject", subject));
    }
}
