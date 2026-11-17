# Removes every POC change from your checkout of the company repo.
# Usage: .\99_remove_overlay.ps1 -Repo C:\path\to\company-repo
param([Parameter(Mandatory)][string]$Repo)
Push-Location $Repo
git checkout -- apps/super_app/pubspec.yaml apps/super_app/lib/Investor/presentation/landingpage/landing_page_header/landingpage_header.dart pubspec.lock
Remove-Item packages\mo_genui -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item apps\super_app\android\app\src\uat -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Removed. git status:"; git status --short
Pop-Location
