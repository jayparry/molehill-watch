<#
    Talking to SQL Server, once.

    This is the plumbing that had been copied into tool after tool - Invoke-Sql existed in seven
    copies, New-ConnectionString in six - and every one of them took its server, credential and
    timeout from whatever happened to be in scope. Here they are parameters, so a function can be
    read on its own and tested on its own.

    System.Data.SqlClient rather than Microsoft.Data.SqlClient: it needs nothing installed, and it
    is the only one that will talk to SQL Server 2000 or 2005. Where a caller has built a string
    for the other driver it hands the whole string over instead, and Open-MhSqlConnection uses
    whichever namespace the settings name.
#>

# identifiers and literals, quoted the long way round
function Esc-MhName { param([string] $Name) '[' + ($Name -replace '\]', ']]') + ']' }
function Esc-MhStr { param([string] $Text) $Text -replace "'", "''" }

<#
  A connection string for one server and database.

  Encrypt is left to the caller: on an old instance asking for it is what breaks the connection,
  and on a new one it is the default anyway.
#>
function New-MhConnectionString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Server,
        [string] $Database = 'master',
        [pscredential] $Credential,
        [switch] $TrustServerCertificate,
        [ValidateRange(1, 300)] [int] $TimeoutSeconds = 15,
        [string] $ApplicationName = 'MolehillTools',
        [switch] $Encrypt
    )

    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder['Data Source'] = $Server
    $builder['Initial Catalog'] = $Database
    $builder['Connect Timeout'] = $TimeoutSeconds
    $builder['Application Name'] = $ApplicationName
    if ($Encrypt) { $builder['Encrypt'] = $true }
    if ($TrustServerCertificate) { $builder['TrustServerCertificate'] = $true }
    if ($Credential) {
        $builder['User ID'] = $Credential.UserName
        $builder['Password'] = $Credential.GetNetworkCredential().Password
    }
    else { $builder['Integrated Security'] = $true }
    $builder.ConnectionString
}

<#
  Runs a query and gives back a DataTable.

  The comma on the return is not a typo: without it PowerShell unrolls the table into its rows and
  the caller loses .Rows, .Columns and the count.
#>
function Invoke-MhSql {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Server')] [string] $Server,
        [Parameter(ParameterSetName = 'Server')] [string] $Database = 'master',
        [Parameter(ParameterSetName = 'Server')] [pscredential] $Credential,
        [Parameter(ParameterSetName = 'Server')] [switch] $TrustServerCertificate,
        [Parameter(ParameterSetName = 'Server')] [ValidateRange(1, 300)] [int] $TimeoutSeconds = 15,
        [Parameter(ParameterSetName = 'Server')] [string] $ApplicationName = 'MolehillTools',
        [Parameter(ParameterSetName = 'Server')] [switch] $Encrypt,

        [Parameter(Mandatory, ParameterSetName = 'ConnectionString')] [string] $ConnectionString,

        [Parameter(Mandatory)] [string] $Query,
        [hashtable] $Parameters,
        [ValidateRange(0, 86400)] [int] $CommandTimeoutSeconds = 120
    )

    if ($PSCmdlet.ParameterSetName -eq 'Server') {
        $ConnectionString = New-MhConnectionString -Server $Server -Database $Database -Credential $Credential `
                                -TrustServerCertificate:$TrustServerCertificate -TimeoutSeconds $TimeoutSeconds `
                                -ApplicationName $ApplicationName -Encrypt:$Encrypt
    }

    $connection = New-Object System.Data.SqlClient.SqlConnection $ConnectionString
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $Query
        $command.CommandTimeout = $CommandTimeoutSeconds
        if ($Parameters) {
            foreach ($key in $Parameters.Keys) { [void]$command.Parameters.AddWithValue($key, $Parameters[$key]) }
        }
        $table = New-Object System.Data.DataTable
        [void](New-Object System.Data.SqlClient.SqlDataAdapter $command).Fill($table)
        , $table
    }
    finally { $connection.Dispose() }
}

# the first column of the first row, or nothing at all
function Get-MhSqlScalar {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Server')] [string] $Server,
        [Parameter(ParameterSetName = 'Server')] [string] $Database = 'master',
        [Parameter(ParameterSetName = 'Server')] [pscredential] $Credential,
        [Parameter(ParameterSetName = 'Server')] [switch] $TrustServerCertificate,
        [Parameter(ParameterSetName = 'Server')] [ValidateRange(1, 300)] [int] $TimeoutSeconds = 15,
        [Parameter(Mandatory, ParameterSetName = 'ConnectionString')] [string] $ConnectionString,
        [Parameter(Mandatory)] [string] $Query,
        [hashtable] $Parameters
    )

    $arguments = @{ Query = $Query }
    if ($Parameters) { $arguments['Parameters'] = $Parameters }
    if ($PSCmdlet.ParameterSetName -eq 'ConnectionString') { $arguments['ConnectionString'] = $ConnectionString }
    else {
        $arguments['Server'] = $Server
        $arguments['Database'] = $Database
        if ($Credential) { $arguments['Credential'] = $Credential }
        $arguments['TrustServerCertificate'] = $TrustServerCertificate
        $arguments['TimeoutSeconds'] = $TimeoutSeconds
    }

    $table = Invoke-MhSql @arguments
    if ($table.Rows.Count -eq 0) { return $null }
    $value = $table.Rows[0][0]
    if ($value -is [DBNull]) { return $null }
    $value
}

Register-MhSelfTest -Name 'Talking to SQL Server' -Test {
    Test-MhSection 'the connection string it builds'
    $windows = New-MhConnectionString -Server 'SQL01' -Database 'Sales'
    Test-MhCheck 'the server and database' (($windows -match 'Data Source=SQL01') -and ($windows -match 'Initial Catalog=Sales'))
    Test-MhCheck 'Windows authentication when no credential is given' ($windows -match 'Integrated Security=True')
    Test-MhCheck 'and master when no database is' ((New-MhConnectionString -Server 'SQL01') -match 'Initial Catalog=master')

    $secure = ConvertTo-SecureString 'p@ss;word' -AsPlainText -Force
    $credential = New-Object pscredential 'sa', $secure
    $sql = New-MhConnectionString -Server 'SQL01' -Credential $credential
    Test-MhCheck 'a credential becomes a user and password' (($sql -match 'User ID=sa') -and ($sql -match 'Password="p@ss;word"'))
    Test-MhCheck 'and turns integrated security off' ($sql -notmatch 'Integrated Security=True')

    Test-MhCheck 'encryption is only asked for when asked for' ((New-MhConnectionString -Server 'SQL01') -notmatch 'Encrypt=True')
    Test-MhCheck 'and is there when it is' ((New-MhConnectionString -Server 'SQL01' -Encrypt) -match 'Encrypt=True')
    Test-MhCheck 'trusting the certificate is the same' (
        ((New-MhConnectionString -Server 'SQL01') -notmatch 'TrustServerCertificate=True') -and
        ((New-MhConnectionString -Server 'SQL01' -TrustServerCertificate) -match 'TrustServerCertificate=True'))
    Test-MhCheck 'the timeout goes in' ((New-MhConnectionString -Server 'SQL01' -TimeoutSeconds 45) -match 'Connect Timeout=45')
    Test-MhCheck 'and the application name, which is what a DBA sees' (
        (New-MhConnectionString -Server 'SQL01' -ApplicationName 'Molehill Thing') -match 'Application Name="?Molehill Thing"?')

    Test-MhSection 'quoting things that would otherwise break out'
    Test-MhCheck 'a name is bracketed' ((Esc-MhName 'Orders') -eq '[Orders]')
    Test-MhCheck 'and a bracket inside it is doubled' ((Esc-MhName 'Odd]Name') -eq '[Odd]]Name]')
    Test-MhCheck 'a literal has its quotes doubled' ((Esc-MhStr "O'Brien") -eq "O''Brien")
}
