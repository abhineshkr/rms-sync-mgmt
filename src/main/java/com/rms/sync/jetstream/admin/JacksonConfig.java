package com.rms.sync.jetstream.admin;


import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Primary;

/**
 * Central Jackson configuration for the application.
 *
 * <h2>Purpose</h2>
 * <ul>
 *   <li>Ensure Java time types (Instant, LocalDateTime, Duration, etc.) serialize/deserialize correctly.</li>
 *   <li>Produce stable JSON output by disabling timestamp-style date serialization.</li>
 *   <li>Provide a single {@link ObjectMapper} bean for the Spring context.</li>
 * </ul>
 *
 * <h2>Production considerations</h2>
 * <ul>
 *   <li>Mark the mapper as {@link Primary} to avoid ambiguity if other mappers are defined.</li>
 *   <li>Prefer letting Spring Boot auto-configure Jackson and customize it via a builder/customizer.
 *       If you do define an {@link ObjectMapper} directly, ensure you don't accidentally lose Boot defaults.</li>
 *   <li>Keep this config minimal and deterministic; avoid environment-specific behavior here.</li>
 * </ul>
 */
@Configuration
public class JacksonConfig {

    /**
     * Primary {@link ObjectMapper} for the application.
     *
     * <p><b>Key settings</b></p>
     * <ul>
     *   <li>{@link JavaTimeModule}: support for {@code java.time.*} types.</li>
     *   <li>{@code WRITE_DATES_AS_TIMESTAMPS = false}: serialize dates as ISO-8601 strings.</li>
     * </ul>
     *
     * <p><b>Important</b>: If your application relies on Spring Boot's default Jackson setup
     * (e.g., property naming strategies, inclusion rules, problem details, etc.), consider using
     * a {@code Jackson2ObjectMapperBuilderCustomizer} instead of creating a new mapper from scratch.</p>
     */
    @Bean
    @Primary
    public ObjectMapper objectMapper() {
        ObjectMapper mapper = new ObjectMapper();

        // Enables Jackson support for java.time (Instant/Duration/LocalDate, etc.).
        mapper.registerModule(new JavaTimeModule());

        // Prefer ISO-8601 textual representation instead of numeric timestamps.
        mapper.disable(SerializationFeature.WRITE_DATES_AS_TIMESTAMPS);

        return mapper;
    }
}
