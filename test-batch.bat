@echo off
setlocal EnableExtensions EnableDelayedExpansion
REM Ejecuta desde CMD o haciendo doble clic. Requiere Docker Desktop iniciado.
cd /d "%~dp0"
if errorlevel 1 goto :fail

if not exist "compose.yaml" goto :missing_compose
set "REGISTROS=%~1"
if defined REGISTROS goto :validate_count

:menu
echo.
echo ====================================================
echo       SPRING BATCH - BANCO DE PRUEBAS
echo ====================================================
echo   [1] 100.000 registros (rapida)
echo   [2] 1.000.000 registros (intermedia)
echo   [3] 10.000.000 registros (prueba completa)
echo   [4] Otra cantidad (max. 10.000.000)
echo   [0] Salir
echo.
choice /C 12340 /N /M "Selecciona una opcion: "
if errorlevel 5 exit /b 0
if errorlevel 4 goto :custom
if errorlevel 3 (
  set "REGISTROS=10000000"
  goto :validate_count
)
if errorlevel 2 (
  set "REGISTROS=1000000"
  goto :validate_count
)
if errorlevel 1 (
  set "REGISTROS=100000"
  goto :validate_count
)

:custom
set "REGISTROS="
set /p "REGISTROS=Introduce el numero de registros: "

:validate_count

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

echo [1/6] Iniciando PostgreSQL...
docker compose up -d --wait db
if errorlevel 1 goto :fail

echo.
echo [2/6] Revisando rango de datos existente...
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U batch -d batchdb -c "DO $ BEGIN IF EXISTS (SELECT 1 FROM source_events WHERE id < 1 OR id > !TOTAL!) THEN RAISE EXCEPTION 'Hay registros fuera del rango elegido; usa una base de prueba limpia'; END IF; END $;"
if errorlevel 1 goto :fail

echo.
echo [3/6] Generando registros SQL en bloques de !BLOCK!...
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
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U batch -d batchdb -c "DO $ DECLARE c BIGINT; BEGIN SELECT count(*) INTO c FROM source_events; IF c <> !TOTAL! THEN RAISE EXCEPTION 'Origen con %% filas; se esperaban !TOTAL!', c; END IF; END $;"
if errorlevel 1 goto :fail
echo.
echo [4/6] Compilando imagen de Spring Batch y ejecutando tests...
docker compose build batch
if errorlevel 1 goto :fail

echo.
echo [5/6] Procesando el lote con clave !RUN_KEY!...
docker compose run --rm batch --app.run=true --app.job-key=!RUN_KEY!
if errorlevel 1 goto :fail

echo.
echo [6/6] Verificando exactamente !TOTAL! filas leidas y escritas...
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U batch -d batchdb -c "SELECT (SELECT count(*) FROM source_events) AS origen, (SELECT count(*) FROM processed_events) AS procesados, (SELECT count(*) FROM rejected_events) AS rechazados;"
if errorlevel 1 goto :fail

docker compose exec -T db psql -v ON_ERROR_STOP=1 -U batch -d batchdb -c "DO $$ DECLARE expected BIGINT := !TOTAL!; source_total BIGINT; target_total BIGINT; job_id BIGINT; job_status VARCHAR(10); read_total BIGINT; write_total BIGINT; skip_total BIGINT; BEGIN SELECT count(*) INTO source_total FROM source_events; SELECT count(*) INTO target_total FROM processed_events; SELECT e.job_execution_id, e.status INTO job_id, job_status FROM batch_job_execution e JOIN batch_job_execution_params p ON p.job_execution_id=e.job_execution_id WHERE p.parameter_name='runKey' AND p.parameter_value='!RUN_KEY!' ORDER BY e.job_execution_id DESC LIMIT 1; IF job_id IS NULL THEN RAISE EXCEPTION 'No se encontro la ejecucion actual'; END IF; SELECT COALESCE(SUM(read_count),0), COALESCE(SUM(write_count),0), COALESCE(SUM(read_skip_count+process_skip_count+write_skip_count),0) INTO read_total, write_total, skip_total FROM batch_step_execution WHERE job_execution_id=job_id AND step_name LIKE 'workerStep:%%'; IF source_total <> expected OR target_total <> expected OR job_status <> 'COMPLETED' OR read_total <> expected OR write_total <> expected OR skip_total <> 0 THEN RAISE EXCEPTION 'Validacion fallida: origen=%% destino=%% estado=%% leidos=%% escritos=%% descartados=%% esperado=%%', source_total, target_total, job_status, read_total, write_total, skip_total, expected; END IF; RAISE NOTICE 'VERIFICACION OK: %% registros leidos y escritos; job COMPLETED', expected; END $$;"
if errorlevel 1 goto :fail

docker compose exec -T db psql -v ON_ERROR_STOP=1 -U batch -d batchdb -c "SELECT job_execution_id, status, start_time, end_time FROM batch_job_execution ORDER BY job_execution_id DESC LIMIT 3;"
if errorlevel 1 goto :fail

echo.
echo =====================================================
echo   PRUEBA FINALIZADA: !TOTAL! REGISTROS LEIDOS Y ESCRITOS
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

:missing_compose
echo ERROR: pon el archivo .bat junto a compose.yaml.
goto :fail

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
echo No se borran datos automaticamente; usa un volumen de DEMOSTRACION limpio para probar tamanos menores.
echo Para reiniciar manualmente un job fallido, conserva su app.job-key.
pause
exit /b 1
