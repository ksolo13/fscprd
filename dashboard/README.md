# Task Dashboard

A portable, **zero-install** dashboard for running a series of tasks — local
PowerShell scripts and remote SSH commands — from a locked-down corporate
Windows laptop. No admin rights, no compiled `.exe`, nothing to install: it is
a PowerShell script that opens a native WPF window, started by a
double-clickable `.cmd`.

## Run it

1. Copy the whole `dashboard\` folder anywhere you can write (USB, OneDrive,
   `C:\Users\you\...`).
2. Double-click **`Launch-Dashboard.cmd`**.

That runs `powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File Dashboard.ps1`
— `-STA` is required for WPF, `-Bypass` is per-process and needs no policy change.

Click **Run** on the **"Hello (sample local task)"** row first — it streams a few
lines and confirms everything works end to end.

## Buttons

| Control | Does |
|---|---|
| **Run** (per row) | Run that one task |
| **Run Selected** | Run every checked task, in order |
| **Run All** | Run every task, top to bottom |
| **Stop** | Kill the running task and clear the queue |
| **Stop on first failure** | When on, a non-zero exit code halts the sequence |
| **Reload Tasks** | Re-read `tasks.json` without restarting |
| **Open Logs** | Open the `logs\` folder |

Each run streams live into the output pane and is saved to
`logs\<task-id>_<timestamp>.log`. Status badges: Ready / Queued / Running /
Success / Failed (exit code).

## Add a task — edit `tasks.json`, then **Reload Tasks**

Tasks are data, not code. Two types:

**Local PowerShell**
```json
{ "id": "my-job", "name": "My job", "type": "powershell",
  "script": "tasks\\My-Job.ps1",
  "args": { "SomeParam": "value", "SomeSwitch": true } }
```
- `script` is relative to the `dashboard\` folder (`..\` reaches the repo root).
- `args` become `-Name Value` pairs; a `true` boolean becomes a `-Switch`.
- The script is launched with `-NoProfile -ExecutionPolicy Bypass -File`.
  It runs with **no console window**, so avoid `Read-Host`; `Get-Credential`
  is fine (it shows the Windows GUI prompt).

**Remote SSH**
```json
{ "id": "check-app01", "name": "Check app01", "type": "ssh",
  "host": "app01.example.com", "user": "deploy", "port": 22,
  "command": "df -h /var && uptime" }
```
- `user`/`key`/`port` fall back to `settings.sshDefaultUser` / `sshKeyPath` if omitted.

## SSH setup (Micro Focus RUMBA client, key-based)

This laptop has no OpenSSH. The dashboard uses the **Micro Focus RUMBA** client
(`C:\Program Files (x86)\Micro Focus\RUMBA\System\ssh.exe`), which is *not*
OpenSSH: it uses `-n` (stdin from null) and `-T` (no tty) instead of
`-o BatchMode`, and writes a non-default port as `user@host#port`. The defaults
in `tasks.json` already match this.

One-time setup:

```powershell
$rumba = 'C:\Program Files (x86)\Micro Focus\RUMBA\System'

# 1. Generate a key (RUMBA writes the public key in SSH2 format)
New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.ssh" | Out-Null
& "$rumba\ssh-keygen.exe" -t rsa -b 3072 -f "$env:USERPROFILE\.ssh\id_dashboard" -N "" -C "dashboard-$env:USERNAME"

# 2. Convert the public key to the one-line OpenSSH form servers expect
$b64  = (Get-Content "$env:USERPROFILE\.ssh\id_dashboard.pub" | Where-Object { $_ -notmatch '^----' -and $_ -notmatch ':' }) -join ''
$line = "ssh-rsa $b64 dashboard-$env:USERNAME"

# 3. Install it on each server (asks for your password once)
& "$rumba\ssh.exe" user@host "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$line' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"

# 4. Test: must print output with no password prompt
& "$rumba\ssh.exe" -i "$env:USERPROFILE\.ssh\id_dashboard" -n -T user@host "hostname && uptime"
```

Safeguards: task stdin is closed (a password prompt gets EOF and fails instead
of hanging) and ssh tasks time out after `settings.sshTimeoutSec` (default 120s;
override per task with `timeoutSec`). A timeout reports exit code 124.

To use a different client (e.g. portable OpenSSH in `bin\`), set `settings.sshExe`
and replace `settings.sshOptions` with `["-o","BatchMode=yes"]`.

## Credentials (`lib\Credentials.psm1`)

Secrets are stored with Windows DPAPI (`Export-Clixml`) — readable only by you,
only on this machine — the same pattern `Export-AgphData.ps1` uses.
```powershell
Import-Module .\lib\Credentials.psm1
Save-DashboardCredential -Name oracle-agph        # prompts, encrypts to %USERPROFILE%\.taskdashboard\
```

## Files

| File | Purpose |
|---|---|
| `Launch-Dashboard.cmd` | Double-click entry point |
| `Dashboard.ps1` | WPF app: rows, run loop, live output |
| `Dashboard.xaml` | Window layout |
| `tasks.json` | Task registry + settings (you edit this) |
| `lib\TaskRunner.psm1` | Execution engine (PowerShell + SSH) |
| `lib\Credentials.psm1` | DPAPI secret store |
| `tasks\` | Task scripts (`Hello-Task.ps1` sample) |
| `logs\` | Per-run logs |
| `bin\` | Optional portable binaries (`ssh.exe` / `plink.exe`) |

## Requirements (all already present on your laptop)

- Windows PowerShell 5.1, `FullLanguage` mode
- .NET Framework 4.x (ships with Windows) for WPF
- An SSH client for `ssh` tasks (see above)
- For the AGPH task: `Oracle.ManagedDataAccess.dll` next to `Export-AgphData.ps1`
  and DB access (see `..\RUNBOOK.md`)
