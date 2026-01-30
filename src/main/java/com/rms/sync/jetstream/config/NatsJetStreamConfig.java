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

@Configuration
@EnableConfigurationProperties({
        SyncMgmtProperties.class,          // keep your existing class unchanged
        JetStreamBootstrapProperties.class,
        JetStreamStreamsProperties.class,
        SyncRelayProperties.class
})
public class NatsJetStreamConfig {

    private static final Logger log = LoggerFactory.getLogger(NatsJetStreamConfig.class);

    @Bean(destroyMethod = "close")
    public Connection natsConnection(SyncMgmtProperties props) throws Exception {
        String url = props.getNatsUrl();

        boolean wantsOptions =
                (props.getNatsUser() != null && !props.getNatsUser().isBlank()) ||
                (props.getNatsPassword() != null && !props.getNatsPassword().isBlank()) ||
                (props.getNatsToken() != null && !props.getNatsToken().isBlank()) ||
                (props.getNatsCreds() != null && !props.getNatsCreds().isBlank()) ||
                props.isNatsTls();

        // Backward compatible: simple connect when no auth/TLS extras are configured.
        if (!wantsOptions) {
            return Nats.connect(url);
        }

        // Production-like test support: build Options via reflection to avoid hard dependency on
        // specific jnats builder method signatures across versions.
        try {
            Object builder = newInstance("io.nats.client.Options$Builder");

            // server(url) or servers(String...)
            if (!tryInvoke(builder, "server", url)) {
                tryInvoke(builder, "servers", (Object) new String[] { url });
            }

            if (props.isNatsTls()) {
                // secure() toggles TLS behavior on the client side. If you use tls:// in the URL,
                // jnats will typically negotiate TLS as well.
                tryInvoke(builder, "secure");
            }

            // token auth
            if (props.getNatsToken() != null && !props.getNatsToken().isBlank()) {
                if (!tryInvoke(builder, "token", props.getNatsToken().toCharArray())) {
                    tryInvoke(builder, "token", props.getNatsToken());
                }
            }

            // user/pass auth
            if (props.getNatsUser() != null && !props.getNatsUser().isBlank()) {
                String pass = props.getNatsPassword() == null ? "" : props.getNatsPassword();
                boolean ok = tryInvoke(builder, "userInfo", props.getNatsUser(), pass.toCharArray());
                if (!ok) ok = tryInvoke(builder, "userInfo", props.getNatsUser().toCharArray(), pass.toCharArray());
                if (!ok) ok = tryInvoke(builder, "userInfo", props.getNatsUser(), pass);
            }

            // .creds (NKey/JWT) auth
            if (props.getNatsCreds() != null && !props.getNatsCreds().isBlank()) {
                Object authHandler = invokeStatic("io.nats.client.Nats", "credentials", new Class<?>[]{String.class}, new Object[]{props.getNatsCreds()});
                // authHandler(AuthHandler)
                tryInvoke(builder, "authHandler", authHandler);
            }

            Object options = tryInvokeAndReturn(builder, "build");

            Class<?> optionsClass = Class.forName("io.nats.client.Options");
            Method connect = Nats.class.getMethod("connect", optionsClass);
            Connection c = (Connection) connect.invoke(null, options);

            log.info("Connected to NATS (url={}, tls={}, user={}, creds={})",
                    url,
                    props.isNatsTls(),
                    props.getNatsUser() == null ? "" : mask(props.getNatsUser()),
                    props.getNatsCreds() == null ? "" : props.getNatsCreds());

            return c;
        } catch (Exception e) {
            log.warn("Falling back to simple Nats.connect(url) due to Options build failure: {}", e.getMessage());
            return Nats.connect(url);
        }
    }

    @Bean
    public JetStream jetStream(Connection connection) throws Exception {
        return connection.jetStream();
    }

    @Bean
    public JetStreamManagement jetStreamManagement(Connection connection) throws Exception {
        return connection.jetStreamManagement();
    }

    private static Object newInstance(String className) throws Exception {
        return Class.forName(className).getConstructor().newInstance();
    }

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

    private static Object tryInvokeAndReturn(Object target, String methodName, Object... args) throws Exception {
        Method m = findBestMethod(target.getClass(), methodName, args);
        if (m == null) throw new NoSuchMethodException(target.getClass().getName() + "." + methodName);
        m.setAccessible(true);
        return m.invoke(target, coerceArgs(m.getParameterTypes(), args));
    }

    private static Object invokeStatic(String className, String methodName, Class<?>[] sig, Object[] args) throws Exception {
        Class<?> c = Class.forName(className);
        Method m = c.getMethod(methodName, sig);
        return m.invoke(null, args);
    }

    private static Method findBestMethod(Class<?> type, String name, Object[] args) {
        Method[] methods = type.getMethods();
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

    private static boolean isCompatible(Class<?> paramType, Object arg) {
        if (arg == null) return !paramType.isPrimitive();
        if (paramType.isInstance(arg)) return true;
        if (paramType == char[].class && arg instanceof String) return true;
        if (paramType == String.class && arg instanceof char[]) return true;
        if (paramType.isArray() && arg.getClass().isArray()) {
            return paramType.getComponentType().isAssignableFrom(arg.getClass().getComponentType());
        }
        return false;
    }

    private static Object[] coerceArgs(Class<?>[] paramTypes, Object[] args) {
        Object[] out = Arrays.copyOf(args, args.length);
        for (int i = 0; i < out.length; i++) {
            if (out[i] == null) continue;
            if (paramTypes[i] == char[].class && out[i] instanceof String s) {
                out[i] = s.toCharArray();
            } else if (paramTypes[i] == String.class && out[i] instanceof char[] c) {
                out[i] = new String(c);
            }
        }
        return out;
    }

    private static String mask(String v) {
        if (v == null || v.isBlank()) return "";
        if (v.length() <= 2) return "**";
        return v.substring(0, 1) + "***" + v.substring(v.length() - 1);
    }
}
