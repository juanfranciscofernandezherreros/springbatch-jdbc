@echo off
setlocal EnableExtensions EnableDelayedExpansion
REM Punto de entrada unico de todos los tests. Configuracion: test-profiles.csv
cd /d "%~dp0"
if errorlevel 1 goto :fatal
if not exist "compose.yaml" goto :missing
if not exist "test-profiles.csv" goto :missing
if not exist "scripts\benchmark-10m.ps1" goto :missing

set "RUNARGS="
set "HAS_CLI_OPTIONS="
if /I "%~1"=="--help" goto :help
if /I "%~1"=="/?" goto :help
if /I "%~1"=="reports" goto :view_reports
if /I "%~1"=="informes" goto :view_reports
REM Todos los perfiles del menu y los cuatro escenarios del benchmark aceptan
REM cualquier numero de parametros adicionales (-Records, -Grid, -ReportsDir...).
if /I "%~1"=="quick" set "RUNARGS=-Profile quick"
if /I "%~1"=="medium" set "RUNARGS=-Profile medium"
if /I "%~1"=="full" set "RUNARGS=-Profile full"
if /I "%~1"=="custom" set "RUNARGS=-Profile custom"
if /I "%~1"=="manual" set "RUNARGS=-Profile manual"
if /I "%~1"=="miprueba" set "RUNARGS=-Profile manual"
if /I "%~1"=="benchmark" set "RUNARGS=-Profile benchmark"
if /I "%~1"=="base" set "RUNARGS=-Profile base"
if /I "%~1"=="A" set "RUNARGS=-Profile A"
if /I "%~1"=="B" set "RUNARGS=-Profile B"
if /I "%~1"=="C" set "RUNARGS=-Profile C"
if /I "%~1"=="single" set "RUNARGS=-Profile single"
if /I "%~1"=="particion" set "RUNARGS=-Profile single"
if /I "%~1"=="simple" set "RUNARGS=-Profile simple"
if /I "%~1"=="stress150" set "RUNARGS=-Profile stress150"
if defined RUNARGS (
    shift
    goto :append_cli
)
if not "%~1"=="" goto :cli_or_number
goto :menu

:cli_or_number
echo(%~1| findstr /R "^[0-9][0-9]*$" >nul
if errorlevel 1 goto :passthrough
set "RUNARGS=-Profile custom -Records %~1"
set "HAS_CLI_OPTIONS=1"
shift
goto :append_cli

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
echo   [8] ESTRES: 10 millones, 1 hilo, 150 MB RAM (posible OOM)
echo   [9] MI PRUEBA: introducir todos los valores manualmente
echo   [R] VER TODOS LOS REPORTES (reports\index.html)
echo   [0] Salir
echo.
echo Pulsa Enter al introducir cada parametro para usar el valor por defecto.
echo Los valores iniciales de cada prueba se leen de test-profiles.csv
echo.
choice /C 123456789R0 /N /M "Selecciona una opcion: "
if errorlevel 11 exit /b 0
if errorlevel 10 goto :view_reports
if errorlevel 9 set "RUNARGS=-Profile manual"
if errorlevel 9 goto :interactive_execute
if errorlevel 8 set "RUNARGS=-Profile stress150"
if errorlevel 8 goto :interactive_execute
if errorlevel 7 set "RUNARGS=-Profile simple"
if errorlevel 7 goto :interactive_execute
if errorlevel 6 set "RUNARGS=-Profile single"
if errorlevel 6 goto :interactive_execute
if errorlevel 5 set "RUNARGS=-Profile benchmark"
if errorlevel 5 goto :interactive_execute
if errorlevel 4 goto :custom
if errorlevel 3 set "RUNARGS=-Profile full"
if errorlevel 3 goto :interactive_execute
if errorlevel 2 set "RUNARGS=-Profile medium"
if errorlevel 2 goto :interactive_execute
set "RUNARGS=-Profile quick"
goto :interactive_execute

:custom
set "RUNARGS=-Profile custom"
goto :interactive_execute

:passthrough
REM Modo explicito: test-batch.bat -Profile ... o -ListProfiles
set "RUNARGS=%*"
goto :execute

:append_cli
if "%~1"=="" (
    if defined HAS_CLI_OPTIONS goto :execute
    goto :interactive_execute
)
REM Usar %1 conserva comillas de rutas como "C:\Mis informes".
set "HAS_CLI_OPTIONS=1"
set "RUNARGS=!RUNARGS! %1"
shift
goto :append_cli

:interactive_execute
set "RUNARGS=!RUNARGS! -Interactive"
goto :execute

:view_reports
where powershell.exe >nul 2>nul
if errorlevel 1 goto :fatal
echo.
echo Actualizando indice general con todos los informes guardados...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\update-reports-index.ps1"
if errorlevel 1 goto :fatal
if not exist "%~dp0reports\index.html" goto :fatal
echo Abriendo: %~dp0reports\index.html
start "" "%~dp0reports\index.html"
exit /b 0

:execute
where powershell.exe >nul 2>nul
if errorlevel 1 (
    echo ERROR: PowerShell de Windows no disponible.
    goto :fatal
)
echo.
echo Ejecutando: !RUNARGS!
echo Configuracion: test-profiles.csv
echo Informes HTML, CSV y logs: carpeta reports\ o la indicada con -ReportsDir
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
echo USO: test-batch.bat [manual ^| quick ^| medium ^| full ^| custom ^| benchmark ^| base ^| A ^| B ^| C ^| single ^| simple ^| stress150 ^| cantidad] [opciones]
echo O sin argumentos para abrir el menu de pruebas y responder preguntas.
echo Cada pregunta muestra el valor por defecto. Pulsa Enter para conservarlo.
echo Para ver TODOS los resultados: elige R o ejecuta test-batch.bat reports

echo Opcion 9: MI PRUEBA, para personalizar todos los parametros desde cero.
echo Acceso directo: test-batch.bat manual
echo Con perfil sin parametros, p.ej. test-batch.bat single, tambien pregunta.
echo Para ejecutar sin preguntas usa -Profile single o pasa algun parametro CLI.
echo Para preguntar con parametros CLI: test-batch.bat -Profile single -Interactive.
echo Cada prueba se configura en test-profiles.csv y se puede sobrescribir desde el CLI.
echo Listar todas: test-batch.bat -ListProfiles
echo Opciones: -Records N -Chunk N -Page N -Grid N -Threads N -Pool N -Interactive
echo           -HeapMiB N -MemoryMiB N -SeedBlock N -ReportsDir "RUTA"
echo Ejemplo: test-batch.bat medium -Records 100000 -Grid 1 -Threads 1 -Pool 6
echo Individual: test-batch.bat A -Records 1000 -ReportsDir "C:\Develop\springbatch-jdbc\reports"
echo Benchmark: test-batch.bat benchmark -Records 1000 -Chunk 1000
echo Opcion 7: 1000 filas, 1 particion, 1 hilo, 500 MiB RAM, heap 256 MiB.
echo Acceso directo: test-batch.bat simple
echo Opcion 8: 10 millones, 1 particion, 1 hilo, contenedor Batch 150 MiB y heap Java 128 MiB.
echo Acceso directo: test-batch.bat stress150
echo Tambien puedes sobrescribir parametros por ejecucion:
echo test-batch.bat -Profile single -Records 100000 -Chunk 1000 -Page 1000 -Grid 1 -Threads 1 -Pool 6 -HeapMiB 512 -MemoryMiB 1024
echo Para el benchmark: test-batch.bat -Profile benchmark -Records 100000
exit /b 0

:fatal
if not "%BATCH_NO_PAUSE%"=="1" pause
exit /b 1
