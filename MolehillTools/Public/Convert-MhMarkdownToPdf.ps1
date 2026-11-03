<#
    Convert-MhMarkdownToPdf

    Turns one of this repository's Markdown documents into a PDF that anyone can open.

    The reason this exists: Windows ships with nothing that opens a .md file. Sending the patch
    report's permissions handout to a security team as Markdown means sending a file that opens in
    Notepad as a page of pipes and asterisks, or does not open at all. A PDF opens in the browser
    they already have, prints, and attaches to a change record.

    It is deliberately not a Markdown engine. It understands what these documents actually use -
    headings, paragraphs, tables, fenced code, lists, block quotes, bold, italic, inline code and
    links - and nothing else. Anything it does not understand is drawn as the text it is, which is
    the right failure: a stray construct looks odd rather than disappearing.

    Backslash escapes are not honoured, on purpose: half the code in these documents is Windows
    paths, and C:\Program Files is meant to read as C:\Program Files.
#>

$ErrorActionPreference = 'Stop'

# which base-14 font each inline style is drawn in, in the order New-MhPdfFile is given them
$script:MhDocFontRef = @{ Body = '/F1'; Bold = '/F2'; Mono = '/F3'; Italic = '/F4' }
$script:MhDocFonts = @('Helvetica', 'Helvetica-Bold', 'Courier', 'Helvetica-Oblique')

$script:MhDocInk = '0.137 0.122 0.125'
$script:MhDocGrey = '0.420 0.400 0.396'
$script:MhDocHair = '0.863 0.851 0.843'
$script:MhDocCodeBg = '0.957 0.953 0.945'

# one row of a Markdown table, split on the pipes that separate cells rather than on the ones
# inside them
function Split-MhDocTableRow {
    [CmdletBinding()]
    param([string] $Line)

    $text = ([string]$Line).Trim() -replace '^\|', '' -replace '\|$', ''
    $held = [string][char]0x1
    $text = $text.Replace('\|', $held)
    @($text -split '\|' | ForEach-Object { $_.Trim().Replace($held, '|') })
}

# Markdown broken into blocks: the shape of the document, before anything is measured or placed.
function Split-MhDocBlock {
    [CmdletBinding()]
    param([string] $Text)

    $bullet = '^[-*+]\s+(.*)$'
    $ordered = '^(\d+)[.)]\s+(.*)$'
    $rule = '^(-{3,}|\*{3,}|_{3,})$'
    $heading = '^(#{1,6})\s+(.*)$'

    $blocks = New-Object System.Collections.Generic.List[hashtable]
    $lines = @([string]$Text -split "`r?`n")
    $i = 0

    while ($i -lt $lines.Count) {
        $line = $lines[$i]
        $trim = $line.Trim()

        if (-not $trim) { $i++; continue }

        # fenced code first: inside a fence nothing else means anything, which is the point of it
        if ($trim -match '^```+\s*(\S*)') {
            $language = $Matches[1]
            $body = New-Object System.Collections.Generic.List[string]
            $i++
            while ($i -lt $lines.Count -and $lines[$i].Trim() -notmatch '^```') { $body.Add($lines[$i]); $i++ }
            $i++
            $blocks.Add(@{ Kind = 'Code'; Lines = $body.ToArray(); Language = $language })
            continue
        }

        if ($trim -match $rule) { $blocks.Add(@{ Kind = 'Rule' }); $i++; continue }

        if ($trim -match $heading) {
            $blocks.Add(@{ Kind = 'Heading'; Level = $Matches[1].Length; Text = $Matches[2].Trim() })
            $i++; continue
        }

        if ($trim.StartsWith('|')) {
            $rows = New-Object System.Collections.Generic.List[object]
            while ($i -lt $lines.Count -and $lines[$i].Trim().StartsWith('|')) {
                $cells = @(Split-MhDocTableRow $lines[$i])
                $i++
                # the |---|:--:| line under the header says where the columns are, not what is in
                # them: drawn, it is a row of dashes in the middle of the table
                if (-not @($cells | Where-Object { $_ -notmatch '^:?-{2,}:?$' }).Count) { continue }
                $rows.Add($cells)
            }
            if ($rows.Count) {
                $blocks.Add(@{ Kind = 'Table'; Header = @($rows[0]); Rows = @($rows | Select-Object -Skip 1) })
            }
            continue
        }

        if ($trim.StartsWith('>')) {
            $parts = New-Object System.Collections.Generic.List[string]
            while ($i -lt $lines.Count -and $lines[$i].Trim().StartsWith('>')) {
                $parts.Add(($lines[$i].Trim() -replace '^>\s?', ''))
                $i++
            }
            $blocks.Add(@{ Kind = 'Quote'; Text = (($parts -join ' ') -replace '\s+', ' ').Trim() })
            continue
        }

        if ($trim -match $bullet -or $trim -match $ordered) {
            $isOrdered = [bool]($trim -match $ordered)
            $items = New-Object System.Collections.Generic.List[string]
            while ($i -lt $lines.Count) {
                $t = $lines[$i].Trim()
                if (-not $t) { break }
                if ($t -match $bullet) { $items.Add($Matches[1]) }
                elseif ($t -match $ordered) { $items.Add($Matches[2]) }
                elseif ($items.Count -and $t -notmatch '^[|#>]' -and $t -notmatch '^```') {
                    # a wrapped line belongs to the item above it, not to a new one
                    $items[$items.Count - 1] = $items[$items.Count - 1] + ' ' + $t
                }
                else { break }
                $i++
            }
            $blocks.Add(@{ Kind = 'List'; Ordered = $isOrdered; Items = $items.ToArray() })
            continue
        }

        # a paragraph: every line until something else starts, joined. These documents are hard
        # wrapped at the hundredth column, so joining is not optional - left alone, each source
        # line would become a short line on the page.
        $parts = New-Object System.Collections.Generic.List[string]
        while ($i -lt $lines.Count) {
            $t = $lines[$i].Trim()
            if (-not $t) { break }
            if ($t -match $heading -or $t -match $rule -or $t -match $bullet -or $t -match $ordered -or
                $t.StartsWith('|') -or $t.StartsWith('>') -or $t -match '^```') { break }
            $parts.Add($t)
            $i++
        }
        $blocks.Add(@{ Kind = 'Paragraph'; Text = ($parts -join ' ') })
    }

    $blocks.ToArray()
}

# A line of code broken to fit, with its whitespace left alone: inside a fence the spaces are the
# content. Two columns of registry values lined up with spaces came out as one run-on line when
# this went through the ordinary word wrapper, which drops leading indentation and squeezes every
# run of spaces down to one.
#
# Courier is monospaced, so fitting is a character count rather than a measurement.
function Split-MhDocCodeLine {
    [CmdletBinding()]
    param([string] $Line, [double] $Width, [double] $Size)

    $text = (Get-MhPdfText $Line) -replace "`t", '    '
    $perLine = [math]::Max(8, [int][math]::Floor($Width / (Get-MhPdfTextWidth -Text 'x' -Size $Size -Font 'Mono')))
    if ($text.Length -le $perLine) { return , $text }

    # what is left of a wrapped command reads better indented under the start of it
    $indent = ''
    if ($text -match '^(\s+)') { $indent = $Matches[1] }
    $hanging = $indent + '  '
    if ($hanging.Length -ge ($perLine - 8)) { $hanging = '' }

    $out = New-Object System.Collections.Generic.List[string]
    $first = $true
    while ($text.Length -gt 0) {
        $prefix = $(if ($first) { '' } else { $hanging })
        $room = $perLine - $prefix.Length
        if ($text.Length -le $room) { $out.Add($prefix + $text); break }

        # broken at a space where there is one worth breaking at, rather than through a word
        $cut = $room
        $at = $text.LastIndexOf(' ', [math]::Min($room, $text.Length - 1))
        if ($at -gt ($room * 0.5)) { $cut = $at }
        $out.Add(($prefix + $text.Substring(0, $cut)).TrimEnd())
        $text = $text.Substring($cut).TrimStart(' ')
        $first = $false
    }
    $out.ToArray()
}

# One line of Markdown as runs of styled text. Code spans are taken first, because inside one an
# asterisk is an asterisk.
function Get-MhDocRun {
    [CmdletBinding()]
    param([string] $Text, [ValidateSet('Body', 'Bold', 'Italic', 'Mono')] [string] $Base = 'Body')

    $runs = New-Object System.Collections.Generic.List[hashtable]
    $source = [string]$Text
    if (-not $source) { return @() }

    $pattern = '`([^`]+)`|\*\*([^*]+)\*\*|__([^_]+)__|\*([^*\n]+)\*|(?<![\w\\])_([^_\n]+)_(?![\w])|\[([^]]+)\]\(([^)]+)\)'
    $at = 0
    foreach ($match in [regex]::Matches($source, $pattern)) {
        if ($match.Index -gt $at) {
            $runs.Add(@{ Text = $source.Substring($at, $match.Index - $at); Style = $Base })
        }
        if ($match.Groups[1].Success) { $runs.Add(@{ Text = $match.Groups[1].Value; Style = 'Mono' }) }
        elseif ($match.Groups[2].Success) { $runs.Add(@{ Text = $match.Groups[2].Value; Style = 'Bold' }) }
        elseif ($match.Groups[3].Success) { $runs.Add(@{ Text = $match.Groups[3].Value; Style = 'Bold' }) }
        elseif ($match.Groups[4].Success) { $runs.Add(@{ Text = $match.Groups[4].Value; Style = $(if ($Base -eq 'Bold') { 'Bold' } else { 'Italic' }) }) }
        elseif ($match.Groups[5].Success) { $runs.Add(@{ Text = $match.Groups[5].Value; Style = $(if ($Base -eq 'Bold') { 'Bold' } else { 'Italic' }) }) }
        else {
            # a link: the words, then where they go, because on paper nobody can follow a link
            $runs.Add(@{ Text = $match.Groups[6].Value; Style = $Base })
            $runs.Add(@{ Text = ' (' + $match.Groups[7].Value + ')'; Style = 'Mono' })
        }
        $at = $match.Index + $match.Length
    }
    if ($at -lt $source.Length) { $runs.Add(@{ Text = $source.Substring($at); Style = $Base }) }
    $runs.ToArray()
}

# Runs broken into lines that fit a width, each line a list of pieces with the offset they are
# drawn at. Measuring per style matters: a line of bold measured as regular runs past the margin.
function Split-MhDocRunToWidth {
    [CmdletBinding()]
    param([AllowEmptyCollection()] [object[]] $Run, [double] $Width, [double] $Size)

    # words, remembering which of them had a space in front. "(`CONNECT SQL`)" has no space after
    # its bracket, and inserting one there is how a converter gives away that it is a converter.
    $tokens = New-Object System.Collections.Generic.List[hashtable]
    $pendingSpace = $false
    foreach ($run in @($Run)) {
        $segments = [string]$run.Text -split ' '
        for ($s = 0; $s -lt $segments.Count; $s++) {
            if ($s -gt 0) { $pendingSpace = $true }
            if (-not $segments[$s]) { continue }
            $tokens.Add(@{ Text = $segments[$s]; Style = $run.Style; Space = ($pendingSpace -and $tokens.Count -gt 0) })
            $pendingSpace = $false
        }
    }

    # a word wider than the whole column - a registry key, a connection string - broken into pieces
    # that fit, each then treated as a word of its own
    $words = New-Object System.Collections.Generic.List[hashtable]
    foreach ($token in $tokens) {
        if ((Get-MhPdfTextWidth -Text $token.Text -Size $Size -Font $token.Style) -le $Width) { $words.Add($token); continue }
        $first = $true
        foreach ($piece in @(Split-MhPdfText -Text $token.Text -Width $Width -Size $Size -Font $token.Style)) {
            $words.Add(@{ Text = $piece; Style = $token.Style; Space = ($first -and $token.Space) })
            $first = $false
        }
    }

    $lines = New-Object System.Collections.Generic.List[object]
    $line = New-Object System.Collections.Generic.List[hashtable]
    $x = 0.0
    foreach ($word in $words) {
        $wordWidth = Get-MhPdfTextWidth -Text $word.Text -Size $Size -Font $word.Style
        $spaceWidth = $(if ($word.Space -and $line.Count) { Get-MhPdfTextWidth -Text ' ' -Size $Size -Font $word.Style } else { 0.0 })

        if ($line.Count -and ($x + $spaceWidth + $wordWidth) -gt $Width) {
            $lines.Add($line.ToArray())
            $line = New-Object System.Collections.Generic.List[hashtable]
            $x = 0.0
            $spaceWidth = 0.0
        }

        if ($spaceWidth) {
            # two code words side by side keep the space inside the code, so their backgrounds join
            # up into one box instead of a dotted row of them
            $previous = $line[$line.Count - 1]
            if ($previous.Style -eq 'Mono' -and $word.Style -eq 'Mono') {
                $previous.Text = $previous.Text + ' '
                $previous.Width = $previous.Width + $spaceWidth
            }
            $x += $spaceWidth
        }

        $line.Add(@{ Text = $word.Text; Style = $word.Style; X = $x; Width = $wordWidth })
        $x += $wordWidth
    }
    if ($line.Count -or -not $lines.Count) { $lines.Add($line.ToArray()) }
    $lines.ToArray()
}

# the operators that draw one laid-out line, inline code on its own background
function Get-MhDocLineOperator {
    [CmdletBinding()]
    param([AllowEmptyCollection()] [object[]] $Line, [double] $X, [double] $Y, [double] $Size, [string] $Colour)

    $out = New-Object System.Collections.Generic.List[string]
    foreach ($piece in @($Line)) {
        if ($piece.Style -eq 'Mono') {
            $out.Add("$script:MhDocCodeBg rg")
            $out.Add(('{0} {1} {2} {3} re f' -f [math]::Round($X + $piece.X - 1, 2), [math]::Round($Y - 0.2 * $Size, 2),
                     [math]::Round($piece.Width + 2, 2), [math]::Round($Size * 1.15, 2)))
        }
    }
    $out.Add("$Colour rg")
    foreach ($piece in @($Line)) {
        $out.Add((Get-MhPdfTextOperator -Text $piece.Text -X ($X + $piece.X) -Y $Y -Size $Size -FontRef $script:MhDocFontRef[$piece.Style]))
    }
    $out.ToArray()
}

<#
    Blocks measured and turned into pieces: a piece is as much as can be drawn in one go without
    being split, and carries its own height. Pagination then only has to add heights up.

    A table row is a piece and so is its header, with each row holding on to its header so the
    header can be drawn again at the top of the next page. A table whose columns are labelled only
    on page one is unreadable by page three.
#>
function Get-MhDocPiece {
    [CmdletBinding()]
    param([AllowEmptyCollection()] [object[]] $Block, [double] $Width)

    $bodySize = 9.5
    $bodyLead = 13.0
    $codeSize = 8.5
    $codeLead = 11.5
    $cellSize = 8.5
    $cellLead = 11.0
    $cellPad = 5.0

    $pieces = New-Object System.Collections.Generic.List[hashtable]
    $add = {
        param($Piece)
        $full = @{ Kind = ''; Height = 0.0; SpaceBefore = 0.0; KeepWithNext = $false
                   Lines = @(); Size = $bodySize; Leading = $bodyLead; Indent = 0.0
                   Colour = $script:MhDocInk; Marker = ''; Level = 0
                   Cells = @(); Widths = @(); Header = $null; Text = '' }
        foreach ($key in $Piece.Keys) { $full[$key] = $Piece[$key] }
        $pieces.Add($full)
    }

    foreach ($block in @($Block)) {
        switch ($block.Kind) {

            'Heading' {
                $size = $(switch ($block.Level) { 1 { 15.0 } 2 { 12.5 } default { 10.5 } })
                $lines = @(Split-MhDocRunToWidth -Run (Get-MhDocRun -Text $block.Text -Base 'Bold') -Width $Width -Size $size)
                & $add @{ Kind = 'Heading'; Lines = $lines; Size = $size; Leading = ($size * 1.35); Level = $block.Level
                          Height = ($lines.Count * $size * 1.35) + $(if ($block.Level -le 2) { 6.0 } else { 0.0 })
                          SpaceBefore = $(switch ($block.Level) { 1 { 20.0 } 2 { 17.0 } default { 12.0 } })
                          # a heading at the foot of a page, with its first line overleaf, reads as
                          # if the section were empty
                          KeepWithNext = $true }
            }

            'Paragraph' {
                $lines = @(Split-MhDocRunToWidth -Run (Get-MhDocRun -Text $block.Text) -Width $Width -Size $bodySize)
                & $add @{ Kind = 'Lines'; Lines = $lines; Height = ($lines.Count * $bodyLead); SpaceBefore = 7.0 }
            }

            'List' {
                $indent = 16.0
                $number = 1
                foreach ($item in @($block.Items)) {
                    $lines = @(Split-MhDocRunToWidth -Run (Get-MhDocRun -Text $item) -Width ($Width - $indent) -Size $bodySize)
                    & $add @{ Kind = 'Lines'; Lines = $lines; Indent = $indent
                              Marker = $(if ($block.Ordered) { "$number." } else { [string][char]0x2022 })
                              Height = ($lines.Count * $bodyLead); SpaceBefore = $(if ($number -eq 1) { 7.0 } else { 3.0 }) }
                    $number++
                }
            }

            'Code' {
                # wrapped rather than clipped: a long command has to be readable, and a reader
                # cannot scroll a page sideways
                $lines = New-Object System.Collections.Generic.List[string]
                foreach ($line in @($block.Lines)) {
                    foreach ($part in @(Split-MhDocCodeLine -Line $line -Width ($Width - 24) -Size $codeSize)) {
                        $lines.Add($part)
                    }
                }
                if (-not $lines.Count) { $lines.Add('') }
                & $add @{ Kind = 'Code'; Lines = $lines.ToArray(); Size = $codeSize; Leading = $codeLead
                          Height = ($lines.Count * $codeLead) + 12.0; SpaceBefore = 9.0 }
            }

            'Quote' {
                $lines = @(Split-MhDocRunToWidth -Run (Get-MhDocRun -Text $block.Text -Base 'Italic') -Width ($Width - 22) -Size $bodySize)
                & $add @{ Kind = 'Quote'; Lines = $lines; Indent = 16.0
                          Height = ($lines.Count * $bodyLead) + 8.0; SpaceBefore = 10.0 }
            }

            'Rule' { & $add @{ Kind = 'Rule'; Height = 1.0; SpaceBefore = 10.0 } }

            'Table' {
                $columns = @($block.Header).Count
                foreach ($row in @($block.Rows)) { if (@($row).Count -gt $columns) { $columns = @($row).Count } }
                if (-not $columns) { continue }

                # every column asked how wide it would like to be, then all of them scaled to the
                # page. Proportional rather than equal: a "#" column next to a "Why" column should
                # not be given the same inch of paper.
                $natural = [double[]]::new($columns)
                for ($c = 0; $c -lt $columns; $c++) {
                    $header = [string]@($block.Header)[$c]
                    $natural[$c] = (Get-MhPdfTextWidth -Text $header -Size $cellSize -Font 'Bold') + (2 * $cellPad)
                    foreach ($row in @($block.Rows)) {
                        $cell = [string]@($row)[$c]
                        # measured without its markup, or ** and ` are paid for in paper
                        $plain = ($cell -replace '\*\*|__|`', '') -replace '\[([^]]+)\]\(([^)]+)\)', '$1 ($2)'
                        $want = (Get-MhPdfTextWidth -Text $plain -Size $cellSize) + (2 * $cellPad)
                        if ($want -gt $natural[$c]) { $natural[$c] = $want }
                    }
                }

                $total = ($natural | Measure-Object -Sum).Sum
                $widths = [double[]]::new($columns)
                $minimum = [math]::Min(46.0, $Width / $columns)
                if ($total -le $Width) {
                    # share the slack out, so the table squares up with the margins rather than
                    # stopping short of the right-hand one
                    for ($c = 0; $c -lt $columns; $c++) { $widths[$c] = $natural[$c] + (($Width - $total) * ($natural[$c] / $total)) }
                }
                else {
                    $spare = $Width
                    $flexible = 0.0
                    for ($c = 0; $c -lt $columns; $c++) {
                        if ($natural[$c] -le $minimum) { $widths[$c] = $natural[$c]; $spare -= $natural[$c] }
                        else { $flexible += $natural[$c] }
                    }
                    for ($c = 0; $c -lt $columns; $c++) {
                        if ($widths[$c] -eq 0) {
                            # every column already at its floor leaves nothing to share out
                            $widths[$c] = $(if ($flexible -gt 0) { [math]::Max($minimum, $spare * ($natural[$c] / $flexible)) } else { $Width / $columns })
                        }
                    }
                }

                $measure = {
                    param($Cells, $Base)
                    $laid = @()
                    $tallest = 1
                    for ($c = 0; $c -lt $columns; $c++) {
                        $text = [string]@($Cells)[$c]
                        $lines = @(Split-MhDocRunToWidth -Run (Get-MhDocRun -Text $text -Base $Base) `
                                                         -Width ($widths[$c] - (2 * $cellPad)) -Size $cellSize)
                        $laid += , $lines
                        if ($lines.Count -gt $tallest) { $tallest = $lines.Count }
                    }
                    @{ Cells = $laid; Height = ($tallest * $cellLead) + 5.0 }
                }

                $head = & $measure @($block.Header) 'Bold'
                $headPiece = @{ Kind = 'TableHead'; Height = $head.Height; SpaceBefore = 10.0; KeepWithNext = $true
                                Cells = $head.Cells; Widths = $widths; Size = $cellSize; Leading = $cellLead }
                & $add $headPiece
                $headRecord = $pieces[$pieces.Count - 1]

                foreach ($row in @($block.Rows)) {
                    $laid = & $measure @($row) 'Body'
                    & $add @{ Kind = 'TableRow'; Height = $laid.Height; Cells = $laid.Cells; Widths = $widths
                              Size = $cellSize; Leading = $cellLead; Header = $headRecord }
                }
            }
        }
    }

    $pieces.ToArray()
}

function Convert-MhMarkdownToPdf {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [string] $Path,
        [string] $OutputPath,
        [string] $Title,
        [string] $Subtitle,
        [string] $Footer = 'Molehill Data Services',
        [switch] $Open
    )

    if (-not (Test-Path -LiteralPath $Path)) { throw "There is no file at $Path." }
    $source = Get-Item -LiteralPath $Path
    $text = [System.IO.File]::ReadAllText($source.FullName, [System.Text.Encoding]::UTF8)

    if (-not $OutputPath) { $OutputPath = Join-Path $source.DirectoryName ($source.BaseName + '.pdf') }
    if (-not [System.IO.Path]::IsPathRooted($OutputPath)) { $OutputPath = Join-Path (Get-Location).Path $OutputPath }

    $blocks = @(Split-MhDocBlock -Text $text)

    # the first heading is the document's title, so it becomes the title rather than being drawn
    # twice - once in the band and again underneath it
    if ($blocks.Count -and $blocks[0].Kind -eq 'Heading' -and $blocks[0].Level -eq 1) {
        if (-not $Title) { $Title = $blocks[0].Text }
        $blocks = @($blocks | Select-Object -Skip 1)
    }
    if (-not $Title) { $Title = $source.BaseName }
    if (-not $PSBoundParameters.ContainsKey('Subtitle')) {
        $Subtitle = '{0}  -  {1}' -f $source.Name, (Get-Date).ToString('dd MMMM yyyy')
    }

    $pageWidth = 595.0
    $pageHeight = 842.0
    $margin = 52.0
    $width = $pageWidth - (2 * $margin)
    $bandDepth = 92.0
    $bottom = $margin + 20.0

    $pieces = @(Get-MhDocPiece -Block $blocks -Width $width)

    # ---- which pieces land on which page
    $firstTop = $pageHeight - $bandDepth - 26.0
    $laterTop = $pageHeight - $margin
    $pages = New-Object System.Collections.Generic.List[object]
    $current = New-Object System.Collections.Generic.List[object]
    $y = $firstTop
    for ($p = 0; $p -lt $pieces.Count; $p++) {
        $piece = $pieces[$p]
        $needed = $piece.SpaceBefore + $piece.Height

        # a heading has to take the start of what follows with it, or it strands at the foot of a
        # page on its own
        if ($piece.KeepWithNext -and $p -lt ($pieces.Count - 1)) {
            $next = $pieces[$p + 1]
            $needed += $next.SpaceBefore + [math]::Min($next.Height, 3 * $next.Leading)
        }

        if ($current.Count -and ($y - $needed) -lt $bottom) {
            $pages.Add($current.ToArray())
            $current = New-Object System.Collections.Generic.List[object]
            $y = $laterTop
            # a table carried over starts with its own header again
            if ($piece.Kind -eq 'TableRow' -and $piece.Header) {
                $current.Add(@{ Piece = $piece.Header; Y = ($y - $piece.Header.Height) })
                $y -= $piece.Header.Height
            }
            $current.Add(@{ Piece = $piece; Y = ($y - $piece.Height) })
            $y -= $piece.Height
            continue
        }

        $y -= $piece.SpaceBefore
        $current.Add(@{ Piece = $piece; Y = ($y - $piece.Height) })
        $y -= $piece.Height
    }
    $pages.Add($current.ToArray())

    # ---- draw
    $contents = New-Object System.Collections.Generic.List[string]
    for ($p = 0; $p -lt $pages.Count; $p++) {
        $out = New-Object System.Collections.Generic.List[string]

        if ($p -eq 0) {
            $out.Add("$script:MhDocInk rg")
            $out.Add(('0 {0} {1} {2} re f' -f ($pageHeight - $bandDepth), $pageWidth, $bandDepth))
            $titleLines = @(Split-MhDocRunToWidth -Run (Get-MhDocRun -Text $Title -Base 'Bold') -Width ($width - 10) -Size 17)
            $titleY = $pageHeight - $bandDepth + 40.0 + (([math]::Min($titleLines.Count, 2) - 1) * 21.0)
            foreach ($line in $titleLines) {
                foreach ($operator in (Get-MhDocLineOperator -Line $line -X $margin -Y $titleY -Size 17 -Colour '1 1 1')) { $out.Add($operator) }
                $titleY -= 21.0
            }
            if ($Subtitle) {
                $out.Add('0.729 0.714 0.706 rg')
                $out.Add((Get-MhPdfTextOperator -Text $Subtitle -X $margin -Y ($pageHeight - $bandDepth + 20.0) -Size 8.5))
            }
        }

        foreach ($placed in $pages[$p]) {
            $piece = $placed.Piece
            $y = $placed.Y
            $top = $y + $piece.Height

            switch ($piece.Kind) {

                'Heading' {
                    $lineY = $top - $piece.Size
                    foreach ($line in $piece.Lines) {
                        foreach ($operator in (Get-MhDocLineOperator -Line $line -X $margin -Y $lineY -Size $piece.Size -Colour $script:MhDocInk)) { $out.Add($operator) }
                        $lineY -= $piece.Leading
                    }
                    if ($piece.Level -le 2) {
                        $out.Add("$script:MhDocHair RG 0.7 w")
                        $out.Add(('{0} {1} m {2} {1} l S' -f $margin, [math]::Round($y + 2, 2), ($pageWidth - $margin)))
                    }
                }

                'Lines' {
                    $lineY = $top - $piece.Size
                    if ($piece.Marker) {
                        $out.Add("$script:MhDocGrey rg")
                        $out.Add((Get-MhPdfTextOperator -Text $piece.Marker -X ($margin + 4) -Y $lineY -Size $piece.Size))
                    }
                    foreach ($line in $piece.Lines) {
                        foreach ($operator in (Get-MhDocLineOperator -Line $line -X ($margin + $piece.Indent) -Y $lineY -Size $piece.Size -Colour $piece.Colour)) { $out.Add($operator) }
                        $lineY -= $piece.Leading
                    }
                }

                'Code' {
                    $out.Add("$script:MhDocCodeBg rg")
                    $out.Add(('{0} {1} {2} {3} re f' -f $margin, [math]::Round($y, 2), $width, [math]::Round($piece.Height, 2)))
                    $out.Add("$script:MhDocHair RG 0.7 w")
                    $out.Add(('{0} {1} {2} {3} re S' -f $margin, [math]::Round($y, 2), $width, [math]::Round($piece.Height, 2)))
                    $out.Add('0.180 0.165 0.157 rg')
                    $lineY = $top - 6.0 - $piece.Size
                    foreach ($line in $piece.Lines) {
                        if ($line) { $out.Add((Get-MhPdfTextOperator -Text $line -X ($margin + 10) -Y $lineY -Size $piece.Size -FontRef '/F3')) }
                        $lineY -= $piece.Leading
                    }
                }

                'Quote' {
                    $out.Add("$script:MhDocInk rg")
                    $out.Add(('{0} {1} 3 {2} re f' -f $margin, [math]::Round($y, 2), [math]::Round($piece.Height, 2)))
                    $lineY = $top - 4.0 - $piece.Size
                    foreach ($line in $piece.Lines) {
                        foreach ($operator in (Get-MhDocLineOperator -Line $line -X ($margin + $piece.Indent) -Y $lineY -Size $piece.Size -Colour $script:MhDocGrey)) { $out.Add($operator) }
                        $lineY -= $piece.Leading
                    }
                }

                'Rule' {
                    $out.Add("$script:MhDocHair RG 0.7 w")
                    $out.Add(('{0} {1} m {2} {1} l S' -f $margin, [math]::Round($y, 2), ($pageWidth - $margin)))
                }

                'TableHead' {
                    $out.Add("$script:MhDocInk rg")
                    $out.Add(('{0} {1} {2} {3} re f' -f $margin, [math]::Round($y, 2), $width, [math]::Round($piece.Height, 2)))
                    $x = $margin
                    for ($c = 0; $c -lt $piece.Cells.Count; $c++) {
                        $lineY = $top - 3.5 - $piece.Size
                        foreach ($line in $piece.Cells[$c]) {
                            foreach ($operator in (Get-MhDocLineOperator -Line $line -X ($x + 5) -Y $lineY -Size $piece.Size -Colour '1 1 1')) { $out.Add($operator) }
                            $lineY -= $piece.Leading
                        }
                        $x += $piece.Widths[$c]
                    }
                }

                'TableRow' {
                    $x = $margin
                    for ($c = 0; $c -lt $piece.Cells.Count; $c++) {
                        $lineY = $top - 3.5 - $piece.Size
                        foreach ($line in $piece.Cells[$c]) {
                            foreach ($operator in (Get-MhDocLineOperator -Line $line -X ($x + 5) -Y $lineY -Size $piece.Size -Colour $script:MhDocInk)) { $out.Add($operator) }
                            $lineY -= $piece.Leading
                        }
                        $x += $piece.Widths[$c]
                    }
                    $out.Add("$script:MhDocHair RG 0.5 w")
                    $out.Add(('{0} {1} m {2} {1} l S' -f $margin, [math]::Round($y, 2), ($pageWidth - $margin)))
                }
            }
        }

        $out.Add("$script:MhDocHair RG 0.5 w")
        $out.Add(('{0} {1} m {2} {1} l S' -f $margin, ($margin + 12), ($pageWidth - $margin)))
        $out.Add("$script:MhDocGrey rg")
        $out.Add((Get-MhPdfTextOperator -Text $Footer -X $margin -Y ($margin + 2) -Size 7.5))
        $pageLabel = 'Page {0} of {1}' -f ($p + 1), $pages.Count
        $out.Add((Get-MhPdfTextOperator -Text $pageLabel -X ($pageWidth - $margin - (Get-MhPdfTextWidth -Text $pageLabel -Size 7.5)) `
                                        -Y ($margin + 2) -Size 7.5))

        $contents.Add($out -join "`n")
    }

    $bytes = New-MhPdfFile -Content $contents.ToArray() -PageWidth $pageWidth -PageHeight $pageHeight `
                           -Font $script:MhDocFonts -Title $Title
    [System.IO.File]::WriteAllBytes($OutputPath, $bytes)

    Write-Host ('  {0} -> {1}' -f $source.Name, (Split-Path -Leaf $OutputPath)) -ForegroundColor Green
    Write-Host ('  {0} page{1}, {2:n0} KB' -f $pages.Count, $(if ($pages.Count -eq 1) { '' } else { 's' }), ($bytes.Length / 1KB)) -ForegroundColor Gray

    if ($Open) { Start-Process -FilePath $OutputPath }
    $OutputPath
}

Register-MhSelfTest -Name 'Convert-MhMarkdownToPdf' -Test {

    Test-MhSection 'the shape of a document'

    $sample = @'
# The title

A paragraph that is
hard wrapped in the source.

## A heading

| # | What | Why |
|---|------|-----|
| 1 | A login | to read the version |
| 2 | A registry key | to read the build |

- first item
  wrapped onto a second line
- second item

> A line for a change record.

```sql
CREATE LOGIN [CONTOSO\svc] FROM WINDOWS;
sqlcmd -S sql01.contoso.local -E -Q "SELECT SERVERPROPERTY('ProductVersion'), SERVERPROPERTY('Edition'), SERVERPROPERTY('ProductUpdateLevel')"
```
'@
    $blocks = @(Split-MhDocBlock -Text $sample)
    Test-MhCheck 'every block is found and none invented' ($blocks.Count -eq 7) "$($blocks.Count): $(($blocks | ForEach-Object { $_.Kind }) -join ', ')"
    Test-MhCheck 'the title is a level 1 heading' ($blocks[0].Kind -eq 'Heading' -and $blocks[0].Level -eq 1)
    Test-MhCheck 'a hard-wrapped paragraph is joined back together' `
        ($blocks[1].Text -ceq 'A paragraph that is hard wrapped in the source.') $blocks[1].Text
    Test-MhCheck 'the heading under it is level 2' ($blocks[2].Level -eq 2)

    $table = $blocks[3]
    Test-MhCheck 'the table has its header' (($table.Header -join '|') -ceq '#|What|Why') ($table.Header -join '|')
    # drawn, the |---|---| line is a row of dashes in the middle of the table
    Test-MhCheck 'and two rows, the dashes not being one of them' (@($table.Rows).Count -eq 2) "$(@($table.Rows).Count)"
    Test-MhCheck 'with the cells in the right order' ((@($table.Rows)[1] -join '|') -ceq '2|A registry key|to read the build')

    Test-MhCheck 'both list items are found' (@($blocks[4].Items).Count -eq 2) "$(@($blocks[4].Items).Count)"
    $markers = @(Get-MhDocPiece -Block @($blocks[4]) -Width 400 | ForEach-Object { $_.Marker })
    # U+0095 is a control character, not a bullet: it has no Windows-1252 byte and comes out as a
    # question mark in front of every item
    Test-MhCheck 'a bullet is drawn as a bullet rather than as a question mark' `
        ((Get-MhPdfText $markers[0]) -ceq ([string][char]0x2022)) ('{0:X4}' -f [int](Get-MhPdfText $markers[0])[0])
    Test-MhCheck 'and a wrapped item stays one item' `
        (@($blocks[4].Items)[0] -ceq 'first item wrapped onto a second line') (@($blocks[4].Items)[0])
    Test-MhCheck 'the quote loses its marker' ($blocks[5].Text -ceq 'A line for a change record.') $blocks[5].Text
    Test-MhCheck 'the code block knows its language' ($blocks[6].Language -ceq 'sql')
    Test-MhCheck 'and its contents are left exactly alone' `
        (@($blocks[6].Lines)[0] -ceq 'CREATE LOGIN [CONTOSO\svc] FROM WINDOWS;') (@($blocks[6].Lines)[0])
    Test-MhSection 'whitespace inside a fence'

    $spaced = @(Split-MhDocCodeLine -Line '    CurrentBuild        InstallationType' -Width 400 -Size 8.5)
    Test-MhCheck 'the spaces that line two columns up are kept, and so is the indent' `
        ($spaced[0] -ceq '    CurrentBuild        InstallationType') "[$($spaced[0])]"
    $wrappedCode = @(Split-MhDocCodeLine -Line ('sqlcmd -S sql01 -Q "' + ('x' * 200) + '"') -Width 200 -Size 8.5)
    Test-MhCheck 'a line too long for the page is broken up' ($wrappedCode.Count -gt 1) "$($wrappedCode.Count)"
    Test-MhCheck 'and no piece of it is wider than the page' `
        (-not @($wrappedCode | Where-Object { (Get-MhPdfTextWidth -Text $_ -Size 8.5 -Font 'Mono') -gt 200.01 }).Count)
    Test-MhCheck 'nothing is lost in the breaking' `
        ((($wrappedCode -join '') -replace '\s', '') -ceq (('sqlcmd -S sql01 -Q "' + ('x' * 200) + '"') -replace '\s', ''))

    # a reader cannot scroll a page sideways, so a long command has to be broken rather than clipped
    $codePiece = @(Get-MhDocPiece -Block @($blocks[6]) -Width 490 | Where-Object { $_.Kind -eq 'Code' })[0]
    Test-MhCheck 'a command too long for the page is wrapped rather than run off it' `
        (@($codePiece.Lines).Count -gt @($blocks[6].Lines).Count) `
        "$(@($codePiece.Lines).Count) lines from $(@($blocks[6].Lines).Count)"

    Test-MhSection 'a fence means what it says'

    $fenced = @(Split-MhDocBlock -Text "text`n`n``````text`n# not a heading`n| not | a table |`n- not a list`n``````")
    Test-MhCheck 'nothing inside a code fence is parsed as anything else' ($fenced.Count -eq 2) `
        (($fenced | ForEach-Object { $_.Kind }) -join ', ')
    Test-MhCheck 'and every line of it is kept' (@($fenced[1].Lines).Count -eq 3) "$(@($fenced[1].Lines).Count)"

    Test-MhSection 'a pipe inside a cell'

    $piped = @(Split-MhDocTableRow '| a | b \| c | d |')
    Test-MhCheck 'splits on the pipes between cells, not the ones in them' ($piped.Count -eq 3) ($piped -join ' / ')
    Test-MhCheck 'and the escaped one is kept as a pipe' ($piped[1] -ceq 'b | c') $piped[1]

    Test-MhSection 'bold, code, italic and links'

    $runs = @(Get-MhDocRun -Text 'A **login** that can `CONNECT SQL` and *nothing* else')
    Test-MhCheck 'the styles come out in order' `
        ((($runs | ForEach-Object { $_.Style }) -join ',') -ceq 'Body,Bold,Body,Mono,Body,Italic,Body') `
        (($runs | ForEach-Object { $_.Style }) -join ',')
    Test-MhCheck 'and the markup itself is gone' ((($runs | ForEach-Object { $_.Text }) -join '') -notmatch '[*`]')
    Test-MhCheck 'the words survive it' `
        ((($runs | ForEach-Object { $_.Text }) -join '') -ceq 'A login that can CONNECT SQL and nothing else')
    # inside a code span an asterisk is an asterisk
    $stars = @(Get-MhDocRun -Text 'use `SELECT *` here')
    Test-MhCheck 'a code span is taken before anything inside it' `
        (@($stars | Where-Object { $_.Style -eq 'Mono' }).Text -ceq 'SELECT *') (@($stars | Where-Object { $_.Style -eq 'Mono' }).Text)
    $heading = @(Get-MhDocRun -Text 'On `sys.databases`, and this' -Base 'Bold')
    Test-MhCheck 'in a heading the plain words are bold' (@($heading)[0].Style -eq 'Bold')
    Test-MhCheck 'and the code in it is still code' (@($heading)[1].Style -eq 'Mono')
    $linked = @(Get-MhDocRun -Text 'see [the article](https://learn.microsoft.com/x) for it')
    Test-MhCheck 'a link keeps its words' (@($linked | Where-Object { $_.Text -match 'the article' }).Count -eq 1)
    Test-MhCheck 'and says where it goes, because paper cannot be clicked' `
        ((($linked | ForEach-Object { $_.Text }) -join '') -match '\(https://learn\.microsoft\.com/x\)')
    # a Windows path is not an escape sequence
    $path = @(Get-MhDocRun -Text 'in C:\Program Files\x')
    Test-MhCheck 'a backslash in a path is left alone' ((($path | ForEach-Object { $_.Text }) -join '') -ceq 'in C:\Program Files\x')

    Test-MhSection 'laying runs out on a line'

    $laid = @(Split-MhDocRunToWidth -Run (Get-MhDocRun -Text 'A domain account in no privileged group at all, which is the identity the report runs as and nothing more') -Width 150 -Size 9.5)
    Test-MhCheck 'long text takes several lines' ($laid.Count -gt 2) "$($laid.Count)"
    $over = @()
    foreach ($line in $laid) {
        $last = @($line)[-1]
        if (($last.X + $last.Width) -gt 150.01) { $over += ($line | ForEach-Object { $_.Text }) -join ' ' }
    }
    Test-MhCheck 'and no line reaches past the width it was given' (-not $over.Count) ($over -join ' / ')
    Test-MhCheck 'every word is still there, in order' `
        ((($laid | ForEach-Object { ($_ | ForEach-Object { $_.Text }) -join ' ' }) -join ' ') -ceq
         'A domain account in no privileged group at all, which is the identity the report runs as and nothing more')

    # a space where the source had none is how a converter gives itself away
    $tight = @(Split-MhDocRunToWidth -Run (Get-MhDocRun -Text 'a login (`CONNECT SQL`) only') -Width 400 -Size 9.5)
    $first = @($tight)[0]
    $bracket = @($first | Where-Object { $_.Text -ceq '(' })[0]
    $code = @($first | Where-Object { $_.Text -match '^CONNECT' })[0]
    Test-MhCheck 'the bracket and the code inside it are drawn touching, with no space invented' `
        ($bracket -and $code -and [math]::Abs(($bracket.X + $bracket.Width) - $code.X) -lt 0.01) `
        (($first | ForEach-Object { "$($_.Style):$($_.Text)@$([math]::Round($_.X, 1))" }) -join '|')
    Test-MhCheck 'and two code words keep the space inside the code, so their backgrounds join up' `
        (@($first | Where-Object { $_.Text -ceq 'CONNECT ' -and $_.Style -eq 'Mono' }).Count -eq 1) `
        (($first | ForEach-Object { "$($_.Style):$($_.Text)" }) -join '|')

    $bold = @(Split-MhDocRunToWidth -Run (Get-MhDocRun -Text '**Access this computer from the network** right') -Width 140 -Size 9.5)
    $boldOver = @()
    foreach ($line in $bold) {
        $last = @($line)[-1]
        if (($last.X + $last.Width) -gt 140.01) { $boldOver += ($line | ForEach-Object { $_.Text }) -join ' ' }
    }
    Test-MhCheck 'bold is measured as bold, or a bold line runs past the margin' (-not $boldOver.Count) ($boldOver -join ' / ')

    $wide = @(Split-MhDocRunToWidth -Run (Get-MhDocRun -Text 'key `HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion`') -Width 90 -Size 9.5)
    $wideOver = @()
    foreach ($line in $wide) {
        $last = @($line)[-1]
        if (($last.X + $last.Width) -gt 90.01) { $wideOver += ($line | ForEach-Object { $_.Text }) -join ' ' }
    }
    Test-MhCheck 'a registry key too long for the column is broken rather than left to overflow' (-not $wideOver.Count) ($wideOver -join ' / ')

    Test-MhSection 'pieces, measured before anything is placed'

    $pieces = @(Get-MhDocPiece -Block (Split-MhDocBlock -Text $sample) -Width 490)
    Test-MhCheck 'every piece knows how tall it is' (-not @($pieces | Where-Object { $_.Height -le 0 -and $_.Kind -ne 'Rule' }).Count)
    Test-MhCheck 'a heading is kept with what follows it' `
        (-not @($pieces | Where-Object { $_.Kind -eq 'Heading' -and -not $_.KeepWithNext }).Count)
    $rows = @($pieces | Where-Object { $_.Kind -eq 'TableRow' })
    Test-MhCheck 'each table row holds on to its header, for the top of the next page' `
        (@($rows | Where-Object { $_.Header -and $_.Header.Kind -eq 'TableHead' }).Count -eq $rows.Count)
    $widths = @($rows)[0].Widths
    Test-MhCheck 'the columns add up to the width of the page' `
        ([math]::Abs((($widths | Measure-Object -Sum).Sum) - 490) -lt 0.5) "$((($widths | Measure-Object -Sum).Sum))"
    Test-MhCheck 'and the column with more in it is given more of it' ($widths[2] -gt $widths[0])

    # a table far too wide for the page: every column still has to end up on it
    $squeezed = @(Get-MhDocPiece -Width 300 -Block (Split-MhDocBlock -Text (
        "| One | Two | Three | Four |`n|---|---|---|---|`n| " +
        ((1..4 | ForEach-Object { 'a rather long cell of text that would like a great deal of room' }) -join ' | ') + ' |')))
    $squeezedWidths = @($squeezed | Where-Object { $_.Kind -eq 'TableRow' })[0].Widths
    Test-MhCheck 'a table too wide for the page is squeezed onto it rather than off it' `
        ([math]::Abs((($squeezedWidths | Measure-Object -Sum).Sum) - 300) -lt 0.5) "$((($squeezedWidths | Measure-Object -Sum).Sum))"

    Test-MhSection 'the document itself'

    $folder = Join-Path ([System.IO.Path]::GetTempPath()) ('mh-doc-' + [guid]::NewGuid().ToString('n').Substring(0, 8))
    [void](New-Item -ItemType Directory -Path $folder)
    try {
        # long enough to need a second page, so that pagination and the repeated table header are
        # exercised rather than assumed
        $long = $sample + "`n`n" + (1..14 | ForEach-Object {
            "## Section $_`n`nA paragraph about section $_, with a ``code span`` and some **bold** in it, long enough to wrap onto a second line on the page.`n`n| Item | Note |`n|---|---|`n| $_ | something worth saying about it |"
        }) -join "`n`n"
        $md = Join-Path $folder 'sample.md'
        # an arrow: Windows-1252 has no byte for one, and it must not simply vanish
        [System.IO.File]::WriteAllText($md, ($long + "`n`nreporting box " + [char]0x2192 + " targets`n"), [System.Text.Encoding]::UTF8)

        $pdf = Convert-MhMarkdownToPdf -Path $md 6>$null
        Test-MhCheck 'the PDF is written beside the Markdown' (Test-Path -LiteralPath $pdf) $pdf

        $bytes = [System.IO.File]::ReadAllBytes($pdf)
        $content = [System.Text.Encoding]::GetEncoding(1252).GetString($bytes)
        Test-MhCheck 'it is a PDF' ($content.StartsWith('%PDF'))
        $pageCount = [int]([regex]::Match($content, '/Count (\d+)').Groups[1].Value)
        Test-MhCheck 'it runs to more than one page' ($pageCount -gt 1) "$pageCount pages"
        Test-MhCheck 'the title comes from the first heading, not the file name' ($content -match '/Title \(The title\)')
        Test-MhCheck 'the pages are numbered, and know how many there are' ($content -match "\(Page 1 of $pageCount\)")
        Test-MhCheck 'all four fonts are declared' (@([regex]::Matches($content, '/BaseFont')).Count -eq 4)
        # every word is placed separately, so the arrow is its own string rather than part of a line
        Test-MhCheck 'an arrow is written as what it means rather than lost' ($content -match '\(->\) Tj')
        Test-MhCheck 'and nothing in it came out as a question mark' ($content -notmatch '\(\?\) Tj')
        Test-MhCheck 'the table header is drawn once per page the table runs onto' `
            (@([regex]::Matches($content, '\(Note\) Tj')).Count -ge 1)

        # The check that matters: nothing is drawn outside the margins. Everything above can pass
        # with text sitting in the gutter - a PDF will happily place a string off the paper, and
        # only measuring every string that was actually written shows it.
        $margin = 52.0
        $outside = @()
        foreach ($match in [regex]::Matches($content, 'BT (/F\d) ([\d.]+) Tf ([\d.-]+) ([\d.-]+) Td \((.*?)\) Tj ET')) {
            $font = @{ '/F1' = 'Body'; '/F2' = 'Bold'; '/F3' = 'Mono'; '/F4' = 'Italic' }[$match.Groups[1].Value]
            $size = [double]$match.Groups[2].Value
            $x = [double]$match.Groups[3].Value
            $y = [double]$match.Groups[4].Value
            $drawn = $match.Groups[5].Value -replace '\\\(', '(' -replace '\\\)', ')' -replace '\\\\', '\'
            $right = $x + (Get-MhPdfTextWidth -Text $drawn -Size $size -Font $font)
            if ($x -lt ($margin - 0.5) -or $right -gt (595.0 - $margin + 0.5) -or $y -lt 40 -or $y -gt 815) {
                $outside += ('{0} at {1},{2} ends {3}' -f $drawn, [int]$x, [int]$y, [int]$right)
            }
        }
        Test-MhCheck 'every string that was written lands inside the margins' (-not $outside.Count) (($outside | Select-Object -First 3) -join ' / ')
        Test-MhCheck 'and there was plenty of text to check' (@([regex]::Matches($content, ' Tj ET')).Count -gt 200) `
            "$(@([regex]::Matches($content, ' Tj ET')).Count) strings"
    }
    finally { Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue }
}
