@{
    RootModule        = 'MolehillTools.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'b7f1c3de-4a2e-4e7a-9c4f-6b1d2f8a5c01'
    Author            = 'Molehill Data Services'
    CompanyName       = 'Molehill Data Services'
    Copyright         = 'Molehill Data Services'
    Description       = 'SQL Server support tools: connect screens, pickers and the tools built on them.'

    # 5.1 because everything in here is tested on it as well as on 7, and a client server is as
    # likely to have one as the other. Raise it the day we use syntax 5.1 cannot parse.
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Add-MhTuiChar',
        'Clear-MhTuiScreen',
        'ConvertTo-MhTuiKeys',
        'Copy-MhSqlAccess',
        'Export-MhDatabaseSample',
        'Get-MhPatchStatus',
        'Get-MhSqlAuthAvailability',
        'Get-MhSqlAuthMethods',
        'Get-MhSqlClientNamespace',
        'Get-MhSqlConnectExplanation',
        'Get-MhSqlConnectionString',
        'Get-MhSqlDatabaseList',
        'Get-MhSqlLicensingAudit',
        'Get-MhSqlScalar',
        'Get-MhSqlServerInfo',
        'Get-MhTuiSelectionSummary',
        'Hide-MhSqlSecret',
        'Invoke-MhSelfTest',
        'Invoke-MhSql',
        'Invoke-MhSqlConnectionTester',
        'Invoke-MhSqlQuery',
        'New-MhConnectionString',
        'New-MhSqlConnectionString',
        'New-MhSqlConnectSettings',
        'Open-MhSqlConnection',
        'Read-MhTuiKey',
        'Remove-MhTuiChar',
        'Restore-MhDatabaseCopy',
        'Restore-MhLatestAzureBackup',
        'Select-MhSqlClientNamespace',
        'Set-MhTuiKeyScript',
        'Show-MhSqlConnectDialog',
        'Show-MhTuiCheckList',
        'Show-MhTuiList',
        'Test-MhDatabaseStatus',
        'Test-MhSqlConnectionString',
        'Test-MhSqlConnectSettings',
        'Test-MhSqlTlsHandshake',
        'Write-MhTui',
        'Write-MhTuiField',
        'Write-MhTuiKeys',
        'Write-MhTuiTitle'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('SQL', 'SQLServer', 'DBA', 'Azure')
            ProjectUri = 'https://github.com/jayparry/molehill-watch'
        }
    }
}
