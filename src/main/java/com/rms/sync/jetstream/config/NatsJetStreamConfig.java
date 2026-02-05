package com.rms.sync.jetstream.config;

import java.lang.reflect.Method;
import java.util.Arrays;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import com.rms.sync.poc.relay.SyncRelayProperties;

import io.nats.client.Connection;
import io.nats.client.JetStream;
import io.nats.client.JetStreamManagement;
import io.nats.client.Nats;

/**
 * Spring configuration that wires up:
 * - NATS {@link Connection}
 * - JetStream client APIs ({@link JetStream} and {@link JetStreamManagement})
 * - Property binding for all NATS/JetStream-related configuration classes
 *
 * <h2>Purpose</h2>
 * <ul>
 *   <li>Create a single, shared NATS connection for the application lifecycle.</li>
 *   <li>Support multiple auth modes (no-auth, user/pass, token, creds) and optional TLS.</li>
 *   <li>Remain tolerant across different jNATS library versions by building Options via reflection.</li>
 * </ul>
 *
 * <h2>Why reflection is used here</h2>
 * The jNATS Options builder API has had signature differences across versions (e.g., token(String) vs
 * token(char[]), userInfo(...) overloads, server vs servers). Rather than pinning to one exact jNATS
 * version, this config:
 * <ul>
 *   <li>Tries to call a compatible builder method if it exists.</li>
 *   <li>Falls back to {@code Nats.connect(url)} if Options construction fails.</li>
 * </ul>
 *
 * <h2>Operational behavior</h2>
 * <ul>
 *   <li>If no auth/TLS fields are configured, it uses the simplest possible connect path.</li>
 *   <li>If any auth/TLS is configured, it attempts an Options-based connect.</li>
 *   <li>On any reflection/build failure, it logs a warning and falls back to the simple connect.</li>
 * </ul>
 */
@Configuration
@EnableConfigurationProperties({
        SyncMgmtProperties.class,          // Base connection settings (url, auth, tls flags)
        JetStreamBootstrapProperties.class, // Stream/consumer bootstrap toggles and policies
        JetStreamStreamsProperties.class,   // Stream specs (names, subjects, retention, etc.)
        SyncRelayProperties.class           // Relay settings (kept in the same app context)
})
public class NatsJetStreamConfig {

    private static final Logger log = LoggerFactory.getLogger(NatsJetStreamConfig.class);

    /**
     * Creates the core NATS {@link Connection} bean.
     *
     * <p><b>Lifecycle</b></p>
     * <ul>
     *   <li>Declared with {@code destroyMethod="close"} so the connection is closed on app shutdown.</li>
     * </ul>
     *
     * <p><b>Connection strategy</b></p>
     * <ol>
     *   <li>Check whether advanced options (auth/creds/TLS) appear to be requested.</li>
     *   <li>If not requested, connect using {@code Nats.connect(url)} (fast path).</li>
     *   <li>If requested, attempt to build {@code io.nats.client.Options} via reflection and connect with it.</li>
     *   <li>If Options building fails for any reason, fall back to {@code Nats.connect(url)}.</li>
     * </ol>
     *
     * <p><b>Security note</b></p>
     * <ul>
     *   <li>This method avoids logging secrets. It masks the username and does not print passwords/tokens.</li>
     * </ul>
     */
    @Bean(destroyMethod = "close")
    public Connection natsConnection(SyncMgmtProperties props) throws Exception {
        String url = props.getNatsUrl();

        // Determine if we should attempt an Options-based connection.
        // Any configured auth mechanism or TLS flag indicates we should build Options.
        boolean wantsOptions =
                (props.getNatsUser() != null && !props.getNatsUser().isBlank()) ||
                (props.getNatsPassword() != null && !props.getNatsPassword().isBlank()) ||
                (props.getNatsToken() != null && !props.getNatsToken().isBlank()) ||
                (props.getNatsCreds() != null && !props.getNatsCreds().isBlank()) ||
                props.isNatsTls();

        // Backward-compatible and simplest behavior: no auth, no TLS, just connect.
        if (!wantsOptions) {
            return Nats.connect(url);
        }

        // Options-based connect (using reflection) to reduce tight coupling to a particular jNATS version.
        try {
            // Instantiate io.nats.client.Options.Builder reflectively:
            // - In some jNATS versions this is an inner class "Options$Builder"
            Object builder = newInstance("io.nats.client.Options$Builder");

            // Set server URL:
            // - Some versions use builder.server(String)
            // - Others use builder.servers(String...)
            if (!tryInvoke(builder, "server", url)) {
                // Coerce to String[] for varargs-style methods.
                tryInvoke(builder, "servers", (Object) new String[] { url });
            }

            if (props.isNatsTls()) {
                // Enable TLS behavior:
                // - secure() is a common toggle on the builder.
                // - Using "tls://" in the URL may also negotiate TLS; secure() is explicit and version-tolerant.
                tryInvoke(builder, "secure");
            }

            // Token auth:
            // - Some versions accept token(String)
            // - Some accept token(char[])
            if (props.getNatsToken() != null && !props.getNatsToken().isBlank()) {
                if (!tryInvoke(builder, "token", props.getNatsToken().toCharArray())) {
                    tryInvoke(builder, "token", props.getNatsToken());
                }
            }

            // Username/password auth:
            // Builder overloads vary; we attempt a few common signatures.
            if (props.getNatsUser() != null && !props.getNatsUser().isBlank()) {
                String pass = props.getNatsPassword() == null ? "" : props.getNatsPassword();

                // Common patterns seen across versions:
                boolean ok = tryInvoke(builder, "userInfo", props.getNatsUser(), pass.toCharArray());
                if (!ok) ok = tryInvoke(builder, "userInfo", props.getNatsUser().toCharArray(), pass.toCharArray());
                if (!ok) ok = tryInvoke(builder, "userInfo", props.getNatsUser(), pass);
            }

            // Credentials auth (NKey/JWT via credentials file):
            // - jNATS provides Nats.credentials(String) which returns an AuthHandler
            // - Then builder.authHandler(AuthHandler) can be used (if present)
            if (props.getNatsCreds() != null && !props.getNatsCreds().isBlank()) {
                Object authHandler = invokeStatic(
                        "io.nats.client.Nats",
                        "credentials",
                        new Class<?>[]{String.class},
                        new Object[]{props.getNatsCreds()}
                );
                tryInvoke(builder, "authHandler", authHandler);
            }

            // Build the Options instance.
            // If the method name differs, findBestMethod will return null and we fail fast.
            Object options = tryInvokeAndReturn(builder, "build");

            // Call Nats.connect(Options) reflectively (avoids compile-time dependency issues if signatures vary).
            Class<?> optionsClass = Class.forName("io.nats.client.Options");
            Method connect = Nats.class.getMethod("connect", optionsClass);
            Connection c = (Connection) connect.invoke(null, options);

            // Log minimal connection metadata (masking any identifying/secret details).
            log.info("Connected to NATS (url={}, tls={}, user={}, creds={})",
                    url,
                    props.isNatsTls(),
                    props.getNatsUser() == null ? "" : mask(props.getNatsUser()),
                    props.getNatsCreds() == null ? "" : props.getNatsCreds());

            return c;
        } catch (Exception e) {
            // If anything goes wrong in reflection (class not found, method mismatch, invoke exception),
            // fall back to the simplest possible connect behavior so local/dev environments still work.
            log.warn("Falling back to simple Nats.connect(url) due to Options build failure: {}", e.getMessage());
            return Nats.connect(url);
        }
    }

    /**
     * Provides the JetStream context API for publish/subscribe operations with streams/consumers.
     *
     * <p>Uses the already-created {@link Connection} bean.</p>
     */
    @Bean
    public JetStream jetStream(Connection connection) throws Exception {
        return connection.jetStream();
    }

    /**
     * Provides JetStream management API for administrative operations:
     * - create/update streams
     * - create/update consumers
     * - query stream/consumer state
     *
     * <p>Uses the already-created {@link Connection} bean.</p>
     */
    @Bean
    public JetStreamManagement jetStreamManagement(Connection connection) throws Exception {
        return connection.jetStreamManagement();
    }

    // -------------------------------------------------------------------------
    // Reflection helpers
    // -------------------------------------------------------------------------

    /**
     * Creates a new instance of a class by name using its no-arg constructor.
     *
     * <p>Used to create the jNATS Options builder without a compile-time dependency on its concrete type.</p>
     */
    private static Object newInstance(String className) throws Exception {
        return Class.forName(className).getConstructor().newInstance();
    }

    /**
     * Attempts to invoke a method on a target object using best-effort overload selection.
     *
     * <p><b>Behavior</b></p>
     * <ul>
     *   <li>Finds the first compatible public method with the given name and arity.</li>
     *   <li>Coerces between {@code String} and {@code char[]} when needed.</li>
     *   <li>Returns {@code false} if no compatible method exists or invocation fails.</li>
     * </ul>
     *
     * <p>This is intentionally forgiving because API differences are expected across library versions.</p>
     */
    private static boolean tryInvoke(Object target, String methodName, Object... args) {
        try {
            Method m = findBestMethod(target.getClass(), methodName, args);
            if (m == null) return false;
            m.setAccessible(true);
            m.invoke(target, coerceArgs(m.getParameterTypes(), args));
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    /**
     * Like {@link #tryInvoke(Object, String, Object...)}, but returns the invoked method's return value.
     *
     * <p>Used for methods that must succeed (e.g., {@code build()}) to continue.</p>
     *
     * @throws Exception if no compatible method is found or invocation fails
     */
    private static Object tryInvokeAndReturn(Object target, String methodName, Object... args) throws Exception {
        Method m = findBestMethod(target.getClass(), methodName, args);
        if (m == null) throw new NoSuchMethodException(target.getClass().getName() + "." + methodName);
        m.setAccessible(true);
        return m.invoke(target, coerceArgs(m.getParameterTypes(), args));
    }

    /**
     * Invokes a static method reflectively.
     *
     * <p>Used here to call {@code Nats.credentials(String)} which returns an AuthHandler.</p>
     */
    private static Object invokeStatic(String className, String methodName, Class<?>[] sig, Object[] args) throws Exception {
        Class<?> c = Class.forName(className);
        Method m = c.getMethod(methodName, sig);
        return m.invoke(null, args);
    }

    /**
     * Finds a "best" compatible public method by:
     * - matching method name
     * - matching parameter count
     * - verifying each parameter is compatible with the provided argument (via {@link #isCompatible(Class, Object)})
     *
     * <p><b>Note</b>: This returns the first compatible method encountered. If a class has multiple compatible
     * overloads, selection is not guaranteed to be the "most specific". For this use-case, the overloads are
     * sufficiently distinct (String vs char[]), so first-match is acceptable.</p>
     */
    private static Method findBestMethod(Class<?> type, String name, Object[] args) {
        Method[] methods = type.getMethods(); // public methods including inherited
        for (Method m : methods) {
            if (!m.getName().equals(name)) continue;
            if (m.getParameterCount() != args.length) continue;

            Class<?>[] p = m.getParameterTypes();
            boolean ok = true;
            for (int i = 0; i < p.length; i++) {
                if (!isCompatible(p[i], args[i])) {
                    ok = false;
                    break;
                }
            }
            if (ok) {
                return m;
            }
        }
        return null;
    }

    /**
     * Determines whether an argument can be used for a parameter type.
     *
     * <p><b>Supported compatibility rules</b></p>
     * <ul>
     *   <li>{@code null} is allowed for non-primitive params.</li>
     *   <li>Direct instance-of match (paramType.isInstance(arg)).</li>
     *   <li>String <-> char[] coercion for auth methods that vary by signature.</li>
     *   <li>Basic array compatibility for varargs-like methods (e.g., servers(String...)).</li>
     * </ul>
     */
    private static boolean isCompatible(Class<?> paramType, Object arg) {
        if (arg == null) return !paramType.isPrimitive();
        if (paramType.isInstance(arg)) return true;

        // Some jNATS versions expose token/userInfo as String, others as char[]
        if (paramType == char[].class && arg instanceof String) return true;
        if (paramType == String.class && arg instanceof char[]) return true;

        // Handle arrays (useful for varargs signature differences)
        if (paramType.isArray() && arg.getClass().isArray()) {
            return paramType.getComponentType().isAssignableFrom(arg.getClass().getComponentType());
        }
        return false;
    }

    /**
     * Coerces arguments to match the chosen method signature.
     *
     * <p>Currently supports only String <-> char[] conversions because those are the most common
     * differences between jNATS builder overloads for auth.</p>
     */
    private static Object[] coerceArgs(Class<?>[] paramTypes, Object[] args) {
        Object[] out = Arrays.copyOf(args, args.length);
        for (int i = 0; i < out.length; i++) {
            if (out[i] == null) continue;

            // Convert String -> char[] when method expects char[]
            if (paramTypes[i] == char[].class && out[i] instanceof String s) {
                out[i] = s.toCharArray();
            }
            // Convert char[] -> String when method expects String
            else if (paramTypes[i] == String.class && out[i] instanceof char[] c) {
                out[i] = new String(c);
            }
        }
        return out;
    }

    /**
     * Masks an identifier for logging (light obfuscation).
     *
     * <p>Example: "admin" -> "a***n"</p>
     *
     * <p><b>Note</b>: This is not cryptographic and is only meant to avoid printing raw identifiers in logs.</p>
     */
    private static String mask(String v) {
        if (v == null || v.isBlank()) return "";
        if (v.length() <= 2) return "**";
        return v.substring(0, 1) + "***" + v.substring(v.length() - 1);
    }
}
