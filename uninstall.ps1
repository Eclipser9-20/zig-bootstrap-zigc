#!/usr/bin/env pwsh
# Removes a ziggy install done by install.ps1.
#
# Run elevated (Administrator) to remove a system-wide install:
#   C:\Program Files\ziggy\        removed, and dropped from the machine PATH
# Run un-elevated to remove a per-user install:
#   %LOCALAPPDATA%\ziggy\          removed, and dropped from the user PATH
#
# Leaves the "_ZIGGYmaintenance" local group in place, since removing a
# group can strand its membership on other machines/tools that reference
# it by name; delete it yourself with Remove-LocalGroup if you're sure
# nothing else depends on it.

$ErrorActionPreference = "Stop"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($isAdmin) {
    $ZiggyHome = "C:\Program Files\ziggy"
    $PathScope = "Machine"
} else {
    $ZiggyHome = Join-Path $env:LOCALAPPDATA "ziggy"
    $PathScope = "User"
}

if (Test-Path $ZiggyHome) {
    Remove-Item -Recurse -Force $ZiggyHome
    Write-Host "==> Removed $ZiggyHome" -ForegroundColor Cyan
} else {
    Write-Host "==> $ZiggyHome not found, nothing to remove there." -ForegroundColor Yellow
    if ($isAdmin) {
        Write-Host "    (run without elevation to remove a per-user install instead)" -ForegroundColor DarkGray
    } else {
        Write-Host "    (run elevated to remove a system-wide install instead)" -ForegroundColor DarkGray
    }
}

$existingPath = [Environment]::GetEnvironmentVariable("Path", $PathScope)
$pathEntries = $existingPath -split ';' | Where-Object { $_ -and $_ -ne $ZiggyHome }
if (($existingPath -split ';') -contains $ZiggyHome) {
    [Environment]::SetEnvironmentVariable("Path", ($pathEntries -join ';'), $PathScope)
    Write-Host "==> Removed $ZiggyHome from the $PathScope PATH." -ForegroundColor Cyan
}

Write-Host "==> ziggy has been uninstalled. Restart open terminals to drop it from PATH." -ForegroundColor Green
