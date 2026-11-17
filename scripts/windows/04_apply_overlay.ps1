# Path B, step 1: adds the POC to your checkout of the company repo (mosl-riseapp-repo).
# Usage: .\04_apply_overlay.ps1 -Repo C:\path\to\company-repo [-SkipPubGet]
# Local changes only: one new package, two small edits, one new manifest. Do not commit or push them.
param([Parameter(Mandatory)][string]$Repo, [switch]$SkipPubGet)
. "$PSScriptRoot\common.ps1"
if (-not (Test-Path "$Repo\apps\super_app\pubspec.yaml")) { throw "$Repo does not look like the RIISE repo" }
Push-Location $Repo
try {
  if (Select-String -Path apps\super_app\pubspec.yaml -Pattern 'mo_genui' -Quiet) { Write-Host "host edits already present; refreshing the package only" }
  else { git apply --ignore-whitespace "$ROOT\overlay\host.patch"; if ($LASTEXITCODE) { throw "host.patch did not apply; see README troubleshooting" } }
  Remove-Item packages\mo_genui -Recurse -Force -ErrorAction SilentlyContinue
  Copy-Item "$ROOT\overlay\packages\mo_genui" packages\mo_genui -Recurse
  New-Item -ItemType Directory -Force apps\super_app\android\app\src\uat | Out-Null
  Copy-Item "$ROOT\overlay\uat_AndroidManifest.xml" apps\super_app\android\app\src\uat\AndroidManifest.xml -Force
  if (-not $SkipPubGet) {
    Push-Location apps\super_app; flutter pub get; Pop-Location
    git checkout -- pubspec.lock 2>$null   # keep the tracked lock file untouched
  }
  Write-Host "Overlay applied. git status:"; git status --short
  Write-Host ("Expected base: " + ((Get-Content "$ROOT\BASE_COMMIT") -join ' '))
} finally { Pop-Location }
