package com.example.batch10m.domain;

import java.math.BigDecimal;
import java.time.OffsetDateTime;

public record SourceEvent(
        long id,
        long customerId,
        BigDecimal amount,
        String category,
        OffsetDateTime createdAt
) { }
