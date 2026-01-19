package com.rms.sync.jetstream.bootstrap;

/**
 * Published after JetStreamBootstrapper has ensured all configured streams exist.
 * Consumers should subscribe only after this event to avoid startup races.
 */
public record JetStreamBootstrapCompleteEvent() { }
