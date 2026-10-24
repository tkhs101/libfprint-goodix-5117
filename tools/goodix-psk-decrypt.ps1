<#
.SYNOPSIS
    Decrypt the per-device Goodix 27c6:5117 TLS PSK from Goodix_Cache.bin.

.DESCRIPTION
    The Goodix Windows driver stores the 32-byte TLS-PSK sealed with DPAPI in
    C:\ProgramData\Goodix\Goodix_Cache.bin.  The file is 332 bytes:

        [ 324-byte DPAPI blob ][ 8-byte seed ]

    The DPAPI entropy is derived from the seed and three 16-byte constants that
    are embedded in gfspi.dll.  The constants are searched for in the installed
    driver instead of relying on a hard-coded file offset, because the offset
    changes between driver versions.

    By default the key is only shown masked.  Use -ShowKey to print all 64 hex
    digits, and/or -OutFile to write a key file for /etc/goodix5117/psk.

.PARAMETER CachePath
    Path to Goodix_Cache.bin.  If omitted, the usual ProgramData path and the
    LocalService profile path are searched.

.PARAMETER DriverPath
    Path to gfspi.dll.  If omitted, the newest gfspi.inf_* directory under the
    Windows DriverStore is used.  If the DLL cannot be found, the documented
    constants are used as a fallback.

.PARAMETER OutFile
    Write the 64 hex digits plus a newline to this file.  On NTFS the file ACL
    is reduced to the current user.

.PARAMETER Scope
    DPAPI scope to try.  Auto (default) tries CurrentUser, then LocalMachine.

.PARAMETER ShowKey
    Print the full key to the console.  Off by default so logs do not leak it.

.EXAMPLE
    .\goodix-psk-decrypt.ps1 -OutFile C:\Users\me\goodix5117\psk

.EXAMPLE
    .\goodix-psk-decrypt.ps1 -CachePath D:\backup\Goodix_Cache.bin -ShowKey
#>
[CmdletBinding()]
param(
    [string]$CachePath = '',
    [string]$DriverPath = '',
    [string]$OutFile = '',
    [ValidateSet('Auto', 'CurrentUser', 'LocalMachine')]
    [string]$Scope = 'Auto',
    [switch]$ShowKey
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security

# Documented constants from gfspi.dll.  They are public protocol constants, not
# the key.  The script searches for the 48-byte sequence first so a new driver
# build with a different layout still works.
$KnownConst1 = [byte[]](0x9d,0x79,0x92,0xb3,0x84,0x02,0xb6,0x6c,
                        0x81,0xd1,0xf5,0x55,0x21,0x89,0x42,0xa9)
$KnownConst2 = [byte[]](0x18,0x48,0xd7,0x15,0x50,0xd2,0x70,0xd2,
                        0x19,0xc8,0x06,0x32,0xab,0x4f,0x8b,0xb3)
$KnownConst3 = [byte[]](0xe4,0x7c,0x89,0x38,0xdb,0x52,0x50,0xf0,
                        0x20,0x56,0x17,0xee,0x17,0xda,0x4e,0xb4)
$KnownRootHex = '04e0b0f3f5598417dde298e467c795f7'

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

function Find-GoodixCache {
    param([string]$Explicit)

    if ($Explicit) {
        if (-not (Test-Path -LiteralPath $Explicit -PathType Leaf)) {
            throw "Goodix_Cache.bin not found: $Explicit"
        }
        return (Resolve-Path -LiteralPath $Explicit).Path
    }

    $paths = @(
        'C:\ProgramData\Goodix\Goodix_Cache.bin',
        'C:\Windows\ServiceProfiles\LocalService\AppData\Local\Goodix\FingerPrint\Goodix_Cache.bin',
        'C:\Windows\ServiceProfiles\LocalService\AppData\Local\Goodix\Goodix_Cache.bin'
    )
    foreach ($p in $paths) {
        if (Test-Path -LiteralPath $p -PathType Leaf) {
            return (Resolve-Path -LiteralPath $p).Path
        }
    }

    $root = 'C:\ProgramData\Goodix'
    if (Test-Path -LiteralPath $root) {
        $found = Get-ChildItem -LiteralPath $root -Filter 'Goodix_Cache.bin' -Recurse -File -ErrorAction SilentlyContinue |
                 Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    throw 'Goodix_Cache.bin not found; pass -CachePath explicitly'
}

function Find-BytePattern {
    param([byte[]]$Haystack, [byte[]]$Needle)

    if ($Needle.Length -eq 0 -or $Haystack.Length -lt $Needle.Length) { return -1 }
    $enc = [System.Text.Encoding]::GetEncoding(28591)  # ISO-8859-1: one char per byte
    $h = $enc.GetString($Haystack)
    $n = $enc.GetString($Needle)
    return $h.IndexOf($n, [System.StringComparison]::Ordinal)
}

function Get-RootKey {
    param([byte[]]$C1, [byte[]]$C2, [byte[]]$C3)

    $root = New-Object byte[] 16
    for ($i = 0; $i -lt 8; $i++) {
        $root[$i] = [byte](([int]$C1[$i]) -bxor ([int]$C2[$i]) -bxor ([int]$C1[$i + 8]))
    }
    for ($i = 8; $i -lt 16; $i++) {
        $root[$i] = [byte](([int]$C2[$i]) -bxor ([int]$C3[$i]) -bxor ([int]$C3[$i - 8]))
    }
    return $root
}

function Get-HexString {
    param([byte[]]$Bytes)
    return (($Bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

$driver = Find-GoodixDriver -Explicit $DriverPath
if ($driver) {
    Write-Verbose "driver: $driver"
}

$c1 = $KnownConst1
$c2 = $KnownConst2
$c3 = $KnownConst3
$constSource = 'built-in documented constants'

if ($driver) {
    $dll = [System.IO.File]::ReadAllBytes($driver)
    $sequence = New-Object byte[] 48
    [Array]::Copy($KnownConst1, 0, $sequence, 0, 16)
    [Array]::Copy($KnownConst2, 0, $sequence, 16, 16)
    [Array]::Copy($KnownConst3, 0, $sequence, 32, 16)

    $idx = Find-BytePattern -Haystack $dll -Needle $sequence
    if ($idx -ge 0) {
        $c1 = New-Object byte[] 16; [Array]::Copy($dll, $idx, $c1, 0, 16)
        $c2 = New-Object byte[] 16; [Array]::Copy($dll, $idx + 16, $c2, 0, 16)
        $c3 = New-Object byte[] 16; [Array]::Copy($dll, $idx + 32, $c3, 0, 16)
        $constSource = ('gfspi.dll at 0x{0:x}' -f $idx)
        Write-Verbose "constants found at 0x$($idx.ToString('x'))"
    } else {
        Write-Warning 'constant sequence not found in gfspi.dll; using the documented constants'
    }
}

$root = Get-RootKey -C1 $c1 -C2 $c2 -C3 $c3
$rootHex = Get-HexString $root
if ($rootHex -ne $KnownRootHex) {
    throw "derived root key $rootHex does not match the documented $KnownRootHex"
}
Write-Verbose "root key: $rootHex"
Write-Verbose "constant source: $constSource"

$cache = Find-GoodixCache -Explicit $CachePath
$data = [System.IO.File]::ReadAllBytes($cache)
if ($data.Length -lt 332) {
    throw "cache is too small ($($data.Length) bytes); expected 332 (324-byte DPAPI blob + 8-byte seed)"
}

$blobLen = $data.Length - 8
$blob = New-Object byte[] $blobLen
[Array]::Copy($data, 0, $blob, 0, $blobLen)
$seed = New-Object byte[] 8
[Array]::Copy($data, $blobLen, $seed, 0, 8)

# Standard DPAPI blob header: version 1 + provider GUID
# {df9d8cd0-1501-11d1-8c7a-00c04fc297eb}
$dpapiGuid = [byte[]](0xd0,0x8c,0x9d,0xdf,0x01,0x15,0xd1,0x11,
                      0x8c,0x7a,0x00,0xc0,0x4f,0xc2,0x97,0xeb)
if ($data[0] -ne 1 -or $data[1] -ne 0 -or $data[2] -ne 0 -or $data[3] -ne 0) {
    throw 'not a DPAPI blob (unexpected version header)'
}
for ($i = 0; $i -lt 16; $i++) {
    if ($data[4 + $i] -ne $dpapiGuid[$i]) {
        throw 'not a DPAPI blob (unexpected provider GUID)'
    }
}

Write-Verbose ('seed: ' + (Get-HexString $seed))

$sha = [System.Security.Cryptography.SHA256]::Create()
$seedHash = $sha.ComputeHash($seed)
$material = New-Object byte[] 32
[Array]::Copy($seedHash, 0, $material, 0, 16)
[Array]::Copy($root, 0, $material, 16, 16)
$entropyHash = $sha.ComputeHash($material)
$entropy = New-Object byte[] 48
[Array]::Copy($seedHash, 16, $entropy, 0, 16)
[Array]::Copy($entropyHash, 0, $entropy, 16, 32)

$scopes = if ($Scope -eq 'Auto') { @('CurrentUser', 'LocalMachine') } else { @($Scope) }
$plain = $null
$usedScope = $null
$errors = @()
foreach ($s in $scopes) {
    try {
        $scopeValue = [System.Enum]::Parse([System.Security.Cryptography.DataProtectionScope], $s)
        $plain = [System.Security.Cryptography.ProtectedData]::Unprotect($blob, $entropy, $scopeValue)
        $usedScope = $s
        break
    } catch {
        $msg = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
        $errors += "${s}: $msg"
    }
}

if (-not $plain) {
    throw ("DPAPI decryption failed. Try running as the user who enrolled the fingerprint, " +
           "or as SYSTEM if the driver stored the cache under LocalSystem. Details: " + ($errors -join '; '))
}
if ($plain.Length -ne 32) {
    throw "decrypted $($plain.Length) bytes; expected a 32-byte PSK"
}

$hex = Get-HexString $plain
$keySha = (Get-HexString $sha.ComputeHash($plain)).ToUpperInvariant()

Write-Host "Cache : $cache"
if ($driver) { Write-Host "Driver: $driver" }
Write-Host "Scope : $usedScope"
Write-Host "PSK   : $($plain.Length) bytes, SHA256 $keySha"
Write-Host ("PSK   : " + $hex.Substring(0, 8) + '...' + $hex.Substring(56, 8) + ' (masked)')

if ($ShowKey) {
    Write-Host "PSK   : $hex"
}

if ($OutFile) {
    $dir = Split-Path -Parent $OutFile
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    [System.IO.File]::WriteAllText($OutFile, $hex + "`n", (New-Object System.Text.UTF8Encoding($false)))
    try {
        $acl = Get-Acl -LiteralPath $OutFile
        $acl.SetAccessRuleProtection($true, $false)
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $me, 'FullControl', 'Allow')
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $OutFile -AclObject $acl
    } catch {
        Write-Warning "could not restrict the ACL of ${OutFile}: $($_.Exception.Message)"
    }
    Write-Host "Wrote : $OutFile"
}
