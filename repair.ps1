<#
    Antigravity Junction Repair
    ---------------------------------------------------------------
    Moves the Antigravity data folder to another drive and replaces it
    with an NTFS directory junction, so the app keeps reading/writing
    the original path while the bytes actually live on the target drive.

    Usage:
      powershell -NoProfile -ExecutionPolicy Bypass -File repair.ps1
      powershell -NoProfile -ExecutionPolicy Bypass -File repair.ps1 -Dest E:\antigravity_data
      powershell -NoProfile -ExecutionPolicy Bypass -File repair.ps1 -Source D:\other -Dest E:\data

    The script is idempotent and never deletes data before it has verified
    that every source file reached the target.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# ---------------- arguments ----------------
$dest   = 'D:\antigravity_data'
$source = Join-Path $env:USERPROFILE '.gemini\antigravity'
for ($i = 0; $i -lt $args.Count; $i++) {
    $a = [string]$args[$i]
    if ($a -match '^(/|-{1,2})auto$')   { continue }
    if ($a -match '^(/|-{1,2})dest$')   { $i++; if ($i -lt $args.Count) { $dest   = [string]$args[$i] }; continue }
    if ($a -match '^(/|-{1,2})source$') { $i++; if ($i -lt $args.Count) { $source = [string]$args[$i] }; continue }
    if ($a -match '^(/|-{1,2})dest=(.+)$')   { $dest   = $Matches[2]; continue }
    if ($a -match '^(/|-{1,2})source=(.+)$') { $source = $Matches[2]; continue }
}

$parent  = Split-Path -Parent $source
$leaf    = Split-Path -Leaf $source
$bakPath = Join-Path $parent ($leaf + '.__bak')
$log     = Join-Path $env:TEMP ('antigravity_junction_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.log')
$utf8    = New-Object System.Text.UTF8Encoding $false

# ---------------- helpers ----------------
function Say {
    param([string]$Message, [string]$Color = 'Gray')
    $line = '[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $Message
    Write-Host $line -ForegroundColor $Color
    try { [IO.File]::AppendAllText($log, $line + "`r`n", $utf8) } catch {}
}

function Get-LinkState {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return @{ Exists = $false; IsLink = $false; Target = '' }
    }
    $item = Get-Item -LiteralPath $Path -Force
    $isLink = [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
    $target = ''
    if ($isLink) {
        $t = @($item.Target)
        if ($t.Count -gt 0 -and $t[0]) { $target = ([string]$t[0]).TrimEnd('\') }
    }
    return @{ Exists = $true; IsLink = $isLink; Target = $target }
}

function Remove-Junction {
    param([string]$Path)
    try {
        if (-not ('AgyFixNative' -as [type])) {
            Add-Type -Namespace '' -Name 'AgyFixNative' -MemberDefinition @'
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool RemoveDirectory(string lpPathName);
'@
        }
        $ok = [AgyFixNative]::RemoveDirectory($Path)
        if ($ok) { return }
    } catch {}
    & cmd /c rmdir $Path 2>&1 | Out-Null
    if (Test-Path -LiteralPath $Path) { throw "cannot remove the existing junction: $Path" }
}

function Get-FileSet {
    param([string]$Root)
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $count = 0
    $bytes = [long]0
    $prefixLen = $Root.Length + 1
    Get-ChildItem -LiteralPath $Root -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object {
        [void]$set.Add($_.FullName.Substring($prefixLen))
        $count++
        $bytes += $_.Length
    }
    return @{ Set = $set; Count = $count; Bytes = $bytes }
}

function Invoke-Robocopy {
    param([string]$From, [string]$To)
    & robocopy $From $To /E /COPY:DAT /DCOPY:T /R:2 /W:1 /NFL /NDL /NP /NJH /NJS | Out-Null
    return $LASTEXITCODE
}

function Show-Disk {
    $letters = @('C')
    $d = ($dest -split ':')[0]
    if ($d -and $d.Length -eq 1) {
        $u = $d.ToUpper()
        if ($letters -notcontains $u) { $letters += $u }
    }
    foreach ($L in $letters) {
        try {
            $drv = Get-PSDrive -Name $L -ErrorAction Stop
            Say ($L + ': ' + [math]::Round($drv.Free / 1GB, 2) + ' GB free')
        } catch {}
    }
}

# ---------------- main ----------------
try {
    Say '===== Antigravity junction repair =====' 'Cyan'
    Say ('script     : ' + $PSCommandPath)
    Say ('source dir : ' + $source)
    Say ('target dir : ' + $dest)

    if (-not (Test-Path -LiteralPath $parent)) { throw "parent folder not found: $parent" }
    $driveLetter = ($dest -split ':')[0]
    if (-not $driveLetter -or -not (Test-Path -LiteralPath ($driveLetter + ':\'))) {
        throw ("target drive is not available: " + $driveLetter + ":")
    }

    # ---- 1. close Antigravity ----
    $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match 'antig' })
    if ($running.Count -gt 0) {
        Say ('Antigravity is running (' + (($running | ForEach-Object { $_.ProcessName }) -join ', ') + '), closing it ...') 'Yellow'
        foreach ($p in $running) { try { $p.CloseMainWindow() | Out-Null } catch {} }
        Start-Sleep -Seconds 2
        foreach ($p in @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match 'antig' })) {
            try { $p.Kill() } catch {}
        }
        Start-Sleep -Seconds 2
        $left = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match 'antig' })
        if ($left.Count -gt 0) { throw 'Antigravity is still running. Close it manually and run again.' }
        Say 'Antigravity closed.' 'Yellow'
    } else {
        Say 'Antigravity is not running.'
    }

    # ---- 2. detect current state ----
    $state = Get-LinkState $source
    if ($state.Exists -and $state.IsLink) {
        Say ('state: JUNCTION -> ' + $state.Target)
    } elseif ($state.Exists) {
        Say 'state: PLAIN FOLDER (re-created, for example by an update)' 'Yellow'
    } else {
        Say 'state: PATH MISSING' 'Yellow'
    }

    # ---- 3. already correct ----
    if ($state.Exists -and $state.IsLink -and ($state.Target -ieq $dest)) {
        if (-not (Test-Path -LiteralPath $dest)) { throw "junction points to $dest but the target is missing. Check it manually." }
        $info = Get-FileSet $dest
        Say ('target content: ' + $info.Count + ' files, ' + [math]::Round($info.Bytes / 1MB, 1) + ' MB')
        Say 'result: junction already correct, nothing changed' 'Green'
        Show-Disk
        exit 0
    }

    if (-not (Test-Path -LiteralPath $dest)) {
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        Say ('created target dir: ' + $dest) 'Yellow'
    }

    $cleanup = $null

    if ($state.Exists -and $state.IsLink) {
        # junction exists but points somewhere else
        if ($state.Target -and (Test-Path -LiteralPath $state.Target) -and ($state.Target -ine $dest)) {
            Say ('merging old target into the new one: ' + $state.Target + ' -> ' + $dest)
            $rc = Invoke-Robocopy $state.Target $dest
            Say ('robocopy exit = ' + $rc)
            if ($rc -ge 8) { throw "robocopy failed (exit $rc). Nothing was deleted." }
        }
        Remove-Junction $source
        Say 'old junction removed (target data untouched)' 'Yellow'
    }
    elseif ($state.Exists) {
        # plain folder: merge, verify, park as backup
        $srcInfo = Get-FileSet $source
        Say ('source content: ' + $srcInfo.Count + ' files, ' + [math]::Round($srcInfo.Bytes / 1MB, 1) + ' MB')
        $rc = Invoke-Robocopy $source $dest
        Say ('robocopy exit = ' + $rc)
        if ($rc -ge 8) { throw "robocopy failed (exit $rc). The source folder was left untouched." }
        $dstInfo = Get-FileSet $dest
        Say ('target content: ' + $dstInfo.Count + ' files, ' + [math]::Round($dstInfo.Bytes / 1MB, 1) + ' MB')
        if ($dstInfo.Count -lt $srcInfo.Count) { throw 'target has fewer files than the source. Aborted, source kept.' }
        $missing = 0
        foreach ($rel in $srcInfo.Set) { if (-not $dstInfo.Set.Contains($rel)) { $missing++ } }
        Say ('missing files = ' + $missing)
        if ($missing -gt 0) { throw "$missing files did not reach the target. Aborted, source kept." }
        if (Test-Path -LiteralPath $bakPath) { Remove-Item -LiteralPath $bakPath -Recurse -Force }
        Rename-Item -LiteralPath $source -NewName ($leaf + '.__bak')
        Say ('source folder parked as: ' + $bakPath) 'Yellow'
        $cleanup = $bakPath
    }
    else {
        Say 'no existing data to migrate, creating the junction directly.'
    }

    # ---- 4. create the junction ----
    New-Item -ItemType Junction -Path $source -Target $dest -ErrorAction Stop | Out-Null
    $check = Get-LinkState $source
    if (-not ($check.IsLink -and ($check.Target -ieq $dest))) { throw 'junction verification failed right after creation' }
    Say ('junction created: ' + $source + '  ->  ' + $dest) 'Green'

    # ---- 5. write-through probe ----
    $probeSrc = Join-Path $source '_junction_probe.tmp'
    $probeDst = Join-Path $dest '_junction_probe.tmp'
    Set-Content -LiteralPath $probeSrc -Value 'probe' -Encoding ASCII
    if (Test-Path -LiteralPath $probeDst) {
        Say 'write-through check: OK' 'Green'
        Remove-Item -LiteralPath $probeDst -Force
    } else {
        Say 'write-through check: NOT VERIFIED, please inspect manually' 'Yellow'
    }

    # ---- 6. drop the backup ----
    if ($cleanup) {
        Say 'removing the backup folder (may take a few seconds) ...'
        Remove-Item -LiteralPath $cleanup -Recurse -Force
        if (Test-Path -LiteralPath $cleanup) { Say ('warning: backup still present: ' + $cleanup) 'Yellow' }
        else { Say 'backup removed.' 'Green' }
    }

    Say 'result: done, all new data now lands on the target drive' 'Green'
    Show-Disk
    exit 0
}
catch {
    Say ('FAILED: ' + $_.Exception.Message) 'Red'
    Say ('full log: ' + $log) 'Yellow'
    exit 1
}
