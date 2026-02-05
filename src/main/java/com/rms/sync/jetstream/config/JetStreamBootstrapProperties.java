package com.rms.sync.jetstream.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

import java.util.ArrayList;
import java.util.List;

/**
 * =====================================================================
 * JetStreamBootstrapProperties
 * =====================================================================
 *
 * PURPOSE ------- Controls **how strictly JetStream infrastructure is
 * validated** during application startup.
 *
 * This configuration governs the behavior of the
 * {@link com.rms.sync.jetstream.bootstrap.JetStreamBootstrapper} when it
 * encounters an existing stream whose configuration differs from the expected,
 * declarative definition.
 *
 * WHY THIS EXISTS --------------- In real-world environments: - Streams may be
 * pre-created manually - Configurations may drift over time - Environments (dev
 * / test / prod) have different tolerances
 *
 * This flag allows operators to choose between: - Safety-first (fail fast) -
 * Availability-first (warn and continue)
 *
 * CONFIGURATION PREFIX -------------------- syncmgmt.bootstrap.*
 *
 * This class is bound via Spring Boot's {@link ConfigurationProperties}
 * mechanism.
 */
@ConfigurationProperties(prefix = "syncmgmt.bootstrap")
public class JetStreamBootstrapProperties {

	/**
	 * Determines behavior when an existing JetStream stream does NOT match the
	 * desired configuration.
	 *
	 * WHEN TRUE (STRICT MODE) ----------------------- - Application startup FAILS -
	 * Prevents running against misconfigured streams - Recommended for: -
	 * Production - Regulated environments - Central / Zone tiers
	 *
	 * WHEN FALSE (PERMISSIVE MODE) ---------------------------- - Application logs
	 * a WARNING - Startup continues - Recommended for: - Local development - POCs -
	 * Transitional environments
	 *
	 * DEFAULT ------- false (permissive)
	 *
	 * IMPORTANT --------- This flag does NOT: - Modify existing streams - Attempt
	 * auto-migration
	 *
	 * It only controls **reaction**, not **repair**.
	 */
	private boolean failOnMismatch = false;

	/**
	 * Optional list of logical stream keys to bootstrap on this node.
	 *
	 * If empty, all configured (enabled=true) streams are bootstrapped.
	 *
	 * Valid keys:
	 * - up-leaf
	 * - up-subzone
	 * - up-zone
	 * - down-central
	 * - down-zone
	 * - down-subzone
	 */
	private List<String> streamKeys = new ArrayList<>();

	/**
	 * @return whether bootstrap should fail on stream config mismatch
	 */
	public boolean isFailOnMismatch() {
		return failOnMismatch;
	}

	/**
	 * Sets strictness of bootstrap validation.
	 *
	 * @param failOnMismatch true to fail fast on config drift
	 */
	public void setFailOnMismatch(boolean failOnMismatch) {
		this.failOnMismatch = failOnMismatch;
	}

	public List<String> getStreamKeys() {
		return streamKeys;
	}

	public void setStreamKeys(List<String> streamKeys) {
		this.streamKeys = streamKeys == null ? new ArrayList<>() : streamKeys;
	}
}
