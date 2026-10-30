# Windows Temporary Profile Recovery (English)

PowerShell utility to diagnose and, under **strict safety checks**, repair temporary Windows user profiles caused by **incorrect ACLs on local user registry hive files** (`NTUSER.DAT`, `UsrClass.dat` and `.LOG1` / `.LOG2` logs). Works with domain or local account names when resolvable.

**Important:** This is a specific repair for demonstrated hive-file permission failures. It is not a general fix for all temporary profile scenarios. The exact trigger of the ACL changes is unknown; **no Windows KB root cause has been confirmed**. The repair was validated on one affected workstation, not across all Windows configurations.

## Safety design

- **Read-only diagnosis by default**; modifying operations require `-Repair` and typed confirmation.
- Requires elevated **64-bit Windows PowerShell 5.1+** and the affected user completely signed out.
- Verifies expected user SID and profile path, unloaded registry hive, and full-control ACEs on parent directories.
- Restricts backup access to `SYSTEM` and Administrators; saves `ProfileList.reg` and full-fidelity backup copies using `robocopy /B /COPYALL` before modifying the originals.
- Changes ACLs **only on six expected `.DAT` / `.LOG1` / `.LOG2` files** (when they exist).
- Restores only the affected SID's `.bak` registry mapping and deletes a same-SID temporary registry entry **only if** its path matches a validated `C:\Users\TEMP...` pattern.
- Never deletes profile folders or backup folders, modifies update settings, or disables security software.

## Usage

Run **Windows PowerShell as Administrator**, signed in as a *different* admin account. Replace the example identity and directory.

Diagnosis:

```powershell
.\scripts\Repair-TemporaryProfile.ps1 -UserName 'EXAMPLE\user' -ProfilePath 'C:\Users\user'
```

Repair:

```powershell
.\scripts\Repair-TemporaryProfile.ps1 -UserName 'EXAMPLE\user' -ProfilePath 'C:\Users\user' -Repair
```

Review the backup report, type `REPAIR` to confirm, restart Windows and sign in with the affected account. Confirm the original path using `$env:USERPROFILE` and check:

```powershell
Get-CimInstance Win32_UserProfile | Where-Object { $_.LocalPath -eq $env:USERPROFILE } | Select-Object LocalPath,Loaded,Status
```

Expected: `Loaded=True`, `Status=0`, original path. Test a second sign-out/sign-in. **Keep backups** until recovery is verified and essential user data is independently backed up. Backups are under `%ProgramData%\WindowsTempProfileRecovery\Backups`.

### Limits

Not tested with FSLogix, roaming profiles, UPD, special redirected folders, EFS or custom ACL strategies. If the hive remains loaded, the backup fails, paths do not match, or the parent folder ACLs are wrong, **stop** and investigate instead of forcing a repair. Never blindly import a full `ProfileList.reg` backup: it contains entries for other users. Do not upload backup files, raw SIDs or user information to public issues.

See [README.md](README.md) for the full Portuguese walkthrough, references and details. Released under the [MIT License](LICENSE).
