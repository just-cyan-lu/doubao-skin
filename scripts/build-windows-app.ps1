param(
    [string]$NodeExecutable = "",
    [switch]$SkipArchive,
    [switch]$CompileNativeManager
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$scriptsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptsRoot
$outputRoot = Join-Path $projectRoot "dist\windows"
$appPath = Join-Path $outputRoot "Doubao Skin"
$temporary = Join-Path $outputRoot ("Doubao Skin.building." + $PID)
$archivePath = Join-Path $outputRoot "Doubao-Skin-Windows-PoC.zip"
$nodeVersion = "v24.16.0"
$nodeArchiveName = "node-$nodeVersion-win-x64.zip"
$nodeSha256 = "edaca9bd58ec8e92037dac4e877d52f6b8f430b81c18b57e264b4e2fb111cd56"
$cacheRoot = Join-Path $env:LOCALAPPDATA "DoubaoSkinBuildCache"
$nodeArchive = Join-Path $cacheRoot $nodeArchiveName

function Remove-ExactBuildDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    $expectedParent = [IO.Path]::GetFullPath($outputRoot).TrimEnd("\")
    $candidate = [IO.Path]::GetFullPath($Path)
    if ((Split-Path -Parent $candidate).TrimEnd("\") -ne $expectedParent -or
        (Split-Path -Leaf $candidate) -notlike "Doubao Skin.building.*") {
        throw "Refusing to remove a path outside the Windows build staging area: $Path"
    }
    if (Test-Path -LiteralPath $candidate) {
        Remove-Item -LiteralPath $candidate -Recurse -Force
    }
}

function Get-BundledNode {
    if (-not [string]::IsNullOrWhiteSpace($NodeExecutable)) {
        $candidate = (Get-Item -LiteralPath $NodeExecutable).FullName
        $version = (& $candidate --version)
        if ($LASTEXITCODE -ne 0 -or [string]$version -notmatch "^v([0-9]+)\." -or [int]$Matches[1] -lt 22) {
            throw "The supplied Node.js executable must be Windows Node.js 22 or newer."
        }
        return $candidate
    }

    New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null
    $downloadRequired = $true
    if (Test-Path -LiteralPath $nodeArchive -PathType Leaf) {
        $hash = (Get-FileHash -LiteralPath $nodeArchive -Algorithm SHA256).Hash.ToLowerInvariant()
        $downloadRequired = $hash -ne $nodeSha256
    }
    if ($downloadRequired) {
        $temporaryArchive = "$nodeArchive.download.$PID"
        Invoke-WebRequest `
            -Uri "https://nodejs.org/dist/$nodeVersion/$nodeArchiveName" `
            -OutFile $temporaryArchive `
            -UseBasicParsing
        $hash = (Get-FileHash -LiteralPath $temporaryArchive -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -ne $nodeSha256) {
            Remove-Item -LiteralPath $temporaryArchive -Force -ErrorAction SilentlyContinue
            throw "The downloaded Node.js archive failed SHA-256 verification."
        }
        Move-Item -LiteralPath $temporaryArchive -Destination $nodeArchive -Force
    }

    $extractRoot = Join-Path $outputRoot ("node.extract." + $PID)
    if (Test-Path -LiteralPath $extractRoot) {
        Remove-Item -LiteralPath $extractRoot -Recurse -Force
    }
    try {
        Expand-Archive -LiteralPath $nodeArchive -DestinationPath $extractRoot -Force
        $candidate = Join-Path $extractRoot "node-$nodeVersion-win-x64\node.exe"
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "The verified Node.js archive did not contain node.exe."
        }
        $destination = Join-Path $temporary "runtime\bin\node.exe"
        Copy-Item -LiteralPath $candidate -Destination $destination
        return $destination
    } finally {
        if (Test-Path -LiteralPath $extractRoot) {
            Remove-Item -LiteralPath $extractRoot -Recurse -Force
        }
    }
}

New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
Remove-ExactBuildDirectory -Path $temporary
New-Item -ItemType Directory -Path (Join-Path $temporary "runtime\bin") -Force | Out-Null

try {
    foreach ($entry in @(
        "assets",
        "docs",
        "presets",
        "scripts",
        "windows",
        "AGENTS.md",
        "LICENSE",
        "README.md",
        "package.json",
        "VERSION"
    )) {
        $source = Join-Path $projectRoot $entry
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $temporary "runtime") -Recurse -Force
        }
    }

    Copy-Item `
        -LiteralPath (Join-Path $projectRoot "windows\Install-DoubaoSkinPackage.ps1") `
        -Destination (Join-Path $temporary "Install Doubao Skin.ps1")
    Copy-Item `
        -LiteralPath (Join-Path $projectRoot "windows\Install-DoubaoSkinPackage.cmd") `
        -Destination (Join-Path $temporary "Install Doubao Skin.cmd")
    Copy-Item `
        -LiteralPath (Join-Path $projectRoot "windows\PACKAGE-README.zh-CN.txt") `
        -Destination (Join-Path $temporary "README-zh-CN.txt")
    Copy-Item `
        -LiteralPath (Join-Path $projectRoot "LICENSE") `
        -Destination (Join-Path $temporary "LICENSE")

    # Source trees prepared on macOS can contain Finder metadata. It is not
    # executable input and should never leak into the distributable archive.
    foreach ($metadata in @(
        Get-ChildItem -LiteralPath $temporary -Recurse -Force |
            Where-Object {
                $_.Name -eq ".DS_Store" -or
                $_.Name -eq "__MACOSX" -or
                $_.Name.StartsWith("._", [StringComparison]::Ordinal)
            } |
            Sort-Object { $_.FullName.Length } -Descending
    )) {
        Remove-Item -LiteralPath $metadata.FullName -Recurse -Force
    }

    if (-not [string]::IsNullOrWhiteSpace($NodeExecutable)) {
        $nodeDestination = Join-Path $temporary "runtime\bin\node.exe"
        Copy-Item -LiteralPath (Get-BundledNode) -Destination $nodeDestination -Force
    } else {
        Get-BundledNode | Out-Null
        $nodeDestination = Join-Path $temporary "runtime\bin\node.exe"
    }

    if ($CompileNativeManager) {
        $cscCandidates = @(
            "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
            "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
        )
        $csc = $cscCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace([string]$csc)) {
            throw "The .NET Framework C# compiler was not found."
        }

        $frameworkDirectory = Split-Path -Parent $csc
        $sourcePath = Join-Path $projectRoot "windows\DoubaoSkinApp.cs"
        $managerPath = Join-Path $temporary "Doubao Skin.exe"
        & $csc `
            /nologo `
            /target:winexe `
            /optimize+ `
            /platform:anycpu `
            /codepage:65001 `
            ("/win32icon:" + (Join-Path $projectRoot "assets\DoubaoSkin.ico")) `
            ("/win32manifest:" + (Join-Path $projectRoot "windows\DoubaoSkinApp.manifest")) `
            ("/out:" + $managerPath) `
            ("/reference:" + (Join-Path $frameworkDirectory "System.dll")) `
            ("/reference:" + (Join-Path $frameworkDirectory "System.Core.dll")) `
            ("/reference:" + (Join-Path $frameworkDirectory "System.Drawing.dll")) `
            ("/reference:" + (Join-Path $frameworkDirectory "System.Management.dll")) `
            ("/reference:" + (Join-Path $frameworkDirectory "System.Web.Extensions.dll")) `
            ("/reference:" + (Join-Path $frameworkDirectory "System.Windows.Forms.dll")) `
            $sourcePath
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $managerPath -PathType Leaf)) {
            throw "The optional native Windows manager could not be compiled."
        }
        Copy-Item `
            -LiteralPath (Join-Path $projectRoot "windows\DoubaoSkinApp.exe.config") `
            -Destination (Join-Path $temporary "Doubao Skin.exe.config")
    }

    & $nodeDestination `
        (Join-Path $temporary "runtime\scripts\injector.mjs") `
        --check `
        --preset mbti-boy-infp | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "The packaged Windows runtime failed theme validation."
    }

    if (Test-Path -LiteralPath $appPath) {
        $existingRuntime = Join-Path $appPath "runtime\assets\windows-app-identity.json"
        if (-not (Test-Path -LiteralPath $existingRuntime -PathType Leaf)) {
            throw "Refusing to replace a dist directory that does not belong to Doubao Skin."
        }
        Remove-Item -LiteralPath $appPath -Recurse -Force
    }
    Move-Item -LiteralPath $temporary -Destination $appPath

    if (-not $SkipArchive) {
        if (Test-Path -LiteralPath $archivePath) {
            Remove-Item -LiteralPath $archivePath -Force
        }
        Compress-Archive `
            -Path (Join-Path $appPath "*") `
            -DestinationPath $archivePath `
            -CompressionLevel Optimal
    }
    Write-Output $appPath
} finally {
    if (Test-Path -LiteralPath $temporary) {
        Remove-ExactBuildDirectory -Path $temporary
    }
}
