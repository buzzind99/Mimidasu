# dmgbuild settings for Mimidasu release DMGs.
#
# Driven by scripts/dmg/style_dmg.sh via -D defines (no templating step):
#   app  absolute path to the staged Mimidasu.app
#   bg   absolute path to the DMG background image
#
# Written for dmgbuild 1.6.x (pip install dmgbuild — needs Python 3.10+).
# Layout mirrors the old create-dmg geometry: 600x400 window, 128pt icons at
# (170, 160) / (430, 160). Note window_rect's y runs bottom-to-top while
# create-dmg's --window-pos used a top-left origin — tune from the preview
# (scripts/dmg/style_dmg.sh) if the window lands oddly.

format = 'ULMO'
filesystem = 'HFS+'

files = [defines['app']]
symlinks = {'Applications': '/Applications'}

background = defines['bg']

icon_locations = {
    'Mimidasu.app': (170, 160),
    'Applications': (430, 160),
}

window_rect = ((200, 480), (600, 400))
default_view = 'icon-view'
icon_size = 128
text_size = 14

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
