@echo off
setlocal EnableExtensions EnableDelayedExpansion
REM Ejecuta desde CMD o haciendo doble clic. Requiere Docker Desktop iniciado.
cd /d "%~dp0"
if errorlevel 1 goto :fail

set "REGISTROS=%~1"
if not defined REGISTROS set "REGISTROS=100000"

echo(!REGISTROS!| findstr /R "^[0-9][0-9]*$" >nul
if errorlevel 1 goto :invalid_count
set /a "TOTAL=!REGISTROS!" >nul 2>nul
if errorlevel 1 goto :invalid_count
if !TOTAL! LSS 1 goto :invalid_count
if !TOTAL! GTR 10000000 goto :invalid_count

set "BLOCK=250000"
set "RUN_KEY=windows-!RANDOM!-!RANDOM!-!RANDOM!"
set "BATCH_FAIL_AT_ID=0"
set "BATCH_MAX_SKIPS=0"

echo.
echo =====================================================
echo   SPRING BATCH - PRUEBA DE !TOTAL! REGISTROS

echo =====================================================
echo.

where docker >nul 2>nul
if errorlevel 1 goto :docker_missing

docker compose version >nul 2>nul
if errorlevel 1 goto :compose_missing

docker info >nul 2>nul
if errorlevel 1 goto :docker_stopped

echo [1/5] Iniciando PostgreSQL...
docker compose up -d --wait db
if errorlevel 1 goto :fail

echo.
echo [2/5] Generando registros SQL en bloques de !BLOCK!...
set /a "START=1"
:seed_loop
if !START! GTR !TOTAL! goto :seed_finished
set /a "END=START+BLOCK-1"
if !END! GTR !TOTAL! set "END=!TOTAL!"

docker compose exec -T db psql -v ON_ERROR_STOP=1 -U batch -d batchdb -c "INSERT INTO source_events (id, customer_id, amount, category, created_at) SELECT s, (s %% 100000) + 1, ((s %% 200000)::numeric / 100), CASE (s %% 3) WHEN 0 THEN 'retail' WHEN 1 THEN 'subscription' ELSE 'online' END, TIMESTAMPTZ '2026-01-01 00:00:00+00' + ((s %% 86400) * INTERVAL '1 second') FROM generate_series(!START!, !END!) AS s ON CONFLICT (id) DO NOTHING;"
if errorlevel 1 goto :fail
echo   Registros sembrados: !START! a !END! de !TOTAL!
set /a "START=END+1"
goto :seed_loop

:seed_finished
echo.
echo [3/5] Compilando imagen de Spring Batch y ejecutando tests...
docker compose build batch
if errorlevel 1 goto :fail

echo.
echo [4/5] Procesando el lote con clave !RUN_KEY!...
docker compose run --rm batch --app.run=true --app.job-key=!RUN_KEY!
if errorlevel 1 goto :fail

echo.
echo [5/5] Consultando resultados y comprobando que no falten filas...
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U batch -d batchdb -c "SELECT (SELECT count(*) FROM source_events) AS origen, (SELECT count(*) FROM processed_events) AS procesados, (SELECT count(*) FROM rejected_events) AS rechazados;"
if errorlevel 1 goto :fail

docker compose exec -T db psql -v ON_ERROR_STOP=1 -U batch -d batchdb -c "DO $$ BEGIN IF EXISTS (SELECT 1 FROM source_events s WHERE NOT EXISTS (SELECT 1 FROM processed_events p WHERE p.id=s.id) AND NOT EXISTS (SELECT 1 FROM rejected_events r WHERE r.event_id=s.id)) THEN RAISE EXCEPTION 'Faltan registros sin procesar ni rechazar'; END IF; END $$;"
if errorlevel 1 goto :fail

docker compose exec -T db psql -v ON_ERROR_STOP=1 -U batch -d batchdb -c "SELECT job_execution_id, status, start_time, end_time FROM batch_job_execution ORDER BY job_execution_id DESC LIMIT 3;"
if errorlevel 1 goto :fail

echo.
echo =====================================================
echo   PRUEBA FINALIZADA CORRECTAMENTE

echo   Ejecutada con job-key: !RUN_KEY!
echo =====================================================
echo.
pause
exit /b 0

:invalid_count
echo ERROR: introduce un numero entero entre 1 y 10000000.
echo Ejemplo: test-batch.bat 100000
pause
exit /b 2

:docker_missing
echo ERROR: docker no esta instalado o no esta en PATH.
goto :fail

:compose_missing
echo ERROR: Docker Compose v2 no esta disponible.
goto :fail

:docker_stopped
echo ERROR: Docker Desktop no esta iniciado.
goto :fail

:fail
echo.
echo ERROR: la prueba se ha detenido. Revisa los mensajes anteriores.
echo Los datos y checkpoints permanecen en PostgreSQL.
echo Para reiniciar manualmente un job fallido, conserva su app.job-key.
pause
exit /b 1
