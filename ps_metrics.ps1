# =============================================================================
# CyberArk Vault - Process CPU & Memory Metrics Collector
# =============================================================================
# Collects CPU and Memory usage for CyberArk Vault processes and sends
# them to Datadog every 15 seconds via DogStatsD (UDP 8125).
#
# Processes monitored:
#   dbmain.exe       - CyberArk Vault database main process
#   BLServiceApp.exe - CyberArk Business Logic service
#   ENE.exe          - CyberArk Event Notification Engine
#
# Metrics emitted:
#   vault.dbmain.cpu_pct           vault.dbmain.memory_bytes
#   vault.blserviceapp.cpu_pct     vault.blserviceapp.memory_bytes
#   vault.ene.cpu_pct              vault.ene.memory_bytes
#
# Tags: read automatically from C:\ProgramData\Datadog\datadog.yaml
#   Add tags there and restart this script - no code change needed.
# =============================================================================

$interval  = 15
$statsd    = "127.0.0.1"
$port      = 8125
$yamlPath  = "C:\ProgramData\Datadog\datadog.yaml"

$targetProcesses = @{
    "dbmain"       = "vault.dbmain"
    "BLServiceApp" = "vault.blserviceapp"
    "ENE"          = "vault.ene"
}

try {
    if (-not [System.Diagnostics.EventLog]::SourceExists("DD-VaultMetrics")) {
        New-EventLog -LogName Application -Source "DD-VaultMetrics"
    }
} catch {}


# Read tags from datadog.yaml tags: block
function Get-AgentTags {
    $tags = @()
    if (-not (Test-Path $yamlPath)) { return "" }
    $inTagsBlock = $false
    foreach ($line in Get-Content $yamlPath) {
        if ($line -match '^tags\s*:') {
            $inTagsBlock = $true
            continue
        }
        if ($inTagsBlock) {
            if ($line -match '^\s+-\s*(.+)') {
                $tags += $matches[1].Trim()
            } elseif ($line -match '^\S') {
                break
            }
        }
    }
    return ($tags -join ',')
}


function Send-Gauge {
    param([string]$metric, [double]$value, [string]$tags)
    try {
        $udp  = New-Object System.Net.Sockets.UdpClient
        $udp.Connect($statsd, $port)
        $payload = if ($tags) { "${metric}:${value}|g|#${tags}" } else { "${metric}:${value}|g" }
        $bytes   = [System.Text.Encoding]::UTF8.GetBytes($payload)
        $udp.Send($bytes, $bytes.Length) | Out-Null
        $udp.Close()
    } catch {
        Write-EventLog -LogName Application -Source "DD-VaultMetrics" -EventId 1001 `
            -EntryType Warning -Message "Send-Gauge error [${metric}]: $_" `
            -ErrorAction SilentlyContinue
    }
}


function Get-ProcessMetrics {
    param([string]$processName)
    $cpuTotal = 0.0
    $memTotal = 0.0
    $found    = 0
    $candidates = @($processName) + (1..9 | ForEach-Object { "$processName#$_" })
    foreach ($inst in $candidates) {
        try {
            $cpu = New-Object System.Diagnostics.PerformanceCounter("Process", "% Processor Time", $inst, $true)
            $mem = New-Object System.Diagnostics.PerformanceCounter("Process", "Working Set",       $inst, $true)
            $cpu.NextValue() | Out-Null
            $mem.NextValue() | Out-Null
            Start-Sleep -Milliseconds 100
            $cpuVal = $cpu.NextValue()
            $memVal = $mem.NextValue()
            $cpu.Close(); $cpu.Dispose()
            $mem.Close(); $mem.Dispose()
            $cpuTotal += $cpuVal
            $memTotal += $memVal
            $found++
        } catch {}
    }
    return @{ cpu = $cpuTotal; mem = $memTotal; found = $found }
}


Write-Host "CyberArk Vault metrics collector starting - $(Get-Date)"
Write-Host "Sending to ${statsd}:${port} every ${interval}s"

# Re-read tags from yaml every 5 minutes in case they change
$tagRefreshCounter = 0
$currentTags = Get-AgentTags
Write-Host "Tags from datadog.yaml: $(if($currentTags){'['+$currentTags+']'}else{'(none)'})"

while ($true) {
    # Refresh tags every 20 loops (~5 min)
    if ($tagRefreshCounter % 20 -eq 0) {
        $currentTags = Get-AgentTags
    }
    $tagRefreshCounter++

    foreach ($proc in $targetProcesses.GetEnumerator()) {
        $procName   = $proc.Key
        $metricBase = $proc.Value
        $r          = Get-ProcessMetrics -processName $procName

        Send-Gauge -metric "$metricBase.cpu_pct"      -value ([double]$r.cpu) -tags $currentTags
        Send-Gauge -metric "$metricBase.memory_bytes" -value ([double]$r.mem) -tags $currentTags

        $status = if ($r.found -gt 0) { "UP" } else { "DOWN" }
        Write-Host "$(Get-Date -Format 'HH:mm:ss') | $procName | $status | cpu=$([math]::Round($r.cpu,1))% | mem=$([math]::Round($r.mem/1MB,1))MB"
    }
    Start-Sleep -Seconds $interval
}
