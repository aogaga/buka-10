#requires -RunAsAdministrator
<#!
.SYNOPSIS
  Bootstrap a Windows developer workstation.

.DESCRIPTION
  - Disables IIS and Hyper-V Windows features.
  - Installs PowerShell 7.4+.
  - Enables WSL2 and configures .wslconfig based on RAM.
  - Installs Docker Desktop 24+ and related developer tools.
  - Installs .NET SDK 6.0.401 and .NET 8 SDK.
  - Installs nvm-windows, Node.js 20.12.1, Yarn Classic, Helm, Azure CLI,
    VS Code + extensions, Visual Studio Professional, MongoDB Compass,
    and Terraform.

.NOTES
  Run from an elevated Windows PowerShell session.
  Some feature changes/installations require a reboot before everything is fully usable.
#>

[CmdletBinding()]
param(
    [switch]$SkipVisualStudio,
    [switch]$SkipDocker,
    [switch]$SkipRebootReminder
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# -----------------------------
# Versions / constants
# -----------------------------
$MinPowerShellVersion = [version]'7.4.0'
$RequiredNodeVersion  = '20.12.1'
$DotNet6SdkVersion    = '6.0.401'
$HelmMinVersion       = [version]'3.7.1'
$TerraformMinVersion  = [version]'1.3.5'

$TempRoot         = 'C:\temp'
$HelmInstallDir   = 'C:\temp\helm'
$TerraformDir     = 'C:\temp\terraform'
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

# -----------------------------
# Helpers
# -----------------------------
function Write-Section {
    param([string]$Message)
    Write-Host "`n==== $Message ====" -ForegroundColor Cyan
}

function Test-IsAdmin {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Directory {
    param([Parameter(Mandatory)] [string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Ensure-Winget {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw 'winget is required for this script. Install App Installer / WinGet first and rerun.'
    }
}

function Get-CommandVersion {
    param([Parameter(Mandatory)] [string]$CommandName)
    $cmd = Get-Command $CommandName -ErrorAction SilentlyContinue
    if (-not $cmd) { return $null }
    try {
        return [version]$cmd.Version
    } catch {
        return $null
    }
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory)] [string]$Id,
        [string]$Version,
        [string]$Override
    )

    $args = @('install', '--exact', '--id', $Id, '--accept-package-agreements', '--accept-source-agreements', '--source', 'winget')
    if ($Version)  { $args += @('--version', $Version) }
    if ($Override) { $args += @('--override', $Override) }

    Write-Host "winget $($args -join ' ')"
    & winget @args
}

function Add-ToMachinePath {
    param([Parameter(Mandatory)] [string]$PathToAdd)

    $current = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $parts = $current -split ';' | Where-Object { $_ -ne '' }
    if ($parts -notcontains $PathToAdd) {
        $newPath = ($parts + $PathToAdd) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'Machine')
        $env:Path = "$env:Path;$PathToAdd"
    }
}

function Download-File {
    param(
        [Parameter(Mandatory)] [string]$Uri,
        [Parameter(Mandatory)] [string]$OutFile
    )
    Invoke-WebRequest -Uri $Uri -OutFile $OutFile
}

function Get-InstalledPowerShellVersion {
    $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if (-not $pwsh) { return $null }

    $versionText = & $pwsh.Source -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
    try { return [version]$versionText } catch { return $null }
}

function Ensure-FeatureState {
    param(
        [Parameter(Mandatory)] [string]$FeatureName,
        [Parameter(Mandatory)] [bool]$Enable
    )

    $feature = Get-WindowsOptionalFeature -Online -FeatureName $FeatureName
    $stateIsEnabled = $feature.State -eq 'Enabled'

    if ($Enable -and -not $stateIsEnabled) {
        Enable-WindowsOptionalFeature -Online -FeatureName $FeatureName -All -NoRestart | Out-Null
        $script:RebootRequired = $true
    }
    elseif (-not $Enable -and $stateIsEnabled) {
        Disable-WindowsOptionalFeature -Online -FeatureName $FeatureName -NoRestart | Out-Null
        $script:RebootRequired = $true
    }
}

function Get-OsBitnessLabel {
    if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
}

function Ensure-DotNetInstallScript {
    $scriptPath = Join-Path $TempRoot 'dotnet-install.ps1'
    if (-not (Test-Path $scriptPath)) {
        Download-File -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile $scriptPath
    }
    return $scriptPath
}

function Install-DotNetSdkVersion {
    param(
        [Parameter(Mandatory)] [string]$Version,
        [Parameter(Mandatory)] [string]$InstallDir
    )

    $dotnetInstall = Ensure-DotNetInstallScript
    & powershell.exe -ExecutionPolicy Bypass -File $dotnetInstall -Version $Version -InstallDir $InstallDir -Architecture x64
}

function Install-DotNetSdkChannel {
    param(
        [Parameter(Mandatory)] [string]$Channel,
        [Parameter(Mandatory)] [string]$InstallDir
    )

    $dotnetInstall = Ensure-DotNetInstallScript
    & powershell.exe -ExecutionPolicy Bypass -File $dotnetInstall -Channel $Channel -Quality GA -InstallDir $InstallDir -Architecture x64
}

function Get-NodeMajorMinorPatch {
    param([string]$NodeVersionText)
    return ($NodeVersionText -replace '^v', '')
}

function Get-PhysicalMemoryGB {
    $computerSystem = Get-CimInstance Win32_ComputerSystem
    return [math]::Floor($computerSystem.TotalPhysicalMemory / 1GB)
}

function Set-WslConfigForRam {
    $ramGB = Get-PhysicalMemoryGB
    if ($ramGB -ge 32) {
        $content = @"
[wsl2]
memory=8GB
processors=4
swap=4GB
"@
    }
    else {
        $content = @"
[wsl2]
memory=4GB
processors=2
swap=8GB
"@
    }

    Set-Content -Path $WslConfigPath -Value $content -Encoding ascii
    Write-Host "Updated $WslConfigPath for ${ramGB}GB RAM."
}

function Install-HelmToFolder {
    Ensure-Directory -Path $HelmInstallDir
    $zipPath = Join-Path $TempRoot 'helm-windows-amd64.zip'
    $extractPath = Join-Path $TempRoot 'helm-extract'

    if (Test-Path $extractPath) {
        Remove-Item -LiteralPath $extractPath -Recurse -Force
    }

    # Latest stable; satisfies 3.7.1+
    $releaseVersion = 'v4.1.3'
    $uri = "https://get.helm.sh/helm-$releaseVersion-windows-amd64.zip"

    Download-File -Uri $uri -OutFile $zipPath
    Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
    Copy-Item -Path (Join-Path $extractPath 'windows-amd64\helm.exe') -Destination (Join-Path $HelmInstallDir 'helm.exe') -Force
    Add-ToMachinePath -PathToAdd $HelmInstallDir
}

function Install-TerraformToFolder {
    Ensure-Directory -Path $TerraformDir
    $zipPath = Join-Path $TempRoot 'terraform.zip'

    # Latest stable at time script was authored; satisfies 1.3.5+
    $releaseVersion = '1.14.7'
    $uri = "https://releases.hashicorp.com/terraform/$releaseVersion/terraform_${releaseVersion}_windows_amd64.zip"

    Download-File -Uri $uri -OutFile $zipPath
    Expand-Archive -Path $zipPath -DestinationPath $TerraformDir -Force
    Add-ToMachinePath -PathToAdd $TerraformDir
}

function Install-VSCodeExtensions {
    $codeCmd = Get-Command code.cmd -ErrorAction SilentlyContinue
    if (-not $codeCmd) {
        $userCodeCmd = Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd'
        if (Test-Path $userCodeCmd) {
            $codeCmd = Get-Item $userCodeCmd
        }
    }

    if (-not $codeCmd) {
        Write-Warning 'VS Code CLI (code) was not found. Open VS Code once, ensure the PATH option is enabled, then rerun the extension section.'
        return
    }

    foreach ($ext in $VSCodeExtensions) {
        & $codeCmd.FullName --install-extension $ext --force | Out-Host
    }
}

# -----------------------------
# Validation
# -----------------------------
if (-not (Test-IsAdmin)) {
    throw 'Run this script from an elevated PowerShell session (Run as Administrator).'
}

Ensure-Directory -Path $TempRoot
Ensure-Winget
$script:RebootRequired = $false

Write-Section 'Disable Windows features: IIS and Hyper-V'
Ensure-FeatureState -FeatureName 'IIS-WebServerRole' -Enable:$false
Ensure-FeatureState -FeatureName 'Microsoft-Hyper-V-All' -Enable:$false

Write-Section 'Install PowerShell 7.4 or higher'
$currentPwshVersion = Get-InstalledPowerShellVersion
if (-not $currentPwshVersion -or $currentPwshVersion -lt $MinPowerShellVersion) {
    Install-WingetPackage -Id 'Microsoft.PowerShell'
}
else {
    Write-Host "PowerShell already installed: $currentPwshVersion"
}

Write-Section 'Enable and install WSL2'
Ensure-FeatureState -FeatureName 'Microsoft-Windows-Subsystem-Linux' -Enable:$true
Ensure-FeatureState -FeatureName 'VirtualMachinePlatform' -Enable:$true

try {
    wsl.exe --install --no-distribution 2>$null | Out-Host
} catch {
    Write-Warning 'WSL install command may require a reboot or may already be configured. Continuing.'
}

try {
    wsl.exe --set-default-version 2 | Out-Host
} catch {
    Write-Warning 'Could not set WSL default version yet. This usually succeeds after reboot.'
}

Set-WslConfigForRam

if (-not $SkipDocker) {
    Write-Section 'Install Docker Desktop'
    Install-WingetPackage -Id 'Docker.DockerDesktop'
}

Write-Section 'Install .NET SDK 6.0.401'
Install-DotNetSdkVersion -Version $DotNet6SdkVersion -InstallDir $DotNetInstallDir

Write-Section 'Install .NET 8 SDK'
Install-DotNetSdkChannel -Channel '8.0' -InstallDir $DotNetInstallDir

Write-Section 'Install NVM for Windows and Node.js 20.12.1'
Install-WingetPackage -Id 'CoreyButler.NVMforWindows'

$env:NVM_HOME = $env:NVM_HOME -as [string]
if (-not $env:NVM_HOME) { $env:NVM_HOME = 'C:\Program Files\nvm' }
$env:NVM_SYMLINK = $env:NVM_SYMLINK -as [string]
if (-not $env:NVM_SYMLINK) { $env:NVM_SYMLINK = 'C:\Program Files\nodejs' }
$env:Path = "$env:Path;$env:NVM_HOME;$env:NVM_SYMLINK"

$nvmCmd = Get-Command nvm.exe -ErrorAction SilentlyContinue
if (-not $nvmCmd) {
    $candidate = 'C:\Program Files\nvm\nvm.exe'
    if (Test-Path $candidate) {
        $nvmCmd = Get-Item $candidate
    }
}
if (-not $nvmCmd) {
    throw 'nvm.exe was not found after installation. A new shell or reboot may be required.'
}

& $nvmCmd.FullName install $RequiredNodeVersion | Out-Host
& $nvmCmd.FullName use $RequiredNodeVersion | Out-Host

Write-Section 'Install Yarn Classic'
& npm.cmd install --global yarn@1 | Out-Host

Write-Section 'Install Helm'
Install-HelmToFolder

Write-Section 'Install Azure CLI'
Install-WingetPackage -Id 'Microsoft.AzureCLI'

Write-Section 'Install VS Code'
Install-WingetPackage -Id 'Microsoft.VisualStudioCode'
Install-VSCodeExtensions

if (-not $SkipVisualStudio) {
    Write-Section 'Install Visual Studio Professional 2022'
    Install-WingetPackage -Id 'Microsoft.VisualStudio.2022.Professional'
}

Write-Section 'Install MongoDB Compass'
Install-WingetPackage -Id 'MongoDB.Compass.Full'

Write-Section 'Install Terraform'
Install-TerraformToFolder

Write-Section 'Summary / verification'

try { & pwsh.exe -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' | Write-Host } catch {}
try { wsl.exe --status | Out-Host } catch {}
try { docker version | Out-Host } catch { Write-Warning 'Docker may not be ready until Docker Desktop is started and/or after reboot.' }
try { & "$DotNetInstallDir\dotnet.exe" --list-sdks | Out-Host } catch {}
try { node --version | Out-Host } catch {}
try { npm --version | Out-Host } catch {}
try { yarn --version | Out-Host } catch {}
try { helm version | Out-Host } catch {}
try { az version | Out-Host } catch {}
try { terraform version | Out-Host } catch {}

if ($script:RebootRequired -and -not $SkipRebootReminder) {
    Write-Warning 'A reboot is required to finish applying Windows feature changes and may be required before WSL/Docker/nvm are fully functional.'
}
else {
    Write-Host 'Bootstrap completed.' -ForegroundColor Green
}
