$script:AccessClassLookup = @{
    'TYPE'                       = @{ View = 'sys.types';                           Id = 'user_type_id';               Schema = $true }
    'XML_SCHEMA_COLLECTION'      = @{ View = 'sys.xml_schema_collections';          Id = 'xml_collection_id';          Schema = $true }
    'DATABASE_PRINCIPAL'         = @{ View = 'sys.database_principals';             Id = 'principal_id';               Type = $true }
    'ROLE'                       = @{ View = 'sys.database_principals';             Id = 'principal_id';               Type = $true }
    'APPLICATION_ROLE'           = @{ View = 'sys.database_principals';             Id = 'principal_id';               Type = $true }
    'ASSEMBLY'                   = @{ View = 'sys.assemblies';                      Id = 'assembly_id' }
    'CERTIFICATE'                = @{ View = 'sys.certificates';                    Id = 'certificate_id' }
    'ASYMMETRIC_KEY'             = @{ View = 'sys.asymmetric_keys';                 Id = 'asymmetric_key_id' }
    'SYMMETRIC_KEY'              = @{ View = 'sys.symmetric_keys';                  Id = 'symmetric_key_id' }
    'FULLTEXT_CATALOG'           = @{ View = 'sys.fulltext_catalogs';               Id = 'fulltext_catalog_id' }
    'FULLTEXT_STOPLIST'          = @{ View = 'sys.fulltext_stoplists';              Id = 'stoplist_id' }
    'SEARCH_PROPERTY_LIST'       = @{ View = 'sys.registered_search_property_lists'; Id = 'property_list_id' }
    'MESSAGE_TYPE'               = @{ View = 'sys.service_message_types';           Id = 'message_type_id' }
    'SERVICE_CONTRACT'           = @{ View = 'sys.service_contracts';               Id = 'service_contract_id' }
    'SERVICE'                    = @{ View = 'sys.services';                        Id = 'service_id' }
    'REMOTE_SERVICE_BINDING'     = @{ View = 'sys.remote_service_bindings';          Id = 'remote_service_binding_id' }
    'ROUTE'                      = @{ View = 'sys.routes';                          Id = 'route_id' }
    'DATABASE_SCOPED_CREDENTIAL' = @{ View = 'sys.database_scoped_credentials';      Id = 'credential_id' }
    'SERVER_PRINCIPAL'           = @{ View = 'sys.server_principals';               Id = 'principal_id';               Type = $true }
    'SERVER_ROLE'                = @{ View = 'sys.server_principals';               Id = 'principal_id';               Type = $true }
    'ENDPOINT'                   = @{ View = 'sys.endpoints';                       Id = 'endpoint_id' }
}

<#
.SYNOPSIS
    Gives one principal the same access another one has, on the same instance or a different one:
    logins, server roles and permissions, database users, roles and permissions.

.DESCRIPTION
    The question this answers is the one that actually gets asked: "give xyz on PROD the same
    access abc has on STAGING". It reads what the source principal has and writes the statements
    that reproduce it, creating the login and the users if they are not there.

    Nothing is changed until you have seen the plan. -WhatIf prints every statement and stops;
    without -Force it asks before applying, and a scheduled run with no console is told to pass
    -Force rather than failing with PowerShell's own message about it.

    It copes with what real instances look like: on-premises and Azure SQL Database and Managed
    Instance, Windows, SQL, Entra and contained users, a destination older than the source (which
    needs sp_addrolemember rather than ALTER ROLE), databases named differently at each end, and
    permissions on every securable class it has met. A class or a login type it has not met is
    reported rather than guessed at - a permission quietly dropped is the failure nobody notices
    until someone cannot work.

    What it will not do silently: copying access that amounts to control of the instance needs
    -AllowPrivileged, and copying a password or a SID needs -CopyPasswordAndSid.

.PARAMETER SourceInstance
    The instance to read from.

.PARAMETER SourcePrincipal
    The login or user whose access is being copied.

.PARAMETER DestinationInstance
    The instance to write to. The same instance is allowed, which is how you clone a principal.

.PARAMETER Principal
    The login or user to give that access to. Created if it is not there.

.PARAMETER Database
    Only these databases. Everything the source principal is a user in, by default.

.PARAMETER DatabaseMap
    Databases named differently at each end: @{ SalesStg = 'SalesProd' } or 'SalesStg=SalesProd'.

.PARAMETER Password
    The password for a SQL login this has to create.

.PARAMETER CopyPasswordAndSid
    Copy the source login's password hash and SID, so the new login is the same login as far as
    every database is concerned. Same instance only, and it needs the right to read the hash.

.PARAMETER AllowPrivileged
    Allow access that amounts to control of the instance - sysadmin, securityadmin, CONTROL
    SERVER and the rest - to be copied. Refused without it.

.PARAMETER SkipServerLevel
    Database access only: no login, no server roles, no server permissions.

.PARAMETER Force
    Do not ask before applying.

.PARAMETER ScriptPath
    Write the statements to this file instead of only printing them. The real password or hash is
    written to the file, not the masked form, so mind where it goes.

.PARAMETER SqlCredential
    SQL authentication for both ends.

.PARAMETER SourceSqlCredential
    SQL authentication for the source only.

.PARAMETER DestinationSqlCredential
    SQL authentication for the destination only.

.PARAMETER TrustServerCertificate
    Skip certificate validation, which an on-premises instance with a self-signed one needs.

.PARAMETER ConnectTimeoutSeconds
    How long to wait for each connection. Default 15.

.PARAMETER LogLevel
    Quiet, Normal, Verbose or Debug. -Verbose and -Debug raise it on their own.

.PARAMETER LogFile
    Append the run to this file as well.

.OUTPUTS
    A summary object: the two ends, how many statements were planned, applied and failed, what
    was not copied and why, the steps with their timings, and Ok.

.EXAMPLE
    Copy-MhSqlAccess -SourceInstance STG -SourcePrincipal abc -DestinationInstance PROD -Principal xyz -WhatIf

    The plan, and nothing else.

.EXAMPLE
    Copy-MhSqlAccess STG abc PROD 'CONTOSO\xyz' -Database Sales -Force

.EXAMPLE
    Copy-MhSqlAccess SQL01 AppSvc SQL01 AppSvc2 -CopyPasswordAndSid -AllowPrivileged

.NOTES
    Molehill Data Services. It reads the source and writes to the destination; the source is never
    changed.
#>

function Copy-MhSqlAccess {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Position = 0)] [string] $SourceInstance,
        [Parameter(Position = 1)] [string] $SourcePrincipal,
        [Parameter(Position = 2)] [string] $DestinationInstance,
        [Parameter(Position = 3)] [string] $Principal,

        [string[]] $Database,
        [object] $DatabaseMap,

        [System.Security.SecureString] $Password,
        [switch] $CopyPasswordAndSid,
        [switch] $AllowPrivileged,
        [switch] $SkipServerLevel,

        [switch] $Force,
        [string] $ScriptPath,

        [PSCredential] $SqlCredential,
        [PSCredential] $SourceSqlCredential,
        [PSCredential] $DestinationSqlCredential,
        [switch] $TrustServerCertificate,
        [ValidateRange(1, 300)] [int] $ConnectTimeoutSeconds = 15,

        [ValidateSet('Quiet', 'Normal', 'Verbose', 'Debug')] [string] $LogLevel = 'Normal',
        [string] $LogFile
    )

    $ErrorActionPreference = 'Stop'

    # the module's log, started for this run: -Verbose and -Debug raise the level on their own, which
    # is why it is handed $PSBoundParameters rather than being asked to work that out
    Initialize-MhLog -Level $LogLevel -LogFile $LogFile -BoundParameters $PSBoundParameters

    # Get-AccessCredentialFor and the rest run at module scope and cannot see this function's
    # parameters, so this run's settings are copied where they can see them. Unconditionally, every
    # run: anything left over from the last one would be used silently by this one.
    $script:AccessSourceInstance = $SourceInstance
    $script:AccessDestinationInstance = $DestinationInstance
    $script:AccessPrincipal = $Principal
    $script:AccessSqlCredential = $SqlCredential
    $script:AccessSourceSqlCredential = $SourceSqlCredential
    $script:AccessDestinationSqlCredential = $DestinationSqlCredential
    $script:AccessTrustServerCertificate = $TrustServerCertificate
    $script:AccessConnectTimeoutSeconds = $ConnectTimeoutSeconds
    $ErrorActionPreference = 'Stop'
    if (-not $script:AccessSourceSqlCredential) { $script:AccessSourceSqlCredential = $script:AccessSqlCredential }
    if (-not $script:AccessDestinationSqlCredential) { $script:AccessDestinationSqlCredential = $script:AccessSqlCredential }

    $LoginQuery = @"
SELECT  sp.name, sp.type, sp.type_desc, sp.is_disabled, sp.default_database_name,
        Sid = sp.sid,
        PasswordHash = CASE WHEN sp.type = 'S'
                            THEN (SELECT sl.password_hash FROM sys.sql_logins sl WHERE sl.principal_id = sp.principal_id) END
FROM sys.server_principals sp
WHERE sp.name = @p AND sp.type <> 'R';
"@
    $ServerRoleQuery = @"
SELECT RoleName = r.name
FROM sys.server_role_members m
JOIN sys.server_principals r ON r.principal_id = m.role_principal_id
JOIN sys.server_principals p ON p.principal_id = m.member_principal_id
WHERE p.name = @p
ORDER BY r.name;
"@
    $ServerPermissionQuery = @"
SELECT  StateDesc = pe.state_desc, PermissionName = pe.permission_name, ClassDesc = pe.class_desc,
        MajorId = pe.major_id, MinorId = pe.minor_id
FROM sys.server_permissions pe
JOIN sys.server_principals p ON p.principal_id = pe.grantee_principal_id
WHERE p.name = @p
ORDER BY pe.class_desc, pe.permission_name;
"@
    $DatabaseRoleQuery = @"
SELECT RoleName = r.name
FROM sys.database_role_members m
JOIN sys.database_principals r ON r.principal_id = m.role_principal_id
JOIN sys.database_principals u ON u.principal_id = m.member_principal_id
WHERE u.name = @p
ORDER BY r.name;
"@
    $DatabasePermissionQuery = @"
SELECT  StateDesc = pe.state_desc, PermissionName = pe.permission_name, ClassDesc = pe.class_desc,
        MajorId = pe.major_id, MinorId = pe.minor_id
FROM sys.database_permissions pe
JOIN sys.database_principals u ON u.principal_id = pe.grantee_principal_id
WHERE u.name = @p
ORDER BY pe.class_desc, pe.permission_name;
"@
    $OwnedQuery = @"
SELECT Kind = 'schema', ObjectName = s.name
FROM sys.schemas s JOIN sys.database_principals p ON p.principal_id = s.principal_id WHERE p.name = @p
UNION ALL
SELECT Kind = 'role', ObjectName = r.name
FROM sys.database_principals r JOIN sys.database_principals p ON p.principal_id = r.owning_principal_id
WHERE r.type = 'R' AND p.name = @p
UNION ALL
SELECT Kind = 'object', ObjectName = SCHEMA_NAME(o.schema_id) + '.' + o.name
FROM sys.objects o JOIN sys.database_principals p ON p.principal_id = o.principal_id WHERE p.name = @p;
"@
    foreach ($required in 'SourceInstance', 'SourcePrincipal') {
        if (-not (Get-Variable -Name $required -ValueOnly)) {
            Stop-AccessRun "-$required is needed. Get-Help Copy-MhSqlAccess -Detailed shows what goes with it."
        }
    }
    if (-not $script:AccessDestinationInstance) { $script:AccessDestinationInstance = $script:AccessSourceInstance }
    if (-not $script:AccessPrincipal) { $script:AccessPrincipal = $SourcePrincipal }
    $script:AccessSourceInstance = $script:AccessSourceInstance.Trim()
    $script:AccessDestinationInstance = $script:AccessDestinationInstance.Trim()
    $SourcePrincipal = $SourcePrincipal.Trim()
    $script:AccessPrincipal = $script:AccessPrincipal.Trim()
    if ($script:AccessSourceInstance -eq $script:AccessDestinationInstance -and $SourcePrincipal -eq $script:AccessPrincipal) {
        Stop-AccessRun 'The source and the target are the same principal on the same instance, so there is nothing to copy.'
    }
    if ($CopyPasswordAndSid -and $SourcePrincipal -ne $script:AccessPrincipal) {
        Stop-AccessRun ('-CopyPasswordAndSid reproduces one principal on another instance, so it cannot be used when the names differ. ' +
                        'A SID identifies a single principal; giving it to a second one would make them the same account.')
    }
    if ($CopyPasswordAndSid -and $script:AccessSourceInstance -eq $script:AccessDestinationInstance) {
        Stop-AccessRun '-CopyPasswordAndSid is for copying to another instance; that SID is already taken on this one.'
    }
    $databaseFilter = @($Database | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    if ($databaseFilter.Count -eq 1 -and $databaseFilter[0] -match ',') {
        # powershell.exe -File hands a comma-separated list over as one string
        $databaseFilter = @($databaseFilter[0] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    $dryRun = ($WhatIfPreference -eq $true)
    $runStart = Get-Date
    $script:AccessPlan = New-Object System.Collections.Generic.List[object]      # Database, Statement, Note, Privileged
    $script:AccessSkipped = New-Object System.Collections.Generic.List[object]
    $owned = New-Object System.Collections.Generic.List[object]
    $setupDone = $false
    $applied = 0
    $failed = 0
    try {
        Write-MhLog ('Copy the access of {0} on {1} to {2} on {3}' -f $SourcePrincipal, $script:AccessSourceInstance, $script:AccessPrincipal, $script:AccessDestinationInstance)
        Write-MhDetail "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)) as $([Environment]::UserDomainName)\$([Environment]::UserName); log level $LogLevel"
        if ($dryRun) { Write-MhLog 'WhatIf: the plan is printed and nothing is changed.' -Level WARN }

        #region Both ends
        Start-MhStep 'Check both instances'
        $sourceCheck = Test-MhSqlConnectivity -Instance $script:AccessSourceInstance -Credential $script:AccessSourceSqlCredential `
                                            -Trust:$script:AccessTrustServerCertificate -TimeoutSeconds $script:AccessConnectTimeoutSeconds
        Write-MhConnectivityReport -Result $sourceCheck -Role 'source'
        $destinationCheck = Test-MhSqlConnectivity -Instance $script:AccessDestinationInstance -Credential $script:AccessDestinationSqlCredential `
                                                 -Trust:$script:AccessTrustServerCertificate -TimeoutSeconds $script:AccessConnectTimeoutSeconds
        Write-MhConnectivityReport -Result $destinationCheck -Role 'destination'
        if (-not $sourceCheck.Connected -or -not $destinationCheck.Connected) {
            $which = @()
            if (-not $sourceCheck.Connected) { $which += "source $script:AccessSourceInstance" }
            if (-not $destinationCheck.Connected) { $which += "destination $script:AccessDestinationInstance" }
            throw ('cannot connect to ' + ($which -join ' and ') + '. The checks above say why.')
        }

        $facts = "SELECT EngineEdition = CONVERT(int, SERVERPROPERTY('EngineEdition')), " +
                 "MajorVersion = CONVERT(int, PARSENAME(CONVERT(nvarchar(128), SERVERPROPERTY('ProductVersion')), 4)), " +
                 "ProductVersion = CONVERT(nvarchar(128), SERVERPROPERTY('ProductVersion'))"
        $srcFacts = (Invoke-AccessSql -Server $script:AccessSourceInstance -Query $facts).Rows[0]
        $dstFacts = (Invoke-AccessSql -Server $script:AccessDestinationInstance -Query $facts).Rows[0]
        $srcEdition = [int]$srcFacts['EngineEdition']
        $dstEdition = [int]$dstFacts['EngineEdition']
        $srcMajor = [int]$srcFacts['MajorVersion']
        $dstMajor = [int]$dstFacts['MajorVersion']
        $srcIsAzureDb = ($srcEdition -in 5, 6, 9, 11)
        $dstIsAzureDb = ($dstEdition -in 5, 6, 9, 11)
        $hasServerLevel = (-not $srcIsAzureDb) -and (-not $dstIsAzureDb) -and (-not $SkipServerLevel)

        Write-MhLog ('Source:      {0}, {1} ({2})' -f $script:AccessSourceInstance, (Get-AccessEditionName $srcEdition), [string]$srcFacts['ProductVersion'])
        Write-MhLog ('Destination: {0}, {1} ({2})' -f $script:AccessDestinationInstance, (Get-AccessEditionName $dstEdition), [string]$dstFacts['ProductVersion'])
        if (($srcIsAzureDb -or $dstIsAzureDb) -and -not $SkipServerLevel) {
            Write-MhLog 'Azure SQL Database has no server level, so logins, server roles and server permissions are not part of this copy. Its principals live in the databases, and master is one of them.' -Level WARN
        }
        elseif ($SkipServerLevel) { Write-MhDetail '  -SkipServerLevel: database access only' }
        if ($dstMajor -gt 0 -and $dstMajor -lt 11) {
            Write-MhLog 'The destination is older than SQL Server 2012, so role memberships are added with the stored procedures rather than ALTER ROLE.' -Level WARN
        }
        Complete-MhStep
        #endregion

        #region Which databases
        Start-MhStep 'Find the databases the principal is in'
        if ($srcIsAzureDb -and $databaseFilter.Count) { $sourceDatabases = @($databaseFilter) }
        else {
            $query = if ($srcIsAzureDb) { 'SELECT name FROM sys.databases ORDER BY name' }
                     else { "SELECT name FROM sys.databases WHERE state_desc = 'ONLINE' AND (database_id = 1 OR database_id > 4) ORDER BY name" }
            $sourceDatabases = @((Invoke-AccessSql -Server $script:AccessSourceInstance -Query $query).Rows | ForEach-Object { [string]$_['name'] })
        }
        if ($databaseFilter.Count) {
            $wanted = $databaseFilter
            $missing = @($wanted | Where-Object { $sourceDatabases -notcontains $_ })
            $sourceDatabases = @($sourceDatabases | Where-Object { $wanted -contains $_ })
            foreach ($m in $missing) { Add-AccessSkip $m 'the whole database' 'not found on the source, or not online' }
        }
        Write-MhDetail ('  looking in: ' + ($sourceDatabases -join ', '))

        $userQuery = Get-AccessUserQuery $srcMajor
        $inDatabases = New-Object System.Collections.Generic.List[object]
        foreach ($db in $sourceDatabases) {
            try {
                $user = Invoke-AccessSql -Server $script:AccessSourceInstance -DatabaseName $db -Query $userQuery -Parameters @{ '@p' = $SourcePrincipal }
                if ($user.Rows.Count) { $inDatabases.Add([pscustomobject]@{ Database = $db; User = $user.Rows[0] }) }
            }
            catch { Add-AccessSkip $db 'reading the user' (Get-AccessFirstLine $_.Exception.GetBaseException().Message) }
        }
        Write-MhLog ('{0} is a user in {1} database(s){2}' -f $SourcePrincipal, $inDatabases.Count,
                   $(if ($inDatabases.Count) { ': ' + (@($inDatabases | ForEach-Object { $_.Database }) -join ', ') } else { '' }))
        Complete-MhStep
        #endregion

        #region The server level
        $sourceLogin = $null
        if ($hasServerLevel) {
            Start-MhStep 'Read the login and its server-level access'
            $loginRows = Invoke-AccessSql -Server $script:AccessSourceInstance -Query $LoginQuery -Parameters @{ '@p' = $SourcePrincipal }
            if ($loginRows.Rows.Count -eq 0) {
                # a role name gets here too, and "there is no login" would be a misleading way to say so
                $asRole = Get-AccessScalar -Server $script:AccessSourceInstance -Parameters @{ '@p' = $SourcePrincipal } -Query `
                          "SELECT name FROM sys.server_principals WHERE name = @p AND type = 'R'"
                if ($asRole) { Write-MhLog ("'{0}' is a server role on the source, not a login." -f $SourcePrincipal) -Level WARN }
                else { Write-MhLog ("There is no login called '{0}' on the source, so this is a database user only." -f $SourcePrincipal) }
                Complete-MhStep -Result 'SKIPPED'
            }
            else {
                $sourceLogin = $loginRows.Rows[0]
                Write-MhLog ('The source login is a {0}{1}' -f [string]$sourceLogin['type_desc'],
                           $(if ([bool]$sourceLogin['is_disabled']) { ', disabled' } else { '' }))

                $already = Get-AccessScalar -Server $script:AccessDestinationInstance -Query 'SELECT name FROM sys.server_principals WHERE name = @p' `
                                      -Parameters @{ '@p' = $script:AccessPrincipal }
                if ($already) { Write-MhLog ("The login '{0}' is already on the destination, so it is left as it is." -f $script:AccessPrincipal) }
                else {
                    $passwordLiteral = ''
                    $sid = ''
                    $hashed = $false
                    if ([string]$sourceLogin['type'] -eq 'S') {
                        if ($CopyPasswordAndSid) {
                            $passwordLiteral = ConvertTo-AccessHexLiteral $sourceLogin['PasswordHash']
                            $sid = ConvertTo-AccessHexLiteral $sourceLogin['Sid']
                            $hashed = $true
                            if (-not $passwordLiteral) {
                                Add-AccessSkip 'server' ('login ' + $script:AccessPrincipal) 'the password hash could not be read, which needs CONTROL SERVER or VIEW DEFINITION on the login'
                            }
                        }
                        elseif ($Password) { $passwordLiteral = ConvertTo-AccessPasswordLiteral $Password }
                    }
                    # the source's default database is mapped like any other, and dropped if it is not
                    # there: a login created with a DEFAULT_DATABASE that does not exist simply fails,
                    # and then so does everything that needed it
                    $defaultDb = [string]$sourceLogin['default_database_name']
                    if ($defaultDb) {
                        $mapped = Resolve-AccessDatabaseName -Name $defaultDb -Map $DatabaseMap
                        $onDestination = Get-AccessScalar -Server $script:AccessDestinationInstance -Parameters @{ '@p' = $mapped } `
                                                    -Query 'SELECT name FROM sys.databases WHERE name = @p'
                        if ($onDestination) { $defaultDb = $mapped }
                        else {
                            Write-MhLog ("The source login's default database '{0}' is not on the destination, so the login is created with master as its default instead." -f $defaultDb) -Level WARN
                            $defaultDb = ''
                        }
                    }
                    $statement = New-AccessPrincipalStatement -Name $script:AccessPrincipal -Scope Login -TypeDesc ([string]$sourceLogin['type_desc']) `
                                    -DefaultDatabase $defaultDb `
                                    -PasswordLiteral $passwordLiteral -Sid $sid -Hashed:$hashed -AzureSqlDatabase:$dstIsAzureDb
                    if ($statement) {
                        Add-AccessPlan 'master' $statement ('create the login (' + [string]$sourceLogin['type_desc'] + ')') $false 'Login'
                        if ([bool]$sourceLogin['is_disabled']) {
                            Add-AccessPlan 'master' ('ALTER LOGIN ' + (Esc-MhName $script:AccessPrincipal) + ' DISABLE;') 'the source login is disabled, so this one is too'
                        }
                    }
                    else {
                        Add-AccessSkip 'server' ('login ' + $script:AccessPrincipal) 'a SQL login needs a password: pass -Password, or -CopyPasswordAndSid to clone the same name onto another instance'
                    }
                }

                $destinationRoles = @((Invoke-AccessSql -Server $script:AccessDestinationInstance -Query `
                                      "SELECT name FROM sys.server_principals WHERE type = 'R'").Rows | ForEach-Object { [string]$_['name'] })
                $destinationMemberOf = @((Invoke-AccessSql -Server $script:AccessDestinationInstance -Query $ServerRoleQuery -Parameters @{ '@p' = $script:AccessPrincipal }).Rows |
                                         ForEach-Object { [string]$_['RoleName'] })
                foreach ($row in (Invoke-AccessSql -Server $script:AccessSourceInstance -Query $ServerRoleQuery -Parameters @{ '@p' = $SourcePrincipal }).Rows) {
                    $role = [string]$row['RoleName']
                    $privileged = Test-AccessPrivilegedGrant -RoleName $role
                    if ($privileged -and -not $AllowPrivileged) {
                        Add-AccessSkip 'server' ('server role ' + $role) 'this is control of the instance: pass -AllowPrivileged to copy it'
                        continue
                    }
                    if ($destinationMemberOf -contains $role) { Write-MhDetail "  already in the server role $role"; continue }
                    if ($destinationRoles -notcontains $role) {
                        Add-AccessSkip 'server' ('server role ' + $role) 'there is no server role of that name on the destination'
                        continue
                    }
                    Add-AccessPlan 'master' (New-AccessRoleMemberStatement -RoleName $role -MemberName $script:AccessPrincipal -Scope Server -MajorVersion $dstMajor) `
                             ('server role ' + $role) $privileged
                }

                $have = if ($already) { Get-AccessExistingGrants -Query $ServerPermissionQuery } else { @{} }
                $serverRows = @((Invoke-AccessSql -Server $script:AccessSourceInstance -Query $ServerPermissionQuery -Parameters @{ '@p' = $SourcePrincipal }).Rows)
                foreach ($row in (Resolve-AccessPermissionTargets -Server $script:AccessSourceInstance -Rows $serverRows)) {
                    $privileged = Test-AccessPrivilegedGrant -PermissionName $row.PermissionName
                    if ($privileged -and -not $AllowPrivileged) {
                        Add-AccessSkip 'server' ($row.PermissionName + ' on the server') 'this is control of the instance: pass -AllowPrivileged to copy it'
                        continue
                    }
                    $statement = if ($row.Resolvable) { New-AccessPermissionStatement -Row $row -ToPrincipal $script:AccessPrincipal } else { $null }
                    if ($statement -and $have.ContainsKey($statement)) { Write-MhDetail ('  already has ' + $statement); continue }
                    if ($statement) { Add-AccessPlan 'master' $statement ('server permission ' + $row.PermissionName) $privileged }
                    else {
                        Add-AccessSkip 'server' ('{0} on {1}' -f $row.PermissionName, $row.ClassDesc) `
                                 'the thing it is granted on could not be named, so it is left out rather than guessed at'
                    }
                }
                Complete-MhStep
            }
        }
        #endregion

        #region Each database
        foreach ($entry in $inDatabases) {
            $sourceDb = $entry.Database
            $targetDb = Resolve-AccessDatabaseName -Name $sourceDb -Map $DatabaseMap
            $script:StepPrefix = $targetDb
            Start-MhStep 'Read and plan the database access'
            if ($targetDb -ne $sourceDb) { Write-MhLog ('mapped from {0}' -f $sourceDb) }

            $existing = $null
            try {
                $existing = Invoke-AccessSql -Server $script:AccessDestinationInstance -DatabaseName $targetDb -Parameters @{ '@p' = $script:AccessPrincipal } `
                                       -Query 'SELECT name FROM sys.database_principals WHERE name = @p'
            }
            catch {
                Add-AccessSkip $targetDb 'the whole database' ('cannot be opened on the destination: ' + (Get-AccessFirstLine $_.Exception.GetBaseException().Message))
                Complete-MhStep -Result 'FAILED'
                $script:StepPrefix = ''
                continue
            }

            $user = $entry.User
            if ($existing.Rows.Count) { Write-MhDetail ('  the user is already in {0}, so it is left as it is' -f $targetDb) }
            else {
                $forLogin = ''
                $authType = [string]$user['AuthType']
                if ([bool]$user['HasSid'] -and $authType -notin 'DATABASE', 'NONE', 'EXTERNAL' -and -not $dstIsAzureDb) { $forLogin = $script:AccessPrincipal }
                $passwordLiteral = if ($Password) { ConvertTo-AccessPasswordLiteral $Password } else { '' }
                $statement = New-AccessPrincipalStatement -Name $script:AccessPrincipal -Scope User -TypeDesc ([string]$user['type_desc']) `
                                -DefaultSchema ([string]$user['default_schema_name']) -ForLogin $forLogin `
                                -PasswordLiteral $passwordLiteral -AuthType $authType -AzureSqlDatabase:$dstIsAzureDb
                if ($statement) { Add-AccessPlan $targetDb $statement ('create the user (' + [string]$user['type_desc'] + ', ' + $authType + ')') $false 'User' }
                else {
                    $why = if ([string]$user['type_desc'] -like '*MAPPED*') {
                               'a user mapped to a certificate or an asymmetric key has to be created against that certificate or key, which is not something this copies'
                           }
                           else { 'this user has its own password rather than a login behind it, so it needs one here too: pass -Password' }
                    Add-AccessSkip $targetDb ('user ' + $script:AccessPrincipal) $why
                }
            }

            $destinationRoles = @((Invoke-AccessSql -Server $script:AccessDestinationInstance -DatabaseName $targetDb -Query `
                                  "SELECT name FROM sys.database_principals WHERE type = 'R'").Rows | ForEach-Object { [string]$_['name'] })
            $destinationMemberOf = @((Invoke-AccessSql -Server $script:AccessDestinationInstance -DatabaseName $targetDb -Query $DatabaseRoleQuery `
                                     -Parameters @{ '@p' = $script:AccessPrincipal }).Rows | ForEach-Object { [string]$_['RoleName'] })
            foreach ($row in (Invoke-AccessSql -Server $script:AccessSourceInstance -DatabaseName $sourceDb -Query $DatabaseRoleQuery -Parameters @{ '@p' = $SourcePrincipal }).Rows) {
                $role = [string]$row['RoleName']
                $privileged = Test-AccessPrivilegedGrant -RoleName $role
                if ($privileged -and -not $AllowPrivileged) {
                    Add-AccessSkip $targetDb ('database role ' + $role) 'this is control of the instance: pass -AllowPrivileged to copy it'
                    continue
                }
                if ($destinationMemberOf -contains $role) { Write-MhDetail "  already in the role $role"; continue }
                if ($destinationRoles -notcontains $role) {
                    Add-AccessSkip $targetDb ('database role ' + $role) ('there is no role of that name in ' + $targetDb + ' on the destination')
                    continue
                }
                Add-AccessPlan $targetDb (New-AccessRoleMemberStatement -RoleName $role -MemberName $script:AccessPrincipal -Scope Database -MajorVersion $dstMajor) `
                         ('role ' + $role) $privileged
            }

            $have = if ($existing.Rows.Count) { Get-AccessExistingGrants -Query $DatabasePermissionQuery -DatabaseName $targetDb } else { @{} }
            $permissionRows = @((Invoke-AccessSql -Server $script:AccessSourceInstance -DatabaseName $sourceDb -Query $DatabasePermissionQuery `
                                -Parameters @{ '@p' = $SourcePrincipal }).Rows)
            foreach ($row in (Resolve-AccessPermissionTargets -Server $script:AccessSourceInstance -DatabaseName $sourceDb -Rows $permissionRows)) {
                $privileged = Test-AccessPrivilegedGrant -PermissionName $row.PermissionName
                if ($privileged -and -not $AllowPrivileged) {
                    Add-AccessSkip $targetDb ($row.PermissionName + ' in ' + $targetDb) 'this is control of the instance: pass -AllowPrivileged to copy it'
                    continue
                }
                $statement = if ($row.Resolvable) { New-AccessPermissionStatement -Row $row -ToPrincipal $script:AccessPrincipal } else { $null }
                if ($statement -and $have.ContainsKey($statement)) { Write-MhDetail ('  already has ' + $statement); continue }
                if ($statement) {
                    $on = if ($row.ObjectName) { $row.ObjectName } else { 'the database' }
                    Add-AccessPlan $targetDb $statement ('{0} on {1}' -f $row.PermissionName, $on) $privileged
                }
                else {
                    Add-AccessSkip $targetDb ('{0} on {1}' -f $row.PermissionName, $row.ClassDesc) `
                             'the thing it is granted on could not be named, so it is left out rather than guessed at'
                }
            }

            foreach ($row in (Invoke-AccessSql -Server $script:AccessSourceInstance -DatabaseName $sourceDb -Query $OwnedQuery -Parameters @{ '@p' = $SourcePrincipal }).Rows) {
                $owned.Add([pscustomobject]@{ Database = $sourceDb; Kind = [string]$row['Kind']; Name = [string]$row['ObjectName'] })
            }
            Complete-MhStep
            $script:StepPrefix = ''
        }
        #endregion

        if ($inDatabases.Count -eq 0 -and -not $sourceLogin) {
            $isRole = Get-AccessScalar -Server $script:AccessSourceInstance -Parameters @{ '@p' = $SourcePrincipal } -Query `
                      "SELECT name FROM sys.server_principals WHERE name = @p AND type = 'R'"
            if ($isRole) {
                Write-MhLog ("'{0}' is a server role, not a login or a user. This copies what a principal has, so name one of its members instead." -f $SourcePrincipal) -Level WARN
            }
            else {
                Write-MhLog ("Nothing found for '{0}' on {1}. Check the spelling, including the domain part, and that you can see it: the catalogue views show you only what your own permissions allow." -f $SourcePrincipal, $script:AccessSourceInstance) -Level WARN
            }
        }
        $setupDone = $true

        #region The plan
        Write-Host ''
        Write-MhLog ('---- the plan: {0} statement(s) ----' -f $script:AccessPlan.Count) -Min Quiet
        foreach ($group in (Get-AccessPlanGroups)) {
            Write-MhLog ('  in {0}:' -f $group.Name) -Min Quiet
            foreach ($item in $group.Group) {
                Write-MhLog ('    ' + (Hide-AccessSecret $item.Statement) + $(if ($item.Privileged) { '    -- privileged' } else { '' })) -Min Quiet
            }
        }
        if ($script:AccessPlan.Count -eq 0) {
            Write-MhLog '  nothing to do: either there is no access to copy, or the target already has all of it' -Min Quiet
        }

        if ($script:AccessSkipped.Count) {
            Write-Host ''
            Write-MhLog ('---- not copied ({0}) ----' -f $script:AccessSkipped.Count) -Level WARN
            foreach ($item in $script:AccessSkipped) { Write-MhLog ('  {0}: {1} - {2}' -f $item.Where, $item.What, $item.Why) -Level WARN }
        }
        if ($owned.Count) {
            Write-Host ''
            Write-MhLog ('---- owned by {0}, which is not copied ----' -f $SourcePrincipal)
            foreach ($item in $owned) { Write-MhLog ('  {0}: {1} {2}' -f $item.Database, $item.Kind, $item.Name) }
            Write-MhLog '  ownership is a decision rather than an access right, so it is left alone. Move it with ALTER AUTHORIZATION if that is what you want.'
        }

        if ($ScriptPath) {
            $lines = New-Object System.Collections.Generic.List[string]
            $lines.Add('-- The access of ' + $SourcePrincipal + ' on ' + $script:AccessSourceInstance)
            $lines.Add('-- copied to ' + $script:AccessPrincipal + ' on ' + $script:AccessDestinationInstance)
            $lines.Add('-- written ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' by Copy-SqlAccess.ps1')
            foreach ($group in (Get-AccessPlanGroups)) {
                $lines.Add('')
                $lines.Add('USE ' + (Esc-MhName $group.Name) + ';')
                $lines.Add('GO')
                foreach ($item in $group.Group) { $lines.Add($item.Statement) }
            }
            if ($script:AccessSkipped.Count) {
                $lines.Add('')
                foreach ($item in $script:AccessSkipped) { $lines.Add('-- NOT COPIED: ' + $item.Where + ': ' + $item.What + ' - ' + $item.Why) }
            }
            [System.IO.File]::WriteAllLines($ScriptPath, $lines.ToArray())
            Write-Host ''
            Write-MhLog "Script written to $ScriptPath"
            if (@($script:AccessPlan | Where-Object { $_.Statement -match '(?i)PASSWORD\s*=' }).Count) {
                Write-MhLog '  that file contains the password, because it has to be able to run. It is not in this log, and it should not stay on disk.' -Level WARN
            }
        }
        #endregion

        #region Do it
        if ($script:AccessPlan.Count -and -not $dryRun) {
            $privilegedCount = @($script:AccessPlan | Where-Object { $_.Privileged }).Count
            $ask = 'Apply {0} statement(s) to {1}, giving {2} the access {3} has on {4}?' -f `
                   $script:AccessPlan.Count, $script:AccessDestinationInstance, $script:AccessPrincipal, $SourcePrincipal, $script:AccessSourceInstance
            if ($privilegedCount) { $ask += ' {0} of them amount to control of the instance.' -f $privilegedCount }
            Write-Host ''
            if (-not (Confirm-MhAction -Message $ask -Caption 'Copy access' -Cmdlet $PSCmdlet -Force:$Force -DryRun:$dryRun)) { throw 'nothing was applied' }

            # If the principal itself cannot be created there is no point issuing everything that would
            # be granted to it: twenty-five copies of "the user does not exist" bury the one error that
            # actually explains it.
            $abandoned = ''
            foreach ($group in (Get-AccessPlanGroups)) {
                $script:StepPrefix = $group.Name
                Start-MhStep 'Apply'
                $failedHere = 0
                $stopHere = ''
                foreach ($item in $group.Group) {
                    if ($abandoned -or $stopHere) {
                        Add-AccessSkip $group.Name $item.Note ('not attempted: ' + $(if ($stopHere) { $stopHere } else { $abandoned }))
                        continue
                    }
                    try {
                        [void](Invoke-AccessSql -Server $script:AccessDestinationInstance -DatabaseName $group.Name -Query $item.Statement)
                        $applied++
                        Write-MhDetail ('  ok: ' + (Hide-AccessSecret $item.Statement))
                    }
                    catch {
                        $failed++
                        $failedHere++
                        $message = Get-AccessFirstLine $_.Exception.GetBaseException().Message
                        Write-MhLog ('failed: ' + (Hide-AccessSecret $item.Statement)) -Level ERROR
                        Write-MhLog ('  ' + $message) -Level ERROR
                        Add-AccessSkip $group.Name $item.Note $message
                        if ($item.Kind -eq 'Login') {
                            $abandoned = 'the login could not be created'
                            Write-MhLog 'The login could not be created, so nothing that depends on it is attempted. Fix the error above and run this again; what did apply is left as it is.' -Level ERROR
                        }
                        elseif ($item.Kind -eq 'User') {
                            $stopHere = 'the user could not be created in ' + $group.Name
                            Write-MhLog ('The user could not be created in {0}, so the rest of that database is left alone.' -f $group.Name) -Level ERROR
                        }
                    }
                }
                Complete-MhStep -Result $(if ($failedHere) { 'FAILED' } elseif ($abandoned -or $stopHere) { 'SKIPPED' } else { 'OK' })
                $script:StepPrefix = ''
            }
        }
        #endregion
    }
    catch {
        if ($script:CurrentStep) { Complete-MhStep -Result 'FAILED' }
        $exception = $_.Exception.GetBaseException()
        Write-MhLog (Get-AccessFirstLine $exception.Message) -Level ERROR
        if ($exception -is [System.Data.SqlClient.SqlException]) {
            $explain = Get-MhSqlErrorExplanation -Number $exception.Number -Message $exception.Message
            if ($explain.Meaning) { Write-MhLog ('  what it means: ' + $explain.Meaning) -Level ERROR }
            if ($explain.Fix) { Write-MhLog ('  what to try: ' + $explain.Fix) -Level WARN }
        }
        Write-MhDeep ('full exception: ' + $exception.ToString())
        if ($_.ScriptStackTrace) { Write-MhDeep ('at: ' + $_.ScriptStackTrace) }
        $failed++
    }
    finally {
        $elapsed = (Get-Date) - $runStart
        Write-Host ''
        Write-MhLog '---------------- Run summary ----------------' -Min Quiet
        Write-MhLog ('From:         {0} on {1}' -f $SourcePrincipal, $script:AccessSourceInstance) -Min Quiet
        Write-MhLog ('To:           {0} on {1}' -f $script:AccessPrincipal, $script:AccessDestinationInstance) -Min Quiet
        Write-MhLog ('Planned:      {0} statement(s) across {1} database(s)' -f $script:AccessPlan.Count, @(Get-AccessPlanGroups).Count) -Min Quiet
        if (-not $dryRun) { Write-MhLog ('Applied:      {0}, failed {1}' -f $applied, $failed) -Min Quiet }
        if ($script:AccessSkipped.Count) { Write-MhLog ('Not copied:   {0} - listed above' -f $script:AccessSkipped.Count) -Level WARN -Min Quiet }
        foreach ($step in (Get-MhLogStep)) { Write-MhLog ('  {0,-8} {1,8} s  {2}' -f $step.Result, $step.Seconds, $step.Step) }
        $overall = if (-not $setupDone) { 'FAILED BEFORE STARTING' }
                   elseif ($dryRun) { 'PLAN ONLY' }
                   elseif ($failed -gt 0) { 'PARTLY DONE' }
                   elseif ($applied -gt 0) { 'DONE' }
                   else { 'NOTHING TO DO' }
        $broke = (-not $setupDone) -or ($failed -gt 0)
        $bad = $broke -or ($script:AccessSkipped.Count -gt 0)
        Write-MhLog ('Result:       {0} in {1:hh\:mm\:ss}' -f $overall, $elapsed) `
                  -Level $(if ($broke) { 'ERROR' } elseif ($bad) { 'WARN' } else { 'INFO' }) -Min Quiet
        if ($LogFile) { Write-MhLog "Log file:     $LogFile" -Min Quiet }
    }
    # the shim turns this into an exit code; a caller gets the whole run back
    [pscustomobject]@{
        SourceInstance      = $SourceInstance
        SourcePrincipal     = $SourcePrincipal
        DestinationInstance = $DestinationInstance
        Principal           = $Principal
        Planned             = $script:AccessPlan.Count
        Applied             = $applied
        Failed              = $failed
        NotCopied           = $script:AccessSkipped.ToArray()   # @() on a generic list throws
        Steps               = @(Get-MhLogStep)
        Result              = $overall
        DryRun              = [bool]$dryRun
        Elapsed             = $elapsed
        Ok                  = -not $bad
    }
}

function Get-AccessCredentialFor([string] $Server) {
    if ($Server -eq $script:AccessDestinationInstance) { return $script:AccessDestinationSqlCredential }
    if ($Server -eq $script:AccessSourceInstance) { return $script:AccessSourceSqlCredential }
    $script:AccessSqlCredential
}

function Get-AccessSecurableClause {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ClassDesc,
        [AllowEmptyString()] [string] $SchemaName,
        [AllowEmptyString()] [string] $ObjectName,
        [AllowEmptyString()] [string] $ColumnName,
        [AllowEmptyString()] [string] $SubType
    )

    $two = {
        if ($SchemaName) { (Esc-MhName $SchemaName) + '.' + (Esc-MhName $ObjectName) } else { Esc-MhName $ObjectName }
    }

    switch ($ClassDesc.ToUpperInvariant()) {
        'DATABASE'  { return '' }            # GRANT CONNECT TO [x] - no ON clause at all
        'SERVER'    { return '' }
        'OBJECT_OR_COLUMN' {
            if (-not $ObjectName) { return $null }
            $clause = 'ON ' + (& $two)
            if ($ColumnName) { $clause += '(' + (Esc-MhName $ColumnName) + ')' }
            return $clause
        }
        'SCHEMA'                  { if ($ObjectName) { return 'ON SCHEMA::' + (Esc-MhName $ObjectName) } return $null }
        'TYPE'                    { if ($ObjectName) { return 'ON TYPE::' + (& $two) } return $null }
        'XML_SCHEMA_COLLECTION'   { if ($ObjectName) { return 'ON XML SCHEMA COLLECTION::' + (& $two) } return $null }
        'DATABASE_PRINCIPAL' {
            # the one class that needs to know what kind of principal it found
            if (-not $ObjectName) { return $null }
            $kind = switch ($SubType.ToUpperInvariant()) {
                'R' { 'ROLE::' ; break }
                'A' { 'APPLICATION ROLE::' ; break }
                default { 'USER::' }
            }
            return 'ON ' + $kind + (Esc-MhName $ObjectName)
        }
        'ROLE'                    { if ($ObjectName) { return 'ON ROLE::' + (Esc-MhName $ObjectName) } return $null }
        'APPLICATION_ROLE'        { if ($ObjectName) { return 'ON APPLICATION ROLE::' + (Esc-MhName $ObjectName) } return $null }
        'ASSEMBLY'                { if ($ObjectName) { return 'ON ASSEMBLY::' + (Esc-MhName $ObjectName) } return $null }
        'CERTIFICATE'             { if ($ObjectName) { return 'ON CERTIFICATE::' + (Esc-MhName $ObjectName) } return $null }
        'ASYMMETRIC_KEY'          { if ($ObjectName) { return 'ON ASYMMETRIC KEY::' + (Esc-MhName $ObjectName) } return $null }
        'SYMMETRIC_KEY'           { if ($ObjectName) { return 'ON SYMMETRIC KEY::' + (Esc-MhName $ObjectName) } return $null }
        'FULLTEXT_CATALOG'        { if ($ObjectName) { return 'ON FULLTEXT CATALOG::' + (Esc-MhName $ObjectName) } return $null }
        'FULLTEXT_STOPLIST'       { if ($ObjectName) { return 'ON FULLTEXT STOPLIST::' + (Esc-MhName $ObjectName) } return $null }
        'SEARCH_PROPERTY_LIST'    { if ($ObjectName) { return 'ON SEARCH PROPERTY LIST::' + (Esc-MhName $ObjectName) } return $null }
        'MESSAGE_TYPE'            { if ($ObjectName) { return 'ON MESSAGE TYPE::' + (Esc-MhName $ObjectName) } return $null }
        'SERVICE_CONTRACT'        { if ($ObjectName) { return 'ON CONTRACT::' + (Esc-MhName $ObjectName) } return $null }
        'SERVICE'                 { if ($ObjectName) { return 'ON SERVICE::' + (Esc-MhName $ObjectName) } return $null }
        'REMOTE_SERVICE_BINDING'  { if ($ObjectName) { return 'ON REMOTE SERVICE BINDING::' + (Esc-MhName $ObjectName) } return $null }
        'ROUTE'                   { if ($ObjectName) { return 'ON ROUTE::' + (Esc-MhName $ObjectName) } return $null }
        'DATABASE_SCOPED_CREDENTIAL' { if ($ObjectName) { return 'ON DATABASE SCOPED CREDENTIAL::' + (Esc-MhName $ObjectName) } return $null }
        'SERVER_PRINCIPAL' {
            if (-not $ObjectName) { return $null }
            if ($SubType.ToUpperInvariant() -eq 'R') { return 'ON SERVER ROLE::' + (Esc-MhName $ObjectName) }
            return 'ON LOGIN::' + (Esc-MhName $ObjectName)
        }
        'SERVER_ROLE'             { if ($ObjectName) { return 'ON SERVER ROLE::' + (Esc-MhName $ObjectName) } return $null }
        'ENDPOINT'                { if ($ObjectName) { return 'ON ENDPOINT::' + (Esc-MhName $ObjectName) } return $null }
        'AVAILABILITY_GROUP'      { if ($ObjectName) { return 'ON AVAILABILITY GROUP::' + (Esc-MhName $ObjectName) } return $null }
        default { return $null }
    }
}

function New-AccessPermissionStatement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Row,
        [Parameter(Mandatory)] [string] $ToPrincipal
    )

    $clause = Get-AccessSecurableClause -ClassDesc ([string]$Row.ClassDesc) -SchemaName ([string]$Row.SchemaName) `
                                  -ObjectName ([string]$Row.ObjectName) -ColumnName ([string]$Row.ColumnName) `
                                  -SubType ([string]$Row.SubType)
    if ($null -eq $clause) { return $null }

    $permission = ([string]$Row.PermissionName).Trim()
    if (-not $permission) { return $null }
    $target = Esc-MhName $ToPrincipal
    $state = ([string]$Row.StateDesc).ToUpperInvariant()

    $verb = switch ($state) {
        'DENY'                    { 'DENY' }
        'REVOKE'                  { 'REVOKE' }
        default                   { 'GRANT' }
    }
    $statement = $verb + ' ' + $permission
    if ($clause) { $statement += ' ' + $clause }
    $statement += ' TO ' + $target
    if ($state -eq 'GRANT_WITH_GRANT_OPTION') { $statement += ' WITH GRANT OPTION' }
    $statement + ';'
}

function Test-AccessPrivilegedGrant {
    [CmdletBinding()]
    param([AllowEmptyString()] [string] $RoleName, [AllowEmptyString()] [string] $PermissionName)

    $roles = 'sysadmin', 'securityadmin', 'serveradmin', 'setupadmin', 'processadmin', 'diskadmin',
             'dbcreator', 'bulkadmin', 'loginmanager', 'dbmanager'
    $permissions = 'CONTROL SERVER', 'ALTER ANY LOGIN', 'ALTER ANY SERVER ROLE', 'ALTER ANY CREDENTIAL',
                   'ALTER ANY LINKED SERVER', 'ALTER SETTINGS', 'ALTER TRACE', 'ADMINISTER BULK OPERATIONS',
                   'IMPERSONATE ANY LOGIN', 'SELECT ALL USER SECURABLES', 'UNSAFE ASSEMBLY',
                   'EXTERNAL ACCESS ASSEMBLY', 'CREATE SERVER ROLE', 'SHUTDOWN'

    if ($RoleName -and ($roles -contains $RoleName.ToLowerInvariant())) { return $true }
    if ($PermissionName -and ($permissions -contains $PermissionName.ToUpperInvariant())) { return $true }
    $false
}

function Resolve-AccessDatabaseName {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Name, $Map)

    if ($null -eq $Map) { return $Name }
    if ($Map -is [System.Collections.IDictionary]) {
        foreach ($key in $Map.Keys) { if ([string]$key -eq $Name) { return [string]$Map[$key] } }
        return $Name
    }
    # the string form, for powershell.exe -File which cannot pass a hashtable
    foreach ($entry in @($Map)) {
        foreach ($pair in (([string]$entry) -split ';')) {
            $parts = $pair.Split('=')
            if ($parts.Count -eq 2 -and $parts[0].Trim() -eq $Name) { return $parts[1].Trim() }
        }
    }
    $Name
}

function New-AccessPrincipalStatement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [ValidateSet('Login', 'User')] [string] $Scope,
        [Parameter(Mandatory)] [string] $TypeDesc,
        [AllowEmptyString()] [string] $DefaultDatabase,
        [AllowEmptyString()] [string] $DefaultSchema,
        [AllowEmptyString()] [string] $PasswordLiteral,
        [AllowEmptyString()] [string] $Sid,
        [switch] $Hashed,
        [switch] $AzureSqlDatabase,
        [AllowEmptyString()] [string] $ForLogin,
        [AllowEmptyString()] [string] $AuthType
    )

    $quoted = Esc-MhName $Name
    $type = $TypeDesc.ToUpperInvariant()
    $windows = ($type -like 'WINDOWS*')
    $external = ($type -like '*EXTERNAL*')          # Entra, in all its spellings

    if ($Scope -eq 'Login') {
        if ($AzureSqlDatabase) { return $null }     # there is no CREATE LOGIN worth having here
        if ($windows) { return 'CREATE LOGIN ' + $quoted + ' FROM WINDOWS' + $(if ($DefaultDatabase) { ' WITH DEFAULT_DATABASE = ' + (Esc-MhName $DefaultDatabase) } else { '' }) + ';' }
        if ($external) { return 'CREATE LOGIN ' + $quoted + ' FROM EXTERNAL PROVIDER;' }
        if (-not $PasswordLiteral) { return $null }
        $with = 'PASSWORD = ' + $PasswordLiteral
        if ($Hashed) { $with += ' HASHED' }
        if ($Sid) { $with += ', SID = ' + $Sid }
        if ($DefaultDatabase) { $with += ', DEFAULT_DATABASE = ' + (Esc-MhName $DefaultDatabase) }
        if ($Hashed) { $with += ', CHECK_POLICY = OFF' }   # a copied hash must not be re-policed
        return 'CREATE LOGIN ' + $quoted + ' WITH ' + $with + ';'
    }

    # A database user, where what to write is decided by what it authenticates with rather than by
    # its type. type_desc says SQL_USER for all three of a user mapped to a login, a user with no
    # login at all and a contained user with its own password; authentication_type_desc is what
    # tells them apart - INSTANCE, NONE and DATABASE.
    $tail = if ($DefaultSchema) { ' WITH DEFAULT_SCHEMA = ' + (Esc-MhName $DefaultSchema) } else { '' }
    $auth = $AuthType.ToUpperInvariant()
    $password = ''
    if ($PasswordLiteral) {
        $password = 'CREATE USER ' + $quoted + ' WITH PASSWORD = ' + $PasswordLiteral +
                    $(if ($DefaultSchema) { ', DEFAULT_SCHEMA = ' + (Esc-MhName $DefaultSchema) } else { '' }) + ';'
    }

    if ($external -or $auth -eq 'EXTERNAL') { return 'CREATE USER ' + $quoted + ' FROM EXTERNAL PROVIDER' + $tail + ';' }
    if ($auth -eq 'NONE') { return 'CREATE USER ' + $quoted + ' WITHOUT LOGIN' + $tail + ';' }
    if ($auth -eq 'DATABASE') { if ($password) { return $password } return $null }
    if ($type -like '*MAPPED*') { return $null }   # tied to a certificate or key, which is not ours to copy
    if ($ForLogin) { return 'CREATE USER ' + $quoted + ' FOR LOGIN ' + (Esc-MhName $ForLogin) + $tail + ';' }
    if ($windows) { return 'CREATE USER ' + $quoted + ' FROM WINDOWS' + $tail + ';' }
    if ($password) { return $password }
    $null
}

function Hide-AccessSecret {
    [CmdletBinding()]
    param([AllowEmptyString()] [string] $Statement)
    [regex]::Replace($Statement, "(?i)(PASSWORD\s*=\s*)(N?'(?:[^']|'')*'|0x[0-9A-Fa-f]+)", '$1<withheld>')
}

function ConvertTo-AccessPasswordLiteral {
    [CmdletBinding()]
    param([AllowNull()] [System.Security.SecureString] $Secure)

    if ($null -eq $Secure) { return '' }
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { "N'" + ([System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) -replace "'", "''") + "'" }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function ConvertTo-AccessHexLiteral {
    [CmdletBinding()]
    param([AllowNull()] $Bytes)

    if ($null -eq $Bytes -or $Bytes -is [System.DBNull]) { return '' }
    if ($Bytes -is [string]) { return $Bytes }
    '0x' + (($Bytes | ForEach-Object { $_.ToString('X2') }) -join '')
}

function Get-AccessEditionName([int] $EngineEdition) {
    switch ($EngineEdition) {
        1 { 'SQL Server Personal/Desktop' }
        2 { 'SQL Server Standard' }
        3 { 'SQL Server Enterprise, Developer or Evaluation' }
        4 { 'SQL Server Express or LocalDB' }
        5 { 'Azure SQL Database' }
        6 { 'Azure Synapse Analytics' }
        8 { 'Azure SQL Managed Instance' }
        9 { 'Azure Synapse serverless SQL pool' }
        11 { 'Azure SQL Edge' }
        default { "an engine edition this script has not seen before ($EngineEdition)" }
    }
}

function New-AccessRoleMemberStatement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RoleName,
        [Parameter(Mandatory)] [string] $MemberName,
        [Parameter(Mandatory)] [ValidateSet('Server', 'Database')] [string] $Scope,
        [int] $MajorVersion = 0
    )

    $legacy = ($MajorVersion -gt 0 -and $MajorVersion -lt 11)
    if ($Scope -eq 'Server') {
        if ($legacy) { return "EXEC sp_addsrvrolemember @loginame = N'" + (Esc-MhStr $MemberName) + "', @rolename = N'" + (Esc-MhStr $RoleName) + "';" }
        return 'ALTER SERVER ROLE ' + (Esc-MhName $RoleName) + ' ADD MEMBER ' + (Esc-MhName $MemberName) + ';'
    }
    if ($legacy) { return "EXEC sp_addrolemember @rolename = N'" + (Esc-MhStr $RoleName) + "', @membername = N'" + (Esc-MhStr $MemberName) + "';" }
    'ALTER ROLE ' + (Esc-MhName $RoleName) + ' ADD MEMBER ' + (Esc-MhName $MemberName) + ';'
}

function Get-AccessClassLookup([string] $ClassDesc) {
    if (-not $ClassDesc) { return $null }
    $key = $ClassDesc.ToUpperInvariant()
    if ($script:AccessClassLookup.ContainsKey($key)) { return $script:AccessClassLookup[$key] }
    $null
}

function New-AccessTargetLookupQuery {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ClassDesc, [Parameter(Mandatory)] [int[]] $Ids)

    $list = ($Ids | Sort-Object -Unique) -join ','
    switch ($ClassDesc.ToUpperInvariant()) {
        'OBJECT_OR_COLUMN' {
            return "SELECT MajorId = o.object_id, SchemaName = SCHEMA_NAME(o.schema_id), ObjectName = o.name, " +
                   "SubType = CONVERT(char(1), NULL) FROM sys.objects o WHERE o.object_id IN ($list);"
        }
        'SCHEMA' {
            return "SELECT MajorId = s.schema_id, SchemaName = CONVERT(sysname, NULL), ObjectName = s.name, " +
                   "SubType = CONVERT(char(1), NULL) FROM sys.schemas s WHERE s.schema_id IN ($list);"
        }
    }
    $lookup = Get-AccessClassLookup $ClassDesc
    if (-not $lookup) { return $null }
    $schema = if ($lookup.Schema) { 'SCHEMA_NAME(x.schema_id)' } else { 'CONVERT(sysname, NULL)' }
    # principals need their own type as well, because a permission on a role is not written the way
    # one on a user is
    $subType = if ($lookup.Type) { 'x.type' } else { 'CONVERT(char(1), NULL)' }
    "IF OBJECT_ID('$($lookup.View)') IS NOT NULL EXEC sp_executesql N'" +
    "SELECT MajorId = x.$($lookup.Id), SchemaName = $schema, ObjectName = x.name, SubType = $subType " +
    "FROM $($lookup.View) x WHERE x.$($lookup.Id) IN ($list)';"
}

function Get-AccessUserQuery([int] $MajorVersion) {
    $auth = if ($MajorVersion -ge 11) { 'dp.authentication_type_desc' }
            else { "CONVERT(nvarchar(60), CASE WHEN dp.sid IS NULL OR (dp.type = 'S' AND SUSER_SNAME(dp.sid) IS NULL) THEN 'NONE' ELSE 'INSTANCE' END)" }
    @"
SELECT  dp.name, dp.type, dp.type_desc, dp.default_schema_name,
        AuthType = $auth,
        HasSid = CONVERT(bit, CASE WHEN dp.sid IS NULL THEN 0 ELSE 1 END)
FROM sys.database_principals dp
WHERE dp.name = @p AND dp.type NOT IN ('R', 'A');
"@
}

function Resolve-AccessPermissionTargets {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Server,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Rows,
        [string] $DatabaseName = 'master'
    )

    $resolved = New-Object System.Collections.Generic.List[object]
    foreach ($row in $Rows) {
        $resolved.Add([pscustomobject]@{
            StateDesc = [string]$row['StateDesc']; PermissionName = [string]$row['PermissionName']
            ClassDesc = [string]$row['ClassDesc']; MajorId = [int]$row['MajorId']; MinorId = [int]$row['MinorId']
            SchemaName = ''; ObjectName = ''; ColumnName = ''; SubType = ''; Resolvable = $true
        })
    }

    foreach ($group in ($resolved | Where-Object { $_.MajorId -ne 0 } | Group-Object ClassDesc)) {
        $ids = @($group.Group | ForEach-Object { $_.MajorId })
        $query = New-AccessTargetLookupQuery -ClassDesc $group.Name -Ids $ids
        if (-not $query) {
            foreach ($row in $group.Group) { $row.Resolvable = $false }
            continue
        }
        $names = @{}
        $schemas = @{}
        $subTypes = @{}
        try {
            foreach ($found in (Invoke-AccessSql -Server $Server -DatabaseName $DatabaseName -Query $query).Rows) {
                $id = [int]$found['MajorId']
                $names[$id] = [string]$found['ObjectName']
                if ($found['SchemaName'] -isnot [DBNull]) { $schemas[$id] = [string]$found['SchemaName'] }
                if ($found['SubType'] -isnot [DBNull]) { $subTypes[$id] = ([string]$found['SubType']).Trim() }
            }
        }
        catch { Write-MhDeep ('could not look up {0} targets: {1}' -f $group.Name, $_.Exception.Message) }

        foreach ($row in $group.Group) {
            if ($names.ContainsKey($row.MajorId)) {
                $row.ObjectName = $names[$row.MajorId]
                if ($schemas.ContainsKey($row.MajorId)) { $row.SchemaName = $schemas[$row.MajorId] }
                if ($subTypes.ContainsKey($row.MajorId)) { $row.SubType = $subTypes[$row.MajorId] }
            }
            else { $row.Resolvable = $false }
        }
    }

    # column permissions, the one case where minor_id means something
    $columnRows = @($resolved | Where-Object { $_.ClassDesc -eq 'OBJECT_OR_COLUMN' -and $_.MinorId -gt 0 -and $_.Resolvable })
    if ($columnRows.Count) {
        $where = @($columnRows | ForEach-Object { '(c.object_id = {0} AND c.column_id = {1})' -f $_.MajorId, $_.MinorId }) -join ' OR '
        $query = 'SELECT MajorId = c.object_id, MinorId = c.column_id, ColumnName = c.name FROM sys.columns c WHERE ' + $where + ';'
        $columns = @{}
        try {
            foreach ($found in (Invoke-AccessSql -Server $Server -DatabaseName $DatabaseName -Query $query).Rows) {
                $columns[('{0}.{1}' -f [int]$found['MajorId'], [int]$found['MinorId'])] = [string]$found['ColumnName']
            }
        }
        catch { Write-MhDeep ('could not look up column names: ' + $_.Exception.Message) }
        foreach ($row in $columnRows) {
            $key = '{0}.{1}' -f $row.MajorId, $row.MinorId
            if ($columns.ContainsKey($key)) { $row.ColumnName = $columns[$key] } else { $row.Resolvable = $false }
        }
    }

    $resolved.ToArray()
}

function Add-AccessPlan([string] $Database, [string] $Statement, [string] $Note = '', [bool] $Privileged = $false,
                  [string] $Kind = 'Grant') {
    # Kind is how the apply knows what depends on what: everything in a database needs the user,
    # and the user needs the login
    $script:AccessPlan.Add([pscustomobject]@{ Database = $Database; Statement = $Statement; Note = $Note
                                 Privileged = $Privileged; Kind = $Kind })
}

function Add-AccessSkip([string] $Where, [string] $What, [string] $Why) {
    $script:AccessSkipped.Add([pscustomobject]@{ Where = $Where; What = $What; Why = $Why })
}

function Get-AccessFirstLine([string] $Text) { ($Text -split "`r?`n")[0] }

function Get-AccessExistingGrants {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Query, [string] $DatabaseName = 'master')

    $have = @{}
    try {
        $rows = @((Invoke-AccessSql -Server $script:AccessDestinationInstance -DatabaseName $DatabaseName -Query $Query `
                   -Parameters @{ '@p' = $script:AccessPrincipal }).Rows)
        foreach ($row in (Resolve-AccessPermissionTargets -Server $script:AccessDestinationInstance -DatabaseName $DatabaseName -Rows $rows)) {
            if (-not $row.Resolvable) { continue }
            $statement = New-AccessPermissionStatement -Row $row -ToPrincipal $script:AccessPrincipal
            if ($statement) { $have[$statement] = $true }
        }
    }
    catch { Write-MhDeep ('could not read what the target already has: ' + $_.Exception.Message) }
    $have
}

function Get-AccessPlanGroups {
    $order = New-Object System.Collections.Generic.List[string]
    foreach ($item in $script:AccessPlan) { if (-not $order.Contains($item.Database)) { $order.Add($item.Database) } }
    foreach ($name in $order) {
        [pscustomobject]@{ Name = $name; Group = @($script:AccessPlan | Where-Object { $_.Database -eq $name }) }
    }
}

Register-MhSelfTest -Name 'Copy-MhSqlAccess' -Test {
    function Perm([string] $Class, [string] $Permission, [string] $State = 'GRANT',
                  [string] $Schema = '', [string] $Object = '', [string] $Column = '', [string] $SubType = '') {
        [pscustomobject]@{ ClassDesc = $Class; PermissionName = $Permission; StateDesc = $State
                           SchemaName = $Schema; ObjectName = $Object; ColumnName = $Column; SubType = $SubType }
    }

    Test-MhSection 'the statements it builds'
    Test-MhCheck 'connect to the database has no ON clause' ((New-AccessPermissionStatement (Perm 'DATABASE' 'CONNECT') 'xyz') -eq 'GRANT CONNECT TO [xyz];')
    Test-MhCheck 'a table' ((New-AccessPermissionStatement (Perm 'OBJECT_OR_COLUMN' 'SELECT' 'GRANT' 'dbo' 'Orders') 'xyz') -eq 'GRANT SELECT ON [dbo].[Orders] TO [xyz];')
    Test-MhCheck 'a column' ((New-AccessPermissionStatement (Perm 'OBJECT_OR_COLUMN' 'SELECT' 'GRANT' 'dbo' 'Orders' 'Total') 'xyz') -eq 'GRANT SELECT ON [dbo].[Orders]([Total]) TO [xyz];')
    Test-MhCheck 'a schema' ((New-AccessPermissionStatement (Perm 'SCHEMA' 'EXECUTE' 'GRANT' '' 'sales') 'xyz') -eq 'GRANT EXECUTE ON SCHEMA::[sales] TO [xyz];')
    Test-MhCheck 'a type keeps its schema' ((New-AccessPermissionStatement (Perm 'TYPE' 'EXECUTE' 'GRANT' 'dbo' 'OrderList') 'xyz') -eq 'GRANT EXECUTE ON TYPE::[dbo].[OrderList] TO [xyz];')
    Test-MhCheck 'a role' ((New-AccessPermissionStatement (Perm 'ROLE' 'ALTER' 'GRANT' '' 'ReportReaders') 'xyz') -eq 'GRANT ALTER ON ROLE::[ReportReaders] TO [xyz];')
    Test-MhCheck 'impersonating a user' ((New-AccessPermissionStatement (Perm 'DATABASE_PRINCIPAL' 'IMPERSONATE' 'GRANT' '' 'dbo') 'xyz') -eq 'GRANT IMPERSONATE ON USER::[dbo] TO [xyz];')
    Test-MhCheck 'a certificate' ((New-AccessPermissionStatement (Perm 'CERTIFICATE' 'VIEW DEFINITION' 'GRANT' '' 'AppCert') 'xyz') -eq 'GRANT VIEW DEFINITION ON CERTIFICATE::[AppCert] TO [xyz];')
    Test-MhCheck 'a symmetric key spells the two words out' ((New-AccessPermissionStatement (Perm 'SYMMETRIC_KEY' 'VIEW DEFINITION' 'GRANT' '' 'AppKey') 'xyz') -eq 'GRANT VIEW DEFINITION ON SYMMETRIC KEY::[AppKey] TO [xyz];')
    Test-MhCheck 'an XML schema collection too' ((New-AccessPermissionStatement (Perm 'XML_SCHEMA_COLLECTION' 'EXECUTE' 'GRANT' 'dbo' 'Invoices') 'xyz') -eq 'GRANT EXECUTE ON XML SCHEMA COLLECTION::[dbo].[Invoices] TO [xyz];')
    Test-MhCheck 'a service broker contract' ((New-AccessPermissionStatement (Perm 'SERVICE_CONTRACT' 'SEND' 'GRANT' '' 'OrderContract') 'xyz') -eq 'GRANT SEND ON CONTRACT::[OrderContract] TO [xyz];')
    Test-MhCheck 'a server permission has no ON clause' ((New-AccessPermissionStatement (Perm 'SERVER' 'VIEW SERVER STATE') 'xyz') -eq 'GRANT VIEW SERVER STATE TO [xyz];')
    Test-MhCheck 'impersonating a login' ((New-AccessPermissionStatement (Perm 'SERVER_PRINCIPAL' 'IMPERSONATE' 'GRANT' '' 'sa') 'xyz') -eq 'GRANT IMPERSONATE ON LOGIN::[sa] TO [xyz];')
    Test-MhCheck 'an endpoint' ((New-AccessPermissionStatement (Perm 'ENDPOINT' 'CONNECT' 'GRANT' '' 'TSQL Default TCP') 'xyz') -eq 'GRANT CONNECT ON ENDPOINT::[TSQL Default TCP] TO [xyz];')

    Test-MhSection 'a principal, which is three different things under one class'
    Test-MhCheck 'a database role is a role, not a user' ((New-AccessPermissionStatement (Perm 'DATABASE_PRINCIPAL' 'ALTER' 'GRANT' '' 'ReportReaders' '' 'R') 'xyz') -eq 'GRANT ALTER ON ROLE::[ReportReaders] TO [xyz];')
    Test-MhCheck 'an application role says so' ((New-AccessPermissionStatement (Perm 'DATABASE_PRINCIPAL' 'ALTER' 'GRANT' '' 'AppRole' '' 'A') 'xyz') -eq 'GRANT ALTER ON APPLICATION ROLE::[AppRole] TO [xyz];')
    Test-MhCheck 'a SQL user is a user' ((New-AccessPermissionStatement (Perm 'DATABASE_PRINCIPAL' 'IMPERSONATE' 'GRANT' '' 'LocalOnly' '' 'S') 'xyz') -eq 'GRANT IMPERSONATE ON USER::[LocalOnly] TO [xyz];')
    Test-MhCheck 'a Windows user is too' ((New-AccessPermissionStatement (Perm 'DATABASE_PRINCIPAL' 'IMPERSONATE' 'GRANT' '' 'CONTOSO\abc' '' 'U') 'xyz') -eq 'GRANT IMPERSONATE ON USER::[CONTOSO\abc] TO [xyz];')
    Test-MhCheck 'a server role is a server role' ((New-AccessPermissionStatement (Perm 'SERVER_PRINCIPAL' 'ALTER' 'GRANT' '' 'AppAdmins' '' 'R') 'xyz') -eq 'GRANT ALTER ON SERVER ROLE::[AppAdmins] TO [xyz];')
    Test-MhCheck 'and a login is a login' ((New-AccessPermissionStatement (Perm 'SERVER_PRINCIPAL' 'IMPERSONATE' 'GRANT' '' 'sa' '' 'S') 'xyz') -eq 'GRANT IMPERSONATE ON LOGIN::[sa] TO [xyz];')

    Test-MhSection 'the three states, which all matter'
    Test-MhCheck 'a deny stays a deny' ((New-AccessPermissionStatement (Perm 'OBJECT_OR_COLUMN' 'SELECT' 'DENY' 'dbo' 'Wages') 'xyz') -eq 'DENY SELECT ON [dbo].[Wages] TO [xyz];')
    Test-MhCheck 'a grant option is carried over' ((New-AccessPermissionStatement (Perm 'OBJECT_OR_COLUMN' 'SELECT' 'GRANT_WITH_GRANT_OPTION' 'dbo' 'Orders') 'xyz') -eq 'GRANT SELECT ON [dbo].[Orders] TO [xyz] WITH GRANT OPTION;')
    Test-MhCheck 'and a revoke is not turned into a grant' ((New-AccessPermissionStatement (Perm 'OBJECT_OR_COLUMN' 'SELECT' 'REVOKE' 'dbo' 'Orders') 'xyz') -match '^REVOKE ')

    Test-MhSection 'names that would otherwise break out of the statement'
    Test-MhCheck 'a bracket in a table name is escaped' ((New-AccessPermissionStatement (Perm 'OBJECT_OR_COLUMN' 'SELECT' 'GRANT' 'dbo' 'Odd]Name') 'xyz') -eq 'GRANT SELECT ON [dbo].[Odd]]Name] TO [xyz];')
    Test-MhCheck 'a domain account is quoted whole' ((New-AccessPermissionStatement (Perm 'DATABASE' 'CONNECT') 'CONTOSO\xyz') -eq 'GRANT CONNECT TO [CONTOSO\xyz];')
    Test-MhCheck 'an Entra account with an at sign too' ((New-AccessPermissionStatement (Perm 'DATABASE' 'CONNECT') 'xyz@contoso.com') -eq 'GRANT CONNECT TO [xyz@contoso.com];')

    Test-MhSection 'a class it does not know is reported, not guessed'
    Test-MhCheck 'an unknown class gives nothing back' ($null -eq (New-AccessPermissionStatement (Perm 'SOME_NEW_CLASS' 'SELECT' 'GRANT' '' 'thing') 'xyz'))
    Test-MhCheck 'and so does a known class with no target' ($null -eq (New-AccessPermissionStatement (Perm 'SCHEMA' 'EXECUTE') 'xyz'))

    Test-MhSection 'what counts as control of the instance'
    Test-MhCheck 'sysadmin does' (Test-AccessPrivilegedGrant -RoleName 'sysadmin')
    Test-MhCheck 'securityadmin does' (Test-AccessPrivilegedGrant -RoleName 'securityadmin')
    Test-MhCheck 'and so does dbcreator' (Test-AccessPrivilegedGrant -RoleName 'dbcreator')
    Test-MhCheck 'Azure loginmanager does' (Test-AccessPrivilegedGrant -RoleName 'loginmanager')
    Test-MhCheck 'CONTROL SERVER does' (Test-AccessPrivilegedGrant -PermissionName 'CONTROL SERVER')
    Test-MhCheck 'ALTER ANY LOGIN does' (Test-AccessPrivilegedGrant -PermissionName 'alter any login')
    Test-MhCheck 'public does not' (-not (Test-AccessPrivilegedGrant -RoleName 'public'))
    Test-MhCheck 'db_datareader does not' (-not (Test-AccessPrivilegedGrant -RoleName 'db_datareader'))
    Test-MhCheck 'VIEW SERVER STATE does not' (-not (Test-AccessPrivilegedGrant -PermissionName 'VIEW SERVER STATE'))
    Test-MhCheck 'and nor does plain SELECT' (-not (Test-AccessPrivilegedGrant -PermissionName 'SELECT'))

    Test-MhSection 'databases named differently at each end'
    Test-MhCheck 'a hashtable maps it' ((Resolve-AccessDatabaseName -Name 'SalesStg' -Map @{ SalesStg = 'SalesProd' }) -eq 'SalesProd')
    Test-MhCheck 'anything unmapped keeps its name' ((Resolve-AccessDatabaseName -Name 'Stock' -Map @{ SalesStg = 'SalesProd' }) -eq 'Stock')
    Test-MhCheck 'the string form works for -File' ((Resolve-AccessDatabaseName -Name 'SalesStg' -Map 'SalesStg=SalesProd') -eq 'SalesProd')
    Test-MhCheck 'several pairs in one string' ((Resolve-AccessDatabaseName -Name 'Stock' -Map 'SalesStg=SalesProd;Stock=StockProd') -eq 'StockProd')
    Test-MhCheck 'no map at all is no change' ((Resolve-AccessDatabaseName -Name 'Sales' -Map $null) -eq 'Sales')

    Test-MhSection 'creating the principal'
    Test-MhCheck 'a Windows login' ((New-AccessPrincipalStatement -Name 'CONTOSO\xyz' -Scope Login -TypeDesc 'WINDOWS_LOGIN') -eq 'CREATE LOGIN [CONTOSO\xyz] FROM WINDOWS;')
    Test-MhCheck 'with its default database' ((New-AccessPrincipalStatement -Name 'CONTOSO\xyz' -Scope Login -TypeDesc 'WINDOWS_LOGIN' -DefaultDatabase 'Sales') -match 'DEFAULT_DATABASE = \[Sales\]')
    Test-MhCheck 'an Entra login' ((New-AccessPrincipalStatement -Name 'xyz@contoso.com' -Scope Login -TypeDesc 'EXTERNAL_LOGIN') -eq 'CREATE LOGIN [xyz@contoso.com] FROM EXTERNAL PROVIDER;')
    Test-MhCheck 'a SQL login needs a password' ($null -eq (New-AccessPrincipalStatement -Name 'xyz' -Scope Login -TypeDesc 'SQL_LOGIN'))
    Test-MhCheck 'and takes one when given' ((New-AccessPrincipalStatement -Name 'xyz' -Scope Login -TypeDesc 'SQL_LOGIN' -PasswordLiteral "N'pw'") -eq "CREATE LOGIN [xyz] WITH PASSWORD = N'pw';")
    $cloned = New-AccessPrincipalStatement -Name 'AppSvc' -Scope Login -TypeDesc 'SQL_LOGIN' -PasswordLiteral '0xABCD' -Sid '0x1234' -Hashed
    Test-MhCheck 'a cloned login carries hash and SID' ($cloned -match 'PASSWORD = 0xABCD HASHED' -and $cloned -match 'SID = 0x1234')
    Test-MhCheck 'and is not re-policed, which would reject the hash' ($cloned -match 'CHECK_POLICY = OFF')
    Test-MhCheck 'there is no login to create on Azure SQL Database' ($null -eq (New-AccessPrincipalStatement -Name 'xyz' -Scope Login -TypeDesc 'WINDOWS_LOGIN' -AzureSqlDatabase))

    Test-MhCheck 'a user for a login' ((New-AccessPrincipalStatement -Name 'xyz' -Scope User -TypeDesc 'SQL_USER' -ForLogin 'xyz') -eq 'CREATE USER [xyz] FOR LOGIN [xyz];')
    Test-MhCheck 'with its default schema' ((New-AccessPrincipalStatement -Name 'xyz' -Scope User -TypeDesc 'SQL_USER' -ForLogin 'xyz' -DefaultSchema 'sales') -match 'DEFAULT_SCHEMA = \[sales\]')
    Test-MhCheck 'an Entra user needs no login' ((New-AccessPrincipalStatement -Name 'xyz@contoso.com' -Scope User -TypeDesc 'EXTERNAL_USER') -eq 'CREATE USER [xyz@contoso.com] FROM EXTERNAL PROVIDER;')
    Test-MhCheck 'a user with no login behind it' ((New-AccessPrincipalStatement -Name 'xyz' -Scope User -TypeDesc 'SQL_USER' -AuthType 'NONE') -eq 'CREATE USER [xyz] WITHOUT LOGIN;')
    Test-MhCheck 'which is how SQL Server describes it, whatever the type says' ((New-AccessPrincipalStatement -Name 'xyz' -Scope User -TypeDesc 'SQL_USER' -AuthType 'NONE' -ForLogin 'xyz') -eq 'CREATE USER [xyz] WITHOUT LOGIN;')
    Test-MhCheck 'a contained user with a password' ((New-AccessPrincipalStatement -Name 'xyz' -Scope User -TypeDesc 'SQL_USER' -AuthType 'DATABASE' -PasswordLiteral "N'pw'") -eq "CREATE USER [xyz] WITH PASSWORD = N'pw';")
    Test-MhCheck 'a contained user keeps its default schema' ((New-AccessPrincipalStatement -Name 'xyz' -Scope User -TypeDesc 'SQL_USER' -AuthType 'DATABASE' -PasswordLiteral "N'pw'" -DefaultSchema 'sales') -match ', DEFAULT_SCHEMA = \[sales\];$')
    Test-MhCheck 'a certificate-mapped user is not invented' ($null -eq (New-AccessPrincipalStatement -Name 'xyz' -Scope User -TypeDesc 'CERTIFICATE_MAPPED_USER'))
    Test-MhCheck 'a Windows user mapped straight through' ((New-AccessPrincipalStatement -Name 'CONTOSO\xyz' -Scope User -TypeDesc 'WINDOWS_USER') -eq 'CREATE USER [CONTOSO\xyz] FROM WINDOWS;')
    Test-MhCheck 'and a contained user with no password is refused' ($null -eq (New-AccessPrincipalStatement -Name 'xyz' -Scope User -TypeDesc 'SQL_USER' -AuthType 'DATABASE'))

    Test-MhSection 'hex and secrets'
    Test-MhCheck 'a password is kept out of the printed plan' ((Hide-AccessSecret "CREATE LOGIN [xyz] WITH PASSWORD = N'p''wd', DEFAULT_DATABASE = [Sales];") -eq 'CREATE LOGIN [xyz] WITH PASSWORD = <withheld>, DEFAULT_DATABASE = [Sales];')
    Test-MhCheck 'and so is a copied hash' ((Hide-AccessSecret 'CREATE LOGIN [xyz] WITH PASSWORD = 0xABCDEF HASHED, SID = 0x1234;') -eq 'CREATE LOGIN [xyz] WITH PASSWORD = <withheld> HASHED, SID = 0x1234;')
    Test-MhCheck 'a statement with no password is left alone' ((Hide-AccessSecret 'GRANT SELECT ON [dbo].[T] TO [xyz];') -eq 'GRANT SELECT ON [dbo].[T] TO [xyz];')
    Test-MhCheck 'bytes become a hex literal' ((ConvertTo-AccessHexLiteral ([byte[]](0x01, 0xAB, 0xFF))) -eq '0x01ABFF')
    Test-MhCheck 'nothing becomes nothing' ((ConvertTo-AccessHexLiteral $null) -eq '')
    $secure = ConvertTo-SecureString "p'wd" -AsPlainText -Force
    Test-MhCheck 'a password is quoted and its quote doubled' ((ConvertTo-AccessPasswordLiteral $secure) -eq "N'p''wd'")
    Test-MhCheck 'no password is an empty literal' ((ConvertTo-AccessPasswordLiteral $null) -eq '')

    Test-MhSection 'statements an older destination can actually run'
    Test-MhCheck 'a modern server role' ((New-AccessRoleMemberStatement -RoleName 'dbcreator' -MemberName 'xyz' -Scope Server -MajorVersion 16) -eq 'ALTER SERVER ROLE [dbcreator] ADD MEMBER [xyz];')
    Test-MhCheck 'a modern database role' ((New-AccessRoleMemberStatement -RoleName 'db_datareader' -MemberName 'xyz' -Scope Database -MajorVersion 16) -eq 'ALTER ROLE [db_datareader] ADD MEMBER [xyz];')
    Test-MhCheck '2008 R2 gets sp_addsrvrolemember' ((New-AccessRoleMemberStatement -RoleName 'dbcreator' -MemberName 'CONTOSO\xyz' -Scope Server -MajorVersion 10) -eq "EXEC sp_addsrvrolemember @loginame = N'CONTOSO\xyz', @rolename = N'dbcreator';")
    Test-MhCheck '2008 R2 gets sp_addrolemember' ((New-AccessRoleMemberStatement -RoleName 'db_datareader' -MemberName 'xyz' -Scope Database -MajorVersion 10) -eq "EXEC sp_addrolemember @rolename = N'db_datareader', @membername = N'xyz';")
    Test-MhCheck 'and a quote in a role name is doubled, not left to break out' ((New-AccessRoleMemberStatement -RoleName "O'Brien" -MemberName 'xyz' -Scope Database -MajorVersion 10) -match "N'O''Brien'")
    Test-MhCheck 'an unknown version is assumed to be a current one' ((New-AccessRoleMemberStatement -RoleName 'public' -MemberName 'xyz' -Scope Database) -match '^ALTER ROLE ')

    Test-MhSection 'looking a permission target up by class'
    Test-MhCheck 'a table is found through sys.objects' ((New-AccessTargetLookupQuery -ClassDesc 'OBJECT_OR_COLUMN' -Ids @(5, 5, 3)) -match 'sys\.objects o WHERE o\.object_id IN \(3,5\);$')
    Test-MhCheck 'a principal lookup brings its type back with it' ((New-AccessTargetLookupQuery -ClassDesc 'DATABASE_PRINCIPAL' -Ids @(5)) -match 'SubType = x\.type')
    Test-MhCheck 'and anything else does not pretend to have one' ((New-AccessTargetLookupQuery -ClassDesc 'CERTIFICATE' -Ids @(5)) -match 'SubType = CONVERT\(char\(1\), NULL\)')
    Test-MhCheck 'a schema through sys.schemas' ((New-AccessTargetLookupQuery -ClassDesc 'SCHEMA' -Ids @(9)) -match 'sys\.schemas s WHERE s\.schema_id IN \(9\)')
    $credential = New-AccessTargetLookupQuery -ClassDesc 'DATABASE_SCOPED_CREDENTIAL' -Ids @(7)
    Test-MhCheck 'a view that may not exist is asked for only if it is there' ($credential -match "IF OBJECT_ID\('sys\.database_scoped_credentials'\) IS NOT NULL")
    Test-MhCheck 'and by its own id column' ($credential -match 'credential_id IN \(7\)')
    Test-MhCheck 'a type carries its schema back with it' ((New-AccessTargetLookupQuery -ClassDesc 'TYPE' -Ids @(256)) -match 'SCHEMA_NAME\(x\.schema_id\)')
    Test-MhCheck 'a certificate does not pretend to have one' ((New-AccessTargetLookupQuery -ClassDesc 'CERTIFICATE' -Ids @(1)) -match 'CONVERT\(sysname, NULL\)')
    Test-MhCheck 'an availability group is not guessed at, because its id is a GUID' ($null -eq (New-AccessTargetLookupQuery -ClassDesc 'AVAILABILITY_GROUP' -Ids @(1)))
    Test-MhCheck 'nor is any other class it has not met' ($null -eq (New-AccessTargetLookupQuery -ClassDesc 'SOMETHING_NEW' -Ids @(1)))

    Test-MhSection 'knowing what kind of instance it is talking to'
    Test-MhCheck 'on premises' ((Get-AccessEditionName 3) -match 'SQL Server Enterprise')
    Test-MhCheck 'Azure SQL Database' ((Get-AccessEditionName 5) -eq 'Azure SQL Database')
    Test-MhCheck 'a managed instance' ((Get-AccessEditionName 8) -eq 'Azure SQL Managed Instance')
    Test-MhCheck 'and an edition from the future is not misreported' ((Get-AccessEditionName 99) -match 'not seen before')

}

<#
  The tool's own two calls over the module's Invoke-MhSql: this tool asks by server and database
  name and expects the credential, the certificate and the timeout for that end to be worked out
  for it, which is what its own copy used to do.
#>
function Invoke-AccessSql {
    [CmdletBinding()]
    param([string] $Server, [string] $Query, [hashtable] $Parameters, [string] $DatabaseName = 'master')

    Invoke-MhSql -Server $Server -Database $DatabaseName -Query $Query -Parameters $Parameters `
                 -Credential (Get-AccessCredentialFor $Server) `
                 -TrustServerCertificate:$script:AccessTrustServerCertificate `
                 -TimeoutSeconds $script:AccessConnectTimeoutSeconds `
                 -ApplicationName 'Copy-SqlAccess'
}

function Get-AccessScalar {
    [CmdletBinding()]
    param([string] $Server, [string] $Query, [hashtable] $Parameters, [string] $DatabaseName = 'master')

    $table = Invoke-AccessSql -Server $Server -Query $Query -Parameters $Parameters -DatabaseName $DatabaseName
    if ($table.Rows.Count -eq 0) { return $null }
    $value = $table.Rows[0][0]
    if ($value -is [DBNull]) { $null } else { $value }
}

# one way to refuse a run, tagged so a shim can tell "you asked for the impossible" from
# "something broke", and on the error stream rather than the host so a caller can catch it
function Stop-AccessRun {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Reason)
    Write-Error $Reason -Category InvalidArgument -ErrorId 'MhBadArgument' -ErrorAction Stop
}
