# Dopamine-roothide / iOS 16.6.1 port

Status: candidate 8 was installed on iOS 16.6.1 and a Safari fallback initialization crash was reported. Candidate 9, from port commit f2d0a03 and cloud run 44875240621, fixes the early-WebContent/startup race, validates local endpoint URLs and uses the explicit user/foreground launchd domain. Apple-host URL/startup regressions, native compilation, cloud package auditing and local checksum/package verification passed. The App now reports version 0.2.2 / build 1.9. Candidate 9 still needs handset verification; the original cause of WebContent XPC termination is not established by the crash log alone.

## Verified inputs

- User selected **Dopamine-roothide**, not ordinary Dopamine rootless.
- Upstream: `yitenchen123/dsh-ios`.
- Inspected release: `v0.2.2-rc.3+ios24.12`.
- Release source commit: `17a0f178ade3b42e7f469b6ea412c81aaf7f58bd`.
- Input deb: `incoming/ios24.12/dev.airdevs.dsh_0.2.2-rc.3+ios24.12_iphoneos-arm64.deb`.
- Input SHA-256, verified against GitHub's asset digest: `1fd86988ee9371bf2890f8cf7c1812521fc158eb1333b16a62f33ac18014d215`.
- Main App, bundled Node CLI, control dylib and HUD dylib each contain an arm64 Mach-O slice with minimum iOS **15.0**. The `ios24.12` version suffix is a package revision, not an iOS 24 requirement.
- The package installs a native App, external Node/DSH service, launchd jobs, shell/CJS launchers and SpringBoard injection libraries. It is not a standalone Fish Pocket app.

## Required changes

1. Establish an explicit path contract. System-API consumers use paths resolved by the official `jbroot()` API; bootstrap shell tools use jbroot-relative paths, with `/rootfs` for the real device filesystem. Do not blindly replace every `/var/jb` string.
2. Replace the project's `phone-bridge/native/core/roothide.h` rootless stub with the actual SDK at compile time, select `MCP_ROOTHIDE`, and rebuild the injected control library for the target architecture(s).
3. Adapt `DSHWebVC.m`, `DSHSettingsVC.m`, the privileged helper, daemon, ctl/autostart scripts, Node/pnpm wrappers, bridge paths and launchd plists. Remove the `/var/jb` symlink installation guard and preserve existing user data.
4. Rebuild the HUD with proper library install names and verify that its status-file path matches the bridge. User previously permitted omission of ordinary widgets/Watch; that does not automatically authorize removing the phone-control backend of this different project.
5. Preserve Node entitlements and merge roothide App/executable requirements where applicable. Check existing Node compatibility before deciding whether a Node source rebuild is necessary.
6. Package with the real roothide scheme. Verify package metadata separately from the CPU slices of each Mach-O; changing `Architecture` alone does not port the application.
7. Validate install/update/remove scripts, signing and dependency paths, then test engine boot, plugin installation, reboot/re-jailbreak path changes and optional phone control on iOS 16.6.1.

## IPA boundary

Putting only `DSH.app` into `Payload` would create a client package, not an embedded engine build: the App expects an external Node service and helper. No standalone IPA has been produced from this repository.

## Cloud build proposal

The user explicitly authorized creation of `xaioxin0312/dsh-ios`, source pushes and cloud builds. That fork now exists. Adaptation work is on local branch `roothide-ios16`; native components, payload staging, runtime path adaptation, a manual workflow and package auditing are being integrated. The upstream release assets remain unchanged. No device installation or runtime validation has been performed.

## Sources reviewed

- roothide/Developer: `README.md`, `roothide.md`, `interface.md`, `entitlements.md`.
- roothide/RootHidePatcher: `patch.sh` at master `80c16e08da33fecd27c0ff35777f37afd171868b`. It performs partial load-path, layout, entitlement and script conversion; remaining fixed-path warnings do not establish compatibility.
- The release's actual deb metadata and binaries, plus the pinned release source in this checkout.
