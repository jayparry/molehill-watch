#Requires -Version 5.1

<#
.SYNOPSIS
    Shows exactly how a SQL Server instance and this machine negotiate encryption: which TLS
    versions are agreed or refused, what cipher is chosen, and what the instance's certificate
    actually is. For when a connection fails with a TLS or certificate error and the message does
    not say why.

.DESCRIPTION
    Molehill Data Services | Test-SqlTlsHandshake

    A single file that can be copied to a server, over the real thing: everything this does lives
    in MolehillTools (Test-MhSqlTlsHandshake). With the module imported you would call that
    directly; this exists because copying one script to a box is how this estate works.

    SQL Server encrypts the login packet whatever else you ask for, so every connection starts with
    a TLS handshake - and on an old instance that is where connections die. The error a client
    reports ("pre-login handshake", "certificate chain", "no common algorithm") rarely says which
    side refused, or why.

    This speaks TDS directly: it opens the socket, sends a PRELOGIN packet, reads what the instance
    says about encryption, and then runs the TLS handshake itself - wrapped in TDS packets, the way
    a real client does - once for each TLS version in turn. No login is attempted, no credentials
    are needed, and nothing is read from or written to any database.

    It reports:
      * what the instance says about encryption: off, on, not supported, or required
      * for each TLS version, and for "whatever Windows picks by default", whether the handshake
        succeeded and with what cipher - or the exact error if it did not
      * the instance's certificate: subject, issuer, signature algorithm, key size and dates. A
        self-signed 1024-bit SHA1 certificate is normal for an old instance and is the usual reason
        a modern client objects
      * what this machine allows, so a refusal can be pinned on the client or the server

    WHY EACH ANSWER MATTERS
      Handshake works at TLS 1.2 but the client fails anyway  -> not TLS: look at the login itself
      Only TLS 1.0 works                                      -> the instance has no TLS 1.2 support
                                                                 (KB3135244 adds it to SQL Server
                                                                 2008, 2008 R2 and 2012, on specific
                                                                 builds for each service pack)
      Nothing works, "no common algorithm"                     -> no cipher suite in common; the
                                                                 instance is limited to suites this
                                                                 Windows build has retired
      Nothing works, the port refuses outright                 -> a closed port, not TLS: TCP/IP off
                                                                 in Configuration Manager, or the
                                                                 instance is on another port
      "Windows default" fails where naming TLS 1.0 works        -> TLS 1.0 is present but off by
                                                                 default here, which is what most
                                                                 clients ask for

    The handshake probe is C# compiled when first used, under Windows PowerShell 5.1 and
    PowerShell 7 alike. The cipher is named the way each edition can name it: a suite -
    TLS_AES_256_GCM_SHA384 - under 7, and algorithm and strength under 5.1.

    Exit code: 0 = every instance negotiated (or -ClientOnly), 1 = one or more did not,
    2 = could not get that far.

.PARAMETER SqlInstance
    The instances to probe: SQL01, 'SQL01\SALES', 'SQL01,14330'. Several can be given, which is
    worth doing when a whole estate is out of support and you want to know which boxes will be
    trouble before you need them. A named instance with no port is looked up through SQL Browser.

.PARAMETER ServerList
    A text file of instances, one per line. Blank lines and lines starting with # are ignored.

.PARAMETER ConnectTimeoutSeconds
    How long to wait for the socket and each handshake. Default 10.

.PARAMETER ClientOnly
    Skip the server and only report what this machine is willing to negotiate, by handshaking with
    itself. Useful for proving the client is not the problem.

.PARAMETER SelfTest
    Check the reasoning - how each combination of handshake results is read - without a server or a
    socket.

.EXAMPLE
    .\Test-SqlTlsHandshake.ps1 LEGACYSERVER2008R2

.EXAMPLE
    .\Test-SqlTlsHandshake.ps1 -SqlInstance 'OLDSQL\SALES' -ConnectTimeoutSeconds 20

.EXAMPLE
    .\Test-SqlTlsHandshake.ps1 -ServerList .\legacy-servers.txt
    # which of them a current client can still talk to, before you need any of them to work

.NOTES
    Molehill Data Services. Read-only, unauthenticated, and it never sends a login packet.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)] [Alias('ComputerName')] [string[]] $SqlInstance,
    [string] $ServerList,
    [ValidateRange(1, 120)] [int] $ConnectTimeoutSeconds = 10,
    [switch] $ClientOnly,
    [switch] $SelfTest
)

$ErrorActionPreference = 'Stop'

$manifest = Join-Path $PSScriptRoot '..\MolehillTools\MolehillTools.psd1'
if (-not (Test-Path -LiteralPath $manifest)) {
    Write-Host '  MolehillTools is not where this script expects it.' -ForegroundColor Red
    Write-Host "  Looked for: $manifest" -ForegroundColor Gray
    Write-Host '  Copy the MolehillTools folder alongside Tools, or import it yourself and call Test-MhSqlTlsHandshake.' -ForegroundColor Gray
    exit 2
}
# not -Force: one shim can call another - the sample screen calls the export - and a forced
# re-import would reset the module underneath the caller, discarding everything it holds. A
# scripted run of the sample screen lost its input halfway through before this was guarded.
if (-not (Get-Module MolehillTools)) { Import-Module $manifest }

if ($SelfTest) {
    $results = Invoke-MhSelfTest -ModuleOnly -Name 'Test-MhSqlTlsHandshake'
    if (@($results | Where-Object { $_.Failed -gt 0 }).Count) { exit 1 }
    exit 0
}

$arguments = @{ ConnectTimeoutSeconds = $ConnectTimeoutSeconds }
foreach ($name in 'SqlInstance', 'ServerList', 'ClientOnly') {
    if ($PSBoundParameters.ContainsKey($name)) { $arguments[$name] = $PSBoundParameters[$name] }
}

try {
    $probed = Test-MhSqlTlsHandshake @arguments
}
catch {
    Write-Error -ErrorRecord $_ -ErrorAction Continue
    exit 2
}

# nothing comes back from -ClientOnly, or when no instance was given: the client report is the
# whole answer in that case and there is nothing to have failed
if (-not $probed) { exit 0 }
exit $(if (@($probed | Where-Object { -not $_.Ok }).Count) { 1 } else { 0 })
