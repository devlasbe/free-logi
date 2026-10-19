#!/bin/bash
# 버전 올림 → universal DMG 빌드 → (확인) → 커밋·태그·push → GitHub 릴리즈 업로드
# 사용: scripts/release.sh [patch|minor|major|X.Y.Z]  (기본 patch)
set -euo pipefail
cd "$(dirname "$0")/.."

PLIST="Resources/Info.plist"
plist() { /usr/libexec/PlistBuddy -c "$1" "$PLIST"; }

[[ -z "$(git status --porcelain)" ]] || { echo "커밋 안 한 변경이 있다" >&2; exit 1; }
[[ "$(git branch --show-current)" == main ]] || { echo "main 브랜치에서만 릴리즈한다" >&2; exit 1; }

IFS=. read -r MAJOR MINOR PATCH <<< "$(plist 'Print CFBundleShortVersionString')"
case "${1:-patch}" in
  patch) VERSION="$MAJOR.$MINOR.$((PATCH + 1))" ;;
  minor) VERSION="$MAJOR.$((MINOR + 1)).0" ;;
  major) VERSION="$((MAJOR + 1)).0.0" ;;
  *) VERSION="$1" ;;
esac
BUILD=$(( $(plist 'Print CFBundleVersion') + 1 ))
TAG="v$VERSION"
! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || { echo "태그 $TAG가 이미 있다" >&2; exit 1; }

source scripts/sign-identity.sh
if [[ "$SIGN_IDENTITY" != 'Developer ID Application'* ]]; then
  echo "Developer ID Application 인증서가 필요하다 (현재: $SIGN_IDENTITY)" >&2
  echo "설정: Xcode에서 Developer ID Application 인증서를 설치하거나 SIGN_IDENTITY를 지정한다" >&2
  exit 1
fi
NOTARY_PROFILE="${NOTARY_PROFILE:-freelogi}"
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "공증 프로파일 '$NOTARY_PROFILE'을 사용할 수 없다" >&2
  echo "설정: xcrun notarytool store-credentials freelogi --apple-id … --team-id …" >&2
  exit 1
fi

# 빌드가 먼저다: 실패하면 저장소는 그대로
APP_VERSION="$VERSION" APP_BUILD="$BUILD" NOTARY_PROFILE="$NOTARY_PROFILE" scripts/make-dmg.sh --arch arm64 --arch x86_64

read -r -p "$TAG ($BUILD) 커밋·push하고 릴리즈를 올릴까? [y/N] " ANSWER
[[ "$ANSWER" == y ]] || { echo "취소: 저장소는 바뀌지 않았다 (build/FreeLogi.dmg만 남음)"; exit 0; }

plist "Set CFBundleShortVersionString $VERSION"
plist "Set CFBundleVersion $BUILD"
git commit -q -m "chore: $TAG" -- "$PLIST"
git tag "$TAG"
git push origin main "$TAG"
gh release create "$TAG" build/FreeLogi.dmg --title "FreeLogi $VERSION" --generate-notes
