#Requires -Version 5.1
# Modos: benchmark secuencial base/A/B/C o prueba independiente de una particion.
# Ejecutar desde Windows con Docker Desktop: test-batch.bat (opcion 5 o 6)
param(
  [ValidateSet('benchmark','quick','medium','full','custom','single')]
  [string]$Profile = 'benchmark',
  [ValidateRange(0,10000000)][long]$Records = 0,
  [ValidateRange(0,100000)][int]$Chunk = 0,
  [ValidateRange(0,100000)][int]$Page = 0,
  [ValidateRange(0,256)][int]$Grid = 0,
  [ValidateRange(0,128)][int]$Threads = 0,
  [ValidateRange(0,256)][int]$Pool = 0,
  [ValidateRange(0,65536)][int]$HeapMiB = 0,
  [ValidateRange(0,65536)][int]$MemoryMiB = 0,
  [ValidateRange(0,1000000)][int]$SeedBlock = 0,
  [switch]$SinglePartition
)

$ErrorActionPreference = 'Stop'
Set-Location (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
# El CSV contiene la configuracion de TODAS las pruebas y puede editarse sin tocar codigo.
$mode = if ($SinglePartition) { 'single' } else { $Profile }
$configPath = Join-Path (Get-Location).Path 'test-profiles.csv'
if (-not (Test-Path -LiteralPath $configPath)) { throw "Falta test-profiles.csv. Ejecuta git pull." }
$configRows = @(Import-Csv -LiteralPath $configPath -Encoding UTF8)
$ids = if ($mode -eq 'benchmark') { @('base','A','B','C') } else { @($mode) }
if (@($configRows.Profile | Select-Object -Unique).Count -ne $configRows.Count) { throw 'Hay perfiles duplicados en test-profiles.csv' }
$scenarios = foreach ($id in $ids) {
  $row = @($configRows | Where-Object { $_.Profile -ceq $id })
  if ($row.Count -ne 1) { throw "Debe existir exactamente un perfil '$id' en test-profiles.csv" }
  $item = $row[0]
  $fields = @('Records','Chunk','Page','Grid','Threads','Pool','HeapMiB','MemoryMiB','SeedBlock')
  foreach ($field in $fields) {
    $value = [string]$item.$field
    if ($value -notmatch '^[0-9]+$') { throw "Valor invalido para $id/$field en CSV: '$value'" }
  }
  $label = switch ($id) {
    'base' {'Configuracion actual'}
    'A' {'Chunk de 1000'}
    'B' {'Seis workers'}
    'C' {'Ocho workers'}
    'single' {'Una particion'}
    'quick' {'Prueba rapida'}
    'medium' {'Prueba intermedia'}
    'full' {'Prueba completa'}
    default {'Prueba personalizada'}
  }
  $entry = [pscustomobject]@{
    Id=$id; Name=$label;
    Records=[long]$item.Records;
    Chunk=[int]$item.Chunk; Page=[int]$item.Page; Grid=[int]$item.Grid;
    Threads=[int]$item.Threads; Pool=[int]$item.Pool;
    HeapMiB=[int]$item.HeapMiB; MemoryMiB=[int]$item.MemoryMiB;
    SeedBlock=[int]$item.SeedBlock
  }
  foreach ($override in @('Chunk','Page','Grid','Threads','Pool','HeapMiB','MemoryMiB','SeedBlock')) {
    $overrideValue = (Get-Variable -Name $override -ValueOnly)
    if ($overrideValue -gt 0) { $entry.$override = $overrideValue }
  }
  if ($Records -gt 0) { $entry.Records = $Records }
  if ($entry.Records -lt 1 -or $entry.Records -gt 10000000) { throw "Registros fuera de rango en $id (1..10.000.000)" }
  if ($entry.Chunk -lt 1 -or $entry.Page -lt 1 -or $entry.Grid -lt 1 -or $entry.Threads -lt 1 -or $entry.SeedBlock -lt 1) {
    throw "Chunk/Page/Grid/Threads/SeedBlock deben ser positivos en $id"
  }
  if ($entry.Pool -lt $entry.Threads + 2) { throw "Pool JDBC de $id ($($entry.Pool)) debe ser al menos Threads+2 ($($entry.Threads + 2))" }
  if ($entry.HeapMiB -lt 128 -or $entry.MemoryMiB -lt $entry.HeapMiB + 128) {
    throw "En $id, HeapMiB >= 128 y MemoryMiB >= HeapMiB + 128 (margen para memoria no heap)"
  }
  $entry
}
if ($scenarios.Count -gt 1) {
  $uniqueCounts = @($scenarios | Select-Object -ExpandProperty Records -Unique)
  if ($uniqueCounts.Count -ne 1) { throw 'Todos los escenarios del benchmark deben tener el mismo Records en el CSV (o pasar -Records)' }
  $uniqueBlocks = @($scenarios | Select-Object -ExpandProperty SeedBlock -Unique)
  if ($uniqueBlocks.Count -ne 1) { throw 'Todos los escenarios del benchmark deben usar el mismo SeedBlock' }
}
$Records = [long]$scenarios[0].Records
$seedBlockValue = [long]$scenarios[0].SeedBlock
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportPrefix = switch ($mode) {
  'benchmark' { 'benchmark-10m-' }
  'single' { 'particion-unica-10m-' }
  default { 'prueba-' + $mode + '-' }
}
$modeLabel = switch ($mode) {
  'benchmark' { 'Benchmark secuencial' }
  'single' { 'Prueba con una particion' }
  default { 'Prueba parametrizada ' + $mode }
}
$reportDir = Join-Path (Get-Location).Path ("reports\" + $reportPrefix + $stamp + "-" + (Get-Random -Maximum 9999))
New-Item -ItemType Directory -Path (Join-Path $reportDir 'logs') -Force | Out-Null
$project = 'sb10mbench-' + (Get-Random -Maximum 999999)
$env:DB_HOST_PORT = [string](Get-Random -Minimum 30000 -Maximum 61000)
$env:BATCH_MAX_SKIPS = '0'
$env:BATCH_FAIL_AT_ID = '0'
$started = $false
$failure = $false
$results = New-Object System.Collections.ArrayList
$scenarioCount = $scenarios.Count

function EscapeHtml([string]$s) { return [System.Net.WebUtility]::HtmlEncode($s) }
function ProgressLog([string]$message) {
  $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $message)
  Write-Host $line
  Add-Content -LiteralPath (Join-Path $reportDir 'progreso.log') -Value $line -Encoding UTF8
}
function Invoke-DockerCommand([string[]]$argv, [switch]$ShowOutput) {
  if ($ShowOutput) {
    # Solo para comandos sin resultado SQL. Muestra el output en vivo.
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      & docker @argv 2>&1 | ForEach-Object { Write-Host ([string]$_) }
      $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $oldPreference }
    if ($code -ne 0) { throw "Docker fallo (codigo $code): docker $($argv -join ' ')" }
    return
  }
  # Separar stdout de stderr es indispensable con PowerShell 5.1:
  # Docker Compose puede escribir progreso en stderr y romper la conversion
  # a [long] de los resultados de psql si se mezclan los dos streams.
  $outPath = [System.IO.Path]::GetTempFileName()
  $errPath = [System.IO.Path]::GetTempFileName()
  try {
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      & docker @argv 1> $outPath 2> $errPath
      $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $oldPreference }
    $out = [System.IO.File]::ReadAllText($outPath)
    $err = [System.IO.File]::ReadAllText($errPath)
    if ($code -ne 0) {
      throw "Docker termino con codigo ${code}: docker $($argv -join ' ')`n$out`n$err"
    }
    return $out.Trim()
  }
  finally {
    Remove-Item -LiteralPath $outPath,$errPath -Force -ErrorAction SilentlyContinue
  }
}
function Sql([string]$query) {
  $argv = @('compose','-p',$project,'exec','-T','db','psql','-X','-v','ON_ERROR_STOP=1','-U','batch','-d','batchdb','-A','-t','-c',$query)
  return (@(Invoke-DockerCommand $argv) -join [Environment]::NewLine).Trim()
}
function SaveReport($r) {
  $seconds = if ($null -ne $r.Seconds) { '{0:N2} s' -f $r.Seconds } else { 'Sin medicion' }
  $throughput = if ($null -ne $r.Throughput) { '{0:N0} reg/s' -f $r.Throughput } else { 'Sin medicion' }
  $heap = if ($null -ne $r.HeapMiB) { "$($r.HeapMiB) MiB" } else { 'Sin dato' }
  $name = EscapeHtml $r.Name
  $errorMessage = EscapeHtml $r.Error
  $status = EscapeHtml $r.Status
  $html = @"
<!doctype html><html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Spring Batch - Prueba $($r.Id)</title>
<style>
body{font:16px Segoe UI,Arial,sans-serif;background:#f5f7fb;color:#172438;max-width:900px;margin:36px auto;padding:0 18px}
header{display:flex;align-items:center;justify-content:space-between;gap:12px;flex-wrap:wrap}
h1{font-size:30px}a{color:#2563a8}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px}
.card,section{background:#fff;border:1px solid #e1e7ed;border-radius:14px;padding:20px;margin:12px 0}
.small{font-size:13px;color:#536477}.num{font-size:26px;font-weight:750;margin-top:8px}
table{width:100%;border-collapse:collapse}td{padding:10px;border-bottom:1px solid #eef1f5}td:last-child{text-align:right;font-weight:600}
pre{white-space:pre-wrap;overflow-wrap:anywhere;color:#a33636}footer{color:#596b7a;font-size:13px;margin:20px 0}
</style></head><body>
<header><div><a href="index.html">Volver a comparativa</a><h1>Prueba $($r.Id): $name</h1></div><strong>$status</strong></header>
<p>Spring Batch + PostgreSQL | $Records registros de origen | ejecución secuencial</p>
<div class="cards"><div class="card"><div class="small">Duración job</div><div class="num">$seconds</div></div>
<div class="card"><div class="small">Velocidad</div><div class="num">$throughput</div></div>
<div class="card"><div class="small">Registros escritos</div><div class="num">$($r.Written)</div></div>
<div class="card"><div class="small">Heap JVM (suma picos)</div><div class="num">$heap</div></div></div>
<section><h2>Configuración y validación</h2><table>
<tr><td>Chunk</td><td>$($r.Chunk)</td></tr><tr><td>Page</td><td>$($r.Page)</td></tr>
<tr><td>Particiones</td><td>$($r.Grid)</td></tr><tr><td>Hilos</td><td>$($r.Threads)</td></tr>
<tr><td>Pool JDBC</td><td>$($r.DbPool)</td></tr>
<tr><td>Heap maximo JVM</td><td>$($r.HeapLimitMiB) MiB</td></tr>
<tr><td>Memoria maxima contenedor Spring Batch</td><td>$($r.MemoryLimitMiB) MiB</td></tr>
<tr><td>Bloque carga de origen</td><td>$($r.SeedBlock)</td></tr>
<tr><td>Leídos</td><td>$($r.Read)</td></tr><tr><td>Escritos</td><td>$($r.Written)</td></tr>
<tr><td>Descartados</td><td>$($r.Skipped)</td></tr><tr><td>Estado</td><td>$status</td></tr>
</table></section><section><h2>Registros de ejecución</h2><p><a href="logs/job-$($r.Id).log">Log completo de Spring Batch</a> · <a href="progreso.log">Progreso global</a></p></section>
<section><h2>Diagnóstico</h2><pre>$errorMessage</pre></section>
<footer>Tiempo y contadores: tablas Spring Batch; heap: suma de picos reportados por pools JVM (no equivale a toda la RAM de Docker).
No incluye inserción inicial, compilación ni limpieza. Informe medido en el PC que ejecuta el script.</footer>
</body></html>
"@
  [System.IO.File]::WriteAllText((Join-Path $reportDir "prueba-$($r.Id).html"),$html,[System.Text.Encoding]::UTF8)
}
function SaveIndex {
  $trs = foreach($r in $results) {
    $t = if ($null -ne $r.Seconds) { '{0:N2}' -f $r.Seconds } else { '-' }
    $speed = if ($null -ne $r.Throughput) { '{0:N0}' -f $r.Throughput } else { '-' }
    "<tr><td><a href='prueba-$($r.Id).html'>$($r.Id) - $(EscapeHtml $r.Name)</a></td><td>$($r.Chunk)</td><td>$($r.Threads)</td><td>$t</td><td>$speed</td><td>$($r.Status)</td></tr>"
  }
  $explanation = if ($mode -eq 'single') {
    'Prueba independiente de un solo trabajador y una sola particion. El tiempo corresponde exclusivamente al job.'
  } else {
    'Las pruebas usan el mismo origen; la caché de PostgreSQL puede mejorar las pasadas posteriores.'
  }
  $html = @"
<!doctype html><html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>$modeLabel Spring Batch</title><style>
body{font:16px Segoe UI,Arial,sans-serif;max-width:1100px;margin:42px auto;padding:0 16px;color:#1d2d42;background:#f5f7fb}
table{border-collapse:collapse;width:100%;background:white}th{background:#243c62;color:white;text-align:left}
td,th{padding:13px;border-bottom:1px solid #e4e9ee}a{color:#225ca2}
p{color:#566678}aside{background:white;border-radius:12px;padding:16px;margin-top:20px}
</style></head><body><h1>$modeLabel - $Records registros</h1>
<p>Completadas $($results.Count) de $scenarioCount prueba(s). Haz clic para abrir su informe HTML.</p>
<table><tr><th>Prueba</th><th>Chunk</th><th>Hilos</th><th>Segundos</th><th>Registros/s</th><th>Estado</th></tr>
$($trs -join [Environment]::NewLine)
</table><aside>$explanation</aside>
<p>Consulta también <a href="progreso.log">el registro de progreso</a> y los logs de cada job en <code>logs/</code>.</p>
<p>Resumen disponible en resumen.csv. La carga inicial y la compilación no cuentan dentro de la duración del job.</p></body></html>
"@
  [System.IO.File]::WriteAllText((Join-Path $reportDir 'index.html'),$html,[System.Text.Encoding]::UTF8)
  $results | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $reportDir 'resumen.csv')
}
function Metrics([string]$jobKey) {
  $query = "SELECT e.status || '|' || COALESCE(ROUND(EXTRACT(EPOCH FROM(e.end_time-e.start_time))*1000)::bigint,0)::text || '|' || COALESCE(SUM(s.read_count),0)::text || '|' || COALESCE(SUM(s.write_count),0)::text || '|' || COALESCE(SUM(s.read_skip_count+s.process_skip_count+s.write_skip_count),0)::text FROM batch_job_execution e JOIN batch_job_execution_params p ON p.job_execution_id=e.job_execution_id LEFT JOIN batch_step_execution s ON s.job_execution_id=e.job_execution_id AND s.step_name LIKE 'workerStep:%' WHERE p.parameter_name='runKey' AND p.parameter_value='$jobKey' GROUP BY e.job_execution_id,e.status,e.start_time,e.end_time ORDER BY e.job_execution_id DESC LIMIT 1;"
  $line = Sql $query
  $fields = $line.Split('|')
  if ($fields.Length -ne 5) { throw "Metadatos no encontrados: $line" }
  return [pscustomobject]@{ Status=$fields[0]; Millis=[long]$fields[1]; Read=[long]$fields[2]; Written=[long]$fields[3]; Skipped=[long]$fields[4] }
}

try {
  ProgressLog ("{0}: {1} prueba(s) de {2:N0} registros" -f $modeLabel,$scenarioCount,$Records)
  ProgressLog "Informes HTML/CSV y logs: $reportDir"
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw "Docker no está instalado" }
  [void](Invoke-DockerCommand -argv @('compose','version'))
  [void](Invoke-DockerCommand -argv @('info','--format','{{.ServerVersion}}'))
  $started = $true
  ProgressLog "FASE 1/3: arrancando PostgreSQL en un proyecto Docker temporal"
  Invoke-DockerCommand -argv @('compose','-p',$project,'up','-d','--wait','db') -ShowOutput
  ProgressLog "FASE 2/3: compilando Java y ejecutando los tests"
  Invoke-DockerCommand -argv @('compose','-p',$project,'build','batch') -ShowOutput

  ProgressLog "FASE 3/3: cargando $Records filas de origen una sola vez"
  $seedWatch = [System.Diagnostics.Stopwatch]::StartNew()
  for($from=1L; $from -le $Records; $from+=$seedBlockValue) {
    $to = [math]::Min($from+$seedBlockValue-1,$Records)
    $sql="INSERT INTO source_events (id,customer_id,amount,category,created_at) SELECT s,(s % 100000)+1,((s % 200000)::numeric/100),CASE (s % 3) WHEN 0 THEN 'retail' WHEN 1 THEN 'subscription' ELSE 'online' END,TIMESTAMPTZ '2026-01-01 00:00:00+00'+((s % 86400)*INTERVAL '1 second') FROM generate_series($from,$to) AS s;"
    [void](Sql $sql)
    $seedPercent = [math]::Round(100.0 * $to / $Records, 1)
    ProgressLog ("CARGA: {0:N0}/{1:N0} registros ({2:N1}%) en {3:N1}s" -f $to,$Records,$seedPercent,$seedWatch.Elapsed.TotalSeconds)
  }
  $seedWatch.Stop()
  if ([long](Sql 'SELECT COUNT(*) FROM source_events;') -ne $Records) { throw "Origen incompleto" }
  ProgressLog ("Carga terminada: {0:N0} registros en {1:N1} s" -f $Records,$seedWatch.Elapsed.TotalSeconds)

  foreach($s in $scenarios) {
    $env:BATCH_CHUNK_SIZE=[string]$s.Chunk
    $env:BATCH_PAGE_SIZE=[string]$s.Page
    $env:BATCH_GRID_SIZE=[string]$s.Grid
    $env:BATCH_THREADS=[string]$s.Threads
    $env:DB_POOL_SIZE=[string]$s.Pool
    $env:BATCH_HEAP_LIMIT=('{0}m' -f $s.HeapMiB)
    $env:BATCH_MEMORY_LIMIT=('{0}m' -f $s.MemoryMiB)
    $key="bench-$($s.Id)-"+[guid]::NewGuid().ToString('N').Substring(0,16)
    $log=Join-Path $reportDir ("logs\job-$($s.Id).log")
    $r=[pscustomobject]@{ Id=$s.Id;Name=$s.Name;Chunk=$s.Chunk;Page=$s.Page;Grid=$s.Grid;Threads=$s.Threads;DbPool=$s.Pool;HeapLimitMiB=$s.HeapMiB;MemoryLimitMiB=$s.MemoryMiB;SeedBlock=$s.SeedBlock;Seconds=$null;Throughput=$null;Read=0L;Written=0L;Skipped=0L;HeapMiB=$null;Status='NOT_STARTED';Error='';RunKey=$key }
    ProgressLog ("PRUEBA {0}/{1}: registros={2}, chunk={3}, page={4}, particiones={5}, hilos={6}, pool={7}, heap={8}MiB, contenedor={9}MiB" -f $s.Id,$scenarioCount,$Records,$s.Chunk,$s.Page,$s.Grid,$s.Threads,$s.Pool,$s.HeapMiB,$s.MemoryMiB)
    try {
      [void](Sql 'TRUNCATE TABLE processed_events,rejected_events;')
      $commandArgs=@('compose','-p',$project,'run','--rm','batch','--app.run=true',"--app.job-key=$key")
      # La salida anterior se guardaba en archivos temporales y solo se
      # mostraba al terminar. Ahora cada linea se imprime y se guarda en vivo.
      $partitionProgress = @{}
      $previousPercent = -1.0
      $lastProgressSeconds = -20.0
      $jobWatch = [System.Diagnostics.Stopwatch]::StartNew()
      $oldPreference = $ErrorActionPreference
      $ErrorActionPreference = 'Continue'
      try {
        & docker @commandArgs 2>&1 | ForEach-Object {
          $line = [string]$_
          Add-Content -LiteralPath $log -Value $line -Encoding UTF8
          Write-Host $line
          # Mensajes emitidos por ChunkListener cada 100.000 registros/particion.
          # El total global es una estimacion entre checkpoints.
          if ($line -match 'PROGRESO.*partition(\d+).*escritos=(\d+)') {
            $partitionProgress[$Matches[1]] = [long]$Matches[2]
            $totalWritten = [long](($partitionProgress.Values | Measure-Object -Sum).Sum)
            $percent = [math]::Min(100.0, [math]::Round(100.0 * $totalWritten / $Records, 1))
            $elapsed = [math]::Max(0.001, $jobWatch.Elapsed.TotalSeconds)
            if (($percent -ge $previousPercent + 1.0) -or
                ($elapsed -ge $lastProgressSeconds + 15.0)) {
              $rate = [math]::Round($totalWritten / $elapsed, 0)
              $remaining = if ($rate -gt 0) { [math]::Ceiling(($Records - $totalWritten) / $rate) } else { 0 }
              ProgressLog ("PRUEBA {0} AVANCE: {1:N0}/{2:N0} ({3:N1}%), {4:N0} reg/s aprox., ETA {5:N0}s" -f $s.Id,$totalWritten,$Records,$percent,$rate,$remaining)
              $previousPercent = $percent
              $lastProgressSeconds = $elapsed
            }
          }
        }
        $jobExitCode = $LASTEXITCODE
      }
      finally {
        $ErrorActionPreference = $oldPreference
        $jobWatch.Stop()
      }
      if ($jobExitCode -ne 0) { throw "Spring Batch fallo (codigo=$jobExitCode). Log: $log" }
      $m=Metrics $key
      $r.Status=$m.Status; $r.Read=$m.Read; $r.Written=$m.Written; $r.Skipped=$m.Skipped
      $r.Seconds=[math]::Round($m.Millis/1000.0,3)
      if ($m.Millis -gt 0) { $r.Throughput=[math]::Round($m.Written*1000.0/$m.Millis,0) }
      $match=[regex]::Match([System.IO.File]::ReadAllText($log),'PERF_RESULT .*?heapPeakMiB=(\d+)')
      if ($match.Success) { $r.HeapMiB=[long]$match.Groups[1].Value }
      $dest=[long](Sql 'SELECT COUNT(*) FROM processed_events;')
      $reject=[long](Sql 'SELECT COUNT(*) FROM rejected_events;')
      if ($r.Status -ne 'COMPLETED' -or $r.Read -ne $Records -or $r.Written -ne $Records -or $r.Skipped -ne 0 -or $dest -ne $Records -or $reject -ne 0) {
        throw "Verificación fallida: estado=$($r.Status), leído=$($r.Read), escrito=$($r.Written), destino=$dest, rechazados=$reject"
      }
      ProgressLog ("PRUEBA {0} OK: {1:N3}s, {2:N0} registros/s, escritos={3:N0}" -f $r.Id,$r.Seconds,$r.Throughput,$r.Written)
    }
    catch {
      $r.Status='FAILED'
      $r.Error=$_.Exception.Message
      ProgressLog ("PRUEBA {0} ERROR: {1}" -f $s.Id,$r.Error)
      try {
        $m=Metrics $key; $r.Read=$m.Read; $r.Written=$m.Written; $r.Skipped=$m.Skipped
        $r.Seconds=[math]::Round($m.Millis/1000.0,3)
      } catch {}
      [void]$results.Add($r); SaveReport $r; SaveIndex
      throw "Prueba $($s.Id) falló: $($r.Error). Informe: $reportDir"
    }
    [void]$results.Add($r); SaveReport $r; SaveIndex
    ProgressLog "Informe HTML generado: $(Join-Path $reportDir "prueba-$($r.Id).html")"
  }
  ProgressLog "BENCHMARK TERMINADO. Comparativa: $(Join-Path $reportDir 'index.html')"
}
catch {
  $failure=$true
  ProgressLog "ERROR GENERAL: $($_.Exception.Message)"
  Write-Warning $_.Exception.Message
}
finally {
  if ($started) {
    Write-Host "Eliminando exclusivamente los recursos Docker de $project..."
    & docker compose -p $project down --volumes --rmi local --remove-orphans | Out-Host
    if ($LASTEXITCODE -ne 0) { Write-Warning "Limpieza incompleta: docker compose -p $project down --volumes --rmi local --remove-orphans" }
  }
  Write-Host "Informes conservados: $reportDir"
  Write-Host "Abre en tu navegador: $(Join-Path $reportDir 'index.html')"
}
if ($failure) { exit 1 }
