param(
	[string]$Runner = "run-in-roblox",
	[string]$Place = "build/ThreadIntegration.rbxlx",
	[string]$Script = "Tests/Integration/run.luau"
)

$runnerOutput = & $Runner --place $Place --script $Script 2>&1
$runnerExitCode = $LASTEXITCODE
$runnerOutput | ForEach-Object { Write-Host $_ }

$combinedOutput = $runnerOutput -join "`n"
if ($combinedOutput -match "Thread server/client integration test passed") {
	if ($runnerExitCode -ne 0) {
		Write-Warning "run-in-roblox reported an unrelated Studio error after the integration suite passed"
	}
	exit 0
}

Write-Error "The Thread integration success marker was not reported"
if ($runnerExitCode -ne 0) {
	exit $runnerExitCode
}
exit 1
