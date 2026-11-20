<#
.SYNOPSIS
  Generates a local internal staging keystore and android/key.properties for
  FujiStudio Mobile release APK signing. Never commit generated keystores or
  key.properties to version control.
#>
[CmdletBinding()]
param(
    [string]$KeystoreRelPath = "app/staging-release.jks",
    [string]$KeyAlias = "fujistudio_staging",
    [string]$StorePassword = "",
    [string]$KeyPassword = "",
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$androidDir = Join-Path $repoRoot "android"
$keystorePath = Join-Path $androidDir $KeystoreRelPath
$keyPropertiesPath = Join-Path $androidDir "key.properties"

function New-SecureRandomPassword {
    param([int]$Length = 28)
    $alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#%^&*_-+"
    $bytes = New-Object byte[] $Length
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    } finally {
        $rng.Dispose()
    }
    $chars = New-Object char[] $Length
    for ($i = 0; $i -lt $Length; $i++) {
        $chars[$i] = $alphabet[$bytes[$i] % $alphabet.Length]
    }
    return (-join $chars)
}

function Resolve-Keytool {
    $cmd = Get-Command keytool -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($env:JAVA_HOME)) {
        $candidates += (Join-Path $env:JAVA_HOME "bin\keytool.exe")
    }
    $candidates += "C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe"
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $candidates += (Join-Path $env:USERPROFILE ".jdks\jbr-21.0.11\bin\keytool.exe")
    }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) {
            return $candidate
        }
    }
    throw "Could not locate keytool.exe. Install JDK or Android Studio JBR."
}

$resolvedStorePassword = $StorePassword
if ([string]::IsNullOrWhiteSpace($resolvedStorePassword)) {
    $resolvedStorePassword = $env:FUJISTUDIO_KEYSTORE_PASSWORD
}
if ([string]::IsNullOrWhiteSpace($resolvedStorePassword)) {
    $resolvedStorePassword = New-SecureRandomPassword
    Write-Host "Generated cryptographically random staging keystore password via RandomNumberGenerator."
}

$resolvedKeyPassword = $KeyPassword
if ([string]::IsNullOrWhiteSpace($resolvedKeyPassword)) {
    $resolvedKeyPassword = $resolvedStorePassword
}

$keytool = Resolve-Keytool
Write-Host "Using keytool: $keytool"

if ((Test-Path $keystorePath) -and -not $Force) {
    Write-Host "Staging keystore already exists at $keystorePath (pass -Force to regenerate)."
} else {
    if (Test-Path $keystorePath) {
        Remove-Item -Force $keystorePath
    }
    $parentDir = Split-Path -Parent $keystorePath
    if (-not (Test-Path $parentDir)) {
        New-Item -ItemType Directory -Force -Path $parentDir | Out-Null
    }

    & $keytool -genkeypair `
        -v `
        -keystore $keystorePath `
        -storetype PKCS12 `
        -alias $KeyAlias `
        -keyalg RSA `
        -keysize 2048 `
        -validity 3650 `
        -storepass $resolvedStorePassword `
        -keypass $resolvedKeyPassword `
        -dname "CN=FujiStudio Mobile Staging, OU=Engineering, O=FujiStudio, L=Hanoi, S=Hanoi, C=VN"

    if ($LASTEXITCODE -ne 0) {
        throw "keytool failed with exit code $LASTEXITCODE"
    }
    Write-Host "Generated staging keystore: $keystorePath"
}

$propertiesContent = @(
    "storePassword=$resolvedStorePassword",
    "keyPassword=$resolvedKeyPassword",
    "keyAlias=$KeyAlias",
    "storeFile=$KeystoreRelPath"
) -join "`n"

Set-Content -Path $keyPropertiesPath -Value ($propertiesContent + "`n") -Encoding ASCII -NoNewline
Write-Host "Wrote signing configuration: $keyPropertiesPath (gitignored)"
