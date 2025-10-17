
# Windows PowerShell runner
$config = Get-Content "runner/runner.config.json" | ConvertFrom-Json
$autoPush = $config.auto_push
$prefix = $config.commit_message_prefix
Write-Host "[Runner] Auto-push: $autoPush"
Write-Host "[Runner] Watching (polling every 5s) artifacts/, contracts/, src/, docs/"

$hashPrev = ""
while ($true) {
  Start-Sleep -Seconds 5
  $hashCurr = (Get-ChildItem artifacts,contracts,src,docs -Recurse -File | Get-FileHash | ForEach-Object Hash) -join ""
  if ($hashCurr -ne $hashPrev) {
    $hashPrev = $hashCurr
    try {
      bash runner/validate.sh
      git add .
      git commit -m "$prefix $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-Null
      if ($autoPush -eq $true) {
        git push origin main | Out-Null
      } else {
        Write-Host "[Runner] Auto-push disabled."
      }
    } catch {
      Write-Host "[Runner] Validation or commit failed."
    }
  }
}
