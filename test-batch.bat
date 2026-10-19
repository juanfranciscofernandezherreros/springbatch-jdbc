@echo off
setlocal EnableExtensions EnableDelayedExpansion
REM Ejecuta desde CMD o haciendo doble clic. Requiere Docker Desktop iniciado.
cd /d "%~dp0"
if errorlevel 1 goto :fail

if not exist "compose.yaml" goto :missing_compose
if /I "%~1"=="benchmark" goto :benchmark_menu
if /I "%~1"=="--help" goto :help
if /I "%~1"=="/?" goto :help
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
echo   [5] BENCHMARK: 4 pruebas de 10 millones + HTML
echo   [0] Salir
echo.
choice /C 123450 /N /M "Selecciona una opcion: "
if errorlevel 6 exit /b 0
if errorlevel 5 goto :benchmark_menu
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
set "PROJECT=sb10mtest-!RANDOM!-!RANDOM!"
set /a "DB_HOST_PORT=30000+!RANDOM!"
set "CLEANUP=0"
set "RESULT=1"
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
set "CLEANUP=1"
echo TEST AISLADO: !PROJECT! - Puerto temporal: !DB_HOST_PORT!
echo Los datos de esta ejecucion se eliminaran al finalizar.

echo [1/6] Iniciando PostgreSQL...
docker compose -p !PROJECT! up -d --wait db
if errorlevel 1 goto :fail

echo.
echo [2/5] Preparando base aislada nueva (sin registros previos)...
echo [3/5] Generando registros SQL en bloques de !BLOCK!...
set /a "START=1"
:seed_loop
if !START! GTR !TOTAL! goto :seed_finished
set /a "END=START+BLOCK-1"
if !END! GTR !TOTAL! set "END=!TOTAL!"

docker compose -p !PROJECT! exec -T db psql -v ON_ERROR_STOP=1 -U batch -d batchdb -c "INSERT INTO source_events (id, customer_id, amount, category, created_at) SELECT s, (s %% 100000) + 1, ((s %% 200000)::numeric / 100), CASE (s %% 3) WHEN 0 THEN 'retail' WHEN 1 THEN 'subscription' ELSE 'online' END, TIMESTAMPTZ '2026-01-01 00:00:00+00' + ((s %% 86400) * INTERVAL '1 second') FROM generate_series(!START!, !END!) AS s ON CONFLICT (id) DO NOTHING;"
if errorlevel 1 goto :fail
echo   Registros sembrados: !START! a !END! de !TOTAL!
set /a "START=END+1"
goto :seed_loop

:seed_finished
docker compose -p !PROJECT! exec -T db psql -X -v ON_ERROR_STOP=1 -U batch -d batchdb -c "SELECT 1 / CASE WHEN (SELECT count(*) FROM source_events) = !TOTAL! THEN 1 ELSE 0 END AS comprobacion_origen;"
if errorlevel 1 goto :fail
echo.
echo [4/6] Compilando imagen de Spring Batch y ejecutando tests...
docker compose -p !PROJECT! build batch
if errorlevel 1 goto :fail

echo.
echo [5/6] Procesando el lote con clave !RUN_KEY!...
docker compose -p !PROJECT! run --rm batch --app.run=true --app.job-key=!RUN_KEY!
if errorlevel 1 goto :fail

echo.
echo [6/6] Verificando exactamente !TOTAL! filas leidas y escritas...
docker compose -p !PROJECT! exec -T db psql -v ON_ERROR_STOP=1 -U batch -d batchdb -c "SELECT (SELECT count(*) FROM source_events) AS origen, (SELECT count(*) FROM processed_events) AS procesados, (SELECT count(*) FROM rejected_events) AS rechazados;"
if errorlevel 1 goto :fail

docker compose -p !PROJECT! exec -T db psql -X -v ON_ERROR_STOP=1 -U batch -d batchdb -c "SELECT 1 / CASE WHEN (SELECT count(*) FROM source_events) = !TOTAL! AND (SELECT count(*) FROM processed_events) = !TOTAL! AND (SELECT count(*) FROM rejected_events) = 0 AND EXISTS (SELECT 1 FROM batch_job_execution e JOIN batch_job_execution_params p ON p.job_execution_id = e.job_execution_id WHERE p.parameter_name = 'runKey' AND p.parameter_value = '!RUN_KEY!' AND e.status = 'COMPLETED' AND (SELECT COALESCE(sum(s.read_count),0) FROM batch_step_execution s WHERE s.job_execution_id = e.job_execution_id AND s.step_name LIKE 'workerStep:%%') = !TOTAL! AND (SELECT COALESCE(sum(s.write_count),0) FROM batch_step_execution s WHERE s.job_execution_id = e.job_execution_id AND s.step_name LIKE 'workerStep:%%') = !TOTAL! AND (SELECT COALESCE(sum(s.read_skip_count + s.process_skip_count + s.write_skip_count),0) FROM batch_step_execution s WHERE s.job_execution_id = e.job_execution_id AND s.step_name LIKE 'workerStep:%%') = 0) THEN 1 ELSE 0 END AS prueba_correcta;"
if errorlevel 1 goto :fail

docker compose -p !PROJECT! exec -T db psql -v ON_ERROR_STOP=1 -U batch -d batchdb -c "SELECT job_execution_id, status, start_time, end_time FROM batch_job_execution ORDER BY job_execution_id DESC LIMIT 3;"
if errorlevel 1 goto :fail

echo.
echo =====================================================
echo   PRUEBA FINALIZADA: !TOTAL! REGISTROS LEIDOS Y ESCRITOS
echo   Ejecutada con job-key: !RUN_KEY!
echo =====================================================
echo.
set "RESULT=0"
goto :finish

:benchmark_menu
where powershell.exe >nul 2>nul
if errorlevel 1 (
    echo ERROR: PowerShell de Windows no esta instalado o no aparece en PATH.
    pause
    exit /b 1
)
if not exist "%~dp0scripts\benchmark-10m.ps1" (
    echo ERROR: falta scripts\benchmark-10m.ps1.
    echo Ejecuta git pull para descargar todos los archivos nuevos.
    pause
    exit /b 1
)
echo.
echo BENCHMARK SECUENCIAL: BASE, A, B y C. 10.000.000 registros por prueba.
echo Los HTML individuales y la comparativa se guardan en reports\.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\benchmark-10m.ps1"
set "BENCH_EXIT=%ERRORLEVEL%"
echo.
if "%BENCH_EXIT%"=="0" (
  echo Benchmark completado. Comprueba la carpeta reports\.
) else (
  echo Benchmark fallido. Revisa el diagnostico en la consola y en reports\.
)
pause
exit /b %BENCH_EXIT%

:help
echo USO: test-batch.bat [cantidad ^| benchmark ^| --help]
echo Sin argumentos muestra el menu. Opcion 5: 4 pruebas secuenciales + informes HTML.
echo Ejecutar directamente: test-batch.bat benchmark
exit /b 0

:invalid_count
echo ERROR: introduce un numero entero entre 1 y 10000000.
echo Ejemplo: test-batch.bat 100000
set "RESULT=2"
goto :finish

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
if "!CLEANUP!"=="1" (
    echo Ultimas ejecuciones en PostgreSQL para diagnostico:
    docker compose -p !PROJECT! exec -T db psql -X -U batch -d batchdb -c "SELECT job_execution_id,status,exit_code,LEFT(exit_message,250) FROM batch_job_execution ORDER BY job_execution_id DESC LIMIT 3;"
)
set "RESULT=1"

:finish
if "!CLEANUP!"=="1" (
    echo.
    echo Limpiando exclusivamente el proyecto temporal !PROJECT!...
    docker compose -p !PROJECT! down --volumes --rmi local --remove-orphans
    if errorlevel 1 (
        echo ADVERTENCIA: limpieza incompleta. Ejecuta el comando siguiente manualmente:
        echo docker compose -p !PROJECT! down --volumes --rmi local --remove-orphans
        set "RESULT=1"
    ) else (
        echo Contenedores y volumenes de esta prueba eliminados.
    )
)
echo.
if "!RESULT!"=="0" (
    echo RESULTADO: OK
) else (
    echo RESULTADO: ERROR
)
pause
exit /b !RESULT!
