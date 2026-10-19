# Spring Batch JDBC — 10 millones de registros

Ejemplo de ETL en **Java 21, Spring Boot 3.5.16, Spring Batch 5.2 y PostgreSQL 16**. Procesa tablas grandes por páginas de tamaño limitado, mediante particionado de rangos de IDs y escritura JDBC por lotes. Es un ejemplo reproducible y no una garantía de rendimiento ni de ausencia absoluta de errores de memoria.

## Arranque rápido

Requisitos: Docker Compose v2, espacio libre para datos, índices y WAL; Bash o WSL para ejecutar los scripts.

```bash
docker compose up -d db
./scripts/seed.sh 100000
docker compose run --build --rm batch --app.run=true --app.job-key=prueba-001
./scripts/verify.sh
```

Para el **ensayo de 10 millones**:

```bash
./scripts/seed.sh 10000000
docker compose run --rm batch --app.run=true --app.job-key=lote-10m-001
./scripts/verify.sh
```

El primer comando crea 100.000 registros; el segundo añade los restantes hasta 10.000.000 gracias a `ON CONFLICT DO NOTHING`. El job mantiene su estado en las tablas `BATCH_*`. Usa una clave diferente cuando quieras crear una ejecución lógica nueva; **para continuar un job fallido, conserva la misma clave**.

## Arquitectura

```text
source_events (PK: id)
    → IdRangePartitioner (8 rangos por defecto)
    → workerStep (4 hilos)
      → JdbcPagingItemReader (páginas de 1.000)
      → EventProcessor (una fila cada vez)
      → JdbcBatchItemWriter (commit por chunks de 500)
    → processed_events (UPSERT por id)

BATCH_*: checkpoints, estados e historial
rejected_events: auditoría de registros saltados de forma explícita
```

La tabla de origen y los IDs se consideran estables mientras se ejecuta o reinicia un mismo job. Las claves de ordenación son únicas. No se carga la tabla completa en heap. La transformación de muestra normaliza categoría y asigna una banda al importe; cámbiala para tu caso real.

## Parámetros

| Variable | Default | Descripción |
|---|---:|---|
| `BATCH_CHUNK_SIZE` | 500 | Filas por transacción |
| `BATCH_PAGE_SIZE` | 1000 | Filas por página |
| `BATCH_GRID_SIZE` | 8 | Particiones de rangos de ID |
| `BATCH_THREADS` | 4 | Trabajadores concurrentes |
| `BATCH_MAX_SKIPS` | 0 | Registros inválidos descartables por step |
| `DB_POOL_SIZE` | 12 | Conexiones JDBC (configurar en compose.yaml) |
| `BATCH_FAIL_AT_ID` | 0 | Inyecta fallo de prueba en ese ID |
| `SEED_BATCH_SIZE` | 50000 | Tamaño del bloque de carga SQL |

```bash
BATCH_CHUNK_SIZE=1000 BATCH_PAGE_SIZE=2000 BATCH_GRID_SIZE=16 BATCH_THREADS=6 \
  docker compose run --rm batch --app.run=true --app.job-key=perfil-002
```

**Importante**: demasiados threads pueden saturar conexiones/IO. Aumenta el pool de Hikari por encima de los trabajadores, dejando margen para las consultas de control. El heap de demostración está fijado a `-Xmx512m` en Docker Compose; mide uso real de memoria y rendimiento antes de producción.

## Fallos y reinicios

```bash
BATCH_FAIL_AT_ID=42000 docker compose run --rm batch --app.run=true --app.job-key=fallo-001
docker compose run --rm batch --app.run=true --app.job-key=fallo-001
./scripts/verify.sh
```

La primera ejecución falla deliberadamente. La segunda usa la **misma clave** y reanuda los checkpoints persistidos. No alteres los IDs de origen ni `BATCH_GRID_SIZE` entre ambas ejecuciones. Evita arrancar dos procesos para una misma clave simultáneamente. El writer es idempotente (`INSERT ... ON CONFLICT ... DO UPDATE`), de modo que reprocesar el último chunk no duplica filas.

## Tratamiento de errores de datos

Por defecto `BATCH_MAX_SKIPS=0`: un registro inválido provoca fallo visible. Si habilitas descartes, `InvalidEventException` se registra en `rejected_events`; los fallos transitorios de base de datos se reintentan hasta tres veces.

```bash
docker compose exec -T db psql -U batch -d batchdb -c "UPDATE source_events SET amount=-1 WHERE id=42"
BATCH_MAX_SKIPS=1 docker compose run --rm batch --app.run=true --app.job-key=con-rechazo-001
./scripts/verify.sh
```

Los datos de destino de ejecuciones anteriores se conservan. Un entorno real debe definir la conciliación y el reprocesamiento de descartes.

## Desarrollo

`mvn test` ejecuta pruebas unitarias del procesador y del particionado. El Dockerfile compila y ejecuta tests durante el build. Los SQL de inicialización solo se ejecutan cuando el volumen de PostgreSQL está vacío.

```sql
SELECT COUNT(*) FROM source_events;
SELECT COUNT(*) FROM processed_events;
SELECT COUNT(*) FROM rejected_events;
SELECT job_execution_id, status, start_time, end_time FROM batch_job_execution ORDER BY job_execution_id DESC LIMIT 5;
```

`./scripts/verify.sh` realiza una comprobación de que no falten IDs sin salida (procesados o rechazados), pero no sustituye pruebas integradas de fallos y de rendimiento con 10 millones. Prueba primero con 100.000.

## Límites y criterios de producción

- PostgreSQL de demostración tiene contraseña y puerto expuestos para **uso local**, no producción.
- Spring Boot 3.5.16 es la última versión OSS 3.5.x; planifica migrar a Spring Boot 4 y Spring Batch 6 antes de un despliegue nuevo a largo plazo.
- No se implementan cambios concurrentes en origen, replicación, colas, alarmas, tracing ni snapshot consistente; decide esto según tus requisitos.
- Valida memoria, IOPS, WAL, CPU, disco, índices, tamaño de chunks, recuperación real, conexión y capacidad de almacenamiento.
- El trabajo usa un solo proceso y varios hilos, no paralelismo remoto.

Documentación: https://docs.spring.io/spring-batch/reference/5.2/scalability.html
