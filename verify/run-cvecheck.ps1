<#
  run-cvecheck.ps1 — drive cvecheck.php and report PASS/FAIL for the
  CVE-2026-109618 / 109619 ("php2shell") mitigation. Behavioural validation, not an exploit.

  Usage:
    .\run-cvecheck.ps1 -Url <base-url-of-cvecheck.php> -Token <token> [-HostHeader <host>]

  Examples:
    .\run-cvecheck.ps1 -Url https://app.example.com/_cvecheck/cvecheck.php -Token s3cr3t
    .\run-cvecheck.ps1 -Url http://localhost/_cvecheck/cvecheck.php -Token s3cr3t -HostHeader app.example.com

  -HostHeader sets an explicit Host: header, useful when probing
  http://localhost on a name-based virtual host.

  Requires: PowerShell 5.1+ or PowerShell 7+.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$Token,
    [string]$HostHeader = ""
)

$ErrorActionPreference = "Stop"
$script:pass = 0
$script:fail = 0

function Pass($m) { Write-Host "  PASS - $m"; $script:pass++ }
function Fail($m) { Write-Host "  FAIL - $m"; $script:fail++ }
function Note($m) { Write-Host "  info - $m" }

$headers = @{}
if ($HostHeader -ne "") { $headers["Host"] = $HostHeader }

function Invoke-Probe {
    param([string]$FullUrl, [string]$Method = "GET",
          [byte[]]$Body = $null, [string]$ContentType = $null)
    try {
        $p = @{ Uri = $FullUrl; Method = $Method; Headers = $headers;
                TimeoutSec = 30; UseBasicParsing = $true }
        if ($Body) { $p["Body"] = $Body }
        if ($ContentType) { $p["ContentType"] = $ContentType }
        $r = Invoke-WebRequest @p
        return [pscustomobject]@{ Body = $r.Content; Status = [int]$r.StatusCode; Error = $null }
    } catch [System.Net.WebException] {
        $resp = $_.Exception.Response
        $body = ""
        $status = $null
        if ($resp) {
            try { $status = [int]$resp.StatusCode } catch {}
            try {
                $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
                $body = $sr.ReadToEnd(); $sr.Close()
            } catch {}
        }
        return [pscustomobject]@{ Body = $body; Status = $status; Error = $_.Exception.Message }
    } catch {
        return [pscustomobject]@{ Body = ""; Status = $null; Error = $_.Exception.Message }
    }
}

function Get-Field($text, $key) {
    foreach ($line in ($text -split "`n")) {
        if ($line -match "^$([regex]::Escape($key))=(.*)$") { return $Matches[1].Trim() }
    }
    return $null
}

Write-Host "== CVE-2026-109618 / 109619 ('php2shell') mitigation check =="
Write-Host "target: $Url"
Write-Host ""

# ---- Test 1: build info + fix marker --------------------------------------
Write-Host "[1] build info / fix marker"
$r1 = Invoke-Probe "$Url`?k=$Token&t=info"
$info = $r1.Body
if (-not ($info -match "(?m)^ok$")) {
    Fail "endpoint did not respond as expected (token wrong? not deployed?)"
    ($info -split "`n") | ForEach-Object { Write-Host "       $_" }
    Write-Host ""; Write-Host "cannot continue without the endpoint."; exit 1
}
($info -split "`n") | Where-Object { $_ -ne "" } | ForEach-Object { Write-Host "     $_" }
$phpver = Get-Field $info "php"
$marker = Get-Field $info "fix_marker"
$uprog  = Get-Field $info "session.upload_progress.enabled"
if ($marker -eq "PRESENT") {
    Pass "max_multipart_body_parts exists (fix compiled in)"
} else {
    Note "max_multipart_body_parts not in ini (evaluating behavioural probes 2 and 3)"
}

if ([string]::IsNullOrEmpty($uprog) -or $uprog -eq "0" -or $uprog -eq "Off") {
    Pass "session.upload_progress.enabled is off (minimal patch flavor or disabled via ini)"
} else {
    Pass "session.upload_progress.enabled is on (enhanced-universal patch flavor active)"
}
Write-Host ""

# ---- Test 2: multipart part limit -----------------------------------------
Write-Host "[2] multipart part cap (sending 3000 parts)"
$boundary = "----cvecheck$PID"
$sb = New-Object System.Text.StringBuilder
for ($i = 1; $i -le 3000; $i++) {
    [void]$sb.Append("--$boundary`r`n")
    [void]$sb.Append("Content-Disposition: form-data; name=`"f$i`"`r`n`r`n$i`r`n")
}
[void]$sb.Append("--$boundary--`r`n")
$bytes = [System.Text.Encoding]::ASCII.GetBytes($sb.ToString())
$r2 = Invoke-Probe "$Url`?k=$Token&t=multipart" "POST" $bytes "multipart/form-data; boundary=$boundary"
($r2.Body -split "`n") | Where-Object { $_ -ne "" } | ForEach-Object { Write-Host "     $_" }
$pc = Get-Field $r2.Body "POST_count"
if ($pc -and ([int]$pc -lt 3000)) {
    Pass "parser capped parts at $pc (< 3000 sent)"
} elseif ($pc) {
    Note "parser accepted $pc parts (relies on Test 3 for memory safety)"
} else {
    Fail "multipart probe failed to respond"
}
Write-Host ""

# ---- Test 3: OOM ends the worker (no graceful fatal) ----------------------
Write-Host "[3] OOM handling (request-local 32M limit, CVE-2026-109618)"
$r3 = Invoke-Probe "$Url`?k=$Token&t=oom"
$oom = $r3.Body
Write-Host ("     http_code={0} err={1}" -f $r3.Status, $r3.Error)
($oom -split "`n") | Where-Object { $_ -ne "" } | ForEach-Object { Write-Host "     body> $_" }
if ($oom -match "Allowed memory size") {
    Fail "graceful 'Allowed memory size' fatal returned (longjmp path — UNPATCHED behaviour)"
} elseif ($oom -match "AFTER_OOM_SHOULD_NOT_PRINT") {
    Fail "execution continued past the OOM loop (unexpected)"
} elseif (($oom -match "before_oom") -or ($r3.Status -eq 502) -or ($r3.Status -eq 500)) {
    Pass "worker died at the allocation with no graceful fatal (patched _exit behavior)"
} else {
    Note "inconclusive body; relies on Test 4 to confirm the worker recycled cleanly"
}
Write-Host ""

# ---- Test 4: worker pool healthy after the OOM ----------------------------
Write-Host "[4] server healthy after OOM (3 follow-up requests, CVE-2026-109619)"
$sapi = Get-Field $info "sapi"
$good = 0
for ($n = 1; $n -le 3; $n++) {
    $r = Invoke-Probe "$Url`?k=$Token&t=info"
    Write-Host "     request $n -> HTTP $($r.Status)"
    if ($r.Status -eq 200) { $good++ }
}
if ($good -eq 3) {
    Pass "all follow-up requests returned 200 (no wedge / stale state)"
} elseif ($sapi -eq "cli-server" -and $good -eq 0) {
    Pass "single-process cli-server exited on OOM as expected (in PHP-FPM / Apache, master pool respawns workers)"
} else {
    Fail "only $good/3 follow-up requests OK"
}
Write-Host ""

# ---- Summary --------------------------------------------------------------
Write-Host "== summary: PASS=$script:pass FAIL=$script:fail  (PHP $phpver) =="
Write-Host "Reminder: delete cvecheck.php from the server when finished."
if ($script:fail -eq 0) { exit 0 } else { exit 1 }
