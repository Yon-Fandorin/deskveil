from pathlib import Path
from unicodedata import normalize

application = Path(defines["app"]).resolve()
format = "UDZO"
filesystem = "HFS+"
files = [str(application)]
applications_link = normalize("NFD", "응용 프로그램")
symlinks = {applications_link: "/Applications"}
# SetFile's hidden-extension flag adds FinderInfo to the signed app and breaks
# strict validation. Keep window layout metadata on the volume instead.
hide_extensions = []
icon = str(application / "Contents/Resources/SoftLock.icns")
background = defines["background"]
window_rect = ((180, 180), (680, 452))
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
include_icon_view_settings = True
include_list_view_settings = False
arrange_by = None
grid_spacing = 96
scroll_position = (0, 0)
label_pos = "bottom"
text_size = 13
icon_size = 104
icon_locations = {application.name: (176, 202), applications_link: (504, 202)}
