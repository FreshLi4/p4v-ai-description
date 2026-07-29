param(
    [string]$Changelist = "default"
)

$ErrorActionPreference = "Stop"
$MaxDiffBytes = 120000
$MaxFiles = 500

function Stop-WithMessage([string]$Message, [string]$Detail = "") {
    Write-Error ("p4-ai-description: " + $Message)
    if ($Detail.Trim()) {
        Write-Error $Detail.Trim().Substring(0, [Math]::Min(2000, $Detail.Trim().Length))
    }
    exit 1
}

if ([string]::IsNullOrWhiteSpace($Changelist) -or $Changelist.StartsWith("%")) {
    $Changelist = "default"
}

$p4Command = $env:P4_BIN
if ([string]::IsNullOrWhiteSpace($p4Command)) {
    $p4Command = (Get-Command p4.exe -ErrorAction SilentlyContinue).Source
}
if ([string]::IsNullOrWhiteSpace($p4Command)) {
    Stop-WithMessage "p4.exe was not found in PATH."
}

$codexCommand = $env:CODEX_BIN
if ([string]::IsNullOrWhiteSpace($codexCommand)) {
    $codexCommand = (Get-Command codex.exe -ErrorAction SilentlyContinue).Source
}
if ([string]::IsNullOrWhiteSpace($codexCommand)) {
    Stop-WithMessage "codex.exe was not found in PATH. Install/login to Codex CLI first."
}

$infoLines = @(& $p4Command info 2>&1)
if ($LASTEXITCODE -ne 0) {
    Stop-WithMessage "could not run p4 info." ($infoLines -join "`n")
}

$rootLine = $infoLines | Where-Object { $_ -match '^Client root:\s*(.+)$' } | Select-Object -First 1
$clientLine = $infoLines | Where-Object { $_ -match '^Client name:\s*(.+)$' } | Select-Object -First 1
if (-not $rootLine -or -not $clientLine) {
    Stop-WithMessage "could not determine the P4 client root/name from p4 info."
}
$workspaceRoot = [regex]::Match($rootLine, '^Client root:\s*(.+)$').Groups[1].Value.Trim()
$clientName = [regex]::Match($clientLine, '^Client name:\s*(.+)$').Groups[1].Value.Trim()

$openedLines = @(& $p4Command -ztag opened -c $Changelist 2>&1)
if ($LASTEXITCODE -ne 0) {
    Stop-WithMessage "could not read changelist $Changelist." ($openedLines -join "`n")
}

$records = [System.Collections.Generic.List[hashtable]]::new()
$current = @{}
foreach ($line in $openedLines) {
    if ($line -match '^\.\.\. (\S+)(?: (.*))?$') {
        $key = $Matches[1]
        $value = if ($null -eq $Matches[2]) { "" } else { $Matches[2] }
        if ($key -eq "depotFile" -and $current.Count -gt 0) {
            $records.Add($current)
            $current = @{}
        }
        $current[$key] = $value
    }
}
if ($current.Count -gt 0) {
    $records.Add($current)
}

if ($records.Count -eq 0) {
    Stop-WithMessage "no opened files in changelist $Changelist for $clientName."
}

$selectedRecords = @($records | Select-Object -First $MaxFiles)
$depotFiles = @($selectedRecords | ForEach-Object { $_["depotFile"] })
$diffLines = @(& $p4Command diff -du @depotFiles 2>&1)
$diffText = ($diffLines -join "`n").Trim()
$diffBytes = [Text.Encoding]::UTF8.GetBytes($diffText)
if ($diffBytes.Length -gt $MaxDiffBytes) {
    $diffText = [Text.Encoding]::UTF8.GetString($diffBytes, 0, $MaxDiffBytes) + "`n[diff truncated for AI context]"
}

$fileLines = @($selectedRecords | ForEach-Object {
    $action = if ($_["action"]) { $_["action"] } else { "open" }
    $type = if ($_["type"]) { $_["type"] } else { "" }
    "- $action $($_["depotFile"]) ($type)"
})
if ($records.Count -gt $MaxFiles) {
    $fileLines += "- [and $($records.Count - $MaxFiles) more files]"
}

$prompt = @"
Generate a concise Perforce changelist description.

Rules:
- Output only the final description, with no preamble and no code fence.
- First line: an imperative summary, <= 72 characters.
- Then 1-5 bullet points describing the meaningful changes.
- Do not claim tests, builds, or behavior unless the evidence below supports it.
- Mention platform or stream context only when it is useful.
- Ignore generated noise and focus on the intent visible in the file list and diff.

Perforce client: $clientName
Changelist: $Changelist

Opened files:
$($fileLines -join "`n")

Diff:
$(if ($diffText) { $diffText } else { "[No textual diff; rely on the opened-file actions and names.]" })
"@

$outputPath = [IO.Path]::GetTempFileName()
$errorPath = [IO.Path]::GetTempFileName()
try {
    $prompt | & $codexCommand exec --ephemeral --ignore-user-config --skip-git-repo-check -s read-only --color never -C $workspaceRoot -o $outputPath - 2> $errorPath | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Stop-WithMessage "AI generation failed." (Get-Content -Raw -LiteralPath $errorPath)
    }
    $description = (Get-Content -Raw -LiteralPath $outputPath).Trim()
    if ([string]::IsNullOrWhiteSpace($description)) {
        Stop-WithMessage "AI returned an empty description." (Get-Content -Raw -LiteralPath $errorPath)
    }

    try {
        Set-Clipboard -Value $description
    } catch {
        $description | clip.exe
    }
    Write-Output $description
} finally {
    Remove-Item -LiteralPath $outputPath, $errorPath -Force -ErrorAction SilentlyContinue
}
