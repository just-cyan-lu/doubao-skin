$manager = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "manage-doubao-skin-windows.ps1"
& $manager "disable"
exit $LASTEXITCODE
