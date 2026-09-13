<#
.SYNOPSIS
    Installs the Molehill Admin database (clients, agreements, tickets, time, billing) on your own SQL Server.

.DESCRIPTION
    1. runs MolehillAdmin_Install.sql (SQL Server 2017+, Express is fine)
    2. optionally sets your invoice details
    3. schedules Invoke-MolehillDaily.ps1 every morning with Windows Task Scheduler
       (billing run + dashboard and draft invoice HTML files)
    Safe to re-run.

.EXAMPLE
    .\Install-MolehillAdmin.ps1 -SqlInstance .\SQLEXPRESS

.EXAMPLE
    .\Install-MolehillAdmin.ps1 -SqlInstance localhost -BusinessAddress "1 High Street, Town, AB1 2CD" `
        -PaymentDetails "Molehill Data Services, sort code 00-00-00, account 00000000" -DailyAt 07:30
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SqlInstance,
    [string] $OutputFolder = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Molehill Admin'),
    [string] $BusinessAddress,
    [string] $PaymentDetails,
    [string] $DailyAt = '07:00',
    [switch] $NoSchedule
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

$conn = New-Object System.Data.SqlClient.SqlConnection "Data Source=$SqlInstance;Initial Catalog=master;Integrated Security=True;TrustServerCertificate=True;Application Name=Molehill Admin Installer"
$conn.add_InfoMessage({ param($s, $e) foreach ($m in $e.Errors) { if ($m.Message -notmatch 'Changed database context|depends on the missing object') { Write-Host "  $($m.Message)" -ForegroundColor DarkGray } } })
function Exec([string]$Sql, [hashtable]$P = @{}) {
    $cmd = $conn.CreateCommand(); $cmd.CommandText = $Sql; $cmd.CommandTimeout = 0
    foreach ($k in $P.Keys) { [void]$cmd.Parameters.AddWithValue("@$k", $P[$k]) }
    [void]$cmd.ExecuteNonQuery()
}

Write-Host 'Molehill Admin installer' -ForegroundColor Cyan
try {
    $conn.Open()
    Write-Host "Installing MolehillAdmin database on $SqlInstance"
    $text = [System.IO.File]::ReadAllText((Join-Path $root 'MolehillAdmin_Install.sql'))
    foreach ($batch in [regex]::Split($text, '^\s*GO\s*$', [System.Text.RegularExpressions.RegexOptions]'Multiline, IgnoreCase')) {
        if ($batch.Trim()) { Exec $batch }
    }
    if ($BusinessAddress) { Exec "UPDATE MolehillAdmin.dbo.Setting SET Value = @v WHERE Name = 'BusinessAddress';" @{ v = $BusinessAddress } }
    if ($PaymentDetails)  { Exec "UPDATE MolehillAdmin.dbo.Setting SET Value = @v WHERE Name = 'PaymentDetails';" @{ v = $PaymentDetails } }
}
catch {
    $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
    Write-Host "FAILED: $($e.Message)" -ForegroundColor Red
    exit 1
}
finally { $conn.Close() }

New-Item -ItemType Directory -Force -Path $OutputFolder | Out-Null
if (-not $NoSchedule) {
    $script = Join-Path $root 'Invoke-MolehillDaily.ps1'
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -SqlInstance `"$SqlInstance`" -OutputFolder `"$OutputFolder`""
    $trigger = New-ScheduledTaskTrigger -Daily -At $DailyAt
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries
    Register-ScheduledTask -TaskPath '\Molehill Watch\' -TaskName 'Molehill Admin - Daily' -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
    Write-Host "Scheduled daily run at $DailyAt (runs as you, catches up if the PC was off): \Molehill Watch\Molehill Admin - Daily"
}

Write-Host "Running the first daily run..."
& (Join-Path $root 'Invoke-MolehillDaily.ps1') -SqlInstance $SqlInstance -OutputFolder $OutputFolder
Write-Host ''
Write-Host 'Installed.' -ForegroundColor Green
Write-Host "Dashboard and invoices: $OutputFolder"
Write-Host 'Next: open Docs\Admin-Guide.md, or run Admin\Example-NewClient.sql in SSMS to see a worked example.'
