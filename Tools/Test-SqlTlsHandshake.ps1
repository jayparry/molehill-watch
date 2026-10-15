#Requires -Version 5.1

<#
.SYNOPSIS
    Shows exactly how a SQL Server instance and this machine negotiate encryption: which TLS
    versions are agreed or refused, what cipher is chosen, and what the instance's certificate
    actually is. For when a connection fails with a TLS or certificate error and the message does
    not say why.

.DESCRIPTION
    Molehill Data Services

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
      Nothing works, "not possess a common algorithm" with a
      1024-bit or SHA1 certificate                             -> the certificate is too weak for
                                                                 this client's policy
      "Windows default" fails where naming TLS 1.0 works        -> TLS 1.0 is present but off by
                                                                 default here, which is what most
                                                                 clients ask for

    Exit code: 0 = at least one handshake succeeded, 1 = none did, 2 = could not get that far.

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
    Check the script's own reasoning - how it reads each combination of handshake results - without
    a server or a socket.

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

<#
  The assemblies the probe's C# has to be compiled against.

  Naming them by hand is how this used to be wrong: "System.Net" on .NET Framework is a facade that
  forwards SslProtocols to System.Net.Primitives, so the compile failed with "the type name
  'SslProtocols' could not be found" - intermittently, depending on what else had been loaded.

  Asking the runtime where each type lives does not work either, and the reason is worth keeping:
  on .NET a type like System.Threading.Thread lives in System.Private.CoreLib at run time, and the
  compiler will not take a reference to that - it wants the reference assembly, System.Threading.
  Thread.dll, which the type itself never mentions.

  So: on .NET, point the compiler at the framework's own assemblies, which is where the reference
  assemblies are. On .NET Framework the simple names are enough and always have been.
#>
function Get-TlsProbeReferences {
    if ($PSVersionTable.PSEdition -ne 'Core') {
        return @('System', 'System.Core', 'System.Net', 'System.Security')
    }

    $references = New-Object System.Collections.Generic.List[string]
    $frameworkDir = [System.IO.Path]::GetDirectoryName([object].Assembly.Location)
    if ($frameworkDir -and (Test-Path -LiteralPath $frameworkDir)) {
        foreach ($file in (Get-ChildItem -LiteralPath $frameworkDir -Filter 'System*.dll' -ErrorAction SilentlyContinue)) {
            # never System.Private.*: referencing the implementation assembly alongside the
            # facades that forward into it is what produces "the type name 'Thread' could not be
            # found ... this type has been forwarded", with the assembly right there in the list
            if ($file.Name -like 'System.Private.*') { continue }
            # the folder holds native libraries as well, and handing one to the compiler is an
            # error rather than something it ignores: "PE image doesn't contain managed metadata"
            try { $null = [System.Reflection.AssemblyName]::GetAssemblyName($file.FullName) }
            catch { continue }
            $references.Add($file.FullName)
        }
        $netstandard = Join-Path $frameworkDir 'netstandard.dll'
        if (Test-Path -LiteralPath $netstandard) { $references.Add($netstandard) }
    }
    if ($references.Count -eq 0) {
        throw 'Could not find the framework assemblies to compile the TLS probe against.'
    }
    $references.ToArray()
}

<#
  The C# is a template in one respect only: how to name the cipher that was negotiated.

  SslStream.CipherAlgorithm, CipherStrength and HashAlgorithm are obsolete on .NET and reported as
  errors rather than warnings, and NegotiatedCipherSuite - which replaces them - does not exist on
  .NET Framework at all. One line each way, chosen here, rather than a tool that compiles on one
  edition and not the other. The modern one is the better answer anyway: a suite name like
  TLS_AES_256_GCM_SHA384 says more than "Aes 256-bit, Sha384".
#>
$cipherLine = if ($PSVersionTable.PSEdition -eq 'Core') {
    'r.Cipher = ssl.NegotiatedCipherSuite.ToString();'
} else {
    'r.Cipher = ssl.CipherAlgorithm + " " + ssl.CipherStrength + "-bit, " + ssl.HashAlgorithm;'
}
$cipherLineLocal = if ($PSVersionTable.PSEdition -eq 'Core') {
    'r.Cipher = s.NegotiatedCipherSuite.ToString();'
} else {
    'r.Cipher = s.CipherAlgorithm + " " + s.CipherStrength + "-bit";'
}

$probeSource = @'
using System;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using System.Threading;

namespace Molehill
{
    // During a pre-login exchange the TLS records are carried inside TDS packets of type 0x12.
    // SslStream knows nothing about that, so this sits in between and adds or strips the 8-byte
    // TDS header until the handshake is done.
    internal class TdsHandshakeStream : Stream
    {
        private readonly Stream _inner;
        private byte[] _payload = new byte[0];
        private int _position;
        public bool Framing = true;

        public TdsHandshakeStream(Stream inner) { _inner = inner; }

        private byte[] ReadExactly(int count)
        {
            byte[] buffer = new byte[count];
            int got = 0;
            while (got < count)
            {
                int n = _inner.Read(buffer, got, count - got);
                if (n <= 0) throw new IOException("the instance closed the connection during the handshake");
                got += n;
            }
            return buffer;
        }

        public override int Read(byte[] buffer, int offset, int count)
        {
            if (!Framing) return _inner.Read(buffer, offset, count);
            if (_position >= _payload.Length)
            {
                byte[] header = ReadExactly(8);
                int length = (header[2] << 8) | header[3];
                if (length < 8) throw new IOException("the instance sent a malformed TDS packet");
                _payload = ReadExactly(length - 8);
                _position = 0;
            }
            int take = Math.Min(count, _payload.Length - _position);
            Array.Copy(_payload, _position, buffer, offset, take);
            _position += take;
            return take;
        }

        public override void Write(byte[] buffer, int offset, int count)
        {
            if (!Framing) { _inner.Write(buffer, offset, count); return; }
            int sent = 0;
            while (sent < count)
            {
                int chunk = Math.Min(4088, count - sent);
                byte[] packet = new byte[8 + chunk];
                packet[0] = 0x12;                       // PRELOGIN
                packet[1] = 0x01;                       // end of message
                packet[2] = (byte)((8 + chunk) >> 8);
                packet[3] = (byte)((8 + chunk) & 0xFF);
                Array.Copy(buffer, offset + sent, packet, 8, chunk);
                _inner.Write(packet, 0, packet.Length);
                _inner.Flush();
                sent += chunk;
            }
        }

        public override void Flush() { _inner.Flush(); }
        public override bool CanRead { get { return true; } }
        public override bool CanWrite { get { return true; } }
        public override bool CanSeek { get { return false; } }
        public override long Length { get { throw new NotSupportedException(); } }
        public override long Position { get { throw new NotSupportedException(); } set { throw new NotSupportedException(); } }
        public override long Seek(long o, SeekOrigin s) { throw new NotSupportedException(); }
        public override void SetLength(long v) { throw new NotSupportedException(); }
    }

    public class HandshakeResult
    {
        public bool Ok;
        public string Asked;
        public string Negotiated;
        public string Cipher;
        public string Error;
        public string Encryption;
        public string CertSubject;
        public string CertIssuer;
        public string CertAlgorithm;
        public int CertKeyBits;
        public DateTime CertFrom;
        public DateTime CertTo;
        public bool CertSelfSigned;
    }

    public static class SqlTls
    {
        private static string Innermost(Exception ex)
        {
            while (ex.InnerException != null) ex = ex.InnerException;
            string m = ex.Message;
            int nl = m.IndexOf('\n');
            return (nl > 0 ? m.Substring(0, nl) : m).Trim();
        }

        // PRELOGIN with VERSION and ENCRYPTION, asking for encryption so the instance starts TLS
        private static byte[] PreloginPacket()
        {
            byte[] payload = new byte[11 + 6 + 1];
            int table = 0;
            payload[table++] = 0x00;                    // VERSION
            payload[table++] = 0x00; payload[table++] = 11;
            payload[table++] = 0x00; payload[table++] = 6;
            payload[table++] = 0x01;                    // ENCRYPTION
            payload[table++] = 0x00; payload[table++] = 17;
            payload[table++] = 0x00; payload[table++] = 1;
            payload[table++] = 0xFF;                    // TERMINATOR
            payload[11] = 11; payload[12] = 0; payload[13] = 0; payload[14] = 0; payload[15] = 0; payload[16] = 0;
            payload[17] = 0x01;                         // ENCRYPT_ON: we would like encryption

            byte[] packet = new byte[8 + payload.Length];
            packet[0] = 0x12; packet[1] = 0x01;
            packet[2] = (byte)((8 + payload.Length) >> 8);
            packet[3] = (byte)((8 + payload.Length) & 0xFF);
            Array.Copy(payload, 0, packet, 8, payload.Length);
            return packet;
        }

        private static string EncryptionName(byte value)
        {
            switch (value)
            {
                case 0x00: return "off (encryption available, not required)";
                case 0x01: return "on (encryption available and in use)";
                case 0x02: return "not supported by the instance";
                case 0x03: return "required by the instance";
                default: return "unrecognised value " + value;
            }
        }

        public static HandshakeResult Probe(string host, int port, SslProtocols asked, string askedName, int timeoutSeconds)
        {
            HandshakeResult r = new HandshakeResult();
            r.Asked = askedName;
            TcpClient tcp = new TcpClient();
            try
            {
                IAsyncResult connecting = tcp.BeginConnect(host, port, null, null);
                if (!connecting.AsyncWaitHandle.WaitOne(timeoutSeconds * 1000))
                    throw new IOException("no answer on " + host + ":" + port + " within " + timeoutSeconds + "s");
                tcp.EndConnect(connecting);
                tcp.ReceiveTimeout = timeoutSeconds * 1000;
                tcp.SendTimeout = timeoutSeconds * 1000;

                NetworkStream raw = tcp.GetStream();
                byte[] prelogin = PreloginPacket();
                raw.Write(prelogin, 0, prelogin.Length);
                raw.Flush();

                // the reply is one TDS packet; the ENCRYPTION option says where the instance stands
                byte[] header = new byte[8];
                int got = 0;
                while (got < 8)
                {
                    int n = raw.Read(header, got, 8 - got);
                    if (n <= 0) throw new IOException("the instance closed the connection without answering PRELOGIN");
                    got += n;
                }
                int length = ((header[2] << 8) | header[3]) - 8;
                byte[] body = new byte[length];
                got = 0;
                while (got < length)
                {
                    int n = raw.Read(body, got, length - got);
                    if (n <= 0) throw new IOException("the instance closed the connection mid-answer");
                    got += n;
                }
                for (int i = 0; i + 4 < body.Length; i += 5)
                {
                    if (body[i] == 0xFF) break;
                    int offset = (body[i + 1] << 8) | body[i + 2];
                    int len = (body[i + 3] << 8) | body[i + 4];
                    if (body[i] == 0x01 && len >= 1 && offset < body.Length)
                        r.Encryption = EncryptionName(body[offset]);
                }
                if (r.Encryption == null) r.Encryption = "the instance did not say";

                TdsHandshakeStream framed = new TdsHandshakeStream(raw);
                SslStream ssl = new SslStream(framed, false,
                    delegate(object a, X509Certificate cert, X509Chain chain, SslPolicyErrors errors)
                    {
                        if (cert != null)
                        {
                            X509Certificate2 c2 = new X509Certificate2(cert);
                            r.CertSubject = c2.Subject;
                            r.CertIssuer = c2.Issuer;
                            r.CertAlgorithm = c2.SignatureAlgorithm != null ? c2.SignatureAlgorithm.FriendlyName : "(unknown)";
                            r.CertFrom = c2.NotBefore;
                            r.CertTo = c2.NotAfter;
                            r.CertSelfSigned = (c2.Subject == c2.Issuer);
                            r.CertKeyBits = 0;
                        try {
                            // PublicKey.Key is obsolete on .NET and an error, not a warning, and
                            // it only ever understood RSA: an ECDSA certificate threw and came
                            // back as nought bits
                            var rsaKey = c2.GetRSAPublicKey();
                            if (rsaKey != null) { r.CertKeyBits = rsaKey.KeySize; }
                            else {
                                var ecKey = c2.GetECDsaPublicKey();
                                if (ecKey != null) { r.CertKeyBits = ecKey.KeySize; }
                            }
                        } catch { r.CertKeyBits = 0; }
                        }
                        return true;      // we are measuring the handshake, not trusting anything
                    });
                ssl.AuthenticateAsClient(host, null, asked, false);
                r.Ok = true;
                r.Negotiated = ssl.SslProtocol.ToString();
                /*CIPHER*/
            }
            catch (Exception ex) { r.Error = Innermost(ex); }
            finally { try { tcp.Close(); } catch { } }
            return r;
        }

        // this machine handshaking with itself, to show what the client alone will agree to
        public static HandshakeResult Loopback(X509Certificate2 cert, SslProtocols serverOffers, SslProtocols clientAsks, string askedName)
        {
            HandshakeResult r = new HandshakeResult();
            r.Asked = askedName;
            TcpListener listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            int port = ((IPEndPoint)listener.LocalEndpoint).Port;
            string serverSide = null;

            Thread server = new Thread(delegate()
            {
                try
                {
                    using (TcpClient c = listener.AcceptTcpClient())
                    using (SslStream s = new SslStream(c.GetStream(), false))
                        s.AuthenticateAsServer(cert, false, serverOffers, false);
                }
                catch (Exception ex) { serverSide = Innermost(ex); }
            });
            server.IsBackground = true;
            server.Start();

            try
            {
                using (TcpClient c = new TcpClient())
                {
                    c.Connect(IPAddress.Loopback, port);
                    using (SslStream s = new SslStream(c.GetStream(), false,
                               delegate(object a, X509Certificate b, X509Chain d, SslPolicyErrors e) { return true; }))
                    {
                        s.AuthenticateAsClient("molehill-tls-probe", null, clientAsks, false);
                        r.Ok = true;
                        r.Negotiated = s.SslProtocol.ToString();
                        /*CIPHER_LOCAL*/
                    }
                }
            }
            catch (Exception ex)
            {
                r.Error = Innermost(ex);
                if (serverSide != null) r.Error += " (the listening side said: " + serverSide + ")";
            }
            finally { listener.Stop(); server.Join(2000); }
            return r;
        }
    }
}
'@
$probeSource = $probeSource.Replace('/*CIPHER_LOCAL*/', $cipherLineLocal).Replace('/*CIPHER*/', $cipherLine)

<#
  The probe is C# because it has to speak TDS and drive the TLS handshake itself, and that C# has
  to be compiled here.

  Under Windows PowerShell this works and is tested. Under PowerShell 7 it does not yet: the
  compiler wants reference assemblies rather than the implementation assemblies the runtime loads,
  and System.Threading.Thread comes back as "forwarded" however it is referenced. Rather than
  print a page of compiler output, say what it is and where it does work - everything else in this
  tool, the reasoning about what a result means, is checked by -SelfTest either way.
#>
try {
    Add-Type -TypeDefinition $probeSource -ReferencedAssemblies (Get-TlsProbeReferences) -ErrorAction Stop
}
catch {
    if ($SelfTest) {
        Write-Host '  NOTE: the handshake probe did not compile in this PowerShell, so only the reasoning is checked.' -ForegroundColor Yellow
        Write-Host '        Run this tool in Windows PowerShell 5.1 to use it against a server.' -ForegroundColor Gray
        Write-Host ''
        $script:ProbeUnavailable = $true
    }
    else {
        Write-Host '  This tool cannot run in this PowerShell: its handshake probe will not compile here.' -ForegroundColor Red
        Write-Host ("  " + (($_.Exception.Message -split "`r?`n")[0])) -ForegroundColor DarkGray
        Write-Host '  Run it in Windows PowerShell 5.1 instead - powershell.exe -File .\Test-SqlTlsHandshake.ps1 SERVERNAME' -ForegroundColor Yellow
        exit 2
    }
}

#==============================================================================
# Helpers
#==============================================================================
function Split-SqlInstanceName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Instance)

    $result = [pscustomobject]@{ Computer = ''; Instance = ''; Port = 0 }
    $text = ([string]$Instance).Trim()
    foreach ($prefix in 'tcp:', 'np:', 'lpc:') {
        if ($text.ToLower().StartsWith($prefix)) { $text = $text.Substring($prefix.Length); break }
    }
    $comma = $text.LastIndexOf(',')
    if ($comma -gt 0) {
        $tail = $text.Substring($comma + 1).Trim()
        if ($tail -match '^\d+$') { $result.Port = [int]$tail; $text = $text.Substring(0, $comma) }
    }
    $slash = $text.IndexOf('\')
    if ($slash -ge 0) { $result.Instance = $text.Substring($slash + 1).Trim(); $text = $text.Substring(0, $slash) }
    $computer = $text.Trim()
    if (-not $computer -or $computer -eq '.' -or $computer -eq '(local)') { $computer = 'localhost' }
    $result.Computer = $computer
    if (-not $result.Instance -and $result.Port -eq 0) { $result.Port = 1433 }
    $result
}

# SQL Browser, over UDP 1434, is the only thing that knows a named instance's port
function Get-SqlBrowserPort {
    [CmdletBinding()]
    param([string]$Computer, [string]$Instance)

    $udp = New-Object System.Net.Sockets.UdpClient
    try {
        $udp.Client.ReceiveTimeout = 2500
        $udp.Connect($Computer, 1434)
        [void]$udp.Send([byte[]](0x03), 1)
        $endpoint = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Any), 0
        $bytes = $udp.Receive([ref]$endpoint)
        if ($bytes.Length -le 3) { return 0 }
        $text = [System.Text.Encoding]::ASCII.GetString($bytes, 3, $bytes.Length - 3)
        foreach ($block in ($text -split ';;')) {
            $fields = $block -split ';'
            $map = @{}
            for ($i = 0; $i -lt $fields.Count - 1; $i += 2) { $map[$fields[$i]] = $fields[$i + 1] }
            if ($map.ContainsKey('InstanceName') -and [string]$map['InstanceName'] -eq $Instance -and $map.ContainsKey('tcp')) {
                return [int]$map['tcp']
            }
        }
        0
    }
    catch { 0 }
    finally { $udp.Close() }
}

function Write-Line([string] $Text, [string] $Colour = 'Gray') { Write-Host $Text -ForegroundColor $Colour }
function Write-Verdict([string] $Mark, [string] $Text, [string] $Colour) {
    Write-Host (' ' + $Mark.PadRight(5) + ' ') -NoNewline -ForegroundColor Black -BackgroundColor $Colour
    Write-Host " $Text"
}

$protocols = @(
    @{ Name = 'Windows default'; Value = [System.Security.Authentication.SslProtocols]::None
       Note = 'what almost every client asks for, including this toolkit' }
    @{ Name = 'TLS 1.2'; Value = [System.Security.Authentication.SslProtocols]::Tls12; Note = '' }
    @{ Name = 'TLS 1.1'; Value = [System.Security.Authentication.SslProtocols]::Tls11; Note = '' }
    @{ Name = 'TLS 1.0'; Value = [System.Security.Authentication.SslProtocols]::Tls; Note = '' }
)

#==============================================================================
# What the answers mean, kept free of sockets so -SelfTest can check it
#==============================================================================

<#
  Turns a set of handshake attempts into a diagnosis.

  The useful distinctions, in the order they matter:

    the default client got through          encryption is fine, look at the login
    only a named version got through        the instance is older than the client's default offer
    nothing got through, and we never saw
      a certificate                         the instance dropped the connection before offering one
    nothing got through, "no common
      algorithm"                            a cipher suite or the certificate itself
    nothing answered on the port            there is no instance there to negotiate with

  The distinction that matters most in practice is the third: a reset is not a refusal. An old
  SCHANNEL that cannot parse a modern ClientHello closes the socket rather than replying with a
  TLS alert, and the client reports "An existing connection was forcibly closed by the remote
  host" - which says nothing at all about the cause unless you know to read it that way.
#>
function Get-TlsVerdict {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()] [object[]] $Results,
        $Certificate,
        [AllowEmptyString()] [string] $Encryption = ''
    )

    $default = @($Results | Where-Object { $_.Asked -eq 'Windows default' })
    $defaultOk = ($default.Count -gt 0 -and $default[0].Ok)
    $namedOk = @($Results | Where-Object { $_.Ok -and $_.Asked -ne 'Windows default' })
    $errors = (@($Results | ForEach-Object { [string]$_.Error }) -join ' ')
    $actions = New-Object System.Collections.Generic.List[string]

    $weakCert = $false
    if ($Certificate -and $Certificate.CertKeyBits -gt 0) {
        $weakCert = ($Certificate.CertKeyBits -lt 2048) -or ([string]$Certificate.CertAlgorithm -match 'sha1|md5')
    }

    if ($defaultOk) {
        return [pscustomobject]@{
            Ok = $true
            Headline = 'The handshake works the way a normal client does it, over {0}. Encryption is not what is stopping you.' -f $default[0].Negotiated
            Actions = @('Look at the login instead: the account, whether it has a login on that instance, and what it can reach.')
        }
    }

    if ($namedOk.Count) {
        $best = ($namedOk | ForEach-Object { $_.Asked }) -join ', '
        $reset = ([string]$default[0].Error) -match 'forcibly closed|closed the connection|existing connection'
        $headline = if ($reset) {
            'The instance manages {0} when it is asked for by name, but it drops the connection when a client asks Windows for its default. That is an old TLS stack refusing a modern ClientHello rather than answering it.' -f $best
        }
        else {
            'The instance can only do {0}, and a client asking Windows for its default is not offered it.' -f $best
        }
        $actions.Add('Run the tool from a machine whose Windows still offers {0} by default - often the destination server itself, which is where a restore wants to run anyway.' -f $best)
        $actions.Add('Or allow it on this machine, which weakens its TLS policy for everything on it: reg add "HKLM\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\{0}\Client" /v Enabled /t REG_DWORD /d 1 /f and the same key with DisabledByDefault /d 0, then restart PowerShell. Undo it by setting Enabled 0 and DisabledByDefault 1.' -f (@($namedOk | ForEach-Object { $_.Asked }) | Select-Object -Last 1))
        $actions.Add('Or patch the instance: KB3135244 adds TLS 1.2 to SQL Server 2008, 2008 R2 and 2012, on specific builds for each service pack.')
        $actions.Add('Or take the source out of the job altogether - Restore-DatabaseCopy.ps1 -SourceHistoryFile, or Restore-LatestAzureBackup.ps1, neither of which connects to it.')
        return [pscustomobject]@{ Ok = $false; Headline = $headline; Actions = $actions.ToArray() }
    }

    if ($errors -match 'no answer on') {
        return [pscustomobject]@{
            Ok = $false
            Headline = 'Nothing answered on that port, so there is nothing to negotiate with yet.'
            Actions = @('Check the instance is running and listening on that port, and that a firewall is not in the way. Test-DatabaseStatus.ps1 and the connection checks in Restore-DatabaseCopy.ps1 cover that ground.')
        }
    }

    if ($Encryption -match 'not supported') {
        return [pscustomobject]@{
            Ok = $false
            Headline = 'The instance says it does not support encryption at all, which no current client will accept.'
            Actions = @('That is either a very old build or a broken configuration. Check the instance''s network configuration and its error log.')
        }
    }

    if ($errors -match 'common algorithm') {
        if ($weakCert) {
            return [pscustomobject]@{
                Ok = $false
                Headline = 'No cipher suite in common, and the certificate the instance presents is {0}-bit {1} - which is what modern clients refuse.' -f $Certificate.CertKeyBits, $Certificate.CertAlgorithm
                Actions = @(
                    'Give the instance a 2048-bit SHA256 certificate and point SQL Server at it in Configuration Manager. That fixes it for every client and survives patching later.',
                    'A patched build will also generate a stronger self-signed certificate of its own: KB3135244 covers SQL Server 2008, 2008 R2 and 2012.'
                )
            }
        }
        return [pscustomobject]@{
            Ok = $false
            Headline = 'No cipher suite in common: the instance only offers suites this Windows build has retired.'
            Actions = @(
                'Get-TlsCipherSuite shows what this machine offers. Enable-TlsCipherSuite puts one back, for example TLS_RSA_WITH_3DES_EDE_CBC_SHA, which weakens this machine''s policy for everything on it.',
                'Running from an older machine avoids changing anything here.'
            )
        }
    }

    if ($errors -match 'forcibly closed|closed the connection|existing connection') {
        $noCert = (-not $Certificate) -or (-not $Certificate.CertSubject)
        $headline = if ($noCert) {
            'Every attempt was dropped by the instance before it offered a certificate. It is resetting the connection rather than refusing it, which is what an old TLS stack does with a ClientHello it cannot parse.'
        }
        else {
            'Every attempt was dropped mid-handshake, after a certificate had been offered.'
        }
        $actions.Add('Try from a machine of the same era as the instance - an older Windows Server sends a smaller, plainer ClientHello that an old SCHANNEL can read. If that works, the instance is the limit, not your settings.')
        $actions.Add('Look at the instance''s SQL Server error log: it records TLS handshake failures with a reason, and it is the only place that says what the server made of it.')
        $actions.Add('Rule out anything between the two machines. A firewall or IPS inspecting TLS will reset a handshake it dislikes, and it looks exactly like this from here.')
        $actions.Add('Patch the instance if you can: KB3135244 adds TLS 1.2 to SQL Server 2008, 2008 R2 and 2012.')
        $actions.Add('Or do the job without connecting to it: Restore-DatabaseCopy.ps1 -SourceHistoryFile reads the backup history from a file exported on the server itself, and Restore-LatestAzureBackup.ps1 needs no source instance at all.')
        return [pscustomobject]@{ Ok = $false; Headline = $headline; Actions = $actions.ToArray() }
    }

    [pscustomobject]@{
        Ok = $false
        Headline = 'No TLS version worked, and the errors do not match anything this script recognises.'
        Actions = @('The errors above are what the client library said. The instance''s SQL Server error log is the other half of the story.')
    }
}

#==============================================================================
# Self test
#==============================================================================
if ($SelfTest) {
    $script:failed = 0
    function Check([string] $Name, [bool] $Ok, [string] $Detail = '') {
        if ($Ok) { Write-Host "  PASS  $Name" -ForegroundColor Green }
        else { Write-Host "  FAIL  $Name $Detail" -ForegroundColor Red; $script:failed++ }
    }
    # not R: that is the built-in alias for Invoke-History, and an alias beats a function.
    # Not $Error for a parameter name either, PowerShell already owns that one.
    function Attempt([string] $Asked, [bool] $Ok, [string] $Failure = '', [string] $Negotiated = '') {
        [pscustomobject]@{ Asked = $Asked; Ok = $Ok; Error = $Failure; Negotiated = $Negotiated }
    }
    function Cert([int] $Bits, [string] $Algorithm) {
        [pscustomobject]@{ CertSubject = 'CN=test'; CertKeyBits = $Bits; CertAlgorithm = $Algorithm }
    }
    $reset = 'An existing connection was forcibly closed by the remote host'

    Write-Host 'Test-SqlTlsHandshake self test'
    Write-Host '  instance names' -ForegroundColor Gray
    $p = Split-SqlInstanceName 'SQL01'
    Check 'a bare name is the default instance on 1433' ($p.Computer -eq 'SQL01' -and $p.Port -eq 1433)
    $p = Split-SqlInstanceName 'SQL01\SALES'
    Check 'a named instance has no port until Browser says' ($p.Instance -eq 'SALES' -and $p.Port -eq 0)
    $p = Split-SqlInstanceName 'SQL01,14330'
    Check 'a comma is a port' ($p.Port -eq 14330)
    $p = Split-SqlInstanceName 'tcp:sql01.contoso.com\SALES,1433'
    Check 'prefix, name, instance and port together' ($p.Computer -eq 'sql01.contoso.com' -and $p.Instance -eq 'SALES' -and $p.Port -eq 1433)

    Write-Host '  the verdict' -ForegroundColor Gray
    $v = Get-TlsVerdict -Results @((Attempt 'Windows default' $true '' 'Tls12'), (Attempt 'TLS 1.2' $true '' 'Tls12')) -Certificate (Cert 2048 'sha256RSA')
    Check 'a working default sends you to the login' ($v.Ok -and $v.Headline -match 'not what is stopping you')

    $v = Get-TlsVerdict -Results @((Attempt 'Windows default' $false 'handshake failed'), (Attempt 'TLS 1.2' $false 'x'), (Attempt 'TLS 1.0' $true '' 'Tls')) -Certificate (Cert 1024 'sha1RSA')
    Check 'only TLS 1.0 working blames the default offer' (-not $v.Ok -and $v.Headline -match 'only do TLS 1.0')
    Check 'and offers the older machine first' ($v.Actions[0] -match 'machine whose Windows still offers')
    Check 'and mentions the registry second, with the undo' (($v.Actions -join ' ') -match 'DisabledByDefault' -and ($v.Actions -join ' ') -match 'Undo it')
    Check 'and the no-source-needed way out' (($v.Actions -join ' ') -match 'SourceHistoryFile')

    $v = Get-TlsVerdict -Results @((Attempt 'Windows default' $false $reset), (Attempt 'TLS 1.2' $false $reset), (Attempt 'TLS 1.0' $true '' 'Tls'))
    Check 'a reset on the default but TLS 1.0 by name blames the modern ClientHello' ($v.Headline -match 'modern ClientHello' -and $v.Headline -match 'drops the connection')

    $v = Get-TlsVerdict -Results @((Attempt 'Windows default' $false $reset), (Attempt 'TLS 1.2' $false $reset), (Attempt 'TLS 1.1' $false $reset), (Attempt 'TLS 1.0' $false $reset))
    Check 'everything reset, no certificate seen, is called a reset not a refusal' (-not $v.Ok -and $v.Headline -match 'resetting the connection rather than refusing')
    Check 'and points at the error log on the instance' (($v.Actions -join ' ') -match 'SQL Server error log')
    Check 'and at anything in between' (($v.Actions -join ' ') -match 'firewall or IPS')
    Check 'and at doing the job without it' (($v.Actions -join ' ') -match 'Restore-LatestAzureBackup')

    $noAlg = 'The client and server cannot communicate, because they do not possess a common algorithm'
    $v = Get-TlsVerdict -Results @((Attempt 'Windows default' $false $noAlg), (Attempt 'TLS 1.0' $false $noAlg)) -Certificate (Cert 1024 'sha1RSA')
    Check 'no common algorithm with a weak certificate blames the certificate' ($v.Headline -match '1024-bit' -and $v.Headline -match 'sha1')
    Check 'and says to replace it' (($v.Actions -join ' ') -match '2048-bit SHA256')

    $v = Get-TlsVerdict -Results @((Attempt 'Windows default' $false $noAlg), (Attempt 'TLS 1.0' $false $noAlg)) -Certificate (Cert 4096 'sha256RSA')
    Check 'no common algorithm with a good certificate blames the cipher suites' ($v.Headline -match 'cipher suite in common' -and $v.Headline -notmatch 'certificate')
    Check 'and names the cmdlets for it' (($v.Actions -join ' ') -match 'Enable-TlsCipherSuite')

    $v = Get-TlsVerdict -Results @((Attempt 'Windows default' $false 'no answer on SQL01:1433 within 10s'))
    Check 'nothing listening is not a TLS problem at all' ($v.Headline -match 'nothing to negotiate')

    $v = Get-TlsVerdict -Results @((Attempt 'Windows default' $false $reset)) -Encryption 'not supported by the instance'
    Check 'an instance that says it cannot encrypt is its own finding' ($v.Headline -match 'does not support encryption')

    $v = Get-TlsVerdict -Results @((Attempt 'Windows default' $false 'something nobody has seen before'))
    Check 'an unrecognised error says so rather than guessing' ($v.Headline -match 'do not match anything this script recognises')

    Write-Host ''
    if ($script:failed -eq 0) { Write-Host 'All self tests passed.' -ForegroundColor Green; exit 0 }
    Write-Host "$script:failed self test(s) failed." -ForegroundColor Red
    exit 1
}

#==============================================================================
# What this machine will agree to, on its own
#==============================================================================
$instances = @($SqlInstance | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
if ($instances.Count -eq 1 -and $instances[0] -match ',\s*\D') {
    # powershell.exe -File turns a list into one string; a comma followed by a digit is a port
    $instances = @($instances[0] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
if ($ServerList) {
    if (-not (Test-Path -LiteralPath $ServerList)) { Write-Host "  No such list: $ServerList" -ForegroundColor Red; exit 2 }
    foreach ($line in (Get-Content -LiteralPath $ServerList)) {
        $t = $line.Trim()
        if ($t -and -not $t.StartsWith('#')) { $instances += $t }
    }
}
$instances = @($instances | Select-Object -Unique)

Write-Host ''
Write-Host '  SQL Server TLS handshake  ' -NoNewline -ForegroundColor Black -BackgroundColor Cyan
Write-Host ("  {0}   {1}" -f $(if ($instances.Count) { $instances -join ', ' } else { 'this machine only' }), (Get-Date).ToString('ddd dd MMM HH:mm'))
Write-Host ''
Write-Line ("  This machine: {0}, PowerShell {1}" -f (Get-CimInstance Win32_OperatingSystem).Caption, $PSVersionTable.PSVersion) 'DarkGray'

Write-Host ''
Write-Line '  What this client will agree to, handshaking with itself' 'White'
# a throwaway certificate for the loopback handshake, removed again at the end of the run
$probeCert = New-SelfSignedCertificate -Subject 'CN=molehill-tls-probe' -CertStoreLocation Cert:\CurrentUser\My `
    -KeyAlgorithm RSA -KeyLength 2048 -NotAfter (Get-Date).AddDays(1)
try {
    foreach ($p in $protocols) {
        if ($p.Name -eq 'Windows default') { continue }
        $r = [Molehill.SqlTls]::Loopback($probeCert, $p.Value, [System.Security.Authentication.SslProtocols]::None, $p.Name)
        if ($r.Ok) { Write-Line ('    ok    {0,-16} a server offering only this is acceptable to a default client ({1})' -f $p.Name, $r.Cipher) 'Gray' }
        else { Write-Line ('    off   {0,-16} a default client here will not use it: {1}' -f $p.Name, $r.Error) 'Yellow' }
    }

    # the suites an old instance is likely to be limited to, since a missing one looks like a
    # protocol problem and is not
    $legacy = 'TLS_RSA_WITH_AES_256_CBC_SHA', 'TLS_RSA_WITH_AES_128_CBC_SHA', 'TLS_RSA_WITH_3DES_EDE_CBC_SHA', 'TLS_RSA_WITH_RC4_128_SHA'
    $missing = @($legacy | Where-Object { -not (Get-TlsCipherSuite -Name $_ -ErrorAction SilentlyContinue) })
    if ($missing.Count -eq 0) { Write-Line ('    ok    {0,-16} all of them are enabled here' -f 'old ciphers') 'Gray' }
    else { Write-Line ('    off   {0,-16} not enabled here: {1}' -f 'old ciphers', ($missing -join ', ')) 'Yellow' }
    Write-Line '    (the client is rarely the problem; this is here so it can be ruled out)' 'DarkGray'
}
finally {
    if ($probeCert) { Remove-Item -LiteralPath $probeCert.PSPath -Force -ErrorAction SilentlyContinue }
}

if ($ClientOnly -or $instances.Count -eq 0) {
    Write-Host ''
    if ($instances.Count -eq 0) { Write-Line '  Give an instance name to probe a server as well.' 'Yellow' }
    Write-Host ''
    exit 0
}

#==============================================================================
# Each instance
#==============================================================================
$anySucceeded = $false
$anyFailed = $false

foreach ($instance in $instances) {
    $parts = Split-SqlInstanceName -Instance $instance
    $port = $parts.Port
    Write-Host ''
    Write-Line ("  {0}" -f $instance) 'White'

    if ($parts.Instance -and $port -eq 0) {
        $port = Get-SqlBrowserPort -Computer $parts.Computer -Instance $parts.Instance
        if ($port -eq 0) {
            Write-Verdict 'FAIL' ("SQL Browser did not say which port '{0}' is on. Give it directly, as SERVER,PORT." -f $parts.Instance) 'Red'
            $anyFailed = $true
            continue
        }
        Write-Line ("    SQL Browser says {0} listens on {1}" -f $parts.Instance, $port) 'DarkGray'
    }
    Write-Line ("    handshaking with {0} on port {1}" -f $parts.Computer, $port) 'DarkGray'

    $results = @()
    foreach ($p in $protocols) {
        $r = [Molehill.SqlTls]::Probe($parts.Computer, $port, $p.Value, $p.Name, $ConnectTimeoutSeconds)
        $results += $r
        if ($r.Ok) { Write-Verdict 'OK' ("{0,-16} negotiated {1}, {2}" -f $p.Name, $r.Negotiated, $r.Cipher) 'Green' }
        else {
            Write-Verdict 'FAIL' ("{0,-16} {1}" -f $p.Name, $r.Error) 'Red'
            if ($p.Note) { Write-Line ("          ({0})" -f $p.Note) 'DarkGray' }
        }
    }

    $encryption = @($results | Where-Object { $_.Encryption } | Select-Object -First 1)
    $stance = if ($encryption.Count) { $encryption[0].Encryption } else { '' }
    if ($stance) { Write-Line ('    the instance says encryption is: ' + $stance) 'Gray' }

    $withCert = @($results | Where-Object { $_.CertSubject } | Select-Object -First 1)
    $certificate = if ($withCert.Count) { $withCert[0] } else { $null }
    if ($certificate) {
        Write-Line '    the certificate it presents' 'White'
        Write-Line ('      subject    {0}' -f $certificate.CertSubject) 'Gray'
        Write-Line ('      issuer     {0}{1}' -f $certificate.CertIssuer, $(if ($certificate.CertSelfSigned) { '  (self-signed, which is normal for SQL Server)' } else { '' })) 'Gray'
        Write-Line ('      signature  {0}' -f $certificate.CertAlgorithm) $(if ($certificate.CertAlgorithm -match 'sha1|md5') { 'Yellow' } else { 'Gray' })
        Write-Line ('      key        {0}-bit' -f $certificate.CertKeyBits) $(if ($certificate.CertKeyBits -gt 0 -and $certificate.CertKeyBits -lt 2048) { 'Yellow' } else { 'Gray' })
        Write-Line ('      valid      {0:dd MMM yyyy} to {1:dd MMM yyyy}' -f $certificate.CertFrom, $certificate.CertTo) $(if ($certificate.CertTo -lt (Get-Date)) { 'Red' } else { 'Gray' })
    }
    elseif (@($results | Where-Object { $_.Ok }).Count -eq 0) {
        Write-Line '    no certificate was seen: the connection was dropped before one was offered' 'Yellow'
    }

    $verdict = Get-TlsVerdict -Results $results -Certificate $certificate -Encryption $stance
    Write-Host ''
    Write-Line '    what this means' 'White'
    Write-Line ('      ' + $verdict.Headline) $(if ($verdict.Ok) { 'Green' } else { 'Yellow' })
    if (-not $verdict.Ok) {
        Write-Line '    what to try' 'White'
        $n = 0
        foreach ($action in $verdict.Actions) {
            $n++
            Write-Line ('      {0}. {1}' -f $n, $action) 'Gray'
        }
    }
    if ($verdict.Ok) { $anySucceeded = $true } else { $anyFailed = $true }
}

Write-Host ''
if ($instances.Count -gt 1) {
    Write-Line ('  {0} instance(s) probed, {1} negotiated cleanly' -f $instances.Count, $(if ($anySucceeded) { @($instances).Count - [int]$anyFailed } else { 0 })) 'DarkGray'
    Write-Host ''
}

if ($anyFailed) { exit 1 }
exit 0
