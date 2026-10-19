package com.example.batch10m.partition;

import org.springframework.batch.core.partition.support.Partitioner;
import org.springframework.batch.item.ExecutionContext;
import org.springframework.jdbc.core.JdbcTemplate;

import java.util.LinkedHashMap;
import java.util.Map;

/** Divide por rangos de PK; los rangos no se solapan, incluso con huecos en los IDs. */
public class IdRangePartitioner implements Partitioner {
    private final JdbcTemplate jdbcTemplate;

    public IdRangePartitioner(JdbcTemplate jdbcTemplate) {
        this.jdbcTemplate = jdbcTemplate;
    }

    @Override
    public Map<String, ExecutionContext> partition(int gridSize) {
        Bounds bounds = jdbcTemplate.queryForObject(
                "SELECT MIN(id) AS min_id, MAX(id) AS max_id FROM source_events",
                (rs, index) -> new Bounds((Long) rs.getObject("min_id"),
                        (Long) rs.getObject("max_id")));
        if (bounds == null || bounds.minId() == null) {
            return createPartitions(1, 0, gridSize);
        }
        return createPartitions(bounds.minId(), bounds.maxId(), gridSize);
    }

    public static Map<String, ExecutionContext> createPartitions(long minId, long maxId, int gridSize) {
        if (gridSize < 1) {
            throw new IllegalArgumentException("gridSize debe ser >= 1");
        }
        Map<String, ExecutionContext> result = new LinkedHashMap<>();
        if (minId > maxId) {
            // Un step vacío permite completar el job si todavía no hay datos.
            addPartition(result, 0, 1, 0);
            return result;
        }
        long totalSpan = Math.subtractExact(maxId, minId) + 1;
        long partitionSpan = Math.max(1, totalSpan / gridSize + (totalSpan % gridSize == 0 ? 0 : 1));
        long start = minId;
        int number = 0;
        while (start <= maxId) {
            long remaining = maxId - start + 1;
            long end = remaining <= partitionSpan ? maxId : start + partitionSpan - 1;
            addPartition(result, number++, start, end);
            if (end == maxId) {
                break;
            }
            start = end + 1;
        }
        return result;
    }

    private static void addPartition(Map<String, ExecutionContext> result, int number,
                                     long minId, long maxId) {
        ExecutionContext context = new ExecutionContext();
        context.putLong("minId", minId);
        context.putLong("maxId", maxId);
        result.put("partition" + number, context);
    }

    private record Bounds(Long minId, Long maxId) { }
}
