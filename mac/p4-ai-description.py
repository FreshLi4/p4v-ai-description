#!/usr/bin/env python3
"""Generate a draft Perforce changelist description with the local Codex CLI.

The script is intended to be launched by a P4V Custom Tool.  It reads the
current P4V connection from the environment, never submits or edits the
changelist, and copies the generated draft to the macOS clipboard.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


P4_DEFAULT = "/Users/taobe/.local/bin/p4"
CODEX_DEFAULT = "/Applications/ChatGPT.app/Contents/Resources/codex"
MAX_DIFF_BYTES = 120_000
MAX_FILES = 500


def run(command: list[str], *, cwd: str | None = None, timeout: int = 30) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=cwd,
        text=True,
        encoding="utf-8",
        errors="replace",
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=False,
    )


def fail(message: str, detail: str = "") -> int:
    print(f"p4-ai-description: {message}", file=sys.stderr)
    if detail.strip():
        print(detail.strip()[-2000:], file=sys.stderr)
    return 1


def p4_info(p4: str) -> tuple[str, str]:
    result = run([p4, "info"])
    if result.returncode != 0:
        raise RuntimeError(result.stderr or result.stdout)
    root_match = re.search(r"^Client root:\s*(.+)$", result.stdout, re.MULTILINE)
    client_match = re.search(r"^Client name:\s*(.+)$", result.stdout, re.MULTILINE)
    if not root_match or not client_match:
        raise RuntimeError("could not determine P4 client root/name from p4 info")
    return root_match.group(1).strip(), client_match.group(1).strip()


def parse_opened_ztag(output: str) -> list[dict[str, str]]:
    records: list[dict[str, str]] = []
    current: dict[str, str] = {}
    for line in output.splitlines():
        if not line.startswith("... "):
            continue
        key, _, value = line[4:].partition(" ")
        if key == "depotFile" and current:
            records.append(current)
            current = {}
        if key:
            current[key] = value
    if current:
        records.append(current)
    return [record for record in records if record.get("depotFile")]


def main() -> int:
    changelist = sys.argv[1].strip() if len(sys.argv) > 1 else "default"
    if not changelist or changelist.startswith("%"):
        changelist = "default"

    p4 = os.environ.get("P4_BIN") or shutil.which("p4") or P4_DEFAULT
    if not Path(p4).exists():
        return fail(f"p4 not found at {p4}")
    if not os.environ.get("P4CLIENT"):
        return fail("P4V did not provide P4CLIENT")

    try:
        workspace_root, client_name = p4_info(p4)
        opened = run([p4, "-ztag", "opened", "-c", changelist], cwd=workspace_root)
        if opened.returncode != 0:
            return fail("could not read the changelist", opened.stderr or opened.stdout)
        records = parse_opened_ztag(opened.stdout)
        if not records:
            return fail(f"no opened files in changelist {changelist} for {client_name}")

        selected = records[:MAX_FILES]
        depot_files = [record["depotFile"] for record in selected]
        diff = run([p4, "diff", "-du", *depot_files], cwd=workspace_root, timeout=90)
        diff_text = diff.stdout.strip()
        if len(diff_text.encode("utf-8")) > MAX_DIFF_BYTES:
            diff_text = diff_text.encode("utf-8")[:MAX_DIFF_BYTES].decode("utf-8", errors="ignore")
            diff_text += "\n[diff truncated for AI context]"

        file_lines = []
        for record in selected:
            action = record.get("action", "open")
            file_type = record.get("type", "")
            file_lines.append(f"- {action} {record['depotFile']} ({file_type})")
        if len(records) > MAX_FILES:
            file_lines.append(f"- [and {len(records) - MAX_FILES} more files]")

        prompt = f"""Generate a concise Perforce changelist description.

Rules:
- Output only the final description, with no preamble and no code fence.
- First line: an imperative summary, <= 72 characters.
- Then 1-5 bullet points describing the meaningful changes.
- Do not claim tests, builds, or behavior unless the evidence below supports it.
- Mention platform or stream context only when it is useful.
- Ignore generated noise and focus on the intent visible in the file list and diff.

Perforce client: {client_name}
Changelist: {changelist}

Opened files:
{chr(10).join(file_lines)}

Diff:
{diff_text or '[No textual diff; rely on the opened-file actions and names.]'}
"""

        codex = os.environ.get("CODEX_BIN") or shutil.which("codex") or CODEX_DEFAULT
        if not Path(codex).exists():
            return fail(f"Codex CLI not found at {codex}")

        with tempfile.NamedTemporaryFile(prefix="p4-ai-description-", suffix=".txt", delete=False) as output_file:
            output_path = output_file.name
        try:
            generated = run(
                [
                    codex,
                    "exec",
                    "--ephemeral",
                    "--ignore-user-config",
                    "--skip-git-repo-check",
                    "-s",
                    "read-only",
                    "--color",
                    "never",
                    "-C",
                    workspace_root,
                    "-o",
                    output_path,
                    "-",
                ],
                cwd=workspace_root,
                timeout=180,
            )
            generated_text = Path(output_path).read_text(encoding="utf-8", errors="replace").strip()
        finally:
            try:
                Path(output_path).unlink()
            except OSError:
                pass

        if generated.returncode != 0 or not generated_text:
            return fail("AI generation failed", generated.stderr or generated.stdout)

        copied = subprocess.run(
            ["/usr/bin/pbcopy"],
            input=generated_text,
            text=True,
            encoding="utf-8",
            errors="replace",
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if copied.returncode != 0:
            return fail("could not copy the generated description to the clipboard", copied.stderr)

        subprocess.run(
            [
                "/usr/bin/osascript",
                "-e",
                'display notification "Draft copied to clipboard" with title "P4V AI Description"',
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        print(generated_text)
        return 0
    except subprocess.TimeoutExpired:
        return fail("command timed out")
    except OSError as error:
        return fail("could not run the required command", str(error))
    except RuntimeError as error:
        return fail("could not inspect the P4 workspace", str(error))


if __name__ == "__main__":
    raise SystemExit(main())
