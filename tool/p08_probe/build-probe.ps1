# Build a separate-UID, test-only Android P0.8 probe. Never ships in the VPN APK.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$AndroidSdkRoot,
    [Parameter(Mandatory=$true)][string]$JdkRoot,
    [string]$OutputDir = (Join-Path ([IO.Path]::GetTempPath()) 'revoltvpn-p08-probe')
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$tools = Join-Path $AndroidSdkRoot 'build-tools\35.0.0'
$platform = Join-Path $AndroidSdkRoot 'platforms\android-35\android.jar'
$javac = Join-Path $JdkRoot 'bin\javac.exe'
$jar = Join-Path $JdkRoot 'bin\jar.exe'
$keytool = Join-Path $JdkRoot 'bin\keytool.exe'
$d8 = Join-Path $tools 'd8.bat'
$aapt = Join-Path $tools 'aapt2.exe'
$align = Join-Path $tools 'zipalign.exe'
$signer = Join-Path $tools 'apksigner.bat'
foreach ($required in @($platform,$javac,$jar,$keytool,$d8,$aapt,$align,$signer)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw 'P0.8 probe build prerequisite missing. Check AndroidSdkRoot/JdkRoot.'
    }
}
$classes = Join-Path $OutputDir 'classes'
$dex = Join-Path $OutputDir 'dex'
New-Item -ItemType Directory -Force $classes, $dex | Out-Null
$source = Join-Path $PSScriptRoot 'ProbeActivity.java'
$wire = Join-Path $PSScriptRoot 'DnsEvidence.java'
$manifest = Join-Path $PSScriptRoot 'AndroidManifest.xml'
$unsigned = Join-Path $OutputDir 'base-unsigned.apk'
$aligned = Join-Path $OutputDir 'base-aligned.apk'
$apk = Join-Path $OutputDir 'probe.apk'
$key = Join-Path $OutputDir 'probe.jks'

& $javac -source 8 -target 8 -classpath $platform -d $classes $source $wire
if ($LASTEXITCODE -ne 0) { throw 'JAVAC_FAILED' }
& $d8 --lib $platform --min-api 28 --output $dex (Join-Path $classes 'dev\naveax\p08probe\ProbeActivity.class') (Join-Path $classes 'dev\naveax\p08probe\DnsEvidence.class')
if ($LASTEXITCODE -ne 0) { throw 'D8_FAILED' }
& $aapt link -o $unsigned --manifest $manifest -I $platform
if ($LASTEXITCODE -ne 0) { throw 'AAPT2_FAILED' }
Push-Location $dex
try {
    & $jar uf $unsigned 'classes.dex'
    if ($LASTEXITCODE -ne 0) { throw 'JAR_FAILED' }
} finally { Pop-Location }
& $align -f 4 $unsigned $aligned
if ($LASTEXITCODE -ne 0) { throw 'ZIPALIGN_FAILED' }
if (-not (Test-Path -LiteralPath $key)) {
    # A throwaway DEBUG identity, never a production signing credential.
    & $keytool -genkeypair -alias p08 -keyalg RSA -keysize 2048 -validity 365 -keystore $key -storepass android -keypass android -dname 'CN=ReVoltVPN P08 Isolation Fixture' -noprompt
    if ($LASTEXITCODE -ne 0) { throw 'DEBUG_KEY_FAILED' }
}
& $signer sign --ks $key --ks-pass pass:android --key-pass pass:android --out $apk $aligned
if ($LASTEXITCODE -ne 0) { throw 'SIGN_FAILED' }
& $signer verify $apk
if ($LASTEXITCODE -ne 0) { throw 'SIGN_VERIFY_FAILED' }

[ordered]@{
    artifact = $apk
    sha256 = (Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToLowerInvariant()
    package = 'dev.naveax.p08probe'
    status = 'TEST_FIXTURE_ONLY_NOT_VPN_APK'
} | ConvertTo-Json
