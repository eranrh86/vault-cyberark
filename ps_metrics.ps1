# =============================================================================
# CyberArk Vault — Process Custom Metrics via DogStatsD
# =============================================================================
# Reads real Windows Performance Counter values for CyberArk Vault processes
# and sends CPU % and Memory (bytes) to Datadog every 15 seconds.
#
# Processes monitored:
#   dbmain.exe       — CyberArk Vault database main process
#   BLServiceApp.exe — CyberArk Business Logic service
#   ENE.exe          — CyberArk Event Notification Engine
#
# Custom metrics (tagged process_name:<name>):
#   vault.process.cpu_pct       — CPU usage %
#   vault.process.memory_bytes  — Working Set memory in bytes
# =============================================================================

$tags     = "env:demo,app:cyberark-vault,host:Vault,collector:powershell"
$interval = 15
$statsd   = "127.0.0.1"
$port     = 8125

$targetProcesses = @("dbmain", "BLServiceApp", "ENE")

try {
    if (-not [System.Diagnostics.EventLog]::SourceExists("DD-VaultMetrics")) {
        New-EventLog -LogName Application -Source "DD-VaultMetrics"
    }
} catch {}


function Send-Gauge {
    param([string]$metric, [double]$value, [string]$tags)
    try {
        $udp     = New-Object System.Net.Sockets.UdpClient
        $udp.Connect($statsd, $port)
        $payload = "${metric}:${value}|g|#${tags}"
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
Write-Host "Monitoring: $($targetProcesses -join ', ')"

while ($true) {
    foreach ($proc in $targetProcesses) {
        $r        = Get-ProcessMetrics -processName $proc
        $procTags = "$tags,process_name:$proc"

        Send-Gauge -metric "vault.process.cpu_pct"      -value ([double]$r.cpu) -tags $procTags
        Send-Gauge -metric "vault.process.memory_bytes" -value ([double]$r.mem) -tags $procTags

        $status = if ($r.found -gt 0) { "UP" } else { "DOWN" }
        Write-Host "$(Get-Date -Format 'HH:mm:ss') | $proc | $status | cpu=$([math]::Round($r.cpu,1))% | mem=$([math]::Round($r.mem/1MB,1))MB"
    }
    Start-Sleep -Seconds $interval
}
