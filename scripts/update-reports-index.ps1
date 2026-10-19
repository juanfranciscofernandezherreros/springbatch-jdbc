#Requires -Version 5.1
<#
  Crea reports/index.html reuniendo TODOS los informes existentes, incluidos
  los de ejecuciones antiguas y las carpetas de informes anidadas.
  No modifica ni elimina ningun reporte individual.
  Compatible con Windows PowerShell 5.1 y PowerShell 7.
#>
param(
  [string]$ReportsDir = '',
  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$root = if ([string]::IsNullOrWhiteSpace($ReportsDir)) {
  Join-Path $projectRoot 'reports'
} elseif ([System.IO.Path]::IsPathRooted($ReportsDir)) {
  [System.IO.Path]::GetFullPath($ReportsDir)
} else {
  [System.IO.Path]::GetFullPath((Join-Path $projectRoot $ReportsDir))
}
New-Item -ItemType Directory -Path $root -Force | Out-Null

function Html([object]$value) {
  return [System.Net.WebUtility]::HtmlEncode([string]$value)
}
function Href([string]$path) {
  $relative = $path.Substring($root.TrimEnd('\','/').Length).TrimStart('\','/')
  $segments = @($relative -split '[\\/]' | ForEach-Object { [System.Uri]::EscapeDataString($_) })
  return ($segments -join '/')
}

# Detectar ejecuciones tambien en raices anidadas (por ejemplo reports/manual tests).
# No incluir indices maestros de subcarpetas que no representen una ejecucion.
$dirs = @(Get-ChildItem -LiteralPath $root -Directory -Recurse -ErrorAction Stop | Where-Object {
  (Test-Path -LiteralPath (Join-Path $_.FullName 'resumen.csv') -PathType Leaf) -or
  (Test-Path -LiteralPath (Join-Path $_.FullName 'progreso.log') -PathType Leaf) -or
  (($_.Name -match '^(prueba-|benchmark-|particion-)') -and
   (Test-Path -LiteralPath (Join-Path $_.FullName 'index.html') -PathType Leaf))
} | Sort-Object -Property LastWriteTime -Descending)

$good = 0
$bad = 0
$other = 0
$htmlRows = New-Object 'System.Collections.Generic.List[string]'

foreach ($dir in $dirs) {
  $csvPath = Join-Path $dir.FullName 'resumen.csv'
  $progressPath = Join-Path $dir.FullName 'progreso.log'
  $runIndexPath = Join-Path $dir.FullName 'index.html'
  $data = @()
  if (Test-Path -LiteralPath $csvPath -PathType Leaf) {
    try { $data = @(Import-Csv -LiteralPath $csvPath -Encoding UTF8 -ErrorAction Stop | Where-Object { $null -ne $_.Id }) }
    catch { $data = @() }
  }

  # El CSV puede contener un benchmark parcialmente completado.
  # Solo damos COMPLETED cuando la ejecucion termino, no solo un escenario.
  $tail = ''
  if (Test-Path -LiteralPath $progressPath -PathType Leaf) {
    try { $tail = (@(Get-Content -LiteralPath $progressPath -Tail 35 -ErrorAction Stop) -join ' ') }
    catch { $tail = '' }
  }
  $statuses = @($data | ForEach-Object { $_.Status })
  $state = 'EN CURSO'
  if ($statuses -contains 'FAILED' -or $tail -match 'ERROR GENERAL:') {
    $state = 'FAILED'
    $bad++
  } elseif ($statuses.Count -gt 0 -and ($statuses | Where-Object { $_ -ne 'COMPLETED' }).Count -eq 0 -and
            ($tail -match 'BENCHMARK TERMINADO' -or -not (Test-Path -LiteralPath $progressPath))) {
    $state = 'COMPLETED'
    $good++
  } else {
    $other++
  }

  $written = 0L
  foreach ($item in $data) {
    $number = 0L
    if ([long]::TryParse([string]$item.Written,[ref]$number)) { $written += $number }
  }
  $files = @(Get-ChildItem -LiteralPath $dir.FullName -File -Filter 'prueba-*.html' -ErrorAction SilentlyContinue | Sort-Object Name)
  $details = New-Object 'System.Collections.Generic.List[string]'
  foreach ($file in $files) {
    $id = $file.BaseName.Substring(7)
    $matchingRow = @($data | Where-Object { $_.Id -eq $id } | Select-Object -First 1)
    $extra = if ($matchingRow.Count -gt 0) { ' (' + (Html $matchingRow[0].Status) + ')' } else { '' }
    $details.Add(('<a href="{0}">{1}</a>{2}' -f (Html (Href $file.FullName)),(Html $id),$extra))
  }

  $main = if (Test-Path -LiteralPath $runIndexPath -PathType Leaf) { $runIndexPath }
          elseif ($files.Count -gt 0) { $files[0].FullName }
          elseif (Test-Path -LiteralPath $progressPath -PathType Leaf) { $progressPath }
          else { $null }

  $title = Html $dir.Name
  $mainLink = if ($null -ne $main) {
    '<a class="run" href="' + (Html (Href $main)) + '">' + $title + '</a>'
  } else { $title }
  $tools = New-Object 'System.Collections.Generic.List[string]'
  if (Test-Path -LiteralPath $csvPath -PathType Leaf) {
    $tools.Add('<a href="' + (Html (Href $csvPath)) + '">CSV</a>')
  }
  if (Test-Path -LiteralPath $progressPath -PathType Leaf) {
    $tools.Add('<a href="' + (Html (Href $progressPath)) + '">Progreso</a>')
  }
  $testLinks = if ($details.Count -gt 0) { $details -join ' · ' } else { '<span class="muted">Aun sin HTML individuales</span>' }
  $toolLinks = if ($tools.Count -gt 0) { $tools -join ' · ' } else { '—' }
  $stateClass = if ($state -eq 'COMPLETED') { 'ok' } elseif ($state -eq 'FAILED') { 'failed' } else { 'pending' }
  $timestamp = Html ($dir.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))
  $relativeDir = Html (Href $dir.FullName)
  $search = Html ($dir.Name + ' ' + ($data.Id -join ' ') + ' ' + $state)
  $htmlRows.Add(('<tr data-search="{0}"><td>{1}<div class="sub">{2}</div></td><td>{3}</td><td><span class="status {4}">{5}</span></td><td class="number">{6:N0}</td><td>{7}</td><td>{8}</td></tr>' -f
    $search,$mainLink,$relativeDir,$timestamp,$stateClass,$state,$written,$testLinks,$toolLinks))
}

$allCount = $dirs.Count
$rowsHtml = if ($htmlRows.Count -gt 0) { $htmlRows -join [Environment]::NewLine } else {
  '<tr><td colspan="6" class="empty">Todavia no hay informes. Ejecuta test-batch.bat para crear el primero.</td></tr>'
}
$generated = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$html = @"
<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="20">
<title>Spring Batch | Todos los informes</title>
<style>
:root {color-scheme:light}
* {box-sizing:border-box}
body {font:15px/1.55 "Segoe UI",system-ui,Arial,sans-serif;background:#f4f7fb;color:#183048;margin:0}
main {max-width:1320px;margin:0 auto;padding:36px 22px 64px}
header {display:flex;align-items:flex-end;justify-content:space-between;gap:24px;flex-wrap:wrap}
h1 {font-size:30px;letter-spacing:-.035em;margin:0}
p {margin:7px 0 0;color:#526578}
.stats {display:grid;grid-template-columns:repeat(4,minmax(130px,1fr));gap:14px;margin:26px 0}
.stat {background:white;border:1px solid #dbe4ee;border-radius:14px;padding:18px}
.stat strong {display:block;font-size:28px;font-variant-numeric:tabular-nums}
.stat span {font-size:13px;color:#536779}
.panel {background:white;border:1px solid #dbe4ee;border-radius:14px;overflow:hidden}
.bar {display:flex;justify-content:space-between;gap:16px;align-items:center;flex-wrap:wrap;padding:16px 20px;border-bottom:1px solid #e1e8f1}
input {border:1px solid #b8c7d8;border-radius:9px;padding:11px 13px;min-width:min(350px,100%);font:inherit}
.tablewrap {overflow:auto}
table {border-collapse:collapse;width:100%;min-width:890px}
th {background:#f4f7fb;color:#4d6275;text-align:left;font-size:12px;text-transform:uppercase;letter-spacing:.04em}
th,td {border-bottom:1px solid #e7edf4;padding:14px 17px;vertical-align:top}
tbody tr:hover {background:#f8fbff}
a {color:#1767ad;text-decoration:none}
a:hover {text-decoration:underline}
a.run {font-weight:700}
.sub {font-size:11px;color:#6b7e90;overflow-wrap:anywhere;margin-top:4px}
.muted {color:#77899b}
.status {display:inline-block;padding:3px 9px;border-radius:99px;font-size:12px;font-weight:700}
.ok {color:#176a43;background:#e5f5ea}
.failed {color:#a32d36;background:#ffeced}
.pending {color:#82600b;background:#fff5d9}
.number {font-variant-numeric:tabular-nums;white-space:nowrap}
.empty {text-align:center;padding:48px 16px;color:#617589}
footer {color:#657a8c;font-size:13px;margin-top:20px}
@media(max-width:680px) {.stats{grid-template-columns:repeat(2,minmax(130px,1fr))}h1{font-size:24px}}
</style>
</head>
<body><main>
<header><div><h1>Todos los informes de Spring Batch</h1>
<p>Historial de ejecuciones, pruebas manuales y benchmarks. Haz clic para abrir cada HTML.</p></div>
<div class="muted">Actualizado: $(Html $generated)<div>Esta pagina se recarga cada 20 segundos</div></div></header>
<section class="stats">
<div class="stat"><strong>$allCount</strong><span>Ejecuciones registradas</span></div>
<div class="stat"><strong>$good</strong><span>Finalizadas correctamente</span></div>
<div class="stat"><strong>$bad</strong><span>Con error</span></div>
<div class="stat"><strong>$other</strong><span>En curso o sin cierre</span></div>
</section>
<div class="panel"><div class="bar"><strong>Historial (mas reciente primero)</strong>
<input id="search" type="search" placeholder="Buscar perfil, estado o carpeta" aria-label="Filtrar informes" oninput="filterRows(this.value)"></div>
<div class="tablewrap"><table><thead><tr><th>Ejecucion</th><th>Fecha</th><th>Estado</th><th>Registros escritos</th><th>Informes HTML</th><th>Archivos</th></tr></thead>
<tbody id="reports">
$rowsHtml
</tbody></table></div></div>
<footer>Los datos provienen de los HTML, CSV y logs guardados en el disco. No se borra ninguna ejecucion.
El estado "EN CURSO" tambien puede significar que una prueba antigua no llego a finalizar.</footer>
</main>
<script>
function filterRows(value) {
  var query = (value || '').toLowerCase().trim();
  Array.prototype.forEach.call(document.querySelectorAll('#reports tr[data-search]'), function(row) {
    row.style.display = row.getAttribute('data-search').toLowerCase().indexOf(query) >= 0 ? '' : 'none';
  });
}
</script></body></html>
"@
# Escribir a temporal y sustituir el archivo completo para evitar paginas a medias.
$outPath = Join-Path $root 'index.html'
$tempPath = Join-Path $root ('index-' + [guid]::NewGuid().ToString('N') + '.tmp')
try {
  [System.IO.File]::WriteAllText($tempPath,$html,(New-Object System.Text.UTF8Encoding($false)))
  Move-Item -LiteralPath $tempPath -Destination $outPath -Force
} finally {
  if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force }
}
if (-not $Quiet) {
  Write-Host ('INDICE GENERAL: {0} ({1} ejecuciones, {2} correctas, {3} con error)' -f $outPath,$allCount,$good,$bad)
}
