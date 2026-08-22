# P4V AI Changelist Description

Generate a draft Perforce changelist description from the selected pending changelist's opened files and diff.

The tool only generates and copies a draft to the clipboard. It does not edit, submit, revert, or sync files.

## Layout

- `mac/` — macOS Python launcher for the Codex CLI and a P4V import file.
- `win/` — Windows PowerShell launcher for the Codex CLI and a P4V import file.

## Windows setup

1. Clone or download this repository on Windows. The included XML assumes `C:\Tools\p4v-ai-description`.
2. Make sure `p4.exe` is in `PATH` and that `codex.exe` is installed and logged in:

   ```powershell
   codex login
   ```

3. If the repository is somewhere else, edit `win/p4v-customtools.xml` and change the `-File` path.
4. In P4V, choose `Tools > Manage Tools > Import Custom Tools...` and import `win/p4v-customtools.xml`.
5. Select a pending changelist and choose `AI Generate Changelist Description` from `Tools` or the changelist context menu.
6. Paste the clipboard contents into the changelist Description and review it before submitting.

P4V passes the active `P4PORT`, `P4USER`, and `P4CLIENT` to the external tool. The script does not contain credentials. If a local `P4CONFIG` overrides those settings, enable P4V's **Ignore P4CONFIG files** option for this custom tool.

## Windows troubleshooting

- The script writes a diagnostic log to `%TEMP%\p4v-ai-description.log`.
- P4V's Log pane is for P4V/P4 command activity and does not capture arbitrary stdout/stderr from an external custom tool. The imported definition enables **Run tool in terminal window** so the process output remains visible.
- The tool skips binary and newly added files when building the diff context. This prevents `p4 diff` errors for add-only files while still listing their actions for the AI.
- The CLI uses an isolated cache under `%TEMP%\p4v-ai-codex-home` and copies the existing local Codex login token there. This avoids incompatibilities between the desktop app's model cache and the npm CLI cache.

## AI provider selection (Windows)

Codex remains the default provider. To use OpenCode instead, configure the P4V process environment before starting P4V:

```powershell
$env:P4V_AI_PROVIDER = "opencode"
# Optional; verify the model ID with `opencode models`.
$env:P4V_AI_MODEL = "opencode-go/kimi-k2.6"
```

OpenCode owns its authentication. Run `opencode auth login` once, or provide an API key through `OPENCODE_API_KEY` (or `P4V_AI_OPENCODE_API_KEY`). The key is passed only to the child process and is not written to this repository. For a custom OpenAI-compatible endpoint, configure that provider in OpenCode's `opencode.jsonc` and set `P4V_AI_MODEL` to its `provider/model` ID.

The launcher calls `opencode run --format json` and extracts the final `text` event, so the same P4V custom tool works with either Codex or OpenCode. Set `P4V_AI_BIN` to an explicit executable path when P4V does not inherit the expected PATH. Restart P4V after changing environment variables.

The error `could not run p4 info` is a Perforce preflight failure, before either AI provider is started. Check the effective `P4PORT` in `%TEMP%\p4v-ai-description.log`; the P4V connection and the interactive shell can have different server settings.

## macOS setup

The current Mac installation uses `/Users/taobe/.local/bin/p4-ai-description` and `mac/p4v-customtools.xml`. For another Mac, install the Python file as an executable and update the `<Command>` path in the XML before importing it.

The macOS and Windows launchers use the local Codex CLI. The selected changelist diff is sent to the Codex service for generation; no automatic submit is performed.

## License

Internal FreshLi4 tooling.
