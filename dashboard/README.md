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

## SSH setup (important on this laptop)

This machine has **no Windows OpenSSH** (`C:\Windows\System32\OpenSSH\ssh.exe`
is absent). The only `ssh` on `PATH` is the **Micro Focus Reflection** client.
Point the dashboard at whichever client you want via `settings.sshExe`:

| Option | `settings.sshExe` | Notes |
|---|---|---|
| **Portable OpenSSH** (most predictable) | `bin\\ssh.exe` | Download the Win32-OpenSSH release `.zip` on a machine with internet, extract, copy `ssh.exe` into `dashboard\bin\`. No install. Standard syntax — the default `sshOptions` work as-is. |
| **Existing Micro Focus client** (no download) | `""` (empty → uses `PATH`) or its full path | It is already approved on your laptop. Its option syntax may differ from OpenSSH — if SSH tasks error on startup, clear or adjust `settings.sshOptions`. |

**Key-based auth (recommended)** — no passwords in sight:
```powershell
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\id_dashboard"   # if ssh-keygen is available
# install the public key on each server:
#   append the contents of id_dashboard.pub to ~/.ssh/authorized_keys on the server
```
Then set `settings.sshKeyPath` to the **private** key path. The default
`sshOptions` use `BatchMode=yes` so a missing key fails fast instead of hanging
the window on a password prompt.

**Password auth fallback** — if keys are not permitted, carry PuTTY's portable
`plink.exe` in `bin\`, add an `ssh` task whose `sshExe` is `bin\plink.exe`, and
store the password with the credential helper (below) rather than on the
command line.

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
