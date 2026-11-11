# iPhone Java runtime probe

This is an **unbuilt experimental iOS test app**, not Genshin and not a working private-server IPA.
It tests a prerequisite for running the existing private server locally on a non-jailbroken phone:
an OpenJDK Mobile Zero runtime with modules beyond `java.base`.

The separate Windows experiment has already run AstaPS 7.2 with a Java/H2 embedded datastore,
disabled JIT, and preserved the account through restart. That does not verify this iOS build.

Only this directory is suitable for an external build. It contains no account snapshot,
game assets, server private keys, Apple credentials, or personal device identifiers.
Do not upload the parent experiment directory or the server-payload ZIP.

## Build

Requirements: an Apple Silicon Mac with Xcode's iPhoneOS SDK, JDK 27, GNU make, autoconf, XcodeGen,
Python 3, Git, and network access to the pinned open-source dependencies.

The script downloads a checksum-pinned macOS JDK 28 EA for module packaging. It builds
the iOS Zero VM and three required native-library modules as static libraries, then
packages ten Java modules with host `jmod`/`jlink`. The first experiment using the generic
OpenJDK `images` target failed because that iOS target supplied ELF `-soname` flags to
Apple's linker. The revised static-only route is awaiting a successful native build.

Run `bash scripts/build.sh` or use the included manually triggered GitHub Actions workflow.
The workflow uses a standard macOS runner, has a 90-minute timeout, and has no scheduled runs.
If successful, it produces an unsigned `RuntimeProbe.ipa`; signing and installation are a separate step.
No App Store, TestFlight, Apple developer subscription, or cloud game server is created.

The first native build may reveal missing iOS APIs or static-library symbols. Such a build
failure is an experiment result, not evidence that the phone can run AstaPS.

## On-device acceptance

1. Install the signed test IPA on the target phone.
2. Keep the app in the foreground and tap Run.
3. Export `runtime-probe.json` and `jvm-output.log` through Files.
4. Require successful file I/O, threads, reflection, TCP/UDP loopback, RSA, XML, and management APIs.
5. Only then integrate the actual embedded server payload and measure memory/performance.

A foreground server test still does not solve native Genshin client compatibility or same-process
integration. The final game must remain usable when the user's computer is off.

## References

- https://github.com/openjdk/mobile
- https://github.com/openjdk-mobile/ios-tools
- https://openjdk-mobile.github.io/ios/helloworld/

OpenJDK carries GPLv2 with the Classpath Exception; preserve its accompanying license files when distributing binaries.
