<#
.SYNOPSIS
    Full installation / reinstallation of Zabbix Agent 2 7.0 LTS on Windows EC2.

.DESCRIPTION
    - Installs/reinstalls Zabbix Agent 2
    - Handles an existing Zabbix Agent 2 installation
    - Uses an MSI timeout instead of waiting forever
    - Creates verbose MSI logs
    - Configures AWS EC2 metadata / Name tag
    - Configures TLS PSK
    - Configures CPU / Memory UserParameters
    - Configures disk discovery / disk reporting
    - Enables and starts Zabbix Agent 2
    - Tests TCP connectivity to Zabbix Server port 10051

.NOTES
    Run PowerShell as Administrator.
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

# ============================================================================
# CONSTANTS
# ============================================================================

$ZabbixBranch = "7.0"

$InstallDir   = "C:\Program Files\Zabbix Agent 2"
$ConfFile     = Join-Path $InstallDir "zabbix_agent2.conf"
$UserParamDir = Join-Path $InstallDir "zabbix_agent2.d"

$AwsUserParam  = Join-Path $UserParamDir "aws_metadata.conf"
$TopProcessConf = Join-Path $UserParamDir "topprocess.conf"
$DiskUserParam  = Join-Path $UserParamDir "disk_report.conf"

$PskFile = Join-Path $InstallDir "zabbix_agent2.psk"

$LogFile = "C:\ProgramData\zabbix_agent2_install.log"

$MsiPath = Join-Path $env:TEMP "zabbix_agent2.msi"
$MsiLog  = Join-Path $env:TEMP "zabbix_agent2_msi.log"

$ImdsUrl = "http://169.254.169.254/latest"

$MsiUrl = "https://cdn.zabbix.com/zabbix/binaries/stable/$ZabbixBranch/latest/zabbix_agent2-$ZabbixBranch-latest-windows-amd64-openssl.msi"

# MSI timeout in seconds.
# 600 = 10 minutes.
$MsiTimeoutSeconds = 600

# ============================================================================
# HELPERS
# ============================================================================

function Write-Log {
    param(
        [string]$Message
    )

    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm"), $Message

    Write-Host $line

    try {
        Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
    }
    catch {
    }
}

function Write-Fatal {
    param(
        [string]$Message
    )

    $line = "[{0}] ERROR: {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm"), $Message

    Write-Host $line -ForegroundColor Red

    try {
        Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
    }
    catch {
    }

    exit 1
}

function Set-ConfValue {
    param(
        [string]$Key,
        [string]$Value
    )

    if (-not (Test-Path $ConfFile)) {
        Write-Fatal "Configuration file not found: $ConfFile"
    }

    $pattern = "^#?\s*$([regex]::Escape($Key))="

    $lines = Get-Content $ConfFile |
        Where-Object { $_ -notmatch $pattern }

    $lines | Set-Content $ConfFile -Encoding ASCII

    Add-Content -Path $ConfFile -Value "$Key=$Value"
}

# ============================================================================
# 0. PRE-FLIGHT
# ============================================================================

$currentPrincipal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)

if (-not $currentPrincipal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)) {
    Write-Fatal "Run PowerShell as Administrator."
}

New-Item -ItemType Directory -Path (Split-Path $LogFile) -Force | Out-Null
New-Item -ItemType File -Path $LogFile -Force | Out-Null

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Log "============================================================"
Write-Log "Zabbix Agent 2 installation started"
Write-Log "============================================================"

# ============================================================================
# 1. INPUT
# ============================================================================

if ([string]::IsNullOrWhiteSpace($Server)) {
    $Server = Read-Host "Enter Zabbix Server IP or DNS"
}

if ([string]::IsNullOrWhiteSpace($Server)) {
    Write-Fatal "Zabbix Server cannot be empty."
}

if ([string]::IsNullOrWhiteSpace($HostName)) {
    $HostName = Read-Host "Enter Hostname"
}

if ([string]::IsNullOrWhiteSpace($HostName)) {
    Write-Fatal "Hostname cannot be empty."
}

if ([string]::IsNullOrWhiteSpace($ClientName)) {
    $ClientName = Read-Host "Enter Client Name (e.g. ACME-Corp)"
}

if ([string]::IsNullOrWhiteSpace($ClientName)) {
    Write-Fatal "Client Name cannot be empty."
}

if ([string]::IsNullOrWhiteSpace($PSKIdentity)) {
    $PSKIdentity = Read-Host "Enter TLS PSK Identity"
}

if ([string]::IsNullOrWhiteSpace($PSKIdentity)) {
    Write-Fatal "TLS PSK Identity cannot be empty."
}

if ([string]::IsNullOrWhiteSpace($PSKKey)) {

    $secure = Read-Host `
        "Enter TLS PSK Key (hex string, input hidden)" `
        -AsSecureString

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)

    try {
        $PSKKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

if ([string]::IsNullOrWhiteSpace($PSKKey)) {
    Write-Fatal "TLS PSK Key cannot be empty."
}

# Basic PSK validation.
if ($PSKKey -notmatch '^[0-9a-fA-F]+$') {
    Write-Fatal "TLS PSK Key must contain hexadecimal characters only."
}

if (($PSKKey.Length % 2) -ne 0) {
    Write-Fatal "TLS PSK Key must contain an even number of hexadecimal characters."
}

Write-Log "Zabbix Server : $Server"
Write-Log "Hostname      : $HostName"
Write-Log "Client Name   : $ClientName"
Write-Log "PSK Identity  : $PSKIdentity"
Write-Log "PSK Key       : (hidden)"

# ============================================================================
# 2. AWS CLI
# ============================================================================

function Install-AwsCli {

    $awsCommand = Get-Command aws.exe -ErrorAction SilentlyContinue

    if ($awsCommand) {

        try {
            Write-Log "AWS CLI already present: $(aws --version 2>&1)"
            return
        }
        catch {
            Write-Log "AWS CLI executable found but version check failed."
        }
    }

    # Common AWS CLI installation path.
    $commonAws = "C:\Program Files\Amazon\AWSCLIV2\aws.exe"

    if (Test-Path $commonAws) {

        $env:Path += ";C:\Program Files\Amazon\AWSCLIV2"

        if (Get-Command aws.exe -ErrorAction SilentlyContinue) {
            Write-Log "AWS CLI found at $commonAws"
            return
        }
    }

    Write-Log "AWS CLI not found, installing AWS CLI v2..."

    $awsMsi = Join-Path $env:TEMP "AWSCLIV2.msi"

    try {

        Invoke-WebRequest `
            -Uri "https://awscli.amazonaws.com/AWSCLIV2.msi" `
            -OutFile $awsMsi `
            -UseBasicParsing

        Write-Log "Installing AWS CLI v2..."

        $awsProc = Start-Process `
            -FilePath "msiexec.exe" `
            -ArgumentList @(
                "/i",
                "`"$awsMsi`"",
                "/qn",
                "/norestart"
            ) `
            -Wait `
            -PassThru

        if ($awsProc.ExitCode -notin @(0, 3010)) {
            Write-Log "WARNING: AWS CLI MSI returned exit code $($awsProc.ExitCode)."
        }
        else {
            Write-Log "AWS CLI installation completed."
        }

        $env:Path += ";C:\Program Files\Amazon\AWSCLIV2"

    }
    catch {

        Write-Log "WARNING: AWS CLI installation failed: $($_.Exception.Message)"
        Write-Log "Name tag lookup may be skipped."

    }
    finally {

        Remove-Item $awsMsi -Force -ErrorAction SilentlyContinue
    }
}

Install-AwsCli

# ============================================================================
# 3. FIND EXISTING ZABBIX INSTALLATION
# ============================================================================

function Get-ZabbixInstalledProduct {

    $uninstallRoots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    foreach ($root in $uninstallRoots) {

        Get-ItemProperty $root -ErrorAction SilentlyContinue |
            Where-Object {
                $_.DisplayName -like "Zabbix Agent 2*"
            } |
            Select-Object -First 1
    }
}

# ============================================================================
# 4. UNINSTALL EXISTING ZABBIX AGENT 2
# ============================================================================

function Remove-ExistingZabbix {

    $service = Get-Service `
        -Name "Zabbix Agent 2" `
        -ErrorAction SilentlyContinue

    $product = Get-ZabbixInstalledProduct

    if (-not $service -and -not $product) {

        Write-Log "No existing Zabbix Agent 2 installation detected."

        return
    }

    Write-Log "Existing Zabbix Agent 2 installation detected."

    # Stop service if present.
    if ($service) {

        try {

            if ($service.Status -ne "Stopped") {

                Write-Log "Stopping existing Zabbix Agent 2 service..."

                Stop-Service `
                    -Name "Zabbix Agent 2" `
                    -Force `
                    -ErrorAction Stop

                Start-Sleep -Seconds 3
            }

        }
        catch {

            Write-Log "WARNING: Could not stop existing service: $($_.Exception.Message)"
        }
    }

    if ($product) {

        $productCode = $product.PSChildName

        if (-not $productCode -and $product.UninstallString) {

            if ($product.UninstallString -match '\{[0-9A-Fa-f-]+\}') {
                $productCode = $matches[0]
            }
        }

        if ($productCode) {

            Write-Log "Removing existing Zabbix Agent 2 MSI installation..."

            $uninstallProc = Start-Process `
                -FilePath "msiexec.exe" `
                -ArgumentList @(
                    "/x",
                    $productCode,
                    "/qn",
                    "/norestart"
                ) `
                -Wait `
                -PassThru

            if ($uninstallProc.ExitCode -notin @(0, 1605, 1614, 3010)) {

                Write-Fatal `
                    "Existing Zabbix Agent 2 uninstall failed with exit code $($uninstallProc.ExitCode)."

            }

            Write-Log "Existing Zabbix Agent 2 removed."
        }
        else {

            Write-Log "WARNING: Existing Zabbix installation found but MSI product code could not be determined."
        }
    }

    Start-Sleep -Seconds 3
}

Remove-ExistingZabbix

# ============================================================================
# 5. DOWNLOAD + INSTALL ZABBIX MSI
# ============================================================================

function Install-ZabbixAgent2Msi {

    Write-Log "Downloading Zabbix Agent2 $ZabbixBranch..."
    Write-Log "URL: $MsiUrl"

    Remove-Item $MsiPath -Force -ErrorAction SilentlyContinue
    Remove-Item $MsiLog  -Force -ErrorAction SilentlyContinue

    try {

        Invoke-WebRequest `
            -Uri $MsiUrl `
            -OutFile $MsiPath `
            -UseBasicParsing `
            -ErrorAction Stop

    }
    catch {

        Write-Fatal `
            "Failed to download Zabbix Agent2 MSI: $($_.Exception.Message)"
    }

    if (-not (Test-Path $MsiPath)) {
        Write-Fatal "Downloaded MSI file does not exist."
    }

    $sizeMB = [math]::Round(
        (Get-Item $MsiPath).Length / 1MB,
        2
    )

    Write-Log "Downloaded Zabbix MSI: $sizeMB MB"
    Write-Log "Installing Zabbix Agent 2..."
    Write-Log "MSI log: $MsiLog"

    $msiArguments = @(
        "/i",
        "`"$MsiPath`"",
        "/qn",
        "/norestart",
        "/l*v",
        "`"$MsiLog`"",
        "SERVER=$Server",
        "SERVERACTIVE=$Server",
        "HOSTNAME=$HostName",
        "ENABLEPATH=1"
    )

    try {

        $proc = Start-Process `
            -FilePath "msiexec.exe" `
            -ArgumentList $msiArguments `
            -PassThru

        Write-Log "Zabbix MSI process started. PID: $($proc.Id)"
        Write-Log "Waiting up to $MsiTimeoutSeconds seconds for MSI..."

        $completed = $proc.WaitForExit($MsiTimeoutSeconds * 1000)

        if (-not $completed) {

            Write-Log "ERROR: Zabbix MSI exceeded timeout of $MsiTimeoutSeconds seconds."

            Write-Log "Collecting MSI log tail..."

            if (Test-Path $MsiLog) {

                Get-Content $MsiLog -Tail 40 |
                    ForEach-Object {
                        Add-Content -Path $LogFile -Value "MSI: $_"
                    }
            }

            try {
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            }
            catch {
            }

            Write-Fatal `
                "Zabbix MSI installation timed out. See $MsiLog and $LogFile"
        }

        $exitCode = $proc.ExitCode

        Write-Log "Zabbix MSI exit code: $exitCode"

        # Standard successful MSI codes:
        # 0    = success
        # 3010 = success, reboot required
        # 1641 = success, reboot initiated

        if ($exitCode -notin @(0, 3010, 1641)) {

            Write-Log "Zabbix MSI failed. MSI log: $MsiLog"

            if (Test-Path $MsiLog) {

                Get-Content $MsiLog -Tail 60 |
                    ForEach-Object {
                        Add-Content -Path $LogFile -Value "MSI: $_"
                    }
            }

            Write-Fatal `
                "Zabbix Agent 2 MSI installation failed with exit code $exitCode."
        }

    }
    catch {

        Write-Fatal `
            "Unable to start/wait for Zabbix MSI: $($_.Exception.Message)"
    }

    Remove-Item $MsiPath -Force -ErrorAction SilentlyContinue

    Start-Sleep -Seconds 3

    if (-not (Test-Path $ConfFile)) {

        Write-Fatal `
            "$ConfFile was not found after MSI installation."
    }

    Write-Log "Zabbix Agent 2 MSI installed successfully."
}

Install-ZabbixAgent2Msi

# ============================================================================
# 6. EC2 METADATA
# ============================================================================

function Get-Ec2Metadata {

    Write-Log "Retrieving EC2 instance metadata (IMDSv2)..."

    try {

        $token = Invoke-RestMethod `
            -Method Put `
            -Uri "$ImdsUrl/api/token" `
            -Headers @{
                "X-aws-ec2-metadata-token-ttl-seconds" = "60"
            } `
            -ErrorAction Stop

    }
    catch {

        Write-Fatal `
            "Unable to obtain IMDSv2 token. Is this script running on an EC2 instance?"
    }

    $headers = @{
        "X-aws-ec2-metadata-token" = $token
    }

    try {

        $script:InstanceId =
            Invoke-RestMethod `
                -Headers $headers `
                -Uri "$ImdsUrl/meta-data/instance-id"

        $script:Region =
            Invoke-RestMethod `
                -Headers $headers `
                -Uri "$ImdsUrl/meta-data/placement/region"

        $script:AvailabilityZone =
            Invoke-RestMethod `
                -Headers $headers `
                -Uri "$ImdsUrl/meta-data/placement/availability-zone"

        $script:InstanceType =
            Invoke-RestMethod `
                -Headers $headers `
                -Uri "$ImdsUrl/meta-data/instance-type"

        $script:PrivateIp =
            Invoke-RestMethod `
                -Headers $headers `
                -Uri "$ImdsUrl/meta-data/local-ipv4"

        $doc =
            Invoke-RestMethod `
                -Headers $headers `
                -Uri "$ImdsUrl/dynamic/instance-identity/document"

        $script:AccountId = $doc.accountId

    }
    catch {

        Write-Fatal `
            "Failed to retrieve required EC2 metadata: $($_.Exception.Message)"
    }

    if (-not $script:InstanceId) {
        Write-Fatal "Failed to retrieve Instance ID."
    }

    if (-not $script:Region) {
        Write-Fatal "Failed to retrieve Region."
    }

    if (-not $script:AccountId) {
        Write-Fatal "Failed to retrieve AWS Account ID."
    }

    # ------------------------------------------------------------------------
    # AWS Name tag
    # ------------------------------------------------------------------------

    Write-Log "Retrieving EC2 Name tag..."

    $script:InstanceName = "N/A"

    if (Get-Command aws.exe -ErrorAction SilentlyContinue) {

        try {

            $name = aws ec2 describe-tags `
                --region $script:Region `
                --filters `
                    "Name=resource-id,Values=$($script:InstanceId)" `
                    "Name=key,Values=Name" `
                --query "Tags[0].Value" `
                --output text `
                2>>$LogFile

            if ($name -and $name -ne "None") {

                $script:InstanceName = $name.Trim()

            }
            else {

                Write-Log "WARNING: No 'Name' tag found."
            }

        }
        catch {

            Write-Log `
                "WARNING: Name tag lookup failed: $($_.Exception.Message)"
        }

    }
    else {

        Write-Log `
            "WARNING: AWS CLI unavailable. Name tag lookup skipped."
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

# ============================================================================
# 7. CONFIGURE ZABBIX AGENT
# ============================================================================

function Set-AgentConfig {

    $backup = "$ConfFile.bak.$(Get-Date -Format yyyyMMddHHmmss)"

    if (Test-Path $ConfFile) {

        Copy-Item `
            $ConfFile `
            $backup `
            -Force

        Write-Log "Backed up existing config to $backup"
    }

    Set-ConfValue -Key "Server" -Value $Server
    Set-ConfValue -Key "ServerActive" -Value $Server
    Set-ConfValue -Key "Hostname" -Value $HostName

    New-Item `
        -ItemType Directory `
        -Path $UserParamDir `
        -Force |
        Out-Null

    $includeExists = Select-String `
        -Path $ConfFile `
        -Pattern "^Include=.*zabbix_agent2\.d" `
        -Quiet `
        -ErrorAction SilentlyContinue

    if (-not $includeExists) {

        Add-Content `
            -Path $ConfFile `
            -Value "Include=$UserParamDir\*.conf"
    }

    Write-Log "zabbix_agent2.conf configured."
}

Set-AgentConfig

# ============================================================================
# 8. TLS PSK
# ============================================================================

function Set-TlsPsk {

    Write-Log "Writing TLS PSK file..."

    [IO.File]::WriteAllText(
        $PskFile,
        $PSKKey,
        [Text.Encoding]::ASCII
    )

    icacls $PskFile /inheritance:r | Out-Null

    icacls $PskFile `
        /grant:r `
        "SYSTEM:F" `
        "BUILTIN\Administrators:F" |
        Out-Null

    Set-ConfValue -Key "TLSConnect" -Value "psk"
    Set-ConfValue -Key "TLSAccept" -Value "psk"
    Set-ConfValue -Key "TLSPSKIdentity" -Value $PSKIdentity
    Set-ConfValue -Key "TLSPSKFile" -Value $PskFile

    Write-Log "TLS PSK configured."
}

Set-TlsPsk

# ============================================================================
# 9. AWS USERPARAMETERS
# ============================================================================

function New-AwsUserParameters {

    Write-Log "Writing AWS metadata UserParameters..."

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

    Set-Content `
        -Path $AwsUserParam `
        -Value $content `
        -Encoding ASCII
}

New-AwsUserParameters

# ============================================================================
# 10. CPU / MEMORY USERPARAMETERS
# ============================================================================

function New-CpuMemoryUserParameters {

    Write-Log "Writing CPU and Memory UserParameters..."

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

    $content =
        $cpuScript +
        "`n`n" +
        $memScript

    Set-Content `
        -Path $TopProcessConf `
        -Value $content `
        -Encoding ASCII
}

New-CpuMemoryUserParameters

# ============================================================================
# 11. DISK USERPARAMETERS
# ============================================================================

function New-DiskUserParameters {

    Write-Log "Writing disk discovery / report UserParameters..."

    $content = @'
# ==========================================================
# DISK DISCOVERY
# ==========================================================

UserParameter=disk.discovery,powershell -NoProfile -ExecutionPolicy Bypass -Command "$drives=Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3';$data=@();foreach($d in $drives){$data+=@{'{#DRIVE}'=$d.DeviceID.TrimEnd(':')}};@{data=$data}|ConvertTo-Json -Compress -Depth 4"

# ==========================================================
# PER-DRIVE LIVE REPORT
# Usage: disk.report[C], disk.report[D], etc.
# ==========================================================

UserParameter=disk.report[*],powershell -NoProfile -ExecutionPolicy Bypass -Command "$d=Get-CimInstance Win32_LogicalDisk -Filter \"DeviceID='$1:'\"; if($d){$total=[math]::Round($d.Size/1GB,2); $used=[math]::Round(($d.Size-$d.FreeSpace)/1GB,2); $free=[math]::Round($d.FreeSpace/1GB,2); $pct=[math]::Round((($d.Size-$d.FreeSpace)/$d.Size)*100,2); Write-Output '============================================================'; Write-Output 'DISK REPORT'; Write-Output '============================================================'; Write-Output ('Drive Letter : '+$d.DeviceID.TrimEnd(':')); Write-Output ('Volume Name : '+$d.VolumeName); Write-Output ''; Write-Output ('Total Space : '+$total+' GB'); Write-Output ('Used Space : '+$used+' GB'); Write-Output ('Free Space : '+$free+' GB'); Write-Output ''; Write-Output ('Used Percent : '+$pct+' %'); Write-Output ''; Write-Output ('Generated : '+(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))}"
'@

    Set-Content `
        -Path $DiskUserParam `
        -Value $content `
        -Encoding ASCII
}

New-DiskUserParameters

# ============================================================================
# 12. SERVICE
# ============================================================================

function Start-ZabbixService {

    Write-Log "Enabling and restarting Zabbix Agent 2 service..."

    $svc = Get-Service `
        -Name "Zabbix Agent 2" `
        -ErrorAction SilentlyContinue

    if (-not $svc) {

        Write-Fatal `
            "'Zabbix Agent 2' service not found after installation."
    }

    Set-Service `
        -Name "Zabbix Agent 2" `
        -StartupType Automatic

    $maxRetries = 5
    $serviceStarted = $false

    for ($i = 1; $i -le $maxRetries; $i++) {

        try {

            $svc = Get-Service `
                -Name "Zabbix Agent 2" `
                -ErrorAction Stop

            if ($svc.Status -eq "Running") {

                Restart-Service `
                    -Name "Zabbix Agent 2" `
                    -Force `
                    -ErrorAction Stop
            }
            else {

                Start-Service `
                    -Name "Zabbix Agent 2" `
                    -ErrorAction Stop
            }

            Start-Sleep -Seconds 3

            $svc = Get-Service `
                -Name "Zabbix Agent 2" `
                -ErrorAction Stop

            if ($svc.Status -eq "Running") {

                $serviceStarted = $true

                Write-Log "Zabbix Agent 2 service is running."

                break
            }

            Write-Log `
                "Service status after attempt ${i}: $($svc.Status)"

        }
        catch {

            Write-Log `
                "Service start attempt ${i} failed: $($_.Exception.Message)"
        }

        Start-Sleep -Seconds 5
    }

    if (-not $serviceStarted) {

        Write-Fatal `
            "Zabbix Agent 2 service failed to start after $maxRetries attempts."
    }
}

Start-ZabbixService

# ============================================================================
# 13. TEST ZABBIX SERVER CONNECTIVITY
# ============================================================================

function Test-ZabbixConnectivity {

    Write-Log "Testing TCP connectivity to $Server`:10051..."

    try {

        $result = Test-NetConnection `
            -ComputerName $Server `
            -Port 10051 `
            -WarningAction SilentlyContinue

        if ($result.TcpTestSucceeded) {

            $script:Connectivity = "Connected"

            Write-Log `
                "TCP connectivity to $Server`:10051 successful."
        }
        else {

            $script:Connectivity =
                "Unreachable (check Security Group / firewall)"

            Write-Log `
                "WARNING: Could not reach $Server`:10051. Agent will retry."
        }
    }
    catch {

        $script:Connectivity =
            "Unreachable (check Security Group / firewall)"

        Write-Log `
            "WARNING: Connectivity test failed: $($_.Exception.Message)"
    }
}

Test-ZabbixConnectivity

# ============================================================================
# 14. FINAL SUMMARY
# ============================================================================

Write-Host ""

Write-Host "============================================================" -ForegroundColor Green
Write-Host " ZABBIX AGENT 2 INSTALLATION COMPLETED SUCCESSFULLY" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green

Write-Host "Zabbix Server   : $Server"
Write-Host "Hostname        : $HostName"
Write-Host "Client Name     : $ClientName"

Write-Host "AWS Account     : $($script:AccountId)"
Write-Host "Instance ID     : $($script:InstanceId)"
Write-Host "Instance Name   : $($script:InstanceName)"
Write-Host "Instance Type   : $($script:InstanceType)"
Write-Host "Private IP      : $($script:PrivateIp)"
Write-Host "Region          : $($script:Region)"
Write-Host "Avail. Zone     : $($script:AvailabilityZone)"

Write-Host ""
Write-Host "TLS PSK Identity: $PSKIdentity"
Write-Host "TLS PSK Key     : (hidden)"
Write-Host ""

Write-Host "Connectivity    : $($script:Connectivity)"

Write-Host ""
Write-Host "UserParameters available:"
Write-Host "  aws.*"
Write-Host "  top.cpu"
Write-Host "  top.memory"
Write-Host "  disk.discovery"
Write-Host "  disk.report[<drive>]"

Write-Host ""
Write-Host "Zabbix MSI log  : $MsiLog"
Write-Host "Install log     : $LogFile"

Write-Host ""
Write-Host "============================================================"

Write-Log "Installation completed successfully."
