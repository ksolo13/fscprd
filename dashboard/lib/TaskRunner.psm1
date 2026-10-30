#Requires -Version 5.1
<#
    TaskRunner.psm1 - execution engine for the Task Dashboard.

    Every task (local PowerShell or remote SSH) is launched as an external
    process. stdout is streamed live into a thread-safe queue the UI drains;
    stderr is collected concurrently and appended at the end. Each run is also
    tee'd to a timestamped log file. Exit codes are reported verbatim
    (Export-AgphData.ps1 and similar return 0 on success, 1 on failure).

    Invoke-TaskProcess is designed to run inside a dedicated runspace so the UI
    thread never blocks. The caller shares a synchronized hashtable ($Shared)
    carrying the output Queue, the Process handle (for Stop), the ExitCode and
    a Done flag.
#>

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# --- Helpers -----------------------------------------------------------------

function ConvertTo-Arg {
    # Quote a single command-line argument when it contains spaces or quotes.
    param([object]$Value)
    $s = [string]$Value
    if ($s -match '[\s"]') { '"' + ($s -replace '"', '\"') + '"' } else { $s }
}

function Resolve-SshExe {
    param($Settings)
    $candidates = @()
    if ($Settings -and $Settings.sshExe) { $candidates += [string]$Settings.sshExe }
    $candidates += (Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe')
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return 'ssh'   # last resort: whatever is first on PATH
}

function Resolve-LogDir {
    param($Settings, [string]$ScriptRoot)
    $d = if ($Settings -and $Settings.logDir) { [string]$Settings.logDir } else { 'logs' }
    if (-not [System.IO.Path]::IsPathRooted($d)) { $d = Join-Path $ScriptRoot $d }
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    return $d
}

function Build-TaskCommand {
    <#
        Returns @{ FilePath; Arguments; Display } for a task.
        type 'powershell' -> powershell.exe -NoProfile -ExecutionPolicy Bypass -File <script> <params>
        type 'ssh'        -> <sshExe> <options> [-i key] [-p port] user@host "<command>"
    #>
    param($Task, $Settings, [string]$ScriptRoot)

    switch ($Task.type) {
        'powershell' {
            $script = [string]$Task.script
            if (-not [System.IO.Path]::IsPathRooted($script)) { $script = Join-Path $ScriptRoot $script }
            if (-not (Test-Path -LiteralPath $script)) { throw "Script not found: $script" }
            $script = (Resolve-Path -LiteralPath $script).Path

            $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (ConvertTo-Arg $script))
            if ($Task.args) {
                foreach ($p in $Task.args.PSObject.Properties) {
                    $v = $p.Value
                    if ($v -is [bool]) {
                        if ($v) { $argList += "-$($p.Name)" }            # switch parameter
                    }
                    elseif ($null -ne $v -and "$v" -ne '') {
                        $argList += "-$($p.Name)"
                        $argList += (ConvertTo-Arg $v)
                    }
                }
            }
            $argStr = ($argList -join ' ')
            return @{
                FilePath  = (Join-Path $PSHOME 'powershell.exe')
                Arguments = $argStr
                Display   = "powershell.exe $argStr"
            }
        }
        'ssh' {
            if (-not $Task.host) { throw "ssh task '$($Task.id)' has no host" }
            $sshExe = Resolve-SshExe $Settings
            $user = if ($Task.user) { [string]$Task.user }
                    elseif ($Settings -and $Settings.sshDefaultUser) { [string]$Settings.sshDefaultUser }
                    else { throw "ssh task '$($Task.id)' has no user (set it on the task or settings.sshDefaultUser)" }

            $opts = if ($Settings -and $Settings.sshOptions) { @($Settings.sshOptions) }
                    else { @('-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=15') }

            $argList = @() + $opts
            $key = if ($Task.key) { [string]$Task.key }
                   elseif ($Settings -and $Settings.sshKeyPath) { [string]$Settings.sshKeyPath }
                   else { $null }
            if ($key) { $argList += '-i'; $argList += (ConvertTo-Arg $key) }
            if ($Task.port) { $argList += '-p'; $argList += [string]$Task.port }
            $argList += "$user@$($Task.host)"
            $argList += (ConvertTo-Arg $Task.command)

            $argStr = ($argList -join ' ')
            return @{
                FilePath  = $sshExe
                Arguments = $argStr
                Display   = "ssh $argStr"
            }
        }
        default { throw "Unknown task type '$($Task.type)' for task '$($Task.id)'" }
    }
}

# --- Worker (runs inside a dedicated runspace) -------------------------------

function Invoke-TaskProcess {
    param($Task, $Settings, $Shared, [string]$ScriptRoot)

    $log = $null
    try {
        $spec   = Build-TaskCommand -Task $Task -Settings $Settings -ScriptRoot $ScriptRoot
        $logDir = Resolve-LogDir $Settings $ScriptRoot
        $stamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
        $logPath = Join-Path $logDir ("{0}_{1}.log" -f $Task.id, $stamp)
        $Shared.LogPath = $logPath

        $log = New-Object System.IO.StreamWriter($logPath, $false, (New-Object System.Text.UTF8Encoding($false)))
        $log.AutoFlush = $true
        $emit = {
            param($line)
            $Shared.Queue.Enqueue([string]$line)
            $log.WriteLine([string]$line)
        }

        & $emit ("# {0}  [{1}]" -f $Task.name, $Task.id)
        & $emit ("# started {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        & $emit ("# > {0}" -f $spec.Display)
        & $emit ('')

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $spec.FilePath
        $psi.Arguments              = $spec.Arguments
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow         = $true
        $psi.WorkingDirectory       = $ScriptRoot

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        $Shared.Process = $proc
        [void]$proc.Start()

        # Drain stderr concurrently so a full stderr buffer can't deadlock stdout.
        $errTask = $proc.StandardError.ReadToEndAsync()

        while ($null -ne ($line = $proc.StandardOutput.ReadLine())) { & $emit $line }
        $proc.WaitForExit()

        $err = $errTask.Result
        if ($err) {
            foreach ($l in ($err -split "`r?`n")) { if ($l.Length) { & $emit ("[stderr] " + $l) } }
        }

        $Shared.ExitCode = $proc.ExitCode
        & $emit ('')
        & $emit ("# exit code: {0}" -f $proc.ExitCode)
    }
    catch {
        try { $Shared.Queue.Enqueue("[dashboard-error] " + $_.Exception.Message) } catch { }
        if ($log) { try { $log.WriteLine("[dashboard-error] " + $_.Exception.Message) } catch { } }
        $Shared.ExitCode = 2
    }
    finally {
        if ($log) { try { $log.Dispose() } catch { } }
        $Shared.Done = $true
    }
}

Export-ModuleMember -Function Invoke-TaskProcess, Build-TaskCommand, Resolve-SshExe, Resolve-LogDir, ConvertTo-Arg
