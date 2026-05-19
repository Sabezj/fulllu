param(
    [string]$TargetRoot = "",
    [switch]$CreateZip,
    [switch]$InitGitRepo
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $TargetRoot) {
    $TargetRoot = Join-Path $repoRoot "publish"
}

$publishName = "lawvoice-official-repo"
$publishRoot = Join-Path $TargetRoot $publishName
$zipPath = Join-Path $TargetRoot "${publishName}.zip"

if (Test-Path $publishRoot) {
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $backupPath = "${publishRoot}.bak_${stamp}"
    Move-Item -LiteralPath $publishRoot -Destination $backupPath
}

New-Item -ItemType Directory -Force -Path $publishRoot | Out-Null

function Copy-RepoFile {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    $sourcePath = Join-Path $repoRoot $RelativePath
    if (-not (Test-Path $sourcePath)) {
        throw "Missing source file: $RelativePath"
    }

    $destinationPath = Join-Path $publishRoot $RelativePath
    $destinationDir = Split-Path -Parent $destinationPath
    if ($destinationDir) {
        New-Item -ItemType Directory -Force -Path $destinationDir | Out-Null
    }
    Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
}

function Get-GitExecutable {
    $preferred = @(
        "C:\Program Files\Git\cmd\git.exe",
        "C:\Program Files\Git\bin\git.exe"
    )

    foreach ($candidate in $preferred) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    $command = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($command -and $command.Source) {
        return $command.Source
    }

    throw "git.exe not found"
}

function Copy-RepoTree {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [string[]]$ExcludeDirNames = @(),
        [string[]]$ExcludeFileNames = @(),
        [string[]]$ExcludePathPatterns = @()
    )

    $sourceRoot = Join-Path $repoRoot $RelativePath
    if (-not (Test-Path $sourceRoot)) {
        throw "Missing source directory: $RelativePath"
    }

    $files = Get-ChildItem -LiteralPath $sourceRoot -Recurse -File
    foreach ($file in $files) {
        $relativeToRepo = $file.FullName.Substring($repoRoot.Length + 1)
        $segments = $relativeToRepo -split '[\\/]'

        if ($segments | Where-Object { $ExcludeDirNames -contains $_ }) {
            continue
        }

        if ($ExcludeFileNames -contains $file.Name) {
            continue
        }

        $skip = $false
        foreach ($pattern in $ExcludePathPatterns) {
            if ($relativeToRepo -like $pattern) {
                $skip = $true
                break
            }
        }
        if ($skip) {
            continue
        }

        $destinationPath = Join-Path $publishRoot $relativeToRepo
        $destinationDir = Split-Path -Parent $destinationPath
        if ($destinationDir) {
            New-Item -ItemType Directory -Force -Path $destinationDir | Out-Null
        }
        Copy-Item -LiteralPath $file.FullName -Destination $destinationPath -Force
    }
}

$rootFiles = @(
    ".dockerignore",
    ".env.example",
    "config.js",
    "docker-compose.yml",
    "Dockerfile",
    "ecosystem.config.cjs",
    "embeddingsWorker.js",
    "jest.config.js",
    "package-lock.json",
    "package.json",
    "server.js",
    "webpack.config.cjs"
)

foreach ($file in $rootFiles) {
    Copy-RepoFile -RelativePath $file
}

Copy-RepoTree -RelativePath "__tests__"
Copy-RepoTree -RelativePath "public"
Copy-RepoTree -RelativePath "src"
Copy-RepoTree -RelativePath "profiles"
Copy-RepoTree -RelativePath "services" -ExcludeDirNames @("pysearch_venv", "__pycache__")

$scriptFiles = @(
    "scripts/setup_windows.ps1",
    "scripts/setup_windows_nodocker.ps1",
    "scripts/setup_wsl.sh",
    "scripts/setup_wsl_nodocker.sh",
    "scripts/start_all.ps1",
    "scripts/start_services.bat"
)

foreach ($file in $scriptFiles) {
    Copy-RepoFile -RelativePath $file
}

$docFiles = @(
    "docs/lawvoice_general_prompt.md",
    "docs/tts_module.md",
    "docs/voice-assistant-architecture.md",
    "docs/node_patch/intentHandlers.sample.js",
    "docs/node_patch/searchClient.js"
)

foreach ($file in $docFiles) {
    Copy-RepoFile -RelativePath $file
}

$thesisSource = "C:\Users\xsanf\Downloads\Telegram Desktop\thesis.docx"
if (Test-Path $thesisSource) {
    $thesisTargetDir = Join-Path $publishRoot "docs\thesis"
    New-Item -ItemType Directory -Force -Path $thesisTargetDir | Out-Null
    Copy-Item -LiteralPath $thesisSource -Destination (Join-Path $thesisTargetDir "thesis.docx") -Force
}

$readme = @'
# LawVoice Official Repository

This directory is a cleaned publication copy of the LawVoice prototype repository.

## Scope

LawVoice is a voice-first legal literacy assistant prototype built on top of OpenAI Realtime infrastructure. This publication copy keeps the project code, core profiles, setup scripts, tests, and supporting technical documentation that are needed to review or reproduce the prototype.

## Included

- Node.js application source and static frontend
- LawVoice profiles and dialog logic
- Automated tests
- Setup scripts for Windows and WSL
- Core technical documentation
- Thesis copy in `docs/thesis/thesis.docx`

## Excluded

- Real secrets and local `.env`
- `node_modules`
- logs, caches, and generated runtime data
- local Python virtual environments
- backup dumps and unrelated admin or VPN tooling
- presentation export artifacts and other non-code working files

## Quick Start

1. Copy `.env.example` to `.env`
2. Fill in the required environment variables
3. Run `npm install`
4. Run `npm start`

## Notes

- This package is intended for official publication and review.
- If you need to rebuild it from the working repository, run `tools/create_official_publish_repo.ps1`.
- Confirm the publication license before pushing to a public remote, because the source workspace did not contain an explicit `LICENSE` file.
'@
Set-Content -LiteralPath (Join-Path $publishRoot "README.md") -Value $readme -Encoding UTF8

$gitignore = @'
node_modules/
logs/
.env
.env.local
.env.*.local
dump.rdb
*.log
services/pysearch/pysearch_venv/
services/pysearch/__pycache__/
**/__pycache__/
*.pyc
publish/
'@
Set-Content -LiteralPath (Join-Path $publishRoot ".gitignore") -Value $gitignore -Encoding UTF8

$gitattributes = @'
* text=auto
*.sh text eol=lf
*.ps1 text eol=crlf
*.bat text eol=crlf
'@
Set-Content -LiteralPath (Join-Path $publishRoot ".gitattributes") -Value $gitattributes -Encoding UTF8

$notes = @'
# Publishing Notes

This repository copy was generated from the working LawVoice project to produce a cleaner package for official publishing.

## Main cleanup decisions

- kept only project-relevant code, tests, profiles, setup scripts, and technical docs
- removed local environment secrets and runtime artifacts
- excluded vendor directories and local Python virtual environment contents
- excluded infrastructure and VPN helper files that are not part of the published prototype
- excluded presentation exports while keeping the thesis document
- left license selection for manual confirmation because the source workspace had no explicit `LICENSE` file

## Regeneration

Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\create_official_publish_repo.ps1
```
'@
Set-Content -LiteralPath (Join-Path $publishRoot "PUBLISHING_NOTES.md") -Value $notes -Encoding UTF8

$gitPublishing = @'
# Git Publishing

## Local repository

If this directory was generated without `-InitGitRepo`, initialize it with:

```powershell
git init -b main
```

## First publish flow

1. Review the content and confirm the intended license.
2. Create a public or private remote repository.
3. Run:

```powershell
git add .
git commit -m "Prepare official LawVoice publication package"
git remote add origin <REMOTE_URL>
git push -u origin main
```
'@
Set-Content -LiteralPath (Join-Path $publishRoot "GIT_PUBLISHING.md") -Value $gitPublishing -Encoding UTF8

$licenseNotice = @'
# License Notice

The source workspace used to generate this package did not contain an explicit `LICENSE` file.

Before public publication, confirm:

1. the intended license for the code;
2. the publication rights for bundled thesis and documentation materials;
3. whether any third-party assets require attribution or removal.
'@
Set-Content -LiteralPath (Join-Path $publishRoot "LICENSE_NOTICE.md") -Value $licenseNotice -Encoding UTF8

$manifest = [ordered]@{
    generated_at = (Get-Date).ToString("s")
    source_root = $repoRoot
    publish_root = $publishRoot
    zip_path = $zipPath
    thesis_included = (Test-Path $thesisSource)
    root_files = $rootFiles
    script_files = $scriptFiles
    doc_files = $docFiles
    trees = @("__tests__", "public", "src", "profiles", "services")
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $publishRoot "publish-manifest.json") -Encoding UTF8

if ($InitGitRepo) {
    Push-Location $publishRoot
    try {
        $gitExe = Get-GitExecutable
        & $gitExe init -b main | Out-Null
    } finally {
        Pop-Location
    }
}

if ($CreateZip) {
    if (Test-Path $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }
    Compress-Archive -LiteralPath $publishRoot -DestinationPath $zipPath -Force
}

Write-Output "Created publish repository: $publishRoot"
if ($InitGitRepo) {
    Write-Output "Initialized git repository: $publishRoot"
}
if ($CreateZip) {
    Write-Output "Created zip archive: $zipPath"
}
