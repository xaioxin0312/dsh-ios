# Dopamine-roothide / iOS 16.6.1 candidate

This fork targets the user's **Dopamine-roothide** environment, not ordinary Dopamine's `/var/jb` layout. A successful cloud build and package audit do not establish that installation or runtime behavior has passed on a handset.

## What is built

- The pinned upstream `v0.2.2-rc.3+ios24.12` deb provides its existing DSH JavaScript runtime, Node 24 executable, pure-JavaScript pnpm, resources and phone bridge. Its digest is checked before use.
- The App executable, privileged helper, launcher, native Node path adapter, log reader and SpringBoard control/HUD libraries are rebuilt for this fork with roothide's headers/libraries and Theos scheme. The original rootless native App/helper/injection binaries are removed from the input layout before building.
- Bootstrap scripts, launchd jobs and package install/remove scripts are staged specifically for roothide. JavaScript/Node filesystem calls and subprocess boundaries use the dedicated preload and native launcher described in `PATH-CONTRACT.md`.
- Node's upstream executable instructions and existing entitlements must be preserved. Required roothide executable entitlements are merged, not used to replace the original permissions.

The `ios24.12` suffix is an upstream package revision, not an iOS 24 requirement. The native deployment target is iOS 15.0 and the compile SDK is iOS 16.5; the target handset for runtime verification remains iOS 16.6.1.

## Build from Windows using GitHub Actions

After these files are on the fork's default branch, open **Actions → Dopamine-roothide candidate → Run workflow**. The workflow uses a macOS runner with Xcode, pinned `roothide/theos`, its pinned submodules and a pinned iPhoneOS 16.5 SDK. Inputs are recorded in `pinned-inputs.json`.

It runs host tests, rebuilds the native parts, packages using `THEOS_PACKAGE_SCHEME=roothide`, and audits the deb before uploading it. The workflow does not install a package, respring a device, create a GitHub Release or publish to the upstream repository.

Artifacts contain the candidate `.deb`, SHA-256, `build-manifest.json` and `package-verification.json`. A separate artifact holds the build log. No Apple developer certificate or device UDID is used to produce this jailbreak package.

## Local macOS entry point

Configure the pinned roothide Theos checkout and iPhoneOS 16.5 SDK, plus `ldid`, `dpkg-deb`, GNU make, Python 3 and Node 24:

```bash
export THEOS=/path/to/roothide/theos
export MAKE=gmake
bash roothide-port/run-tests.sh
bash roothide-port/build.sh
```

To use a locally downloaded copy of the exact pinned upstream deb, set `DSH_PORT_INPUT_DEB` to its absolute path. Its digest must still match. The input archive is read-only and the build works in a separate temporary directory.

## Verification boundary

The automated audit checks package identity/architecture, absence of the old `/var/jb` outer payload, expected files, ARM64/ARM64e slices, binary minimum OS versions, signature/entitlement metadata, injected-library dependencies and preservation of the original Node instruction section and entitlements. It does not execute an iOS binary on the host.

The following still need device evidence: installation and daemon startup, the App loading the local UI, model requests, plugin install/enable/disable, SpringBoard injection and phone control, state sharing, and behavior after reboot/re-jailbreak changes the real jbroot. Existing user files are not removed or reset by this build.

This is a jailbreak-system package, not a standalone IPA. Copying its `.app` into `Payload` would omit the external Node/launchd backend.

## Upstream rules

- https://github.com/roothide/Developer
- https://github.com/roothide/theos
- https://github.com/yitenchen123/dsh-ios
