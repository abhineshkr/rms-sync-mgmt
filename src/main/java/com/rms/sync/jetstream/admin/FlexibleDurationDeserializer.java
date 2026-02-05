package com.rms.sync.jetstream.admin;

import com.fasterxml.jackson.core.JsonParser;
import com.fasterxml.jackson.databind.DeserializationContext;
import com.fasterxml.jackson.databind.JsonDeserializer;
import com.fasterxml.jackson.databind.JsonNode;

import java.io.IOException;
import java.time.Duration;
import java.util.Locale;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Jackson {@link JsonDeserializer} for {@link Duration} that is tolerant of operator-friendly inputs.
 *
 * <h2>Purpose</h2>
 * Many operational/admin endpoints accept timeouts, delays, or intervals. Humans commonly type:
 * <ul>
 *   <li>{@code 5s}, {@code 250ms}, {@code 2m}, {@code 1h}</li>
 *   <li>or just a bare number (often assumed milliseconds in CLI contexts)</li>
 * </ul>
 * while Java/Jackson's default {@link Duration} parsing expects strict ISO-8601 strings such as {@code PT5S}.
 *
 * This deserializer supports:
 * <ul>
 *   <li>ISO-8601 duration strings (case-insensitive), e.g. {@code PT5S}, {@code pt30s}</li>
 *   <li>Shorthand formats: {@code <number><unit>} where unit is one of {@code ms|s|m|h}</li>
 *   <li>Numeric values interpreted as milliseconds</li>
 *   <li>Null / empty input with a safe default</li>
 * </ul>
 *
 * <h2>Defaults / Safety</h2>
 * When input is missing or invalid, this deserializer returns {@code Duration.ofSeconds(5)}.
 * This is a defensive default intended to:
 * <ul>
 *   <li>avoid "infinite wait" style failures caused by null/empty values</li>
 *   <li>keep administrative operations responsive even when operators provide bad input</li>
 * </ul>
 *
 * <h2>Accepted examples</h2>
 * <pre>
 * "PT5S"   -> 5 seconds
 * "pt5s"   -> 5 seconds
 * "250ms"  -> 250 milliseconds
 * "5s"     -> 5 seconds
 * "2m"     -> 2 minutes
 * "1h"     -> 1 hour
 * 5000     -> 5000 milliseconds
 * null     -> 5 seconds (default)
 * ""       -> 5 seconds (default)
 * </pre>
 */
public final class FlexibleDurationDeserializer extends JsonDeserializer<Duration> {

    /**
     * Regex for shorthand duration strings:
     * - group(1): numeric magnitude (one or more digits)
     * - group(2): unit suffix (ms|s|m|h), case-insensitive
     *
     * Examples matched:
     * - "5s", "250ms", "2m", "1h", "10S", "15MS"
     */
    private static final Pattern SHORTHAND =
            Pattern.compile("^(\\d+)(ms|s|m|h)$", Pattern.CASE_INSENSITIVE);

    /**
     * Deserialize JSON content into a {@link Duration} using tolerant parsing rules.
     *
     * <p><b>Input handling</b></p>
     * <ul>
     *   <li><b>null</b> or JSON null: returns {@code 5s}</li>
     *   <li><b>number</b>: treated as milliseconds (conservative, common CLI convention)</li>
     *   <li><b>string</b>:
     *     <ul>
     *       <li>if starts with {@code P/p}: parse as ISO-8601 (case-insensitive)</li>
     *       <li>else if matches shorthand: parse magnitude+unit</li>
     *       <li>else: attempt ISO-8601 parse after uppercasing</li>
     *     </ul>
     *   </li>
     * </ul>
     *
     * @param p Jackson parser positioned at the duration field
     * @param ctxt deserialization context (unused but required by signature)
     * @return parsed Duration, or a safe default if missing/invalid
     */
    @Override
    public Duration deserialize(JsonParser p, DeserializationContext ctxt) throws IOException {
        // Read the field as a JsonNode so we can handle number vs string vs null uniformly.
        JsonNode node = p.getCodec().readTree(p);

        // Missing or explicit JSON null -> safe default.
        if (node == null || node.isNull()) {
            return Duration.ofSeconds(5);
        }

        // Bare numeric -> treat as milliseconds (most "human CLI" safe default).
        // Example: 5000 -> 5000ms
        if (node.isNumber()) {
            return Duration.ofMillis(node.asLong());
        }

        // Everything else we treat as text (includes JSON strings, and also other scalar nodes).
        String raw = node.asText(null);
        if (raw == null) {
            return Duration.ofSeconds(5);
        }

        String s = raw.trim();
        if (s.isEmpty()) {
            return Duration.ofSeconds(5);
        }

        // ISO-8601 durations start with 'P' (e.g. PT5S).
        // Duration.parse is case-sensitive regarding the 'PT' tokens in practice, so normalize to uppercase.
        if (s.startsWith("P") || s.startsWith("p")) {
            return Duration.parse(s.toUpperCase(Locale.ROOT));
        }

        // Shorthand formats: "5s", "250ms", "2m", "1h"
        Matcher m = SHORTHAND.matcher(s);
        if (m.matches()) {
            long n = Long.parseLong(m.group(1));
            String unit = m.group(2).toLowerCase(Locale.ROOT);

            // Map shorthand suffix to Duration factory methods.
            return switch (unit) {
                case "ms" -> Duration.ofMillis(n);
                case "s"  -> Duration.ofSeconds(n);
                case "m"  -> Duration.ofMinutes(n);
                case "h"  -> Duration.ofHours(n);
                // Should never happen due to regex, but keep a defensive fallback.
                default   -> Duration.ofSeconds(5);
            };
        }

        // Fallback: try ISO parsing after uppercasing.
        // This helps if someone typed "pt5s" without the leading 'P' check (or other valid ISO variants).
        try {
            return Duration.parse(s.toUpperCase(Locale.ROOT));
        } catch (Exception ignored) {
            // Final fallback: safe default for malformed inputs ("five seconds", "5sec", etc.)
            return Duration.ofSeconds(5);
        }
    }
}
