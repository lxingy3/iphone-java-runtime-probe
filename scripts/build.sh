#!/usr/bin/env bash
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'This native device build requires macOS and the Apple iPhoneOS SDK.' >&2
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
import hashlib,pathlib,urllib.request,zipfile
p=pathlib.Path('build/libffi-ios.zip')
if not p.exists():
    p.write_bytes(urllib.request.urlopen('https://github.com/openjdk-mobile/ios-tools/releases/download/libffi-build/libffi-ios.zip').read())
assert hashlib.sha256(p.read_bytes()).hexdigest()=='4f39fd1d53fbd69d1bdbd915413077d130daa3f6792d1b3a03a690a9cbd4dea3'
with zipfile.ZipFile(p) as z:
    for name in z.namelist():
        if name.startswith('/') or '..' in pathlib.PurePosixPath(name).parts: raise ValueError('Invalid archive path')
    z.extractall('build/support')
PY
sdk_root="$(xcrun --sdk iphoneos --show-sdk-path)"
mac_sdk_root="$(xcrun --sdk macosx --show-sdk-path)"
support_root="$project_root/build/support"
cd build/mobile
bash configure --with-conf-name=ios-aarch64-zero-release --disable-warnings-as-errors \
  --openjdk-target=aarch64-macos-ios --with-jvm-variants=zero \
  --with-sysroot="$sdk_root" --with-libffi-include="$support_root/include/ffi" \
  --with-libffi-lib="$support_root" --with-cups-include="$mac_sdk_root/usr/include"
# Unlike the upstream HelloWorld workflow, retain the complete module image.
gmake CONF=ios-aarch64-zero-release images static-libs-image
cd "$project_root"
image_root="$project_root/build/mobile/build/ios-aarch64-zero-release/images"
export IMAGE_ROOT="$image_root"
python3 - <<'PY'
import json,os,pathlib,shutil
image=pathlib.Path(os.environ['IMAGE_ROOT'])/'jdk'
release=(image/'release').read_text()
module_line=next(x for x in release.splitlines() if x.startswith('MODULES='))
modules=set(module_line.split('=',1)[1].strip('"').split())
required={'java.base','java.logging','java.management','java.naming','java.sql','java.xml','jdk.management','jdk.unsupported'}
missing=sorted(required-modules)
pathlib.Path('build/module-check.json').write_text(json.dumps({'missing':missing,'modules':sorted(modules)},indent=2))
if missing: raise SystemExit('iOS runtime is missing required modules: '+','.join(missing))
target=pathlib.Path('build/runtime/lib');target.mkdir(parents=True,exist_ok=True)
shutil.copy2(image/'lib/modules',target/'modules')
shutil.copy2(image/'release','build/runtime/release')
if (image/'conf').exists(): shutil.copytree(image/'conf','build/runtime/conf',dirs_exist_ok=True)
if (image/'legal').exists(): shutil.copytree(image/'legal','build/runtime/legal',dirs_exist_ok=True)
PY
lib_root="$image_root/static-libs/lib"
libraries=( "$lib_root/zero/libjvm.a" "$support_root/libffi.a" )
for library in java zip net nio jimage management management_ext; do
  test -f "$lib_root/lib$library.a" || { echo "Missing native iOS library: $library"; exit 3; }
  libraries+=( "$lib_root/lib$library.a" )
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
