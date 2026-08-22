param(
    [string]$Changelist = "default"
)

$ErrorActionPreference = "Stop"
$MaxDiffBytes = 120000
$MaxFiles = 500
$LogPath = $env:P4V_AI_LOG
if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path $env:TEMP "p4v-ai-description.log"
}
$CodexRuntimeRoot = $env:P4V_AI_CODEX_HOME
if ([string]::IsNullOrWhiteSpace($CodexRuntimeRoot)) {
    $CodexRuntimeRoot = Join-Path $env:TEMP "p4v-ai-codex-home"
}
$CodexModel = $env:P4V_AI_MODEL
if ([string]::IsNullOrWhiteSpace($CodexModel)) {
    $CodexModel = "gpt-5.5"
}
$AiProvider = $env:P4V_AI_PROVIDER
if ([string]::IsNullOrWhiteSpace($AiProvider)) {
    $AiProvider = "codex"
}
$AiProvider = $AiProvider.Trim().ToLowerInvariant()
$AiModel = $env:P4V_AI_MODEL
if ($AiProvider -eq "codex" -and [string]::IsNullOrWhiteSpace($AiModel)) {
    $AiModel = $CodexModel
}

function Write-Log([string]$Message) {
    try {
        $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
        Add-Content -LiteralPath $LogPath -Value ("$timestamp $Message") -Encoding UTF8
    } catch {
        # Logging must never prevent the custom tool from running.
    }
}

function Resolve-CommandPath([string[]]$Names) {
    foreach ($name in $Names) {
        $command = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command -and -not [string]::IsNullOrWhiteSpace($command.Source)) {
            return $command.Source
        }
    }
    return $null
}

function Invoke-P4Capture([string[]]$Arguments) {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $capturedLines = @(& $p4Command @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    [pscustomobject]@{
        ExitCode = $exitCode
        Lines = $capturedLines
    }
}

function Stop-WithMessage([string]$Message, [string]$Detail = "") {
    Write-Log "ERROR: $Message"
    if ($Detail.Trim()) {
        Write-Log ("DETAIL: " + $Detail.Trim().Substring(0, [Math]::Min(4000, $Detail.Trim().Length)))
    }
    Write-Error ("p4-ai-description: " + $Message)
    if ($Detail.Trim()) {
        Write-Error $Detail.Trim().Substring(0, [Math]::Min(2000, $Detail.Trim().Length))
    }
    exit 1
}

if ($AiProvider -notin @("codex", "opencode")) {
    Stop-WithMessage "unsupported AI provider '$AiProvider'. Use codex or opencode."
}

if ([string]::IsNullOrWhiteSpace($Changelist) -or $Changelist.StartsWith("%")) {
    $Changelist = "default"
}

Write-Log "----- START changelist=$Changelist log=$LogPath -----"
Write-Log ("P4PORT={0} P4USER={1} P4CLIENT={2} P4CONFIG={3}" -f $env:P4PORT, $env:P4USER, $env:P4CLIENT, $env:P4CONFIG)

$p4Command = $env:P4_BIN
if ([string]::IsNullOrWhiteSpace($p4Command)) {
    $p4Command = (Get-Command p4.exe -ErrorAction SilentlyContinue).Source
}
if ([string]::IsNullOrWhiteSpace($p4Command)) {
    Stop-WithMessage "p4.exe was not found in PATH."
}
Write-Log "p4=$p4Command"

$aiCommand = $env:P4V_AI_BIN
if ([string]::IsNullOrWhiteSpace($aiCommand)) {
    if ($AiProvider -eq "codex") {
        $aiCommand = $env:CODEX_BIN
        if ([string]::IsNullOrWhiteSpace($aiCommand)) {
            $npmCodexBinary = Join-Path $env:APPDATA "npm\node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\codex\codex.exe"
            if (Test-Path -LiteralPath $npmCodexBinary) {
                $aiCommand = $npmCodexBinary
            }
        }
        if ([string]::IsNullOrWhiteSpace($aiCommand)) {
            # Prefer the npm launcher. On Windows, the packaged codex.exe app alias
            # can be discoverable in PATH but still reject child-process execution.
            $aiCommand = Resolve-CommandPath @("codex.cmd", "codex.ps1", "codex.exe")
        }
    } else {
        $aiCommand = $env:P4V_AI_OPENCODE_BIN
        if ([string]::IsNullOrWhiteSpace($aiCommand)) {
            $aiCommand = $env:OPENCODE_BIN
        }
        if ([string]::IsNullOrWhiteSpace($aiCommand)) {
            $aiCommand = Resolve-CommandPath @("opencode.cmd", "opencode.ps1", "opencode.exe")
        }
    }
}
if ([string]::IsNullOrWhiteSpace($aiCommand)) {
    if ($AiProvider -eq "codex") {
        Stop-WithMessage "Codex CLI was not found in PATH. Install/login to Codex CLI first."
    } else {
        Stop-WithMessage "OpenCode CLI was not found in PATH. Install it and run 'opencode auth login' first."
    }
}
Write-Log "provider=$AiProvider ai=$aiCommand model=$AiModel"
$originalOpenCodeApiKey = $env:OPENCODE_API_KEY

if ($AiProvider -eq "codex") {
    $codexAuthSource = Join-Path $env:USERPROFILE ".codex\auth.json"
    $codexAuthTarget = Join-Path $CodexRuntimeRoot "auth.json"
    if (-not (Test-Path -LiteralPath $codexAuthSource)) {
        Stop-WithMessage "Codex auth.json was not found." "Expected $codexAuthSource"
    }
    try {
        New-Item -ItemType Directory -Force -Path $CodexRuntimeRoot, (Join-Path $CodexRuntimeRoot ".tmp") | Out-Null
        Copy-Item -LiteralPath $codexAuthSource -Destination $codexAuthTarget -Force
        Write-Log "prepared isolated Codex home and copied auth.json"
    } catch {
        Stop-WithMessage "could not prepare isolated Codex home." $_.Exception.Message
    }
} else {
    if (-not [string]::IsNullOrWhiteSpace($env:P4V_AI_OPENCODE_API_KEY) -and
        [string]::IsNullOrWhiteSpace($env:OPENCODE_API_KEY)) {
        $env:OPENCODE_API_KEY = $env:P4V_AI_OPENCODE_API_KEY
        Write-Log "using OPENCODE_API_KEY supplied through P4V_AI_OPENCODE_API_KEY"
    } else {
        Write-Log "using OpenCode's configured auth (auth file or environment)"
    }
}

$infoResult = Invoke-P4Capture @("info")
$infoLines = @($infoResult.Lines)
Write-Log ("p4 info exit={0} lines={1}" -f $infoResult.ExitCode, $infoLines.Count)
if ($infoResult.ExitCode -ne 0) {
    Stop-WithMessage "could not run p4 info." ($infoLines -join "`n")
}

$rootLine = $infoLines | Where-Object { $_ -match '^Client root:\s*(.+)$' } | Select-Object -First 1
$clientLine = $infoLines | Where-Object { $_ -match '^Client name:\s*(.+)$' } | Select-Object -First 1
if (-not $rootLine -or -not $clientLine) {
    Stop-WithMessage "could not determine the P4 client root/name from p4 info."
}
$workspaceRoot = [regex]::Match($rootLine, '^Client root:\s*(.+)$').Groups[1].Value.Trim()
$clientName = [regex]::Match($clientLine, '^Client name:\s*(.+)$').Groups[1].Value.Trim()

$openedResult = Invoke-P4Capture @("-ztag", "opened", "-c", $Changelist)
$openedLines = @($openedResult.Lines)
Write-Log ("p4 opened exit={0} lines={1}" -f $openedResult.ExitCode, $openedLines.Count)
if ($openedResult.ExitCode -ne 0) {
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
$diffableRecords = @($selectedRecords | Where-Object {
    $action = if ($_['action']) { [string]$_['action'] } else { "" }
    $type = if ($_['type']) { [string]$_['type'] } else { "" }
    $action -notmatch '^(add|move/add|purge)$' -and
        $type -notmatch '(?i)(binary|ubinary|xbinary|resource|apple)'
})
Write-Log ("records={0} selected={1} diffable={2}" -f $records.Count, $selectedRecords.Count, $diffableRecords.Count)

$diffParts = [System.Collections.Generic.List[string]]::new()
foreach ($record in $diffableRecords) {
    $depotFile = [string]$record["depotFile"]
    $diffResult = Invoke-P4Capture @("diff", "-du", $depotFile)
    if ($diffResult.ExitCode -eq 0) {
        foreach ($line in $diffResult.Lines) {
            [void]$diffParts.Add([string]$line)
        }
    } else {
        Write-Log ("p4 diff skipped exit={0} file={1} detail={2}" -f $diffResult.ExitCode, $depotFile, (($diffResult.Lines -join " ").Trim()))
    }
}

$diffText = ($diffParts -join "`n").Trim()
$diffBytes = [Text.Encoding]::UTF8.GetBytes($diffText)
if ($diffBytes.Length -gt $MaxDiffBytes) {
    $diffText = [Text.Encoding]::UTF8.GetString($diffBytes, 0, $MaxDiffBytes) + "`n[diff truncated for AI context]"
}
Write-Log ("diffChars={0} diffBytes={1}" -f $diffText.Length, $diffBytes.Length)

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
$previousCodexHome = $env:CODEX_HOME
$previousOpenCodeApiKey = $originalOpenCodeApiKey
try {
    Write-Log ("starting provider={0} model={1} promptChars={2} workspace={3}" -f $AiProvider, $AiModel, $prompt.Length, $workspaceRoot)
    $previousCodexErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        if ($AiProvider -eq "codex") {
            $env:CODEX_HOME = $CodexRuntimeRoot
            $prompt | & $aiCommand exec --ephemeral --ignore-user-config --skip-git-repo-check -m $AiModel -s read-only --color never -C $workspaceRoot -o $outputPath - 2> $errorPath | Out-Null
            $aiExitCode = $LASTEXITCODE
        } else {
            $openCodeArguments = @("run", "--format", "json", "--dir", $workspaceRoot)
            if (-not [string]::IsNullOrWhiteSpace($AiModel)) {
                $openCodeArguments += @("--model", $AiModel)
            }
            # OpenCode reads piped stdin and emits newline-delimited JSON events.
            $prompt | & $aiCommand @openCodeArguments 2> $errorPath > $outputPath
            $aiExitCode = $LASTEXITCODE
        }
    } finally {
        $ErrorActionPreference = $previousCodexErrorActionPreference
    }
    $aiError = if (Test-Path -LiteralPath $errorPath) { (Get-Content -Raw -LiteralPath $errorPath).Trim() } else { "" }
    $description = ""
    if ($AiProvider -eq "codex") {
        $description = (Get-Content -Raw -LiteralPath $outputPath).Trim()
    } else {
        $openCodeErrors = [System.Collections.Generic.List[string]]::new()
        foreach ($line in @(Get-Content -LiteralPath $outputPath)) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }
            try {
                $event = $line | ConvertFrom-Json
            } catch {
                continue
            }
            if ($event.type -eq "text" -and $event.part -and -not [string]::IsNullOrWhiteSpace([string]$event.part.text)) {
                # The final text event contains the complete assistant answer.
                $description = [string]$event.part.text
            } elseif ($event.type -eq "error" -and $event.error) {
                [void]$openCodeErrors.Add(([string]$event.error))
            }
        }
        if ($openCodeErrors.Count -gt 0) {
            $aiError = (($openCodeErrors -join "`n") + "`n" + $aiError).Trim()
        }
    }
    Write-Log ("ai exit={0} stderr={1}" -f $aiExitCode, $aiError)
    if ($aiExitCode -ne 0) {
        Stop-WithMessage "AI generation failed." $aiError
    }
    Write-Log ("descriptionChars={0} description={1}" -f $description.Length, $description)
    if ([string]::IsNullOrWhiteSpace($description)) {
        Stop-WithMessage "AI returned an empty description." $aiError
    }

    try {
        Set-Clipboard -Value $description
        Write-Log "clipboard=Set-Clipboard succeeded"
    } catch {
        $description | clip.exe
        Write-Log "clipboard=clip.exe fallback used"
    }
    Write-Output $description
} catch {
    $detail = $_.Exception.Message
    Write-Log ("AI invocation exception={0}" -f $detail)
    Stop-WithMessage "AI generation failed." $detail
} finally {
    if ($null -eq $previousCodexHome) {
        Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue
    } else {
        $env:CODEX_HOME = $previousCodexHome
    }
    if ($null -eq $previousOpenCodeApiKey) {
        Remove-Item Env:OPENCODE_API_KEY -ErrorAction SilentlyContinue
    } else {
        $env:OPENCODE_API_KEY = $previousOpenCodeApiKey
    }
    Remove-Item -LiteralPath $outputPath, $errorPath -Force -ErrorAction SilentlyContinue
    Write-Log "----- END -----"
}
