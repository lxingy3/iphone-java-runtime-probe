#!/usr/bin/env bash
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'This native device build requires macOS and the Apple iPhoneOS SDK.' >&2
  exit 2
fi
if [[ "$(uname -m)" != arm64 ]]; then
  echo 'This pinned experiment currently requires an Apple Silicon Mac.' >&2
  exit 2
fi
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
mkdir -p build
exec > >(tee build/build.log) 2>&1
sdk_name="${PROBE_SDK:-iphoneos}"
extra_target_flags=()
case "$sdk_name" in
  iphoneos)
    target_conf=ios-aarch64-zero-release
    build_destination='generic/platform=iOS'
    ;;
  iphonesimulator)
    target_conf=iossim-aarch64-zero-release
    build_destination='generic/platform=iOS Simulator'
    extra_target_flags=( '--with-extra-cflags=-target arm64-apple-ios-simulator -mios-simulator-version-min=18.5' '--with-extra-cxxflags=-target arm64-apple-ios-simulator -mios-simulator-version-min=18.5' )
    ;;
  *) echo "Unsupported test SDK: $sdk_name" >&2; exit 2 ;;
esac
export PROBE_SDK="$sdk_name"
for command_name in xcodebuild xcrun xcodegen git python3 javac jar gmake autoconf; do
  command -v "$command_name" >/dev/null || { echo "Missing build tool: $command_name"; exit 2; }
done
mobile_commit=c13417aa36f8f44755d0984b58aa735d0b41f233
if [[ ! -d build/mobile/.git ]]; then
  git init build/mobile
  git -C build/mobile remote add origin https://github.com/openjdk/mobile.git
  git -C build/mobile fetch --depth 1 origin "$mobile_commit"
  git -C build/mobile checkout --detach FETCH_HEAD
fi
test "$(git -C build/mobile rev-parse HEAD)" = "$mobile_commit"
python3 - <<'PY'
from pathlib import Path
# Zero selects bsd_zero, so it cannot reference WX helpers implemented only in
# bsd_aarch64. It interprets bytecode and does not generate executable JIT pages.
p=Path('build/mobile/src/hotspot/share/utilities/macros.hpp')
s=p.read_text()
before='''#define MACOS_AARCH64_ONLY(x) MACOS_ONLY(AARCH64_ONLY(x))
#if defined(__APPLE__) && defined(AARCH64)
#define MACOS_AARCH64 1'''
after='''#define MACOS_AARCH64_ONLY(x) NOT_ZERO(MACOS_ONLY(AARCH64_ONLY(x)))
#if defined(__APPLE__) && defined(AARCH64) && !defined(ZERO)
#define MACOS_AARCH64 1'''
if before in s:
    assert s.count(before)==1
    p.write_text(s.replace(before,after))
else:
    assert after in s, 'Unexpected upstream WX macro layout'
p=Path('build/mobile/src/hotspot/share/runtime/thread.inline.hpp')
s=p.read_text()
before='#if defined(__APPLE__) && defined(AARCH64)'
after='#ifdef MACOS_AARCH64'
if before in s:
    assert s.count(before)==1
    p.write_text(s.replace(before,after))
else:
    assert after in s, 'Unexpected upstream thread WX guard'
p=Path('build/mobile/src/hotspot/os_cpu/bsd_zero/os_bsd_zero.cpp')
s=p.read_text()
before='#if defined(AARCH64) && defined(__APPLE__)'
after='#ifdef MACOS_AARCH64'
if before in s:
    assert s.count(before)==1
    p.write_text(s.replace(before,after))
else:
    assert after in s, 'Unexpected upstream Zero OS WX guard'
PY
python3 - <<'PY'
import hashlib,os,pathlib,urllib.request,zipfile
simulator=os.environ['PROBE_SDK']=='iphonesimulator'
filename='libffi-ios-sim.zip' if simulator else 'libffi-ios.zip'
checksum='701b522e3eff0263f18d4a9e487f0a7ac30050fb2af20e86b6849daa14f5781f' if simulator else '4f39fd1d53fbd69d1bdbd915413077d130daa3f6792d1b3a03a690a9cbd4dea3'
p=pathlib.Path('build')/filename
if not p.exists():
    p.write_bytes(urllib.request.urlopen('https://github.com/openjdk-mobile/ios-tools/releases/download/libffi-build/'+filename).read())
assert hashlib.sha256(p.read_bytes()).hexdigest()==checksum
with zipfile.ZipFile(p) as z:
    for name in z.namelist():
        if name.startswith('/') or '..' in pathlib.PurePosixPath(name).parts: raise ValueError('Invalid archive path')
    z.extractall('build/support')
PY
sdk_root="$(xcrun --sdk "$sdk_name" --show-sdk-path)"
mac_sdk_root="$(xcrun --sdk macosx --show-sdk-path)"
support_root="$project_root/build/support"
cd build/mobile
# The packaging tools must use the same java.base build signature and iOS-aware
# platform enum as the target. A vendor JDK of the same feature version is insufficient.
version_options=( --with-version-opt=iphone-probe --with-vendor-name=OpenJDKMobileProbe )
host_jdk="$project_root/build/mobile/build/macos-aarch64-server-release/images/jdk"
if [[ ! -x "$host_jdk/bin/jlink" ]]; then
bash configure --with-conf-name=macos-aarch64-server-release --disable-warnings-as-errors \
  --with-jvm-variants=server --with-sysroot="$mac_sdk_root" "${version_options[@]}"
gmake CONF=macos-aarch64-server-release images
fi
test -x "$host_jdk/bin/jmod" && test -x "$host_jdk/bin/jlink"
"$host_jdk/bin/java" -version
bash configure --with-conf-name="$target_conf" --disable-warnings-as-errors \
  --openjdk-target=aarch64-macos-ios --with-jvm-variants=zero \
  "${version_options[@]}" "${extra_target_flags[@]}" \
  --with-build-jdk="$host_jdk" \
  --with-sysroot="$sdk_root" --with-libffi-include="$support_root/include/ffi" \
  --with-libffi-lib="$support_root" --with-cups-include="$mac_sdk_root/usr/include"
# iOS static libraries avoid the unsupported ELF shared-library image target.
gmake CONF="$target_conf" \
  hotspot-zero-static-libs java.base-static-libs \
  java.management-static-libs jdk.management-static-libs \
  java.base-gendata java.base-copy \
  java.logging-java java.management-java java.naming-java java.security.sasl-java \
  java.sql-java java.transaction.xa-java java.xml-java jdk.management-java jdk.unsupported-java jdk.zipfs-java
cd "$project_root"
device_root="$project_root/build/mobile/build/$target_conf"
export DEVICE_ROOT="$device_root" HOST_JDK="$host_jdk"
python3 - <<'PY'
import json,os,pathlib,shutil,subprocess
device=pathlib.Path(os.environ['DEVICE_ROOT'])
host=pathlib.Path(os.environ['HOST_JDK'])
modules=['java.base','java.logging','java.management','java.naming','java.security.sasl',
         'java.sql','java.transaction.xa','java.xml','jdk.management','jdk.unsupported','jdk.zipfs']
jmods=pathlib.Path('build/ios-jmods');jmods.mkdir(parents=True,exist_ok=True)
for module in modules:
    classes=device/'jdk/modules'/module
    if not (classes/'module-info.class').is_file(): raise SystemExit('Missing compiled module '+module)
    args=[str(host/'bin/jmod'),'create','--target-platform','ios-aarch64','--class-path',str(classes)]
    conf=device/'support/modules_conf'/module
    if conf.is_dir(): args+=['--config',str(conf)]
    libs=device/'support/modules_libs'/module
    if libs.is_dir():
        staging=pathlib.Path('build/module-data')/module
        for source in libs.rglob('*'):
            if source.is_file() and source.suffix not in {'.so','.dylib','.a','.dll','.pdb','.debuginfo'}:
                target=staging/source.relative_to(libs);target.parent.mkdir(parents=True,exist_ok=True)
                shutil.copy2(source,target)
        if staging.is_dir(): args+=['--libs',str(staging)]
    modified=device/'support/modules_legal'/module
    original=pathlib.Path('build/mobile/src')/module/'share/legal'
    notices=[device/'support/modules_legal/common',modified if modified.is_dir() else original]
    notices=[str(p) for p in notices if p.is_dir()]
    if notices: args+=['--legal-notices',os.pathsep.join(notices)]
    subprocess.run(args+[str(jmods/(module+'.jmod'))],check=True)
subprocess.run([str(host/'bin/jlink'),'--module-path',str(jmods),'--add-modules',','.join(modules),
                '--strip-debug','--no-header-files','--no-man-pages','--output','build/runtime'],check=True)
image=pathlib.Path('build/runtime')
release=(image/'release').read_text()
module_line=next(x for x in release.splitlines() if x.startswith('MODULES='))
modules=set(module_line.split('=',1)[1].strip('"').split())
required={'java.base','java.logging','java.management','java.naming','java.sql','java.xml','jdk.management','jdk.unsupported','jdk.zipfs'}
missing=sorted(required-modules)
pathlib.Path('build/module-check.json').write_text(json.dumps({'missing':missing,'modules':sorted(modules)},indent=2))
if missing: raise SystemExit('iOS runtime is missing required modules: '+','.join(missing))
for filename in ['conf/security/java.security','lib/tzdb.dat','lib/modules']:
    if not (image/filename).is_file(): raise SystemExit('Missing runtime data: '+filename)
for filename in ['LICENSE','ASSEMBLY_EXCEPTION']:
    shutil.copy2(pathlib.Path('build/mobile')/filename,image/filename)
(image/'SOURCE.txt').write_text('OpenJDK Mobile source: https://github.com/openjdk/mobile/tree/c13417aa36f8f44755d0984b58aa735d0b41f233\n')
(image/'LOCAL-PATCHES.txt').write_text('Guard MACOS_AARCH64 and MACOS_AARCH64_ONLY against ZERO, and align thread.inline.hpp with the same guard, to avoid references to unavailable JIT WX helpers.\nReproducible patch: https://github.com/lxingy3/iphone-java-runtime-probe/blob/main/scripts/build.sh\n')
PY
libraries=( "$device_root/hotspot/variant-zero/libjvm/objs/static/libjvm.a" "$support_root/libffi.a" )
for entry in java.base/java java.base/zip java.base/net java.base/nio java.base/jimage java.management/management jdk.management/management_ext; do
  module="${entry%/*}"; library="${entry#*/}"
  native_library="$device_root/support/native/$module/lib$library/static/lib$library.a"
  test -f "$native_library" || { echo "Missing native iOS library: $native_library"; exit 3; }
  libraries+=( "$native_library" )
done
libtool -static -o build/libOpenJDK.a "${libraries[@]}"
mkdir -p build/include
cp "$device_root"/jdk/include/*.h build/include/
cp "$device_root"/jdk/include/ios/*.h build/include/
if [[ -e build/OpenJDK.xcframework ]]; then
  echo 'Framework already exists; use a clean checkout to rebuild.' >&2; exit 3
fi
xcodebuild -create-xcframework -library "$project_root/build/libOpenJDK.a" -headers "$project_root/build/include" -output "$project_root/build/OpenJDK.xcframework"
mkdir -p build/java
javac --release 21 -encoding UTF-8 -d build/java Java/DeviceProbe.java
jar --create --file build/DeviceProbe.jar -C build/java .
xcodegen generate --spec project.yml
xcodebuild -project RuntimeProbe.xcodeproj -scheme RuntimeProbe -configuration Release \
  -destination "$build_destination" -derivedDataPath build/DerivedData ARCHS=arm64 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
if [[ "$sdk_name" == iphonesimulator ]]; then
python3 - <<'PY'
import json,pathlib,shutil,subprocess,time
output=pathlib.Path('build/simulator-results');output.mkdir(parents=True,exist_ok=True)
def command(*args,check=True,timeout=180):
    return subprocess.run(args,check=check,capture_output=True,text=True,timeout=timeout)
inventory=json.loads(command('xcrun','simctl','list','devices','available','--json').stdout)
devices=[d for runtime,items in inventory['devices'].items() if '.iOS-' in runtime for d in items if d['name'].startswith('iPhone')]
if not devices: raise SystemExit('No available iPhone simulator runtime')
device=next((d for d in devices if d['state']=='Booted'),devices[0]);udid=device['udid']
if device['state']!='Booted': command('xcrun','simctl','boot',udid)
command('xcrun','simctl','bootstatus',udid,'-b',timeout=240)
command('xcrun','simctl','install',udid,'build/DerivedData/Build/Products/Release-iphonesimulator/RuntimeProbe.app')
command('xcrun','simctl','launch','--terminate-running-process',udid,'local.astaps.RuntimeProbe','--probe-auto-run')
container=pathlib.Path(command('xcrun','simctl','get_app_container',udid,'local.astaps.RuntimeProbe','data').stdout.strip())
report=container/'Documents/runtime-probe.json'
for _ in range(120):
    if report.is_file(): break
    time.sleep(1)
for name in ['runtime-probe.json','jvm-output.log']:
    source=container/'Documents'/name
    if source.is_file(): shutil.copy2(source,output/name)
command('xcrun','simctl','io',udid,'screenshot',str(output/'screen.png'),check=False)
result=json.loads(report.read_text()) if report.is_file() else {'passed':False,'error':'No report before timeout'}
result['environment']='iOS Simulator, not a physical iPhone'
(output/'acceptance.json').write_text(json.dumps(result,indent=2))
print(json.dumps(result,indent=2))
if not result['passed']: raise SystemExit('Simulator runtime probe failed; inspect retained results')
PY
exit 0
fi
mkdir -p build/Payload
cp -R build/DerivedData/Build/Products/Release-iphoneos/RuntimeProbe.app build/Payload/
(cd build && zip -qr RuntimeProbe.ipa Payload)
echo 'Unsigned experimental IPA created. Real iPhone execution is not yet verified.'
