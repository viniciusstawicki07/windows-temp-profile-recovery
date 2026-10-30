#Requires -Version 5.1
<#
.SYNOPSIS
    Diagnoses and repairs a Windows user profile affected by incorrect registry-hive file ACLs.
.DESCRIPTION
    Read-only by default. With -Repair, creates a protected backup of the relevant hive files,
    their transactional logs and ProfileList registry key, restores inherited ACLs on six
    specific files, and restores an original ProfileList entry from a .bak key when applicable.
    Does not remove user folders, disable security tools, or uninstall Windows updates.
.PARAMETER UserName
    Identity in DOMAIN\username or COMPUTER\username form.
.PARAMETER ProfilePath
    Exact original local profile path, e.g. C:\Users\example.user.
.PARAMETER Repair
    Perform the repair after safety checks, backup, and interactive confirmation.
.EXAMPLE
    .\Repair-TemporaryProfile.ps1 -UserName 'EXAMPLE\jdoe' -ProfilePath 'C:\Users\jdoe'
.EXAMPLE
    .\Repair-TemporaryProfile.ps1 -UserName 'EXAMPLE\jdoe' -ProfilePath 'C:\Users\jdoe' -Repair
.NOTES
    Run elevated, from a DIFFERENT administrator account, after signing out the affected user.
    Intended for local profiles whose .DAT and .LOG file permissions are broken.
    Review README.md before running. No warranty; MIT License.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$UserName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ProfilePath,

    [switch]$Repair
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-NativeSuccess {
    param([string]$Step)
    if ($LASTEXITCODE -ne 0) { throw "$Step failed (exit code $LASTEXITCODE)." }
}

function Get-ProfileState {
    param([string]$Sid)
    $rows = @(Get-CimInstance -ClassName Win32_UserProfile -Filter "SID='$Sid'")
    return $rows
}

function Assert-Unloaded {
    param([string]$Sid)
    $loaded = @(Get-ProfileState -Sid $Sid | Where-Object { $_.Loaded })
    if ($loaded.Count -gt 0 -or (Test-Path -LiteralPath "Registry::HKEY_USERS\$Sid") -or (Test-Path -LiteralPath "Registry::HKEY_USERS\$($Sid)_Classes")) {
        throw 'The profile is still loaded. Sign out the user completely, or reboot and log on directly with another administrator account.'
    }
}

function Assert-ParentAcl {
    param([string]$Folder, [string]$Sid)
    $acl = Get-Acl -LiteralPath $Folder
    $rules = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
    foreach ($identity in @($Sid, 'S-1-5-18', 'S-1-5-32-544')) {
        $ok = @($rules | Where-Object {
            $_.IdentityReference.Value -eq $identity -and
            $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
            (($_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -eq [System.Security.AccessControl.FileSystemRights]::FullControl)
        }).Count -gt 0
        if (-not $ok) { throw "Parent folder $Folder does not have an explicit/inherited FullControl allowance for $identity. Fix its ACL manually before continuing." }
    }
    $denies = @($rules | Where-Object { $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Deny })
    if ($denies.Count -gt 0) { throw "Parent folder $Folder has explicit/inherited Deny entries; manual review required." }
}

function New-ProtectedBackupFolder {
    param([string]$Folder)
    [void](New-Item -ItemType Directory -Path $Folder -Force)
    $acl = [System.Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $identity = [System.Security.Principal.SecurityIdentifier]::new($sid)
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $identity,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            ([System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit),
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        [void]$acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Folder -AclObject $acl
    $effective = Get-Acl -LiteralPath $Folder
    if (-not $effective.AreAccessRulesProtected) { throw 'Backup folder ACL protection was not applied.' }
}

function Invoke-RobocopyBackup {
    param([string]$Source, [string]$Destination, [string]$Pattern, [string]$LogFile)
    [void](New-Item -ItemType Directory -Path $Destination -Force)
    $files = @(Get-ChildItem -LiteralPath $Source -Force -File | Where-Object { $_.Name -like $Pattern })
    if ($files.Count -eq 0) { throw "No files match $Pattern in $Source" }
    $arguments = @($Source, $Destination, $Pattern, '/B', '/COPYALL', '/R:0', '/W:0')
    $output = & robocopy.exe @arguments 2>&1
    $code = $LASTEXITCODE
    $output | Out-File -LiteralPath $LogFile -Encoding UTF8
    if ($code -ge 8) { throw "Robocopy failed with exit code $code. See $LogFile" }
    foreach ($file in $files) {
        $copy = Join-Path $Destination $file.Name
        if (-not (Test-Path -LiteralPath $copy)) { throw "Backup missing file: $copy" }
        if ((Get-Item -LiteralPath $copy -Force).Length -ne $file.Length) {
            throw "Backup size mismatch for $copy"
        }
    }
    Write-Host "Backed up $($files.Count) file(s) for $Pattern."
}

function Assert-SafeRegistryLayout {
    param([string]$Original, [string]$OriginalBak, [string]$ExpectedPath)
    $hasOriginal = Test-Path -LiteralPath $Original
    $hasBak = Test-Path -LiteralPath $OriginalBak
    if ($hasBak) {
        $bakPath = (Get-ItemProperty -LiteralPath $OriginalBak).ProfileImagePath
        if ($bakPath -ine $ExpectedPath) { throw "The .bak key points to '$bakPath', not '$ExpectedPath'." }
        if ($hasOriginal) {
            $tempPath = (Get-ItemProperty -LiteralPath $Original).ProfileImagePath
            $pattern = '^' + [regex]::Escape((Join-Path (Split-Path -Path $ExpectedPath -Parent) 'TEMP')) + '(\.[^\\]+)?$'
            if ($tempPath -notmatch $pattern) { throw "Existing SID key does not point to a recognized TEMP path: '$tempPath'." }
        }
    } elseif ($hasOriginal) {
        $path = (Get-ItemProperty -LiteralPath $Original).ProfileImagePath
        if ($path -ine $ExpectedPath) { throw "SID key points to '$path', not the original profile." }
    } else {
        throw 'Neither the original SID registry entry nor its .bak entry exists. Manual diagnosis required.'
    }
}

# --- Preflight: fail closed before any write ---
if (-not [Environment]::Is64BitOperatingSystem -or -not [Environment]::Is64BitProcess) {
    throw 'Use 64-bit Windows PowerShell running on 64-bit Windows.'
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run an elevated Windows PowerShell as a local administrator.'
}
if (-not ($UserName -match '^[^\\]+\\[^\\]+$')) { throw 'Use DOMAIN\username (or COMPUTER\username).' }
$sid = ([System.Security.Principal.NTAccount]::new($UserName)).Translate([System.Security.Principal.SecurityIdentifier]).Value
$ProfilePath = [IO.Path]::GetFullPath($ProfilePath).TrimEnd('\')
if ($ProfilePath -eq [IO.Path]::GetPathRoot($ProfilePath)) { throw 'The supplied profile path is a drive root.' }
if (-not (Test-Path -LiteralPath $ProfilePath -PathType Container)) { throw "Profile folder not found: $ProfilePath" }
if (((Get-Item -LiteralPath $ProfilePath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'The profile path is a reparse point. Manual review required.'
}
if ($identity.User.Value -eq $sid) { throw 'Do not repair the currently logged-on user profile.' }
$base = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
$original = Join-Path $base $sid
$bak = Join-Path $base ($sid + '.bak')
$hiveFolder = Join-Path $ProfilePath 'AppData\Local\Microsoft\Windows'
if (-not (Test-Path -LiteralPath $hiveFolder -PathType Container)) { throw "Missing folder: $hiveFolder" }
$hives = @((Join-Path $ProfilePath 'NTUSER.DAT'), (Join-Path $hiveFolder 'UsrClass.dat'))
foreach ($file in $hives) { if (-not (Test-Path -LiteralPath $file)) { throw "Missing hive file: $file" } }
$files = @(
    (Join-Path $ProfilePath 'NTUSER.DAT'),
    (Join-Path $ProfilePath 'NTUSER.DAT.LOG1'),
    (Join-Path $ProfilePath 'NTUSER.DAT.LOG2'),
    (Join-Path $hiveFolder 'UsrClass.dat'),
    (Join-Path $hiveFolder 'UsrClass.dat.LOG1'),
    (Join-Path $hiveFolder 'UsrClass.dat.LOG2')
) | Where-Object { Test-Path -LiteralPath $_ }

Write-Host "Account: $UserName"
Write-Host "SID: $sid"
Write-Host "Original profile path: $ProfilePath"
$states = @(Get-ProfileState -Sid $sid)
$states | Select-Object LocalPath, Loaded, Status | Format-Table -AutoSize
Write-Host 'ProfileList entries:'
foreach ($key in @($original, $bak)) {
    if (Test-Path -LiteralPath $key) {
        $p = Get-ItemProperty -LiteralPath $key
        Write-Host "  $key => $($p.ProfileImagePath), State=$($p.State)"
    }
}
Write-Host 'Hive ACLs (icacls exit codes):'
foreach ($file in $files) {
    & icacls.exe $file
    Write-Host "  Exit code: $LASTEXITCODE"
}

if (-not $Repair) {
    Write-Host 'Diagnosis only. No changes were made. To repair, run again with -Repair.'
    exit 0
}

Assert-Unloaded -Sid $sid
Assert-ParentAcl -Folder $ProfilePath -Sid $sid
Assert-ParentAcl -Folder $hiveFolder -Sid $sid
Assert-SafeRegistryLayout -Original $original -OriginalBak $bak -ExpectedPath $ProfilePath

$backupRoot = Join-Path $env:ProgramData 'WindowsTempProfileRecovery\Backups'
$backupDir = Join-Path $backupRoot ('profile-' + $sid + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-ProtectedBackupFolder -Folder $backupDir
Write-Host "Protected backup folder: $backupDir"
$registryBackup = Join-Path $backupDir 'ProfileList.reg'
& reg.exe export 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' $registryBackup /y | Out-Null
Assert-NativeSuccess -Step 'Registry export'
if (-not (Test-Path -LiteralPath $registryBackup)) { throw 'Registry backup file was not created.' }
Invoke-RobocopyBackup -Source $ProfilePath -Destination (Join-Path $backupDir 'UserHive') -Pattern 'NTUSER.DAT*' -LogFile (Join-Path $backupDir 'robocopy-ntuser.log')
Invoke-RobocopyBackup -Source $hiveFolder -Destination (Join-Path $backupDir 'ClassHive') -Pattern 'UsrClass.dat*' -LogFile (Join-Path $backupDir 'robocopy-usrclass.log')

Write-Warning 'The next step will change NTFS ACLs of up to six hive files and the user SID ProfileList registry entry.'
Write-Warning 'It will NOT delete temporary profile folders. Keep the backup until two successful sign-ins.'
$answer = Read-Host 'Type REPAIR to proceed (all other responses cancel)'
if ($answer -cne 'REPAIR') { throw "Cancelled. Backup remains at $backupDir" }

# Recheck state because the user might have signed in while the backup ran.
Assert-Unloaded -Sid $sid
Assert-SafeRegistryLayout -Original $original -OriginalBak $bak -ExpectedPath $ProfilePath
foreach ($file in $files) {
    & takeown.exe /F $file /A | Out-Null
    Assert-NativeSuccess -Step "takeown $file"
    & icacls.exe $file /reset | Out-Null
    Assert-NativeSuccess -Step "icacls /reset $file"
    & icacls.exe $file | Out-Null
    Assert-NativeSuccess -Step "icacls validation $file"
    Write-Host "ACL reset: $file"
}

# Registry repair, only for the explicitly checked SID. Never recursively delete profile folders.
if (Test-Path -LiteralPath $bak) {
    if (Test-Path -LiteralPath $original) {
        Remove-Item -LiteralPath $original -Recurse -Force -ErrorAction Stop
        Write-Host 'Removed the TEMP ProfileList key (registry only).'
    }
    Rename-Item -LiteralPath $bak -NewName $sid -ErrorAction Stop
    Write-Host 'Restored original ProfileList SID from .bak.'
}
Set-ItemProperty -LiteralPath $original -Name State -Value 0 -ErrorAction Stop
$p = Get-ItemProperty -LiteralPath $original
if ($p.PSObject.Properties.Name -contains 'RefCount') {
    Set-ItemProperty -LiteralPath $original -Name RefCount -Value 0 -ErrorAction Stop
}
if ((Get-ItemProperty -LiteralPath $original).ProfileImagePath -ine $ProfilePath) { throw 'Post-repair ProfileImagePath validation failed.' }
if (Test-Path -LiteralPath $bak) { throw 'Post-repair: .bak registry entry still exists.' }
Write-Host "Repair finished. Restart and sign in as $UserName."
Write-Host 'After login, validate: $env:USERPROFILE and Get-CimInstance Win32_UserProfile.'
Write-Host "Keep backup: $backupDir"
