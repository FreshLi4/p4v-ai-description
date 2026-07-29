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

## macOS setup

The current Mac installation uses `/Users/taobe/.local/bin/p4-ai-description` and `mac/p4v-customtools.xml`. For another Mac, install the Python file as an executable and update the `<Command>` path in the XML before importing it.

The macOS and Windows launchers use the local Codex CLI. The selected changelist diff is sent to the Codex service for generation; no automatic submit is performed.

## License

Internal FreshLi4 tooling.
