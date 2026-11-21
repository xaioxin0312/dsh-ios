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

```sh
node --test roothide-port/tests/roothide-node-preload.test.cjs
python3 roothide-port/tests/verify_payload_stage.py PATH_TO_RELEASE_DEB
```

Run the Node suite with Node 24 on POSIX. The stage verifier extracts the real
archive into private temporary storage and only checks shell syntax, never
executes maintainer scripts or installs packages.
