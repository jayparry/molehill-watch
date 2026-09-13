<#
.SYNOPSIS
    Runs one Molehill Watch collection. Used by Windows Task Scheduler on SQL Server
    Express, which has no SQL Agent. Install-MolehillWatch.ps1 -UseTaskScheduler sets this up.
#>
param(
    [Parameter(Mandatory)] [string] $SqlInstance,
    [Parameter(Mandatory)] [ValidateSet('Frequent', 'Hourly', 'Daily', 'Weekly')] [string] $Type
)
$conn = New-Object System.Data.SqlClient.SqlConnection "Data Source=$SqlInstance;Initial Catalog=MolehillWatch;Integrated Security=True;TrustServerCertificate=True;Application Name=Molehill Watch Collector"
try {
    $conn.Open()
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = 'EXEC dbo.usp_Collect @Type = @Type;'
    $cmd.CommandTimeout = 0
    [void]$cmd.Parameters.AddWithValue('@Type', $Type)
    [void]$cmd.ExecuteNonQuery()
}
catch {
    $log = Join-Path $env:ProgramData 'MolehillWatch\collector-errors.log'
    Add-Content -Path $log -Value "$(Get-Date -Format s) [$SqlInstance] $Type : $($_.Exception.Message)"
    exit 1
}
finally { $conn.Close() }
