# Runs the automated tests on a temporary copy of src\. They never touch your
# installed copy, power settings or services. From PowerShell:
#   powershell -ExecutionPolicy Bypass -File tests\run.ps1
$repo = Split-Path $PSScriptRoot -Parent
$tmp = Join-Path $env:TEMP 'lsm-test-src'
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory $tmp | Out-Null
Copy-Item (Join-Path $repo 'src\*'), (Join-Path $PSScriptRoot '*.ps1') $tmp
Remove-Item (Join-Path $tmp 'run.ps1')
$status = 0
foreach ($t in Get-ChildItem $tmp -Filter '*.Tests.ps1') {
    "== $($t.Name)"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $t.FullName -Src $tmp
    if ($LASTEXITCODE -ne 0) { $status = 1 }
}
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
exit $status
