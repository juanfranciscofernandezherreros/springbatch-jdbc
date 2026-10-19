package com.example.batch10m.processing;

import com.example.batch10m.domain.ProcessedEvent;
import com.example.batch10m.domain.SourceEvent;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.OffsetDateTime;

import static org.junit.jupiter.api.Assertions.*;

class EventProcessorTest {
    private final EventProcessor processor = new EventProcessor();
    private final OffsetDateTime created = OffsetDateTime.parse("2026-01-01T00:00:00Z");

    @Test
    void normalizaYClasifica() {
        SourceEvent input = new SourceEvent(1, 5, new BigDecimal("1000.00"), " retail ", created);
        ProcessedEvent result = processor.process(input);
        assertEquals("RETAIL", result.category());
        assertEquals("HIGH", result.amountBand());
        assertEquals(new BigDecimal("1000.00"), result.amount());
        assertEquals(1, result.id());
    }

    @Test
    void clasificaNormalPorDebajoDelUmbral() {
        SourceEvent input = new SourceEvent(2, 5, new BigDecimal("999.99"), "online", created);
        assertEquals("NORMAL", processor.process(input).amountBand());
    }

    @Test
    void rechazaImportesNegativos() {
        SourceEvent input = new SourceEvent(3, 5, new BigDecimal("-1.00"), "online", created);
        assertThrows(InvalidEventException.class, () -> processor.process(input));
    }

    @Test
    void rechazaCategoriaVacia() {
        SourceEvent input = new SourceEvent(4, 5, BigDecimal.ONE, "   ", created);
        assertThrows(InvalidEventException.class, () -> processor.process(input));
    }
}
