param(
    [int]$Port = 9451,
    [string]$ThemeDir = ""
)

$manager = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "manage-doubao-skin-windows.ps1"
if ([string]::IsNullOrWhiteSpace($ThemeDir)) {
    & $manager "enable-default" -Port $Port
} else {
    & $manager "activate-library" -Port $Port -ThemeDir $ThemeDir
}
exit $LASTEXITCODE
