# Spring Batch JDBC — 10 millones de registros

Ejemplo de ETL en **Java 21, Spring Boot 3.5.16, Spring Batch 5.2 y PostgreSQL 16**. Procesa tablas grandes por páginas de tamaño limitado, mediante particionado de rangos de IDs y escritura JDBC por lotes. Es un ejemplo reproducible y no una garantía de rendimiento ni de ausencia absoluta de errores de memoria.

## Prueba desde Windows (BAT, con menú)

Con Docker Desktop iniciado, abre `test-batch.bat` haciendo doble clic. Selecciona **[3]** para generar y procesar **10.000.000 registros**; **[1]** ejecuta 100.000 y **[2]** un millón.

También se puede ejecutar directamente:

```bat
test-batch.bat 10000000
```

El script verifica que existan exactamente diez millones en el origen y el destino, que la ejecución termine `COMPLETED` y que los contadores del job registren exactamente diez millones de lecturas y escrituras, sin saltos. Cada lanzamiento del `.bat` crea un proyecto Docker **aislado** con una base de datos vacía y puerto temporal. Tanto si el job termina correctamente como si falla, ejecuta `docker compose -p <proyecto-temporal> down --volumes --rmi local --remove-orphans`: borra los contenedores, el volumen PostgreSQL y la imagen local de esa prueba. **No elimina los otros proyectos Docker, ni las imágenes base compartidas, ni la caché global de compilación**. Si el `.bat` se cierra a la fuerza, es posible que tengas que ejecutar el comando de limpieza impreso en consola. La prueba de 10 millones todavía no ha sido ejecutada de extremo a extremo en un equipo Windows.

## Prueba más simple con límite de 500 MB

Solo necesitas el archivo **`test-batch.bat`** que ya existe en este repositorio:
elige la **opción 7** o ejecútalo desde CMD con `test-batch.bat simple`.

El perfil `simple` de `test-profiles.csv` configura **1.000 registros, una
partición, un trabajador, chunk de 500, página de 1.000, seis conexiones JDBC,
heap máximo Java de 256 MiB y límite de 500 MiB para el contenedor de Spring Batch**.
PostgreSQL **no tiene un límite de memoria añadido**.

```bat
git pull origin main
test-batch.bat simple
```

Al terminar genera un HTML `prueba-simple.html` y los logs bajo
`reports/prueba-simple-*/` y limpia los contenedores temporales.
Este límite es para toda la memoria del contenedor Batch; si se supera,
Docker podría finalizarlo por falta de memoria (OOM). Para comprobar
los parámetros sin ejecutar Docker:

```bat
test-batch.bat -Profile simple -ValidateOnly
```

## Prueba de estres: contenedor Spring Batch limitado a 150 MiB

En el **unico `test-batch.bat`**, selecciona **[8]** o ejecuta:

```bat
git pull origin main
test-batch.bat stress150
```

El perfil `stress150` de `test-profiles.csv` utiliza **10.000.000 de registros,
una particion, un trabajador, heap maximo JVM de 128 MiB y limite de memoria
del contenedor Batch de 150 MiB** (`BATCH_MEMORY_LIMIT=150m`). PostgreSQL
**no cambia sus limites**.

La prueba es intencionalmente extrema: puede fallar al arrancar Spring Boot,
lanzar `OutOfMemoryError` o terminar con codigo 137 (posible OOM/SIGKILL).
**No se garantiza que falle**, ya que depende del uso real de memoria.
El proceso marca el resultado como fallido cuando corresponde, pero conserva
`reports/prueba-stress150-*/prueba-stress150.html`,
`progreso.log`, `resumen.csv` y `logs/job-stress150.log`.
En caso de fallo se muestra el codigo de salida para el diagnostico.
Solo se eliminan los recursos temporales de este proyecto Docker.

Puedes validar el perfil sin ejecutar Docker, o hacer una prueba corta antes de los 10 millones:

```bat
test-batch.bat -Profile stress150 -ValidateOnly
test-batch.bat -Profile stress150 -Records 1000
```

Esta prueba permite **menos margen de memoria** que los perfiles habituales;
solo se admite para `stress150` y no es una configuracion recomendada para
produccion.

## Configuración parametrizada de todas las pruebas (Windows)

El **único archivo ejecutable BAT** es `test-batch.bat`. Todas sus opciones
leen `test-profiles.csv`; cada fila corresponde a un perfil:

| Menú | Perfil CSV | Qué ejecuta |
|---|---|---|
| 1 | `quick` | 100.000 registros por defecto |
| 2 | `medium` | 1.000.000 por defecto |
| 3 | `full` | 10.000.000 por defecto |
| 4 | `custom` | Cantidad introducida manualmente |
| 5 | `base`, `A`, `B`, `C` | Cuatro escenarios secuenciales |
| 6 | `single` | Una partición y un trabajador |
| 7 | `simple` | 1.000 registros, una partición, un hilo, 500 MiB para Batch |
| 8 | `stress150` | 10.000.000 registros, una partición, un hilo, 150 MiB para Batch; fallo de memoria posible |

Se pueden editar `Records`, `Chunk`, `Page`, `Grid`, `Threads`,
`Pool`, `HeapMiB`, `MemoryMiB` y `SeedBlock` en
`test-profiles.csv` (CSV con comas). El límite de RAM afecta **solo a
Spring Batch**, no al contenedor PostgreSQL.

Prueba rápida de un perfil con solo mil filas:

```bat
git pull origin main
test-batch.bat -Profile single -Records 1000
```

Sobrescritura temporal sin modificar el CSV:

```bat
test-batch.bat -Profile quick -Records 100000 -Chunk 1000 -Page 1000 -Grid 1 -Threads 1 -Pool 6 -HeapMiB 512 -MemoryMiB 1024
```

Para las cuatro pruebas del benchmark con mil filas por escenario:

```bat
test-batch.bat -Profile benchmark -Records 1000
```

Los parámetros se validan antes de iniciar Docker. El pool debe disponer
de al menos `Threads + 2` conexiones; `MemoryMiB` debe superar
`HeapMiB` en un mínimo de 128 MiB. El benchmark mantiene el mismo
número de registros y tamaño de bloque de carga en sus cuatro escenarios
para conservar la comparabilidad. Todos los perfiles generan informes HTML,
`resumen.csv`, `progreso.log` y logs de Spring Batch en `reports/`.

Para comprobar solo parámetros y sintaxis sin arrancar Docker:

```bat
test-batch.bat -Profile single -Records 1000 -ValidateOnly
```

Las configuraciones cargadas, incluyendo heap y memoria máxima del
contenedor, quedan registradas en los informes para poder reproducir las pruebas.

## Prueba con una partición y un trabajador (Windows)

En el **único `test-batch.bat`**, selecciona la **opción 6** para procesar
**10.000.000 de registros con una sola partición y sin paralelismo de workers**.
También puedes ejecutarla directamente desde CMD:

```bat
git pull
test-batch.bat single
```

No tienes que definir variables con `set`. Los valores predeterminados
de esta opción están en el perfil `single` de `test-profiles.csv`
(una partición, un trabajador, chunk de 500, página de 1.000,
pool de 6, heap de 512 MiB y RAM del contenedor Batch de 1.024 MiB).
Puedes modificarlos antes de ejecutar la prueba.

La prueba utiliza una instancia PostgreSQL aislada, genera 10 millones de
registros de origen, procesa el job, verifica todos los contadores y genera
`reports/particion-unica-10m-FECHA-IDENTIFICADOR/` con `index.html`,
**`prueba-single.html`**, `resumen.csv`, `progreso.log` y
`logs/job-single.log`. El progreso se muestra en consola. Al finalizar
se eliminan únicamente los contenedores y el volumen de esta ejecución;
los informes quedan guardados.

Para comprobar el recorrido con pocos datos durante el desarrollo, desde
PowerShell ejecuta:
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/benchmark-10m.ps1 -Records 1000 -SinglePartition`.

Esta opción **no modifica la opción 5**, que sigue comparando base, A, B y C
con 4, 4, 6 y 8 trabajadores respectivamente.

## Benchmark secuencial con HTML (Windows)

**Único BAT:** ejecuta `test-batch.bat` y elige la opción **5**; también puedes usar `test-batch.bat benchmark` desde CMD. Requiere Docker Desktop y Windows PowerShell 5.1. El archivo interno `scripts/benchmark-10m.ps1` realiza las mediciones y genera los HTML; **no es un segundo BAT**.

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
`resumen.csv`, **`progreso.log`** (cronología con porcentaje, registros por segundo
y ETA estimada) y los logs completos de cada trabajo en `logs/job-base.log`,
`logs/job-A.log`, `logs/job-B.log` y `logs/job-C.log`. Los informes HTML incluyen enlaces
a los logs. **Los mensajes se ven en tiempo real en la consola del BAT** durante la
generación de datos, compilación y procesamiento; el tiempo restante es orientativo
porque los contadores del lector se publican por intervalos.

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

**Prueba de humo para desarrolladores:** desde PowerShell puedes ejecutar `powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/benchmark-10m.ps1 -Records 1000`. Las pruebas completas se ejecutan con la opción 5 del BAT, sin parámetros. GitHub Actions valida automáticamente las cuatro pasadas con 1.000 filas y revisa la sintaxis en Windows.

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
