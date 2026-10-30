#Requires -Version 5.1
<#
.SYNOPSIS
    Task Dashboard - a portable, zero-install WPF front end for running local
    PowerShell scripts and remote SSH commands.

.DESCRIPTION
    Reads tasks.json, shows one row per task with a live status badge, and runs
    tasks on demand (one, a selection, or all in sequence). Each task runs in a
    dedicated runspace as an external process; stdout streams live into the
    output pane and a timestamped log under .\logs. See README.md.

    Launch via Launch-Dashboard.cmd (which supplies -STA, required for WPF).

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\Dashboard.ps1
#>
[CmdletBinding()]
param([string]$ConfigPath)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

# Resolve our own folder in the body: $PSScriptRoot is reliable here even when it
# is empty during param-default binding (e.g. the ExecutionPolicy "Run once" path).
$script:ScriptRoot =
    if ($PSScriptRoot) { $PSScriptRoot }
    elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
    else { (Get-Location).Path }

if (-not $ConfigPath) { $ConfigPath = Join-Path $script:ScriptRoot 'tasks.json' }

$script:ModulePath = Join-Path $script:ScriptRoot 'lib\TaskRunner.psm1'
Import-Module $script:ModulePath -Force -DisableNameChecking
Import-Module (Join-Path $script:ScriptRoot 'lib\Credentials.psm1') -Force -DisableNameChecking

# --- Load config -------------------------------------------------------------
function Read-Config {
    if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Config not found: $ConfigPath" }
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    if (-not $cfg.tasks) { throw "tasks.json has no 'tasks' array." }
    $cfg
}
$script:config   = Read-Config
$script:settings = if ($script:config.settings) { $script:config.settings } else { [pscustomobject]@{} }

# --- Load UI -----------------------------------------------------------------
[xml]$xamlDoc = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Dashboard.xaml') -Raw
$reader  = New-Object System.Xml.XmlNodeReader $xamlDoc
$window  = [Windows.Markup.XamlReader]::Load($reader)

$TaskList       = $window.FindName('TaskList')
$Output         = $window.FindName('Output')
$StatusText     = $window.FindName('StatusText')
$BtnRunSelected = $window.FindName('BtnRunSelected')
$BtnRunAll      = $window.FindName('BtnRunAll')
$BtnStop        = $window.FindName('BtnStop')
$BtnReload      = $window.FindName('BtnReload')
$BtnOpenLogs    = $window.FindName('BtnOpenLogs')
$ChkStopOnFail  = $window.FindName('ChkStopOnFail')

# --- State -------------------------------------------------------------------
$script:rows      = @{}                                           # id -> @{ Status; Check }
$script:tasksById = @{}
$script:runQueue  = New-Object System.Collections.Generic.List[string]
$script:current   = $null                                        # running task context

function New-Brush([string]$hex) { (New-Object System.Windows.Media.BrushConverter).ConvertFromString($hex) }

function Set-RowStatus([string]$id, [string]$state, $code) {
    $r = $script:rows[$id]; if (-not $r) { return }
    switch ($state) {
        'Ready'   { $r.Status.Text = 'Ready';   $r.Status.Foreground = New-Brush '#9CA3AF' }
        'Queued'  { $r.Status.Text = 'Queued';  $r.Status.Foreground = New-Brush '#9CDCFE' }
        'Running' { $r.Status.Text = 'Running'; $r.Status.Foreground = New-Brush '#D7BA7D' }
        'Success' { $r.Status.Text = 'Success'; $r.Status.Foreground = New-Brush '#4EC9B0' }
        'Failed'  { $r.Status.Text = ("Failed ({0})" -f $code); $r.Status.Foreground = New-Brush '#F48771' }
    }
}

function Set-Running([bool]$running) {
    $BtnRunSelected.IsEnabled = -not $running
    $BtnRunAll.IsEnabled      = -not $running
    $BtnReload.IsEnabled      = -not $running
    $BtnStop.IsEnabled        = $running
}

# --- Build task rows ---------------------------------------------------------
function Build-Rows {
    $TaskList.Children.Clear()
    $script:rows.Clear()
    $script:tasksById.Clear()

    foreach ($t in $script:config.tasks) {
        $script:tasksById[$t.id] = $t

        $border = New-Object System.Windows.Controls.Border
        $border.BorderBrush = New-Brush '#555'
        $border.BorderThickness = '1'
        $border.CornerRadius = '3'
        $border.Margin = '0,0,0,6'
        $border.Padding = '6'
        $border.Background = New-Brush '#252526'

        $grid = New-Object System.Windows.Controls.Grid
        1..3 | ForEach-Object { $null = $grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)) }
        $grid.ColumnDefinitions[0].Width = 'Auto'
        $grid.ColumnDefinitions[1].Width = '*'
        $grid.ColumnDefinitions[2].Width = 'Auto'

        $check = New-Object System.Windows.Controls.CheckBox
        $check.VerticalAlignment = 'Center'; $check.Margin = '2,0,8,0'
        [System.Windows.Controls.Grid]::SetColumn($check, 0)

        $info = New-Object System.Windows.Controls.StackPanel
        [System.Windows.Controls.Grid]::SetColumn($info, 1)
        $name = New-Object System.Windows.Controls.TextBlock
        $name.Text = "$($t.name)  [$($t.type)]"; $name.FontWeight = 'Bold'
        $name.Foreground = New-Brush '#DCDCDC'; $name.TextWrapping = 'Wrap'
        $status = New-Object System.Windows.Controls.TextBlock
        $status.Text = 'Ready'; $status.Foreground = New-Brush '#9CA3AF'; $status.FontSize = 11
        $desc = New-Object System.Windows.Controls.TextBlock
        $desc.Text = [string]$t.description; $desc.Foreground = New-Brush '#8C8C8C'
        $desc.FontSize = 11; $desc.TextWrapping = 'Wrap'
        $null = $info.Children.Add($name)
        $null = $info.Children.Add($status)
        if ($t.description) { $null = $info.Children.Add($desc) }

        $runBtn = New-Object System.Windows.Controls.Button
        $runBtn.Content = 'Run'; $runBtn.Padding = '10,3'; $runBtn.VerticalAlignment = 'Center'
        $runBtn.Tag = $t.id
        [System.Windows.Controls.Grid]::SetColumn($runBtn, 2)
        $runBtn.Add_Click({ param($s, $e) Queue-Run @($s.Tag) })

        $null = $grid.Children.Add($check)
        $null = $grid.Children.Add($info)
        $null = $grid.Children.Add($runBtn)
        $border.Child = $grid
        $null = $TaskList.Children.Add($border)

        $script:rows[$t.id] = @{ Status = $status; Check = $check; RunBtn = $runBtn }
    }
}

# --- Run orchestration -------------------------------------------------------
function Start-TaskRun($task) {
    $shared = [hashtable]::Synchronized(@{})
    $shared.Queue    = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
    $shared.Done     = $false
    $shared.ExitCode = $null
    $shared.Process  = $null

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($Task, $Settings, $Shared, $ModulePath, $ScriptRoot)
        Import-Module $ModulePath -Force -DisableNameChecking
        Invoke-TaskProcess -Task $Task -Settings $Settings -Shared $Shared -ScriptRoot $ScriptRoot
    }).AddArgument($task).AddArgument($script:settings).AddArgument($shared).AddArgument($script:ModulePath).AddArgument($script:ScriptRoot)

    $handle = $ps.BeginInvoke()
    $script:current = @{ Task = $task; Shared = $shared; PS = $ps; Handle = $handle; Rs = $rs }
}

function Start-NextInQueue {
    if ($script:current) { return }
    if ($script:runQueue.Count -eq 0) {
        Set-Running $false
        $StatusText.Text = 'Ready'
        return
    }
    $id = $script:runQueue[0]; $script:runQueue.RemoveAt(0)
    $task = $script:tasksById[$id]
    $Output.AppendText("`r`n===== $($task.name)  [$id] =====`r`n")
    $Output.ScrollToEnd()
    Set-RowStatus $id 'Running' $null
    $StatusText.Text = "Running: $($task.name)"
    Start-TaskRun $task
}

function Queue-Run([string[]]$ids) {
    if ($script:current -or $script:runQueue.Count -gt 0) {
        $StatusText.Text = 'A run is already in progress.'
        return
    }
    if (-not $ids -or $ids.Count -eq 0) { $StatusText.Text = 'Nothing selected.'; return }
    $Output.Clear()
    foreach ($id in $ids) { $script:runQueue.Add($id); Set-RowStatus $id 'Queued' $null }
    Set-Running $true
    Start-NextInQueue
}

# --- UI poll timer: drains output, finalizes, chains the queue ---------------
$script:timer = New-Object System.Windows.Threading.DispatcherTimer
$script:timer.Interval = [TimeSpan]::FromMilliseconds(120)
$script:timer.Add_Tick({
    $cur = $script:current
    if (-not $cur) { return }

    $line = $null
    while ($cur.Shared.Queue.TryDequeue([ref]$line)) {
        $Output.AppendText([string]$line + "`r`n")
    }
    $Output.ScrollToEnd()

    if ($cur.Shared.Done) {
        $code = $cur.Shared.ExitCode
        Set-RowStatus $cur.Task.id $(if ($code -eq 0) { 'Success' } else { 'Failed' }) $code
        try { $cur.PS.EndInvoke($cur.Handle) } catch { }
        try { $cur.PS.Dispose() } catch { }
        try { $cur.Rs.Close(); $cur.Rs.Dispose() } catch { }
        if ($cur.Shared.LogPath) { $Output.AppendText("# log: $($cur.Shared.LogPath)`r`n") }
        $script:current = $null

        if ($code -ne 0 -and $ChkStopOnFail.IsChecked -and $script:runQueue.Count -gt 0) {
            $Output.AppendText("`r`n*** Stopped: task failed (exit $code) and 'Stop on first failure' is on.`r`n")
            foreach ($qid in $script:runQueue) { Set-RowStatus $qid 'Ready' $null }
            $script:runQueue.Clear()
        }
        Start-NextInQueue
    }
})

# --- Wire toolbar ------------------------------------------------------------
$BtnRunSelected.Add_Click({
    $ids = @($script:config.tasks | Where-Object { $script:rows[$_.id].Check.IsChecked } | ForEach-Object { $_.id })
    Queue-Run $ids
})
$BtnRunAll.Add_Click({
    Queue-Run @($script:config.tasks | ForEach-Object { $_.id })
})
$BtnStop.Add_Click({
    $script:runQueue.Clear()
    if ($script:current -and $script:current.Shared.Process) {
        try { $script:current.Shared.Process.Kill() } catch { }
        $Output.AppendText("`r`n*** Stop requested.`r`n")
    }
})
$BtnReload.Add_Click({
    try {
        $script:config   = Read-Config
        $script:settings = if ($script:config.settings) { $script:config.settings } else { [pscustomobject]@{} }
        Build-Rows
        $StatusText.Text = "Reloaded $($script:config.tasks.Count) task(s)."
    } catch { $StatusText.Text = "Reload failed: $($_.Exception.Message)" }
})
$BtnOpenLogs.Add_Click({
    $d = Resolve-LogDir $script:settings $script:ScriptRoot
    Start-Process explorer.exe $d
})

# --- Go ----------------------------------------------------------------------
Build-Rows
Set-Running $false
$StatusText.Text = "Loaded $($script:config.tasks.Count) task(s) from tasks.json"
$script:timer.Start()
$window.Add_Closed({ $script:timer.Stop() })
[void]$window.ShowDialog()
