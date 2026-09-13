<#
.SYNOPSIS
    Molehill Admin daily run: creates due billing cycles and draft invoices, then writes the
    dashboard and every draft invoice as HTML files you can open, print to PDF and send.

.EXAMPLE
    .\Invoke-MolehillDaily.ps1 -SqlInstance .\SQLEXPRESS -OutputFolder "$env:USERPROFILE\Documents\Molehill Admin"

.EXAMPLE
    # Re-export one invoice (e.g. after an adjustment)
    .\Invoke-MolehillDaily.ps1 -SqlInstance .\SQLEXPRESS -InvoiceNo MDS-2026-0003 -NoBillingRun
#>
param(
    [Parameter(Mandatory)] [string] $SqlInstance,
    [string] $OutputFolder = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Molehill Admin'),
    [string] $InvoiceNo,
    [switch] $NoBillingRun,
    [switch] $Open
)
$ErrorActionPreference = 'Stop'

$conn = New-Object System.Data.SqlClient.SqlConnection "Data Source=$SqlInstance;Initial Catalog=MolehillAdmin;Integrated Security=True;TrustServerCertificate=True;Application Name=Molehill Admin Daily"
$conn.Open()
function Query([string]$Sql, [hashtable]$P = @{}) {
    $cmd = $conn.CreateCommand(); $cmd.CommandText = $Sql; $cmd.CommandTimeout = 600
    foreach ($k in $P.Keys) { [void]$cmd.Parameters.AddWithValue("@$k", $P[$k]) }
    $dt = New-Object System.Data.DataTable; $dt.Load($cmd.ExecuteReader()); return ,$dt
}

try {
    $invoiceDir = Join-Path $OutputFolder 'Invoices'
    New-Item -ItemType Directory -Force -Path $invoiceDir | Out-Null

    if (-not $NoBillingRun) {
        $created = Query 'EXEC dbo.usp_Daily;'
        foreach ($r in $created.Rows) { Write-Host "Draft invoice created: $($r.InvoiceNo) $($r.ClientName) GBP $($r.Total)" -ForegroundColor Cyan }
    }

    $list = if ($InvoiceNo) { Query 'SELECT InvoiceNo FROM dbo.Invoice WHERE InvoiceNo = @No;' @{ No = $InvoiceNo } }
            else { Query "SELECT InvoiceNo FROM dbo.Invoice WHERE Status = 'Draft' ORDER BY InvoiceNo;" }
    foreach ($r in $list.Rows) {
        $html = (Query 'DECLARE @h nvarchar(max); EXEC dbo.usp_Invoice_Html @InvoiceNo = @No, @Html = @h OUTPUT, @Select = 0; SELECT Html = @h;' @{ No = $r.InvoiceNo }).Rows[0].Html
        $file = Join-Path $invoiceDir "$($r.InvoiceNo).html"
        [System.IO.File]::WriteAllText($file, $html, [System.Text.Encoding]::UTF8)
        Write-Host "Invoice saved: $file"
    }

    $dash = (Query 'DECLARE @h nvarchar(max); EXEC dbo.usp_DashboardHtml @Html = @h OUTPUT, @Select = 0; SELECT Html = @h;').Rows[0].Html
    $dashFile = Join-Path $OutputFolder 'Dashboard.html'
    [System.IO.File]::WriteAllText($dashFile, $dash, [System.Text.Encoding]::UTF8)
    Write-Host "Dashboard saved: $dashFile" -ForegroundColor Green
    if ($Open) { Start-Process $dashFile }
}
catch {
    New-Item -ItemType Directory -Force -Path $OutputFolder | Out-Null
    Add-Content -Path (Join-Path $OutputFolder 'daily-errors.log') -Value "$(Get-Date -Format s) $($_.Exception.Message)"
    throw
}
finally { $conn.Close() }
