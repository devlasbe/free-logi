# 서명 인증서: Developer ID → Apple Development → ad-hoc
if [[ -z "${SIGN_IDENTITY+x}" ]]; then
  SIGN_IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || true)
  SIGN_IDENTITY=$(awk -F'"' '/Developer ID Application/{print $2; exit}' <<< "$SIGN_IDENTITIES")
  if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY=$(awk -F'"' '/Apple Development/{print $2; exit}' <<< "$SIGN_IDENTITIES")
  fi
  SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi
