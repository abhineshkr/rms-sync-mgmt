package com.rms.sync.poc.api;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;

import java.math.BigDecimal;

public record OrderCreateRequest(
        @NotBlank String orderId,
        @NotNull BigDecimal amount
) {}
