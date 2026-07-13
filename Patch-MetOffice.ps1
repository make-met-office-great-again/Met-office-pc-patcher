[CmdletBinding()]
param(
    [string] $InputApkm = "",
    [string] $ApiKeyFile = "",
    [string] $OutputApkm = "",
    [string] $Abi = "arm64_v8a",
    [string] $Language = "en",
    [string] $Density = "xxhdpi",
    [string] $AndroidSdk = "",
    [switch] $Install,
    [string] $DeviceSerial = ""
)

$ErrorActionPreference = "Stop"

$ScriptDir = if ($PSScriptRoot) {
    $PSScriptRoot
} else {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}

if (-not $InputApkm) {
    $InputApkm = Join-Path $ScriptDir "input\original.apkm"
}
if (-not $ApiKeyFile) {
    $ApiKeyFile = Join-Path $ScriptDir "API.txt"
}
if (-not $OutputApkm) {
    $OutputApkm = Join-Path $ScriptDir "output\metoffice-patched.apkm"
}

function Write-Step([string] $Message) {
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Require-File([string] $Path, [string] $Label) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Label not found: $Path"
    }
}

function Require-Command([string] $Name) {
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) {
        throw "Required command '$Name' was not found on PATH. Install a JDK and make sure Java tools are on PATH."
    }
    return $command.Source
}

function Invoke-Native([string] $FilePath, [string[]] $Arguments, [string] $FailureMessage) {
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$FailureMessage (exit code $LASTEXITCODE)"
    }
}

function Get-AndroidSdkPath {
    if ($AndroidSdk -and (Test-Path -LiteralPath $AndroidSdk)) {
        return (Resolve-Path -LiteralPath $AndroidSdk).Path
    }

    foreach ($candidate in @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT, (Join-Path $env:LOCALAPPDATA "Android\Sdk"))) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw "Android SDK not found. Install Android Studio or command-line tools, or pass -AndroidSdk C:\Path\To\Sdk."
}

function Get-LatestDirectory([string] $Path) {
    $directories = Get-ChildItem -LiteralPath $Path -Directory -ErrorAction Stop
    if (-not $directories) {
        throw "No directories found in $Path"
    }

    return ($directories | Sort-Object Name -Descending | Select-Object -First 1).FullName
}

function Escape-JavaString([string] $Value) {
    return $Value.Replace("\", "\\").Replace('"', '\"')
}

$java = Require-Command "java"
$javac = Require-Command "javac"
$jar = Require-Command "jar"
$keytool = Require-Command "keytool"

$sdk = Get-AndroidSdkPath
$buildTools = Get-LatestDirectory (Join-Path $sdk "build-tools")
$platform = Get-LatestDirectory (Join-Path $sdk "platforms")

$androidJar = Join-Path $platform "android.jar"
$d8 = Join-Path $buildTools "d8.bat"
$zipalign = Join-Path $buildTools "zipalign.exe"
$apksigner = Join-Path $buildTools "apksigner.bat"
$adb = Join-Path $sdk "platform-tools\adb.exe"

Require-File $InputApkm "Input APKM"
Require-File $ApiKeyFile "API key file"
Require-File (Join-Path $ScriptDir "src\LocalProxyServer.java") "LocalProxyServer source"
Require-File (Join-Path $ScriptDir "patches\metoffice-revanced-patches-template.rvp") "Patch template"
Require-File (Join-Path $ScriptDir "tools\revanced-cli.jar") "ReVanced CLI"
Require-File (Join-Path $ScriptDir "tools\apktool.jar") "APKTool"
Require-File $androidJar "android.jar"
Require-File $d8 "d8"
Require-File $zipalign "zipalign"
Require-File $apksigner "apksigner"

if ($Install) {
    Require-File $adb "adb"
}

$apiKey = (Get-Content -LiteralPath $ApiKeyFile -Raw).Trim()
if (-not $apiKey -or $apiKey -eq "PUT-YOUR-MET-OFFICE-DATAHUB-API-KEY-HERE" -or $apiKey -eq "PASTE YOUR API KEY HERE") {
    throw "API.txt is empty or still contains the placeholder value."
}

$workRoot = Join-Path $ScriptDir "work"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$work = Join-Path $workRoot $stamp
$proxySourceDir = Join-Path $work "proxy-src"
$proxyClassesDir = Join-Path $work "proxy-classes"
$proxyDexDir = Join-Path $work "proxy-dex"
$rvpDir = Join-Path $work "rvp"
$unpackedDir = Join-Path $work "unpacked-apkm"
$patchedRvp = Join-Path $work "metoffice-revanced-patches-api.rvp"
$cliTemp = Join-Path $work "revanced-temp"
$manifestFixDir = Join-Path $work "manifest-fix"
$installSet = Join-Path $ScriptDir "output\install-set"
$signingDir = Join-Path $ScriptDir "signing"
$keystore = Join-Path $signingDir "metoffice-patcher.p12"
$keystorePassword = "password"
$keystoreAlias = "metoffice_patcher"

New-Item -ItemType Directory -Force $proxySourceDir, $proxyClassesDir, $proxyDexDir, $rvpDir, $unpackedDir, $cliTemp, $manifestFixDir, $installSet, $signingDir, (Split-Path -Parent $OutputApkm) | Out-Null
$workAndroidJar = Join-Path $work "android.jar"
Copy-Item -LiteralPath $androidJar -Destination $workAndroidJar -Force

Write-Step "Compiling LocalProxyServer with API.txt"
$proxyTemplate = Get-Content -LiteralPath (Join-Path $ScriptDir "src\LocalProxyServer.java") -Raw
$proxySource = [regex]::Replace(
    $proxyTemplate,
    'private\s+static\s+final\s+String\s+API_KEY\s*=\s*"[^"]*";',
    'private static final String API_KEY = "' + (Escape-JavaString $apiKey) + '";'
)
$proxySourcePath = Join-Path $proxySourceDir "LocalProxyServer.java"
[System.IO.File]::WriteAllText($proxySourcePath, $proxySource, [System.Text.UTF8Encoding]::new($false))

$stubSourceDir = Join-Path $proxySourceDir "uk\gov\metoffice\weather\android"
New-Item -ItemType Directory -Force $stubSourceDir | Out-Null
$stubSourcePath = Join-Path $stubSourceDir "MetOfficeApplication.java"
$stubSource = @"
package uk.gov.metoffice.weather.android;

public class MetOfficeApplication extends android.app.Application {
    public static MetOfficeApplication g() {
        return null;
    }
}
"@
[System.IO.File]::WriteAllText($stubSourcePath, $stubSource, [System.Text.UTF8Encoding]::new($false))

$javacArgs = @(
    "-source", "1.8",
    "-target", "1.8",
    "-classpath", $workAndroidJar,
    "-d", $proxyClassesDir,
    $proxySourcePath,
    $stubSourcePath
)
$javacLog = Join-Path $work "javac.log"
$javacOut = Join-Path $work "javac.out"
$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
    & $javac @javacArgs > $javacOut 2> $javacLog
    $javacExitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $previousErrorActionPreference
}
if ($javacExitCode -ne 0) {
    if (Test-Path -LiteralPath $javacOut) {
        Get-Content -LiteralPath $javacOut | Write-Error
    }
    if (Test-Path -LiteralPath $javacLog) {
        Get-Content -LiteralPath $javacLog | Write-Error
    }
    throw "Failed to compile LocalProxyServer.java (exit code $javacExitCode)"
}

$classFiles = @(Get-ChildItem -LiteralPath $proxyClassesDir -Recurse -Filter "*.class" |
    Where-Object { $_.FullName -notmatch "\\uk\\gov\\metoffice\\weather\\android\\MetOfficeApplication\.class$" } |
    ForEach-Object { $_.FullName })
if (-not $classFiles) {
    throw "No proxy .class files were produced."
}

Invoke-Native $d8 (@("--classpath", $workAndroidJar, "--classpath", $proxyClassesDir, "--output", $proxyDexDir) + $classFiles) "Failed to dex LocalProxyServer"
$proxyDex = Join-Path $proxyDexDir "classes.dex"
Require-File $proxyDex "Compiled proxy dex"

Write-Step "Rebuilding patch bundle with user API key"
Push-Location $rvpDir
try {
    Invoke-Native $jar @("xf", (Join-Path $ScriptDir "patches\metoffice-revanced-patches-template.rvp")) "Failed to unpack patch RVP"
} finally {
    Pop-Location
}
Copy-Item -LiteralPath $proxyDex -Destination (Join-Path $rvpDir "proxy_classes.dex") -Force
if (Test-Path -LiteralPath $patchedRvp) {
    Remove-Item -LiteralPath $patchedRvp -Force
}
Invoke-Native $jar @("cf", $patchedRvp, "-C", $rvpDir, ".") "Failed to create API-specific patch RVP"

Write-Step "Unpacking source APKM"
Push-Location $unpackedDir
try {
    Invoke-Native $jar @("xf", (Resolve-Path -LiteralPath $InputApkm).Path) "Failed to unpack APKM"
} finally {
    Pop-Location
}
$baseApk = Join-Path $unpackedDir "base.apk"
Require-File $baseApk "base.apk inside APKM"

Write-Step "Preparing local signing key"
if (-not (Test-Path -LiteralPath $keystore)) {
    Invoke-Native $keytool @(
        "-genkeypair",
        "-storetype", "PKCS12",
        "-keystore", $keystore,
        "-alias", $keystoreAlias,
        "-keyalg", "RSA",
        "-keysize", "2048",
        "-validity", "10000",
        "-storepass", $keystorePassword,
        "-keypass", $keystorePassword,
        "-dname", "CN=MetOffice PC Patcher, OU=Weather, O=Local, L=Local, ST=Local, C=GB"
    ) "Failed to generate signing key"
}

Write-Step "Patching base.apk"
$cliOutput = Join-Path $work "revanced-output.apk"

Invoke-Native $java @(
    "-jar", (Join-Path $ScriptDir "tools\revanced-cli.jar"),
    "patch",
    "-p", $patchedRvp,
    "-b",
    "-f",
    "-o", $cliOutput,
    "-t", $cliTemp,
    $baseApk
) "ReVanced patching failed"

Require-File $cliOutput "ReVanced patched base output"

Write-Step "Allowing localhost cleartext traffic"
$manifestDecodedDir = Join-Path $manifestFixDir "decoded"
$manifestFixedApk = Join-Path $manifestFixDir "base-cleartext.apk"
Invoke-Native $java @(
    "-jar", (Join-Path $ScriptDir "tools\apktool.jar"),
    "d",
    "-f",
    $cliOutput,
    "-o",
    $manifestDecodedDir
) "Failed to decode patched base for manifest update"

$manifestPath = Join-Path $manifestDecodedDir "AndroidManifest.xml"
Require-File $manifestPath "Decoded AndroidManifest.xml"
$manifest = Get-Content -LiteralPath $manifestPath -Raw
if ($manifest -notmatch 'android:usesCleartextTraffic=') {
    $manifest = $manifest -replace '<application\s+', '<application android:usesCleartextTraffic="true" '
    [System.IO.File]::WriteAllText($manifestPath, $manifest, [System.Text.UTF8Encoding]::new($false))
}

$networkSecurityConfig = Join-Path $manifestDecodedDir "res\xml\network_security_config_prod.xml"
if (Test-Path -LiteralPath $networkSecurityConfig) {
    $networkSecurityXml = Get-Content -LiteralPath $networkSecurityConfig -Raw
    $networkSecurityXml = $networkSecurityXml -replace 'cleartextTrafficPermitted="false"', 'cleartextTrafficPermitted="true"'
    [System.IO.File]::WriteAllText($networkSecurityConfig, $networkSecurityXml, [System.Text.UTF8Encoding]::new($false))
}

Invoke-Native $java @(
    "-jar", (Join-Path $ScriptDir "tools\apktool.jar"),
    "b",
    $manifestDecodedDir,
    "-o",
    $manifestFixedApk
) "Failed to rebuild patched base after manifest update"

$patchedBaseInput = $manifestFixedApk

Write-Step "Signing patched base and splits"
Remove-Item -Recurse -Force $installSet -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $installSet | Out-Null

$alignedBase = Join-Path $work "base-aligned.apk"
$signedBase = Join-Path $installSet "base.apk"
Invoke-Native $zipalign @("-f", "4", $patchedBaseInput, $alignedBase) "Failed to zipalign patched base"
Invoke-Native $apksigner @(
    "sign",
    "--ks", $keystore,
    "--ks-pass", "pass:$keystorePassword",
    "--ks-key-alias", $keystoreAlias,
    "--key-pass", "pass:$keystorePassword",
    "--out", $signedBase,
    $alignedBase
) "Failed to sign patched base"

$splitApks = @(Get-ChildItem -LiteralPath $unpackedDir -File -Filter "split_*.apk")
foreach ($split in $splitApks) {
    $alignedSplit = Join-Path $work ($split.BaseName + "-aligned.apk")
    $signedSplit = Join-Path $installSet $split.Name

    if ($split.Name -match "arm64|armeabi|x86") {
        Invoke-Native $zipalign @("-f", "-p", "4096", $split.FullName, $alignedSplit) "Failed to zipalign native split $($split.Name)"
    } else {
        Invoke-Native $zipalign @("-f", "4", $split.FullName, $alignedSplit) "Failed to zipalign split $($split.Name)"
    }

    Invoke-Native $apksigner @(
        "sign",
        "--ks", $keystore,
        "--ks-pass", "pass:$keystorePassword",
        "--ks-key-alias", $keystoreAlias,
        "--key-pass", "pass:$keystorePassword",
        "--out", $signedSplit,
        $alignedSplit
    ) "Failed to sign split $($split.Name)"
}

Write-Step "Building patched APKM"
$packageDir = Join-Path $work "package"
New-Item -ItemType Directory -Force $packageDir | Out-Null

Get-ChildItem -LiteralPath $unpackedDir -File | Where-Object { $_.Extension -ne ".apk" } | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $packageDir $_.Name) -Force
}
Copy-Item -LiteralPath (Join-Path $installSet "base.apk") -Destination (Join-Path $packageDir "base.apk") -Force
Get-ChildItem -LiteralPath $installSet -File -Filter "split_*.apk" | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $packageDir $_.Name) -Force
}

if (Test-Path -LiteralPath $OutputApkm) {
    Remove-Item -LiteralPath $OutputApkm -Force
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory(
    $packageDir,
    $OutputApkm,
    [System.IO.Compression.CompressionLevel]::Optimal,
    $false
)

Write-Step "Verifying signed install set"
foreach ($apk in Get-ChildItem -LiteralPath $installSet -File -Filter "*.apk") {
    Invoke-Native $apksigner @("verify", $apk.FullName) "Signature verification failed for $($apk.Name)"
}

if ($Install) {
    Write-Step "Installing selected split set via ADB"
    $selectedSplits = @(
        (Join-Path $installSet "base.apk"),
        (Join-Path $installSet "split_config.$Abi.apk"),
        (Join-Path $installSet "split_config.$Language.apk"),
        (Join-Path $installSet "split_config.$Density.apk")
    )

    foreach ($selected in $selectedSplits) {
        Require-File $selected "Selected install APK"
    }

    $adbArgs = @()
    if ($DeviceSerial) {
        $adbArgs += @("-s", $DeviceSerial)
    }
    $adbArgs += @("install-multiple", "-r")
    $adbArgs += $selectedSplits

    Invoke-Native $adb $adbArgs "ADB install-multiple failed"
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "Patched APKM: $OutputApkm"
Write-Host "ADB install set: $installSet"
Write-Host "Work folder: $work"
