package com.rms.sync.r2dbc.entity;

import java.time.Instant;
import java.util.UUID;

import org.springframework.data.annotation.Id;
import org.springframework.data.relational.core.mapping.Column;
import org.springframework.data.relational.core.mapping.Table;



@Table("sync_outbox_event")
public class OutboxEventEntity {

    @Id
    private UUID id;

    @Column("subject")
    private String subject;

    @Column("payload")
    private String payloadText;

    @Column("headers")
    private String headersText;

    @Column("status")
    private String status;

    @Column("retry_count")
    private Integer retryCount;

    @Column("created_at")
    private Instant createdAt;

    @Column("published_at")
    private Instant publishedAt;

    public UUID getId() { return id; }
    public void setId(UUID id) { this.id = id; }

    public String getSubject() { return subject; }
    public void setSubject(String subject) { this.subject = subject; }

    public String getPayloadText() { return payloadText; }
    public void setPayloadText(String payloadText) { this.payloadText = payloadText; }

    public String getHeadersText() { return headersText; }
    public void setHeadersText(String headersText) { this.headersText = headersText; }

    public String getStatus() { return status; }
    public void setStatus(String status) { this.status = status; }

    public Integer getRetryCount() { return retryCount; }
    public void setRetryCount(Integer retryCount) { this.retryCount = retryCount; }

    public Instant getCreatedAt() { return createdAt; }
    public void setCreatedAt(Instant createdAt) { this.createdAt = createdAt; }

    public Instant getPublishedAt() { return publishedAt; }
    public void setPublishedAt(Instant publishedAt) { this.publishedAt = publishedAt; }
}
