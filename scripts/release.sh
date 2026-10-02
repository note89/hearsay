#!/usr/bin/env bash
# Build, Developer ID sign, notarize and staple hearsay-VERSION.zip.
# --publish stages a draft before the tag, waits for platform builds, then releases.
# Signing credentials stay in this Mac's keychain (profile: devid-notary).
set -euo pipefail

VERSION="${1:-}"
PUBLISH="${2:-}"
[[ $# -le 2 && $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "usage: $0 VERSION [--publish]" >&2
    exit 2
}
[[ -z $PUBLISH || $PUBLISH == --publish ]] || { echo "release: unknown option: $PUBLISH" >&2; exit 2; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
REPOSITORY="note89/hearsay"
TEAM_ID="43BT9GR95A"
IDENTITY="${HEARSAY_SIGN_IDENTITY:-Developer ID Application: Nils Olof Tson Eriksson ($TEAM_ID)}"
NOTARY_PROFILE="${HEARSAY_NOTARY_PROFILE:-devid-notary}"
APP="$ROOT/build/hearsay.app"
ZIP="$ROOT/build/hearsay-$VERSION.zip"
CHECKSUM="$ZIP.sha256"
SUBMISSION="$ROOT/build/hearsay-$VERSION-notarize.zip"
NOTARY_RESULT="$ROOT/build/hearsay-$VERSION-notary.json"
TAG="v$VERSION"
REVISION="$(git rev-parse HEAD)"

step() { printf '\n==> %s\n' "$*"; }
die() { echo "release: $*" >&2; exit 1; }
[[ $(uname -s) == Darwin ]] || die "a Mac with the Developer ID private key is required"
SOURCE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
[[ $SOURCE_VERSION == "$VERSION" ]] || die "source Info.plist is $SOURCE_VERSION; update and commit it before releasing $VERSION"
VALID_IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
[[ $VALID_IDENTITIES == *"\"$IDENTITY\""* ]] || die "no valid signing identity '$IDENTITY' in the keychain"

if [[ $PUBLISH == --publish ]]; then
    [[ -z $(git status --porcelain) ]] || die "working tree is not clean; commit first so the tag matches the build"
    ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || die "tag $TAG already exists locally"
    REMOTE_TAG="$(git ls-remote --tags origin "refs/tags/$TAG")"
    [[ -z $REMOTE_TAG ]] || die "tag $TAG already exists on origin"
    command -v gh >/dev/null || die "gh is not installed"
    gh auth status >/dev/null 2>&1 || die "gh is not authenticated"
fi

step "Building Apple Silicon app"
HEARSAY_SIGN_IDENTITY="$IDENTITY" scripts/bundle.sh release
step "Signing with secure timestamp"
codesign --force --options runtime --timestamp \
    --entitlements Resources/hearsay.entitlements --sign "$IDENTITY" "$APP"
scripts/verify-release.sh "$APP"

step "Notarizing"
trap 'rm -f "$SUBMISSION"' EXIT
ditto -c -k --keepParent "$APP" "$SUBMISSION"
if ! xcrun notarytool submit "$SUBMISSION" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$NOTARY_RESULT"; then
    die "notarytool submit failed; result: $NOTARY_RESULT"
fi
SUBMISSION_ID="$(plutil -extract id raw -o - "$NOTARY_RESULT" 2>/dev/null || true)"
STATUS="$(plutil -extract status raw -o - "$NOTARY_RESULT" 2>/dev/null || true)"
[[ -n $SUBMISSION_ID ]] || die "notarytool returned no submission ID; result: $NOTARY_RESULT"
echo "submission $SUBMISSION_ID: $STATUS"
if [[ $STATUS != Accepted ]]; then
    xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    die "notarization $STATUS"
fi
rm -f "$SUBMISSION"

step "Stapling and checking Gatekeeper"
xcrun stapler staple "$APP"
scripts/verify-release.sh "$APP" --notarized
step "Archiving"
rm -f "$ZIP" "$CHECKSUM"
ditto -c -k --keepParent "$APP" "$ZIP"
(
    cd "$ROOT/build"
    shasum -a 256 "hearsay-$VERSION.zip" > "hearsay-$VERSION.zip.sha256"
)
echo "$ZIP"
cat "$CHECKSUM"

if [[ $PUBLISH != --publish ]]; then
    echo "Built and verified. Publish from a clean committed tree with: $0 $VERSION --publish"
    exit 0
fi

# Do not publish bytes built while the checkout was changing.
[[ $(git rev-parse HEAD) == "$REVISION" && -z $(git status --porcelain) ]] || die "checkout changed during the build"
step "Staging draft release $TAG"
if EXISTING_DRAFT="$(gh release view "$TAG" --repo "$REPOSITORY" --json isDraft --jq .isDraft 2>/dev/null)"; then
    [[ $EXISTING_DRAFT == true ]] || die "$TAG is already published"
else
    NOTES=(--generate-notes)
    if [[ -f "docs/release-notes-v$VERSION.md" ]]; then
        NOTES=(--notes-file "docs/release-notes-v$VERSION.md")
    fi
    gh release create "$TAG" --repo "$REPOSITORY" --draft --target "$REVISION" \
        --title "hearsay $VERSION" "${NOTES[@]}"
fi
gh release upload "$TAG" "$ZIP" "$CHECKSUM" --repo "$REPOSITORY" --clobber
git tag -a "$TAG" -m "hearsay $VERSION" "$REVISION"
# Capture before the push so workflows created immediately during it are included.
TAG_PUSH_STARTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
git push origin "$TAG"

wait_for_workflow() {
    local workflow="$1" run_id=""
    for attempt in {1..12}; do
        run_id="$(gh run list --repo "$REPOSITORY" --workflow "$workflow" --branch "$TAG" \
            --event push --commit "$REVISION" --created ">=$TAG_PUSH_STARTED_AT" \
            --limit 1 --json databaseId --jq '.[0].databaseId // empty')"
        [[ -z $run_id ]] || break
        sleep 5
    done
    [[ -n $run_id ]] || die "$workflow did not start; the release remains a draft"
    gh run watch "$run_id" --repo "$REPOSITORY" --exit-status
}
step "Waiting for macOS release checks"
wait_for_workflow macos.yml
step "Waiting for Linux, Windows and NixOS release checks"
wait_for_workflow crossplatform.yml
step "Publishing $TAG"
gh release edit "$TAG" --repo "$REPOSITORY" --draft=false
