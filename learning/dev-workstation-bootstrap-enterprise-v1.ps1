#requires -RunAsAdministrator
<#
.SYNOPSIS
  Enterprise-grade bootstrap for a Windows developer workstation.

.DESCRIPTION
  - Performs a full app inventory before any installs begin.
  - Prints two reports before installation:
      1) Apps already installed / compliant
      2) Apps missing / non-compliant and scheduled for install
  - Installs only the missing apps.
  - Supports transcript logging, dry-run mode, inventory-only mode, and continue-on-error.
  - Keeps platform configuration steps separate from app inventory.

.NOTES
  Run from an elevated Windows PowerShell session.
#>

[CmdletBinding()]
param(
    [switch]$SkipVisualStudio,
    [switch]$SkipDocker,
    [switch]$SkipRebootReminder,
    [switch]$ContinueOnError,
    [switch]$EnableTranscriptLogging,
    [switch]$DryRun,
    [switch]$InventoryOnly,
    [switch]$KeepHyperV,
    [switch]$KeepIIS
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest

# -----------------------------
# Versions / constants
# -----------------------------
$MinPowerShellVersion = [version]'7.4.0'
$RequiredNodeVersion  = '20.12.1'
$DotNet6SdkVersion    = '6.0.401'
$DotNet8MinVersion    = [version]'8.0.0'
$HelmMinVersion       = [version]'3.7.1'
$TerraformMinVersion  = [version]'1.3.5'

$TempRoot         = 'C:\temp'
$DotNetInstallDir = 'C:\Program Files\dotnet'
$UserProfilePath  = [Environment]::GetFolderPath('UserProfile')
$WslConfigPath    = Join-Path $UserProfilePath '.wslconfig'

$VSCodeExtensions = @(
    'EditorConfig.EditorConfig',
    'dbaeumer.vscode-eslint',
    'esbenp.prettier-vscode',
    'hex-ci.stylelint-plus',
    'styled-components.vscode-styled-components',
    'Tyriar.sort-lines'
)

$script:RebootRequired = $false
$script:Inventory = [System.Collections.Generic.List[object]]::new()
$script:MissingApps = [System.Collections.Generic.List[object]]::new()
$script:InstalledApps = [System.Collections.Generic.List[object]]::new()
$script:Manifest = @()
$script:ReportJsonPath = $null
$script:ReportCsvPath = $null
$script:TranscriptStarted = $false

# -----------------------------
# Helpers
# -----------------------------
function Write-Section {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "`n==== $Message ====" -ForegroundColor Cyan
}

function Write-Info {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Gray
}

function Write-Success {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "[ OK ] $Message" -ForegroundColor Green
}

function Write-WarnMessage {
    param([Parameter(Mandatory)][string]$Message)
    Write-Warning $Message
}

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Refresh-SessionPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @($machinePath, $userPath) | Where-Object { $_ -and $_.Trim() -ne '' }
    $env:Path = ($parts -join ';')
}

function Invoke-Step {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    Write-Info $Name

    if ($DryRun) {
        Write-Host "[DRYRUN] $Name" -ForegroundColor Yellow
        return
    }

    try {
        & $Action
    }
    catch {
        if ($ContinueOnError) {
            Write-WarnMessage ("Step failed: {0}. {1}" -f $Name, $_.Exception.Message)
        }
        else {
            throw
        }
    }
}

function Ensure-Winget {
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        throw 'winget is required for this script. Install App Installer / WinGet first and rerun.'
    }
}

function Get-WingetPackageVersion {
    param([Parameter(Mandatory)][string]$Id)

    $output = & winget list --exact --id $Id --source winget --accept-source-agreements 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $output) {
        return $null
    }

    foreach ($line in $output) {
        if ($line -match [regex]::Escape($Id)) {
            $parts = $line -split '\s{2,}'
            if ($parts.Count -ge 3) {
                $candidate = $parts[2].Trim()
                if ($candidate -and $candidate -notmatch '^[><-]+$') {
                    return $candidate
                }
            }
        }
    }

    return $null
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Version,
        [string]$Override
    )

    $args = @('install', '--exact', '--id', $Id, '--accept-package-agreements', '--accept-source-agreements', '--source', 'winget')
    if ($Version) {
        $args += @('--version', $Version)
    }
    if ($Override) {
        $args += @('--override', $Override)
    }

    Write-Host ("winget {0}" -f ($args -join ' '))
    & winget @args
    Refresh-SessionPath
}

function Download-File {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile
    )
    Invoke-WebRequest -Uri $Uri -OutFile $OutFile
}

function Get-InstalledPowerShellVersion {
    $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if (-not $pwsh) {
        return $null
    }

    try {
        $versionText = & $pwsh.Source -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
        if (-not $versionText) {
            return $null
        }
        return [version]$versionText
    }
    catch {
        return $null
    }
}

function Ensure-DotNetInstallScript {
    $scriptPath = Join-Path $TempRoot 'dotnet-install.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        Download-File -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile $scriptPath
    }
    return $scriptPath
}

function Get-DotNetSdkVersions {
    $dotnetExe = Join-Path $DotNetInstallDir 'dotnet.exe'
    if (-not (Test-Path -LiteralPath $dotnetExe)) {
        return @()
    }

    try {
        $output = & $dotnetExe --list-sdks 2>$null
    }
    catch {
        return @()
    }

    $versions = foreach ($line in $output) {
        if ($line -match '^(?<version>\d+\.\d+\.\d+)') {
            try {
                [version]$matches.version
            }
            catch {
            }
        }
    }

    return @($versions)
}

function Test-DotNetSdkInstalled {
    param([Parameter(Mandatory)][string]$Version)

    $target = [version]$Version
    $match = Get-DotNetSdkVersions | Where-Object { $_ -eq $target } | Select-Object -First 1
    return $null -ne $match
}

function Test-DotNetSdkChannelInstalled {
    param([Parameter(Mandatory)][version]$MinVersion)

    $match = Get-DotNetSdkVersions | Where-Object { $_.Major -eq $MinVersion.Major -and $_ -ge $MinVersion } | Select-Object -First 1
    return $null -ne $match
}

function Install-DotNetSdkVersion {
    param([Parameter(Mandatory)][string]$Version)

    if (Test-DotNetSdkInstalled -Version $Version) {
        Write-Info ".NET SDK $Version already installed."
        return
    }

    $dotnetInstall = Ensure-DotNetInstallScript
    & powershell.exe -ExecutionPolicy Bypass -File $dotnetInstall -Version $Version -InstallDir $DotNetInstallDir -Architecture x64
    Refresh-SessionPath
}

function Install-DotNetSdkChannel {
    param(
        [Parameter(Mandatory)][string]$Channel,
        [Parameter(Mandatory)][version]$MinVersion
    )

    if (Test-DotNetSdkChannelInstalled -MinVersion $MinVersion) {
        Write-Info ".NET SDK channel $Channel already satisfies minimum version $MinVersion."
        return
    }

    $dotnetInstall = Ensure-DotNetInstallScript
    & powershell.exe -ExecutionPolicy Bypass -File $dotnetInstall -Channel $Channel -Quality GA -InstallDir $DotNetInstallDir -Architecture x64
    Refresh-SessionPath
}

function Get-InstalledNodeVersion {
    $nodeCmd = Get-Command node.exe -ErrorAction SilentlyContinue
    if (-not $nodeCmd) {
        return $null
    }

    try {
        $versionText = & $nodeCmd.Source --version 2>$null
        if (-not $versionText) {
            return $null
        }
        return ($versionText -replace '^v', '')
    }
    catch {
        return $null
    }
}

function Get-NvmCommandPath {
    $candidates = [System.Collections.Generic.List[string]]::new()

    $cmd = Get-Command nvm.exe -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) {
        return $cmd.Source
    }

    Refresh-SessionPath
    $cmd = Get-Command nvm.exe -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) {
        return $cmd.Source
    }

    foreach ($base in @(
        $env:NVM_HOME,
        'C:\Program Files\nvm',
        (Join-Path ${env:ProgramFiles} 'nvm'),
        (Join-Path ${env:ProgramFiles(x86)} 'nvm')
    )) {
        if ($base) {
            $candidate = Join-Path $base 'nvm.exe'
            if (Test-Path -LiteralPath $candidate) {
                return $candidate
            }
        }
    }

    return $null
}

function Ensure-NvmAvailable {
    param(
        [int]$Retries = 4,
        [int]$DelaySeconds = 2
    )

    for ($i = 0; $i -lt $Retries; $i++) {
        $path = Get-NvmCommandPath
        if ($path) {
            return $path
        }
        Start-Sleep -Seconds $DelaySeconds
        Refresh-SessionPath
    }

    return $null
}

function Test-NvmNodeVersionInstalled {
    param(
        [Parameter(Mandatory)][string]$NvmExePath,
        [Parameter(Mandatory)][string]$Version
    )

    try {
        $output = & $NvmExePath list 2>$null
        return (@($output | Where-Object { $_ -match [regex]::Escape($Version) }).Count -gt 0)
    }
    catch {
        return $false
    }
}

function Test-NpmGlobalPackageInstalled {
    param([Parameter(Mandatory)][string]$PackageName)

    $npmCmd = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if (-not $npmCmd) {
        $npmCmd = Get-Command npm.exe -ErrorAction SilentlyContinue
    }
    if (-not $npmCmd) {
        return $false
    }

    try {
        $output = & $npmCmd.Source list -g --depth=0 2>$null
        return (@($output | Where-Object { $_ -match ("{0}@" -f [regex]::Escape($PackageName)) }).Count -gt 0)
    }
    catch {
        return $false
    }
}

function Get-HelmVersion {
    $helmCmd = Get-Command helm.exe -ErrorAction SilentlyContinue
    if (-not $helmCmd) {
        $helmCmd = Get-Command helm -ErrorAction SilentlyContinue
    }
    if (-not $helmCmd) {
        return $null
    }

    try {
        $versionText = & $helmCmd.Source version --template '{{.Version}}' 2>$null
        if (-not $versionText) {
            return $null
        }
        return [version]($versionText -replace '^v', '')
    }
    catch {
        return $null
    }
}

function Get-TerraformVersion {
    $terraformCmd = Get-Command terraform.exe -ErrorAction SilentlyContinue
    if (-not $terraformCmd) {
        $terraformCmd = Get-Command terraform -ErrorAction SilentlyContinue
    }
    if (-not $terraformCmd) {
        return $null
    }

    try {
        $output = & $terraformCmd.Source version 2>$null | Select-Object -First 1
        if ($output -match 'v(?<version>\d+\.\d+\.\d+)') {
            return [version]$matches.version
        }
        return $null
    }
    catch {
        return $null
    }
}

function Get-VSCodeCommandPath {
    $cmd = Get-Command code.cmd -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) {
        return $cmd.Source
    }

    $cmd = Get-Command code -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) {
        return $cmd.Source
    }

    foreach ($candidate in @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd'),
        (Join-Path ${env:ProgramFiles} 'Microsoft VS Code\bin\code.cmd'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft VS Code\bin\code.cmd')
    )) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    return $null
}

function Get-VSCodeInstalledExtensions {
    $codePath = Get-VSCodeCommandPath
    if (-not $codePath) {
        return @()
    }

    try {
        return @(& $codePath --list-extensions 2>$null)
    }
    catch {
        return @()
    }
}

function Ensure-VSCodeExtensions {
    $codePath = Get-VSCodeCommandPath
    if (-not $codePath) {
        Write-WarnMessage 'VS Code command not found. Skipping extension install.'
        return
    }

    $existing = @(Get-VSCodeInstalledExtensions)
    foreach ($extension in $VSCodeExtensions) {
        if ($existing -contains $extension) {
            Write-Info "VS Code extension already installed: $extension"
            continue
        }

        Invoke-Step -Name ("Install VS Code extension: {0}" -f $extension) -Action {
            & $codePath --install-extension $extension --force
        }
    }
}

function Ensure-FeatureState {
    param(
        [Parameter(Mandatory)][string]$FeatureName,
        [Parameter(Mandatory)][bool]$Enable
    )

    $feature = Get-WindowsOptionalFeature -Online -FeatureName $FeatureName
    $isEnabled = ($feature.State -eq 'Enabled')

    if ($Enable -and -not $isEnabled) {
        Enable-WindowsOptionalFeature -Online -FeatureName $FeatureName -All -NoRestart | Out-Null
        $script:RebootRequired = $true
        Write-Success "Enabled feature: $FeatureName"
    }
    elseif (-not $Enable -and $isEnabled) {
        Disable-WindowsOptionalFeature -Online -FeatureName $FeatureName -NoRestart | Out-Null
        $script:RebootRequired = $true
        Write-Success "Disabled feature: $FeatureName"
    }
    else {
        Write-Info "Feature already in desired state: $FeatureName"
    }
}

function Ensure-WslConfig {
    $memoryGb = [Math]::Max([Math]::Floor(([math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 0) * 0.5)), 4)
    $processors = [Math]::Max([Math]::Floor((Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors * 0.5), 2)

    $desired = @(
        '[wsl2]',
        ("memory={0}GB" -f $memoryGb),
        ("processors={0}" -f $processors),
        'localhostForwarding=true'
    )

    $desiredContent = ($desired -join [Environment]::NewLine) + [Environment]::NewLine
    $currentContent = $null
    if (Test-Path -LiteralPath $WslConfigPath) {
        $currentContent = Get-Content -LiteralPath $WslConfigPath -Raw
    }

    if ($currentContent -ne $desiredContent) {
        Set-Content -LiteralPath $WslConfigPath -Value $desiredContent -Encoding ASCII
        Write-Success "Updated $WslConfigPath"
    }
    else {
        Write-Info "$WslConfigPath already matches desired configuration"
    }
}

function Add-ManifestItem {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Check,
        [Parameter(Mandatory)][scriptblock]$Install,
        [string]$WingetId,
        [string]$TargetVersion
    )

    $item = [pscustomobject]@{
        Name          = $Name
        Check         = $Check
        Install       = $Install
        WingetId      = $WingetId
        TargetVersion = $TargetVersion
    }

    $script:Manifest += $item
}

function Initialize-Manifest {
    $script:Manifest = @()

    Add-ManifestItem -Name 'PowerShell 7.4+' -WingetId 'Microsoft.PowerShell' -TargetVersion $MinPowerShellVersion.ToString() -Check {
        $version = Get-InstalledPowerShellVersion
        if ($version -and $version -ge $MinPowerShellVersion) {
            return [pscustomobject]@{ Installed = $true; Details = $version.ToString() }
        }
        if ($version) {
            return [pscustomobject]@{ Installed = $false; Details = $version.ToString() }
        }
        return [pscustomobject]@{ Installed = $false; Details = $null }
    } -Install {
        Install-WingetPackage -Id 'Microsoft.PowerShell'
    }

    if (-not $SkipDocker) {
        Add-ManifestItem -Name 'Docker Desktop' -WingetId 'Docker.DockerDesktop' -Check {
            $version = Get-WingetPackageVersion -Id 'Docker.DockerDesktop'
            if ($version) {
                return [pscustomobject]@{ Installed = $true; Details = $version }
            }
            return [pscustomobject]@{ Installed = $false; Details = $null }
        } -Install {
            Install-WingetPackage -Id 'Docker.DockerDesktop'
        }
    }

    Add-ManifestItem -Name ".NET SDK $DotNet6SdkVersion" -TargetVersion $DotNet6SdkVersion -Check {
        $installed = Test-DotNetSdkInstalled -Version $DotNet6SdkVersion
        if ($installed) {
            return [pscustomobject]@{ Installed = $true; Details = $DotNet6SdkVersion }
        }
        return [pscustomobject]@{ Installed = $false; Details = $null }
    } -Install {
        Install-DotNetSdkVersion -Version $DotNet6SdkVersion
    }

    Add-ManifestItem -Name '.NET 8 SDK' -TargetVersion $DotNet8MinVersion.ToString() -Check {
        $sdkVersions = @(Get-DotNetSdkVersions | Where-Object { $_.Major -eq 8 } | ForEach-Object { $_.ToString() })
        if ($sdkVersions.Count -gt 0) {
            return [pscustomobject]@{ Installed = $true; Details = ($sdkVersions -join ', ') }
        }
        return [pscustomobject]@{ Installed = $false; Details = $null }
    } -Install {
        Install-DotNetSdkChannel -Channel '8.0' -MinVersion $DotNet8MinVersion
    }

    Add-ManifestItem -Name 'NVM for Windows' -WingetId 'CoreyButler.NVMforWindows' -Check {
        $path = Get-NvmCommandPath
        if ($path) {
            return [pscustomobject]@{ Installed = $true; Details = $path }
        }
        return [pscustomobject]@{ Installed = $false; Details = $null }
    } -Install {
        Install-WingetPackage -Id 'CoreyButler.NVMforWindows'
        $nvmPath = Ensure-NvmAvailable
        if (-not $nvmPath) {
            throw 'nvm.exe was not found after installation. Open a new shell or reboot, then rerun the script.'
        }
    }

    Add-ManifestItem -Name "Node.js $RequiredNodeVersion" -TargetVersion $RequiredNodeVersion -Check {
        $nodeVersion = Get-InstalledNodeVersion
        if ($nodeVersion -eq $RequiredNodeVersion) {
            return [pscustomobject]@{ Installed = $true; Details = $nodeVersion }
        }
        if ($nodeVersion) {
            return [pscustomobject]@{ Installed = $false; Details = $nodeVersion }
        }
        return [pscustomobject]@{ Installed = $false; Details = $null }
    } -Install {
        $nvmPath = Ensure-NvmAvailable
        if (-not $nvmPath) {
            throw 'nvm.exe is not available. Install NVM first or open a new shell and rerun.'
        }

        if (-not (Test-NvmNodeVersionInstalled -NvmExePath $nvmPath -Version $RequiredNodeVersion)) {
            & $nvmPath install $RequiredNodeVersion
        }
        & $nvmPath use $RequiredNodeVersion
        Refresh-SessionPath
    }

    Add-ManifestItem -Name 'Yarn Classic' -Check {
        $installed = Test-NpmGlobalPackageInstalled -PackageName 'yarn'
        if ($installed) {
            return [pscustomobject]@{ Installed = $true; Details = 'Installed globally' }
        }
        return [pscustomobject]@{ Installed = $false; Details = $null }
    } -Install {
        $npmCmd = Get-Command npm.cmd -ErrorAction SilentlyContinue
        if (-not $npmCmd) {
            $npmCmd = Get-Command npm.exe -ErrorAction SilentlyContinue
        }
        if (-not $npmCmd) {
            throw 'npm is not available. Node.js must be installed before Yarn.'
        }
        & $npmCmd.Source install -g yarn
        Refresh-SessionPath
    }

    Add-ManifestItem -Name 'Helm' -WingetId 'Kubernetes.Helm' -TargetVersion $HelmMinVersion.ToString() -Check {
        $version = Get-HelmVersion
        if ($version -and $version -ge $HelmMinVersion) {
            return [pscustomobject]@{ Installed = $true; Details = $version.ToString() }
        }
        if ($version) {
            return [pscustomobject]@{ Installed = $false; Details = $version.ToString() }
        }
        return [pscustomobject]@{ Installed = $false; Details = $null }
    } -Install {
        Install-WingetPackage -Id 'Kubernetes.Helm'
    }

    Add-ManifestItem -Name 'Azure CLI' -WingetId 'Microsoft.AzureCLI' -Check {
        $azCmd = Get-Command az.cmd -ErrorAction SilentlyContinue
        if (-not $azCmd) {
            $azCmd = Get-Command az -ErrorAction SilentlyContinue
        }
        if ($azCmd) {
            return [pscustomobject]@{ Installed = $true; Details = $azCmd.Source }
        }
        return [pscustomobject]@{ Installed = $false; Details = $null }
    } -Install {
        Install-WingetPackage -Id 'Microsoft.AzureCLI'
    }

    Add-ManifestItem -Name 'VS Code' -WingetId 'Microsoft.VisualStudioCode' -Check {
        $path = Get-VSCodeCommandPath
        if ($path) {
            return [pscustomobject]@{ Installed = $true; Details = $path }
        }
        return [pscustomobject]@{ Installed = $false; Details = $null }
    } -Install {
        Install-WingetPackage -Id 'Microsoft.VisualStudioCode'
    }

    if (-not $SkipVisualStudio) {
        Add-ManifestItem -Name 'Visual Studio Professional 2022' -WingetId 'Microsoft.VisualStudio.2022.Professional' -Check {
            $version = Get-WingetPackageVersion -Id 'Microsoft.VisualStudio.2022.Professional'
            if ($version) {
                return [pscustomobject]@{ Installed = $true; Details = $version }
            }
            return [pscustomobject]@{ Installed = $false; Details = $null }
        } -Install {
            Install-WingetPackage -Id 'Microsoft.VisualStudio.2022.Professional'
        }
    }

    Add-ManifestItem -Name 'MongoDB Compass' -WingetId 'MongoDB.Compass.Full' -Check {
        $version = Get-WingetPackageVersion -Id 'MongoDB.Compass.Full'
        if ($version) {
            return [pscustomobject]@{ Installed = $true; Details = $version }
        }
        return [pscustomobject]@{ Installed = $false; Details = $null }
    } -Install {
        Install-WingetPackage -Id 'MongoDB.Compass.Full'
    }

    Add-ManifestItem -Name 'Terraform' -WingetId 'Hashicorp.Terraform' -TargetVersion $TerraformMinVersion.ToString() -Check {
        $version = Get-TerraformVersion
        if ($version -and $version -ge $TerraformMinVersion) {
            return [pscustomobject]@{ Installed = $true; Details = $version.ToString() }
        }
        if ($version) {
            return [pscustomobject]@{ Installed = $false; Details = $version.ToString() }
        }
        return [pscustomobject]@{ Installed = $false; Details = $null }
    } -Install {
        Install-WingetPackage -Id 'Hashicorp.Terraform'
    }
}

function Build-Inventory {
    $script:Inventory.Clear()
    $script:MissingApps.Clear()
    $script:InstalledApps.Clear()

    foreach ($item in $script:Manifest) {
        $result = & $item.Check

        $entry = [pscustomobject]@{
            Name          = $item.Name
            Installed     = [bool]$result.Installed
            Details       = $result.Details
            WingetId      = $item.WingetId
            TargetVersion = $item.TargetVersion
        }

        $script:Inventory.Add($entry) | Out-Null
        if ($entry.Installed) {
            $script:InstalledApps.Add($entry) | Out-Null
        }
        else {
            $script:MissingApps.Add($entry) | Out-Null
        }
    }
}

function Write-InventoryReports {
    Write-Section 'Installed / already present'
    if ($script:InstalledApps.Count -eq 0) {
        Write-Host '  (none)'
    }
    else {
        foreach ($entry in ($script:InstalledApps | Sort-Object Name)) {
            if ($entry.Details) {
                Write-Host ("  [+] {0} ({1})" -f $entry.Name, $entry.Details) -ForegroundColor Green
            }
            else {
                Write-Host ("  [+] {0}" -f $entry.Name) -ForegroundColor Green
            }
        }
    }

    Write-Section 'Missing / will be installed'
    if ($script:MissingApps.Count -eq 0) {
        Write-Host '  (none)'
    }
    else {
        foreach ($entry in ($script:MissingApps | Sort-Object Name)) {
            if ($entry.Details) {
                Write-Host ("  [-] {0} (current: {1})" -f $entry.Name, $entry.Details) -ForegroundColor Yellow
            }
            else {
                Write-Host ("  [-] {0}" -f $entry.Name) -ForegroundColor Yellow
            }
        }
    }

    Ensure-Directory -Path $TempRoot
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:ReportJsonPath = Join-Path $TempRoot ("dev-workstation-inventory-{0}.json" -f $timestamp)
    $script:ReportCsvPath = Join-Path $TempRoot ("dev-workstation-inventory-{0}.csv" -f $timestamp)

    $script:Inventory | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:ReportJsonPath -Encoding UTF8
    $script:Inventory | Export-Csv -LiteralPath $script:ReportCsvPath -NoTypeInformation -Encoding UTF8

    Write-Host "`nInventory JSON: $script:ReportJsonPath"
    Write-Host "Inventory CSV : $script:ReportCsvPath"
}

function Install-MissingApps {
    if ($script:MissingApps.Count -eq 0) {
        Write-Success 'All target apps are already installed. No app installation is required.'
        return
    }

    Write-Section 'Install missing apps'

    foreach ($manifestItem in $script:Manifest) {
        $missing = $script:MissingApps | Where-Object { $_.Name -eq $manifestItem.Name } | Select-Object -First 1
        if (-not $missing) {
            Write-Info ("Skipping {0} because it is already installed." -f $manifestItem.Name)
            continue
        }

        Invoke-Step -Name ("Install {0}" -f $manifestItem.Name) -Action $manifestItem.Install
    }
}

function Configure-Platform {
    Write-Section 'Platform configuration'

    if (-not $KeepIIS) {
        Invoke-Step -Name 'Disable IIS' -Action {
            Ensure-FeatureState -FeatureName 'IIS-WebServerRole' -Enable $false
        }
    }
    else {
        Write-Info 'Keeping IIS enabled by request.'
    }

    if (-not $KeepHyperV) {
        Invoke-Step -Name 'Disable Hyper-V' -Action {
            Ensure-FeatureState -FeatureName 'Microsoft-Hyper-V-All' -Enable $false
        }
    }
    else {
        Write-Info 'Keeping Hyper-V enabled by request.'
    }

    Invoke-Step -Name 'Enable WSL' -Action {
        Ensure-FeatureState -FeatureName 'Microsoft-Windows-Subsystem-Linux' -Enable $true
    }

    Invoke-Step -Name 'Enable Virtual Machine Platform' -Action {
        Ensure-FeatureState -FeatureName 'VirtualMachinePlatform' -Enable $true
    }

    Invoke-Step -Name 'Configure .wslconfig' -Action {
        Ensure-WslConfig
    }
}

function Start-OptionalTranscript {
    if (-not $EnableTranscriptLogging) {
        return
    }

    Ensure-Directory -Path $TempRoot
    $path = Join-Path $TempRoot ("dev-workstation-bootstrap-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Start-Transcript -Path $path -Force | Out-Null
    $script:TranscriptStarted = $true
    Write-Host "Transcript log: $path"
}

function Stop-OptionalTranscript {
    if ($script:TranscriptStarted) {
        Stop-Transcript | Out-Null
        $script:TranscriptStarted = $false
    }
}

# -----------------------------
# Main
# -----------------------------
try {
    Ensure-Directory -Path $TempRoot
    Start-OptionalTranscript

    Write-Section 'Preflight checks'
    Ensure-Winget
    Refresh-SessionPath

    Write-Section 'Build app manifest'
    Initialize-Manifest

    Write-Section 'App inventory'
    Build-Inventory
    Write-InventoryReports

    if ($InventoryOnly) {
        Write-Success 'Inventory-only mode requested. Exiting without installing apps.'
        return
    }

    Install-MissingApps

    Write-Section 'Post-install tasks'
    Invoke-Step -Name 'Install VS Code extensions' -Action {
        Ensure-VSCodeExtensions
    }

    Configure-Platform

    if ($script:RebootRequired -and -not $SkipRebootReminder) {
        Write-Warning 'One or more changes require a reboot before everything is fully usable.'
    }

    Write-Success 'Bootstrap completed.'
}
finally {
    Stop-OptionalTranscript
}
