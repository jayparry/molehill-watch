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
    The instance to probe: SQL01, 'SQL01\SALES' or 'SQL01,14330'. A named instance with no port is
    looked up through SQL Browser.

.PARAMETER ConnectTimeoutSeconds
    How long to wait for the socket and each handshake. Default 10.

.PARAMETER ClientOnly
    Skip the server and only report what this machine is willing to negotiate, by handshaking with
    itself. Useful for proving the client is not the problem.

.EXAMPLE
    .\Test-SqlTlsHandshake.ps1 LEGACYSERVER2008R2

.EXAMPLE
    .\Test-SqlTlsHandshake.ps1 -SqlInstance 'OLDSQL\SALES' -ConnectTimeoutSeconds 20

.NOTES
    Molehill Data Services. Read-only, unauthenticated, and it never sends a login packet.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string] $SqlInstance,
    [ValidateRange(1, 120)] [int] $ConnectTimeoutSeconds = 10,
    [switch] $ClientOnly
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
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
                            try { r.CertKeyBits = c2.PublicKey.Key.KeySize; } catch { r.CertKeyBits = 0; }
                        }
                        return true;      // we are measuring the handshake, not trusting anything
                    });
                ssl.AuthenticateAsClient(host, null, asked, false);
                r.Ok = true;
                r.Negotiated = ssl.SslProtocol.ToString();
                r.Cipher = ssl.CipherAlgorithm + " " + ssl.CipherStrength + "-bit, " + ssl.HashAlgorithm;
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
                        r.Cipher = s.CipherAlgorithm + " " + s.CipherStrength + "-bit";
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
'@ -ReferencedAssemblies System.Net, System.Security

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
# What this machine will agree to, on its own
#==============================================================================
Write-Host ''
Write-Host '  SQL Server TLS handshake  ' -NoNewline -ForegroundColor Black -BackgroundColor Cyan
Write-Host ("  {0}   {1}" -f $(if ($SqlInstance) { $SqlInstance } else { 'this machine only' }), (Get-Date).ToString('ddd dd MMM HH:mm'))
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
Write-Line '    (the client side is rarely the problem; this is here so it can be ruled out)' 'DarkGray'
}
finally {
    if ($probeCert) { Remove-Item -LiteralPath $probeCert.PSPath -Force -ErrorAction SilentlyContinue }
}

if ($ClientOnly -or -not $SqlInstance) {
    Write-Host ''
    if (-not $SqlInstance) { Write-Line '  Give an instance name to probe a server as well.' 'Yellow' }
    Write-Host ''
    exit 0
}

#==============================================================================
# The instance
#==============================================================================
$parts = Split-SqlInstanceName -Instance $SqlInstance
$port = $parts.Port
if ($parts.Instance -and $port -eq 0) {
    $port = Get-SqlBrowserPort -Computer $parts.Computer -Instance $parts.Instance
    if ($port -eq 0) {
        Write-Host ''
        Write-Line ("  SQL Browser did not say which port '{0}' is on. Give it directly, as SERVER,PORT." -f $parts.Instance) 'Red'
        Write-Host ''
        exit 2
    }
    Write-Line ("  SQL Browser says {0} listens on {1}" -f $parts.Instance, $port) 'DarkGray'
}

Write-Host ''
Write-Line ("  Handshaking with {0} on port {1}" -f $parts.Computer, $port) 'White'

$results = @()
foreach ($p in $protocols) {
    $r = [Molehill.SqlTls]::Probe($parts.Computer, $port, $p.Value, $p.Name, $ConnectTimeoutSeconds)
    $results += $r
    if ($r.Ok) {
        Write-Verdict 'OK' ("{0,-16} negotiated {1}, {2}" -f $p.Name, $r.Negotiated, $r.Cipher) 'Green'
    }
    else {
        Write-Verdict 'FAIL' ("{0,-16} {1}" -f $p.Name, $r.Error) 'Red'
    }
    if ($p.Note -and -not $r.Ok) { Write-Line ("          ({0})" -f $p.Note) 'DarkGray' }
}

$encryption = @($results | Where-Object { $_.Encryption } | Select-Object -First 1)
if ($encryption.Count) {
    Write-Host ''
    Write-Line ('  The instance says encryption is: ' + $encryption[0].Encryption) 'Gray'
}

$withCert = @($results | Where-Object { $_.CertSubject } | Select-Object -First 1)
if ($withCert.Count) {
    $c = $withCert[0]
    Write-Host ''
    Write-Line '  The certificate it presents' 'White'
    Write-Line ('    subject    {0}' -f $c.CertSubject) 'Gray'
    Write-Line ('    issuer     {0}{1}' -f $c.CertIssuer, $(if ($c.CertSelfSigned) { '  (self-signed, which is normal for SQL Server)' } else { '' })) 'Gray'
    Write-Line ('    signature  {0}' -f $c.CertAlgorithm) $(if ($c.CertAlgorithm -match 'sha1|md5') { 'Yellow' } else { 'Gray' })
    Write-Line ('    key        {0}-bit' -f $c.CertKeyBits) $(if ($c.CertKeyBits -gt 0 -and $c.CertKeyBits -lt 2048) { 'Yellow' } else { 'Gray' })
    Write-Line ('    valid      {0:dd MMM yyyy} to {1:dd MMM yyyy}' -f $c.CertFrom, $c.CertTo) $(if ($c.CertTo -lt (Get-Date)) { 'Red' } else { 'Gray' })
}

#==============================================================================
# What it means
#==============================================================================
$default = @($results | Where-Object { $_.Asked -eq 'Windows default' })[0]
$anyOk = @($results | Where-Object { $_.Ok })
$named = @($results | Where-Object { $_.Ok -and $_.Asked -ne 'Windows default' })

Write-Host ''
Write-Line '  What this means' 'White'
if ($default.Ok) {
    Write-Line ("    The handshake works the way a normal client does it, over {0}. Encryption is not what is" -f $default.Negotiated) 'Green'
    Write-Line '    stopping you: look at the login instead - the account, its permissions, or the database.' 'Green'
}
elseif ($named.Count) {
    $best = ($named | ForEach-Object { $_.Asked }) -join ', '
    Write-Line ("    The instance can only do {0}, and a client asking Windows for its default is not offered it." -f $best) 'Yellow'
    Write-Line '    Two ways out, and the first is usually right:' 'Yellow'
    Write-Line '      1. Run the tool from a machine whose Windows still offers that version by default - often' 'Gray'
    Write-Line '         the destination server itself, which is where a restore wants to run anyway.' 'Gray'
    Write-Line '      2. Allow it on this machine, which weakens its TLS policy for everything:' 'Gray'
    Write-Line '           reg add "HKLM\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.0\Client" /v Enabled /t REG_DWORD /d 1 /f' 'DarkCyan'
    Write-Line '           reg add "HKLM\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.0\Client" /v DisabledByDefault /t REG_DWORD /d 0 /f' 'DarkCyan'
    Write-Line '         then restart PowerShell. To undo it, set Enabled to 0 and DisabledByDefault to 1.' 'Gray'
    Write-Line '      3. Or patch the instance: KB3135244 adds TLS 1.2 to SQL Server 2008, 2008 R2 and 2012, on' 'Gray'
    Write-Line '         specific builds per service pack. Check its build against that article.' 'Gray'
}
else {
    Write-Line '    No TLS version worked at all, so this is not about the version.' 'Red'
    $errors = (($results | ForEach-Object { $_.Error }) -join ' ')
    if ($errors -match 'common algorithm') {
        Write-Line '    "No common algorithm" means no cipher suite in common. Either the instance only offers suites' 'Yellow'
        Write-Line '    this Windows build has retired, or its certificate is too weak for the client to accept:' 'Yellow'
        if ($withCert.Count -and ($withCert[0].CertKeyBits -lt 2048 -or $withCert[0].CertAlgorithm -match 'sha1')) {
            Write-Line ('      the certificate above is {0}-bit {1}, which modern clients often refuse.' -f $withCert[0].CertKeyBits, $withCert[0].CertAlgorithm) 'Yellow'
            Write-Line '      A SQL Server certificate can be replaced: give the instance a 2048-bit SHA256 certificate' 'Gray'
            Write-Line '      in Configuration Manager, or let it regenerate one on a patched build.' 'Gray'
        }
        Write-Line '      Get-TlsCipherSuite shows what this machine offers; Enable-TlsCipherSuite adds one back.' 'Gray'
    }
    elseif ($errors -match 'closed the connection|forcibly closed|did not answer') {
        Write-Line '    The instance accepted the socket and then dropped it. That is usually encryption being' 'Yellow'
        Write-Line '    refused outright, or something between the two machines interfering with the handshake.' 'Yellow'
    }
    elseif ($errors -match 'no answer on') {
        Write-Line '    Nothing answered on that port, so there is nothing to negotiate with yet.' 'Yellow'
    }
}
Write-Host ''

if ($anyOk.Count) { exit 0 }
exit 1
