package com.example.batch10m.partition;

import org.junit.jupiter.api.Test;
import org.springframework.batch.item.ExecutionContext;

import java.util.Map;
import java.util.stream.LongStream;

import static org.junit.jupiter.api.Assertions.*;

class IdRangePartitionerTest {
    @Test
    void cubreCadaIdentificadorUnaSolaVez() {
        Map<String, ExecutionContext> partitions = IdRangePartitioner.createPartitions(1, 10, 3);
        assertEquals(3, partitions.size());
        for (long id = 1; id <= 10; id++) {
            final long current = id;
            long matches = partitions.values().stream().filter(context ->
                    context.getLong("minId") <= current && context.getLong("maxId") >= current).count();
            assertEquals(1, matches, "ID sin cobertura o duplicado: " + id);
        }
    }

    @Test
    void soportaMasParticionesQueIds() {
        assertEquals(2, IdRangePartitioner.createPartitions(11, 12, 8).size());
    }

    @Test
    void tablaVaciaCreaUnaParticionVacia() {
        ExecutionContext empty = IdRangePartitioner.createPartitions(1, 0, 4)
                .get("partition0");
        assertNotNull(empty);
        assertTrue(empty.getLong("minId") > empty.getLong("maxId"));
    }

    @Test
    void rechazaGridSizeInvalido() {
        assertThrows(IllegalArgumentException.class,
                () -> IdRangePartitioner.createPartitions(1, 100, 0));
    }
}
