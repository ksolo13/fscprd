<#
.SYNOPSIS
    Compares folder names in a root path against FICID values in an Excel worksheet
    and reports values that exist in only one place.

.DESCRIPTION
    Reads the worksheet via Excel COM (requires Excel installed). Values are trimmed
    and compared case-insensitively. Results are written to the console and to a CSV.

.EXAMPLE
    .\Compare-FicidFolders.ps1
    .\Compare-FicidFolders.ps1 -Column 2 -HasHeader:$false
#>
[CmdletBinding()]
param(
    [string]$FolderRoot = 'Z:\',
    [string]$ExcelPath  = 'C:\Users\patersk\Downloads\extract_manifest_20260924_181512.xlsx',
    [string]$SheetName  = 'Unique_FICIDs',
    [int]$Column        = 1,
    [bool]$HasHeader    = $true,
    [string]$OutputCsv  = (Join-Path $PSScriptRoot ("FICID_Compare_{0:yyyyMMdd_HHmmss}.csv" -f (Get-Date)))
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $FolderRoot)) { throw "Folder root not found: $FolderRoot" }
if (-not (Test-Path -LiteralPath $ExcelPath))  { throw "Excel file not found: $ExcelPath" }

# --- Folder names ---
$folders = Get-ChildItem -LiteralPath $FolderRoot -Directory |
    ForEach-Object { $_.Name.Trim() } |
    Where-Object { $_ } |
    Sort-Object -Unique

# --- Excel values ---
$excel = $null; $wb = $null; $ws = $null
try {
    $excel = New-Object -ComObject Excel.Application
    $excel.Visible = $false
    $excel.DisplayAlerts = $false
    $wb = $excel.Workbooks.Open($ExcelPath, 0, $true)   # read-only
    $ws = $wb.Worksheets.Item($SheetName)

    $lastRow  = $ws.Cells($ws.Rows.Count, $Column).End(-4162).Row   # xlUp
    $startRow = if ($HasHeader) { 2 } else { 1 }

    $excelValues = @()
    if ($lastRow -ge $startRow) {
        $data = $ws.Range($ws.Cells($startRow, $Column), $ws.Cells($lastRow, $Column)).Value2
        if ($data -is [array]) { $excelValues = foreach ($v in $data) { $v } } else { $excelValues = @($data) }
    }
}
finally {
    if ($wb)    { $wb.Close($false) }
    if ($excel) { $excel.Quit() }
    foreach ($o in @($ws, $wb, $excel)) {
        if ($o) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($o) }
    }
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
}

$excelValues = $excelValues |
    Where-Object { $null -ne $_ } |
    ForEach-Object { "$_".Trim() } |
    Where-Object { $_ } |
    Sort-Object -Unique

# --- Compare (case-insensitive) ---
$folderSet = [System.Collections.Generic.HashSet[string]]::new([string[]]@($folders),     [StringComparer]::OrdinalIgnoreCase)
$excelSet  = [System.Collections.Generic.HashSet[string]]::new([string[]]@($excelValues), [StringComparer]::OrdinalIgnoreCase)

$onlyInFolders = $folders     | Where-Object { -not $excelSet.Contains($_) }
$onlyInExcel   = $excelValues | Where-Object { -not $folderSet.Contains($_) }

$results = @(
    $onlyInFolders | ForEach-Object { [pscustomobject]@{ Value = $_; FoundIn = 'Folder only'; MissingFrom = 'Excel' } }
    $onlyInExcel   | ForEach-Object { [pscustomobject]@{ Value = $_; FoundIn = 'Excel only';  MissingFrom = "Folder ($FolderRoot)" } }
)

# --- Report ---
Write-Host ""
Write-Host ("Folders          : {0}" -f @($folders).Count)
Write-Host ("Excel values     : {0}" -f @($excelValues).Count)
Write-Host ("Matched          : {0}" -f (@($folders).Count - @($onlyInFolders).Count))
Write-Host ("Folder only      : {0}" -f @($onlyInFolders).Count) -ForegroundColor Yellow
Write-Host ("Excel only       : {0}" -f @($onlyInExcel).Count)   -ForegroundColor Yellow
Write-Host ""

if ($results.Count -gt 0) {
    $results | Sort-Object FoundIn, Value | Format-Table -AutoSize
    $results | Sort-Object FoundIn, Value | Export-Csv -LiteralPath $OutputCsv -NoTypeInformation
    Write-Host "Results saved to: $OutputCsv" -ForegroundColor Green
}
else {
    Write-Host "No differences found." -ForegroundColor Green
}
