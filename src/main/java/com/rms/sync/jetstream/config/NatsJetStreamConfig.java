package com.rms.sync.jetstream.config;

import io.nats.client.Connection;
import io.nats.client.JetStream;
import io.nats.client.JetStreamManagement;
import io.nats.client.Nats;
import com.rms.sync.poc.relay.SyncRelayProperties;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
@EnableConfigurationProperties({
        SyncMgmtProperties.class,          // keep your existing class unchanged
        JetStreamBootstrapProperties.class,
        JetStreamStreamsProperties.class,
        SyncRelayProperties.class
})
public class NatsJetStreamConfig {

    @Bean(destroyMethod = "close")
    public Connection natsConnection(SyncMgmtProperties props) throws Exception {
        return Nats.connect(props.getNatsUrl());
    }

    @Bean
    public JetStream jetStream(Connection connection) throws Exception {
        return connection.jetStream();
    }

    @Bean
    public JetStreamManagement jetStreamManagement(Connection connection) throws Exception {
        return connection.jetStreamManagement();
    }
}
