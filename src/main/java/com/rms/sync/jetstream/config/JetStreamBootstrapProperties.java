package com.rms.sync.jetstream.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Controls JetStream bootstrap behavior.
 */
@ConfigurationProperties(prefix = "syncmgmt.bootstrap")
public class JetStreamBootstrapProperties {

    /**
     * When true, fail fast if an existing stream differs from the desired configuration.
     */
    private boolean failOnMismatch = false;

    public boolean isFailOnMismatch() {
        return failOnMismatch;
    }

    public void setFailOnMismatch(boolean failOnMismatch) {
        this.failOnMismatch = failOnMismatch;
    }
}
