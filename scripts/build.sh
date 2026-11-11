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
import hashlib,pathlib,tarfile,urllib.request,zipfile
p=pathlib.Path('build/libffi-ios.zip')
if not p.exists():
    p.write_bytes(urllib.request.urlopen('https://github.com/openjdk-mobile/ios-tools/releases/download/libffi-build/libffi-ios.zip').read())
assert hashlib.sha256(p.read_bytes()).hexdigest()=='4f39fd1d53fbd69d1bdbd915413077d130daa3f6792d1b3a03a690a9cbd4dea3'
with zipfile.ZipFile(p) as z:
    for name in z.namelist():
        if name.startswith('/') or '..' in pathlib.PurePosixPath(name).parts: raise ValueError('Invalid archive path')
    z.extractall('build/support')
# Use native macOS tools to package the iOS bytecode, avoiding a cross-built host JDK.
p=pathlib.Path('build/host-jdk-28.tar.gz')
if not p.exists():
    urllib.request.urlretrieve('https://github.com/adoptium/temurin28-binaries/releases/download/jdk-28%2B9-ea-beta/OpenJDK-jdk_aarch64_mac_hotspot_28_9-ea.tar.gz',p)
with p.open('rb') as f:
    assert hashlib.file_digest(f,'sha256').hexdigest()=='c4c7416891f86b56e7d831c300a0541f649d6a3267598aba8b82a6158cf7e35a'
with tarfile.open(p) as archive:
    archive.extractall('build/host-jdk',filter='data')
PY
sdk_root="$(xcrun --sdk iphoneos --show-sdk-path)"
mac_sdk_root="$(xcrun --sdk macosx --show-sdk-path)"
support_root="$project_root/build/support"
host_jdk="$(find "$project_root/build/host-jdk" -type d -path '*/Contents/Home' -print -quit)"
test -x "$host_jdk/bin/jmod" && test -x "$host_jdk/bin/jlink"
"$host_jdk/bin/java" -version
cd build/mobile
bash configure --with-conf-name=ios-aarch64-zero-release --disable-warnings-as-errors \
  --openjdk-target=aarch64-macos-ios --with-jvm-variants=zero \
  --with-build-jdk="$host_jdk" \
  --with-sysroot="$sdk_root" --with-libffi-include="$support_root/include/ffi" \
  --with-libffi-lib="$support_root" --with-cups-include="$mac_sdk_root/usr/include"
# iOS static libraries avoid the unsupported ELF shared-library image target.
gmake CONF=ios-aarch64-zero-release \
  hotspot-zero-static-libs java.base-static-libs \
  java.management-static-libs jdk.management-static-libs \
  java.base-gendata java.base-copy \
  java.logging-java java.management-java java.naming-java java.security.sasl-java \
  java.sql-java java.transaction.xa-java java.xml-java jdk.management-java jdk.unsupported-java
cd "$project_root"
device_root="$project_root/build/mobile/build/ios-aarch64-zero-release"
export DEVICE_ROOT="$device_root" HOST_JDK="$host_jdk"
python3 - <<'PY'
import json,os,pathlib,shutil,subprocess
device=pathlib.Path(os.environ['DEVICE_ROOT'])
host=pathlib.Path(os.environ['HOST_JDK'])
modules=['java.base','java.logging','java.management','java.naming','java.security.sasl',
         'java.sql','java.transaction.xa','java.xml','jdk.management','jdk.unsupported']
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
required={'java.base','java.logging','java.management','java.naming','java.sql','java.xml','jdk.management','jdk.unsupported'}
missing=sorted(required-modules)
pathlib.Path('build/module-check.json').write_text(json.dumps({'missing':missing,'modules':sorted(modules)},indent=2))
if missing: raise SystemExit('iOS runtime is missing required modules: '+','.join(missing))
for filename in ['conf/security/java.security','lib/tzdb.dat','lib/modules']:
    if not (image/filename).is_file(): raise SystemExit('Missing runtime data: '+filename)
for filename in ['LICENSE','ASSEMBLY_EXCEPTION']:
    shutil.copy2(pathlib.Path('build/mobile')/filename,image/filename)
(image/'SOURCE.txt').write_text('OpenJDK Mobile source: https://github.com/openjdk/mobile/tree/c13417aa36f8f44755d0984b58aa735d0b41f233\n')
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
cp build/mobile/build/ios-aarch64-zero-release/jdk/include/*.h build/include/
cp build/mobile/build/ios-aarch64-zero-release/jdk/include/ios/*.h build/include/
if [[ -e build/OpenJDK.xcframework ]]; then
  echo 'Framework already exists; use a clean checkout to rebuild.' >&2; exit 3
fi
xcodebuild -create-xcframework -library "$project_root/build/libOpenJDK.a" -headers "$project_root/build/include" -output "$project_root/build/OpenJDK.xcframework"
mkdir -p build/java
javac --release 21 -encoding UTF-8 -d build/java Java/DeviceProbe.java
jar --create --file build/DeviceProbe.jar -C build/java .
xcodegen generate --spec project.yml
xcodebuild -project RuntimeProbe.xcodeproj -scheme RuntimeProbe -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
mkdir -p build/Payload
cp -R build/DerivedData/Build/Products/Release-iphoneos/RuntimeProbe.app build/Payload/
(cd build && zip -qr RuntimeProbe.ipa Payload)
echo 'Unsigned experimental IPA created. Real iPhone execution is not yet verified.'
