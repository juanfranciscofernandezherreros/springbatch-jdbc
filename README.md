# Spring Batch JDBC — 10 millones de registros

Ejemplo de ETL en **Java 21, Spring Boot 3.5.16, Spring Batch 5.2 y PostgreSQL 16**. Procesa tablas grandes por páginas de tamaño limitado, mediante particionado de rangos de IDs y escritura JDBC por lotes. Es un ejemplo reproducible y no una garantía de rendimiento ni de ausencia absoluta de errores de memoria.

## Prueba desde Windows (BAT, con menú)

Con Docker Desktop iniciado, abre `test-batch.bat` haciendo doble clic. Selecciona **[3]** para generar y procesar **10.000.000 registros**; **[1]** ejecuta 100.000 y **[2]** un millón.

También se puede ejecutar directamente:

```bat
test-batch.bat 10000000
```

El script verifica que existan exactamente diez millones en el origen y el destino, que la ejecución termine `COMPLETED` y que los contadores del job registren exactamente diez millones de lecturas y escrituras, sin saltos. Cada lanzamiento del `.bat` crea un proyecto Docker **aislado** con una base de datos vacía y puerto temporal. Tanto si el job termina correctamente como si falla, ejecuta `docker compose -p <proyecto-temporal> down --volumes --rmi local --remove-orphans`: borra los contenedores, el volumen PostgreSQL y la imagen local de esa prueba. **No elimina los otros proyectos Docker, ni las imágenes base compartidas, ni la caché global de compilación**. Si el `.bat` se cierra a la fuerza, es posible que tengas que ejecutar el comando de limpieza impreso en consola. La prueba de 10 millones todavía no ha sido ejecutada de extremo a extremo en un equipo Windows.

## Benchmark secuencial con HTML (Windows)

**Menú:** ejecuta `test-batch.bat` y elige la opción **5**. Alternativamente,
haz doble clic en **`benchmark-10m.bat`**. Requiere Docker Desktop y Windows
PowerShell 5.1 (o una instalación de PowerShell compatible con el comando del BAT).

El benchmark ejecuta **en orden, sin solapamientos**, cuatro trabajos sobre
los mismos **10.000.000 registros**. Carga una única vez `source_events`
y vacía únicamente `processed_events` y `rejected_events` **entre**
las cuatro pasadas. No borra las tablas de metadatos de Spring Batch entre
ejecuciones; cada prueba usa una clave de job diferente.

| HTML de prueba | Chunk | Página | Particiones | Workers |
|---|---:|---:|---:|---:|
| `prueba-base.html` | 500 | 1.000 | 8 | 4 |
| `prueba-A.html` | 1.000 | 1.000 | 8 | 4 |
| `prueba-B.html` | 1.000 | 1.000 | 12 | 6 |
| `prueba-C.html` | 2.000 | 1.000 | 16 | 8 |

Los resultados se guardan en **`reports/benchmark-10m-FECHA-IDENTIFICADOR/`**,
con `index.html` (comparación), un HTML por cada prueba completada,
`resumen.csv` y los logs de cada trabajo en `logs/`.

La duración y la velocidad de procesamiento proceden de los metadatos de
Spring Batch. El dato de memoria es un aproximado de **pico de heap de la JVM**
sacado del log `PERF_RESULT`: **no** equivale a RAM del contenedor.
El tiempo **no incluye** la creación de los 10 millones de filas,
la compilación Java ni la limpieza de Docker.

**Aislamiento:** el benchmark utiliza un nombre de proyecto Docker temporal.
Al acabar (también si falla) elimina sus contenedores, su volumen y su imagen
local. Los HTML/CSV/logs quedan guardados en tu equipo. Un cierre forzado
de la ventana puede impedir la limpieza; en ese caso revisa el mensaje
mostrado por el script.

**Prueba de humo:** para comprobar el flujo sin cargar 10 millones
puedes ejecutar desde CMD `benchmark-10m.bat -Records 1000`.
Para las pruebas de rendimiento reales, no pases parámetros.

**Limitación del experimento:** las pruebas son secuenciales pero la caché
de PostgreSQL y del sistema operativo puede calentar entre pasadas. No se
debe concluir que una configuración es mejor de forma definitiva sin
repeticiones en diferente orden y seguimiento de I/O.

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
| `DB_POOL_SIZE` | 12 | Conexiones JDBC (configurables por entorno) |
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
