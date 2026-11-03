#Requires -Version 5.1

<#
.SYNOPSIS
    Turns a Markdown file into a PDF that anyone can open.

.DESCRIPTION
    Molehill Data Services | Convert-MarkdownToPdf

    A single file that can be copied to a server, over the real thing: everything this does lives
    in MolehillTools (Convert-MhMarkdownToPdf).

    Windows ships with nothing that opens a .md file. Sending one of these documents to a security
    team or attaching it to a change record means sending something that opens in Notepad as a page
    of pipes and asterisks, or does not open at all. This writes the same document as a PDF.

    Nothing is installed and nothing is called out to: the PDF is written here, using the fonts
    every reader already has, so it works the same on a locked-down server as on a laptop.

    It understands what these documents use - headings, paragraphs, tables, fenced code, lists,
    block quotes, bold, italic, inline code and links. Anything else is drawn as the text it is.

.PARAMETER Path
    The Markdown file to convert.

.PARAMETER OutputPath
    Where the PDF goes. Defaults to the same name and folder as the Markdown.

.PARAMETER Title
    The title for the first page and for the file's properties. Defaults to the document's first
    heading. That heading becomes the title either way rather than being drawn twice, so passing
    this replaces it rather than adding to it.

.PARAMETER Subtitle
    The line under the title. Defaults to the file name and today's date. Pass '' for none.

.PARAMETER Footer
    The line along the bottom of every page, beside the page number.

.PARAMETER Open
    Open the PDF when it is written.

.PARAMETER SelfTest
    Check the conversion - the parsing, the measuring and the file itself - with nothing to convert.

.EXAMPLE
    .\Convert-MarkdownToPdf.ps1 ..\Docs\Get-PatchStatus-Permissions.md

.EXAMPLE
    # for a ticket, where the title becomes what people read first
    .\Convert-MarkdownToPdf.ps1 ..\Docs\Get-PatchStatus-Permissions.md -Title 'Patch report: access request' -Open

.NOTES
    Molehill Data Services. Reads one file and writes one file.
#>
[CmdletBinding(DefaultParameterSetName = 'Convert')]
param(
    [Parameter(ParameterSetName = 'Convert', Mandatory, Position = 0)] [string] $Path,
    [Parameter(ParameterSetName = 'Convert')] [string] $OutputPath,
    [Parameter(ParameterSetName = 'Convert')] [string] $Title,
    [Parameter(ParameterSetName = 'Convert')] [string] $Subtitle,
    [Parameter(ParameterSetName = 'Convert')] [string] $Footer = 'Molehill Data Services',
    [Parameter(ParameterSetName = 'Convert')] [switch] $Open,
    [Parameter(ParameterSetName = 'SelfTest', Mandatory)] [switch] $SelfTest
)

$ErrorActionPreference = 'Stop'

$manifest = Join-Path $PSScriptRoot '..\MolehillTools\MolehillTools.psd1'
if (-not (Test-Path -LiteralPath $manifest)) {
    Write-Host '  MolehillTools is not where this script expects it.' -ForegroundColor Red
    Write-Host "  Looked for: $manifest" -ForegroundColor Gray
    Write-Host '  Copy the MolehillTools folder alongside Tools, or import it yourself and call Convert-MhMarkdownToPdf.' -ForegroundColor Gray
    exit 2
}
# not -Force: one shim can call another, and a forced re-import would reset the module underneath
# the caller, discarding everything it holds
if (-not (Get-Module MolehillTools)) { Import-Module $manifest }

if ($SelfTest) {
    # -Name takes one set, and the conversion is checked by two: the document and the PDF under it
    $results = @()
    foreach ($set in 'Convert-MhMarkdownToPdf', 'The PDF primitives') {
        $results += Invoke-MhSelfTest -ModuleOnly -Name $set
    }
    if (@($results | Where-Object { $_.Failed -gt 0 }).Count) { exit 1 }
    exit 0
}

# handed through by asking the function what it takes, rather than by a list here that can drift
$takes = @((Get-Command Convert-MhMarkdownToPdf).Parameters.Keys)
$arguments = @{}
foreach ($name in $PSBoundParameters.Keys) {
    if ($takes -contains $name) { $arguments[$name] = $PSBoundParameters[$name] }
}

$written = Convert-MhMarkdownToPdf @arguments
if (-not $written) { exit 1 }
exit 0
