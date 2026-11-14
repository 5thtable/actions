set -euo pipefail
umask 077
export LC_ALL=C
signing_scripts="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

: "${IOS_CERTIFICATE_BASE64:?Configure the Apple distribution certificate}"
: "${IOS_CERTIFICATE_PASSWORD:?Configure the Apple distribution certificate password}"
: "${IOS_PROVISIONING_PROFILE_BASE64:?Configure the App Store provisioning profile}"
MOBILE_BUILD_NUMBER="${MOBILE_BUILD_NUMBER:-$(cat "$MOBILE_BUILD_INPUT/build-number.txt")}"
if [[ -f "$MOBILE_BUILD_INPUT/source-commit.txt" ]]; then
  MOBILE_SOURCE_SHA="$(cat "$MOBILE_BUILD_INPUT/source-commit.txt")"
fi
MOBILE_SOURCE_SHA="${MOBILE_SOURCE_SHA:-$GITHUB_SHA}"
[[ "$MOBILE_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]
[[ "$MOBILE_SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]]
signing_dir="$(mktemp -d "$RUNNER_TEMP/ios-signing.XXXXXX")"
keychain="$signing_dir/signing.keychain-db"
installed_profile=
original_keychains=()
while IFS= read -r path; do
  path="${path#*\"}"
  original_keychains+=("${path%\"}")
done < <(security list-keychains -d user)

cleanup() {
  if [[ -f "$keychain" ]]; then
    security list-keychains -d user -s "${original_keychains[@]}" || true
    security delete-keychain "$keychain" 2>/dev/null || true
  fi
  if [[ -n "$installed_profile" ]]; then
    rm -f "$installed_profile"
  fi
  rm -f "$signing_dir/certificate.p12" "$signing_dir/profile.mobileprovision" "$signing_dir/profile.plist" "$signing_dir/export.plist"
  rmdir "$signing_dir"
}
trap cleanup EXIT

printf '%s' "$IOS_CERTIFICATE_BASE64" | base64 -D > "$signing_dir/certificate.p12"
printf '%s' "$IOS_PROVISIONING_PROFILE_BASE64" | base64 -D > "$signing_dir/profile.mobileprovision"
security cms -D -i "$signing_dir/profile.mobileprovision" > "$signing_dir/profile.plist"
unset IOS_CERTIFICATE_BASE64 IOS_PROVISIONING_PROFILE_BASE64

keychain_password="$(openssl rand -hex 24)"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$signing_dir/certificate.p12" -k "$keychain" -P "$IOS_CERTIFICATE_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain" "${original_keychains[@]}"
unset IOS_CERTIFICATE_PASSWORD
identities="$(security find-identity -v -p codesigning "$keychain" | awk '/"Apple Distribution:/ {print $2}')"
profile="$(python3 "$signing_scripts/verify-ios-profile.py" "$signing_dir/profile.plist" "$MOBILE_APPLICATION_ID" "$identities")"
read -r team_id profile_uuid <<< "$profile"

profiles="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
mkdir -p "$profiles"
profile_path="$profiles/$profile_uuid.mobileprovision"
if [[ ! -e "$profile_path" ]]; then
  cp "$signing_dir/profile.mobileprovision" "$profile_path"
  installed_profile="$profile_path"
elif ! cmp -s "$signing_dir/profile.mobileprovision" "$profile_path"; then
  echo "The iOS provisioning profile conflicts with a profile on the runner." >&2
  exit 1
fi

tar -xzf "$MOBILE_BUILD_INPUT/Xcode.tar.gz" -C "$RUNNER_TEMP"
project="$RUNNER_TEMP/Xcode/Unity-iPhone.xcodeproj"
ruby "$signing_scripts/configure-xcode-signing.rb" "$project" "$MOBILE_APPLICATION_ID" "$team_id" "$profile_uuid"

archive="$RUNNER_TEMP/Player.xcarchive"
xcodebuild -version
xcodebuild archive -project "$project" \
  -scheme Unity-iPhone -configuration Release -destination 'generic/platform=iOS' -archivePath "$archive" \
  > "$RUNNER_TEMP/ios-archive.log" 2>&1

plist=/usr/libexec/PlistBuddy
export_options="$signing_dir/export.plist"
plutil -create xml1 "$export_options"
plutil -insert method -string app-store-connect "$export_options"
plutil -insert signingStyle -string manual "$export_options"
plutil -insert signingCertificate -string "Apple Distribution" "$export_options"
plutil -insert teamID -string "$team_id" "$export_options"
plutil -insert manageAppVersionAndBuildNumber -bool NO "$export_options"
"$plist" -c 'Add :provisioningProfiles dict' "$export_options"
"$plist" -c "Add :provisioningProfiles:$MOBILE_APPLICATION_ID string $profile_uuid" "$export_options"

xcodebuild -exportArchive -archivePath "$archive" \
  -exportPath "$RUNNER_TEMP/ios-export" -exportOptionsPlist "$export_options" \
  > "$RUNNER_TEMP/ios-export.log" 2>&1

ipas=("$RUNNER_TEMP/ios-export"/*.ipa)
if [[ "${#ipas[@]}" != 1 || ! -f "${ipas[0]}" ]]; then
  echo "Xcode must export exactly one IPA." >&2
  exit 1
fi
mkdir -p "$MOBILE_BUILD_OUTPUT"
mv "${ipas[0]}" "$MOBILE_BUILD_OUTPUT/Player.ipa"
unzip -q "$MOBILE_BUILD_OUTPUT/Player.ipa" -d "$RUNNER_TEMP/ios-payload"
apps=("$RUNNER_TEMP/ios-payload/Payload"/*.app)
if [[ "${#apps[@]}" != 1 || ! -d "${apps[0]}" ]]; then
  echo "The IPA must contain exactly one application." >&2
  exit 1
fi
codesign --verify --deep --strict "${apps[0]}"
info="${apps[0]}/Info.plist"
bundle_id="$("$plist" -c 'Print CFBundleIdentifier' "$info")"
build_number="$("$plist" -c 'Print CFBundleVersion' "$info")"
version="$("$plist" -c 'Print CFBundleShortVersionString' "$info")"
if [[ "$bundle_id" != "$MOBILE_APPLICATION_ID" || "$build_number" != "$MOBILE_BUILD_NUMBER" || ! "$version" =~ ^[0-9]+\.[0-9]+\.$build_number$ ]]; then
  echo "The IPA has an unexpected bundle ID or build version." >&2
  exit 1
fi

(
  cd "$MOBILE_BUILD_OUTPUT"
  shasum -a 256 Player.ipa > SHA256SUMS
  if [[ -d "$archive/dSYMs" ]]; then
    ditto -c -k --keepParent "$archive/dSYMs" Player-dSYMs.zip
    shasum -a 256 Player-dSYMs.zip >> SHA256SUMS
  fi
)
printf 'Commit %s\nBuild %s\nVersion %s\n' "$MOBILE_SOURCE_SHA" "$build_number" "$version" > "$MOBILE_BUILD_OUTPUT/build-info.txt"
printf 'app-version=%s\nbuild-number=%s\n' "$version" "$build_number" >> "$GITHUB_OUTPUT"
