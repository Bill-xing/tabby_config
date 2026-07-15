param(
    [string]$RepoRoot = $(Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'

function Require-Winget {
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        throw 'winget.exe was not found. Install App Installer from Microsoft Store first.'
    }
}

Require-Winget

winget.exe install -e --id MSYS2.MSYS2 --accept-package-agreements --accept-source-agreements
winget.exe install -e --id Wez.WezTerm --accept-package-agreements --accept-source-agreements
winget.exe install -e --id JesseDuffield.lazygit --accept-package-agreements --accept-source-agreements

$bash = 'C:\msys64\usr\bin\bash.exe'
if (-not (Test-Path $bash)) {
    throw 'MSYS2 was installed but C:\msys64\usr\bin\bash.exe was not found.'
}

$escapedRepoRoot = $RepoRoot.Replace('\\', '/')
& $bash -lc "cd '$escapedRepoRoot' && ./install/windows-msys2.sh"
