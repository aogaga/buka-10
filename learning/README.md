# Enterprise Developer Workstation Bootstrap Script

## Overview

This PowerShell bootstrap script automates the setup of a complete enterprise-grade developer workstation.

The script is designed to:

- Check whether applications are already installed before attempting installation
- Generate a report of installed and missing applications
- Install only missing applications
- Support safe reruns (idempotent behavior)
- Support restart-and-rerun workflows during setup
- Generate installation logs and inventory reports
- Provide enterprise-style resiliency and error handling

The script can be safely executed multiple times.

---

# Included Applications

The script can install and manage:

- Git
- PowerShell 7
- Docker Desktop
- .NET SDK 6
- .NET SDK 8
- NVM for Windows
- Node.js
- Yarn
- Helm
- Azure CLI
- Visual Studio Code
- Visual Studio Professional
- Terraform
- MongoDB Compass
- Additional VS Code extensions

---

# Key Enterprise Features

## 1. Pre-Install Inventory Check

Before installing anything, the script:

1. Checks whether each application already exists
2. Generates two reports:
   - Installed applications
   - Missing applications
3. Prints both reports to the console
4. Exports reports to JSON and CSV
5. Installs only missing applications

---

## 2. Safe To Run Multiple Times

The script is idempotent.

This means:

- Existing applications are skipped
- Missing applications are installed
- Failed installations can be retried later
- Re-running the script will not reinstall everything unnecessarily

---

## 3. Restart-And-Rerun Friendly

Some applications installed by the script modify:

- Windows PATH
- System environment variables
- Windows features
- Shell integration
- Package manager state

Because of this, a restart is often required before newly installed tools become fully available.

The script is intentionally designed so that:

1. You can restart the machine at any time
2. Re-run the script after reboot
3. The script will continue from where it left off
4. Already installed applications will be skipped automatically

---

# IMPORTANT RECOMMENDATION

## Restart and Re-run During Setup

For the best installation experience:

1. Run the script
2. Allow some applications to install
3. Restart the computer
4. Re-run the script
5. Repeat until all applications are installed successfully

This approach is strongly recommended because:

- Some installers require a reboot
- Some PATH updates require a new shell session
- Some applications are unavailable until after restart
- Winget-installed tools may not appear immediately in the current PowerShell session

---

# How To Run The Script

## Simple Method

```powershell
powershell -ExecutionPolicy Bypass -File .\dev-workstation-bootstrap-enterprise-final.ps1 -ContinueOnError -EnableTranscriptLogging
```

---

## Inventory Only

```powershell
powershell -ExecutionPolicy Bypass -File .\dev-workstation-bootstrap-enterprise-final.ps1 -InventoryOnly
```

---

## Dry Run

```powershell
powershell -ExecutionPolicy Bypass -File .\dev-workstation-bootstrap-enterprise-final.ps1 -DryRun
```

---

# Final Notes

## This Script Is Designed To Be Re-Run

You SHOULD:

- Restart the machine during setup
- Re-run the script multiple times
- Allow the script to continue incrementally

The script was intentionally designed to support:

- Partial installs
- Interrupted installs
- Reboots during setup
- Enterprise provisioning workflows
