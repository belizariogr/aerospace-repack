#!/usr/bin/env bash
# Builds the release with ./build-release.sh, then re-signs it with a Developer ID Application certificate
# (hardened runtime + secure timestamp), notarizes it with Apple and staples the ticket to the app.
# The result can be installed on another Mac without removing the quarantine attribute.
#
# Usage:
#   ./script/build-signed-release.sh --build-version 0.21.4-Repack.1 \
#       --codesign-identity "Developer ID Application: Name (TEAMID)"
#
# Notarization credentials, one of:
#   AEROSPACE_NOTARY_PROFILE  keychain profile created with `xcrun notarytool store-credentials`
#   AEROSPACE_NOTARY_APPLE_ID + AEROSPACE_NOTARY_PASSWORD (app-specific password) + AEROSPACE_NOTARY_TEAM_ID
cd "$(dirname "$0")/.."
source ./script/setup.sh

build_version=''
codesign_identity="${AEROSPACE_CODESIGN_IDENTITY:-}"
while test $# -gt 0; do
    case $1 in
        --build-version) build_version="$2"; shift 2;;
        --codesign-identity) codesign_identity="$2"; shift 2;;
        *) echo "Unknown option $1" > /dev/stderr; exit 1;;
    esac
done

if test -z "$build_version"; then echo "--build-version is mandatory" > /dev/stderr; exit 1; fi
if test -z "$codesign_identity"; then echo "--codesign-identity is mandatory" > /dev/stderr; exit 1; fi
if ! grep -q '^Developer ID Application: ' <<< "$codesign_identity"; then
    echo "Notarization requires a 'Developer ID Application: ...' identity" > /dev/stderr
    exit 1
fi

if test -n "${AEROSPACE_NOTARY_PROFILE:-}"; then
    notary_args=(--keychain-profile "$AEROSPACE_NOTARY_PROFILE")
elif test -n "${AEROSPACE_NOTARY_APPLE_ID:-}" && test -n "${AEROSPACE_NOTARY_PASSWORD:-}" && test -n "${AEROSPACE_NOTARY_TEAM_ID:-}"; then
    notary_args=(--apple-id "$AEROSPACE_NOTARY_APPLE_ID" --password "$AEROSPACE_NOTARY_PASSWORD" --team-id "$AEROSPACE_NOTARY_TEAM_ID")
else
    echo "Set AEROSPACE_NOTARY_PROFILE, or AEROSPACE_NOTARY_APPLE_ID, AEROSPACE_NOTARY_PASSWORD and AEROSPACE_NOTARY_TEAM_ID" > /dev/stderr
    exit 1
fi

# Fail before the long build if the credentials don't work
/usr/bin/xcrun notarytool history "${notary_args[@]}" > /dev/null

./build-release.sh --build-version "$build_version" --codesign-identity "$codesign_identity"

dist_name="AeroSpace-v$build_version"
dist=".release/$dist_name"
app="$dist/AeroSpace.app"
cli="$dist/bin/aerospace"

sign() {
    /usr/bin/codesign --force --timestamp --options runtime --sign "$codesign_identity" "$@"
}

# Inside out: nested code first, then the bundle
sign "$app/Contents/Frameworks/libswiftCompatibilitySpan.dylib"
sign --entitlements ./resources/AeroSpace.entitlements "$app"
sign "$cli"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"
/usr/bin/codesign --verify --strict --verbose=2 "$cli"

zip_path="$PWD/.release/$dist_name.zip"
rm -f "$zip_path"
(cd .release && /usr/bin/ditto -c -k --keepParent "$dist_name" "$zip_path")

/usr/bin/xcrun notarytool submit "$zip_path" "${notary_args[@]}" --wait --timeout 30m --output-format json \
    > ".release/notary-result.json"
cat ".release/notary-result.json"
if ! grep -q '"status" *: *"Accepted"' ".release/notary-result.json"; then
    submission_id=$(plutil -extract id raw ".release/notary-result.json" 2> /dev/null || true)
    if test -n "$submission_id"; then
        /usr/bin/xcrun notarytool log "$submission_id" "${notary_args[@]}" ".release/notary-log.json" || true
    fi
    echo "Notarization was not accepted. See .release/notary-log.json" > /dev/stderr
    exit 1
fi

# Bare Mach-O binaries can't hold a stapled ticket; Gatekeeper fetches the CLI's ticket online
/usr/bin/xcrun stapler staple "$app"
/usr/bin/xcrun stapler validate "$app"
/usr/sbin/spctl --assess --type execute --verbose=4 "$app"

# Re-pack so the zip contains the stapled app
rm -f "$zip_path"
(cd .release && /usr/bin/ditto -c -k --keepParent "$dist_name" "$zip_path")

echo
echo "$zip_path"
