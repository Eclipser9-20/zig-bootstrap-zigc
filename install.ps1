#!/usr/bin/env pwsh
# Installs ziggy (this repo's Zig fork, with vendored llvm-tools nm/objdump)
# on Windows, FROM A LOCAL BUILD — there is no GitHub Releases artifact for
# ziggy yet.
#
# Prerequisite: build it first with `build.bat <target> <mcpu>` (from a
# Visual Studio developer command prompt), which produces a flat install
# tree at out-win\zig-<target>-<mcpu>\ (binary at the root of that dir,
# e.g. out-win\zig-x86_64-windows-gnu-baseline\zig.exe). This script copies
# that whole tree into place and renames the binary to "ziggy.exe" so it
# doesn't collide with a real Zig install.
#
# Run elevated (Administrator) for a system-wide install:
#   C:\Program Files\ziggy\ziggy.exe   the binary, alongside lib\, doc\, ...
# The install dir is added to the machine PATH. To let a later re-run of
# this script (to pick up a newer local build) work WITHOUT elevation, a
# local group "_ZIGGYmaintenance" is created and granted Modify rights on
# the install directory specifically (not Program Files as a whole) — the
# same "owner has full control, group can update, everyone else read+
# execute only" model as install.sh's Unix group, just via an NTFS ACL
# instead of POSIX permission bits. Add another user to that group
# (`Add-LocalGroupMember -Group _ZIGGYmaintenance -Member <user>`) to let
# them update without an admin prompt too.
#
# Run un-elevated for a per-user install, no admin needed:
#   %LOCALAPPDATA%\ziggy\ziggy.exe
# added to the current user's PATH. No group/ACL setup — the user already
# owns everything they'd want to update.
#
# Re-running this script (fresh install or update) always overwrites the
# install directory in place — that's the whole self-update story for
# now, until ziggy gets its own --update subcommand.
#
# Params:
#   -From      path to a local build output dir (e.g.
#              out-win\zig-x86_64-windows-gnu-baseline) to install
#              instead of auto-detecting the newest one.
#   -GrantTo   (elevated installs only) user (DOMAIN\name or name) to add
#              to _ZIGGYmaintenance. Defaults to whoever is running the
#              installer — but when this runs as NT AUTHORITY\SYSTEM (a
#              deployment tool or scheduled task), that default is
#              useless, since nobody logs in as SYSTEM. In that case, pass
#              the real target user explicitly, e.g. -GrantTo "CONTOSO\jsmith".

param(
    [string]$From = "",
    [string]$GrantTo = ""
)

$ErrorActionPreference = "Stop"

$RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $From) {
    # Auto-detect the most recently modified out*\zig-*\ directory.
    $candidates = Get-ChildItem -Path $RootDir -Directory -Filter "out*" -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ChildItem -Path $_.FullName -Directory -Filter "zig-*" -ErrorAction SilentlyContinue }
    $newest = $candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($newest) {
        $From = $newest.FullName
    }
}

if (-not $From -or -not (Test-Path $From -PathType Container)) {
    Write-Error "no build output found -- run build.bat <target> <mcpu> first (or pass -From <path-to-build-output>)"
    exit 1
}

$SrcExe = Join-Path $From "zig.exe"
if (-not (Test-Path $SrcExe -PathType Leaf)) {
    Write-Error "no build output found -- '$From' doesn't contain a zig.exe binary. Run build.bat <target> <mcpu> first, or pass -From <path-to-build-output>."
    exit 1
}

Write-Host "==> Installing ziggy from local build: $From" -ForegroundColor Cyan

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($isAdmin) {
    $ZiggyHome = "C:\Program Files\ziggy"
    $PathScope = "Machine"
} else {
    $ZiggyHome = Join-Path $env:LOCALAPPDATA "ziggy"
    $PathScope = "User"
}
$TargetExe = Join-Path $ZiggyHome "ziggy.exe"

$updating = Test-Path $ZiggyHome
if ($updating) {
    Write-Host "==> $ZiggyHome already exists -- updating in place" -ForegroundColor Cyan
} else {
    Write-Host "==> Installing ziggy to $ZiggyHome" -ForegroundColor Cyan
}
if (-not $isAdmin) {
    Write-Host "    (per-user install -- run elevated instead for a system-wide install)" -ForegroundColor DarkGray
}

# Copy the whole build output tree to a staging dir first, so a
# half-finished copy never replaces a working install, then swap it in.
$TmpHome = "$ZiggyHome.new.$PID"
if (Test-Path $TmpHome) { Remove-Item -Recurse -Force $TmpHome }
New-Item -ItemType Directory -Force -Path $TmpHome | Out-Null
Copy-Item -Path (Join-Path $From "*") -Destination $TmpHome -Recurse -Force

$TmpExe = Join-Path $TmpHome "zig.exe"
if (-not (Test-Path $TmpExe -PathType Leaf)) {
    Remove-Item -Recurse -Force $TmpHome
    Write-Error "unexpected build output layout -- no zig.exe at the root of $From"
    exit 1
}
Move-Item -Force $TmpExe (Join-Path $TmpHome "ziggy.exe")

if (Test-Path $ZiggyHome) { Remove-Item -Recurse -Force $ZiggyHome }
Move-Item -Force $TmpHome $ZiggyHome

# Add the install dir to the appropriate PATH (machine-wide when elevated,
# current user's otherwise) if it isn't already there.
$existingPath = [Environment]::GetEnvironmentVariable("Path", $PathScope)
if (($existingPath -split ';') -notcontains $ZiggyHome) {
    [Environment]::SetEnvironmentVariable("Path", "$existingPath;$ZiggyHome", $PathScope)
    Write-Host "==> Added $ZiggyHome to the $PathScope PATH." -ForegroundColor Yellow
}

if (-not $isAdmin) {
    Write-Host "==> Installed: $TargetExe" -ForegroundColor Green
    Write-Host "==> Open a new shell before 'ziggy version' works (PATH was updated)." -ForegroundColor Yellow
    return
}

$GroupName = "_ZIGGYmaintenance"
if (-not (Get-LocalGroup -Name $GroupName -ErrorAction SilentlyContinue)) {
    New-LocalGroup -Name $GroupName -Description "Can update ziggy without elevation" | Out-Null
}

$grantUser = $GrantTo
if (-not $grantUser) {
    if ("$env:USERNAME" -eq "SYSTEM") {
        # Running as NT AUTHORITY\SYSTEM (a deployment tool or scheduled
        # task) with no -GrantTo given -- fall back to whoever owns the
        # explorer.exe process, i.e. the actual interactive user, if one
        # is logged on.
        $explorer = Get-CimInstance Win32_Process -Filter "Name = 'explorer.exe'" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($explorer) {
            $owner = Invoke-CimMethod -InputObject $explorer -MethodName GetOwner
            if ($owner.ReturnValue -eq 0) {
                $grantUser = "$($owner.Domain)\$($owner.User)"
            }
        }
    } else {
        $grantUser = "$env:USERDOMAIN\$env:USERNAME"
    }
}

if ($grantUser) {
    try {
        Add-LocalGroupMember -Group $GroupName -Member $grantUser -ErrorAction Stop
    } catch [Microsoft.PowerShell.Commands.MemberExistsException] {
        # Already a member -- fine, nothing to do.
    }
} else {
    Write-Host "==> Running as SYSTEM with no logged-on user found and no -GrantTo given." -ForegroundColor Yellow
    Write-Host "    Nobody was added to '$GroupName' -- add the intended user yourself:" -ForegroundColor Yellow
    Write-Host "        Add-LocalGroupMember -Group $GroupName -Member <DOMAIN\user>" -ForegroundColor Yellow
}

$acl = Get-Acl $ZiggyHome
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $GroupName, "Modify", "ContainerInherit,ObjectInherit", "None", "Allow"
)
$acl.AddAccessRule($rule)
Set-Acl $ZiggyHome $acl

Write-Host "==> $ZiggyHome is group-writable by '$GroupName'." -ForegroundColor Cyan
if ($grantUser) {
    Write-Host "    $grantUser was added to it." -ForegroundColor Cyan
}
Write-Host "==> Installed: $TargetExe" -ForegroundColor Green
Write-Host "==> Open a new shell before 'ziggy version' works (PATH was updated)." -ForegroundColor Yellow
