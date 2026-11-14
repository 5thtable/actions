set -euo pipefail
umask 077
export LC_ALL=C
signing_scripts="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

: "${ANDROID_UPLOAD_KEYSTORE_BASE64:?Configure the Android upload keystore}"
: "${ANDROID_UPLOAD_PASSWORD:?Configure the Android upload keystore password}"
: "${ANDROID_UPLOAD_ALIAS:?Set the Android upload key alias}"
MOBILE_BUILD_NUMBER="${MOBILE_BUILD_NUMBER:-$(cat "$MOBILE_BUILD_INPUT/build-number.txt")}"
if [[ -f "$MOBILE_BUILD_INPUT/source-commit.txt" ]]; then
  MOBILE_SOURCE_SHA="$(cat "$MOBILE_BUILD_INPUT/source-commit.txt")"
fi
MOBILE_SOURCE_SHA="${MOBILE_SOURCE_SHA:-$GITHUB_SHA}"
[[ "$MOBILE_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]
[[ "$MOBILE_SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]]
signing_dir="$(mktemp -d "$RUNNER_TEMP/android-signing.XXXXXX")"
trap 'rm -f "$signing_dir/upload.p12" "$signing_dir/unsigned.aab"; rmdir "$signing_dir"' EXIT
keystore="$signing_dir/upload.p12"
printf '%s' "$ANDROID_UPLOAD_KEYSTORE_BASE64" | base64 --decode > "$keystore"
unset ANDROID_UPLOAD_KEYSTORE_BASE64

mkdir -p "$MOBILE_BUILD_OUTPUT"
bundle="$MOBILE_BUILD_OUTPUT/Player.aab"
python3 "$signing_scripts/strip-android-signature.py" "$MOBILE_BUILD_INPUT/Player.aab" "$signing_dir/unsigned.aab"
jarsigner -keystore "$keystore" -storetype PKCS12 -storepass:env ANDROID_UPLOAD_PASSWORD \
  -signedjar "$bundle" "$signing_dir/unsigned.aab" "$ANDROID_UPLOAD_ALIAS"
jarsigner -verify -strict -keystore "$keystore" -storetype PKCS12 \
  -storepass:env ANDROID_UPLOAD_PASSWORD "$bundle" "$ANDROID_UPLOAD_ALIAS" \
  > "$RUNNER_TEMP/android-bundle-signing.log" 2>&1
grep '^jar verified\.$' "$RUNNER_TEMP/android-bundle-signing.log"

bundletool="$RUNNER_TEMP/bundletool.jar"
curl --fail --silent --show-error --location --retry 3 \
  https://github.com/google/bundletool/releases/download/1.18.3/bundletool-all-1.18.3.jar \
  --output "$bundletool"
printf '%s  %s\n' a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29 "$bundletool" | sha256sum --check
java -jar "$bundletool" validate --bundle="$bundle" > "$RUNNER_TEMP/android-bundle-validation.log"
java -jar "$bundletool" dump manifest --bundle="$bundle" > "$MOBILE_BUILD_OUTPUT/android-manifest.xml"
java -jar "$bundletool" dump config --bundle="$bundle" | grep 'PAGE_ALIGNMENT_16K'
version="$(python3 "$signing_scripts/verify-android.py" "$bundle" "$MOBILE_BUILD_OUTPUT/android-manifest.xml" "$MOBILE_APPLICATION_ID" "$MOBILE_BUILD_NUMBER")"
(
  cd "$MOBILE_BUILD_OUTPUT"
  sha256sum Player.aab > SHA256SUMS
)
printf 'Commit %s\nBuild %s\nVersion %s\n' "$MOBILE_SOURCE_SHA" "$MOBILE_BUILD_NUMBER" "$version" > "$MOBILE_BUILD_OUTPUT/build-info.txt"
printf 'app-version=%s\nbuild-number=%s\n' "$version" "$MOBILE_BUILD_NUMBER" >> "$GITHUB_OUTPUT"
