@echo off
setlocal EnableExtensions EnableDelayedExpansion
REM Punto de entrada unico de todos los tests. Configuracion: test-profiles.csv
cd /d "%~dp0"
if errorlevel 1 goto :fatal
if not exist "compose.yaml" goto :missing
if not exist "test-profiles.csv" goto :missing
if not exist "scripts\benchmark-10m.ps1" goto :missing

set "RUNARGS="
if /I "%~1"=="--help" goto :help
if /I "%~1"=="/?" goto :help
if /I "%~1"=="-Profile" goto :passthrough
if /I "%~1"=="-Records" goto :passthrough
if /I "%~1"=="-SinglePartition" goto :passthrough
if /I "%~1"=="stress150" set "RUNARGS=-Profile stress150"
if /I "%~1"=="simple" set "RUNARGS=-Profile simple"
if /I "%~1"=="benchmark" set "RUNARGS=-Profile benchmark"
if /I "%~1"=="single" set "RUNARGS=-Profile single"
if /I "%~1"=="particion" set "RUNARGS=-Profile single"
if /I "%~1"=="quick" set "RUNARGS=-Profile quick"
if /I "%~1"=="medium" set "RUNARGS=-Profile medium"
if /I "%~1"=="full" set "RUNARGS=-Profile full"
if defined RUNARGS goto :execute
if not "%~1"=="" (
    echo(%~1| findstr /R "^[0-9][0-9]*$" >nul
    if errorlevel 1 goto :invalid
    set "RUNARGS=-Profile custom -Records %~1"
    goto :execute
)

:menu
echo.
echo ====================================================
echo       SPRING BATCH - BANCO DE PRUEBAS
echo ====================================================
echo   [1] Rapida (perfil quick, 100.000 predeterminado)
echo   [2] Intermedia (perfil medium, 1.000.000 predeterminado)
echo   [3] Completa (perfil full, 10.000.000 predeterminado)
echo   [4] Cantidad personalizada (perfil custom)
echo   [5] Benchmark secuencial (base, A, B, C) + HTML
echo   [6] Una particion (perfil single) + HTML
echo   [7] PRUEBA SIMPLE: 1.000 filas, 1 hilo, 500 MB RAM
echo   [8] ESTRES: 1.000 filas, 1 hilo, 150 MB RAM (posible OOM)
echo   [0] Salir
echo.
echo Los valores de cada prueba se editan en test-profiles.csv
echo.
choice /C 123456780 /N /M "Selecciona una opcion: "
if errorlevel 9 exit /b 0
if errorlevel 8 set "RUNARGS=-Profile stress150"
if errorlevel 8 goto :execute
if errorlevel 7 set "RUNARGS=-Profile simple"
if errorlevel 7 goto :execute
if errorlevel 6 set "RUNARGS=-Profile single"
if errorlevel 6 goto :execute
if errorlevel 5 set "RUNARGS=-Profile benchmark"
if errorlevel 5 goto :execute
if errorlevel 4 goto :custom
if errorlevel 3 set "RUNARGS=-Profile full"
if errorlevel 3 goto :execute
if errorlevel 2 set "RUNARGS=-Profile medium"
if errorlevel 2 goto :execute
set "RUNARGS=-Profile quick"
goto :execute

:custom
echo.
set "RECORDS="
set /p "RECORDS=Registros a procesar (1-10000000): "
echo(!RECORDS!| findstr /R "^[0-9][0-9]*$" >nul
if errorlevel 1 goto :invalid
set "RUNARGS=-Profile custom -Records !RECORDS!"
goto :execute

:passthrough
set "RUNARGS=%*"

:execute
where powershell.exe >nul 2>nul
if errorlevel 1 (
    echo ERROR: PowerShell de Windows no disponible.
    goto :fatal
)
echo.
echo Ejecutando: !RUNARGS!
echo Configuracion: test-profiles.csv
echo Informes HTML, CSV y logs: reports\
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\benchmark-10m.ps1" !RUNARGS!
set "EXITCODE=!ERRORLEVEL!"
echo.
if "!EXITCODE!"=="0" (
    echo RESULTADO: OK. Comprueba los informes en reports\
) else (
    echo RESULTADO: ERROR. Revisa los logs en reports\
)
if not "%BATCH_NO_PAUSE%"=="1" pause
exit /b !EXITCODE!

:missing
echo ERROR: faltan compose.yaml, test-profiles.csv o scripts\benchmark-10m.ps1.
echo Actualiza los archivos del repositorio con git pull.
goto :fatal

:invalid
echo ERROR: parametros no validos.
echo Usa test-batch.bat --help para consultar la sintaxis.
goto :fatal

:help
echo USO: test-batch.bat [stress150 ^| simple ^| quick ^| medium ^| full ^| single ^| benchmark ^| cantidad]
echo O sin argumentos para abrir el menu de pruebas.
echo Cada prueba se configura en test-profiles.csv.
echo Opcion 7: 1000 filas, 1 particion, 1 hilo, 500 MiB RAM, heap 256 MiB.
echo Acceso directo: test-batch.bat simple
echo Opcion 8: 1000 filas, 1 particion, 1 hilo, contenedor Batch 150 MiB y heap Java 128 MiB.
echo Acceso directo: test-batch.bat stress150
echo Tambien puedes sobrescribir parametros por ejecucion:
echo test-batch.bat -Profile single -Records 100000 -Chunk 1000 -Page 1000 -Grid 1 -Threads 1 -Pool 6 -HeapMiB 512 -MemoryMiB 1024
echo Para el benchmark: test-batch.bat -Profile benchmark -Records 100000
exit /b 0

:fatal
if not "%BATCH_NO_PAUSE%"=="1" pause
exit /b 1
