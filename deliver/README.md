# u2.jar 0.4.1: loopback-bind build (handoff to Hermes)

This build comes from `openatx/android-uiautomator-server-jar` at tag `0.4.1`
(`1ebbe916835be9be298e619ffb859ddf157d09d1`), with exactly two edits. The
HTTP/JSON-RPC server binds `127.0.0.1` instead of all interfaces, and the log line matches the new bind.

| File | Contents |
|---|---|
| `claude-cloud-u2-0.4.1-loopback.jar` | the build (`assembleDebug` output, `app-debug.apk` renamed) |
| `claude-cloud-u2-0.4.1-loopback.SHA256SUMS` | sha256 + md5 of the jar |
| `claude-cloud-u2-0.4.1-loopback.patch` | `git diff`, 2 hunks |
| `claude-cloud-u2-0.4.1-loopback.build-log.txt` | Gradle output (`BUILD SUCCESSFUL`) |
| `claude-cloud-u2-0.4.1-loopback.verification.txt` | all check output |

- sha256: `9eb6a26c9393caf4face0898d80a520dd65e24afc2441ec2aca96e6e9627a446`
- md5: `91d8169a62bb4d7fcdfe6a12eb4abf47`. uiautomator2 3.7.1 compares this md5 against the jar on the phone.

## Status against the plan

| Phase | Result |
|---|---|
| 1. Source commit + upstream hash | **PASS** |
| 2. Fail-first on device | **NOT RUN**: no phone or second Wi-Fi device on this build host |
| 3. Patch (2 hunks), build, dexdump string | **PASS** |
| 4. Device + network + Python client proof | **NOT RUN**: same reason |
| 5. Deliver | Committed here. Copyparty is not reachable from this host |

Extra checks done in place of the device tests (details in verification.txt):

- **Reproducible build.** The unpatched 0.4.1 source, rebuilt with the same toolchain, matches the official
  release `u2.jar` byte for byte, apart from `META-INF` signing.
- **Full diff audit, upstream vs. patched.** After normalizing dex index renumbering, the only instruction
  changes are `NanoHTTPD.<init>(I)` → `const-string "127.0.0.1"` + `NanoHTTPD.<init>(String,I)` and the
  log string. The remaining delta is `versionName` `0.4.1` → `0.4.1-dirty`, set by the androidGitVersion
  plugin. `versionCode` stays 4002.
- **Bind semantics on the host JVM.** I ran the same nanohttpd 2.3.1 library on the build host itself
  (not on a phone), using each constructor form. `super(port)` answered on the non-loopback IP.
  `super("127.0.0.1", port)` refused it and still served on loopback.

## Testing it yourself (Phases 2 + 4)

The `.jar` **is** the APK: it's the `app-debug.apk` build output, renamed the way upstream CI renames it.
It has no activities or services. It runs through `app_process`, the same way uiautomator2 runs it.
**Don't `adb install` it.** Its package name is `com.github.uiautomator`, the same as the keyboard app.

Requirements:
- A Mac or Linux computer (Windows: use WSL or Git Bash) with `adb`, `curl` and `python3`.
- The phone plugged in by USB, with USB debugging authorized.
- **The computer on the same Wi-Fi as the phone.** It acts as the "second device" that tries to reach the
  phone over the network.

```bash
git clone -b claude/uiautomator2-loopback-bind-jc1twz https://github.com/TheOneBestAgent/Tanbro.git
cd Tanbro/deliver && ./test-u2-loopback.sh
```

The script checks both jar hashes, downloading the upstream 0.4.1 jar for the baseline. It then runs:
1. The baseline: the bug must reproduce.
2. The patched jar: log line, loopback-only listener, unreachable over Wi-Fi, tunnel `pong`.
3. The real uiautomator2 3.7.1 client in a throwaway venv, with the patched asset and the keyboard APK
   deleted. It must read the screen, and the server it launches must also be loopback only.

It cleans up the phone afterwards and writes `claude-cloud-u2-0.4.1-loopback.device-verification.txt`.
Exit code 0 means every check passed.

Options:
- `PHONE_IP=…`: set this if the phone's Wi-Fi IP isn't detected.
- `ANDROID_SERIAL=…`: set this if more than one device is attached.
- `SKIP_PYTHON=1`: skips the client test.

If the baseline isn't reachable over Wi-Fi (client isolation, or the computer on Ethernet or another
network), the network checks report FAIL as inconclusive. Use a network that allows device-to-device
traffic.

**Phase 4 still has to pass on a real device before Hermes installs this.** Run it on any host with a
USB-debuggable phone and a second device on the same Wi-Fi, using the commands in the plan, and use this
jar as-is. Its hash must match the one above.
