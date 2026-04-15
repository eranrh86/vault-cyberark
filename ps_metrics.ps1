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
# Tags:
#   Configure tags in C:\ProgramData\Datadog\datadog.yaml:
#     tags:
#       - env:production
#       - app:cyberark-vault
#       - team:security
#
# Requirements:
#   - PowerShell 5.1 or later (built into Windows Server 2016+)
#   - Datadog Agent installed and running on the same server
#
# Installation:
#   See README.md
# =============================================================================

$interval = 15           # seconds between collections
$statsd   = "127.0.0.1"  # Datadog Agent DogStatsD host (localhost)
$port     = 8125          # Datadog Agent DogStatsD port

# CyberArk Vault processes to monitor (map: process name -> metric prefix)
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
        $payload = "${metric}:${value}|g"
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

    # Handle multiple instances of the same process: proc, proc#1, proc#2 ...
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

while ($true) {
    foreach ($proc in $targetProcesses.GetEnumerator()) {
        $procName   = $proc.Key
        $metricBase = $proc.Value
        $r          = Get-ProcessMetrics -processName $procName

        Send-Gauge -metric "$metricBase.cpu_pct"      -value ([double]$r.cpu)
        Send-Gauge -metric "$metricBase.memory_bytes" -value ([double]$r.mem)

        $status = if ($r.found -gt 0) { "UP" } else { "DOWN" }
        Write-Host "$(Get-Date -Format 'HH:mm:ss') | $procName | $status | cpu=$([math]::Round($r.cpu,1))% | mem=$([math]::Round($r.mem/1MB,1))MB"
    }
    Start-Sleep -Seconds $interval
}
