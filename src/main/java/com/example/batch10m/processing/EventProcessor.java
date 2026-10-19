package com.example.batch10m.processing;

import com.example.batch10m.domain.ProcessedEvent;
import com.example.batch10m.domain.SourceEvent;
import org.springframework.batch.item.ItemProcessor;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.Locale;

public class EventProcessor implements ItemProcessor<SourceEvent, ProcessedEvent> {
    private static final BigDecimal HIGH_AMOUNT_THRESHOLD = new BigDecimal("1000.00");
    private final long simulatedFailureId;

    public EventProcessor() {
        this(0);
    }

    public EventProcessor(long simulatedFailureId) {
        this.simulatedFailureId = simulatedFailureId;
    }

    @Override
    public ProcessedEvent process(SourceEvent source) {
        if (simulatedFailureId > 0 && source.id() == simulatedFailureId) {
            throw new IllegalStateException("Fallo inducido para probar reinicio en ID " + source.id());
        }
        if (source.amount() == null || source.amount().signum() < 0) {
            throw new InvalidEventException("Evento " + source.id() + ": importe inválido");
        }
        if (source.category() == null || source.category().isBlank()) {
            throw new InvalidEventException("Evento " + source.id() + ": categoría vacía");
        }
        BigDecimal amount = source.amount().setScale(2, RoundingMode.HALF_UP);
        String category = source.category().strip().toUpperCase(Locale.ROOT);
        String amountBand = amount.compareTo(HIGH_AMOUNT_THRESHOLD) >= 0 ? "HIGH" : "NORMAL";
        return new ProcessedEvent(source.id(), source.customerId(), amount,
                category, amountBand, source.createdAt());
    }
}
