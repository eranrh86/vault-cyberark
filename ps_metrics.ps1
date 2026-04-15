# =============================================================================
# CyberArk Vault — Process Custom Metrics via DogStatsD
# =============================================================================
# Metrics emitted per process (no process_name tag needed — name is in metric):
#   vault.dbmain.cpu_pct           vault.dbmain.memory_bytes
#   vault.blserviceapp.cpu_pct     vault.blserviceapp.memory_bytes
#   vault.ene.cpu_pct              vault.ene.memory_bytes
# =============================================================================

# Tags are intentionally left empty here.
# Add tags via the Datadog Agent datadog.yaml file instead:
#   tags:
#     - env:production
#     - app:cyberark-vault
#     - team:security
$interval = 15
$statsd   = "127.0.0.1"
$port     = 8125

# Map process name -> metric prefix (lowercase, no special chars)
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


function Send-Gauge {
    param([string]$metric, [double]$value)
    try {
        $udp     = New-Object System.Net.Sockets.UdpClient
        $udp.Connect($statsd, $port)
        # No tags in payload — tags are managed via datadog.yaml on the host
        $payload = "${metric}:${value}|g"
        $bytes   = [System.Text.Encoding]::UTF8.GetBytes($payload)
        $udp.Send($bytes, $bytes.Length) | Out-Null
        $udp.Close()
    } catch {}
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


Write-Host "CyberArk Vault metrics collector starting — $(Get-Date)"

while ($true) {
    foreach ($proc in $targetProcesses.GetEnumerator()) {
        $procName   = $proc.Key
        $metricBase = $proc.Value
        $r          = Get-ProcessMetrics -processName $procName

        # Metric name carries the process identity — no process_name tag needed
        Send-Gauge -metric "$metricBase.cpu_pct"      -value ([double]$r.cpu)
        Send-Gauge -metric "$metricBase.memory_bytes" -value ([double]$r.mem)

        $status = if ($r.found -gt 0) { "UP" } else { "DOWN" }
        Write-Host "$(Get-Date -Format 'HH:mm:ss') | $procName | $status | cpu=$([math]::Round($r.cpu,1))% | mem=$([math]::Round($r.mem/1MB,1))MB"
    }
    Start-Sleep -Seconds $interval
}
