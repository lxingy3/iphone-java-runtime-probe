# iPhone Java runtime experiment

This is an experimental native iOS host, **not a working game client**.
Only these eight source files belong in the public repository. No game resources,
account snapshot, server private keys, signing credentials, or personal device identifiers are included.
The private server payload is transferred locally over USB and must not be uploaded here.

The current optional client probe adds an explicit `LocalRoutingEnabled` switch, off by
default. Within the configured bundle/version boundary it redirects a narrow allowlist
of login and dispatch URL paths to HTTP loopback port 8088. Resource URLs, unrelated
hosts, unsupported schemes/ports, and user-info URLs retain their original destination.
The original RSA calls and system TLS validation are unchanged. A fourth simulator
fixture checks URL/query preservation and sends a synthetic POST to a loopback mock,
verifying the method, body and encoded query. These checks do not establish that a
real game uses this network path, accepts server signatures, or can enter the world.
Real native gameplay remains unverified.

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

The physical 0.2 server test completed payload extraction and seed import, then failed with `VerifyError: Could not link verifier`. The archive was missing `VerifyClassForMajorVersion`. Version 0.3 links the matching pinned OpenJDK legacy verifier and adds checks for valid and invalid old-format bytecode; bytecode verification remains enabled. The 0.3 runtime suite therefore has fourteen checks.

The physical 0.3 test passed the verifier stage and reached game-server initialization, then found a missing `PollingWatchService`. Version 0.4 restores that portable class from the same pinned OpenJDK source through a bundled `java.base` patch JAR. A fifteenth check registers a directory and verifies delivery of a real file creation event.
User-supplied physical 0.4 logs subsequently showed local HTTP and UDP server startup and an
account persistence round-trip. HTTP access failed after two minutes with another app in
the foreground, then recovered with the same server start time when this app returned.
That is consistent with suspension, not proof of permanent background execution. A short
two-app visible test remained responsive. Native game login and sustained gameplay remain unverified.

## Version 0.5 experiments

The background button submits one finite `BGContinuedProcessingTask` from a user action,
using the immediate-failure strategy. It performs 120 actual HTTP/server-tick checks about
five seconds apart, saves lifecycle and sample evidence, and ends on completion, cancellation,
expiration, a changed server start time, a failed response, or a sampling gap above 15 seconds.
Progress counts completed checks. No automatic renewal, silent audio, fake location work,
or indefinite keep-alive is used. Finishing the diagnostic does not stop the JVM or promise
future background availability. Native gameplay is a separate acceptance condition.

The signed bundle ID MUST match the `BGTaskSchedulerPermittedIdentifiers` prefix.
Re-signing tools that append a team suffix must rewrite that plist entry exactly once.
iloader 2.4.1 performs this rewrite itself; do not pre-append its suffix to the input IPA.
A mismatch disables the test with a visible explanation. Keep the existing bundle identity
when updating an installed test app so its private Documents data can be retained.

Version 0.5 registered the wildcard itself. A physical-device run returned false even
after the installed plist and signed bundle prefix matched. Version 0.6 uses the same
concrete `.servertrial.session` identifier in the plist, registration and submission,
following Apple's static-identifier example. Registration timing remains at app launch.
A separate run token isolates delayed callbacks from cancelled runs. The registration
report now records the installed declarations, build and PID. This is a candidate fix:
physical registration and real background samples must pass before claiming success.
Reference: https://developer.apple.com/videos/play/wwdc2025/227/

The build also produces `RuntimeHostKit/libRuntimeHostKit.a`, an Objective-C header and a
host integration contract. It exports bootstrap, snapshot and scene-event entry points and
omits `main` and app/scene delegates. It never changes an embedding host's cwd or redirects
its native stdout. The present private payload still uses relative java.io paths: server mode
fails closed unless the host already established the required cwd before engine startup.
That restriction requires real game testing or server path migration before integration.
The kit contains no game executable and has not been integrated with an actual game client.
Compiled symbols do not establish runtime coexistence, login, signing or gameplay compatibility.

The optional `RuntimeHost.dylib` and `RuntimeClientProbe.dylib` package the same host
and a local-only observation mode for a separately installed, explicitly configured client.
Observation mode preserves destinations; an explicit opt-in enables only the loopback
URL routes described above. There is no trust bypass, signature bypass or key replacement.
It records allowlisted URL hosts/paths and fingerprints of public keys, never credentials,
request headers or bodies. It needs a matching `RuntimeIntegration.plist` bundle prefix,
version and build. Merely loading the library does not start Java. An additional local
`LocalServer/enable-server.txt` marker plus the private payload and checksum opt into the
same-process server trial on the next app launch. That trial establishes cwd before
UIApplicationMain, but compatibility with the host's earlier initializers is unverified.
These libraries are experimental and do not make a client playable on a private server.

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
Select `simulator-standard` to isolate generic runtime tests on a non-Duo iPhone.
That profile provides no Duo layout or folding evidence.
Results include a screenshot, runtime reports, window geometry, and command help.
Four small UIKit fixtures also load the actual observation libraries. They check original
method and URL results, URL filtering, omission of input/query/key contents, and rejection
of an unexpected host bundle. The routing fixture verifies a real synthetic HTTP request
against a local mock. The third starts the Java probe through the dynamic host
library in the same process and checks that a second JVM request is rejected.
The fixtures contain no game code. Passing them does not
verify library loading, signing, or SDK behavior inside a real game.
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
- https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados

OpenJDK carries GPLv2 with the Classpath Exception. Preserve its license files with binaries.
