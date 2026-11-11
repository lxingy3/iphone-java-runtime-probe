# iPhone Java runtime experiment

This is an experimental native iOS host, **not a working game client**.
Only these eight source files belong in the public repository. No game resources,
account snapshot, server private keys, signing credentials, or personal device identifiers are included.
The private server payload is transferred locally over USB and must not be uploaded here.

## Verified results

On November 11, 2026, version 0.1 passed all twelve runtime checks on a physical
non-jailbroken iPhone running iOS 27.3: module loading, JavaBeans introspection,
scheduling, file persistence, JAR filesystems, platform threads, reflection,
TCP/UDP loopback, RSA, XML, and management APIs. The VM was OpenJDK 64-Bit Zero VM,
Java 28-internal, Darwin. This proves those prerequisites, not full server or game compatibility.

[Simulator run 11](https://github.com/lxingy3/iphone-java-runtime-probe/actions/runs/43017706671)
and [device build 12](https://github.com/lxingy3/iphone-java-runtime-probe/actions/runs/43018423186)
produced the tested runtime. The separate Windows experiment ran the embedded server
with JIT disabled and preserved the account through restart.

Version 0.2 added a private-payload loader and Duo-aware UI. Simulator runs 13/15 passed all twelve checks, and physical size-transition reports retained one process and one JVM start across outer display, inner display, and landscape. Partial-fold angles and complete visual acceptance remain unverified.

Version 0.3 moves first-install archive SHA-256 out of the Zero interpreter into iOS CommonCrypto, reports verification and extraction progress, and keeps the foreground test awake. A simulator benchmark compares native and Java hashing of the same 16 MiB file against a known digest. Performance improvement must be measured; full private-payload validation is a separate physical test.
Full server execution on the phone, sustained memory usage, background survival, native game
client integration, and folding transitions have not yet passed acceptance.

## Duo layout and lifecycle

Build the app using Xcode 27.1 and the iOS 27.1 SDK or newer. The app uses a UIWindowScene,
UIArrangementViewController on supported systems, safe-area constraints, scrollable panels,
and Dynamic Type. It reads actual window geometry rather than assuming a fixed screen size
or interpreting orientation as a fold state. The system arrangement handles active hinge
reserved regions. A process-owned session prevents another JVM from being created when
views or scenes change. This does not promise survival after iOS terminates the process.

Physical acceptance must cover outer display, fully unfolded inner display, partially folded
poses, landscape and portrait, larger text, and repeated transitions during an active test.
Require usable buttons, unclipped content, no controls trapped in reserved regions,
unchanged JVM start count, and preserved state. `layout-history.json` and `host-status.json`
provide measurements; real-device interaction is still necessary.

## Build

Use an Apple Silicon Mac with Xcode 27.1+, JDK 27, GNU make, autoconf, XcodeGen,
Python 3, and Git. `bash scripts/build.sh` builds pinned OpenJDK Mobile source commit
`c13417aa36f8f44755d0984b58aa735d0b41f233` and the app. The script contains the reproducible
Zero-only changes for non-executable entry descriptors and early JAVA_HOME initialization.
The runtime has eighteen modules; native AWT graphics are not included.

The manual workflow uses GitHub's standard `xcode-27` runner, a 90-minute limit,
and no scheduled runs. It reuses SHA-256-verified runtime artifacts from runs 11/12
to avoid rebuilding unchanged native libraries. These temporary artifacts expire after
seven days; if unavailable, rebuild from source by omitting `PROBE_RUNTIME_ARCHIVE`
and `PROBE_RUNTIME_SHA256`. An old runtime archive alone does not provide Duo layout:
the app is compiled and linked with the new SDK, recorded in `toolchain.json`.

Select `simulator` for the iPhone Duo simulator and automatic runtime checks.
Results include a screenshot, runtime reports, window geometry, and command help.
Simulator results do not establish physical signing, folding transitions, memory limits,
or game performance. Select `device` for an unsigned ARM64 `RuntimeProbe.ipa`.
Signing and installation are separate steps. No cloud game server or paid subscription is created.

## Local payload contract

The host expects `Documents/server-payload.zip` and a matching `server-payload.sha256`.
The archive must include a reviewed Java launcher, dependency JARs, resources, and configuration.
It is hashed by the native host before extraction. Java verifies the computed digest against the expected checksum; non-native callers retain the original Java hashing path. Entry paths and extracted size are bounded. After preparation,
a matching marker reuses the existing server directory without replacing its saved database.
The launcher is loaded with an isolated URLClassLoader in the existing Zero JVM.
Neither native dynamic code nor JIT entitlement is needed for this experiment.

Keep the app in the foreground and select one test per launch. Runtime reports and logs are
available through app document sharing. Server tests also record loopback HTTP readiness,
resident footprint, elapsed time, and JVM start count. A foreground server test does not solve
the need to run the game and server together when the computer is off.

## References

- https://github.com/openjdk/mobile
- https://openjdk-mobile.github.io/ios/helloworld/
- https://developer.apple.com/iphone-duo/prepare/
- https://developer.apple.com/videos/play/tech-talks/111463/

OpenJDK carries GPLv2 with the Classpath Exception. Preserve its license files with binaries.
