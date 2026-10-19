@echo off
setlocal EnableExtensions
cd /d "%~dp0"
if not exist "compose.yaml" (
  echo ERROR: ejecuta este archivo desde la raiz del proyecto.
  pause
  exit /b 1
)
where powershell.exe >nul 2>nul
if errorlevel 1 (
  echo ERROR: Windows PowerShell no esta disponible.
  pause
  exit /b 1
)
echo.
echo Benchmark secuencial: base, A, B, C (10.000.000 cada una).
echo Cada prueba genera su HTML y se crea un indice comparativo.
echo El origen se carga una sola vez; el destino se vacia entre pruebas.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\benchmark-10m.ps1" %*
set "BENCH_EXIT=%ERRORLEVEL%"
echo.
if %BENCH_EXIT% EQU 0 (
  echo Benchmark terminado correctamente. Abre reports\benchmark-10m-...\index.html
) else (
  echo Benchmark fallido. Consulta reports\benchmark-10m-...\ para los informes y logs.
)
pause
exit /b %BENCH_EXIT%
