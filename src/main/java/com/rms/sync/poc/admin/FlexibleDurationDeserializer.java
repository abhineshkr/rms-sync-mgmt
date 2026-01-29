package com.rms.sync.poc.admin;

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
 * Accepts ISO-8601 durations (e.g. PT5S) plus common operator shorthands (e.g. 5s, 250ms, 2m).
 *
 * Why: operators often type "5s" in curl requests; Jackson's default Duration parsing expects ISO.
 */
public final class FlexibleDurationDeserializer extends JsonDeserializer<Duration> {

    private static final Pattern SHORTHAND = Pattern.compile("^(\\d+)(ms|s|m|h)$", Pattern.CASE_INSENSITIVE);

    @Override
    public Duration deserialize(JsonParser p, DeserializationContext ctxt) throws IOException {
        JsonNode node = p.getCodec().readTree(p);

        if (node == null || node.isNull()) {
            return Duration.ofSeconds(5);
        }

        if (node.isNumber()) {
            // Treat a bare number as milliseconds for safety (it matches common CLI conventions).
            return Duration.ofMillis(node.asLong());
        }

        String raw = node.asText(null);
        if (raw == null) {
            return Duration.ofSeconds(5);
        }

        String s = raw.trim();
        if (s.isEmpty()) {
            return Duration.ofSeconds(5);
        }

        // ISO-8601, e.g. PT5S
        if (s.startsWith("P") || s.startsWith("p")) {
            return Duration.parse(s.toUpperCase(Locale.ROOT));
        }

        // Shorthand, e.g. 5s, 250ms, 2m, 1h
        Matcher m = SHORTHAND.matcher(s);
        if (m.matches()) {
            long n = Long.parseLong(m.group(1));
            String unit = m.group(2).toLowerCase(Locale.ROOT);
            return switch (unit) {
                case "ms" -> Duration.ofMillis(n);
                case "s" -> Duration.ofSeconds(n);
                case "m" -> Duration.ofMinutes(n);
                case "h" -> Duration.ofHours(n);
                default -> Duration.ofSeconds(5);
            };
        }

        // Fallback: try ISO parse after uppercasing (handles pt5s typed in lowercase).
        try {
            return Duration.parse(s.toUpperCase(Locale.ROOT));
        } catch (Exception ignored) {
            // Final fallback.
            return Duration.ofSeconds(5);
        }
    }
}
