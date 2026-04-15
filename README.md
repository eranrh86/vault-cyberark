# vault-cyberark

Datadog custom metrics collector for CyberArk Vault — monitors CPU and Memory usage per process via DogStatsD.

## Metrics

| Metric | Description |
|--------|-------------|
| `vault.dbmain.cpu_pct` | CPU usage % of dbmain.exe |
| `vault.dbmain.memory_bytes` | Working Set memory of dbmain.exe |
| `vault.blserviceapp.cpu_pct` | CPU usage % of BLServiceApp.exe |
| `vault.blserviceapp.memory_bytes` | Working Set memory of BLServiceApp.exe |
| `vault.ene.cpu_pct` | CPU usage % of ENE.exe |
| `vault.ene.memory_bytes` | Working Set memory of ENE.exe |

Metrics are collected every 15 seconds via Windows Performance Counters and sent to Datadog via DogStatsD (UDP 8125).

## Requirements

- Windows Server 2016 or later
- PowerShell 5.1 or later (built-in)
- Datadog Agent 7+ installed and running on the same server

## Installation

### 1. Install Datadog Agent

Download and install from: https://app.datadoghq.com/account/settings#agent/windows

### 2. Configure the Agent

Edit `C:\ProgramData\Datadog\datadog.yaml`:

```yaml
api_key: <YOUR_DD_API_KEY>
hostname: Vault

# Optional: add tags for your environment
tags:
  - env:production
  - app:cyberark-vault
  - team:security
```

Restart the agent after any changes:
```powershell
Restart-Service datadogagent
```

### 3. Deploy the collector script

```powershell
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/eranrh86/vault-cyberark/main/ps_metrics.ps1" `
  -OutFile "C:\ps_metrics.ps1" -UseBasicParsing
```

### 4. Run as a Scheduled Task (auto-start, persist across reboots)

```powershell
$action   = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File C:\ps_metrics.ps1"
$trigger  = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName "VaultPSMetrics" -Action $action -Trigger $trigger -RunLevel Highest -User SYSTEM -Settings $settings
Start-ScheduledTask -TaskName "VaultPSMetrics"
```

### 5. Run manually (for testing)

```powershell
powershell -ExecutionPolicy Bypass -File C:\ps_metrics.ps1
```

## Tags

Tags are **not** hardcoded in the script. Add them in `datadog.yaml` so they apply to all metrics from the host:

```yaml
tags:
  - env:production
  - app:cyberark-vault
  - team:security
  - site:datacenter-1
```

## Processes Monitored

| Process | Description |
|---------|-------------|
| `dbmain.exe` | CyberArk Vault database main process |
| `BLServiceApp.exe` | CyberArk Business Logic service |
| `ENE.exe` | CyberArk Event Notification Engine |

Metrics report `0` when a process is not running, making it easy to set up monitors for process availability.
