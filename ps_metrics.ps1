# =============================================================================
# CyberArk Vault — Process CPU & Memory Metrics Collector
# =============================================================================
# Monitors key CyberArk Vault processes and sends metrics to Datadog
# every 15 seconds via DogStatsD (UDP 8125).
#
# Processes monitored:
#   dbmain.exe      — CyberArk Vault database main process
#   BLServiceApp.exe — CyberArk Business Logic service
#   ENE.exe         — CyberArk Event Notification Engine
#
# Metrics emitted (tagged with process_name:<name>):
#   vault.process.cpu_pct       — CPU usage %
#   vault.process.memory_bytes  — Working Set memory in bytes
#   vault.process.running       — 1 = running, 0 = down
#
# Requirements:
#   - PowerShell 5.1+ (built into Windows Server 2016+)
#   - Datadog Agent running on same server (DogStatsD port 8125)
# =============================================================================

# --- CONFIGURE THESE ---------------------------------------------------------
$tags     = "env:demo,app:cyberark-vault,host:Vault,collector:powershell"
$interval = 15           # seconds between collections
$statsd   = "127.0.0.1"  # DogStatsD host
$port     = 8125          # DogStatsD port
# -----------------------------------------------------------------------------

# CyberArk Vault processes to monitor (without .exe)
$targetProcesses = @("dbmain", "BLServiceApp", "ENE")

# Register Event Log source for error reporting
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
    } catch {
        Write-EventLog -LogName Application -Source "DD-VaultMetrics" -EventId 1001 `
            -EntryType Warning -Message "Send-Gauge error [${metric}]: $_" `
            -ErrorAction SilentlyContinue
    }
}


function Read-ProcessMetrics {
    param([string]$processName)

    $cpuTotal = 0.0
    $memTotal = 0.0
    $found    = 0

    # Handle multiple instances: processName, processName#1 ... processName#9
    $candidates = @($processName) + (1..9 | ForEach-Object { "$processName#$_" })

    foreach ($inst in $candidates) {
        try {
            $cpuCounter = New-Object System.Diagnostics.PerformanceCounter("Process", "% Processor Time", $inst, $true)
            $memCounter = New-Object System.Diagnostics.PerformanceCounter("Process", "Working Set",       $inst, $true)

            $cpuCounter.NextValue() | Out-Null  # discard first (always 0)
            $memCounter.NextValue() | Out-Null
            Start-Sleep -Milliseconds 100

            $cpu = $cpuCounter.NextValue()
            $mem = $memCounter.NextValue()

            $cpuCounter.Close(); $cpuCounter.Dispose()
            $memCounter.Close(); $memCounter.Dispose()

            $cpuTotal += $cpu
            $memTotal += $mem
            $found++
        } catch {
            # Instance doesn't exist — skip
        }
    }

    return @{
        cpu     = $cpuTotal
        mem     = $memTotal
        running = if ($found -gt 0) { 1 } else { 0 }
    }
}


Write-Host "CyberArk Vault metrics collector starting"
Write-Host "Processes: $($targetProcesses -join ', ')"
Write-Host "Sending to ${statsd}:${port} every ${interval}s"

while ($true) {

    foreach ($procName in $targetProcesses) {
        $result   = Read-ProcessMetrics -processName $procName
        $procTags = "$tags,process_name:$procName"

        # Always send all 3 metrics — 0 when process is not running
        Send-Gauge -metric "vault.process.cpu_pct"      -value ([double]$result.cpu)     -tags $procTags
        Send-Gauge -metric "vault.process.memory_bytes" -value ([double]$result.mem)     -tags $procTags
        Send-Gauge -metric "vault.process.running"      -value ([double]$result.running) -tags $procTags

        $status = if ($result.running -eq 1) { "UP" } else { "DOWN" }
        Write-Host "$(Get-Date -Format 'HH:mm:ss') | $procName | $status | cpu=$([math]::Round($result.cpu,1))% | mem=$([math]::Round($result.mem/1MB,1))MB"
    }

    Start-Sleep -Seconds $interval
}
