#!/usr/bin/env bash
set -Eeuo pipefail
# Comprueba que todos los registros están en destino o han sido rechazados.
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U batch -d batchdb <<'SQL'
SELECT (SELECT count(*) FROM source_events) AS origen,
       (SELECT count(*) FROM processed_events) AS procesados,
       (SELECT count(*) FROM rejected_events) AS rechazados;
SELECT j.job_execution_id, j.status, j.start_time, j.end_time,
       SUM(s.read_count) FILTER (WHERE s.step_name LIKE 'workerStep:%') AS leidos,
       SUM(s.write_count) FILTER (WHERE s.step_name LIKE 'workerStep:%') AS escritos
FROM batch_job_execution j
LEFT JOIN batch_step_execution s ON j.job_execution_id = s.job_execution_id
GROUP BY j.job_execution_id, j.status, j.start_time, j.end_time
ORDER BY j.job_execution_id DESC LIMIT 5;
DO $$
DECLARE missing_count BIGINT;
BEGIN
  SELECT count(*) INTO missing_count
  FROM source_events s
  WHERE NOT EXISTS (SELECT 1 FROM processed_events p WHERE p.id = s.id)
    AND NOT EXISTS (SELECT 1 FROM rejected_events r WHERE r.event_id = s.id);
  IF missing_count > 0 THEN
    RAISE EXCEPTION 'Hay % eventos que no se han procesado ni rechazado', missing_count;
  END IF;
END $$;
SELECT 'VERIFICACION OK: todos los registros tienen salida o rechazo' AS resultado;
SQL
