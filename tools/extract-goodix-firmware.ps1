<#
.SYNOPSIS
    Extract and verify Goodix 27c6:5117 firmware images from gfspi.dll.

.DESCRIPTION
    The Goodix Windows driver embeds a set of complete firmware images in
    gfspi.dll.  Each image starts with the four bytes 00 00 02 20 followed by
    an ARM vector table (a little-endian address in the 0x08xxxxxx range).
    For the 12118 family the image length is 102336 bytes.

    This script scans the installed driver, validates each candidate with
    CRC-32/MPEG-2 and SHA-256, groups identical copies, and writes one file
    per unique image.  It does not download anything and does not touch the
    sensor.

    Firmware is a vendor binary: do not redistribute it.  The normal Linux
    path uses the per-device PSK, not reflashing.

.PARAMETER DriverPath
    Path to gfspi.dll.  If omitted, the newest gfspi.inf_* directory under the
    Windows DriverStore is used.

.PARAMETER OutDir
    Directory for the extracted .bin files.  Defaults to ..\firmware next to
    this script (ignored by the repository's .gitignore).

.PARAMETER PidFilter
    Extract only 5110, only 5117, or all unique images (default).

.PARAMETER Force
    Overwrite existing output files.

.EXAMPLE
    .\extract-goodix-firmware.ps1

.EXAMPLE
    .\extract-goodix-firmware.ps1 -Pid 5117 -OutDir C:\Users\me\goodix5117\firmware
#>
[CmdletBinding()]
param(
    [string]$DriverPath = '',
    [string]$OutDir = '',
    [Alias('Pid')]
    [ValidateSet('all', '5110', '5117')]
    [string]$PidFilter = 'all',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$ImageLength = 102336
# PowerShell 5.1 parses 0x886AE278 / 0xD90EC273 as negative Int32, so build
# the unsigned values from their hex strings instead of casting the literals.
$KnownCrc5110 = [Convert]::ToUInt32('886AE278', 16)
$KnownCrc5117 = [Convert]::ToUInt32('D90EC273', 16)

function Find-GoodixDriver {
    param([string]$Explicit)

    if ($Explicit) {
        if (-not (Test-Path -LiteralPath $Explicit -PathType Leaf)) {
            throw "gfspi.dll not found: $Explicit"
        }
        return (Resolve-Path -LiteralPath $Explicit).Path
    }

    $repo = 'C:\Windows\System32\DriverStore\FileRepository'
    $candidates = @()
    if (Test-Path -LiteralPath $repo) {
        $dirs = Get-ChildItem -LiteralPath $repo -Directory -Filter 'gfspi.inf_*' -ErrorAction SilentlyContinue
        foreach ($d in $dirs) {
            $p = Join-Path $d.FullName 'gfspi.dll'
            if (Test-Path -LiteralPath $p -PathType Leaf) {
                $candidates += Get-Item -LiteralPath $p
            }
        }
    }
    if ($candidates.Count -gt 0) {
        return ($candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
    }
    return $null
}

if (-not ([System.Management.Automation.PSTypeName]'GoodixCrc32Mpeg2').Type) {
    Add-Type -TypeDefinition @"
public static class GoodixCrc32Mpeg2 {
    public static uint Compute(byte[] data, int offset, int count) {
        uint crc = 0xFFFFFFFFu;
        for (int i = 0; i < count; i++) {
            crc ^= ((uint)data[offset + i]) << 24;
            for (int b = 0; b < 8; b++) {
                if ((crc & 0x80000000u) != 0)
                    crc = (crc << 1) ^ 0x04C11DB7u;
                else
                    crc = crc << 1;
            }
        }
        return crc;
    }
}
"@
}

function Get-HexString {
    param([byte[]]$Bytes)
    return (($Bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

$driver = Find-GoodixDriver -Explicit $DriverPath
if (-not $driver) {
    throw 'gfspi.dll not found; pass -DriverPath explicitly'
}
Write-Verbose "driver: $driver"

if (-not $OutDir) {
    $OutDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'firmware'
}
$OutDir = [System.IO.Path]::GetFullPath($OutDir)
if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
}

$bytes = [System.IO.File]::ReadAllBytes($driver)
$latin = [System.Text.Encoding]::GetEncoding(28591).GetString($bytes)
$magic = ([char]0) + ([char]0) + ([char]2) + ([char]0x20)
$sha = [System.Security.Cryptography.SHA256]::Create()

$groups = @{}
$pos = 0
$candidates = 0
while (($pos = $latin.IndexOf($magic, $pos, [System.StringComparison]::Ordinal)) -ge 0) {
    $imageStart = $pos
    $pos += 4

    if ($imageStart + $ImageLength -gt $bytes.Length) { continue }
    $vector = [BitConverter]::ToUInt32($bytes, $imageStart + 4)
    if ($vector -lt 0x08000000 -or $vector -gt 0x08FFFFFF) { continue }

    $candidates++
    # PowerShell may surface a uint > int.MaxValue as a negative int; normalise
    # it before storing it in a [uint32] property.
    $crcRaw = [GoodixCrc32Mpeg2]::Compute($bytes, $imageStart, $ImageLength)
    $crc = [uint32]([int64]$crcRaw -band 0xFFFFFFFFL)
    $slice = New-Object byte[] $ImageLength
    [Array]::Copy($bytes, $imageStart, $slice, 0, $ImageLength)
    $shaHex = Get-HexString $sha.ComputeHash($slice)
    $key = ('{0:x8}:{1}' -f $crc, $shaHex)

    if (-not $groups.ContainsKey($key)) {
        $groups[$key] = [pscustomobject]@{
            Crc     = [uint32]$crc
            Sha256  = $shaHex
            Offsets = @()
            First   = $imageStart
        }
    }
    $groups[$key].Offsets += $imageStart
}

Write-Host "Driver        : $driver"
Write-Host "Candidates    : $candidates"
Write-Host "Unique images : $($groups.Count)"

if ($groups.Count -eq 0) {
    throw 'no firmware images found; is this the right gfspi.dll?'
}

$rows = @()
foreach ($group in $groups.Values) {
    $first = $group.First

    # The image is immediately preceded by its ASCII name.
    $lookback = 80
    $start = [Math]::Max(0, $first - $lookback)
    $prefix = $latin.Substring($start, $first - $start)
    $nameMatches = [regex]::Matches($prefix, 'GF_ST[0-9A-Za-z_.-]+')
    if ($nameMatches.Count -gt 0) {
        $baseName = $nameMatches[$nameMatches.Count - 1].Value
    } else {
        $baseName = 'GF_ST411SEC_APP_unknown'
    }

    $pidByte = $bytes[$first + 0x18f42]
    $pidName = switch ($pidByte) {
        0x10 { '5110' }
        0x17 { '5117' }
        default { 'pid{0:x2}' -f $pidByte }
    }

    if ($PidFilter -ne 'all' -and $pidName -ne $PidFilter) { continue }

    if ($baseName -match '_[0-9A-Fa-f]{4}$') {
        $fileName = "$baseName.bin"
    } else {
        $fileName = "${baseName}_${pidName}.bin"
    }
    $path = Join-Path $OutDir $fileName

    $saved = $false
    if ((Test-Path -LiteralPath $path) -and -not $Force) {
        Write-Host "skip          : $path (exists; use -Force to overwrite)"
    } else {
        $image = New-Object byte[] $ImageLength
        [Array]::Copy($bytes, $first, $image, 0, $ImageLength)
        [System.IO.File]::WriteAllBytes($path, $image)
        $saved = $true
    }

    $kind = if ($group.Crc -eq $KnownCrc5117) { '12118/5117' }
            elseif ($group.Crc -eq $KnownCrc5110) { '12118/5110' }
            else { 'unknown' }

    $rows += [pscustomobject]@{
        File    = $fileName
        Kind    = $kind
        Pid     = $pidName
        Copies  = $group.Offsets.Count
        Offset  = ('0x{0:x}' -f $first)
        Length  = $ImageLength
        Crc     = ('0x{0:X8}' -f $group.Crc)
        Sha256  = $group.Sha256
        Saved   = $saved
    }
}

$rows | Format-Table -AutoSize
Write-Host ''
Write-Host "Output directory: $OutDir"
