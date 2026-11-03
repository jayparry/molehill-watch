<#
    PDF primitives: font metrics, text measurement, string escaping, and the file itself.

    Shared by the patch report's table and by Convert-MhMarkdownToPdf, so there is one set of
    metrics and one assembler in the module rather than one per document.

    Nothing is embedded. The base-14 fonts - Helvetica, Helvetica-Bold, Helvetica-Oblique and
    Courier - are the ones every reader already has, which is the whole point: these files open on
    a locked-down server with nothing installed on it, and they look the same there as on a laptop.

    A PDF places every string itself. Nothing wraps text, nothing measures it, and a string written
    past the edge of the page is simply written past the edge of the page. That is why the width
    tables below exist.
#>

$ErrorActionPreference = 'Stop'

# Widths per 1000 units for the printable ASCII range 32-126, from Adobe's own metrics for each
# font. Helvetica-Oblique is Helvetica sheared, so it shares the table rather than carrying a copy.
$script:MhPdfWidth = @{
    Body = @(
        278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278,
        556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556,
        1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778,
        667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556,
        333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556,
        556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584
    )
    Bold = @(
        278, 333, 474, 556, 556, 889, 722, 238, 333, 333, 389, 584, 278, 333, 278, 278,
        556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 333, 333, 584, 584, 584, 611,
        975, 722, 722, 722, 722, 667, 611, 778, 722, 278, 556, 722, 611, 833, 722, 778,
        667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 333, 278, 333, 584, 556,
        333, 556, 611, 556, 611, 556, 333, 611, 611, 278, 278, 556, 278, 889, 611, 611,
        611, 611, 389, 556, 333, 611, 556, 778, 556, 556, 500, 389, 280, 389, 584
    )
    # Courier is monospaced: every character, including the space, is 600
    Mono = @(1..95 | ForEach-Object { 600 })
}
$script:MhPdfWidth['Italic'] = $script:MhPdfWidth['Body']

# The handful of characters above 126 that actually turn up in this estate's documents. Without
# these an em dash is measured as an average letter and the line it is on runs long - it is nearly
# twice the width of one.
#
# Keyed by what the character is in a PowerShell string, which is Unicode, and not by the
# Windows-1252 byte it is later written as: an em dash is U+2014 in the string and 0x97 in the
# file, and a table keyed by 0x97 never matches anything at all.
$script:MhPdfHighWidth = @{
    0x00A0 = 278;  0x00A3 = 556;  0x00A9 = 737;  0x00B0 = 400;  0x00B7 = 278;  0x00BD = 834
    0x2018 = 222;  0x2019 = 222;  0x201C = 333;  0x201D = 333;  0x2022 = 350
    0x2013 = 556;  0x2014 = 1000
}

# Characters Windows-1252 has no byte for, written out as what they mean rather than left to become
# a question mark. An arrow in a firewall rule - "reporting box -> targets" - is the one that
# matters here; it is in the permissions handout and would otherwise vanish from the PDF.
$script:MhPdfFold = @{
    ([string][char]0x2192) = '->'
    ([string][char]0x2190) = '<-'
    ([string][char]0x21D2) = '=>'
    ([string][char]0x2265) = '>='
    ([string][char]0x2264) = '<='
    ([string][char]0x2260) = '<>'
    ([string][char]0x00D7) = 'x'
    ([string][char]0x2713) = 'yes'
    ([string][char]0x2717) = 'no'
    ([string][char]0x2026) = '...'
    ([string][char]0x200B) = ''
}

# Text as Windows-1252 can carry it, which is what /WinAnsiEncoding on the fonts means. Anything
# with no byte at all becomes a question mark rather than a different character, and it does so
# here - before measuring - so that what is measured is what is drawn.
function Get-MhPdfText {
    [CmdletBinding()]
    param([string] $Text)

    $out = [string]$Text
    if (-not $out) { return '' }
    foreach ($from in @($script:MhPdfFold.Keys)) {
        if ($out.Contains($from)) { $out = $out.Replace($from, $script:MhPdfFold[$from]) }
    }
    $encoding = [System.Text.Encoding]::GetEncoding(1252)
    $encoding.GetString($encoding.GetBytes($out))
}

function Get-MhPdfTextWidth {
    [CmdletBinding()]
    param(
        [string] $Text,
        [double] $Size,
        [ValidateSet('Body', 'Bold', 'Italic', 'Mono')] [string] $Font = 'Body'
    )

    $table = $script:MhPdfWidth[$Font]

    # measured as it will be written, not as it arrived: an arrow is one character here and two on
    # the page, and measuring the one before folding it is how a line ends up past the margin
    $measured = [string]$Text
    if ($measured -match '[^\x00-\x7F]') { $measured = Get-MhPdfText $measured }

    $units = 0
    foreach ($char in [char[]]$measured) {
        $code = [int]$char
        $units += $(
            if ($code -ge 32 -and $code -le 126)       { $table[$code - 32] }
            elseif ($Font -eq 'Mono')                  { 600 }
            elseif ($script:MhPdfHighWidth.ContainsKey($code)) { $script:MhPdfHighWidth[$code] }
            else                                       { 556 }
        )
    }
    ($units / 1000.0) * $Size
}

# Text broken into lines that fit a column, on word boundaries where it can and mid-word where a
# single word is longer than the column - a file path or a registry key, usually. Left whole, one
# of those runs out of its column and across the next one.
function Split-MhPdfText {
    [CmdletBinding()]
    param(
        [string] $Text,
        [double] $Width,
        [double] $Size,
        [ValidateSet('Body', 'Bold', 'Italic', 'Mono')] [string] $Font = 'Body'
    )

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($paragraph in ([string]$Text -split "`r?`n")) {
        $current = ''
        foreach ($word in ($paragraph -split ' ' | Where-Object { $_ -ne '' })) {

            $pieces = @($word)
            if ((Get-MhPdfTextWidth -Text $word -Size $Size -Font $Font) -gt $Width) {
                $pieces = @()
                $piece = ''
                foreach ($char in [char[]]$word) {
                    if ($piece -and (Get-MhPdfTextWidth -Text ($piece + $char) -Size $Size -Font $Font) -gt $Width) {
                        $pieces += $piece
                        $piece = [string]$char
                    }
                    else { $piece += $char }
                }
                if ($piece) { $pieces += $piece }
            }

            foreach ($part in $pieces) {
                if (-not $current) { $current = $part; continue }
                if ((Get-MhPdfTextWidth -Text "$current $part" -Size $Size -Font $Font) -le $Width) { $current = "$current $part" }
                else { $lines.Add($current); $current = $part }
            }
        }
        $lines.Add($current)
    }
    # never nothing: an empty cell still takes one line, or the row heights stop lining up
    if (-not $lines.Count) { $lines.Add('') }
    $lines.ToArray()
}

# ( ) and \ end or escape a PDF string, so they are escaped.
#
# The replacement side of -replace takes backslashes literally, so '\\' there means two of them -
# which is what one backslash has to become. '\\\\' would produce four and put a stray pair into
# every Windows path in the document.
function Get-MhPdfString {
    [CmdletBinding()]
    param([string] $Text)
    '(' + ((Get-MhPdfText $Text) -replace '\\', '\\' -replace '\(', '\(' -replace '\)', '\)') + ')'
}

# one line of text, placed: the operators that actually put ink on a page
function Get-MhPdfTextOperator {
    [CmdletBinding()]
    param([string] $Text, [double] $X, [double] $Y, [double] $Size, [string] $FontRef = '/F1')
    'BT {0} {1} Tf {2} {3} Td {4} Tj ET' -f $FontRef, $Size, [math]::Round($X, 2), [math]::Round($Y, 2), (Get-MhPdfString $Text)
}

<#
    The file itself: a catalog, a page tree, the fonts, an information dictionary, and one page plus
    one content stream for each page of content.

    The cross-reference table at the end gives the byte offset of every object, so the objects are
    written in the order their numbers were handed out and each offset is recorded as it is reached.
    A reader uses those offsets to find anything at all, which makes the xref the one part of this a
    reader will refuse outright if it is wrong.

    Content streams are uncompressed: the whole file stays readable in a text editor, which is worth
    more here than the kilobytes.
#>
function New-MhPdfFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Content,
        [double] $PageWidth = 595.0,
        [double] $PageHeight = 842.0,
        [string[]] $Font = @('Helvetica', 'Helvetica-Bold'),
        [string] $Title,
        [string] $Author = 'Molehill Data Services',
        [datetime] $When = (Get-Date)
    )

    $pageCount = @($Content).Count
    if (-not $pageCount) { throw 'A PDF needs at least one page of content.' }

    # object numbers, handed out in the order they will be written so that the xref can be built by
    # recording each offset as it is reached
    $next = 3
    $fontIds = @()
    foreach ($name in $Font) { $fontIds += $next; $next++ }
    $infoId = $next; $next++
    $pageIds = @()
    $contentIds = @()
    for ($i = 0; $i -lt $pageCount; $i++) {
        $pageIds += $next; $next++
        $contentIds += $next; $next++
    }
    $totalObjects = $next - 1

    $resources = @()
    for ($i = 0; $i -lt $Font.Count; $i++) { $resources += '/F{0} {1} 0 R' -f ($i + 1), $fontIds[$i] }

    $encoding = [System.Text.Encoding]::GetEncoding(1252)
    $stream = New-Object System.IO.MemoryStream
    $offsets = @{}
    $write = {
        param($Text)
        $bytes = $encoding.GetBytes([string]$Text)
        $stream.Write($bytes, 0, $bytes.Length)
    }

    # the second line is the conventional "this file has binary in it" marker: four bytes above 127,
    # so that anything copying the file in text mode is known to have corrupted it
    & $write ("%PDF-1.4`n%" + [string][char]0xE2 + [char]0xE3 + [char]0xCF + [char]0xD3 + "`n")

    $offsets[1] = $stream.Position
    & $write "1 0 obj`n<< /Type /Catalog /Pages 2 0 R >>`nendobj`n"

    $offsets[2] = $stream.Position
    & $write ("2 0 obj`n<< /Type /Pages /Kids [{0}] /Count {1} >>`nendobj`n" -f
              (($pageIds | ForEach-Object { "$_ 0 R" }) -join ' '), $pageCount)

    for ($i = 0; $i -lt $Font.Count; $i++) {
        $offsets[$fontIds[$i]] = $stream.Position
        & $write ("{0} 0 obj`n<< /Type /Font /Subtype /Type1 /BaseFont /{1} /Encoding /WinAnsiEncoding >>`nendobj`n" -f
                  $fontIds[$i], $Font[$i])
    }

    # the title a reader shows in its own window and in a file's properties. Without it the window
    # says the file name, which for an attachment on a ticket is a temporary file's name.
    $offset = [datetimeoffset]::new($When).Offset
    $stamp = 'D:{0}{1}{2:00}''{3:00}''' -f $When.ToString('yyyyMMddHHmmss'),
             $(if ($offset.Ticks -lt 0) { '-' } else { '+' }), [math]::Abs($offset.Hours), [math]::Abs($offset.Minutes)
    $offsets[$infoId] = $stream.Position
    & $write ("{0} 0 obj`n<< /Title {1} /Author {2} /Producer {3} /CreationDate {4} >>`nendobj`n" -f
              $infoId, (Get-MhPdfString $Title), (Get-MhPdfString $Author),
              (Get-MhPdfString 'Molehill Watch'), (Get-MhPdfString $stamp))

    for ($i = 0; $i -lt $pageCount; $i++) {
        $offsets[$pageIds[$i]] = $stream.Position
        & $write ("{0} 0 obj`n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {1} {2}] /Resources << /Font << {3} >> >> /Contents {4} 0 R >>`nendobj`n" -f
                  $pageIds[$i], $PageWidth, $PageHeight, ($resources -join ' '), $contentIds[$i])

        $body = [string]$Content[$i]
        $offsets[$contentIds[$i]] = $stream.Position
        # the length is the length in bytes after encoding, not in characters
        & $write ("{0} 0 obj`n<< /Length {1} >>`nstream`n" -f $contentIds[$i], $encoding.GetByteCount($body))
        & $write $body
        & $write "`nendstream`nendobj`n"
    }

    $xrefAt = $stream.Position
    & $write ("xref`n0 {0}`n" -f ($totalObjects + 1))
    & $write "0000000000 65535 f `n"
    for ($id = 1; $id -le $totalObjects; $id++) {
        & $write ("{0:0000000000} 00000 n `n" -f [int64]$offsets[$id])
    }
    & $write ("trailer`n<< /Size {0} /Root 1 0 R /Info {1} 0 R >>`nstartxref`n{2}`n%%EOF`n" -f
              ($totalObjects + 1), $infoId, [int64]$xrefAt)

    $bytes = $stream.ToArray()
    $stream.Dispose()
    # comma: a byte array returned bare is unrolled into a stream of bytes by the pipeline
    , $bytes
}

Register-MhSelfTest -Name 'The PDF primitives' -Test {

    Test-MhSection 'the font metrics'

    foreach ($font in 'Body', 'Bold', 'Italic', 'Mono') {
        Test-MhCheck "$font has one width per printable character" ($script:MhPdfWidth[$font].Count -eq 95) `
            "$($script:MhPdfWidth[$font].Count)"
    }
    Test-MhCheck 'wide letters measure wider than narrow ones' `
        ((Get-MhPdfTextWidth -Text 'WWWWW' -Size 10) -gt (Get-MhPdfTextWidth -Text 'iiiii' -Size 10))
    Test-MhCheck 'bold is wider than regular' `
        ((Get-MhPdfTextWidth -Text 'Remote Registry' -Size 10 -Font 'Bold') -gt (Get-MhPdfTextWidth -Text 'Remote Registry' -Size 10))
    Test-MhCheck 'Courier measures every character the same' `
        ((Get-MhPdfTextWidth -Text 'iiiii' -Size 10 -Font 'Mono') -eq (Get-MhPdfTextWidth -Text 'WWWWW' -Size 10 -Font 'Mono'))
    Test-MhCheck 'a 10pt Courier character is 6 points wide' ((Get-MhPdfTextWidth -Text 'x' -Size 10 -Font 'Mono') -eq 6)
    Test-MhCheck 'twice the text is twice the width' `
        ([math]::Abs((Get-MhPdfTextWidth -Text 'abcabc' -Size 9) - 2 * (Get-MhPdfTextWidth -Text 'abc' -Size 9)) -lt 0.001)
    # measured as an average letter, an em dash comes out at half its real width and the line it is
    # on runs past the margin
    Test-MhCheck 'an em dash is measured as the wide character it is' `
        ((Get-MhPdfTextWidth -Text ([string][char]0x2014) -Size 10) -gt (Get-MhPdfTextWidth -Text 'W' -Size 10)) `
        "$(Get-MhPdfTextWidth -Text ([string][char]0x2014) -Size 10)"
    # it is written as two characters, so it has to be measured as two
    Test-MhCheck 'and an arrow is measured as the two characters it becomes' `
        ([math]::Abs((Get-MhPdfTextWidth -Text ([string][char]0x2192) -Size 10) - (Get-MhPdfTextWidth -Text '->' -Size 10)) -lt 0.001) `
        "$(Get-MhPdfTextWidth -Text ([string][char]0x2192) -Size 10) against $(Get-MhPdfTextWidth -Text '->' -Size 10)"
    Test-MhCheck 'a pound sign is measured from the table rather than guessed at' `
        ([math]::Abs((Get-MhPdfTextWidth -Text ([string][char]0xA3) -Size 10) - 5.56) -lt 0.001) `
        "$(Get-MhPdfTextWidth -Text ([string][char]0xA3) -Size 10)"

    Test-MhSection 'characters Windows-1252 cannot carry'

    Test-MhCheck 'an arrow becomes what it means' `
        ((Get-MhPdfText ('box {0} targets' -f [char]0x2192)) -ceq 'box -> targets') (Get-MhPdfText ('box {0} targets' -f [char]0x2192))
    Test-MhCheck 'an em dash is kept, because 1252 has one' `
        ((Get-MhPdfText ('one {0} two' -f [char]0x2014)) -ceq ('one {0} two' -f [char]0x2014))
    Test-MhCheck 'and so is a pound sign' ((Get-MhPdfText ([string][char]0xA3 + '950')) -ceq ([string][char]0xA3 + '950'))
    Test-MhCheck 'folding twice changes nothing further' `
        ((Get-MhPdfText (Get-MhPdfText ('a {0} b' -f [char]0x2192))) -ceq 'a -> b')
    Test-MhCheck 'something with no byte at all is visible rather than silent' `
        ((Get-MhPdfText ([string][char]0x4E2D)) -ceq '?') (Get-MhPdfText ([string][char]0x4E2D))

    Test-MhSection 'escaping, where a stray character ends the string early'

    Test-MhCheck 'a backslash becomes two, not four' ((Get-MhPdfString 'SQL01\PROD') -ceq '(SQL01\\PROD)') (Get-MhPdfString 'SQL01\PROD')
    Test-MhCheck 'brackets are escaped' ((Get-MhPdfString 'Standard Edition (64-bit)') -ceq '(Standard Edition \(64-bit\))')
    Test-MhCheck 'and a path with both survives' `
        ((Get-MhPdfString 'C:\Program Files (x86)\x') -ceq '(C:\\Program Files \(x86\)\\x)') (Get-MhPdfString 'C:\Program Files (x86)\x')

    Test-MhSection 'wrapping to a column'

    $wrapped = @(Split-MhPdfText -Text 'Give the account sysadmin on SQL Server so the report can read the key' -Width 90 -Size 8)
    Test-MhCheck 'long text is broken into several lines' ($wrapped.Count -gt 1) "$($wrapped.Count)"
    Test-MhCheck 'no line is wider than the column' `
        (-not @($wrapped | Where-Object { (Get-MhPdfTextWidth -Text $_ -Size 8) -gt 90.01 }).Count)
    Test-MhCheck 'and no word is lost' (($wrapped -join ' ') -ceq 'Give the account sysadmin on SQL Server so the report can read the key')
    $key = @(Split-MhPdfText -Text 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows' -Width 60 -Size 8)
    Test-MhCheck 'a single word too wide for the column is split rather than left to overflow' `
        (-not @($key | Where-Object { (Get-MhPdfTextWidth -Text $_ -Size 8) -gt 60.01 }).Count)
    Test-MhCheck 'an empty cell is still one line, so rows line up' ((@(Split-MhPdfText -Text '' -Width 50 -Size 8)).Count -eq 1)

    Test-MhSection 'the file a reader has to accept'

    $bytes = New-MhPdfFile -Content @('BT /F1 10 Tf 40 700 Td (one) Tj ET', 'BT /F1 10 Tf 40 700 Td (two) Tj ET') `
                           -Font @('Helvetica', 'Helvetica-Bold', 'Courier') -Title 'Two pages'
    Test-MhCheck 'it is a byte array rather than a stream of bytes' ($bytes -is [byte[]]) $bytes.GetType().Name
    $text = [System.Text.Encoding]::GetEncoding(1252).GetString($bytes)
    Test-MhCheck 'it starts as a PDF' ($text.StartsWith('%PDF-1.4'))
    Test-MhCheck 'and ends where a reader looks for the end' ($text.TrimEnd().EndsWith('%%EOF'))
    Test-MhCheck 'both pages are there' ($text -match '/Count 2')
    Test-MhCheck 'all three fonts are there' (@([regex]::Matches($text, '/BaseFont')).Count -eq 3)
    Test-MhCheck 'Courier among them, for code' ($text -match '/BaseFont /Courier')
    Test-MhCheck 'the title is carried, so a reader does not show a temporary file name' ($text -match '/Title \(Two pages\)')

    # the xref is the one part a reader will refuse outright: every offset is checked against what
    # is actually at that byte
    $xrefAt = [int]([regex]::Match($text, 'startxref\s+(\d+)').Groups[1].Value)
    Test-MhCheck 'startxref points at the cross-reference table' ($text.Substring($xrefAt, 4) -ceq 'xref') $text.Substring($xrefAt, 12)
    $size = [int]([regex]::Match($text, '/Size (\d+)').Groups[1].Value)
    $entries = @([regex]::Matches($text.Substring($xrefAt), '(\d{10}) 00000 n'))
    Test-MhCheck 'there is one entry per object' ($entries.Count -eq ($size - 1)) "$($entries.Count) for $($size - 1) objects"
    $wrong = @()
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $at = [int]$entries[$i].Groups[1].Value
        if ($text.Substring($at, ("{0} 0 obj" -f ($i + 1)).Length) -cne ("{0} 0 obj" -f ($i + 1))) { $wrong += ($i + 1) }
    }
    Test-MhCheck 'and every offset lands on the object it claims' (-not $wrong.Count) ("objects $($wrong -join ', ')")

    $lengths = @([regex]::Matches($text, '/Length (\d+)'))
    Test-MhCheck 'each content stream declares its real length' `
        (-not @($lengths | Where-Object {
            $after = $text.IndexOf("stream`n", $_.Index) + 7
            $text.Substring($after, [int]$_.Groups[1].Value + 10) -notmatch "endstream"
        }).Count)
}
