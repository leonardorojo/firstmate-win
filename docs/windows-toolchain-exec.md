# Windows tool execution from WSL

Use `fmw win exec` for one explicit Windows executable from a Windows-mounted WSL directory:

```text
fmw win exec --cwd /mnt/c/FirstmateWorktrees/My\ Project -- dotnet.exe --version
fmw win exec --cwd /mnt/c/FirstmateWorktrees/My\ Project --report -- MSBuild.exe My.sln
fmw win exec --cwd /mnt/c/FirstmateWorktrees/My\ Project --backend powershell -- dotnet.exe --info
```

The `--` separator is required.
The executable and every argument remain separate arguments.
Do not pass a shell command string; this command is not a Bash-to-PowerShell translator.

`--cwd` must be an existing absolute WSL path under `/mnt/<drive>`.
The helper converts it with `wslpath -w` and does not change the caller's cwd.
Paths and arguments containing spaces, quotes, Unicode, empty values, or leading dashes are preserved.

Executable resolution uses the portable configuration keys `WINDOWS_DOTNET` and optional `WINDOWS_MSBUILD`, then PATH for other names.
Absolute WSL `.exe` paths and Windows drive paths are accepted.
No filesystem-wide search or version update is performed.

Direct execution is the default and preserves child stdout, stderr, and exit code.
`--backend powershell` is explicit and uses PowerShell literal quoting plus an argument array only when a Windows Location/invocation wrapper is needed.
`--report` writes a bounded `fmw-report` line to stderr with the WSL cwd, Windows cwd, resolved executable, backend, and child exit code.

The helper does not create tasks or worktrees, acquire locks, arm watchers, invoke Treehouse, or build a project.
