#Requires -Version 5.1
# Benchmark secuencial: base, A, B y C. Cada test produce HTML.
# Ejecutar desde Windows con Docker Desktop: benchmark-10m.bat
param([ValidateRange(1,10000000)][long]$Records = 10000000)

$ErrorActionPreference = 'Stop'
Set-Location (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportDir = Join-Path (Get-Location).Path ("reports\benchmark-10m-" + $stamp + "-" + (Get-Random -Maximum 9999))
New-Item -ItemType Directory -Path (Join-Path $reportDir 'logs') -Force | Out-Null
$project = 'sb10mbench-' + (Get-Random -Maximum 999999)
$env:DB_HOST_PORT = [string](Get-Random -Minimum 30000 -Maximum 61000)
$env:DB_POOL_SIZE = '12'
$env:BATCH_MAX_SKIPS = '0'
$env:BATCH_FAIL_AT_ID = '0'
$started = $false
$failure = $false
$results = New-Object System.Collections.ArrayList
$scenarios = @(
  [pscustomobject]@{ Id='base';Name='Configuracion actual';Chunk=500;Page=1000;Grid=8;Threads=4 },
  [pscustomobject]@{ Id='A';Name='Chunk de 1000';Chunk=1000;Page=1000;Grid=8;Threads=4 },
  [pscustomobject]@{ Id='B';Name='Seis workers';Chunk=1000;Page=1000;Grid=12;Threads=6 },
  [pscustomobject]@{ Id='C';Name='Ocho workers';Chunk=2000;Page=1000;Grid=16;Threads=8 }
)

function EscapeHtml([string]$s) { return [System.Net.WebUtility]::HtmlEncode($s) }
function Docker([string[]]$argv) {
  $out = @(& docker @argv 2>&1)
  if ($LASTEXITCODE -ne 0) { throw "Docker fallo: docker $($argv -join ' ') | $($out -join ' ')" }
  return $out
}
function Sql([string]$query) {
  $argv = @('compose','-p',$project,'exec','-T','db','psql','-X','-v','ON_ERROR_STOP=1','-U','batch','-d','batchdb','-A','-t','-c',$query)
  return (@(Docker $argv) -join [Environment]::NewLine).Trim()
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
<tr><td>Leídos</td><td>$($r.Read)</td></tr><tr><td>Escritos</td><td>$($r.Written)</td></tr>
<tr><td>Descartados</td><td>$($r.Skipped)</td></tr><tr><td>Estado</td><td>$status</td></tr>
</table></section><section><h2>Diagnóstico</h2><pre>$errorMessage</pre></section>
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
  $html = @"
<!doctype html><html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Benchmark Spring Batch</title><style>
body{font:16px Segoe UI,Arial,sans-serif;max-width:1100px;margin:42px auto;padding:0 16px;color:#1d2d42;background:#f5f7fb}
table{border-collapse:collapse;width:100%;background:white}th{background:#243c62;color:white;text-align:left}
td,th{padding:13px;border-bottom:1px solid #e4e9ee}a{color:#225ca2}
p{color:#566678}aside{background:white;border-radius:12px;padding:16px;margin-top:20px}
</style></head><body><h1>Benchmark secuencial - $Records registros</h1>
<p>Completadas $($results.Count) de 4 pruebas. Haz clic en cada una para abrir su informe HTML.</p>
<table><tr><th>Prueba</th><th>Chunk</th><th>Hilos</th><th>Segundos</th><th>Registros/s</th><th>Estado</th></tr>
$($trs -join [Environment]::NewLine)
</table><aside>El origen es el mismo en las cuatro pruebas; se vacía el destino antes de cada ejecución.
La primera pasada puede verse afectada por caché fría. Para un benchmark concluyente, hay que repetir y alternar el orden.</aside>
<p>Resumen también disponible en resumen.csv. La carga de datos inicial y la compilación no cuentan dentro de la duración del job.</p></body></html>
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
  Write-Host "Benchmark secuencial (4 pruebas de $Records registros)"
  Write-Host "HTML y CSV: $reportDir"
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw "Docker no está instalado" }
  [void](Docker @('compose','version'))
  [void](Docker @('info','--format','{{.ServerVersion}}'))
  $started = $true
  [void](Docker @('compose','-p',$project,'up','-d','--wait','db'))
  Write-Host 'Compilando Java (y tests) una sola vez...'
  [void](Docker @('compose','-p',$project,'build','batch'))

  Write-Host "Generando $Records filas de origen una sola vez..."
  for($from=1L; $from -le $Records; $from+=250000L) {
    $to = [math]::Min($from+249999L,$Records)
    $sql="INSERT INTO source_events (id,customer_id,amount,category,created_at) SELECT s,(s % 100000)+1,((s % 200000)::numeric/100),CASE (s % 3) WHEN 0 THEN 'retail' WHEN 1 THEN 'subscription' ELSE 'online' END,TIMESTAMPTZ '2026-01-01 00:00:00+00'+((s % 86400)*INTERVAL '1 second') FROM generate_series($from,$to) AS s;"
    [void](Sql $sql)
    Write-Host "Cargadas $to / $Records"
  }
  if ([long](Sql 'SELECT COUNT(*) FROM source_events;') -ne $Records) { throw "Origen incompleto" }

  foreach($s in $scenarios) {
    $env:BATCH_CHUNK_SIZE=[string]$s.Chunk
    $env:BATCH_PAGE_SIZE=[string]$s.Page
    $env:BATCH_GRID_SIZE=[string]$s.Grid
    $env:BATCH_THREADS=[string]$s.Threads
    $key="bench-$($s.Id)-"+[guid]::NewGuid().ToString('N').Substring(0,16)
    $log=Join-Path $reportDir ("logs\job-$($s.Id).log")
    $r=[pscustomobject]@{ Id=$s.Id;Name=$s.Name;Chunk=$s.Chunk;Page=$s.Page;Grid=$s.Grid;Threads=$s.Threads;Seconds=$null;Throughput=$null;Read=0L;Written=0L;Skipped=0L;HeapMiB=$null;Status='NOT_STARTED';Error='';RunKey=$key }
    Write-Host "PRUEBA $($s.Id): chunk=$($s.Chunk), page=$($s.Page), grid=$($s.Grid), workers=$($s.Threads)"
    try {
      [void](Sql 'TRUNCATE TABLE processed_events,rejected_events;')
      $args=@('compose','-p',$project,'run','--rm','batch','--app.run=true',"--app.job-key=$key")
      & docker @args 2>&1 | Tee-Object -FilePath $log | Out-Host
      if ($LASTEXITCODE -ne 0) { throw "Spring Batch falló. Revisa $log" }
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
      Write-Host "OK $($r.Id): $($r.Seconds) segundos, $($r.Throughput) registros/s"
    }
    catch {
      $r.Status='FAILED'
      $r.Error=$_.Exception.Message
      try {
        $m=Metrics $key; $r.Read=$m.Read; $r.Written=$m.Written; $r.Skipped=$m.Skipped
        $r.Seconds=[math]::Round($m.Millis/1000.0,3)
      } catch {}
      [void]$results.Add($r); SaveReport $r; SaveIndex
      throw "Prueba $($s.Id) falló: $($r.Error). Informe: $reportDir"
    }
    [void]$results.Add($r); SaveReport $r; SaveIndex
    Write-Host "Informe HTML: $(Join-Path $reportDir "prueba-$($r.Id).html")"
  }
  Write-Host "BENCHMARK TERMINADO. Comparativa: $(Join-Path $reportDir 'index.html')"
}
catch {
  $failure=$true
  Write-Warning $_.Exception.Message
}
finally {
  if ($started) {
    Write-Host "Eliminando exclusivamente los recursos Docker de $project..."
    & docker compose -p $project down --volumes --rmi local --remove-orphans | Out-Host
    if ($LASTEXITCODE -ne 0) { Write-Warning "Limpieza incompleta: docker compose -p $project down --volumes --rmi local --remove-orphans" }
  }
  Write-Host "Informes conservados: $reportDir"
}
if ($failure) { exit 1 }
