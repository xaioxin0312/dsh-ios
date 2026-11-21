# Roothide payload path contract

## Staging

```sh
python3 roothide-port/prepare_payload.py INPUT_EXTRACTED_ROOT OUTPUT_LOGICAL_PAYLOAD
```

Pass the POSIX `dpkg-deb -R` extraction of the separately SHA-256-verified
`0.2.2-rc.3+ios24.12` release. Use Python 3.9+ and a POSIX filesystem. The output
must not exist and its parent must exist. The stage is built in a private sibling
temporary directory and published after the checks and transforms succeed. All
mutated inputs are checked against release SHA-256 values, and the only permitted
links are the 13 exact npm `.bin` links. The extractor's input stays read-only.

Output is a logical layout (`Applications`, `Library`, `etc`, `usr`) plus
`DEBIAN/{control,postinst,prerm}`. Use the Roothide Theos package scheme and pass
these control files separately from the data payload; `iphoneos-arm64e` is the
expected metadata, not a substitute for rebuilding. Node's original Mach-O is
copied unchanged as `usr/lib/dsh/bin/node-real`. Inject/sign the native launcher
as `usr/lib/dsh/bin/node`; inject the rebuilt `DSHNativeApp`, `dsh-app-helper`,
`mcp-logreader` and the control/HUD dylibs at the original logical paths. The
old `DSHLauncher` is also removed from the input and replaced by a rebuilt
roothide-aware launcher inside the App bundle. Preserve the helper's root/setuid mode
and merge Node's Roothide entitlements into its original entitlements while
signing on the build host; neither maintainer script re-signs binaries.

## Launchd domain and build identity

All package job management uses `user/foreground`: `bootstrap` receives that
domain, and `print`, `bootout` and `kickstart` receive
`user/foreground/<package-label>`. Legacy `load`, `unload`, `remove` and bare-label
`list` are not used as domain-ambiguous fallbacks. This is the explicit iOS 16
foreground-user target implemented by Roothide's `launchctl`.

On configure, `postinst` boots out only `dev.airdevs.dsh.agent`,
`dev.airdevs.dsh.phone-bridge` and `dev.airdevs.dsh`, then bootstraps and restarts
the two main services using the newly installed plists. Candidate 8's `system`
alias may already have loaded these jobs in the foreground domain; this replaces
those same registrations without killing processes selected by name or touching
other services. Removal/deconfiguration stops only these three package labels.
`prerm upgrade` preserves them until the new `postinst` replaces them.

The staged service plists omit the original `UserName=mobile` and
`GroupName=mobile`, since the user domain supplies the execution identity; those
keys describe root launchd identity overrides. The optional agent also omits its
original `LimitLoadToSessionType=Aqua`, a session-type filter rather than a user
domain selector. Other service properties, logical paths and user data stay as
before. Actual foreground-user identity and execution remain device acceptance
checks. A domain compatibility warning alone is not evidence that a job failed
to run, and this change makes no claim about the separate App/WebKit crash.

The copied App plist is stamped `CFBundleShortVersionString=0.2.2`,
`CFBundleVersion=1.<DSH_PORT_BUILD_NUMBER>` (digits only, otherwise `1.0`), and
`DSHRHPackageVariant=dopamine-roothide`. Original release hashes remain unchanged.

## Runtime

| Context | Paths |
| --- | --- |
| Bootstrap shell, launchctl, uicache, plist arguments and logs | Logical paths from `/`; explicit `/rootfs/` for physical iOS filesystem paths |
| Runtime DSH home | Logical `/var/mobile/.dsh`, passed to Node as `jbroot("/var/mobile/.dsh")` unless explicitly overridden |
| HUD | Node/native use real `/var/mobile/Library/DSH`; shell diagnostics use `/rootfs/var/mobile/Library/DSH` |
| Node and its module loader | Real paths; launcher sets `DSH_JBROOT`, `DSH_HOME`, real `PATH` and path-like environment values, and passes an absolute preload via `--require` |
| Node spawning bootstrap | Real executable and cwd for libuv; virtual argv path operands, PATH and known path-valued environment for bootstrap/libvroot |

The preload maps legacy `/var/jb` in common fs methods, CommonJS and ESM module
resolution and child-process helpers. It leaves ordinary physical `/var/mobile`
untouched. `process.execPath` stays the actual Node binary and fork retains the
preload. `postinst` creates/chowns only package-owned log and HUD directories,
registers the app and reloads the two services. It does not run upstream extras,
rewrite DSH home, clean Web Clips, or migrate existing configs. Bridge registration
remains available by explicit `dsh-phone-bridge-ctl config-on`; the automatic
upstream heal and bridge configuration migration are disabled to protect existing
YAML. Existing registrations remain valid. This stage neither imports nor deletes
data from another jailbreak root.

The preload does not port arbitrary native Node addons or rewrite shell source,
embedded shell commands, special Node CLI options, or arbitrary environment
variables. In shell source use logical paths or explicit `/rootfs` paths. The
preload is not libvroot and Linux tests do not establish iOS launchd, setuid,
SpringBoard, JIT or HUD behavior.

## References and tests

- [Roothide development](https://github.com/roothide/Developer/blob/main/README.md)
- [Bootstrap and logical paths](https://github.com/roothide/Developer/blob/main/roothide.md)
- [Official `jbroot` and `rootfs` APIs](https://github.com/roothide/Developer/blob/main/interface.md)
- [libvroot](https://github.com/roothide/Developer/blob/main/vroot.md)
- [Mirrored paths](https://github.com/roothide/Developer/blob/main/filemirror.md)
- [Roothide foreground-user target and legacy service remapping](https://github.com/roothide/launchctl/blob/main/xpc_helper.c)
- [Roothide bootstrap/bootout domain compatibility](https://github.com/roothide/launchctl/blob/main/bootstrap.c)
- [Apple launchd plist identity and session keys](https://github.com/apple-oss-distributions/launchd/blob/main/man/launchd.plist.5)

```sh
node --test roothide-port/tests/roothide-node-preload.test.cjs
python3 roothide-port/tests/verify_payload_stage.py PATH_TO_RELEASE_DEB
```

Run the Node suite with Node 24 on POSIX. The stage verifier extracts the real
archive into private temporary storage and checks shell syntax. It never
runs maintainer filesystem/service operations or installs packages. It executes the
launch-control portions against a recording mock to check actual argv, loaded and
absent jobs, upgrade replacement, bootstrap error propagation and PID parsing.
