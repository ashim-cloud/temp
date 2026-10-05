<#
.SYNOPSIS
    Full installation of Zabbix Agent 2 (7.0 LTS) on Windows EC2 with:
    - AWS metadata (IMDSv2 + Name tag)
    - CPU / Memory top process reports
    - Disk discovery (LLD) and per-drive live reports
    - TLS PSK encryption
.DESCRIPTION
    This script downloads and installs Zabbix Agent 2, configures all required
    UserParameters, and starts the service. All input (Server, Hostname, Client, PSK)
    is prompted if not supplied as parameters.
.PARAMETER Server
    Zabbix server IP or DNS (required).
.PARAMETER HostName
    Zabbix hostname (required).
.PARAMETER ClientName
    Client identifier for alerting (required).
.PARAMETER PSKIdentity
    TLS PSK identity string (required).
.PARAMETER PSKKey
    TLS PSK key (hex string) - can be supplied as secure string input.
.EXAMPLE
    .\Install-ZabbixAgent2.ps1 -Server 10.0.0.5 -HostName web01 -ClientName ACME -PSKIdentity web01 -PSKKey 1234567890abcdef
#>

[CmdletBinding()]
param(
    [string]$Server,
    [string]$HostName,
    [string]$ClientName,
    [string]$PSKIdentity,
    [string]$PSKKey
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Paths / constants
# ---------------------------------------------------------------------------
$ZabbixBranch    = "7.0"
$InstallDir      = "C:\Program Files\Zabbix Agent 2"
$ConfFile        = Join-Path $InstallDir "zabbix_agent2.conf"
$UserParamDir    = Join-Path $InstallDir "zabbix_agent2.d"
$AwsUserParam    = Join-Path $UserParamDir "aws_metadata.conf"
$TopProcessConf  = Join-Path $UserParamDir "topprocess.conf"
$DiskUserParam   = Join-Path $UserParamDir "disk_report.conf"
$PskFile         = Join-Path $InstallDir "zabbix_agent2.psk"
$LogFile         = "C:\ProgramData\zabbix_agent2_install.log"
$ImdsUrl         = "http://169.254.169.254/latest"
$MsiUrl          = "https://cdn.zabbix.com/zabbix/binaries/stable/$ZabbixBranch/latest/zabbix_agent2-$ZabbixBranch-latest-windows-amd64-openssl.msi"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm"), $Message
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

function Write-Fatal {
    param([string]$Message)
    $line = "[{0}] ERROR: {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm"), $Message
    Write-Host $line -ForegroundColor Red
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
    exit 1
}

function Set-ConfValue {
    param([string]$Key, [string]$Value)
    if (Test-Path $ConfFile) {
        $pattern = "^#?\s*$([regex]::Escape($Key))="
        (Get-Content $ConfFile) | Where-Object { $_ -notmatch $pattern } | Set-Content $ConfFile
    }
    Add-Content -Path $ConfFile -Value "$Key=$Value"
}

# ---------------------------------------------------------------------------
# 0. Pre-flight checks
# ---------------------------------------------------------------------------
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Fatal "This script must be run as Administrator (right-click PowerShell -> Run as Administrator)."
}
New-Item -ItemType Directory -Path (Split-Path $LogFile) -Force | Out-Null
New-Item -ItemType File -Path $LogFile -Force | Out-Null
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------------------
# 1. Collect user input
# ---------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($Server))   { $Server = Read-Host "Enter Zabbix Server IP or DNS" }
if ([string]::IsNullOrWhiteSpace($Server))   { Write-Fatal "Zabbix Server value cannot be empty." }

if ([string]::IsNullOrWhiteSpace($HostName)) { $HostName = Read-Host "Enter Hostname" }
if ([string]::IsNullOrWhiteSpace($HostName)) { Write-Fatal "Hostname cannot be empty." }

if ([string]::IsNullOrWhiteSpace($ClientName)) { $ClientName = Read-Host "Enter Client Name (e.g. ACME-Corp)" }
if ([string]::IsNullOrWhiteSpace($ClientName)) { Write-Fatal "Client Name cannot be empty." }

if ([string]::IsNullOrWhiteSpace($PSKIdentity)) { $PSKIdentity = Read-Host "Enter TLS PSK Identity" }
if ([string]::IsNullOrWhiteSpace($PSKIdentity)) { Write-Fatal "TLS PSK Identity cannot be empty." }

if ([string]::IsNullOrWhiteSpace($PSKKey)) {
    $secure = Read-Host "Enter TLS PSK Key (hex string, input hidden)" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    $PSKKey = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}
if ([string]::IsNullOrWhiteSpace($PSKKey)) { Write-Fatal "TLS PSK Key cannot be empty." }

Write-Log "Zabbix Server : $Server"
Write-Log "Hostname      : $HostName"
Write-Log "Client Name   : $ClientName"
Write-Log "PSK Identity  : $PSKIdentity"
Write-Log "PSK Key       : (hidden)"

# ---------------------------------------------------------------------------
# 2. Install AWS CLI v2 if missing (for Name tag lookup)
# ---------------------------------------------------------------------------
function Install-AwsCli {
    if (Get-Command aws.exe -ErrorAction SilentlyContinue) {
        Write-Log "AWS CLI already present: $(aws --version 2>&1)"
        return
    }
    Write-Log "AWS CLI not found, installing AWS CLI v2..."
    $msiPath = Join-Path $env:TEMP "AWSCLIV2.msi"
    try {
        Invoke-WebRequest -Uri "https://awscli.amazonaws.com/AWSCLIV2.msi" -OutFile $msiPath -UseBasicParsing
        Start-Process msiexec.exe -ArgumentList "/i `"$msiPath`" /qn /norestart" -Wait
        Remove-Item $msiPath -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Log "WARNING: Could not install AWS CLI ($($_.Exception.Message)), Name tag lookup will be skipped."
    }
}
Install-AwsCli

# ---------------------------------------------------------------------------
# 3. Download and install Zabbix Agent2 MSI
# ---------------------------------------------------------------------------
function Install-ZabbixAgent2Msi {
    Write-Log "Downloading Zabbix Agent2 $ZabbixBranch from $MsiUrl ..."
    $msiPath = Join-Path $env:TEMP "zabbix_agent2.msi"
    try {
        Invoke-WebRequest -Uri $MsiUrl -OutFile $msiPath -UseBasicParsing
    } catch {
        Write-Fatal "Failed to download Zabbix Agent2 MSI: $($_.Exception.Message)"
    }

    Write-Log "Installing zabbix-agent2 (silent MSI)..."
    $msiLog = Join-Path $env:TEMP "zabbix_agent2_msi.log"
    $msiArgs = @(
        "/i", "`"$msiPath`"",
        "/qn", "/norestart",
        "/l*v", "`"$msiLog`"",
        "SERVER=$Server",
        "SERVERACTIVE=$Server",
        "HOSTNAME=$HostName",
        "ENABLEPATH=1"
    )
    $proc = Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        Write-Fatal "zabbix-agent2 MSI install failed with exit code $($proc.ExitCode). See $msiLog"
    }
    Remove-Item $msiPath -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path $ConfFile)) {
        Write-Fatal "$ConfFile not found; zabbix-agent2 may not be installed correctly."
    }
    Write-Log "zabbix-agent2 installed successfully."
}
Install-ZabbixAgent2Msi

# ---------------------------------------------------------------------------
# 4. Collect EC2 metadata via IMDSv2
# ---------------------------------------------------------------------------
function Get-Ec2Metadata {
    Write-Log "Retrieving EC2 instance metadata (IMDSv2)..."
    try {
        $token = Invoke-RestMethod -Method Put -Uri "$ImdsUrl/api/token" `
            -Headers @{ "X-aws-ec2-metadata-token-ttl-seconds" = "60" } -ErrorAction Stop
    } catch {
        Write-Fatal "Unable to obtain IMDSv2 token. Is this script running on an EC2 instance?"
    }
    $h = @{ "X-aws-ec2-metadata-token" = $token }

    $script:InstanceId       = Invoke-RestMethod -Headers $h -Uri "$ImdsUrl/meta-data/instance-id"
    $script:Region           = Invoke-RestMethod -Headers $h -Uri "$ImdsUrl/meta-data/placement/region"
    $script:AvailabilityZone = Invoke-RestMethod -Headers $h -Uri "$ImdsUrl/meta-data/placement/availability-zone"
    $script:InstanceType     = Invoke-RestMethod -Headers $h -Uri "$ImdsUrl/meta-data/instance-type"
    $script:PrivateIp        = Invoke-RestMethod -Headers $h -Uri "$ImdsUrl/meta-data/local-ipv4"
    $doc                     = Invoke-RestMethod -Headers $h -Uri "$ImdsUrl/dynamic/instance-identity/document"
    $script:AccountId        = $doc.accountId

    if (-not $script:InstanceId)  { Write-Fatal "Failed to retrieve Instance ID from IMDS." }
    if (-not $script:Region)      { Write-Fatal "Failed to retrieve Region from IMDS." }
    if (-not $script:AccountId)   { Write-Fatal "Failed to retrieve AWS Account ID from IMDS." }

    Write-Log "Retrieving EC2 Name tag..."
    $script:InstanceName = "N/A"
    if (Get-Command aws.exe -ErrorAction SilentlyContinue) {
        try {
            $name = aws ec2 describe-tags --region $script:Region `
                --filters "Name=resource-id,Values=$($script:InstanceId)" "Name=key,Values=Name" `
                --query "Tags[0].Value" --output text 2>>$LogFile
            if ($name -and $name -ne "None") { $script:InstanceName = $name.Trim() }
            else { Write-Log "WARNING: No 'Name' tag found on this instance." }
        } catch {
            Write-Log "WARNING: Name tag lookup failed: $($_.Exception.Message)"
        }
    } else {
        Write-Log "WARNING: AWS CLI unavailable, Name tag lookup skipped."
    }

    Write-Log "Account ID    : $($script:AccountId)"
    Write-Log "Instance ID   : $($script:InstanceId)"
    Write-Log "Instance Name : $($script:InstanceName)"
    Write-Log "Instance Type : $($script:InstanceType)"
    Write-Log "Private IP    : $($script:PrivateIp)"
    Write-Log "Region        : $($script:Region)"
    Write-Log "Avail. Zone   : $($script:AvailabilityZone)"
}
Get-Ec2Metadata

# ---------------------------------------------------------------------------
# 5. Configure zabbix_agent2.conf
# ---------------------------------------------------------------------------
function Set-AgentConfig {
    $backup = "$ConfFile.bak.$(Get-Date -Format yyyyMMddHHmmss)"
    Copy-Item $ConfFile $backup -Force
    Write-Log "Backed up existing config to $backup"

    Set-ConfValue -Key "Server" -Value $Server
    Set-ConfValue -Key "ServerActive" -Value $Server
    Set-ConfValue -Key "Hostname" -Value $HostName

    New-Item -ItemType Directory -Path $UserParamDir -Force | Out-Null
    if (-not (Select-String -Path $ConfFile -Pattern "^Include=.*zabbix_agent2\.d" -Quiet -ErrorAction SilentlyContinue)) {
        Add-Content -Path $ConfFile -Value "Include=$UserParamDir\*.conf"
    }
    Write-Log "zabbix_agent2.conf configured."
}
Set-AgentConfig

# ---------------------------------------------------------------------------
# 6. Configure TLS PSK encryption
# ---------------------------------------------------------------------------
function Set-TlsPsk {
    Write-Log "Writing PSK key to $PskFile ..."
    [IO.File]::WriteAllText($PskFile, $PSKKey, [Text.Encoding]::ASCII)
    icacls $PskFile /inheritance:r | Out-Null
    icacls $PskFile /grant:r "SYSTEM:F" "BUILTIN\Administrators:F" | Out-Null

    Set-ConfValue -Key "TLSConnect" -Value "psk"
    Set-ConfValue -Key "TLSAccept" -Value "psk"
    Set-ConfValue -Key "TLSPSKIdentity" -Value $PSKIdentity
    Set-ConfValue -Key "TLSPSKFile" -Value $PskFile

    Write-Log "TLS PSK configured."
}
Set-TlsPsk

# ---------------------------------------------------------------------------
# 7. Create AWS metadata UserParameters
# ---------------------------------------------------------------------------
function New-AwsUserParameters {
    Write-Log "Writing AWS metadata UserParameters to $AwsUserParam ..."
    $content = @"
# Auto-generated on $(Get-Date -Format "yyyy-MM-dd HH:mm")

UserParameter=aws.account.id,echo $($script:AccountId)
UserParameter=aws.instance.id,echo $($script:InstanceId)
UserParameter=aws.instance.name,echo $($script:InstanceName)
UserParameter=aws.instance.type,echo $($script:InstanceType)
UserParameter=aws.instance.privateip,echo $($script:PrivateIp)
UserParameter=aws.instance.region,echo $($script:Region)
UserParameter=aws.instance.az,echo $($script:AvailabilityZone)
UserParameter=aws.client.name,echo $ClientName
"@
    Set-Content -Path $AwsUserParam -Value $content -Encoding ASCII
}
New-AwsUserParameters

# ---------------------------------------------------------------------------
# 8. Create CPU / Memory UserParameters
# ---------------------------------------------------------------------------
function New-CpuMemoryUserParameters {
    Write-Log "Writing CPU and Memory UserParameters to $TopProcessConf ..."

    $cpuScript = @'
# ==========================================================
# TOP 5 CPU CONSUMING PROCESSES
# ==========================================================
UserParameter=top.cpu,powershell -NoProfile -ExecutionPolicy Bypass -Command "Write-Output 'TOP 5 CPU CONSUMING PROCESSES';Write-Output '============================================================';Get-Process | Sort-Object CPU -Descending | Select-Object -First 5 ProcessName,@{N='CPU Time(s)';E={[math]::Round($_.CPU,2)}} | Format-Table -AutoSize | Out-String -Width 4096"
'@

    $memScript = @'
# ==========================================================
# MEMORY REPORT
# ==========================================================
UserParameter=top.memory,powershell -NoProfile -ExecutionPolicy Bypass -Command "$os=Get-CimInstance Win32_OperatingSystem;$total=[math]::Round($os.TotalVisibleMemorySize/1MB,2);$free=[math]::Round($os.FreePhysicalMemory/1MB,2);$used=[math]::Round($total-$free,2);Write-Output 'MEMORY SUMMARY';Write-Output '============================================================';Write-Output ('Total Memory : '+$total+' GB');Write-Output ('Used Memory : '+$used+' GB');Write-Output ('Free Memory : '+$free+' GB');Write-Output '';Write-Output 'TOP 5 MEMORY CONSUMING PROCESSES';Write-Output '============================================================';Get-Process | Sort-Object WS -Descending | Select-Object -First 5 ProcessName,@{N='Memory(MB)';E={[math]::Round($_.WS/1MB,1)}} | Format-Table -AutoSize | Out-String -Width 4096"
'@

    $content = $cpuScript + "`n`n" + $memScript
    Set-Content -Path $TopProcessConf -Value $content -Encoding ASCII
}
New-CpuMemoryUserParameters

# ---------------------------------------------------------------------------
# 9. Create disk discovery and per-drive LIVE report UserParameters
#    (queries CIM directly at poll time - no cache file, no scheduled task)
# ---------------------------------------------------------------------------
function New-DiskUserParameters {
    Write-Log "Writing disk discovery / report UserParameters to $DiskUserParam ..."
    $content = @'
# ==========================================================
# DISK DISCOVERY (LLD) - returns JSON with {#DRIVE}
# ==========================================================
UserParameter=disk.discovery,powershell -NoProfile -ExecutionPolicy Bypass -Command "$drives=Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3';$data=@();foreach($d in $drives){$data+=@{'{#DRIVE}'=$d.DeviceID.TrimEnd(':')}};@{data=$data}|ConvertTo-Json -Compress -Depth 4"

# ==========================================================
# PER-DRIVE LIVE REPORT
# Usage: disk.report[C], disk.report[D], etc.
# ==========================================================
UserParameter=disk.report[*],powershell -NoProfile -ExecutionPolicy Bypass -Command "$d=Get-CimInstance Win32_LogicalDisk -Filter \"DeviceID='$1:'\"; if($d){$total=[math]::Round($d.Size/1GB,2); $used=[math]::Round(($d.Size-$d.FreeSpace)/1GB,2); $free=[math]::Round($d.FreeSpace/1GB,2); $pct=[math]::Round((($d.Size-$d.FreeSpace)/$d.Size)*100,2); Write-Output '============================================================'; Write-Output 'DISK REPORT'; Write-Output '============================================================'; Write-Output ('Drive Letter : '+$d.DeviceID.TrimEnd(':')); Write-Output ('Volume Name : '+$d.VolumeName); Write-Output ''; Write-Output ('Total Space : '+$total+' GB'); Write-Output ('Used Space : '+$used+' GB'); Write-Output ('Free Space : '+$free+' GB'); Write-Output ''; Write-Output ('Used Percent : '+$pct+' %'); Write-Output ''; Write-Output ('Generated : '+(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))}"
'@
    Set-Content -Path $DiskUserParam -Value $content -Encoding ASCII
}
New-DiskUserParameters

# ---------------------------------------------------------------------------
# 10. Enable and restart the Zabbix Agent 2 service
# ---------------------------------------------------------------------------
function Start-ZabbixService {
    Write-Log "Enabling and restarting 'Zabbix Agent 2' service..."
    $svc = Get-Service -Name "Zabbix Agent 2" -ErrorAction SilentlyContinue
    if (-not $svc) { Write-Fatal "'Zabbix Agent 2' service not found after install." }

    Set-Service -Name "Zabbix Agent 2" -StartupType Automatic

    $maxRetries = 5
    $retryCount = 0
    $serviceStarted = $false

    while ($retryCount -lt $maxRetries -and -not $serviceStarted) {
        try {
            Restart-Service -Name "Zabbix Agent 2" -Force -ErrorAction Stop
            Start-Sleep -Seconds 3
            $svc.Refresh()
            if ($svc.Status -eq "Running") {
                $serviceStarted = $true
                Write-Log "Zabbix Agent 2 service is running."
            } else {
                Write-Log "Service status: $($svc.Status), waiting..."
                Start-Sleep -Seconds 5
                $retryCount++
            }
        } catch {
            Write-Log "Attempt $($retryCount + 1) to restart service failed: $($_.Exception.Message)"
            Start-Sleep -Seconds 5
            $retryCount++
        }
    }

    if (-not $serviceStarted) {
        Write-Fatal "Zabbix Agent 2 service failed to start after $maxRetries attempts."
    }
}
Start-ZabbixService

# ---------------------------------------------------------------------------
# 11. Verify connectivity to Zabbix Server (port 10051)
# ---------------------------------------------------------------------------
function Test-ZabbixConnectivity {
    Write-Log "Verifying TCP connectivity to $($Server):10051 ..."
    try {
        $result = Test-NetConnection -ComputerName $Server -Port 10051 -WarningAction SilentlyContinue
        if ($result.TcpTestSucceeded) {
            $script:Connectivity = "Connected"
            Write-Log "TCP connectivity to $($Server):10051 successful."
        } else {
            $script:Connectivity = "Unreachable (check Security Group / firewall)"
            Write-Log "WARNING: Could not reach $($Server):10051. The agent will retry."
        }
    } catch {
        $script:Connectivity = "Unreachable (check Security Group / firewall)"
        Write-Log "WARNING: Could not test connectivity to $($Server):10051. The agent will retry."
    }
}
Test-ZabbixConnectivity

# ---------------------------------------------------------------------------
# 12. Installation summary
# ---------------------------------------------------------------------------
@"

============================================================
ZABBIX AGENT 2 INSTALLATION COMPLETED SUCCESSFULLY
============================================================

Zabbix Server   : $Server
Hostname        : $HostName
Client Name     : $ClientName
AWS Account     : $($script:AccountId)
Instance ID     : $($script:InstanceId)
Instance Name   : $($script:InstanceName)
Instance Type   : $($script:InstanceType)
Private IP      : $($script:PrivateIp)
Region          : $($script:Region)
Avail. Zone     : $($script:AvailabilityZone)

TLS PSK Identity: $PSKIdentity
TLS PSK Key     : $PSKKey

Connectivity    : $($script:Connectivity)

UserParameters available:
  aws.*, top.cpu, top.memory
  disk.discovery (LLD JSON -> {#DRIVE})
  disk.report[<drive>] (e.g., disk.report[C]) - queried live, no cache/scheduled task

Zabbix Frontend Setup:
  Create a Discovery rule with key "disk.discovery".
  Create an Item prototype with key "disk.report[{#DRIVE}]",
  Type: Zabbix agent, Type of information: Text, Update interval: 1h.
  Discovery will automatically create/remove items as drives are added/removed.

Log file: $LogFile
============================================================
"@

Write-Log "Installation completed successfully."
