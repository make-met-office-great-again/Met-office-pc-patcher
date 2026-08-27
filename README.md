# Met Office PC Patcher

This folder builds and installs a patched Met Office Android app using the stock APKM (2.47.2) included in `input/original.apkm`.

The patch:

- bypasses the forced update/takeover screen;
- disables ads;
- adds the on-device local proxy on `http://127.0.0.1:18080`, getting data using your own API key.

Do not share your own built `output/` files if they contain your private API key. Other users should run the patcher with their own key.

## Before you run it

Install these on the PC:

- Java JDK, not just JRE.
- Android Studio or Android SDK command-line tools.
- PowerShell 5+.

The script needs the Android SDK tools `d8`, `zipalign`, `apksigner`, and `adb`. It auto-detects the SDK from `ANDROID_HOME`, `ANDROID_SDK_ROOT`, or `%LOCALAPPDATA%\Android\Sdk`.

## Get a Met Office API key

1. Go to the [Met Office Weather DataHub](https://datahub.metoffice.gov.uk/).
2. Register or log in.
3. Choose the Site-Specific forecast product. The patcher uses the Global Spot APIs: hourly, three-hourly, and daily.
4. Subscribe to the free plan.
5. Copy the API key for the created DataHub application.
6. Create or edit `API.txt` in this folder and paste the key into it.

Keep `API.txt` private.

## Build and install

Open PowerShell, change to this directory, then run:

```powershell
cd "C:\Path\To\PC Patcher"
powershell.exe -ExecutionPolicy Bypass -File .\Patch-MetOffice.ps1 -Install
```

That builds the patched APKM, signs it locally, and installs it on the attached Android phone over ADB.

The built files are written to:

```text
output/
```

## Build and install on macOS (no Windows or VM needed)

The `Patch-MetOffice.ps1` glue is Windows-only, but the tools it drives (`d8`, `zipalign`, `apksigner`, `javac`, `adb`) all have native macOS builds. `patch-metoffice.sh` is a bash port that does exactly the same thing.

### Prerequisites (Homebrew)

```bash
brew install openjdk                      # JDK: javac, jar, keytool
brew install --cask android-commandlinetools
brew install --cask android-platform-tools   # adb (only needed for -Install)

# Fetch the SDK bits the patcher needs:
yes | sdkmanager "build-tools;34.0.0" "platforms;android-34"
```

The script auto-detects the toolchain: Homebrew's `openjdk` (or any JDK via `/usr/libexec/java_home`), and the SDK from `ANDROID_SDK_ROOT` / `ANDROID_HOME`, the Homebrew command-line-tools location, or `~/Library/Android/sdk`. It works on both Apple Silicon (`/opt/homebrew`) and Intel (`/usr/local`).

### Run

Put your key in `API.txt` (see above), then:

```bash
chmod +x patch-metoffice.sh
./patch-metoffice.sh                 # build only -> output/metoffice-patched.apkm
DO_INSTALL=1 ./patch-metoffice.sh    # build and adb install-multiple to the attached phone
```

Options are environment variables (defaults shown):

```bash
ABI=arm64_v8a LANGUAGE=en DENSITY=xxhdpi \
DEVICE_SERIAL=YOUR_SERIAL \
INPUT_APKM=input/original.apkm OUTPUT_APKM=output/metoffice-patched.apkm \
DO_INSTALL=1 ./patch-metoffice.sh
```

### Notes

- A recent Homebrew `openjdk` (e.g. 26) prints harmless `WARNING: ... restricted method ... loadLibrary` lines from `apksigner`, and `javac` warns that `-source 8` is obsolete. Both are noise; the build and signatures are fine (`apksigner verify` passes).
- To get a single tap-to-install APK instead of the split `output/metoffice-patched.apkm` (handy for sideloading to your own phone without a split-APK installer), merge the output with [APKEditor](https://github.com/REAndroid/APKEditor), then re-sign:
  ```bash
  java -jar APKEditor.jar m -i output/metoffice-patched.apkm -o merged.apk
  "$SDK/build-tools/34.0.0/zipalign" -f 4 merged.apk merged-aligned.apk
  "$SDK/build-tools/34.0.0/apksigner" sign \
    --ks signing/metoffice-patcher.p12 --ks-pass pass:password \
    --ks-key-alias metoffice_patcher --key-pass pass:password \
    --out MetOffice-patched.apk merged-aligned.apk
  ```

## If there are issues

### Multiple phones attached

Find the device serial:

```powershell
adb devices
```

Then run:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Patch-MetOffice.ps1 -Install -DeviceSerial YOUR_DEVICE_SERIAL
```

### Android SDK not found

Pass the SDK path manually:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Patch-MetOffice.ps1 -Install -AndroidSdk "C:\Users\YourName\AppData\Local\Android\Sdk"
```

### Wrong split selected

By default the installer uses:

```text
ABI:      arm64_v8a
Language: en
Density:  xxhdpi
```

Override them if needed:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Patch-MetOffice.ps1 -Install -Abi arm64_v8a -Language en -Density xxxhdpi
```

### App already installed with a different signature

Uninstall the existing Met Office app first, then rerun the patcher.

Uninstalling may remove the app's saved data.

### Manual install

If you do not want the script to install automatically, run it without `-Install`:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Patch-MetOffice.ps1
```

Then install `output/metoffice-patched.apkm` with an APKM/split APK installer, or use ADB:

```powershell
adb install-multiple -r `
  output\install-set\base.apk `
  output\install-set\split_config.arm64_v8a.apk `
  output\install-set\split_config.en.apk `
  output\install-set\split_config.xxhdpi.apk
```

### Temporary files

`work/`, `output/`, and `signing/` are generated locally and can be deleted.
