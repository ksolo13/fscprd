#Requires -Version 5.1
<#
    Hello-Task.ps1 - a zero-dependency sample task.
    Proves the dashboard streams output live and reports exit codes.
    Safe to run anywhere; touches nothing.
#>
[CmdletBinding()]
param([string]$Name = 'world')

Write-Host "Hello, $Name - from $env:COMPUTERNAME ($env:USERNAME)"
Write-Host "PowerShell $($PSVersionTable.PSVersion), started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
1..5 | ForEach-Object {
    Write-Host ("  working... step {0}/5" -f $_)
    Start-Sleep -Milliseconds 400
}
Write-Host "Done."
exit 0
