package com.rms.sync.poc;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication(scanBasePackages = "com.rms.sync")
public class SyncPocApplication {
    public static void main(String[] args) {
        SpringApplication.run(SyncPocApplication.class, args);
    }
}
