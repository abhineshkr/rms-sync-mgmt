package com.rms.sync.core.subject;

import java.util.Objects;
import java.util.regex.Pattern;

/**
 * =====================================================================
 * SyncSubject
 * =====================================================================
 *
 * PURPOSE ------- Represents the canonical **Phase-3 adjacency model** subject
 * used by RMS SYNC_MGMT across JetStream.
 *
 * A subject uniquely identifies: - Direction of propagation (up / down) -
 * Origin tier (leaf / subzone / zone / central) - Physical topology position
 * (zone / subzone / node) - Business semantics (domain / entity / event)
 *
 * WHY THIS EXISTS --------------- JetStream subjects are the *routing,
 * partitioning, authorization, and replay mechanism*. Any inconsistency causes:
 *
 * - Broken replay - ACL mismatches - Stream fragmentation - Incorrect fan-out
 *
 * Therefore: - Subjects are STRICT - Subjects are VALIDATED - Subjects are
 * IMMUTABLE
 *
 * CANONICAL FORMAT (LOCKED) ------------------------
 *
 * <dir>
 * .<tier>.<zone>.<subzone>.<node>.<domain>.<entity>.<event>
 *
 * Token Count: EXACTLY 8
 *
 * Examples: up.leaf.z1.sz1.leaf01.order.order.created
 * up.subzone.z1.sz1.subzone01.order.order.created
 * up.zone.z1.none.zone01.order.order.created
 *
 * down.central.z1.sz1.all.config.policy.updated
 * down.zone.z1.sz1.zone01.config.policy.updated
 * down.subzone.z1.sz1.subzone01.config.policy.updated
 *
 * IMMUTABILITY ------------ Once created, a SyncSubject cannot be modified.
 * This guarantees thread-safety and audit integrity.
 */
public final class SyncSubject {

	/**
	 * TOKEN VALIDATION RULE --------------------- Ensures: - ASCII safe - JetStream
	 * compatible - No wildcard injection - Bounded size
	 *
	 * Rules: - Must start with alphanumeric - May contain alphanumeric, underscore,
	 * hyphen - Max length: 64 chars
	 */
	private static final Pattern TOKEN = Pattern.compile("^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$");

	/*
	 * =============================================================== Canonical
	 * Subject Components
	 * ===============================================================
	 */

	/** Direction of propagation (upstream / downstream) */
	private final SyncDirection direction;

	/** Tier that originated the event */
	private final OriginTier tier;

	/** Zone identifier (z1..zN or central) */
	private final String zone;

	/**
	 * Subzone identifier. MUST be "none" when not applicable (never null).
	 */
	private final String subzone;

	/**
	 * Origin node identifier. Can be: - leaf id - subzone aggregator id - zone
	 * aggregator id - "all" for broadcast
	 */
	private final String node;

	/** Business domain (order, config, audit, etc.) */
	private final String domain;

	/** Entity name within the domain */
	private final String entity;

	/** Event/action (created, updated, deleted, synced, etc.) */
	private final String event;

	/**
	 * Private constructor.
	 *
	 * Forces usage of the Builder to: - Apply defaults - Enforce validation -
	 * Prevent partial construction
	 */
	private SyncSubject(Builder b) {
		this.direction = Objects.requireNonNull(b.direction, "direction");
		this.tier = Objects.requireNonNull(b.tier, "tier");

		this.zone = requireToken(b.zone, "zone");
		this.subzone = requireToken(b.subzone, "subzone");
		this.node = requireToken(b.node, "node");

		this.domain = requireToken(b.domain, "domain");
		this.entity = requireToken(b.entity, "entity");
		this.event = requireToken(b.event, "event");
	}

	/**
	 * Entry point for building a canonical subject.
	 */
	public static Builder builder() {
		return new Builder();
	}

	/**
	 * Converts this object into its canonical JetStream subject string.
	 *
	 * IMPORTANT: - Token order is FIXED - No conditional omission - Always produces
	 * exactly 8 tokens
	 */
	public String toSubject() {
		return direction.name() + "." + tier.name() + "." + zone + "." + subzone + "." + node + "." + domain + "."
				+ entity + "." + event;
	}

	/**
	 * Attempts to parse a subject string into a structured form.
	 *
	 * BEHAVIOR -------- - Returns Parsed if subject is canonical - Returns null if:
	 * - subject is null - token count != 8 - enums do not match
	 *
	 * NOTE ---- This method is intentionally NON-THROWING to allow fast-path
	 * filtering in consumers.
	 */
	public static Parsed tryParse(String subject) {
		if (subject == null)
			return null;

		String[] t = subject.split("\\.");
		if (t.length != 8)
			return null;

		try {
			return new Parsed(SyncDirection.valueOf(t[0]), OriginTier.valueOf(t[1]), t[2], t[3], t[4], t[5], t[6],
					t[7]);
		} catch (Exception e) {
			return null;
		}
	}

	/**
	 * Rewrites an existing canonical subject to reflect a new propagation path
	 * while preserving business semantics.
	 *
	 * USE CASES --------- - Zone forwarding a leaf event upstream - Central
	 * broadcasting downstream config - Subzone rebasing identity during replay
	 *
	 * PRESERVED --------- - domain - entity - event
	 *
	 * CHANGED ------- - direction - tier - zone / subzone / node
	 */
	public static String rewrite(String subject, SyncDirection newDir, OriginTier newTier, String zone, String subzone,
			String node) {

		Parsed p = tryParse(subject);
		if (p == null) {
			throw new IllegalArgumentException("Cannot rewrite non-canonical subject (expected 8 tokens): " + subject);
		}

		return newDir.name() + "." + newTier.name() + "." + zone + "." + subzone + "." + node + "." + p.domain + "."
				+ p.entity + "." + p.event;
	}

	/**
	 * Validates a single subject token.
	 *
	 * RULES ----- - Not null - Not blank - Matches TOKEN regex
	 */
	private static String requireToken(String value, String name) {
		if (value == null || value.isBlank()) {
			throw new IllegalArgumentException(name + " is required");
		}
		if (!TOKEN.matcher(value).matches()) {
			throw new IllegalArgumentException(name + " must match " + TOKEN.pattern() + " but was: " + value);
		}
		return value;
	}

	/*
	 * =============================================================== Accessors
	 * (record-like) ===============================================================
	 */

	public SyncDirection direction() {
		return direction;
	}

	public OriginTier tier() {
		return tier;
	}

	public String zone() {
		return zone;
	}

	public String subzone() {
		return subzone;
	}

	public String node() {
		return node;
	}

	public String domain() {
		return domain;
	}

	public String entity() {
		return entity;
	}

	public String event() {
		return event;
	}

	/**
	 * =============================================================== Builder
	 * ===============================================================
	 *
	 * Enforces: - Sensible defaults - Explicit tier selection - Validation on
	 * build()
	 */
	public static final class Builder {

		/** Default direction is upstream */
		private SyncDirection direction = SyncDirection.up;

		/** Tier MUST be explicitly set */
		private OriginTier tier;

		private String zone;
		private String subzone = "none";
		private String node;

		private String domain;
		private String entity;
		private String event;

		public Builder direction(SyncDirection direction) {
			this.direction = direction;
			return this;
		}

		public Builder tier(OriginTier tier) {
			this.tier = tier;
			return this;
		}

		public Builder zone(String zone) {
			this.zone = zone;
			return this;
		}

		public Builder subzone(String subzone) {
			this.subzone = subzone;
			return this;
		}

		public Builder node(String node) {
			this.node = node;
			return this;
		}

		public Builder domain(String domain) {
			this.domain = domain;
			return this;
		}

		public Builder entity(String entity) {
			this.entity = entity;
			return this;
		}

		public Builder event(String event) {
			this.event = event;
			return this;
		}

		/**
		 * Finalizes and validates the subject.
		 */
		public SyncSubject build() {
			return new SyncSubject(this);
		}
	}

	/**
	 * =============================================================== Parsed
	 * Representation
	 * ===============================================================
	 *
	 * Lightweight, allocation-cheap view of a subject. Used mainly by: - Consumers
	 * - Routers - ACL evaluators
	 */
	public static final class Parsed {

		public final SyncDirection direction;
		public final OriginTier tier;
		public final String zone;
		public final String subzone;
		public final String node;
		public final String domain;
		public final String entity;
		public final String event;

		public Parsed(SyncDirection direction, OriginTier tier, String zone, String subzone, String node, String domain,
				String entity, String event) {

			this.direction = direction;
			this.tier = tier;
			this.zone = zone;
			this.subzone = subzone;
			this.node = node;
			this.domain = domain;
			this.entity = entity;
			this.event = event;
		}

		@Override
		public String toString() {
			return "Parsed{" + "direction=" + direction + ", tier=" + tier + ", zone='" + zone + '\'' + ", subzone='"
					+ subzone + '\'' + ", node='" + node + '\'' + ", domain='" + domain + '\'' + ", entity='" + entity
					+ '\'' + ", event='" + event + '\'' + '}';
		}
	}
}
