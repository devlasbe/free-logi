"""FreeLogi 설치 창 설정. 레포 루트에서 make-dmg.sh로 실행한다."""

from pathlib import Path

ROOT = Path.cwd()

format = "UDZO"
files = [str(ROOT / "build/FreeLogi.app")]
symlinks = {"Applications": "/Applications"}
background = str(ROOT / "build/dmg-background.tiff")
hide_extensions = ["FreeLogi.app"]

# 배경 생성 스크립트와 같은 640×400pt 좌표계. 아이콘 사이가 화살표 자리다.
window_rect = ((200, 200), (640, 400))
icon_locations = {"FreeLogi.app": (180, 210), "Applications": (460, 210)}
icon_size = 96
text_size = 13
label_pos = "bottom"
arrange_by = None
grid_spacing = 80
scroll_position = (0, 0)
default_view = "icon-view"
include_icon_view_settings = True
include_list_view_settings = False
show_icon_preview = False
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
