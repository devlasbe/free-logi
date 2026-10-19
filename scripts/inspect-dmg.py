"""마운트한 DMG의 내용과 Finder 배치를 출력한다. 인자: 볼륨 경로."""

import sys
from pathlib import Path

from ds_store import DSStore

volume = Path(sys.argv[1])
for name in ("FreeLogi.app", "Applications", ".background.tiff", ".DS_Store"):
    path = volume / name
    if not path.exists():
        raise SystemExit(f"누락: {path}")
    print(f"파일: {name}")

applications = volume / "Applications"
if not applications.is_symlink() or applications.readlink() != Path("/Applications"):
    raise SystemExit("Applications가 /Applications 심볼릭 링크가 아닙니다")

# ds_store가 bwsp·icvp·Iloc를 사전·좌표로 해석한다.
with DSStore.open(str(volume / ".DS_Store"), "r") as store:
    print("창:", store["."]["bwsp"])
    print("아이콘 보기·배경:", store["."]["icvp"])
    print("기본 보기:", store["."]["icvl"])
    for name in ("FreeLogi.app", "Applications"):
        print(f"위치 {name}:", store[name]["Iloc"])
