--[[
webdav-browser v10  -  two-panel (Folders | Files) WebDAV browser for mpv

What's new in v10
  Fixes
  - Windows on-screen-keyboard arrows (KP_UP/KP_DOWN/KP_LEFT/KP_RIGHT/KP_ENTER...) work in
    BOTH browse and search mode: every key alias now comes from ONE table
  - 'r' on the Folders panel refreshes the whole visible folder tree (root + expanded folders);
    'R' refreshes everything and re-indexes. Deleted folders are pruned instead of lingering
  - Watch history / watched markers / directory cache now actually persist (single-file scripts
    have no script directory: data now lives in <mpv config>/script-opts/)
  - Late replies from a slow folder can no longer overwrite the folder you opened afterwards
  - A failed refresh of one folder no longer blanks the healthy Files panel (errors are per folder)
  - Retry-on-failure also works when a file fails to OPEN; retry counters reset on success
  - Auto-play "next episode" follows natural filename order, not the on-screen sort
  - A few seconds of viewing no longer creates an "in progress" marker
  - '+' in file names is no longer turned into a space
  - Search box: any character can be typed (any_unicode fallback), words match across . _ - separators
  - Credentials: curl gets them on stdin (not on the command line) and the stream auth header is
    scoped to files on your server instead of being sent session-wide
  - HTTP status codes are checked; timeouts / 429 / 5xx are retried with back-off
  - Background blur is cheaper ("lite" mode) and is skipped for heavy / hardware-decoded video
  New
  - Sakura Night palette
  - Experimental clean titles with quality chips (experimental_clean_titles)
  - Persistent recursive search: background index of the whole library ('f')
  - Mouse: double-click to play, expand arrow hit-area, wheel scrolls the view, draggable scrollbar
  - "Resumed at 12:34" notice with a start-over key
  - Per-folder sort memory; live config reload (edit the .conf while the browser is open)
  - Debug overlay ('d'): cache age, last request time/status, index state
  - Continue Watching row at the top of the Folders panel, 'm' toggles watched, 'H' hides watched

Ctrl+W toggles. Config: script-opts/webdav-browser.conf
]]--

local mp      = require("mp")
local utils   = require("mp.utils")
local msg     = require("mp.msg")
local options = require("mp.options")

-- Namespaces (Lua 5.1 allows only 200 local variables per function, so pure helpers live in tables)
local U = {}   -- utilities: text / url / time / matching helpers
local D = {}   -- ASS drawing primitives

local SCRIPT_VERSION = "v10.9"

-- ============================================================
-- OPTIONS  (edit these via script-opts/webdav-browser.conf)
-- ============================================================
local o = {
    -- ===== Connection =====
    url = "",                    -- Base WebDAV URL, e.g. https://dav.example.com/remote.php/dav/files/user (no trailing slash)
    user = "",                   -- WebDAV username (leave blank for anonymous / public shares)
    pass = "",                   -- WebDAV password
    curl_path = "curl",          -- Path to the curl binary; change if curl isn't on your PATH
    request_timeout = 15,        -- Seconds to wait for a PROPFIND response before failing
    request_retries = 2,         -- Automatic retries for a folder listing that times out / gets HTTP 429 / 5xx
    request_retry_delay = 1.5,   -- Base back-off (seconds); attempt N waits N x this
    scoped_auth = true,          -- true = send the Authorization header ONLY for files on your server (file-local);
                                 -- false = old behaviour (one session-wide header sent to every URL mpv opens)

    -- ===== Appearance: text =====
    font_size = 20,              -- Base font size (px) used across the whole UI
    font_name = "Segoe UI",      -- Font family used for all browser text

    -- ===== Browsing behavior =====
    start_path = "/",                 -- WebDAV path the browser opens to (root of the tree)
    default_sort = "name",            -- "name" or "recent" - initial sort order (toggle in-UI with 's')
    autoplay_next = true,             -- Enables the one-ahead auto-buffering chain (see "Buffering / prefetch" below)
    prefetch = true,                  -- Enables mpv's own prefetch-playlist option (lets mpv actually cache an appended-but-not-yet-playing entry)
    embed_credentials_in_url = false, -- true = put user:pass directly in the stream URL instead of an Authorization header
    user_agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/126 Safari/537.36",
                                       -- User-Agent sent with stream requests (some servers reject the mpv default)
    max_retries = 2,                  -- How many times to retry a file if playback fails mid-stream
    retry_delay = 1.5,                -- Seconds to wait between retries
    auto_close_on_play = true,        -- Close the browser overlay automatically once playback starts
    show_watched_status = true,       -- Show watched / in-progress markers next to files

    -- ===== Directory cache =====
    cache_ttl = 600,              -- Seconds before a cached folder listing counts as stale. A stale listing is still shown
                                   -- instantly and silently refreshed in the background. 0 or less = never stale.
    revalidate_stale = true,      -- Re-fetch stale listings in the background when you open them
    persist_dir_cache = true,     -- Save the directory cache to disk so it survives mpv restarts

    -- ===== Focus / layout behavior =====
    auto_focus_files_on_open = true, -- Automatically switch focus+expand to the Files panel after opening a folder
    focused_width_pct = 70,          -- Width % given to whichever panel is currently focused (other panel gets the rest)
    indent_px = 16,                  -- Horizontal indent (px) per folder-tree depth level
    max_indent_levels = 6,           -- Cap indentation after this many nested levels (prevents runaway indent)

    -- ===== Background / opacity =====
    -- Lowered from the previous defaults so the blurred video shows through the
    -- panels (the "glass" look). Raise these back toward 90-100 if you prefer a
    -- more solid/opaque panel instead.
    dim_background_pct = 46,   -- How much to dim the video behind the whole browser overlay (0-100)
    panel_opacity  = 62,       -- Opacity of the folder/files panel backgrounds (0-100)
    header_opacity = 68,       -- Opacity of the top title bar background (0-100)
    footer_opacity = 68,       -- Opacity of the bottom hotkey/status bar background (0-100)

    -- ===== Background blur =====
    -- Blurs the actual video behind the overlay via mpv's video filter chain (not just the
    -- overlay shapes). Applied only while the browser is open, removed the instant it closes.
    -- Requires an mpv build with libavfilter support; silently disables itself if unsupported.
    background_blur_enabled = true,    -- Master switch (false = never blur)
    background_blur_mode = "auto",     -- "auto" | "lite" | "full" | "off"
                                       --   lite = shrink 4x, blur, let mpv scale back up (cheap, looks the same)
                                       --   full = blur at full resolution (heavy on 1440p/2160p)
                                       --   auto = lite, but skipped for heavy or hardware-decoded video (see below)
    background_blur_strength = 14,     -- Blur intensity (gaussian sigma, roughly 1-20). Higher = blurrier.
    background_blur_max_height = 1440, -- auto mode: no blur when the video is taller than this (px)
    background_blur_force = false,     -- auto mode: blur even when hardware decoding without -copy is active
                                       --   (a software filter can force mpv back to software decoding)

    -- ===== Rounded corners (px; set to 0 for sharp/square corners) =====
    corner_radius       = 12,  -- Corner radius of the two main panels (sidebar & file list)
    corner_radius_row   = 6,   -- Corner radius of the selected/hovered row highlight
    corner_radius_small = 3,   -- Corner radius of small elements: scrollbar, progress bar, sort pill, search pill

    -- ===== Border widths (px) =====
    border_width_focus   = 2,  -- Border thickness of whichever panel currently has focus
    border_width_unfocus = 1,  -- Border thickness of the unfocused panel

    -- ===== Glass border & highlight (LiquidGlass-style) =====
    -- ASS/libass can't draw a true gradient stroke on one shape, so the gradient
    -- border is faked by stacking 3 horizontal bands (light / dark / light) of the
    -- SAME outline, each clipped to its band - same visual idea as a vertical
    -- LinearGradientBrush with 3 GradientStops. Applied to BOTH panels now (focus
    -- is shown via brightness/fill instead of a blue accent border).
    border_gradient_enabled = true,    -- Enable the LiquidGlass-style gradient border
    border_alpha            = 42,      -- Base opacity (0-100) of the gradient border strokes (focused panel gets a bit more)
    color_border_grad_top    = "FF9CC2", -- Gradient border color at the very top    (Sakura pink)
    color_border_grad_mid    = "2B2140", -- Gradient border color in the middle      (deep violet)
    color_border_grad_bottom = "B79CFF", -- Gradient border color at the very bottom (lavender)
    glass_highlight_enabled  = true,   -- Thin bright line just inside the top edge of each panel (simulated light-on-glass)
    glass_highlight_opacity  = 14,     -- Opacity (0-100) of that highlight line - keep low, it's meant to be subtle

    -- ===== Colors (hex, no '#') - "Sakura Night" =====
    -- NOTE: if your webdav-browser.conf still lists old color_* lines they override these defaults.
    color_bg_dim         = "08050F",  -- Full-screen dimming overlay color (behind everything)
    color_bg_header      = "100C18",  -- Top title bar & bottom status bar background
    color_bg_panel       = "221A2F",  -- Focused panel background
    color_bg_panel_dim   = "1A1425",  -- Unfocused panel background
    color_accent         = "FF8FB8",  -- Primary accent color: selection highlight, active labels, search box
    color_border_focus   = "",        -- Unused (kept for backwards-compat with old config files)
    color_border_unfocus = "3A2D4F",  -- Fallback flat border color, only used if border_gradient_enabled = false
    color_text_primary   = "FAF5FF",  -- Main text color (focused panel, unselected rows)
    color_text_muted     = "B2A8C6",  -- Secondary text color (unfocused panel text, sizes, breadcrumbs)
    color_text_dim       = "867C9A",  -- Dimmed text for empty-state messages
    color_good           = "7FE3B0",  -- "Connected" status dot + fully-watched marker
    color_bad            = "FF6B8B",  -- "Error" status dot + error messages
    color_warn           = "FFB86B",  -- In-progress (partially watched) marker color + confirmed search chip
    color_folder         = "FFD6A5",  -- Folder icon/name color
    color_video          = "8EC5FF",  -- Video file icon color
    color_audio          = "C9A7FF",  -- Audio file icon color
    color_file           = "A59BB8",  -- Generic (non-media) file icon color
    color_cached_folder  = "9C92B0",  -- Name color for folders already cached (instant reopen, no network fetch)
    color_track          = "3B2F52",  -- Scrollbar track + progress-bar track

    -- ===== Icons =====
    -- icon_style picks a built-in icon set: "emoji" | "minimal" | "ascii"
    -- Any icon_* field below that is NOT empty overrides that single icon regardless of icon_style.
    icon_style = "emoji",
    icon_folder_closed = "",   -- Collapsed folder icon
    icon_folder_open   = "",   -- Expanded folder icon
    icon_folder_empty  = "",   -- Folder icon shown once loaded and confirmed to have no subfolders
    icon_file  = "",           -- Generic file icon (non-audio/video)
    icon_video = "",           -- Video file icon
    icon_audio = "",           -- Audio file icon
    icon_watched  = "",        -- Marker shown next to fully-watched files
    icon_watching = "",        -- Marker shown next to partially-watched (in-progress) files
    icon_search = "",          -- Icon shown in the search box
    icon_active_marker = "",   -- Small marker shown next to whichever folder's files are on-screen

    -- ===== Search =====
    search_font_boost = 4,     -- Extra font size (px) added ONLY while actively typing a query, so it's unmistakable

    -- ===== Persistent library index (recursive search, key 'f') =====
    index_enabled = true,          -- Let 'f' search the folders you have opened (and remember them between sessions)
    index_mode = "visited",        -- "visited" = only folders you actually open | "full" = also crawl the whole library in the background
    index_auto_update = true,      -- (index_mode=full only) re-crawl automatically when the index is older than index_refresh_hours
    index_refresh_hours = 24,      -- Age after which the index counts as stale
    index_delay_secs = 0.6,        -- Pause between crawl requests (be gentle with the server; ~100 requests/min)
    index_start_delay_secs = 5,    -- Wait this long after opening the browser before an automatic crawl starts
    index_max_dirs = 4000,         -- Safety cap on folders visited per crawl
    index_max_results = 400,       -- Max rows shown for one search

    -- ===== Clean titles (EXPERIMENTAL) =====
    experimental_clean_titles = true,  -- Show "S01E03" + quality chips instead of the raw release name (full name on hover)
    clean_titles_chips = true,         -- Quality chips: 4K / 1080p / HDR / DV / ATMOS / REMUX ...
    clean_titles_tooltip = true,       -- Hovering a row shows its full release name in a tooltip
    -- (used by webdav-browser-posters.lua only; listed so the shared conf does not warn)
    home_view = true, home_card_pct = 19, home_recent_count = 20,
    merge_seasons = true, queue_folder = true, queue_max = 200, cache_clear_key = "ctrl+x",   -- poster edition only (listed so the shared conf does not warn)
    open_key_posters = "ctrl+p", experimental_posters = true, tmdb_key = "", poster_column_pct = 17,
    poster_converter = "auto", poster_cache_dir = "",
    open_key = "ctrl+w",               -- Key(s) that open/close the browser (separate several with spaces), e.g. "ctrl+w ctrl+p"
    clean_folder_titles = true,        -- Also clean the folder names in the left panel (title + season + quality + release group)

    -- ===== Mouse =====
    double_click_ms = 400,       -- Two clicks on one row within this time = double-click (plays a file)
    scroll_lines = 3,            -- Rows moved per mouse-wheel notch
    scrollbar_hit_px = 14,       -- Width of the scrollbar grab area (the drawn bar is thinner)

    -- ===== Watch tracking / resume =====
    watch_min_secs = 30,           -- Don't record "in progress" until you've watched at least this many seconds...
    watch_min_pct = 2,             -- ...and at least this % of the file
    watched_threshold_pct = 95,    -- Past this % the file counts as watched
    watched_tail_secs = 20,        -- ...or when this close to the end
    resume_min_secs = 15,          -- Only resume files saved beyond this position
    resume_notice = true,          -- Show "Resumed at 12:34" when resuming
    resume_notice_secs = 6,        -- How long the notice (and the start-over key) stays active
    start_over_key = "b",          -- Press during the notice to restart from 0:00
    continue_row = true,           -- "Continue Watching" row at the top of the Folders panel
    continue_max_items = 30,       -- Max entries in that list
    hide_watched_default = false,  -- Start with watched files hidden (toggle: 'H')

    -- ===== Diagnostics / config =====
    debug_overlay = false,         -- Start with the debug panel open (toggle: 'd')
    config_poll_secs = 2,          -- While the browser is open, re-read the .conf this often (live reload)
    show_status_text = true,       -- Right edge of file rows: "✓ Watched" / "◐ 42% - 31:10 left" (false = just the small tick after the name)
    watched_label = "Watched",     -- Text shown next to the tick for watched files
    stay_open = true,              -- Keep mpv open (idle) when a file fails to load or the playlist ends, instead of quitting
    http_reconnect = true,         -- Ask ffmpeg to reconnect dropped/ended HTTP streams (helps flaky CDN links)
    fallback_download = true,      -- If streaming a file fails, download it with curl and play it while it downloads
    fallback_after_failures = 1,   -- Start the fallback after this many failed stream attempts (1 = right away)
    fallback_start_mb = 200,       -- Start playing once this much (MB) has been downloaded
    fallback_dir = "",             -- Where partial downloads go ("" = <temp folder>/webdav-browser-cache)
    fallback_stall_secs = 45,      -- How long playback waits for the download to catch up before giving up
    fallback_keep = false,         -- Keep the downloaded file after playback (false = delete it)
    fallback_cleanup_hours = 24,   -- Leftover files older than this are removed at startup
    curl_auth_mode = "auto",       -- "auto" | "arg" | "stdin": how credentials reach curl (auto = arg on Windows, stdin elsewhere)

    -- ===== Buffering / prefetch =====
    demuxer_readahead_secs    = 300,  -- Seconds of media mpv tries to buffer ahead of the playback position
    demuxer_max_bytes_mb      = 1024, -- Max forward buffer (MiB of RAM) - whichever of secs/bytes is reached first stops buffering
    demuxer_max_back_bytes_mb = 256,  -- Max backward buffer (MiB) - lets you seek back without re-downloading
    prefetch_threshold_pct    = 75,   -- Once playback reaches this % of the duration, queue + buffer the next episode
    prefetch_on_buffered      = true, -- ...or earlier, as soon as the current file is completely buffered
    prefetch_check_interval_secs = 5, -- How often (seconds) to check whether the prefetch threshold has been crossed
}
-- Snapshot of the built-in defaults, so a live config reload can fall back to them for options
-- that were removed from the .conf (read_options alone only overwrites keys that ARE in the file).
local DEFAULTS = {}
for k, v in pairs(o) do DEFAULTS[k] = v end

local host_label = "not configured"
-- Environment-variable fallbacks + trailing-slash cleanup. Works on any options table so a live
-- config reload can normalise the freshly-read copy the same way before comparing it with `o`.
local function normalize_into(tbl)
    if tbl.url  == "" and os.getenv("WEBDAV_URL")  then tbl.url  = os.getenv("WEBDAV_URL")  end
    if tbl.user == "" and os.getenv("WEBDAV_USER") then tbl.user = os.getenv("WEBDAV_USER") end
    if tbl.pass == "" and os.getenv("WEBDAV_PASS") then tbl.pass = os.getenv("WEBDAV_PASS") end
    tbl.url = (tbl.url:gsub("/+$", ""))
end
local function normalize_options()
    normalize_into(o)
    host_label = o.url:match("^https?://([^/]+)") or (o.url ~= "" and o.url or "not configured")
end

-- on_update (3rd arg) fires when script-opts change at runtime; hot_reload_hook is filled in near the
-- bottom of the file (it needs functions defined later).
local hot_reload_hook = nil
options.read_options(o, "webdav-browser", function(changed)
    if hot_reload_hook then hot_reload_hook("script-opts", changed) end
end)

-- mpv's own .conf parser is strict: it does not trim values, does not strip trailing "# comments",
-- and only accepts yes/no for booleans. This second pass re-reads the file leniently and overrides
-- the affected keys, so "default_sort=recent   # newest first" and "prefetch=true" just work.
-- Credentials (user/pass) are only trimmed, never comment-stripped.
U.conf_notes = {}
function U.lenient_conf(tbl)
    local notes = {}
    local path
    pcall(function() path = mp.find_config_file("script-opts/webdav-browser.conf") end)
    if not path then
        pcall(function() path = mp.command_native({ "expand-path", "~~/script-opts/webdav-browser.conf" }) end)
    end
    if type(path) ~= "string" then return notes end
    local f = io.open(path, "rb")
    if not f then return notes end
    local text = f:read("*a") or ""
    f:close()
    if text:sub(1, 3) == "\239\187\191" then text = text:sub(4) end
    local stripped, bad, unknown = {}, {}, {}
    for line in (text .. "\n"):gmatch("(.-)\r?\n") do
        local t = line:match("^%s*(.-)%s*$")
        if t ~= "" and t:sub(1, 1) ~= "#" then
            local k, v = t:match("^([%w_%-]+)%s*=%s*(.*)$")
            if k then
                local def = DEFAULTS[k]
                if def == nil then
                    unknown[#unknown + 1] = k
                elseif k == "user" or k == "pass" then
                    tbl[k] = v
                    if v:find("%s#") then
                        notes[#notes + 1] = k .. " contains ' #' - kept as part of the value (put comments on their own line)"
                    end
                else
                    local clean = (v:gsub("%s+#.*$", ""))
                    clean = clean:match("^%s*(.-)%s*$")
                    if clean ~= v then stripped[#stripped + 1] = k end
                    if type(def) == "boolean" then
                        local l = clean:lower()
                        if l == "yes" or l == "true" or l == "on" or l == "1" then tbl[k] = true
                        elseif l == "no" or l == "false" or l == "off" or l == "0" then tbl[k] = false
                        else bad[#bad + 1] = k end
                    elseif type(def) == "number" then
                        local n = tonumber(clean)
                        if n then tbl[k] = n else bad[#bad + 1] = k end
                    else
                        tbl[k] = clean
                    end
                end
            end
        end
    end
    if #stripped > 0 then notes[#notes + 1] = "inline comments ignored on: " .. table.concat(stripped, ", ") end
    if #bad > 0 then notes[#notes + 1] = "invalid value (default kept): " .. table.concat(bad, ", ") end
    if #unknown > 0 then notes[#notes + 1] ="unknown/removed options ignored: " .. table.concat(unknown, ", ") end
    for _, n in ipairs(notes) do pcall(function() mp.msg.warn("config: " .. n) end) end
    return notes
end
U.conf_notes = U.lenient_conf(o)
normalize_options()

-- ============================================================
-- COLOR HELPERS
-- ============================================================
function U.ass_color(hex)
    hex = hex:gsub("^#", "")
    return "&H" .. hex:sub(5, 6) .. hex:sub(3, 4) .. hex:sub(1, 2) .. "&"
end
function U.ass_alpha(opacity_pct)
    opacity_pct = math.max(0, math.min(100, opacity_pct))
    return string.format("&H%02X&", math.floor((100 - opacity_pct) / 100 * 255 + 0.5))
end
function U.pick(v, fallback)
    if v == nil or v == "" then return fallback end
    return v
end

-- ============================================================
-- THEME (built from options)
-- ============================================================
local function build_theme()
    return {
        bg_dim         = U.pick(o.color_bg_dim, "08050F"),
        bg_header      = U.pick(o.color_bg_header, "100C18"),
        bg_panel       = U.pick(o.color_bg_panel, "221A2F"),
        bg_panel_dim   = U.pick(o.color_bg_panel_dim, "1A1425"),
        accent         = U.pick(o.color_accent, "FF8FB8"),
        border_unfocus = U.pick(o.color_border_unfocus, "3A2D4F"),
        text_primary   = U.pick(o.color_text_primary, "FAF5FF"),
        text_muted     = U.pick(o.color_text_muted, "B2A8C6"),
        text_dim       = U.pick(o.color_text_dim, "867C9A"),
        good           = U.pick(o.color_good, "7FE3B0"),
        warn           = U.pick(o.color_warn, "FFB86B"),
        bad            = U.pick(o.color_bad, "FF6B8B"),
        folder         = U.pick(o.color_folder, "FFD6A5"),
        video          = U.pick(o.color_video, "8EC5FF"),
        audio          = U.pick(o.color_audio, "C9A7FF"),
        file           = U.pick(o.color_file, "A59BB8"),
        cached         = U.pick(o.color_cached_folder, "9C92B0"),
        track          = U.pick(o.color_track, "3B2F52"),
    }
end
local THEME = build_theme()

-- ============================================================
-- ICONS
-- ============================================================
local ICON_SETS = {
    emoji = {
        folder_closed = "📁", folder_open = "📂", folder_empty = "📁",
        file = "📄", video = "🎬", audio = "🎵",
        watched = "✅", watching = "⏳",
        search = "🔍", active_marker = "🔵",
    },
    minimal = {
        folder_closed = "▸", folder_open = "▾", folder_empty = "•",
        file = "·", video = "▶", audio = "♪",
        watched = "✓", watching = "●",
        search = "⌕", active_marker = "●",
    },
    ascii = {
        folder_closed = "[+]", folder_open = "[-]", folder_empty = "[ ]",
        file = "-", video = ">", audio = "~",
        watched = "v", watching = "o",
        search = "?", active_marker = "*",
    },
}

local function build_icons()
    local base = ICON_SETS[o.icon_style] or ICON_SETS.minimal
    local icons = {}
    for k, v in pairs(base) do icons[k] = v end
    local overrides = {
        folder_closed = o.icon_folder_closed, folder_open = o.icon_folder_open,
        folder_empty  = o.icon_folder_empty,  file = o.icon_file,
        video = o.icon_video, audio = o.icon_audio,
        watched = o.icon_watched, watching = o.icon_watching,
        search = o.icon_search, active_marker = o.icon_active_marker,
    }
    for k, v in pairs(overrides) do
        if v and v ~= "" then icons[k] = v end
    end
    return icons
end
local ICONS = build_icons()

-- ============================================================
-- FORWARD DECLS
-- ============================================================
local render, load_root, get_panel_items
local move_selection, switch_panel, open_selected, collapse_or_parent
local toggle_sort, refresh_current, queue_add_current
local on_click, on_wheel
local open_browser, close_browser
local play_entry, open_folder_node
local save_persistence, set_focus
local apply_dir_result, get_or_create_node, flatten_visible, collect_matching_folders
local cache_is_fresh
local bind_all, unbind_all, bind_search, unbind_search
local start_search, confirm_search, cancel_search, search_append, search_backspace
local find_next_media_href
local refresh_all, open_continue_view, reveal_path, index_start, index_stop
local get_continue_list, after_files_set, fetch_listing, mark_continue_dirty
local on_dblclick
local run_global_search_hook

-- ============================================================
-- STATE
-- ============================================================
local browser_active = false
local root_href = (o.start_path ~= "" and o.start_path or "/")
local current_path = root_href

local tree = {}
local root_children = {}

local file_entries = {}

local selected_episode, sidebar_selected_index = 1, 1
local scroll_offset_episodes, scroll_offset_folders = 0, 0
local focus_panel = "sidebar"
local status_line = "Ready"

local is_loading = false
local loading_count = 0                       -- number of visible (non-silent) fetches in flight
local listing_error = {}                      -- dir href -> message   (errors are per folder now)
local req_seq = {}                            -- dir href -> newest request number (older replies are ignored)
local dir_cache = {}
local hide_watched = o.hide_watched_default
local pending_select_href = nil               -- after a listing loads, highlight this file
local free_scroll = { sidebar = false, episodes = false }  -- true after wheel/scrollbar use: don't snap view to selection
local search_results = {}                     -- global (index) search results
-- Mouse + overlay state kept in one table (Lua 5.1 allows only 200 local variables per function)
local MS = { drag = nil, hover_sb = nil, last_down_t = 0, last_panel = nil, last_index = nil,
             last_double_t = 0, last_move_render = 0, debug = false, last_overlay_key = nil,
             tooltip_x = 0, tooltip_y = 0, inflight = {} }
local CW_HREF = "webdav-browser://continue-watching"

local watch_history, watched_set = {}, {}
local pending_meta, now_playing = {}, nil
local retry_counts, close_pending_for = {}, nil
local auth_configured = false

-- Continuously-tracked playback position/duration. See the comment above the
-- mp.observe_property calls near the bottom for why this exists.
local last_known_pos, last_known_dur = nil, nil

local hover_panel, hover_index = nil, nil
local row_hitboxes, button_hitboxes = {}, {}
local layout = nil

local sidebar_frac = (100 - o.focused_width_pct) / 100
local anim_timer = nil

-- search_scope tells us WHICH panel a search applies to: "sidebar" | "episodes" | nil (no filter)
local search_active = false
local search_query = ""
local search_scope = nil

-- background video blur state
local blur_applied = false
local blur_supported = true

local spinner_frames = {"⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏"}
local spinner_idx = 1

local overlay = mp.create_osd_overlay("ass-events")
overlay.z = 3000

if o.prefetch then pcall(function() mp.set_property_bool("prefetch-playlist", true) end) end
-- By default mpv exits as soon as its playlist is empty, which includes "the only file failed to open".
-- Staying idle keeps the window (and this browser) alive so the failure is visible and retryable.
if o.stay_open then pcall(mp.set_property, "idle", "yes") end
if o.http_reconnect then
    pcall(mp.commandv, "change-list", "stream-lavf-o", "append", "reconnect=1")
    pcall(mp.commandv, "change-list", "stream-lavf-o", "append", "reconnect_streamed=1")
    pcall(mp.commandv, "change-list", "stream-lavf-o", "append", "reconnect_delay_max=5")
end

-- ============================================================
-- BACKGROUND BLUR (real video filter, not just an overlay effect)
-- ============================================================
local function apply_background_blur()
    if blur_applied then return end
    if not o.background_blur_enabled then MS.blur_state = "disabled"; return end
    if not blur_supported then MS.blur_state = "unsupported by this mpv build"; return end
    local mode = tostring(o.background_blur_mode or "auto"):lower()
    if mode ~= "auto" and mode ~= "lite" and mode ~= "full" and mode ~= "off" then mode = "auto" end
    if mode == "off" then MS.blur_state = "off"; return end
    local sigma = tonumber(o.background_blur_strength) or 0
    if sigma <= 0 then MS.blur_state = "off (strength 0)"; return end
    if not mp.get_property("video-format") then MS.blur_state = "off (no video)"; return end

    if mode == "auto" then
        -- A software video filter on heavy video is costly, and on hardware-decoded video (without
        -- -copy) it can push mpv back to software decoding. auto mode skips blur in those cases.
        local vh = mp.get_property_number("height") or 0
        if vh > (tonumber(o.background_blur_max_height) or 1440) then
            MS.blur_state = string.format("skipped (%dp video)", vh); return
        end
        local hw = mp.get_property("hwdec-current") or ""
        if not o.background_blur_force and hw ~= "" and hw ~= "no" and not hw:find("%-copy$") then
            MS.blur_state = "skipped (hardware decoding: " .. hw .. ")"; return
        end
        mode = "lite"
    end

    local filter_str
    if mode == "lite" then
        -- shrink 4x, blur lightly, and let mpv's own scaler stretch it back up: looks the same, ~16x cheaper
        filter_str = string.format("@webdav_blur:lavfi=[scale=iw/4:-2:flags=fast_bilinear,gblur=sigma=%g:steps=1]",
            math.max(1, sigma / 4))
    else
        filter_str = string.format("@webdav_blur:lavfi=[gblur=sigma=%s]", tostring(sigma))
    end
    local ok_call, ok_result = pcall(function() return mp.commandv("vf", "add", filter_str) end)
    if ok_call and ok_result ~= false then
        blur_applied = true
        MS.blur_state = mode
    else
        blur_supported = false
        MS.blur_state = "unsupported by this mpv build"
        msg.warn("webdav-browser: background blur unsupported on this mpv build (needs libavfilter)")
    end
end

-- True if our blur filter is really in mpv's filter chain (independent of our own bookkeeping).
local function blur_in_chain()
    local ok, chain = pcall(mp.get_property_native, "vf")
    if not ok or type(chain) ~= "table" then return blur_applied end
    for _, f in ipairs(chain) do
        if type(f) == "table" and f.label == "webdav_blur" then return true end
    end
    return false
end

local function remove_background_blur()
    if blur_applied or blur_in_chain() then
        pcall(function() mp.commandv("vf", "remove", "@webdav_blur") end)
    end
    blur_applied = false
    MS.blur_state = "off"
end

-- ============================================================
-- MEDIA TYPE DETECTION
-- ============================================================
U.video_exts = {
    mp4=true, mkv=true, avi=true, mov=true, wmv=true, flv=true, webm=true,
    ts=true, m2ts=true, mpg=true, mpeg=true, vob=true, rm=true, rmvb=true,
    ["3gp"]=true, m4v=true, ogv=true,
}
U.audio_exts = {
    mp3=true, flac=true, ogg=true, oga=true, wav=true, aac=true,
    m4a=true, opus=true, wma=true, mka=true,
}

function U.ext_of(name) return name:match("%.([%w]+)$") end
function U.is_video(name) local e = U.ext_of(name); return e ~= nil and U.video_exts[e:lower()] == true end
function U.is_audio(name) local e = U.ext_of(name); return e ~= nil and U.audio_exts[e:lower()] == true end
function U.is_media(name) return U.is_video(name) or U.is_audio(name) end

-- ============================================================
-- SMALL UTILS
-- ============================================================
function U.url_encode_segment(seg)
    return (seg:gsub("([^%w%-%_%.%~])", function(c) return string.format("%%%02X", string.byte(c)) end))
end

-- NOTE: no "+" -> " " step. That only applies to query strings / form data, never to URL
-- paths, and it used to turn names like "DD+5.1" into "DD 5.1".
function U.percent_decode(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

function U.xml_unescape(s)
    return s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"')
            :gsub("&apos;", "'"):gsub("&amp;", "&")
end

function U.basename(path)
    path = path:gsub("/+$", "")
    local name = path:match("([^/]+)$") or path
    return U.percent_decode(name)
end

U.http_months = {Jan=1,Feb=2,Mar=3,Apr=4,May=5,Jun=6,Jul=7,Aug=8,Sep=9,Oct=10,Nov=11,Dec=12}
function U.parse_http_date(s)
    if not s then return nil end
    local day, mon, year, hh, mm, ss = s:match("(%d+)%s+(%a+)%s+(%d+)%s+(%d+):(%d+):(%d+)")
    if not day or not U.http_months[mon] then return nil end
    local ok, t = pcall(os.time, {
        year=tonumber(year), month=U.http_months[mon], day=tonumber(day),
        hour=tonumber(hh), min=tonumber(mm), sec=tonumber(ss),
    })
    return ok and t or nil
end

function U.utf8_len(s)
    local n = 0
    for _ in s:gmatch("[\1-\127\194-\253][\128-\191]*") do n = n + 1 end
    return n
end

function U.utf8_sub(s, max_chars)
    if max_chars <= 0 then return "" end
    local out, n = {}, 0
    for ch in s:gmatch("[\1-\127\194-\253][\128-\191]*") do
        n = n + 1
        if n > max_chars then return table.concat(out) .. "…" end
        table.insert(out, ch)
    end
    return table.concat(out)
end

-- Removes the last UTF-8 CHARACTER (not just the last byte) so Backspace never leaves half a glyph.
function U.utf8_pop(s)
    if s == "" then return s end
    local i = #s
    while i > 1 do
        local b = s:byte(i)
        if b < 128 or b >= 192 then break end   -- stop on an ASCII or lead byte
        i = i - 1
    end
    return s:sub(1, i - 1)
end

-- Natural ordering: "ep2" < "ep10", case-insensitive.
function U.natural_less(a, b)
    a, b = a:lower(), b:lower()
    local i, j = 1, 1
    local la, lb = #a, #b
    while i <= la and j <= lb do
        local ad, bd = a:match("^%d+", i), b:match("^%d+", j)
        if ad and bd then
            local an, bn = tonumber(ad), tonumber(bd)
            if an ~= bn then return an < bn end
            if #ad ~= #bd then return #ad < #bd end
            i, j = i + #ad, j + #bd
        else
            local ac, bc = a:sub(i, i), b:sub(j, j)
            if ac ~= bc then return ac < bc end
            i, j = i + 1, j + 1
        end
    end
    return (la - i) < (lb - j)
end

-- Search normalisation: release names use dots/underscores/dashes as word separators.
function U.norm_text(s)
    return (" " .. s:lower():gsub("[%._%-%[%]%(%)]+", " "):gsub("%s+", " ") .. " ")
end
function U.query_tokens(q)
    local toks = {}
    for w in U.norm_text(q):gmatch("%S+") do toks[#toks + 1] = w end
    return toks
end
-- Returns a score (higher = better) when EVERY token occurs in the name, else nil.
function U.match_score(name, toks)
    if #toks == 0 then return 0 end
    local hay = U.norm_text(name)
    local score = 0
    for _, tok in ipairs(toks) do
        local pos = hay:find(tok, 1, true)
        if not pos then return nil end
        if hay:sub(pos - 1, pos - 1) == " " then score = score + 3 else score = score + 1 end
    end
    return score
end

function U.fmt_time(sec)
    sec = math.max(0, math.floor(sec or 0))
    local h, m, s = math.floor(sec / 3600), math.floor(sec % 3600 / 60), sec % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%d:%02d", m, s)
end

function U.fmt_age(ts)
    if not ts then return "never" end
    local d = os.time() - ts
    if d < 0 then d = 0 end
    if d < 90 then return d .. "s ago" end
    if d < 5400 then return math.floor(d / 60) .. "m ago" end
    if d < 172800 then return math.floor(d / 3600) .. "h ago" end
    return math.floor(d / 86400) .. "d ago"
end

-- Parent directory href of a file/folder href ("/a/b/c.mkv" -> "/a/b/", "/a/b/" -> "/a/")
function U.dirname(href)
    local h = href:gsub("/+$", "")
    return h:match("^(.*/)[^/]+$") or "/"
end

function U.now_s() return mp.get_time() end

function U.ass_escape(s)
    return (tostring(s):gsub("\\", "\\\\"):gsub("{", "\\{"):gsub("}", "\\}"))
end

function U.fit_text(s, max_px, fs)
    local max_chars = math.max(1, math.floor(max_px / (fs * 0.62)))
    if U.utf8_len(s) <= max_chars then return s end
    return U.utf8_sub(s, math.max(1, max_chars - 1))
end

function U.fmt_bytes(n)
    if n >= 1073741824 then return string.format("%.1f GB", n / 1073741824) end
    return string.format("%.0f MB", n / 1048576)
end

function U.canvas_size()
    local w = mp.get_property_number("osd-width") or 0
    local h = mp.get_property_number("osd-height") or 0
    if w < 64 or h < 64 then
        local ow, oh = mp.get_osd_size()
        w, h = ow or 0, oh or 0
    end
    if w < 64 then w = 1280 end
    if h < 64 then h = 720 end
    return math.floor(w), math.floor(h)
end

-- ============================================================
-- PERSISTENCE (watch history, watched set, sort memory, directory cache / index)
-- ============================================================
local persist_status = { path = nil, ok = nil, last_save = nil, err = nil, bytes = 0 }
local sort_by_dir = {}                 -- directory href -> "name" | "recent"   (per-folder sort memory)
local index_meta = { last_full = nil } -- when the library index was last crawled completely

-- mp.get_script_directory() returns NOTHING for a single-file script (one that sits directly in
-- mpv's scripts/ folder), which silently disabled every save in earlier versions. Fall back to
-- <mpv config dir>/script-opts/, which exists for anyone who has a .conf file.
local function data_dir()
    local d = mp.get_script_directory()
    if d and d ~= "" then return d end
    local ok, r = pcall(mp.command_native, { "expand-path", "~~/script-opts" })
    if ok and type(r) == "string" and r ~= "" then return r end
    if mp.find_config_file then
        local ok2, r2 = pcall(mp.find_config_file, "script-opts")
        if ok2 and type(r2) == "string" and r2 ~= "" then return r2 end
    end
    return nil
end

local function history_file_path()
    local dir = data_dir()
    if not dir then return nil end
    return utils.join_path(dir, "webdav_browser_data.json")
end

-- Writes via a temp file so a crash mid-write can't corrupt the data. Windows' rename() refuses
-- to overwrite an existing file, so the old file is moved aside to .bak first (and load falls
-- back to .bak if the main file ever fails to parse).
local function atomic_write(path, content)
    local tmp, bak = path .. ".tmp", path .. ".bak"
    local f, err = io.open(tmp, "wb")
    if not f then return false, tostring(err) end
    local okw, werr = f:write(content)
    f:close()
    if not okw then os.remove(tmp); return false, tostring(werr) end
    os.remove(bak)
    local had_old = os.rename(path, bak)
    if not os.rename(tmp, path) then
        if had_old then os.rename(bak, path) end
        local f2 = io.open(path, "wb")
        if not f2 then return false, "could not replace " .. path end
        f2:write(content); f2:close(); os.remove(tmp)
    end
    return true
end

local function try_load_json(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    if not content or content == "" then return nil end
    local ok, data = pcall(utils.parse_json, content)
    if ok and type(data) == "table" then return data end
    return nil
end

-- ROOT CAUSE of "history is gone after a restart": mpv's JSON parser returns "[]" as an ARRAY-flagged table, and
-- format_json then writes an array-flagged table as [] no matter what string keys were added afterwards. The very
-- first save wrote "history": [] (empty table), every later session loaded that flagged table, and all history
-- written into it vanished again at the next save. Maps read from disk are therefore always copied into plain tables.
function U.plain(t)
    local r = {}
    if type(t) == "table" then for k, v in pairs(t) do r[k] = v end end
    return r
end

-- Invalid UTF-8 (odd file names on a server) makes utils.format_json fail; this replaces such bytes with "?".
function U.clean_utf8(s)
    if not s:find("[\128-\255]") then return s end
    local out, i, n = {}, 1, #s
    while i <= n do
        local b = s:byte(i)
        local len = (b < 128 and 1) or (b >= 194 and b <= 223 and 2) or (b >= 224 and b <= 239 and 3) or (b >= 240 and b <= 244 and 4) or 0
        local ok = len > 0 and i + len - 1 <= n
        if ok then
            for k = 1, len - 1 do
                local c = s:byte(i + k)
                if c < 128 or c > 191 then ok = false break end
            end
        end
        if ok then out[#out + 1] = s:sub(i, i + len - 1); i = i + len
        else out[#out + 1] = "?"; i = i + 1 end
    end
    return table.concat(out)
end
function U.clean_tree(v, depth)
    depth = depth or 0
    if depth > 12 then return nil end
    if type(v) == "string" then return U.clean_utf8(v) end
    if type(v) ~= "table" then return v end
    local t = {}
    for k, x in pairs(v) do t[type(k) == "string" and U.clean_utf8(k) or k] = U.clean_tree(x, depth + 1) end
    return t
end
local function safe_json(payload)
    local ok, json = pcall(utils.format_json, payload)
    if ok and type(json) == "string" then return json end
    ok, json = pcall(utils.format_json, U.clean_tree(payload))
    if ok and type(json) == "string" then return json end
    return nil
end

local function load_persistence()
    local path = history_file_path()
    persist_status.path = path
    if not path then
        persist_status.ok, persist_status.err = false, "no writable data directory (needs mpv 'expand-path')"
        msg.warn("webdav-browser: persistence disabled - no data directory available")
        return
    end
    local data = try_load_json(path) or try_load_json(path .. ".bak")
    if data then
        watch_history = U.plain(data.history)
        watched_set   = U.plain(data.watched)
        sort_by_dir   = U.plain(data.sort)
        index_meta    = U.plain(data.index)
        if o.persist_dir_cache and type(data.dir_cache) == "table" then
            dir_cache = U.plain(data.dir_cache)
            MS.cache_version = MS.cache_version + 1
        end
    end
    persist_status.ok = true
end

save_persistence = function(force)
    if MS.active == false and not force then return end     -- only the instance that owns playback writes
    local path = persist_status.path or history_file_path()
    if not path then return end
    local payload = { v = 2, history = watch_history, watched = watched_set, sort = sort_by_dir, index = index_meta }
    if o.persist_dir_cache then payload.dir_cache = dir_cache end
    local json = safe_json(payload)
    if not json and payload.dir_cache then     -- the big cache must never cost you the history
        payload.dir_cache = nil
        json = safe_json(payload)
    end
    if not json then
        persist_status.ok, persist_status.err = false, "format_json failed"
        return
    end
    local wok, werr = atomic_write(path, json)
    persist_status.path = path
    persist_status.ok = wok
    persist_status.err = wok and nil or werr
    if wok then persist_status.last_save, persist_status.bytes = os.time(), #json
    else msg.warn("webdav-browser: could not save data: " .. tostring(werr)) end
end

-- Directory-cache writes are batched: the first dirty change schedules ONE flush; further changes
-- inside that window ride along. Watch-history saves (end-file) stay immediate.
local persist_debounce_timer = nil
local function debounced_save_persistence(delay)
    if persist_debounce_timer then return end
    persist_debounce_timer = mp.add_timeout(delay or 3, function()
        persist_debounce_timer = nil
        save_persistence()
    end)
end

-- A cached listing is "fresh" for cache_ttl seconds (<=0 = forever). Stale listings are still shown
-- instantly and, with revalidate_stale, silently re-fetched in the background.
cache_is_fresh = function(entry)
    if not entry then return false end
    if entry.stale then return false end
    if o.cache_ttl <= 0 then return true end
    return (os.time() - (entry.ts or 0)) < o.cache_ttl
end

-- ============================================================
-- WEBDAV
-- ============================================================
-- Request statistics, shown in the debug overlay ('d').
local req_stats = { last = nil, pending = 0, total = 0, failures = 0 }

function U.curl_quote(s)
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r")
    return '"' .. s .. '"'
end

-- mpv documents subprocess stdin_data as unreliable on Windows, so "auto" passes -u there and
-- uses curl's config-on-stdin (-K -) elsewhere (keeps the password out of the process list).
function U.auth_mode()
    local m = tostring(o.curl_auth_mode or "auto"):lower()
    if m ~= "arg" and m ~= "stdin" then
        m = (package.config:sub(1, 1) == "\\") and "arg" or "stdin"
    end
    return m
end

-- Runs curl asynchronously. The HTTP status code is appended to
-- the output via -w and split off again here.
-- callback(stdout_or_nil, err_or_nil, info{ms, exit, code})
local function run_curl_async(args, callback)
    local full_args = {
        o.curl_path, "-s", "-S",
        "--max-time", tostring(o.request_timeout),
        "--connect-timeout", tostring(math.min(10, o.request_timeout)),
        "-w", "\\n%{http_code}",
    }
    local stdin_data = nil
    if o.user ~= "" or o.pass ~= "" then
        if U.auth_mode() == "arg" then
            table.insert(full_args, "-u"); table.insert(full_args, o.user .. ":" .. o.pass)
        else
            table.insert(full_args, "-K"); table.insert(full_args, "-")
            stdin_data = "user = " .. U.curl_quote(o.user .. ":" .. o.pass) .. "\n"
        end
    end
    for _, a in ipairs(args) do table.insert(full_args, a) end

    local t0 = U.now_s()
    req_stats.pending = req_stats.pending + 1
    req_stats.total = req_stats.total + 1
    return mp.command_native_async({
        name = "subprocess", args = full_args, stdin_data = stdin_data,
        capture_stdout = true, capture_stderr = true, playback_only = false,
    }, function(success, result, err_msg)
        req_stats.pending = math.max(0, req_stats.pending - 1)
        local info = { ms = math.floor((U.now_s() - t0) * 1000 + 0.5) }
        if not success or not result then
            callback(nil, err_msg or "failed to launch curl", info); return
        end
        info.exit = result.status
        local out = result.stdout or ""
        local body, code = out:match("^(.*)\n(%d%d%d)$")
        if code then info.code = tonumber(code); out = body end
        if result.status ~= 0 then
            local e = (result.stderr and result.stderr ~= "" and result.stderr)
                or ("curl exited with status " .. tostring(result.status))
            callback(nil, e, info); return
        end
        callback(out, nil, info)
    end)
end

local function sort_mode_for(href)
    return sort_by_dir[href] or ((o.default_sort == "recent") and "recent" or "name")
end

-- Folders first, then the directory's own sort mode (name = natural order, so ep2 < ep10).
local function sort_entries(list, mode)
    table.sort(list, function(a, b)
        if a.is_dir ~= b.is_dir then return a.is_dir end
        if mode == "recent" then
            local am, bm = a.mtime, b.mtime
            if am and bm and am ~= bm then return am > bm end
            if am and not bm then return true end
            if bm and not am then return false end
        end
        return U.natural_less(a.name, b.name)
    end)
end

local function parse_propfind(xml, request_path)
    local results, seen = {}, {}
    if not xml then return results end
    for block in xml:gmatch("<[^>]-:?response[^>]*>(.-)</[^>]-:?response>") do
        local href = block:match("<[^>]-:?href[^>]*>(.-)</[^>]-:?href>")
        if href then
            href = U.xml_unescape(href)
            local path_only = href:gsub("^https?://[^/]+", "")
            local is_collection = block:match("<[^>]-:?collection%s*/?>") ~= nil
            local norm_req  = request_path:gsub("/+$", "")
            local norm_href = path_only:gsub("/+$", "")
            if norm_href ~= norm_req then
                local size = block:match("<[^>]-:?getcontentlength[^>]*>(%d+)</[^>]-:?getcontentlength>")
                local mtime_str = block:match("<[^>]-:?getlastmodified[^>]*>(.-)</[^>]-:?getlastmodified>")
                local name = U.basename(path_only)
                local key = (is_collection and "D:" or "F:") .. name:lower() .. "|" .. tostring(size or "")
                if not seen[key] then
                    seen[key] = true
                    table.insert(results, {
                        name = name, href = path_only, is_dir = is_collection,
                        size = tonumber(size),
                        mtime = U.parse_http_date(mtime_str and U.xml_unescape(mtime_str) or nil),
                    })
                end
            end
        end
    end
    return results
end

-- Fetches one folder listing. Timeouts, HTTP 429 and 5xx are retried (attempt N waits N x
-- request_retry_delay). callback(entries_or_nil, err_or_nil, info{ms, code, exit, attempts})
local function fetch_dir_async(path, callback)
    if o.url == "" then callback(nil, "WebDAV URL not configured", {}); return end
    local attempt = 0
    local function try()
        attempt = attempt + 1
        local args = { "-X", "PROPFIND", "-H", "Depth: 1", "-H", "Content-Type: application/xml", o.url .. path }
        run_curl_async(args, function(stdout, err, info)
            info.attempts = attempt
            local problem, retriable = nil, false
            if err then
                local ex = info.exit
                if ex == 28 then
                    problem, retriable = "Timed out after " .. o.request_timeout .. "s (raise request_timeout)", true
                elseif ex == 6 or ex == 7 then
                    problem, retriable = "Can't reach the server", true
                elseif ex == 35 or ex == 58 or ex == 60 then
                    problem = "TLS / certificate problem"
                else
                    problem = "Request failed: " .. (tostring(err):gsub("%s+$", ""))
                end
            else
                local code = info.code
                if code == 401 then problem = "Unauthorized (check user/pass)"
                elseif code == 403 then problem = "Forbidden (HTTP 403)"
                elseif code == 404 then problem = "Not found (HTTP 404) - folder may have been removed"
                elseif code == 429 then problem, retriable = "Rate limited (HTTP 429)", true
                elseif code and code >= 500 then problem, retriable = "Server error (HTTP " .. code .. ")", true
                elseif not stdout or stdout == "" then problem = "Empty response"
                elseif not stdout:match("^%s*<%?xml") and not stdout:match("<[^>]-multistatus") then
                    problem = "Invalid response from server" .. (code and (" (HTTP " .. code .. ")") or "")
                end
            end
            if problem and retriable and attempt <= o.request_retries then
                mp.add_timeout(o.request_retry_delay * attempt, try)
                return
            end
            req_stats.last = { path = path, ms = info.ms, code = info.code, exit = info.exit,
                               attempts = attempt, ts = os.time(), err = problem }
            if problem then
                req_stats.failures = req_stats.failures + 1
                callback(nil, problem, info)
            else
                callback(parse_propfind(stdout, path), nil, info)
            end
        end)
    end
    try()
end

-- ============================================================
-- TREE HELPERS
-- ============================================================
function U.with_slash(href) return (href:gsub("/+$", "")) .. "/" end

-- cached listing for a directory, tolerant of a missing/extra trailing slash
local function find_cached_dir(href)
    return dir_cache[href] or dir_cache[U.with_slash(href)] or dir_cache[(href:gsub("/+$", ""))]
end

get_or_create_node = function(href, name, depth, parent_href)
    local existing = tree[href]
    if existing then return existing end
    local node = {
        href = href, name = name, depth = depth, parent_href = parent_href,
        expanded = false, loaded = false, loading = false, children = {},
    }
    tree[href] = node
    return node
end

local function prune_tree(href)
    local node = tree[href]
    if node then
        for _, c in ipairs(node.children) do prune_tree(c) end
        tree[href] = nil
    end
end

local function drop_cached_prefix(href)
    local prefix = U.with_slash(href)
    for k in pairs(dir_cache) do
        if k:sub(1, #prefix) == prefix then dir_cache[k] = nil end
    end
end

-- Stores a freshly fetched listing. Sub-folders that existed in the previous listing but are gone
-- now are pruned (tree nodes AND their cached listings), so deleted folders no longer linger in the
-- tree, in folder search, or in the library index.
local function store_listing(href, entries)
    local old = dir_cache[href]
    if old and type(old.entries) == "table" then
        local still = {}
        for _, e in ipairs(entries) do if e.is_dir then still[e.href] = true end end
        for _, e in ipairs(old.entries) do
            if e.is_dir and not still[e.href] then
                prune_tree(e.href)
                drop_cached_prefix(e.href)
                dir_cache[e.href] = nil
            end
        end
    end
    dir_cache[href] = { entries = entries, ts = os.time() }
    MS.cache_version = MS.cache_version + 1
    mark_continue_dirty()
end

apply_dir_result = function(href, entries)
    sort_entries(entries, sort_mode_for(href))

    local depth_of_href
    if href == root_href then
        depth_of_href = -1
    else
        depth_of_href = (tree[href] and tree[href].depth) or 0
    end

    local dirs, files = {}, {}
    for _, e in ipairs(entries) do
        if e.is_dir then table.insert(dirs, e) else table.insert(files, e) end
    end

    local ordered = {}
    for _, e in ipairs(dirs) do
        get_or_create_node(e.href, e.name, depth_of_href + 1, href)
        table.insert(ordered, e.href)
    end

    if href == root_href then
        root_children = ordered
    else
        local node = tree[href]
        if node then
            node.children = ordered
            node.loaded = true
        end
    end
    return files
end

-- Virtual "Continue Watching" row, always first in the Folders panel (when it has anything to show).
local CW_NODE = { href = CW_HREF, name = "Continue Watching", depth = 0, virtual = true,
                  expanded = false, loaded = true, loading = false, children = {} }

flatten_visible = function()
    local out = {}
    if o.continue_row and #get_continue_list() > 0 then table.insert(out, CW_NODE) end
    local function walk(hrefs)
        for _, href in ipairs(hrefs) do
            local node = tree[href]
            if node then
                table.insert(out, node)
                if node.expanded then walk(node.children) end
            end
        end
    end
    walk(root_children)
    return out
end

-- Folder-name search across the whole loaded tree (expanded or not); words match across . _ - separators.
collect_matching_folders = function(query)
    local toks = U.query_tokens(query)
    local out = {}
    for _, node in pairs(tree) do
        if U.match_score(node.name, toks) then table.insert(out, node) end
    end
    table.sort(out, function(a, b)
        if a.depth ~= b.depth then return a.depth < b.depth end
        return U.natural_less(a.name, b.name)
    end)
    return out
end

-- ============================================================
-- DIRECTORY LOADING
-- ============================================================
local function loading_delta(d)
    loading_count = math.max(0, loading_count + d)
    is_loading = loading_count > 0
end

-- The ONE place a folder listing is fetched, stored and applied.
--   opts.silent  : no spinner / status text (background revalidation, index crawl)
--   opts.status  : status line text while loading
-- Replies for a folder are only applied if no NEWER request for the same folder was issued, and the
-- Files panel is only touched if that folder is still the open one (so a slow reply for folder A
-- can never overwrite the file list of folder B you opened afterwards).
-- on_done(ok, err) is always called exactly once.
fetch_listing = function(href, opts, on_done)
    opts = opts or {}
    -- A background (silent) request for a folder that is already being fetched just waits for that
    -- request instead of replacing it (otherwise the index crawl or a revalidation could cancel
    -- the listing you are actually waiting for).
    if opts.silent and MS.inflight[href] then
        if on_done then table.insert(MS.inflight[href], on_done) end
        return
    end
    local waiters = {}
    MS.inflight[href] = waiters
    local function finish(ok, err)
        if MS.inflight[href] == waiters then MS.inflight[href] = nil end
        if on_done then on_done(ok, err) end
        for _, w in ipairs(waiters) do w(ok, err) end
    end

    req_seq[href] = (req_seq[href] or 0) + 1
    local seq = req_seq[href]
    local node = tree[href]
    if not opts.silent then
        loading_delta(1)
        if node then node.loading = true end
        if opts.status then status_line = opts.status end
        render()
    end

    fetch_dir_async(href, function(entries, err)
        if not opts.silent then
            loading_delta(-1)
            local n = tree[href]
            if n then n.loading = false end
        end
        if seq ~= req_seq[href] then          -- superseded by a newer request for this folder
            if not opts.silent then render() end
            finish(false, "superseded")
            return
        end
        if err then
            listing_error[href] = err
            if not opts.silent or href == current_path then
                status_line = "Failed: " .. err
            end
            render()
            finish(false, err)
            return
        end
        listing_error[href] = nil
        store_listing(href, entries)
        -- Only build tree nodes for folders that are part of the tree already (or the root). The
        -- background index also fetches deep folders whose ancestors aren't loaded; creating nodes
        -- for those would leave orphans with wrong depths.
        local files
        if href == root_href or tree[href] then
            files = apply_dir_result(href, entries)
        end
        if current_path == href then
            if not files then
                sort_entries(entries, sort_mode_for(href))
                files = {}
                for _, e in ipairs(entries) do if not e.is_dir then files[#files + 1] = e end end
            end
            file_entries = files
            after_files_set()
        end
        if not opts.silent and opts.status then status_line = "Loaded: " .. (U.basename(href) ~= "" and U.basename(href) or "root") end
        render()
        -- during a library crawl write less often (every ~30 s): the data file holds the whole index
        debounced_save_persistence(opts.silent and (MS.idx_running and 30 or 8) or 3)
        finish(true)
    end)
end

after_files_set = function()
    if pending_select_href then
        local items = get_panel_items("episodes")
        for i, e in ipairs(items) do
            if e.href == pending_select_href then
                selected_episode = i
                free_scroll.episodes = false
                break
            end
        end
        pending_select_href = nil
    end
    local n = #get_panel_items("episodes")
    if selected_episode > n then selected_episode = math.max(1, n) end
end

-- Show a cached listing instantly (even a stale one, when revalidate_stale is on) and refresh stale
-- ones silently; otherwise fetch with a visible spinner.
local function show_dir(href, status_text)
    local cached = dir_cache[href]
    if cached and (cache_is_fresh(cached) or o.revalidate_stale) then
        listing_error[href] = nil
        file_entries = apply_dir_result(href, cached.entries)
        after_files_set()
        render()
        if not cache_is_fresh(cached) then fetch_listing(href, { silent = true }) end
        return
    end
    file_entries = {}
    fetch_listing(href, { status = status_text })
end

load_root = function()
    current_path = root_href
    if search_scope ~= "sidebar" then
        search_query = ""
        search_scope = nil
    end
    show_dir(root_href, "Loading library")
end

open_folder_node = function(node)
    if node.virtual then open_continue_view(); return end
    if node.loading then return end
    node.expanded = true
    if current_path ~= node.href then
        selected_episode, scroll_offset_episodes = 1, 0
        free_scroll.episodes = false
    end
    current_path = node.href
    status_line = "Opening: " .. node.name

    if search_scope ~= "sidebar" then
        search_query = ""
        search_scope = nil
    end
    if o.auto_focus_files_on_open then set_focus("episodes") end
    show_dir(node.href, "Opening: " .. node.name)
end

-- Refreshes a list of folders one after another (gentle on the server) with a progress readout.
local function refresh_many(hrefs, label, on_done)
    local idx, total = 0, #hrefs
    local failed = 0
    local function step(ok)
        if idx > 0 and ok == false then failed = failed + 1 end
        idx = idx + 1
        if idx > total then
            status_line = (failed > 0) and string.format("%s: done, %d failed", label, failed) or (label .. ": done")
            render()
            if on_done then on_done() end
            return
        end
        status_line = string.format("%s %d/%d", label, idx, total)
        render()
        fetch_listing(hrefs[idx], { silent = true }, step)
    end
    step(true)
end

-- Root + every expanded folder + the highlighted/open one: i.e. everything the Folders panel shows.
local function visible_tree_hrefs()
    local list, seen = { root_href }, { [root_href] = true }
    local function add(h)
        if h and not seen[h] and h ~= CW_HREF then seen[h] = true; table.insert(list, h) end
    end
    local nodes = {}
    for _, node in pairs(tree) do
        if node.expanded and node.loaded then table.insert(nodes, node) end
    end
    table.sort(nodes, function(a, b)
        if a.depth ~= b.depth then return a.depth < b.depth end
        return a.href < b.href
    end)
    for _, n in ipairs(nodes) do add(n.href) end
    local hl = get_panel_items("sidebar")[sidebar_selected_index]
    if hl and not hl.virtual and hl.loaded then add(hl.href) end
    add(current_path)
    return list
end

-- 'r'  : Folders panel -> refresh the whole visible folder tree
--        Files panel   -> refresh the open folder
-- 'R'  : everything (see refresh_all)
refresh_current = function()
    if current_path == CW_HREF and focus_panel == "episodes" then
        mark_continue_dirty()
        open_continue_view()
        return
    end
    if focus_panel == "sidebar" then
        refresh_many(visible_tree_hrefs(), "Refreshing folders")
    else
        local nm = U.basename(current_path)
        fetch_listing(current_path, { status = "Refreshing: " .. (nm ~= "" and nm or "root") })
    end
end

-- Refreshes the visible tree, then marks every other cached listing stale (so it revalidates the
-- next time it is opened) and kicks off a full re-index of the library.
refresh_all = function()
    local hrefs = visible_tree_hrefs()
    local done = {}
    for _, h in ipairs(hrefs) do done[h] = true end
    refresh_many(hrefs, "Refreshing all", function()
        for h, c in pairs(dir_cache) do
            if not done[h] then c.stale = true end
        end
        if o.index_enabled and o.index_mode == "full" then index_start(true) end
        debounced_save_persistence()
    end)
end

-- ============================================================
-- PLAYBACK
-- ============================================================
U.b64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
function U.base64_encode(data)
    local out, len, i = {}, #data, 1
    while i <= len do
        local b1, b2, b3 = data:byte(i, i + 2)
        b2, b3 = b2 or 0, b3 or 0
        local n = b1 * 65536 + b2 * 256 + b3
        local c1 = math.floor(n / 262144) % 64
        local c2 = math.floor(n / 4096) % 64
        local c3 = math.floor(n / 64) % 64
        local c4 = n % 64
        local chunk = U.b64_chars:sub(c1+1,c1+1) .. U.b64_chars:sub(c2+1,c2+1)
        chunk = chunk .. ((i+1<=len) and U.b64_chars:sub(c3+1,c3+1) or "=")
        chunk = chunk .. ((i+2<=len) and U.b64_chars:sub(c4+1,c4+1) or "=")
        table.insert(out, chunk)
        i = i + 3
    end
    return table.concat(out)
end

local function file_stream_url(href)
    if o.embed_credentials_in_url and (o.user ~= "" or o.pass ~= "") then
        local scheme, rest = o.url:match("^(https?://)(.+)$")
        if scheme then
            return scheme .. U.url_encode_segment(o.user) .. ":" .. U.url_encode_segment(o.pass) .. "@" .. rest .. href
        end
    end
    return o.url .. href
end

local function auth_header_value()
    return "Authorization: Basic " .. U.base64_encode(o.user .. ":" .. o.pass)
end

local function is_our_url(u)
    return o.url ~= "" and type(u) == "string" and u:sub(1, #o.url) == o.url
end

-- Credentials are sent ONLY for files on your server: this hook runs before mpv opens each
-- file/URL and sets file-local options (they reset when that file ends), so playing any other
-- http(s) URL in the same mpv session never sees your Authorization header.
-- scoped_auth = false falls back to one session-wide header (see ensure_http_options).
mp.add_hook("on_load", 50, function()
    if not MS.active and not now_playing then return end   -- the other webdav-browser script owns playback right now
    if not o.scoped_auth or o.embed_credentials_in_url then return end
    if o.user == "" and o.pass == "" then return end
    local url = mp.get_property("stream-open-filename") or ""
    if is_our_url(url) then
        pcall(mp.set_property_native, "file-local-options/http-header-fields", { auth_header_value() })
        if o.user_agent ~= "" then pcall(mp.set_property, "file-local-options/user-agent", o.user_agent) end
    end
end)

-- Runs once per mpv session: demuxer cache sizing (+ the old session-wide auth header when
-- scoped_auth is off).
local function ensure_http_options()
    if auth_configured then return end
    auth_configured = true
    if not o.scoped_auth then
        if not o.embed_credentials_in_url and (o.user ~= "" or o.pass ~= "") then
            pcall(mp.set_property_native, "http-header-fields", { auth_header_value() })
        end
        if o.user_agent ~= "" then pcall(mp.set_property, "user-agent", o.user_agent) end
    end
    -- Bigger demuxer cache so slow/unstable WebDAV connections stutter less.
    pcall(mp.set_property, "cache", "yes")
    pcall(mp.set_property_number, "demuxer-readahead-secs", tonumber(o.demuxer_readahead_secs) or 300)
    pcall(mp.set_property, "demuxer-max-bytes", string.format("%dMiB", math.floor(tonumber(o.demuxer_max_bytes_mb) or 1024)))
    pcall(mp.set_property, "demuxer-max-back-bytes", string.format("%dMiB", math.floor(tonumber(o.demuxer_max_back_bytes_mb) or 256)))
end

local function queue_load(url, mode)
    ensure_http_options()
    mp.commandv("loadfile", url, mode)
end

-- Queue `url` directly AFTER the current file (so it plays next even if you queued other things
-- with 'a'); older mpv without "insert-next" falls back to appending.
local function queue_next(url)
    ensure_http_options()
    if not mp.commandv("loadfile", url, "insert-next") then
        mp.commandv("loadfile", url, "append")
    end
end

-- ---------- Continue Watching (virtual list) ----------
local cw_cache, cw_dirty = nil, true
mark_continue_dirty = function() cw_dirty = true end

-- Two kinds of rows: files you left part-way ("resume", newest first) and, per folder you have
-- been watching, the first not-yet-watched file after the last one you finished ("next").
get_continue_list = function()
    if not cw_dirty and cw_cache then return cw_cache end
    local resume, nxt = {}, {}

    for href, rec in pairs(watch_history) do
        if rec.pos and not watched_set[href] then
            table.insert(resume, {
                name = rec.name or U.basename(href), href = href, is_dir = false, cw = "resume",
                dirpath = rec.dirpath or U.dirname(href), ts = rec.last_played or 0,
            })
        end
    end
    table.sort(resume, function(a, b) return a.ts > b.ts end)

    local dirs = {}
    for href, v in pairs(watched_set) do
        local d = U.dirname(href)
        local ts = (type(v) == "number") and v or 0
        if not dirs[d] or ts > dirs[d] then dirs[d] = ts end
    end
    for d, ts in pairs(dirs) do
        local cached = find_cached_dir(d)
        if cached and type(cached.entries) == "table" then
            local media = {}
            for _, e in ipairs(cached.entries) do
                if not e.is_dir and U.is_media(e.name) then media[#media + 1] = e end
            end
            table.sort(media, function(a, b) return U.natural_less(a.name, b.name) end)
            local last_watched = 0
            for i, e in ipairs(media) do if watched_set[e.href] then last_watched = i end end
            for i = last_watched + 1, #media do
                local e = media[i]
                if watch_history[e.href] then break end            -- already listed above as "resume"
                if not watched_set[e.href] then
                    table.insert(nxt, {
                        name = e.name, href = e.href, is_dir = false, size = e.size, cw = "next",
                        dirpath = d, ts = ts,
                    })
                    break
                end
            end
        end
    end
    table.sort(nxt, function(a, b) return a.ts > b.ts end)

    local out = {}
    for _, e in ipairs(resume) do out[#out + 1] = e end
    for _, e in ipairs(nxt) do out[#out + 1] = e end
    while #out > o.continue_max_items do out[#out] = nil end
    cw_cache, cw_dirty = out, false
    return out
end

open_continue_view = function()
    current_path = CW_HREF
    file_entries = get_continue_list()
    selected_episode, scroll_offset_episodes = 1, 0
    free_scroll.episodes = false
    search_query, search_scope = "", nil
    status_line = "Continue Watching"
    if o.auto_focus_files_on_open then set_focus("episodes") end
    render()
end

-- 'm': manual watched / unwatched toggle (automatic tracking still works as before).
local function toggle_watched(entry)
    if not entry or entry.is_dir then return end
    if watched_set[entry.href] then
        watched_set[entry.href] = nil
        status_line = "Marked unwatched: " .. entry.name
    else
        watched_set[entry.href] = os.time()
        watch_history[entry.href] = nil
        status_line = "Marked watched: " .. entry.name
    end
    mark_continue_dirty()
    if current_path == CW_HREF then file_entries = get_continue_list(); after_files_set() end
    save_persistence()
    render()
end

-- Sidebar = tree nodes (all, or filtered if a sidebar-scoped search is active).
-- Episodes = files (optionally minus watched ones; filtered if an episodes-scoped search is active;
-- or the global index search results).
get_panel_items = function(panel_name)
    if panel_name == "sidebar" then
        if search_scope == "sidebar" and search_query ~= "" then
            return collect_matching_folders(search_query)
        end
        return flatten_visible()
    end
    if search_scope == "global" then return search_results end
    local base = file_entries
    if hide_watched and current_path ~= CW_HREF then
        local kept = {}
        for _, e in ipairs(base) do
            if not watched_set[e.href] then kept[#kept + 1] = e end
        end
        base = kept
    end
    if search_scope == "episodes" and search_query ~= "" then
        local toks = U.query_tokens(search_query)
        local out = {}
        for _, e in ipairs(base) do
            if U.match_score(e.name, toks) then out[#out + 1] = e end
        end
        return out
    end
    return base
end

-- Next MEDIA file after `current_href`, in natural filename order within that file's own folder
-- (from the cached listing) -- independent of what is on screen or how it is sorted, so
-- "Recent first" can never make auto-play go backwards.
find_next_media_href = function(current_href)
    local d = find_cached_dir(U.dirname(current_href))
    if not d or type(d.entries) ~= "table" then return nil end
    local media = {}
    for _, e in ipairs(d.entries) do
        if not e.is_dir and U.is_media(e.name) then media[#media + 1] = e end
    end
    table.sort(media, function(a, b) return U.natural_less(a.name, b.name) end)
    for i, e in ipairs(media) do
        if e.href == current_href then return media[i + 1] end
    end
    return nil
end

local loading_meta = nil   -- meta of the file most recently sent to loadfile (set before mpv confirms it opened)

play_entry = function(entry, append)
    if not append and MS.fb.active then MS.fb_stop(true) end
    local stream_url = file_stream_url(entry.href)
    local dirpath = U.dirname(entry.href)

    if append then
        -- Manual "queue" action ('a' key) - just append, no auto-chaining needed.
        pending_meta[stream_url] = { href = entry.href, name = entry.name, dirpath = dirpath }
        queue_load(stream_url, "append-play")
        status_line = "Queued: " .. entry.name
        return
    end

    -- Compute (once) what the NEXT episode would be, but don't queue it yet -
    -- it only gets queued once playback crosses prefetch_threshold_pct.
    local next_entry = o.autoplay_next and find_next_media_href(entry.href) or nil
    local meta = {
        href = entry.href, name = entry.name, dirpath = dirpath,
        next_queued = false,
        next_item = next_entry and { href = next_entry.href, name = next_entry.name } or nil,
    }
    pending_meta[stream_url] = meta
    loading_meta = meta

    queue_load(stream_url, "replace")
    status_line = "Playing: " .. entry.name
    if o.auto_close_on_play then close_pending_for = stream_url end
end

-- ============================================================
-- DOWNLOAD-WHILE-PLAYING FALLBACK
-- ============================================================
-- Some Real-Debrid links answer mpv's range requests (seeking to the end of an MKV to read its index)
-- with HTTP 503. A plain sequential download is not affected, so when streaming fails this downloads
-- the file with curl and plays the growing local file (ffmpeg's file "follow" mode) while it downloads.
MS.fb = { active = false }
MS.fb_dirty_files = {}

function MS.fb_dir()
    local d = tostring(o.fallback_dir or "")
    if d == "" then
        d = os.getenv("TEMP") or os.getenv("TMP") or os.getenv("TMPDIR") or "/tmp"
        d = d .. "/webdav-browser-cache"
    end
    d = d:gsub("\\", "/")
    return (d:gsub("/+$", ""))
end

function MS.fb_name(href, name)
    local h = 5381
    for i = 1, #href do h = (h * 33 + href:byte(i)) % 4294967296 end
    local safe = tostring(name or "video.mkv"):gsub("[^%w%._%-]", "_")
    return string.format("%08x_%s", h, safe)
end

function MS.fb_total(href)
    local c = find_cached_dir(U.dirname(href))
    if c and type(c.entries) == "table" then
        for _, e in ipairs(c.entries) do
            if e.href == href then return e.size end
        end
    end
    return nil
end

function MS.fb_remove(path)
    if not path then return end
    if not pcall(os.remove, path) then MS.fb_dirty_files[path] = true end
    local ok = io.open(path, "rb")
    if ok then ok:close(); MS.fb_dirty_files[path] = true else MS.fb_dirty_files[path] = nil end
end

-- Leftovers from earlier sessions (and files Windows would not let us delete while mpv had them open).
function MS.fb_purge()
    pcall(function()
        local dir = MS.fb_dir()
        local files = utils.readdir(dir, "files")
        if type(files) ~= "table" then return end
        local max_age = (tonumber(o.fallback_cleanup_hours) or 24) * 3600
        for _, f in ipairs(files) do
            local pth = dir .. "/" .. f
            local info = utils.file_info(pth)
            if info and info.mtime and (os.time() - info.mtime) > max_age then pcall(os.remove, pth) end
        end
    end)
end

function MS.fb_stop(delete_file)
    local fb = MS.fb
    if fb.timer then fb.timer:kill() end
    if fb.cmd then
        fb.killed = true
        pcall(mp.abort_async_command, fb.cmd)
    end
    local path = fb.path
    MS.fb = { active = false }
    if delete_file and path and not o.fallback_keep then MS.fb_remove(path) end
end

function MS.fb_say(text)
    mp.osd_message(text, 1.6)
    status_line = text
    if browser_active then render() end
end

function MS.fb_play()
    local fb = MS.fb
    fb.playing = true
    fb.restarts = (fb.restarts or 0) + 1
    fb.local_url = "ffmpeg://file:" .. fb.path
    pending_meta[fb.local_url] = fb.meta
    loading_meta = fb.meta
    queue_load(fb.local_url, "replace")
    if o.auto_close_on_play then close_pending_for = fb.local_url end
end

function MS.fb_tick()
    local fb = MS.fb
    if not fb.active then return end
    local info = utils.file_info(fb.path)
    local size = info and info.size or 0
    local now = U.now_s()
    local speed = 0
    if fb.last_t and now > fb.last_t then speed = math.max(0, (size - (fb.last_size or 0)) / (now - fb.last_t)) end
    fb.last_size, fb.last_t = size, now
    fb.size, fb.speed = size, speed

    local total = tonumber(fb.total) or 0
    local pct = (total > 0) and math.floor(size / total * 100) or nil
    local label = string.format("%s%s of %s%s", U.fmt_bytes(size), pct and (" (" .. pct .. "%)") or "",
        total > 0 and U.fmt_bytes(total) or "?", speed > 0 and ("  " .. U.fmt_bytes(speed) .. "/s") or "")

    if fb.failed and not fb.playing then
        local why = tostring(fb.err or "unknown error"):gsub("%s+$", "")
        MS.fb_stop(true)
        MS.fb_say("Download failed: " .. why:sub(1, 120))
        return
    end

    if not fb.playing then
        local need = math.floor((tonumber(o.fallback_start_mb) or 200) * 1048576)
        if total > 0 then need = math.min(need, total) end
        if size > 0 and (size >= need or fb.done) then
            MS.fb_say("Download-play: starting (" .. label .. ")")
            MS.fb_play()
        else
            MS.fb_say(string.format("Download-play: buffering %s  -  starts at %d MB", label, math.floor(need / 1048576)))
        end
        return
    end

    -- playing the growing file
    if fb.done and mp.get_property("path") ~= fb.local_url then
        MS.fb_stop(true)       -- finished and mpv has moved on / gone idle: clean up
        return
    end
    if fb.done then
        -- ffmpeg's "follow" keeps waiting at the end of the file; once the download is complete, move on.
        local pos, dur = mp.get_property_number("time-pos"), mp.get_property_number("duration")
        if pos and dur and dur > 0 and pos >= dur - 1.5 and mp.get_property("path") == fb.local_url then
            local pl_pos, pl_cnt = mp.get_property_number("playlist-pos"), mp.get_property_number("playlist-count")
            if pl_pos and pl_cnt and pl_pos + 1 < pl_cnt then mp.commandv("playlist-next", "force") else mp.commandv("stop") end
        end
    elseif fb.failed then
        if not fb.fail_told then
            fb.fail_told = true
            MS.fb_say("Download stopped (" .. tostring(fb.err or "error"):sub(1, 80) .. ") - playback may stall")
        end
    elseif mp.get_property_bool("core-idle") and speed >= 0 then
        mp.osd_message("Waiting for download: " .. label, 1.2)
    end
end

-- meta: { href, name, dirpath, next_item... }
function MS.fb_start(meta, reason)
    if not o.fallback_download or not meta or not meta.href then return false end
    if MS.fb.active then
        if MS.fb.href == meta.href then return true end
        MS.fb_stop(true)       -- a different file now needs the fallback (e.g. the next episode): the old download is done with
    end
    local path = MS.fb_dir() .. "/" .. MS.fb_name(meta.href, meta.name)
    MS.fb = {
        active = true, meta = meta, href = meta.href, path = path, total = MS.fb_total(meta.href),
        playing = false, done = false, failed = false, reason = reason,
    }
    local fb = MS.fb
    local args = { o.curl_path, "-s", "-S", "-L", "--create-dirs", "-C", "-", "--retry", "30", "--retry-delay", "3",
        "--connect-timeout", "15", "-o", path }
    if o.user_agent ~= "" then args[#args + 1] = "-A"; args[#args + 1] = o.user_agent end
    local stdin_data = nil
    if o.user ~= "" or o.pass ~= "" then
        if U.auth_mode() == "arg" then
            args[#args + 1] = "-u"; args[#args + 1] = o.user .. ":" .. o.pass
        else
            args[#args + 1] = "-K"; args[#args + 1] = "-"
            stdin_data = "user = " .. U.curl_quote(o.user .. ":" .. o.pass) .. "\n"
        end
    end
    args[#args + 1] = o.url .. meta.href
    fb.cmd = mp.command_native_async({
        name = "subprocess", args = args, stdin_data = stdin_data,
        capture_stdout = false, capture_stderr = true, playback_only = false,
    }, function(success, result)
        if MS.fb ~= fb or fb.killed then return end
        fb.cmd = nil
        if success and result and result.status == 0 then
            fb.done = true
        else
            fb.failed = true
            fb.err = (result and result.stderr and result.stderr ~= "" and result.stderr)
                or ("curl exited with status " .. tostring(result and result.status))
        end
    end)
    fb.timer = mp.add_periodic_timer(1, MS.fb_tick)
    MS.fb_say("Download-play: starting download...")
    return true
end

-- Manual 'p' key: skip streaming and use the download route for the selected file.
function MS.fb_manual(entry)
    if not entry or entry.is_dir or not U.is_media(entry.name) then return end
    if MS.fb.active then MS.fb_stop(true) end
    local next_entry = o.autoplay_next and find_next_media_href(entry.href) or nil
    local meta = {
        href = entry.href, name = entry.name, dirpath = U.dirname(entry.href), next_queued = false,
        next_item = next_entry and { href = next_entry.href, name = next_entry.name } or nil,
    }
    if not MS.fb_start_forced(meta) then status_line = "Download-play is disabled (fallback_download=no)" ; render() end
end
function MS.fb_start_forced(meta)
    local saved = o.fallback_download
    o.fallback_download = true
    local ok = MS.fb_start(meta, "manual")
    o.fallback_download = saved
    return ok
end

-- script-message webdav-browser-play <href> [download]
-- e.g. in input.conf:  F5 script-message webdav-browser-play /torrents/Show/ep1.mkv download
mp.register_script_message("webdav-browser-play", function(href, mode)
    if not MS.active then return end
    if not href or href == "" then return end
    local entry = { href = href, name = U.percent_decode(U.basename(href)), is_dir = false }
    if mode == "download" then MS.fb_manual(entry) else play_entry(entry, false) end
end)

-- Applies ffmpeg's "follow" mode to the local growing file (file-local, so nothing else is affected).
mp.add_hook("on_load", 40, function()
    local fb = MS.fb
    if not (fb.active and fb.local_url) then return end
    if (mp.get_property("stream-open-filename") or "") ~= fb.local_url then return end
    local rw = tostring(math.floor((tonumber(o.fallback_stall_secs) or 45) * 1000000))
    if not pcall(mp.set_property_native, "file-local-options/stream-lavf-o", { follow = "1", rw_timeout = rw }) then
        pcall(mp.set_property, "file-local-options/stream-lavf-o", "follow=1,rw_timeout=" .. rw)
    end
end)

-- ============================================================
-- NAVIGATION
-- ============================================================
move_selection = function(delta)
    local items = get_panel_items(focus_panel)
    if #items == 0 then return end
    free_scroll[focus_panel == "sidebar" and "sidebar" or "episodes"] = false
    if focus_panel == "sidebar" then
        sidebar_selected_index = math.max(1, math.min(#items, sidebar_selected_index + delta))
    else
        selected_episode = math.max(1, math.min(#items, selected_episode + delta))
    end
    render()
end

local function want_sidebar_frac()
    local f = tonumber(o.focused_width_pct) or 70
    f = math.max(55, math.min(80, f)) / 100
    if focus_panel == "sidebar" then return f end
    return 1 - f
end

local function stop_anim()
    if anim_timer then anim_timer:kill(); anim_timer = nil end
end

local function start_anim()
    if anim_timer then return end
    anim_timer = mp.add_periodic_timer(0.033, function()
        local target = want_sidebar_frac()
        local d = target - sidebar_frac
        if math.abs(d) < 0.003 then
            sidebar_frac = target
            stop_anim()
            render()
            return
        end
        sidebar_frac = sidebar_frac + d * 0.45
        render()
    end)
end

set_focus = function(panel)
    if focus_panel == panel then
        if math.abs(sidebar_frac - want_sidebar_frac()) > 0.01 then start_anim() end
        return
    end
    focus_panel = panel
    start_anim()
    render()
end

switch_panel = function()
    set_focus((focus_panel == "sidebar") and "episodes" or "sidebar")
end

-- Makes `href` (a folder) visible in the Folders panel by materialising its ancestors from the
-- cached listings and expanding them, then opens it. With `select_href`, that file is highlighted
-- in the Files panel once the listing is shown. Used by global-search results.
reveal_path = function(href, select_href)
    local chain, cur, guard = {}, href, 0
    while guard < 64 do
        guard = guard + 1
        local parent = U.dirname(cur)
        if parent == cur or #parent >= #cur then break end
        table.insert(chain, 1, parent)
        cur = parent
        if U.with_slash(parent) == U.with_slash(root_href) or parent == "/" then break end
    end
    if chain[1] ~= root_href and U.with_slash(chain[1] or "") ~= U.with_slash(root_href) then
        table.insert(chain, 1, root_href)
    end
    for _, a in ipairs(chain) do
        local c = find_cached_dir(a)
        if c and type(c.entries) == "table" then
            apply_dir_result(a, c.entries)
            if tree[a] then tree[a].expanded = true end
        end
    end

    search_query, search_scope, search_results = "", nil, {}
    pending_select_href = select_href
    local node = tree[href]
    if href == root_href or U.with_slash(href) == U.with_slash(root_href) then
        current_path = root_href
        selected_episode, scroll_offset_episodes = 1, 0
        show_dir(root_href, "Opening")
        node = nil
    elseif node then
        open_folder_node(node)
    else
        status_line = "That folder isn't in the cache yet - press R to refresh"
        render()
        return
    end
    if node then
        for i, n in ipairs(flatten_visible()) do
            if n.href == node.href then
                sidebar_selected_index = i
                free_scroll.sidebar = false
                break
            end
        end
    end
    set_focus(select_href and "episodes" or "sidebar")
    render()
end

-- reveal = true (Right arrow / l): jump to the folder that contains a search result instead of
-- playing it. Enter always plays files.
open_selected = function(reveal)
    if focus_panel == "sidebar" then
        local node = get_panel_items("sidebar")[sidebar_selected_index]
        if node then open_folder_node(node) end
        return
    end
    local item = get_panel_items("episodes")[selected_episode]
    if not item then return end
    if item.is_dir then
        reveal_path(item.href)
    elseif reveal and search_scope == "global" then
        reveal_path(U.dirname(item.href), item.href)
    else
        play_entry(item, false)
        render()
    end
end

-- Expand / collapse a folder WITHOUT opening it in the Files panel (the little arrow in the row).
local function toggle_expand(node)
    if not node or node.virtual then return end
    if node.expanded then
        node.expanded = false
        render()
        return
    end
    node.expanded = true
    if not node.loaded then
        local cached = dir_cache[node.href]
        if cached then
            apply_dir_result(node.href, cached.entries)
            if not cache_is_fresh(cached) then fetch_listing(node.href, { silent = true }) end
        else
            fetch_listing(node.href, { status = "Loading: " .. node.name })
        end
    end
    render()
end

collapse_or_parent = function()
    if focus_panel == "episodes" then
        set_focus("sidebar")
        return
    end
    local items = get_panel_items("sidebar")
    local node = items[sidebar_selected_index]
    if not node or node.virtual then return end

    if node.expanded and #node.children > 0 then
        node.expanded = false
        render()
        return
    end

    if node.parent_href then
        for i, n in ipairs(items) do
            if n.href == node.parent_href then
                sidebar_selected_index = i
                break
            end
        end
    end
    render()
end

queue_add_current = function()
    if focus_panel ~= "episodes" then return end
    local item = get_panel_items("episodes")[selected_episode]
    if item and not item.is_dir then play_entry(item, true); render() end
end

-- Sort order is remembered PER FOLDER (and saved). `s` toggles the folder shown in the Files panel;
-- with the Folders panel focused it toggles the highlighted folder's own listing (its sub-folders
-- and files). `target` lets the header button always address the open folder.
toggle_sort = function(target)
    if not target then
        if focus_panel == "sidebar" then
            local node = get_panel_items("sidebar")[sidebar_selected_index]
            target = (node and not node.virtual) and node.href or current_path
        else
            target = current_path
        end
    end
    if target == CW_HREF then return end
    local new_mode = (sort_mode_for(target) == "recent") and "name" or "recent"
    sort_by_dir[target] = new_mode

    local cached = find_cached_dir(target)
    if cached and type(cached.entries) == "table" then
        local files = apply_dir_result(target, cached.entries)
        if current_path == target then
            file_entries = files
            selected_episode, scroll_offset_episodes = 1, 0
            free_scroll.episodes = false
        end
    end
    local nm = U.basename(target)
    status_line = string.format("Sort (%s): %s", nm ~= "" and nm or "root", new_mode == "recent" and "Recent first" or "Name")
    debounced_save_persistence()
    render()
end

-- ============================================================
-- LIBRARY INDEX  (background crawl feeding the global search, key 'f')
-- ============================================================
-- The "index" is simply the directory cache: the crawler walks the library breadth-first, ONE
-- request at a time with a pause in between (gentle on the server), and stores every listing in
-- dir_cache, which is saved to disk. Global search then scans those cached listings, so it is
-- instant and works across restarts. Folders whose cached listing is younger than
-- index_refresh_hours are not re-fetched; 'R' forces a complete re-crawl.
local IDX = {
    running = false, force = false, queue = {}, head = 1, scanned = 0, fetched = 0,
    errors = 0, consecutive_errors = 0, started = nil, last_stop = nil, autostart_armed = false,
}

function IDX.count_items()
    local dirs, items = 0, 0
    for _, c in pairs(dir_cache) do
        if type(c.entries) == "table" then dirs = dirs + 1; items = items + #c.entries end
    end
    return dirs, items
end

function IDX.finish(complete, reason)
    IDX.running = false
    MS.idx_running = false
    MS.cache_version = MS.cache_version + 1      -- make sure the final index state is searchable
    IDX.last_stop = os.time()
    if complete then
        index_meta.last_full = os.time()
        IDX.last_reason = "complete"
    else
        IDX.last_reason = reason or "stopped"
    end
    save_persistence()
    if browser_active then
        if search_scope == "global" then run_global_search_hook() end
        render()
    end
end

function IDX.step()
    if not IDX.running then return end
    if IDX.head > #IDX.queue then IDX.finish(true); return end
    if IDX.scanned >= o.index_max_dirs then IDX.finish(false, "folder limit reached"); return end
    if IDX.consecutive_errors >= 5 then IDX.finish(false, "stopped after repeated errors"); return end

    local href = IDX.queue[IDX.head]
    IDX.head = IDX.head + 1
    IDX.scanned = IDX.scanned + 1

    local function enqueue_children(entries)
        for _, e in ipairs(entries) do
            if e.is_dir then IDX.queue[#IDX.queue + 1] = e.href end
        end
    end
    local function next_step(delay) mp.add_timeout(delay, IDX.step) end

    local cached = dir_cache[href]
    local max_age = o.index_refresh_hours * 3600
    local fresh_enough = cached and not cached.stale and type(cached.entries) == "table"
        and (os.time() - (cached.ts or 0)) < max_age
    if fresh_enough and not IDX.force then
        enqueue_children(cached.entries)
        next_step(0.002)          -- no network involved: keep going right away
        return
    end

    fetch_listing(href, { silent = true }, function(ok)
        if not IDX.running then return end
        if ok then
            IDX.fetched = IDX.fetched + 1
            IDX.consecutive_errors = 0
            local c = dir_cache[href]
            if c then enqueue_children(c.entries) end
        else
            IDX.errors = IDX.errors + 1
            IDX.consecutive_errors = IDX.consecutive_errors + 1
        end
        if browser_active and search_scope == "global" then
            run_global_search_hook()
            render()
        end
        next_step(math.max(0.05, o.index_delay_secs))
    end)
end

index_start = function(force)
    if not o.index_enabled or o.url == "" then return end
    if IDX.running then
        if force then IDX.force = true end
        return
    end
    IDX.running, IDX.force = true, force and true or false
    MS.idx_running = true
    IDX.queue, IDX.head = { root_href }, 1
    IDX.scanned, IDX.fetched, IDX.errors, IDX.consecutive_errors = 0, 0, 0, 0
    IDX.started, IDX.last_reason = os.time(), nil
    if browser_active then status_line = force and "Re-indexing the library..." or "Indexing the library in the background..." end
    mp.add_timeout(0.05, IDX.step)
    if browser_active then render() end
end

index_stop = function()
    if IDX.running then IDX.finish(false, "stopped") end
end

-- One-line description for the footer / debug panel.
function IDX.summary()
    local dirs, items = IDX.count_items()
    if IDX.running then
        return string.format("Indexing: %d folder%s visited, %d item%s", IDX.scanned, IDX.scanned == 1 and "" or "s",
            items, items == 1 and "" or "s")
    end
    if o.index_mode ~= "full" then
        return string.format("Search covers %d folder%s you've opened (%d items)", dirs, dirs == 1 and "" or "s", items)
    end
    if index_meta.last_full then
        return string.format("Index: %d items in %d folders - updated %s", items, dirs, U.fmt_age(index_meta.last_full))
    end
    return string.format("Index: %d items cached so far (full crawl not finished yet)", items)
end

-- Starts a crawl automatically (once per browser session) when the index is stale/missing.
function IDX.maybe_autostart()
    if not (o.index_enabled and o.index_auto_update and o.index_mode == "full") or IDX.autostart_armed or IDX.running then return end
    local age_ok = index_meta.last_full and (os.time() - index_meta.last_full) < o.index_refresh_hours * 3600
    if age_ok then return end
    IDX.autostart_armed = true
    mp.add_timeout(o.index_start_delay_secs, function()
        IDX.autostart_armed = false
        if o.index_enabled and not IDX.running then index_start(false) end
    end)
end

-- ============================================================
-- SEARCH
-- ============================================================
MS.global_total = 0           -- total matches before the index_max_results cut-off
MS.flat, MS.flat_built_at, MS.flat_version, MS.cache_version = nil, 0, -1, 0

-- "ep2" sorts before "ep10": zero-pad digit runs so plain string comparison gives natural order
local function pad_digits(s)
    return (s:gsub("%d+", function(d) return (#d < 8) and (string.rep("0", 8 - #d) .. d) or d end))
end

-- Flat, pre-sorted copy of every cached entry (normalised name + sort key). Built once per cache
-- change, so a keystroke is just a linear scan with no sorting.
local function build_flat()
    local flat, n = {}, 0
    for dirhref, c in pairs(dir_cache) do
        if type(c.entries) == "table" then
            for _, e in ipairs(c.entries) do
                local hay = U.norm_text(e.name)
                n = n + 1
                flat[n] = { hay = hay, key = pad_digits(hay), e = e, dir = dirhref }
            end
        end
    end
    table.sort(flat, function(a, b) return a.key < b.key end)
    MS.flat, MS.flat_version, MS.flat_built_at = flat, MS.cache_version, U.now_s()
end

local function run_global_search()
    search_results, MS.global_total = {}, 0
    local toks = U.query_tokens(search_query)
    if #toks == 0 then return end
    -- rebuild when the cache changed (while a crawl is running: at most every 4 s, so typing stays smooth)
    if not MS.flat or (MS.flat_version ~= MS.cache_version and (not MS.idx_running or U.now_s() - MS.flat_built_at > 4)) then
        build_flat()
    end
    local maxr = o.index_max_results
    local buckets, maxscore, total = {}, 0, 0
    for _, it in ipairs(MS.flat) do
        local hay, score, hit = it.hay, 0, true
        for _, tok in ipairs(toks) do
            local pos = hay:find(tok, 1, true)
            if not pos then hit = false; break end
            score = score + ((hay:sub(pos - 1, pos - 1) == " ") and 3 or 1)
        end
        if hit then
            total = total + 1
            local bucket = buckets[score]
            if not bucket then
                bucket = {}
                buckets[score] = bucket
                if score > maxscore then maxscore = score end
            end
            if #bucket < maxr then bucket[#bucket + 1] = it end   -- already in name order; never need more than maxr
        end
    end
    MS.global_total = total
    local out = {}
    for score = maxscore, 0, -1 do
        local bucket = buckets[score]
        if bucket then
            for _, it in ipairs(bucket) do
                if #out >= maxr then break end
                out[#out + 1] = {
                    name = it.e.name, href = it.e.href, is_dir = it.e.is_dir,
                    size = it.e.size, mtime = it.e.mtime, dirpath = it.dir,
                }
            end
        end
        if #out >= maxr then break end
    end
    search_results = out
end
run_global_search_hook = run_global_search

local function search_reset_selection()
    if search_scope == "sidebar" then
        sidebar_selected_index, scroll_offset_folders = 1, 0
    else
        selected_episode, scroll_offset_episodes = 1, 0
    end
    free_scroll.sidebar, free_scroll.episodes = false, false
end

local function search_hint()
    if search_scope == "global" then return "Type to search the folders you have opened" end
    return "Type to filter " .. (search_scope == "sidebar" and "folders" or "files")
end

-- scope: "sidebar" | "episodes" | "global" (nil = the focused panel)
start_search = function(scope)
    if not browser_active or search_active then return end
    scope = scope or focus_panel
    search_query = ""   -- every new search starts empty (the old query used to linger and look like a dead search box)
    search_results, MS.global_total = {}, 0
    search_scope = scope
    search_active = true
    if scope == "global" then
        set_focus("episodes")
        run_global_search()
        IDX.maybe_autostart()
    end
    search_reset_selection()
    unbind_all()
    bind_search()
    status_line = search_hint() .. " - Enter to confirm, Esc to cancel"
    render()
end

confirm_search = function()
    search_active = false
    unbind_search()
    bind_all()
    search_reset_selection()
    if search_scope == "global" then
        status_line = string.format('Search "%s": %d result%s', search_query, MS.global_total, MS.global_total == 1 and "" or "s")
        set_focus("episodes")
    else
        status_line = (search_query ~= "") and string.format('Filter: "%s"', search_query) or "Ready"
    end
    render()
end

cancel_search = function()
    search_active = false
    search_query = ""
    search_scope = nil
    search_results, MS.global_total = {}, 0
    unbind_search()
    bind_all()
    selected_episode, scroll_offset_episodes = 1, 0
    sidebar_selected_index, scroll_offset_folders = 1, 0
    status_line = "Ready"
    render()
end

search_append = function(ch)
    search_query = search_query .. ch
    if search_scope == "global" then run_global_search() end
    search_reset_selection()
    render()
end

search_backspace = function()
    if #search_query > 0 then
        search_query = U.utf8_pop(search_query)
        if search_scope == "global" then run_global_search() end
        search_reset_selection()
        render()
    end
end

-- ============================================================
-- DRAWING PRIMITIVES  (PlayRes pixels; \fs18 => 1 draw unit = 1 px)
-- ============================================================
function D.style_text(fs)
    return string.format("\\bord0\\shad0\\q2\\fn%s\\fs%d", o.font_name, fs or o.font_size)
end

function D.ev_text(x, y, an, extra, str)
    return string.format("{\\an%d\\pos(%d,%d)%s%s}%s",
        an, math.floor(x), math.floor(y), D.style_text(o.font_size), extra or "", str)
end

function D.rd(v) return math.floor(v + 0.5) end

function D.rect_path(x1, y1, x2, y2)
    x1, y1, x2, y2 = D.rd(x1), D.rd(y1), D.rd(x2), D.rd(y2)
    return string.format("m %d %d l %d %d l %d %d l %d %d", x1, y1, x2, y1, x2, y2, x1, y2)
end

function D.rounded_path(x1, y1, x2, y2, r)
    r = math.max(0, math.min(r, (x2 - x1) / 2, (y2 - y1) / 2))
    if r < 1 then return D.rect_path(x1, y1, x2, y2) end
    local k = r * 0.5522847
    return table.concat({
        string.format("m %d %d",   D.rd(x1 + r), D.rd(y1)),
        string.format("l %d %d",   D.rd(x2 - r), D.rd(y1)),
        string.format("b %d %d %d %d %d %d", D.rd(x2 - r + k), D.rd(y1), D.rd(x2), D.rd(y1 + r - k), D.rd(x2), D.rd(y1 + r)),
        string.format("l %d %d",   D.rd(x2), D.rd(y2 - r)),
        string.format("b %d %d %d %d %d %d", D.rd(x2), D.rd(y2 - r + k), D.rd(x2 - r + k), D.rd(y2), D.rd(x2 - r), D.rd(y2)),
        string.format("l %d %d",   D.rd(x1 + r), D.rd(y2)),
        string.format("b %d %d %d %d %d %d", D.rd(x1 + r - k), D.rd(y2), D.rd(x1), D.rd(y2 - r + k), D.rd(x1), D.rd(y2 - r)),
        string.format("l %d %d",   D.rd(x1), D.rd(y1 + r)),
        string.format("b %d %d %d %d %d %d", D.rd(x1), D.rd(y1 + r - k), D.rd(x1 + r - k), D.rd(y1), D.rd(x1 + r), D.rd(y1)),
    }, " ")
end

function D.ev_shape(path, fill_rgb, fill_a, border_rgb, border_a, border_w)
    local tags = string.format("\\fs18\\bord%d\\shad0\\1c%s\\1a%s",
        border_w or 0, U.ass_color(fill_rgb), U.ass_alpha(fill_a or 100))
    if border_rgb and border_w and border_w > 0 then
        tags = tags .. "\\3c" .. U.ass_color(border_rgb) .. "\\3a" .. U.ass_alpha(border_a or 100)
    else
        tags = tags .. "\\3a&HFF&"
    end
    return string.format("{\\an7\\pos(0,0)%s\\p1}%s{\\p0}", tags, path)
end

function D.ev_rect(x1, y1, x2, y2, fill_rgb, fill_a, border_rgb, border_a, border_w, radius)
    if x2 <= x1 or y2 <= y1 then return "" end
    local path = (radius and radius > 0) and D.rounded_path(x1, y1, x2, y2, radius) or D.rect_path(x1, y1, x2, y2)
    return D.ev_shape(path, fill_rgb, fill_a, border_rgb, border_a, border_w)
end

function D.clip_tag(x1, y1, x2, y2)
    return string.format("\\clip(%d,%d,%d,%d)", math.floor(x1), math.floor(y1), math.floor(x2), math.floor(y2))
end

-- ===== LiquidGlass-style gradient border + top glass highlight =====
-- libass can't stroke a shape with a true gradient, so we fake a vertical
-- light->dark->light border (same idea as LiquidGlass's LinearGradientBrush)
-- by drawing the SAME border-only outline three times, each clipped to a
-- horizontal band of the panel with its own flat color.
function D.ev_border_pass(path, border_rgb, border_a, border_w, clip)
    local tags = string.format("\\fs18\\bord%d\\shad0\\1a&HFF&\\3c%s\\3a%s%s",
        border_w or 1, U.ass_color(border_rgb), U.ass_alpha(border_a or 100), clip or "")
    return string.format("{\\an7\\pos(0,0)%s\\p1}%s{\\p0}", tags, path)
end

function D.draw_gradient_border(chunks, x1, y1, x2, y2, radius, border_w, colors, alpha)
    if not border_w or border_w <= 0 then return end
    local path = D.rounded_path(x1, y1, x2, y2, radius)
    local h = y2 - y1
    local pad = border_w + 2
    local bands = {
        { y1 - pad,          y1 + h * 0.32, colors[1] },
        { y1 + h * 0.32,     y1 + h * 0.68, colors[2] },
        { y1 + h * 0.68,     y2 + pad,      colors[3] },
    }
    for _, band in ipairs(bands) do
        local clip = D.clip_tag(x1 - pad, band[1], x2 + pad, band[2])
        table.insert(chunks, D.ev_border_pass(path, band[3], alpha, border_w, clip))
    end
end

-- Thin bright line just inside the top edge, simulating light catching the
-- top of a glass panel. Inset horizontally so it doesn't poke out of the
-- rounded corners. border_w should match whatever border width THIS panel is
-- currently using (focused vs unfocused), so the highlight sits flush against
-- its own border instead of a hardcoded one.
function D.draw_glass_highlight(chunks, x1, y1, x2, y2, radius, border_w)
    local inset = math.max(6, radius)
    local hy1 = y1 + math.max(1, border_w or 1)
    table.insert(chunks, D.ev_rect(x1 + inset, hy1, x2 - inset, hy1 + 1.6,
        "FFFFFF", U.pick(o.glass_highlight_opacity, 14), nil, 0, 0, 1))
end

local function build_breadcrumb(path, max_px)
    local parts = {}
    for seg in path:gmatch("[^/]+") do table.insert(parts, U.percent_decode(seg)) end
    local s = "root" .. (#parts > 0 and (" / " .. table.concat(parts, " / ")) or "")
    return U.fit_text(s, max_px, o.font_size - 6)
end

-- Renders the search UI for one panel's second header line.
-- big=true  -> actively typing: large font + accent pill, unmistakable.
-- big=false -> confirmed filter: small warn-colored chip, unobtrusive.
--
-- NOTE: the icon is deliberately kept at NORMAL weight (\b0) even inside the
-- otherwise-bold "big" box. Forcing \b1 on an emoji glyph makes libass hunt
-- for a bold variant of the UI font, which usually doesn't have that emoji,
-- so it silently falls back to some other glyph/font (this was the "wrong
-- search icon" bug).
local function draw_search_indicator(chunks, rect, y, match_count, big)
    local clip = D.clip_tag(rect.x1, rect.y1, rect.x2, rect.y1 + layout.panel_header_h)
    if big then
        local fs_big = layout.fs_big
        local pad = 8
        table.insert(chunks, D.ev_rect(rect.x1 + pad, y - fs_big * 0.72, rect.x2 - pad, y + fs_big * 0.5,
            THEME.accent, 16, THEME.accent, 55, 1, o.corner_radius_small))
        local text = string.format("{\\b0}%s{\\b1} %s▏", ICONS.search, U.ass_escape(search_query))
        table.insert(chunks, D.ev_text(rect.x1 + pad + 10, y, 4,
            string.format("%s\\b1\\fs%d\\c%s", clip, fs_big, U.ass_color(THEME.accent)), text))
        table.insert(chunks, D.ev_text(rect.x2 - pad - 10, y, 6,
            string.format("%s\\fs%d\\c%s", clip, layout.fs - 4, U.ass_color(THEME.text_muted)),
            string.format("%d match%s", match_count, (match_count == 1) and "" or "es")))
    else
        table.insert(chunks, D.ev_text(rect.x1 + 12, y, 4,
            string.format("%s\\fs%d\\c%s", clip, layout.fs - 6, U.ass_color(THEME.warn)),
            string.format('%s "%s" - %d match%s (Esc to clear)', ICONS.search, U.ass_escape(search_query),
                match_count, (match_count == 1) and "" or "es")))
    end
end

-- ============================================================
-- LAYOUT
-- ============================================================
local function visible_rows_for(rect, panel_header_h, row_h)
    local body = rect.y2 - rect.y1 - panel_header_h - 8
    return math.max(1, math.floor(body / row_h))
end

local function compute_layout()
    local w, h = U.canvas_size()
    overlay.res_x = w
    overlay.res_y = h

    local pad, gap = 12, 10
    local header_h = 52
    local footer_h = 58
    local inner_x1, inner_x2 = pad, w - pad
    local inner_w = inner_x2 - inner_x1
    local inner_y1 = header_h + 8
    local inner_y2 = h - footer_h - 8

    local usable = inner_w - gap
    local min_w = math.max(170, math.floor(usable * 0.18))
    local sb_w = math.floor(usable * sidebar_frac)
    sb_w = math.max(min_w, math.min(usable - min_w, sb_w))

    local fs = o.font_size
    local fs_big = fs + (tonumber(o.search_font_boost) or 8)

    -- Baseline (non-search) header height: unchanged from previous versions.
    local base_header_h = math.max(50, math.floor(fs * 2.6))

    -- Default sub-line (breadcrumb / file-count / confirmed-chip) position.
    local sub_line_y = 36
    local panel_header_h = base_header_h

    -- While ACTIVELY TYPING, the search pill uses fs_big (bigger font) and
    -- must be pushed below the title text with enough clearance, otherwise it
    -- visually overlaps the title above it and the row list below it (this
    -- was the "search mixing with names" bug). Only grows the header for the
    -- duration of active typing - confirmed/quiet chip mode is unaffected.
    if search_active then
        local title_bottom = 16 + fs * 0.55
        local sub_h = fs_big * 1.35
        local sub_gap = 10
        sub_line_y = title_bottom + sub_gap + sub_h / 2
        panel_header_h = math.max(base_header_h, math.floor(sub_line_y + sub_h / 2 + 10))
    end

    return {
        w = w, h = h,
        header_h = header_h, footer_h = footer_h,
        sidebar = { x1 = inner_x1, y1 = inner_y1, x2 = inner_x1 + sb_w, y2 = inner_y2 },
        list    = { x1 = inner_x1 + sb_w + gap, y1 = inner_y1, x2 = inner_x2, y2 = inner_y2 },
        row_h = math.max(28, math.floor(fs * 1.95)),
        panel_header_h = panel_header_h,
        sub_line_y = math.floor(sub_line_y),
        fs_big = fs_big,
        fs = fs,
        scroll_info = {},   -- panel -> { n, vis, max_scroll }     (filled by keep_selection_in_view)
        scrollbars = {},    -- panel -> track / thumb / hit rectangles (filled by draw_scrollbar)
    }
end

local function keep_selection_in_view()
    if not layout then return end
    for _, panel in ipairs({ "sidebar", "episodes" }) do
        local items = get_panel_items(panel)
        local rect = (panel == "sidebar") and layout.sidebar or layout.list
        local vis = visible_rows_for(rect, layout.panel_header_h, layout.row_h)
        local sel = (panel == "sidebar") and sidebar_selected_index or selected_episode
        local scroll = (panel == "sidebar") and scroll_offset_folders or scroll_offset_episodes
        local n = #items
        if n < 1 then
            sel, scroll = 1, 0
            layout.scroll_info[panel] = { n = 0, vis = vis, max_scroll = 0 }
        else
            sel = math.max(1, math.min(n, sel))
            local max_scroll = math.max(0, n - vis)
            -- After wheel / scrollbar use the view is "free": it stays where the user put it and
            -- only snaps back to the selection once the selection moves (see move_selection).
            if not free_scroll[panel] then
                local margin = (n > vis) and 1 or 0
                if sel < scroll + 1 + margin then scroll = sel - 1 - margin end
                if sel > scroll + vis - margin then scroll = sel - vis + margin end
            end
            scroll = math.max(0, math.min(max_scroll, scroll))
            layout.scroll_info[panel] = { n = n, vis = vis, max_scroll = max_scroll }
        end
        if panel == "sidebar" then
            sidebar_selected_index, scroll_offset_folders = sel, scroll
        else
            selected_episode, scroll_offset_episodes = sel, scroll
        end
    end
end

-- ============================================================
-- ROW DRAWING
-- ============================================================
local function draw_scrollbar(chunks, rect, header_h, scroll, n_items, n_vis, panel)
    if n_items <= n_vis then return end
    local x2 = rect.x2 - 5
    local x1 = x2 - 4
    local y1 = rect.y1 + header_h + 4
    local y2 = rect.y2 - 6
    local track_h = y2 - y1
    if track_h < 10 then return end
    local thumb_h = math.max(16, track_h * n_vis / n_items)
    local max_scroll = n_items - n_vis
    local thumb_y = y1 + (track_h - thumb_h) * (scroll / math.max(1, max_scroll))
    local dragging = MS.drag and MS.drag.panel == panel
    local hot = dragging or (MS.hover_sb == panel)
    local bx1 = hot and (x1 - 2) or x1
    table.insert(chunks, D.ev_rect(bx1, y1, x2, y2, THEME.track, hot and 100 or 100, nil, 0, 0, o.corner_radius_small))
    table.insert(chunks, D.ev_rect(bx1, thumb_y, x2, thumb_y + thumb_h, THEME.accent, hot and 100 or 80, nil, 0, 0, o.corner_radius_small))
    local half = math.floor(o.scrollbar_hit_px / 2)
    layout.scrollbars[panel] = {
        hx1 = x2 - o.scrollbar_hit_px, hx2 = rect.x2, y1 = y1, y2 = y2,
        ty1 = thumb_y, ty2 = thumb_y + thumb_h, track_h = track_h, thumb_h = thumb_h,
        max_scroll = max_scroll, n = n_items, vis = n_vis,
    }
end

-- ============================================================
-- CLEAN TITLES (experimental_clean_titles)
-- ============================================================
-- "The.Gentlemen.S02E03.2160p.NF.WEB-DL.DV.HDR.Atmos.H.265-GRP.mkv"  ->  "S02E03" + [4K] [HDR] [DV] [ATMOS]
-- Everything is wrapped in pcall; if a name can't be parsed the raw name is shown unchanged.
local CT = { cache = {}, count = 0 }

CT.TOKENS = {
    "2160p", "1080p", "1080i", "720p", "480p", "4k", "uhd", "bluray", "blu%-ray", "bdrip", "brrip",
    "web%-dl", "webdl", "webrip", "hdtv", "dvdrip", "remux", "x264", "x265", "h264", "h265", "hevc",
    "av1", "hdr", "dovi", "atmos", "dts", "ddp", "dd%+",
}

function CT.parse_raw(name)
    local base = name
    local ext = U.ext_of(name)
    if ext and (U.video_exts[ext:lower()] or U.audio_exts[ext:lower()]) then
        base = name:sub(1, #name - #ext - 1)
    end
    local lower = base:lower()

    -- season/episode token: must start a "word" (so "class01e02" doesn't match)
    local cut, se_label = nil, nil
    local init = 1
    while true do
        local a, _, s, e = lower:find("s(%d%d?)e(%d%d%d?)", init)
        if not a then break end
        if a == 1 or not lower:sub(a - 1, a - 1):match("%w") then
            se_label = string.format("S%02dE%02d", tonumber(s), tonumber(e))
            cut = a - 1
            break
        end
        init = a + 1
    end
    if not se_label then   -- anime style: "Show Name - 03 [1080p]"
        local a, _, e = lower:find("%s%-%s(%d%d%d?)[%s%[%(%.]")
        if a then se_label = string.format("E%02d", tonumber(e)); cut = a - 1 end
    end

    if not se_label then
        -- absolute numbering: "Show.2009.004.1080p.BD" / "Show - 004 [1080p]" -> E04. A bare 3-4 digit number counts only when
        -- a year came before it or a quality tag follows it, so "The.300.Spartans.1962" is left alone.
        local skipv = { [480] = true, [576] = true, [720] = true, [1080] = true, [1440] = true, [2160] = true, [4320] = true }
        local init3, year_seen, year_pos = 1, nil, nil
        while true do
            local a, _, n = lower:find("[%._%s%-%[%(](%d%d%d%d?)[%._%s%-%]%)]", init3)
            if not a then break end
            local v = tonumber(n)
            local sep, pc = lower:sub(a, a), lower:sub(a - 1, a - 1)
            if not (sep == "." and (pc == "h" or pc == "x")) and not skipv[v] then
                if #n == 4 and v >= 1900 and v <= 2099 then
                    if not year_seen then year_seen, year_pos = n, a end
                else
                    local nxt = lower:sub(a + #n + 1, a + #n + 14)
                    local qual = nxt:find("^[%[%(]?%d%d%d%d?p") or nxt:find("^[%[%(]?bd") or nxt:find("^[%[%(]?web")
                        or nxt:find("^[%[%(]?x26") or nxt:find("^[%[%(]?hevc") or nxt:find("^[%[%(]?blu") or nxt:find("^[%[%(]?dvd")
                    if year_seen or qual then
                        se_label = string.format("E%02d", v)
                        cut = (year_pos or a) - 1
                        year = year_seen
                        break
                    end
                end
            end
            init3 = a + 1
        end
    end
    if not cut then
        local init2 = 1
        while true do
            local a, _, y = lower:find("[%._%s%(%[](%d%d%d%d)[%._%s%)%]]", init2)
            if not a then break end
            if y:sub(1, 2) == "19" or y:sub(1, 2) == "20" then year = y; cut = a - 1; break end
            init2 = a + 1
        end
    end
    if not cut then
        local best
        for _, tok in ipairs(CT.TOKENS) do
            local a = lower:find("[%._%s%-%[%(]" .. tok)
            if a and (not best or a < best) then best = a end
        end
        if best then cut = best - 1 end
    end
    if not cut and not se_label then return false end

    local title = base:sub(1, cut or #base)
    title = title:gsub("^%b[]%s*", "")
    title = title:gsub("[%._]+", " "):gsub("%s+", " "):gsub("^[%s%-]+", ""):gsub("[%s%-%(%[]+$", "")
    if title == "" and not se_label then return false end

    local chips = {}
    local function has(pat) return lower:find(pat) ~= nil end
    if has("2160p") or has("%f[%w]4k%f[%W]") or has("%f[%a]uhd%f[%A]") then chips[#chips + 1] = "4K"
    elseif has("1080[pi]") then chips[#chips + 1] = "1080p"
    elseif has("720p") then chips[#chips + 1] = "720p"
    elseif has("480p") then chips[#chips + 1] = "480p" end
    if has("hdr10%+") or has("hdr10plus") then chips[#chips + 1] = "HDR10+"
    elseif has("%f[%a]hdr%f[%A]") then chips[#chips + 1] = "HDR" end
    if has("%f[%a]dv%f[%A]") or has("dovi") or has("dolby[%._%s%-]?vision") then chips[#chips + 1] = "DV" end
    if has("atmos") then chips[#chips + 1] = "ATMOS" end
    if has("remux") then chips[#chips + 1] = "REMUX" end
    if has("dual[%._%s%-]?audio") then chips[#chips + 1] = "DUAL" end

    return {
        title = title, se = se_label, year = year, chips = chips,
        label = se_label or (title .. (year and (" (" .. year .. ")") or "")),
    }
end

function CT.parse(name)
    local hit = CT.cache[name]
    if hit ~= nil then return hit end
    local ok, res = pcall(CT.parse_raw, name)
    if not ok then res = false end
    CT.count = CT.count + 1
    if CT.count > 6000 then CT.cache, CT.count = {}, 1 end
    CT.cache[name] = res
    return res
end

-- true when every parsed media file in the list shares one show title (then the title is redundant
-- on each row and only "S01E03" is shown)
function CT.uniform_title(items)
    local first, seen = nil, 0
    for _, it in ipairs(items) do
        if not it.is_dir and U.is_media(it.name) then
            local cp = CT.parse(it.name)
            if cp then
                local tl = cp.title:lower()
                if first == nil then first = tl elseif first ~= tl then return false end
                seen = seen + 1
                if seen >= 60 then break end
            end
        end
    end
    return true
end

-- ---- folder names: "MASHLE.MAGIC.AND.MUSCLES.S01.1080p.BluRay.REMUX.AVC.FLAC.2.0-NAN0" ----
--   -> title "Mashle Magic and Muscles", season "S01", chips {1080p, REMUX}, group "NAN0"
CT.GROUP_BLOCK = { dl = true, hd = true, rip = true, ma = true, hdr = true, dv = true, webdl = true, hevc = true,
    x264 = true, x265 = true, h264 = true, h265 = true, avc = true, aac = true, dts = true, ac3 = true, flac = true }
CT.SMALL_WORDS = { a = true, an = true, ["and"] = true, as = true, at = true, but = true, by = true, ["for"] = true,
    ["in"] = true, of = true, on = true, ["or"] = true, the = true, to = true, vs = true }

-- Only names that are ALL upper or ALL lower case get re-cased; mixed case is how the release was named.
function CT.titlecase(str)
    if str:find("%l") and str:find("%u") then return str end
    local out, first = {}, true
    for w in str:gmatch("%S+") do
        local lw = w:lower()
        if not first and CT.SMALL_WORDS[lw] then out[#out + 1] = lw
        else out[#out + 1] = lw:sub(1, 1):upper() .. lw:sub(2) end
        first = false
    end
    return table.concat(out, " ")
end

function CT.chips_for(lower)
    local chips = {}
    local function has(pat) return lower:find(pat) ~= nil end
    if has("2160p") or has("%f[%w]4k%f[%W]") or has("%f[%a]uhd%f[%A]") then chips[#chips + 1] = "4K"
    elseif has("1080[pi]") then chips[#chips + 1] = "1080p"
    elseif has("720p") then chips[#chips + 1] = "720p"
    elseif has("480p") then chips[#chips + 1] = "480p" end
    if has("hdr10%+") or has("hdr10plus") then chips[#chips + 1] = "HDR10+"
    elseif has("%f[%a]hdr%f[%A]") then chips[#chips + 1] = "HDR" end
    if has("%f[%a]dv%f[%A]") or has("dovi") or has("dolby[%._%s%-]?vision") then chips[#chips + 1] = "DV" end
    if has("atmos") then chips[#chips + 1] = "ATMOS" end
    if has("remux") then chips[#chips + 1] = "REMUX" end
    if has("dual[%._%s%-]?audio") then chips[#chips + 1] = "DUAL" end
    return chips
end

function CT.parse_folder_raw(name)
    local base = name
    local group
    local lead = base:match("^%[([^%]]+)%]")                 -- anime style: "[SubsPlease] Show ..."
    if lead and #lead >= 2 and #lead <= 24 then group = lead end
    local body = base:gsub("^%b[]%s*", "")
    body = body:gsub("%s*%b[]%s*$", "")                       -- trailing [site]/[hash] tags
    body = body:gsub("\234\158\137", ":")                      -- U+A789 (a colon look-alike used in file names) -> ":"
    local g = body:match("%-([%w_]+)$")                       -- scene style: "...-GROUP"
    if g and not group and #g >= 2 and #g <= 20 and not CT.GROUP_BLOCK[g:lower()] and not g:match("^%d+$") then
        group = g
        body = body:sub(1, #body - #g - 1)
    end

    local lower = body:lower()
    local ls = lower .. "."
    local cut, season, year
    local function mark(a) if a and (not cut or a < cut) then cut = a end end

    local a, _, s1, s2 = ls:find("[%._%s%(%[%-]s(%d%d?)%-s?(%d%d?)[%._%s%)%]%-]")
    if a then season = string.format("S%02d-S%02d", tonumber(s1), tonumber(s2)); mark(a) end
    if not season then
        local b, _, sn, ep = ls:find("[%._%s%(%[%-]s(%d%d?)e(%d%d%d?)[%._%s%)%]%-]")
        if b then season = string.format("S%02dE%02d", tonumber(sn), tonumber(ep)); mark(b) end
    end
    if not season then
        local b, _, sn = ls:find("[%._%s%(%[%-]s(%d%d?)[%._%s%)%]%-]")
        if b then season = string.format("S%02d", tonumber(sn)); mark(b) end
    end
    if not season then
        local b, _, sn = ls:find("[%._%s%(%[%-]season[%._%s]*(%d%d?)[%._%s%)%]%-]")
        if b then season = string.format("S%02d", tonumber(sn)); mark(b) end
    end
    local ca = ls:find("[%._%s%(%[%-]complete[%._%s%)%]%-]")
    if ca then
        mark(ca)
        if not season then season = "Complete" end
    end
    local init = 1
    while true do
        local b, _, y = ls:find("[%._%s%(%[](%d%d%d%d)[%._%s%)%]]", init)
        if not b then break end
        if y:sub(1, 2) == "19" or y:sub(1, 2) == "20" then year = y; mark(b); break end
        init = b + 1
    end
    for _, tok in ipairs(CT.TOKENS) do
        mark(ls:find("[%._%s%-%[%(]" .. tok))
    end

    local br = ls:find("%s[%[%(]")                            -- "Show [001-135] (ANIMAX ...)": the first bracket ends the title
    if br then mark(br) end
    if not cut and not group then return false end
    local title = body:sub(1, (cut or (#body + 1)) - 1)
    title = title:gsub("[%._]+", " "):gsub("%s+", " ")
    title = title:gsub("^[%s%-]+", ""):gsub("[%s%-%(%[]+$", "")
    local anime_ep = title:match("%s%-%s(%d%d?%d?)$")         -- anime "Show - 12"
    if anime_ep then
        title = title:gsub("%s%-%s%d%d?%d?$", "")
        if not season then season = string.format("E%02d", tonumber(anime_ep)) end
    end
    title = CT.strip_tail(title)
    if title == "" then return false end

    return {
        title = CT.titlecase(title), season = season, year = year, group = group,
        chips = CT.chips_for(lower),
    }
end

-- Removes release-ish words from the END of a title: "Silo Season 1", "Bleach - Box 01", "Bleach USBD", "Naruto HD"...
function CT.strip_tail(t)
    for _ = 1, 8 do
        local old = t
        t = t:gsub("[%s%-:]+$", "")
        local l = t:lower()
        local function cut(pat)
            local a = l:find(pat)
            if a then t = t:sub(1, a - 1); l = t:lower() end
        end
        cut("%s+seasons?%s*%d+.*$")
        cut("%s+box%s*%d+.*$")
        cut("%s+usbd$"); cut("%s+hd$"); cut("%s+tl$"); cut("%s+bd$"); cut("%s+remux$"); cut("%s+complete$"); cut("%s+collection$")
        if t == old then break end
    end
    return t
end

CT.fcache, CT.fcount = {}, 0
function CT.parse_folder(name)
    local hit = CT.fcache[name]
    if hit ~= nil then return hit end
    local ok, res = pcall(CT.parse_folder_raw, name)
    if not ok then res = false end
    CT.fcount = CT.fcount + 1
    if CT.fcount > 3000 then CT.fcache, CT.fcount = {}, 1 end
    CT.fcache[name] = res
    return res
end

CT.COLORS = {
    ["4K"] = "accent", ["1080p"] = "muted", ["720p"] = "muted", ["480p"] = "muted",
    ["HDR"] = "warn", ["HDR10+"] = "warn", ["DV"] = "audio", ["ATMOS"] = "video",
    ["REMUX"] = "good", ["DUAL"] = "folder", ["NEXT"] = "accent",
}
function CT.chip_color(label)
    local k = CT.COLORS[label]
    if k == "accent" then return THEME.accent elseif k == "muted" then return THEME.text_muted
    elseif k == "warn" then return THEME.warn elseif k == "audio" then return THEME.audio
    elseif k == "video" then return THEME.video elseif k == "good" then return THEME.good
    elseif k == "folder" then return THEME.folder end
    return THEME.warn   -- resume-time chips
end

-- ============================================================
-- ROW DRAWING (continued)
-- ============================================================
local function draw_sidebar_rows(chunks, hitboxes, rect)
    local header_h = layout.panel_header_h
    local row_h = layout.row_h
    local fs = layout.fs
    local items = get_panel_items("sidebar")
    local selected_idx = sidebar_selected_index
    local scroll_off = scroll_offset_folders
    local vis = visible_rows_for(rect, header_h, row_h)
    local focused = (focus_panel == "sidebar")
    local tree_mode = not (search_scope == "sidebar" and search_query ~= "")

    local body_x1, body_y1 = rect.x1 + 1, rect.y1 + header_h
    local body_x2, body_y2 = rect.x2 - 1, rect.y2 - 1
    local clip = D.clip_tag(body_x1, body_y1, body_x2, body_y2)

    local last_idx = math.min(#items, scroll_off + vis)
    for i = scroll_off + 1, last_idx do
        local node = items[i]
        local row_y1 = body_y1 + (i - scroll_off - 1) * row_h
        local row_y2 = math.min(row_y1 + row_h, body_y2)
        local is_sel = focused and (i == selected_idx)
        local is_hov = (hover_panel == "sidebar" and hover_index == i and not is_sel)

        if is_sel then
            table.insert(chunks, D.ev_rect(rect.x1 + 2, row_y1 + 1, rect.x2 - 2, row_y2 - 1, THEME.accent, 18, nil, 0, 0, o.corner_radius_row))
            table.insert(chunks, D.ev_rect(rect.x1 + 2, row_y1 + 1, rect.x1 + 5, row_y2 - 1, THEME.accent, 100, nil, 0, 0, o.corner_radius_small))
        elseif is_hov then
            table.insert(chunks, D.ev_rect(rect.x1 + 2, row_y1 + 1, rect.x2 - 2, row_y2 - 1, "FFFFFF", 7, nil, 0, 0, o.corner_radius_row))
        end

        local icon, icon_col
        if node.virtual then
            icon, icon_col = "★", THEME.warn
        elseif node.loading then
            icon, icon_col = spinner_frames[spinner_idx], THEME.text_muted
        elseif node.loaded and #node.children == 0 then
            icon, icon_col = ICONS.folder_empty, THEME.text_dim
        elseif node.expanded then
            icon, icon_col = ICONS.folder_open, THEME.folder
        else
            icon, icon_col = ICONS.folder_closed, THEME.folder
        end

        local indent = tree_mode and (math.min(node.depth, o.max_indent_levels) * o.indent_px) or 0
        local arrow_x = rect.x1 + 14 + indent
        local name_x = arrow_x + (tree_mode and 18 or 0)
        local name_y = row_y1 + row_h / 2

        -- expand/collapse arrow: its own click target (toggles WITHOUT opening the folder)
        if tree_mode and not node.virtual and not (node.loaded and #node.children == 0) then
            table.insert(chunks, D.ev_text(arrow_x + 6, name_y, 5,
                string.format("%s\\fs%d\\c%s", clip, fs - 4, U.ass_color(is_sel and THEME.accent or THEME.text_muted)),
                node.expanded and "▾" or "▸"))
            table.insert(hitboxes, {
                panel = "sidebar", index = i, arrow = true,
                x1 = arrow_x - 6, y1 = row_y1, x2 = arrow_x + 20, y2 = row_y2,
            })
        end

        local name_col
        if is_sel then
            name_col = THEME.accent
        elseif node.virtual then
            name_col = THEME.warn
        elseif focused then
            name_col = THEME.text_primary
        else
            name_col = THEME.text_muted
        end

        local active_marker = ""
        if node.href == current_path then
            active_marker = string.format("{\\c%s}%s ", U.ass_color(THEME.accent), ICONS.active_marker)
        end

        local max_name_px = math.max(20, rect.x2 - name_x - 40)
        local display_name = U.fit_text(node.name, max_name_px, fs)
        local suffix = node.virtual and "" or "/"
        local count_txt = ""
        if node.virtual then
            count_txt = string.format("  {\\c%s}%d", U.ass_color(THEME.text_dim), #get_continue_list())
        end

        -- cleaned folder name: Title  S01  1080p REMUX  GROUP   (extras are dropped, last first, if the row is narrow)
        local fp = (o.experimental_clean_titles and o.clean_folder_titles and not node.virtual) and CT.parse_folder(node.name) or nil
        if fp then
            local budget = max_name_px - 30 - (node.href == current_path and 16 or 0)
            local title_min = math.min(U.utf8_len(fp.title) * fs * 0.62, fs * 0.62 * 14)
            local used, extras = 0, {}
            local function add_extra(text, size, col)
                local w = (U.utf8_len(text) + 2) * size * 0.58
                if budget - used - w >= title_min then
                    used = used + w
                    extras[#extras + 1] = string.format("  {\\fs%d\\c%s}%s", size, U.ass_color(col), U.ass_escape(text))
                end
            end
            if fp.season then add_extra(fp.season, fs - 4, THEME.text_muted) end
            if fp.group then add_extra(fp.group, fs - 6, THEME.audio) end
            if o.clean_titles_chips then
                local chip_txt = {}
                for _, c in ipairs(fp.chips) do chip_txt[#chip_txt + 1] = c end
                for k = 1, math.min(#chip_txt, 3) do add_extra(chip_txt[k], fs - 8, CT.chip_color(chip_txt[k])) end
            end
            display_name = U.fit_text(fp.title, budget - used, fs)
            suffix = table.concat(extras)
        end

        local line = string.format("%s{\\c%s}%s  {\\c%s}%s%s%s",
            active_marker, U.ass_color(icon_col), icon, U.ass_color(name_col), U.ass_escape(display_name), suffix, count_txt)

        table.insert(chunks, D.ev_text(name_x, name_y, 4, string.format("%s\\fs%d", clip, fs), line))

        table.insert(hitboxes, {
            panel = "sidebar", index = i,
            x1 = rect.x1, y1 = row_y1, x2 = rect.x2, y2 = row_y2,
        })
    end

    if #items == 0 then
        local msg2 = (search_scope == "sidebar" and search_query ~= "") and "(no matches)" or "(no subfolders)"
        table.insert(chunks, D.ev_text(rect.x1 + 14, rect.y1 + header_h + 22, 4,
            string.format("\\i1\\fs%d\\c%s", fs - 4, U.ass_color(THEME.text_dim)), msg2))
    end

    draw_scrollbar(chunks, rect, header_h, scroll_off, #items, vis, "sidebar")
    if last_idx < #items then
        table.insert(chunks, D.ev_text((rect.x1 + rect.x2) / 2, rect.y2 - 10, 5,
            string.format("\\fs%d\\c%s", fs - 8, U.ass_color(THEME.accent)), "▼"))
    end
end

local function draw_episode_rows(chunks, hitboxes, rect)
    local header_h = layout.panel_header_h
    local row_h = layout.row_h
    local fs = layout.fs
    local items = get_panel_items("episodes")
    local selected_idx = selected_episode
    local scroll_off = scroll_offset_episodes
    local vis = visible_rows_for(rect, header_h, row_h)
    local focused = (focus_panel == "episodes")
    local is_global = (search_scope == "global")

    local body_x1, body_y1 = rect.x1 + 1, rect.y1 + header_h
    local body_x2, body_y2 = rect.x2 - 1, rect.y2 - 1
    local clip = D.clip_tag(body_x1, body_y1, body_x2, body_y2)

    local clean = o.experimental_clean_titles and not is_global
    local uniform = clean and CT.uniform_title(items)
    local cfs = math.max(10, fs - 8)

    -- draws one chip with its LEFT edge at x_left; returns the next chip's left edge
    local function draw_chip(x_left, cy, label, color)
        local w = U.utf8_len(label) * cfs * 0.62 + 12
        local x2 = x_left + w
        table.insert(chunks, D.ev_rect(x_left, cy - cfs * 0.78, x2, cy + cfs * 0.78, color, 16, color, 45, 1, o.corner_radius_small))
        table.insert(chunks, D.ev_text((x_left + x2) / 2, cy, 5,
            string.format("%s\\b1\\fs%d\\c%s", clip, cfs, U.ass_color(color)), U.ass_escape(label)))
        return x2 + 5
    end

    local last_idx = math.min(#items, scroll_off + vis)
    for i = scroll_off + 1, last_idx do
        local item = items[i]
        local row_y1 = body_y1 + (i - scroll_off - 1) * row_h
        local row_y2 = math.min(row_y1 + row_h, body_y2)
        local is_sel = focused and (i == selected_idx)
        local is_hov = (hover_panel == "episodes" and hover_index == i and not is_sel)

        if is_sel then
            table.insert(chunks, D.ev_rect(rect.x1 + 2, row_y1 + 1, rect.x2 - 2, row_y2 - 1, THEME.accent, 18, nil, 0, 0, o.corner_radius_row))
            table.insert(chunks, D.ev_rect(rect.x1 + 2, row_y1 + 1, rect.x1 + 5, row_y2 - 1, THEME.accent, 100, nil, 0, 0, o.corner_radius_small))
        elseif is_hov then
            table.insert(chunks, D.ev_rect(rect.x1 + 2, row_y1 + 1, rect.x2 - 2, row_y2 - 1, "FFFFFF", 7, nil, 0, 0, o.corner_radius_row))
        end

        local icon, icon_col
        if item.is_dir then
            icon, icon_col = ICONS.folder_closed, THEME.folder
        elseif U.is_video(item.name) then
            icon, icon_col = ICONS.video, THEME.video
        elseif U.is_audio(item.name) then
            icon, icon_col = ICONS.audio, THEME.audio
        else
            icon, icon_col = ICONS.file, THEME.file
        end

        local name_x = rect.x1 + 14
        local name_y = row_y1 + row_h / 2
        local name_col = is_sel and THEME.accent or (focused and THEME.text_primary or THEME.text_muted)
        local scroll_pad = (#items > vis) and 10 or 0

        -- right-hand text: path (search results / continue list) or size
        local right_text, right_col = nil, THEME.text_muted
        local hist = watch_history[item.href]
        local use_right_status = o.show_status_text and not is_global and not item.cw and not item.is_dir
        if use_right_status then
            if watched_set[item.href] then
                right_text, right_col = ICONS.watched .. " " .. tostring(o.watched_label or "Watched"), THEME.good
            elseif hist and hist.pos and hist.duration and hist.duration > 0 then
                local pct = math.floor(math.min(1, hist.pos / hist.duration) * 100)
                right_text, right_col = string.format("%s %d%% - %s left", ICONS.watching, pct,
                    U.fmt_time(math.max(0, hist.duration - hist.pos))), THEME.warn
            end
        end
        if is_global then
            right_text = U.fit_text(U.percent_decode(item.dirpath or ""):gsub("^/", ""), (rect.x2 - rect.x1) * 0.34, fs - 6)
            if right_text == "" then right_text = "/" end
        elseif item.cw then
            right_text = U.fit_text(U.basename(item.dirpath or ""), (rect.x2 - rect.x1) * 0.30, fs - 6)
        end
        local right_w = right_text and (U.utf8_len(right_text) * (fs - 6) * 0.55 + 22) or 18
        right_w = right_w + scroll_pad

        -- clean title + chips
        local cp = (clean and not item.is_dir and U.is_media(item.name)) and CT.parse(item.name) or nil
        local shown_name, name_suffix = item.name, ""
        local chip_labels = {}
        if cp then
            if cp.se then
                shown_name = cp.se
                if not uniform and cp.title ~= "" then
                    name_suffix = string.format("  {\\fs%d\\c%s}%s", fs - 4, U.ass_color(THEME.text_muted), U.ass_escape(cp.title))
                end
            else
                shown_name = cp.label
            end
            if o.clean_titles_chips then
                for _, c in ipairs(cp.chips) do chip_labels[#chip_labels + 1] = c end
            end
        end
        if item.cw == "next" then table.insert(chip_labels, 1, "NEXT") end
        if item.cw == "resume" and hist and hist.pos then table.insert(chip_labels, 1, U.fmt_time(hist.pos)) end

        local chips_w = 0
        for _, c in ipairs(chip_labels) do chips_w = chips_w + U.utf8_len(c) * cfs * 0.62 + 12 + 5 end
        local size_text = (not item.is_dir and item.size and item.size > 0) and U.fmt_bytes(item.size) or nil
        local size_w = size_text and (U.utf8_len(size_text) * (fs - 6) * 0.55 + 14) or 0

        local status = ""
        if o.show_watched_status and not use_right_status then
            if watched_set[item.href] then
                status = string.format("{\\c%s} %s", U.ass_color(THEME.good), ICONS.watched)
            elseif hist then
                status = string.format("{\\c%s} %s", U.ass_color(THEME.warn), ICONS.watching)
            end
        end

        local icon_w_est = 30
        local status_w_est = (status ~= "") and 26 or 0
        local suffix_w_est = (name_suffix ~= "") and (U.utf8_len(cp and cp.title or "") * (fs - 4) * 0.55 + 14) or 0
        -- Narrow panel? Give up the extras in priority order (size, then chips, then the status words)
        -- so the name always keeps a readable minimum.
        do
            local keep_px = math.min(U.utf8_len(shown_name) * fs * 0.62, fs * 0.62 * 12)
            local avail = rect.x2 - name_x - icon_w_est - status_w_est - suffix_w_est - 14
            if avail - right_w - chips_w - size_w < keep_px then size_text, size_w = nil, 0 end
            if avail - right_w - chips_w < keep_px then chip_labels, chips_w = {}, 0 end
            if avail - right_w < keep_px and use_right_status and right_text then
                right_text = right_text:match("^%S+")        -- just the tick / progress icon
                right_w = U.utf8_len(right_text) * (fs - 6) * 0.55 + 22 + scroll_pad
            end
        end
        local max_name_px = math.max(20, rect.x2 - name_x - right_w - chips_w - size_w - icon_w_est - status_w_est - suffix_w_est)
        local display_name = U.fit_text(shown_name, max_name_px, fs)
        if item.is_dir then display_name = display_name .. "/" end

        local line = string.format("{\\c%s}%s  {\\c%s}%s%s%s",
            U.ass_color(icon_col), icon, U.ass_color(name_col), U.ass_escape(display_name), name_suffix, status)
        table.insert(chunks, D.ev_text(name_x, name_y, 4, string.format("%s\\fs%d", clip, fs), line))

        if right_text then
            table.insert(chunks, D.ev_text(rect.x2 - 16 - scroll_pad, name_y, 6,
                string.format("%s\\fs%d\\c%s", clip, fs - 6, U.ass_color(right_col)),
                U.ass_escape(right_text)))
        end

        -- chips and size sit right after the name (estimated end of the text), not at the row's edge
        local cx = name_x + icon_w_est + U.utf8_len(display_name) * fs * 0.58 + suffix_w_est + status_w_est + 8
        local limit = rect.x2 - right_w - 4
        for k = 1, #chip_labels do
            if cx > limit then break end
            cx = draw_chip(cx, name_y, chip_labels[k], CT.chip_color(chip_labels[k]))
        end
        if size_text and cx + size_w <= limit + 8 then
            table.insert(chunks, D.ev_text(cx + 2, name_y, 4,
                string.format("%s\\fs%d\\c%s", clip, fs - 6, U.ass_color(THEME.text_dim)), U.ass_escape(size_text)))
        end

        if hist and hist.pos and hist.duration and hist.duration > 0 and not item.is_dir then
            local pct = math.min(1, hist.pos / hist.duration)
            local bx1, bx2 = name_x, rect.x2 - 14
            local by1, by2 = row_y2 - 4, row_y2 - 2
            table.insert(chunks, D.ev_rect(bx1, by1, bx2, by2, THEME.track, 100, nil, 0, 0, o.corner_radius_small))
            table.insert(chunks, D.ev_rect(bx1, by1, bx1 + (bx2 - bx1) * pct, by2, THEME.accent, 100, nil, 0, 0, o.corner_radius_small))
        end

        table.insert(hitboxes, {
            panel = "episodes", index = i,
            x1 = rect.x1, y1 = row_y1, x2 = rect.x2, y2 = row_y2,
        })
    end

    if #items == 0 then
        local msg2 = "(no files)"
        if is_global then
            msg2 = (search_query == "") and "Type to search the folders you have opened" or "(no matches in the folders you have opened)"
        elseif search_scope == "episodes" and search_query ~= "" then
            msg2 = "(no matches)"
        elseif current_path == CW_HREF then
            msg2 = "Nothing to continue yet - watch something and it will show up here"
        elseif hide_watched and #file_entries > 0 then
            msg2 = "(everything here is watched - press H to show watched files)"
        end
        table.insert(chunks, D.ev_text(rect.x1 + 14, rect.y1 + header_h + 22, 4,
            string.format("\\i1\\fs%d\\c%s", fs - 4, U.ass_color(THEME.text_dim)), U.ass_escape(msg2)))
    end

    draw_scrollbar(chunks, rect, header_h, scroll_off, #items, vis, "episodes")
    if last_idx < #items then
        table.insert(chunks, D.ev_text((rect.x1 + rect.x2) / 2, rect.y2 - 10, 5,
            string.format("\\fs%d\\c%s", fs - 8, U.ass_color(THEME.accent)), "▼"))
    end
end

-- ============================================================
-- MAIN RENDER
-- ============================================================
-- ---------- debug overlay ('d') ----------
function U.table_count(tbl) local n = 0 for _ in pairs(tbl) do n = n + 1 end return n end

local function build_debug_lines()
    local L = {}
    local dirs, items = IDX.count_items()
    local cached = find_cached_dir(current_path)
    local rs = req_stats.last
    L[#L + 1] = "DEBUG  -  webdav-browser " .. SCRIPT_VERSION
    L[#L + 1] = "folder: " .. current_path
    L[#L + 1] = "listing: " .. (cached and (string.format("cached %s (%s)", U.fmt_age(cached.ts),
        cache_is_fresh(cached) and "fresh" or "stale")) or "not cached")
    L[#L + 1] = string.format("cache: %d folders, %d items, ttl %ds", dirs, items, o.cache_ttl)
    if rs then
        L[#L + 1] = "last request: " .. rs.path
        L[#L + 1] = string.format("   %d ms   HTTP %s   attempts %d   %s", rs.ms or 0, tostring(rs.code or "-"),
            rs.attempts or 1, U.fmt_age(rs.ts))
        if rs.err then L[#L + 1] = "   error: " .. rs.err end
    else
        L[#L + 1] = "last request: none yet"
    end
    L[#L + 1] = string.format("requests: %d total, %d failed, %d in flight", req_stats.total, req_stats.failures, req_stats.pending)
    L[#L + 1] = IDX.summary()
    L[#L + 1] = string.format("persistence: %s%s", persist_status.ok and "ok" or ("FAILED - " .. tostring(persist_status.err)),
        persist_status.last_save and (", saved " .. U.fmt_age(persist_status.last_save)) or ", not saved yet")
    L[#L + 1] = "data file: " .. tostring(persist_status.path)
    L[#L + 1] = string.format("auth: %s    blur: %s", o.scoped_auth and "scoped (file-local)" or "session-wide", MS.blur_state or "off")
    do
        local ok, chain = pcall(mp.get_property_native, "vf")
        local names = {}
        if ok and type(chain) == "table" then
            for _, f in ipairs(chain) do names[#names + 1] = (f.label and ("@" .. f.label) or tostring(f.name)) end
        end
        L[#L + 1] = "video filters: " .. (#names > 0 and table.concat(names, ", ") or "none")
    end
    do
        local fb = MS.fb
        if fb.active then
            L[#L + 1] = string.format("download-play: %s %s / %s%s", fb.playing and "playing" or "buffering",
                U.fmt_bytes(fb.size or 0), fb.total and U.fmt_bytes(fb.total) or "?", fb.done and "  (complete)" or "")
        end
    end
    L[#L + 1] = string.format("posters: %s, tmdb_key %s, status %s%s", o.experimental_posters and "on" or "OFF (experimental_posters=no)",
        o.tmdb_key ~= "" and (#o.tmdb_key .. " chars") or "MISSING", tostring(PS and PS.status or "?"), PS and PS.err and (" - " .. PS.err) or "")
    if MS.debug_extra then for _, ln in ipairs(MS.debug_extra()) do L[#L + 1] = ln end end
    L[#L + 1] = string.format("credentials: user '%s', password %d chars, curl via %s", o.user, #o.pass, U.auth_mode())
    for _, n in ipairs(U.conf_notes or {}) do L[#L + 1] = "config: " .. n end
    L[#L + 1] = string.format("watch tracking: %d in progress, %d watched", U.table_count(watch_history), U.table_count(watched_set))
    local errs = U.table_count(listing_error)
    if errs > 0 then L[#L + 1] = string.format("folders with errors: %d", errs) end
    return L
end

-- ============================================================
-- POSTERS (EXPERIMENTAL - poster edition only)
-- Looks the open folder's title up on TMDB, downloads the poster, converts it to raw BGRA and shows it
-- in a reserved column on the right with mpv's overlay-add. The bitmap is drawn ABOVE all text, so the
-- column is kept free of other UI and the picture is removed whenever something could cover it.
-- This product uses the TMDB API but is not endorsed or certified by TMDB.
-- ============================================================
PS = { ID = 63, gen = 0, status = "idle", info = nil, want = nil, shown = nil, timer = nil, idx = nil, dir_ok = false }

PS.PS1 = [[
param([string]$In, [string]$Out, [int]$W, [int]$H)
Add-Type -AssemblyName System.Drawing
$src = [System.Drawing.Image]::FromFile($In)
$fmt = [System.Drawing.Imaging.PixelFormat]::Format32bppPArgb
$bmp = New-Object System.Drawing.Bitmap($W, $H, $fmt)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g.DrawImage($src, 0, 0, $W, $H)
$g.Dispose(); $src.Dispose()
$rect = New-Object System.Drawing.Rectangle(0, 0, $W, $H)
$data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, $fmt)
$bytes = New-Object byte[] ($data.Stride * $H)
[System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
$bmp.UnlockBits($data); $bmp.Dispose()
[System.IO.File]::WriteAllBytes($Out, $bytes)
]]

PS.GENERIC = { season = true, seasons = true, specials = true, special = true, extras = true, extra = true, subs = true, sample = true }

function PS.enabled()
    return o.experimental_posters and o.tmdb_key ~= ""
end

function PS.dir()
    if PS._dir then return PS._dir end
    local d = o.poster_cache_dir
    if d == "" then
        local base = data_dir()
        d = base and utils.join_path(base, "webdav_posters")
            or ((os.getenv("TEMP") or os.getenv("TMP") or os.getenv("TMPDIR") or "/tmp"):gsub("\\", "/") .. "/webdav_posters")
    end
    PS._dir = (d:gsub("\\", "/"):gsub("/+$", ""))
    return PS._dir
end

-- Creates the cache folder (mpv has no mkdir of its own).
function PS.mkdir()
    local d = PS.dir()
    if PS._made then return end
    local is_win = package.config:sub(1, 1) == "\\"
    local args = is_win and { "cmd", "/c", "mkdir", (d:gsub("/", "\\")) } or { "mkdir", "-p", d }
    pcall(mp.command_native, { name = "subprocess", args = args, capture_stdout = true, capture_stderr = true, playback_only = false })
    PS._made = true
end

function PS.run(args, cb)
    mp.command_native_async({
        name = "subprocess", args = args, capture_stdout = true, capture_stderr = true, playback_only = false,
    }, function(success, res, err)
        if not success or not res then cb(nil, err or "could not start the program") return end
        cb(res, nil)
    end)
end

function PS.norm(s) return (tostring(s):lower():gsub("[^%w]+", "")) end

-- Title (and year) of a folder NAME; nil for generic names ("Season 1", "Specials"...) so callers can look further up.
function PS.title_of_name(name)
    local fp = o.experimental_clean_titles and CT.parse_folder(name) or nil
    local title, year
    if fp and fp.title then
        title, year = fp.title, fp.year
    else
        title = name:gsub("\234\158\137", ":"):gsub("[%._]+", " "):gsub("%[[^%]]*%]", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        year = title:match("%((%d%d%d%d)%)")
        title = title:gsub("%(%d%d%d%d%)", ""):gsub("%s+$", "")
        title = CT.strip_tail(title)
    end
    local first = title:lower():match("^(%a+)")
    local generic = (first and PS.GENERIC[first] and #title < 14) or title:match("^[Ss]%d+$")
    if title == "" or #title < 2 or generic then return nil end
    return title, year and tostring(year) or ""
end

-- Title of a folder path: the folder itself, or the nearest parent with a real title. Never the library root.
function PS.title_of_path(p)
    for _ = 1, 4 do
        local pn = p:gsub("/+$", "")
        if pn == "" or pn == root_href:gsub("/+$", "") then return nil end
        local t, y = PS.title_of_name(U.basename(p))
        if t then return t, y end
        p = U.dirname(p)
    end
    return nil
end

-- Title (and year) to look up for the folder open in the files panel.
function PS.target()
    if search_scope == "global" or current_path == CW_HREF then return nil end
    return PS.title_of_path(current_path)
end

PS.IDX_VERSION = 4     -- bump when the matching rules change: older lookups (and "not found" results) are dropped once
function PS.load_index()
    if PS.idx then return end
    PS.idx = { __v = PS.IDX_VERSION }
    local f = io.open(PS.dir() .. "/index.json", "rb")
    if f then
        local txt = f:read("*a"); f:close()
        local ok, data = pcall(utils.parse_json, txt)
        if ok and type(data) == "table" then
            data = U.plain(data)
            if data.__v == PS.IDX_VERSION then PS.idx = data end
        end
    end
end

function PS.save_index()
    local txt = utils.format_json(PS.idx)
    if not txt then return end
    pcall(atomic_write, PS.dir() .. "/index.json", txt)
end

-- ---- the lookup / download / convert chain -------------------------------------------------
-- Search strings to try, best first, for one folder name.
function PS.queries(raw, title, year)
    local out, seen = {}, {}
    local function add(q)
        if not q then return end
        q = q:gsub("\234\158\137", ":"):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        if #q >= 2 and not seen[q:lower()] then seen[q:lower()] = true; out[#out + 1] = q end
    end
    add(title)
    local r = tostring(raw or ""):gsub("\234\158\137", ":"):gsub("%b[]", " "):gsub("%b()", " "):gsub("[%._]+", " ")
    r = r:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    r = CT.strip_tail(r)
    add(r)
    for _, base in ipairs({ title or "", r }) do
        add(base:match("^(.-)%s+%-%s+"))
        add(base:match("^(.-):"))
    end
    local words = {}
    for w in tostring(title or r):gmatch("%S+") do words[#words + 1] = w end
    for n = #words - 1, 2, -1 do add(table.concat(words, " ", 1, n)) end
    if #words >= 2 and #words[1] >= 4 then add(words[1]) end
    return out
end

-- Best result. kindpref = "tv" | "movie" | "" (a season tag in the folder name means TV; a bare year means a film).
-- strict: only results whose name relates to the query count; the best unrelated one is handed back as `any`.
function PS.pick(results, title, year, kindpref, strict)
    local best, best_score, any
    local want = PS.norm(title)
    for _, r in ipairs(results or {}) do
        if (r.media_type == "tv" or r.media_type == "movie") and r.poster_path and r.poster_path ~= "" then
            local date = r.first_air_date or r.release_date or ""
            local nm, on = PS.norm(r.name or r.title or ""), PS.norm(r.original_name or r.original_title or "")
            local exact = (nm == want or on == want)
            local related = exact or (#want >= 4 and ((nm ~= "" and (nm:find(want, 1, true) or want:find(nm, 1, true)))
                or (on ~= "" and (on:find(want, 1, true) or want:find(on, 1, true)))))
            local score = exact and 3 or (related and 1 or 0)
            local ry = tonumber(date:sub(1, 4)) or 0
            local wy = tonumber(year) or 0
            if wy > 0 and ry > 0 then
                if ry == wy then score = score + 2 elseif math.abs(ry - wy) == 1 then score = score + 1 end
            end
            if kindpref and kindpref ~= "" and r.media_type == kindpref then score = score + 1.5 end
            score = score + math.min(0.9, (tonumber(r.popularity) or 0) / 1000)
            if not any then any = r end
            if (not strict or related) and (not best_score or score > best_score) then best, best_score = r, score end
        end
    end
    return best, any
end

function PS.search(title, year, gen, cb, kindpref, strict)
    local url = o.tmdb_api_base .. "/search/multi?include_adult=false&query=" .. U.url_encode_segment(title)
    local args = { o.curl_path, "-s", "-S", "-m", "15", "-w", "\n%{http_code}" }
    if #o.tmdb_key > 40 then
        args[#args + 1] = "-H"; args[#args + 1] = "Authorization: Bearer " .. o.tmdb_key
    else
        url = url .. "&api_key=" .. o.tmdb_key
    end
    args[#args + 1] = url
    PS.run(args, function(res, err)
        if gen and gen ~= PS.gen then return end
        if not res or res.status ~= 0 then cb(nil, "search failed") return end
        local body, code = res.stdout:match("^(.*)\n(%d%d%d)$")
        if code == "401" then cb(nil, "TMDB rejected the key") return end
        if code ~= "200" then cb(nil, "TMDB HTTP " .. tostring(code)) return end
        local ok, data = pcall(utils.parse_json, body)
        if not ok or type(data) ~= "table" then cb(nil, "bad reply") return end
        local best, any = PS.pick(data.results, title, year, kindpref, strict)
        cb(best or false, nil, any)
    end)
end

-- Generic TMDB GET. cb(data|nil, err, http_code)
function PS.api(path, cb)
    local url = o.tmdb_api_base .. path
    local args = { o.curl_path, "-s", "-S", "-m", "15", "-w", "\n%{http_code}" }
    if #o.tmdb_key > 40 then
        args[#args + 1] = "-H"; args[#args + 1] = "Authorization: Bearer " .. o.tmdb_key
    else
        url = url .. (url:find("?", 1, true) and "&" or "?") .. "api_key=" .. o.tmdb_key
    end
    args[#args + 1] = url
    PS.run(args, function(res)
        if not res or res.status ~= 0 then cb(nil, "request failed", 0) return end
        local body, code = tostring(res.stdout):match("^(.*)\n(%d%d%d)$")
        code = tonumber(code) or 0
        if code == 401 then cb(nil, "TMDB rejected the key", 401) return end
        if code ~= 200 then cb(nil, "TMDB HTTP " .. code, code) return end
        local ok, data = pcall(utils.parse_json, body)
        if not ok or type(data) ~= "table" then cb(nil, "bad reply", code) return end
        cb(data, nil, 200)
    end)
end

-- Persistent episode data (episodes.json): one record per show+season, fetched ONCE and kept forever.
PS.eps, PS.eps_ver = nil, 0
function PS.load_eps()
    if PS.eps then return end
    PS.eps = {}
    local f = io.open(PS.dir() .. "/episodes.json", "rb")
    if f then
        local txt = f:read("*a"); f:close()
        local ok, data = pcall(utils.parse_json, txt)
        if ok and type(data) == "table" then PS.eps = U.plain(data) end
    end
end
function PS.save_eps()
    local txt = safe_json(PS.eps)
    if not txt then return end
    if not atomic_write(PS.dir() .. "/episodes.json", txt) then PS.mkdir(); atomic_write(PS.dir() .. "/episodes.json", txt) end
end
function PS.ep_info(show, s, e)
    if not (show and show.id and s and e) then return nil end
    PS.load_eps()
    local rec = PS.eps[show.id .. ":" .. s]
    if type(rec) ~= "table" or rec.none or type(rec.eps) ~= "table" then return nil end
    return rec.eps[tostring(e)]
end
-- Fetch (once) season s of a TV show; calls cb() when stored (also for a season TMDB does not know).
function PS.season(show, s, cb)
    PS.load_eps()
    local key = show.id .. ":" .. s
    if PS.eps[key] ~= nil then cb() return end
    PS.api(string.format("/tv/%s/season/%d?language=en-US", show.id, s), function(data, err, code)
        if data and type(data.episodes) == "table" then
            local rec = { ts = os.time(), eps = {} }
            for _, ep in ipairs(data.episodes) do
                local n = tonumber(ep.episode_number)
                if n then
                    rec.eps[tostring(n)] = {
                        n = ep.name or "", o = tostring(ep.overview or ""):sub(1, 400), st = ep.still_path or "",
                        d = ep.air_date or "", r = tonumber(ep.runtime) or 0, v = tonumber(ep.vote_average) or 0,
                    }
                end
            end
            PS.eps[key] = rec
            PS.save_eps()
        elseif code == 404 then
            PS.eps[key] = { none = true, ts = os.time() }      -- TMDB has no such season: remember, do not ask again
            PS.save_eps()
        else
            PS.season_err = err
            cb(err) return
        end
        PS.eps_ver = PS.eps_ver + 1
        cb()
    end)
end
-- Overview / backdrop / season count for a show that was cached without them (older cache entries).
function PS.details(entry, cb)
    PS.api(string.format("/%s/%s?language=en-US", entry.kind == "movie" and "movie" or "tv", entry.id), function(d)
        if d then
            entry.overview = tostring(d.overview or "")
            entry.backdrop_path = d.backdrop_path or entry.backdrop_path or ""
            entry.seasons = tonumber(d.number_of_seasons) or entry.seasons
            entry.vote = tonumber(d.vote_average) or entry.vote
            local sc = {}
            local n = 0
            if type(d.seasons) == "table" then
                for _, se in ipairs(d.seasons) do
                    local sn, cnt = tonumber(se.season_number), tonumber(se.episode_count)
                    if sn and sn >= 1 and cnt then sc[tostring(sn)] = cnt; n = n + 1 end
                end
            end
            entry.sc = (n > 0) and sc or false
            entry.detail = true
            PS.save_index()
            PS.eps_ver = PS.eps_ver + 1
        end
        cb()
    end)
end
-- Download an image to the cache (never expires). cb(ok)
function PS.fetch_image(size, path, jpg, cb)
    local ji = utils.file_info(jpg)
    if ji and ji.size > 500 then cb(true) return end
    PS.run({ o.curl_path, "-s", "-S", "-m", "30", "--create-dirs", "-o", jpg, o.tmdb_image_base .. size .. path }, function(res)
        local info = utils.file_info(jpg)
        local ok = res and res.status == 0 and info and info.size > 500
        if not ok then pcall(os.remove, jpg) end
        cb(ok and true or false)
    end)
end

-- Cache size (everything in the cache folder; history lives elsewhere and is never counted or touched).
function PS.stats(force)
    local now = os.time()
    if PS.st and not force and now - PS.st.t < 15 and not PS.st_dirty then return PS.st end
    PS.st_dirty = false
    local dir = PS.dir()
    local bytes, files, imgs = 0, 0, 0
    local list = utils.readdir(dir, "files")
    if type(list) == "table" then
        for _, f in ipairs(list) do
            local info = utils.file_info(dir .. "/" .. f)
            if info then
                bytes = bytes + (info.size or 0); files = files + 1
                if f:match("%.jpg$") then imgs = imgs + 1 end
            end
        end
    end
    PS.st = { t = now, bytes = bytes, files = files, imgs = imgs }
    return PS.st
end
function PS.clear_cache()
    local dir = PS.dir()
    local list = utils.readdir(dir, "files")
    local n = 0
    if type(list) == "table" then
        for _, f in ipairs(list) do
            if os.remove(dir .. "/" .. f) then n = n + 1 end
        end
    end
    PS.idx, PS.eps = {}, {}
    PS.eps_ver = PS.eps_ver + 1
    dir_cache = {}
    MS.cache_version = MS.cache_version + 1
    PS.st_dirty = true
    return n
end

function PS.convert(jpg, bgra, w, h, cb)
    local mode = o.poster_converter
    local is_win = package.config:sub(1, 1) == "\\"
    if mode == "auto" then mode = is_win and "powershell" or "ffmpeg" end
    local function done(res, err, tag)
        if not res or res.status ~= 0 then cb(false, tag .. " failed") else cb(true) end
    end
    if mode == "powershell" then
        local ps = PS.dir() .. "/convert.ps1"
        local f = io.open(ps, "wb")
        if not f then cb(false, "cannot write convert script") return end
        f:write(PS.PS1); f:close()
        PS.run({ "powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", ps,
                 jpg, bgra, tostring(w), tostring(h) }, function(r, e) done(r, e, "powershell") end)
    elseif mode == "ffmpeg" then
        PS.run({ o.ffmpeg_path, "-v", "error", "-y", "-i", jpg, "-vf", string.format("scale=%d:%d", w, h),
                 "-pix_fmt", "bgra", "-f", "rawvideo", bgra }, function(r, e) done(r, e, "ffmpeg") end)
    else
        PS.run({ o.magick_path, jpg, "-resize", string.format("%dx%d!", w, h), "-depth", "8", "bgra:" .. bgra },
            function(r, e) done(r, e, "magick") end)
    end
end

-- Show (or re-show) the converted picture for the current request.
function PS.draw()
    local want = PS.want
    if not (want and want.ready and browser_active and PS.status == "ok") then return end
    local ok = mp.commandv("overlay-add", tostring(PS.ID), tostring(want.x), tostring(want.y), want.bgra, "0", "bgra",
        tostring(want.w), tostring(want.h), tostring(want.w * 4))
    PS.shown = ok and want.key or nil
end

function PS.hide()
    PS.gen = PS.gen + 1
    if PS.timer then PS.timer:kill(); PS.timer = nil end
    if PS.shown then pcall(mp.commandv, "overlay-remove", tostring(PS.ID)) end
    PS.shown = nil
    PS.want = nil
    PS.status = "idle"
    PS.info = nil
end

-- Download (if needed) and convert for the size in `want`, then draw.
function PS.finish_convert(want, gen)
    local bgra = string.format("%s/p%s_%dx%d.bgra", PS.dir(), want.id, want.w, want.h)
    local bi = utils.file_info(bgra)
    if bi and bi.size == want.w * want.h * 4 then
        want.bgra, want.ready = bgra, true
        PS.status = "ok"; PS.draw(); render(); return
    end
    PS.convert(want.jpg, bgra, want.w, want.h, function(ok, why)
        if gen ~= PS.gen then return end
        local bi2 = utils.file_info(bgra)
        if not ok or not bi2 or bi2.size ~= want.w * want.h * 4 then
            PS.status, PS.err = "error", why or "bad converted size"
            render(); return
        end
        want.bgra, want.ready = bgra, true
        PS.status = "ok"; PS.draw(); render()
    end)
end

function PS.have_poster(want, entry, gen)
    PS.info = { name = entry.name, year = entry.year, kind = entry.kind }
    local jpg = string.format("%s/p%s_%s.jpg", PS.dir(), entry.id, want.size)
    want.id, want.jpg = entry.id, jpg
    local ji = utils.file_info(jpg)
    if ji and ji.size > 1000 then PS.finish_convert(want, gen); return end
    PS.run({ o.curl_path, "-s", "-S", "-m", "30", "--create-dirs", "-o", jpg,
             o.tmdb_image_base .. want.size .. entry.poster_path }, function(res, err)
        if gen ~= PS.gen then return end
        local info = utils.file_info(jpg)
        if not res or res.status ~= 0 or not info or info.size < 1000 then
            PS.status, PS.err = "error", "poster download failed"
            render(); return
        end
        PS.save_index()   -- the cache folder exists now (curl --create-dirs), so this write can succeed
        PS.finish_convert(want, gen)
    end)
end

function PS.start(want)
    PS.gen = PS.gen + 1
    local gen = PS.gen
    PS.want = want
    PS.status = "loading"
    PS.info, PS.err = nil, nil
    PS.load_index()
    local ik = PS.norm(want.title) .. "|" .. want.year
    local hit = PS.idx[ik]
    if hit ~= nil then
        if hit == false or hit.none then PS.status = "none"; render(); return end
        PS.have_poster(want, hit, gen); return
    end
    PS.search(want.title, want.year, gen, function(r, err)
        if gen ~= PS.gen then return end
        if r == nil then PS.status, PS.err = "error", err; render(); return end
        if r == false then
            PS.idx[ik] = { none = true }
            PS.save_index()
            PS.status = "none"; render(); return
        end
        local entry = {
            id = tostring(r.id or "0"), name = r.name or r.title or "?", kind = r.media_type,
            year = (r.first_air_date or r.release_date or ""):sub(1, 4), poster_path = r.poster_path,
        }
        PS.idx[ik] = entry
        PS.save_index()
        PS.have_poster(want, entry, gen)
    end)
end

-- Called at the end of every render(). Cheap when nothing changed.
function PS.update()
    local rect = layout and layout.poster
    local title, year
    if rect and PS.enabled() and not MS.debug then title, year = PS.target() end
    if not title then
        if PS.want or PS.shown or PS.status ~= "idle" then PS.hide() end
        return
    end
    -- picture box inside the column: 2:3, leaving room for the caption underneath
    local pw = rect.x2 - rect.x1 - 16
    local avail_h = rect.y2 - rect.y1 - 16 - PS.caption_h(rect)
    local ph = math.floor(pw * 1.5)
    if ph > avail_h then ph = avail_h; pw = math.floor(ph / 1.5) end
    if pw < 80 then
        if PS.want or PS.shown or PS.status ~= "idle" then PS.hide() end
        return
    end
    pw = math.min(pw, 340)
    ph = math.floor(pw * 1.5)
    local x = math.floor(rect.x1 + ((rect.x2 - rect.x1) - pw) / 2)
    local y = math.floor(rect.y1 + 12)
    local key = PS.norm(title) .. "|" .. year
    local w_ = PS.want
    if w_ and w_.key == key and w_.w == pw and w_.h == ph and w_.x == x and w_.y == y then
        -- same request: make sure the bitmap is still on screen (e.g. after a hide)
        if w_.ready and PS.shown ~= key and PS.status == "ok" then PS.draw() end
        return
    end
    -- different request: remove the old bitmap right away, debounce the lookup while scrolling
    if PS.shown then pcall(mp.commandv, "overlay-remove", tostring(PS.ID)); PS.shown = nil end
    PS.gen = PS.gen + 1
    local gen = PS.gen
    local keep_info = (w_ and w_.key == key) and PS.info or nil
    local want = { key = key, title = title, year = year, w = pw, h = ph, x = x, y = y,
                   size = (pw > 300) and "w500" or "w342" }
    PS.want, PS.status, PS.info = want, "loading", keep_info
    if PS.timer then PS.timer:kill() end
    PS.timer = mp.add_timeout(0.35, function()
        PS.timer = nil
        if gen ~= PS.gen then return end
        PS.start(want)
    end)
end

function PS.caption_h(rect)
    return 92
end

-- Draw the column background, caption and the required TMDB attribution (ASS layer, under the bitmap).
function PS.draw_panel(chunks, rect, paint_panel)
    paint_panel(rect, false)
    local fs = layout.fs
    local cx = (rect.x1 + rect.x2) / 2
    local pw = rect.x2 - rect.x1 - 12
    local ty = rect.y2 - PS.caption_h(rect) + 4
    local want = PS.want
    local status_text
    if PS.status == "loading" then status_text = "Loading poster..."
    elseif PS.status == "none" then status_text = "No poster found"
    elseif PS.status == "error" then status_text = PS.err or "Poster error" end
    if status_text then
        table.insert(chunks, D.ev_text(cx, rect.y1 + (rect.y2 - rect.y1 - PS.caption_h(rect)) / 2, 5,
            string.format("\\fs%d\\c%s", fs - 6, U.ass_color(THEME.text_muted)), U.ass_escape(U.fit_text(status_text, pw, fs - 6))))
    elseif not want then
        table.insert(chunks, D.ev_text(cx, rect.y1 + (rect.y2 - rect.y1 - PS.caption_h(rect)) / 2, 5,
            string.format("\\fs%d\\c%s", fs - 6, U.ass_color(THEME.text_muted)), "No title to look up"))
    end
    if PS.info then
        local line = PS.info.name .. ((PS.info.year and PS.info.year ~= "") and ("  (" .. PS.info.year .. ")") or "")
        table.insert(chunks, D.ev_text(cx, ty + 8, 5,
            string.format("\\b1\\fs%d\\c%s", fs - 6, U.ass_color(THEME.text_primary)), U.ass_escape(U.fit_text(line, pw, fs - 6))))
    end
    local afs = math.max(10, fs - 14)
    local lines = { "This product uses the TMDB API", "but is not endorsed or certified", "by TMDB." }
    for i, ln in ipairs(lines) do
        table.insert(chunks, D.ev_text(cx, ty + 32 + (i - 1) * (afs + 4), 5,
            string.format("\\fs%d\\c%s", afs, U.ass_color(THEME.text_muted)), U.ass_escape(U.fit_text(ln, pw, afs))))
    end
end

-- ============================================================
-- HOME: Netflix-style poster grid (EXPERIMENTAL - poster edition only)
-- Rows of poster cards with the clean title underneath: Continue Watching, Recently Added and
-- All Titles (A-Z). Enter opens a title (its episode page is the normal browser) or resumes a
-- Continue Watching card. Posters are fetched from TMDB lazily (only what is on screen plus the next
-- row), cached on disk, and shown with overlay-add. This product uses the TMDB API but is not
-- endorsed or certified by TMDB.
-- ============================================================
local HV = {
    r = 1, c = 1, want_vc = 1, top = 1, rows = {}, sig = nil,
    items = {}, sn = 0, dn = 0, convq = {}, converting = false, batch_n = 0,
    shown = {}, hover = nil, vis = {}, hit = {}, vis_cards = {}, wanted = {},
    last_data = nil, last_click_t = 0, last_click = nil, m = nil, mode = "home",
}
local TV = { req = {}, sn = 0, card = nil }     -- title page of one show (episodes with TMDB stills)
HV.tv = TV

HV.PS1 = [[
param([string]$Manifest)
Add-Type -AssemblyName System.Drawing
$fmt = [System.Drawing.Imaging.PixelFormat]::Format32bppPArgb
foreach ($line in [System.IO.File]::ReadAllLines($Manifest)) {
    $p = $line.Split('|')
    if ($p.Length -lt 4) { continue }
    try {
        $W = [int]$p[2]; $H = [int]$p[3]
        $src = [System.Drawing.Image]::FromFile($p[0])
        $bmp = New-Object System.Drawing.Bitmap($W, $H, $fmt)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.DrawImage($src, 0, 0, $W, $H)
        $g.Dispose(); $src.Dispose()
        $rect = New-Object System.Drawing.Rectangle(0, 0, $W, $H)
        $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, $fmt)
        $bytes = New-Object byte[] ($data.Stride * $H)
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
        $bmp.UnlockBits($data); $bmp.Dispose()
        [System.IO.File]::WriteAllBytes($p[1], $bytes)
    } catch { }
}
]]

local function hv_clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

function HV.active() return browser_active and MS.view == "home" end
-- The hero band is only shown while the first row is at the top; scrolling down gives the rows the full height.
function HV.rows_y(m) return (m.title and HV.top <= 1) and m.ry1 or m.ry0 end
function HV.kick() if HV.active() then render() end end

-- ---------- geometry ----------
function HV.metrics()
    local w, h = U.canvas_size()
    local pct = tonumber(o.home_card_pct) or 19
    local title = (HV.mode == "title")
    local cw = hv_clamp(math.floor(h * pct / 100 + 0.5), 90, 260)
    local lfs = math.max(12, math.floor(cw * 0.098))
    if title then
        cw = hv_clamp(math.floor(h * 0.33), 150, 420)       -- 16:9 episode stills
        lfs = math.max(12, math.floor(h * 0.0186))
    end
    local gap = math.max(10, math.floor(cw * 0.09))
    local per = math.max(2, math.floor((w - 48 + gap) / (cw + gap)))
    local used = per * cw + (per - 1) * gap
    local m = { w = w, h = h, cw = cw, ch = title and math.floor(cw * 9 / 16) or math.floor(cw * 1.5), gap = gap, per = per, lfs = lfs }
    m.title = title
    m.mx = math.floor((w - used) / 2)
    m.top_h = math.max(48, math.floor(lfs * 3.2))
    m.hero_h = title and math.floor(h * 0.27) or 0
    m.foot_h = math.max(44, math.floor(lfs * 3.5))
    m.sec_h = math.floor(lfs * 2.3)
    m.bar_h = 8
    m.line_h = math.floor(lfs * 1.3)
    m.label_h = m.line_h * 2 + math.floor(lfs * 1.2) + 6
    m.block_h = m.ch + m.bar_h + m.label_h + math.floor(lfs * 1.1)
    m.ry0, m.ry1 = m.top_h + 6, m.top_h + m.hero_h + 6     -- first row's y without / with the hero band
    m.sk = m.cw .. "x" .. m.ch
    return m
end

-- ---------- data ----------
-- Name of the folder whose title should be looked up: the folder itself or the nearest parent with a real title.
function PS.titled_name(p)
    for _ = 1, 4 do
        local pn = p:gsub("/+$", "")
        if pn == "" or pn == root_href:gsub("/+$", "") then return nil end
        local t = PS.title_of_name(U.basename(p))
        if t then return U.basename(p) end
        p = U.dirname(p)
    end
    return nil
end

-- Grouping key: every season of a show shares it ("Show.S01", "Show.S02" -> one card); movies keep their year.
function HV.gkey(name)
    local title, year = PS.title_of_name(name)
    local fp = o.experimental_clean_titles and CT.parse_folder(name) or nil
    title = title or name
    if o.merge_seasons and fp and fp.season then return PS.norm(title) end
    return PS.norm(title) .. "|" .. (year or "")
end

-- Everything the poster lookup and the grouping need to know about a folder name.
function HV.ident(name)
    local title, year = PS.title_of_name(name)
    local fp = o.experimental_clean_titles and CT.parse_folder(name) or nil
    title = title or name
    year = year or ""
    local kp = (fp and fp.season) and "tv" or (year ~= "" and "movie" or "")
    return { title = title, year = year, fp = fp, kindpref = kp, raw = name,
             key = PS.norm(title) .. "|" .. year .. "|" .. kp }
end

-- Grouping key: every season of a show shares it ("Show.S01", "Show.S02", "Show Season 1" -> one card); films keep their year.
function HV.gkey(name)
    local id = HV.ident(name)
    if o.merge_seasons and id.fp and id.fp.season then return PS.norm(id.title) end
    return PS.norm(id.title) .. "|" .. id.year
end

-- One detail part: text, colour, priority (the lowest priority is dropped first when the line is too long).
local function dp(t, col, prio) return { t = t, c = col, p = prio } end

function HV.chip_parts(chips, prio_base)
    local out = {}
    for _, ch in ipairs(chips or {}) do
        local pr = (ch == "4K" or ch == "1080p" or ch == "720p" or ch == "480p") and 8 or ((ch == "HDR" or ch == "HDR10+" or ch == "DV") and 6 or 5)
        out[#out + 1] = dp(ch, CT.chip_color(ch), pr)
    end
    return out
end

function HV.card_for_folder(e)
    local id = HV.ident(e.name)
    local fp = id.fp
    local parts = {}
    if fp then
        if fp.season then parts[#parts + 1] = dp(fp.season, THEME.text_muted, 9) end
        for _, p in ipairs(HV.chip_parts(fp.chips)) do parts[#parts + 1] = p end
        if fp.group then parts[#parts + 1] = dp(fp.group, THEME.text_dim, 7) end
    end
    return { kind = "folder", href = e.href, name = e.name, title = id.title, year = id.year, raw = e.name, kindpref = id.kindpref,
             parts = parts, key = id.key, gkey = HV.gkey(e.name), folders = { e }, mtime = e.mtime or 0 }
end

-- One card per show: folders with the same grouping key are merged (merge_seasons).
function HV.group_cards(dirs)
    local groups, order = {}, {}
    for _, e in ipairs(dirs) do
        local c = HV.card_for_folder(e)
        local g = o.merge_seasons and groups[c.gkey] or nil
        if g then
            g.folders[#g.folders + 1] = e
            if (e.mtime or 0) > g.mtime then g.mtime = e.mtime or 0 end
        else
            groups[c.gkey] = c
            order[#order + 1] = c
        end
    end
    for _, c in ipairs(order) do
        if #c.folders > 1 then
            table.sort(c.folders, function(a, b) return U.natural_less(a.name, b.name) end)
            local first, last = c.folders[1], c.folders[#c.folders]
            local f1 = HV.card_for_folder(first)
            local fl = HV.card_for_folder(last)
            c.href, c.name, c.raw = first.href, first.name, first.name
            c.title, c.year, c.key, c.kindpref = f1.title, f1.year, f1.key, f1.kindpref
            -- same title in several qualities/groups: say so, the title page lists each one
            local seasons = {}
            for _, f in ipairs(c.folders) do
                local fp = o.experimental_clean_titles and CT.parse_folder(f.name) or nil
                seasons[(fp and fp.season) or f.name] = true
            end
            local nseasons = 0
            for _ in pairs(seasons) do nseasons = nseasons + 1 end
            c.parts = {}
            if nseasons > 1 then c.parts[1] = dp(string.format("%d seasons", nseasons), THEME.text_muted, 9)
            else c.parts[1] = dp(string.format("%d versions", #c.folders), THEME.text_muted, 9) end
            for _, p in ipairs(HV.chip_parts(fl.parts and (function() local ch = {} for _, x in ipairs(fl.parts) do if CT.COLORS[x.t] then ch[#ch + 1] = x.t end end return ch end)())) do
                c.parts[#c.parts + 1] = p
            end
        end
    end
    -- two different titles that read the same (a 2019 film and a 2024 series): add the year / type to the label
    local count = {}
    for _, c in ipairs(order) do local k = PS.norm(c.title); count[k] = (count[k] or 0) + 1 end
    for _, c in ipairs(order) do
        if count[PS.norm(c.title)] > 1 then
            local tag = (c.year ~= "" and c.year) or ((c.kindpref == "tv") and "series" or "movie")
            if c.kindpref == "tv" and c.year ~= "" then tag = c.year .. " series" end
            c.shown = c.title .. " (" .. tag .. ")"
        end
    end
    return order
end

function HV.card_for_resume(e)
    local dir = e.dirpath or U.dirname(e.href)
    local tn = PS.titled_name(dir)
    local id = HV.ident(tn or U.basename(dir))
    local p = CT.parse(e.name)
    local hist = watch_history[e.href]
    local frac, parts = nil, {}
    if p and p.se then parts[#parts + 1] = dp(p.se, THEME.text_muted, 9) end
    if e.cw == "next" then
        parts[#parts + 1] = dp("Next up", THEME.accent, 9)
    elseif hist and hist.pos and hist.duration and hist.duration > 0 then
        frac = math.min(1, hist.pos / hist.duration)
        parts[#parts + 1] = dp(U.fmt_time(math.max(0, hist.duration - hist.pos)) .. " left", THEME.warn, 9)
    end
    return { kind = "play", entry = e, href = dir, name = e.name, title = id.title, year = id.year, raw = id.raw, kindpref = id.kindpref,
             parts = parts, frac = frac, key = id.key, gkey = tn and HV.gkey(tn) or dir }
end

HV.HOME_SORT = "webdav-browser://home"
function HV.sort_id()
    if HV.mode == "title" and TV.card then return "webdav-browser://title/" .. TV.card.key end
    return HV.HOME_SORT
end
function HV.sort_mode()
    local v = sort_by_dir[HV.sort_id()]
    if v == "recent" or v == "name" then return v end
    return (HV.mode == "home" and o.default_sort == "recent") and "recent" or "name"
end
function HV.toggle_sort()
    local nm = (HV.sort_mode() == "recent") and "name" or "recent"
    sort_by_dir[HV.sort_id()] = nm
    local sel = HV.selected()
    HV.reselect = sel and sel.key or nil
    HV.sig = nil
    status_line = "Sort: " .. (nm == "recent" and "Recent first" or (HV.mode == "title" and "Episode order" or "Name"))
    save_persistence()
    render()
end

-- Show cards for the library search (top-level folders that contain a match).
function HV.search_cards(groups)
    local out, seen = {}, {}
    local rootn = root_href:gsub("/+$", "")
    local byhref = {}
    for _, c in ipairs(groups) do for _, f in ipairs(c.folders) do byhref[f.href:gsub("/+$", "")] = c end end
    for _, r in ipairs(search_results or {}) do
        local h = (r.is_dir and r.href or r.dirpath or r.href):gsub("/+$", "")
        -- walk up to the top-level folder under the library root
        local guard = 0
        while guard < 12 and h ~= "" and not byhref[h] do
            local up = U.dirname(h .. "/"):gsub("/+$", "")
            if up == h then break end
            h = up
            guard = guard + 1
        end
        local c = byhref[h]
        if c and not seen[c] then seen[c] = true; out[#out + 1] = c end
    end
    return out
end

function HV.build(m)
    if HV.mode == "title" then return TV.build(m) end
    local rows = {}
    local root = find_cached_dir(root_href)
    local dirs = {}
    if root and type(root.entries) == "table" then
        for _, e in ipairs(root.entries) do if e.is_dir then dirs[#dirs + 1] = e end end
    end
    local groups = (#dirs > 0) and HV.group_cards(dirs) or {}

    if HV.q then      -- library search: results are poster cards of the matching shows
        local cards = HV.search_cards(groups)
        local q = HV.q
        local note = (MS.idx_running or not index_meta.last_full) and "  ·  index still building, results may be incomplete" or ""
        rows[1] = { title = string.format("Search \"%s\"  ·  %d title%s%s", q, #cards, #cards == 1 and "" or "s", note), cards = {}, off = 0 }
        local i = 1
        while i <= #cards do
            local part = {}
            for j = i, math.min(#cards, i + m.per - 1) do part[#part + 1] = cards[j] end
            rows[#rows + 1] = { title = (i == 1) and rows[1].title or nil, cards = part, off = 0 }
            i = i + m.per
        end
        if #cards == 0 then HV.search_empty = true else HV.search_empty = false; table.remove(rows, 1) end
        if #cards == 0 then rows = {} end
        return rows
    end

    local bygk = {}
    for _, c in ipairs(groups) do bygk[c.gkey] = c end
    if o.continue_row then
        local cards, seen = {}, {}
        for _, e in ipairs(get_continue_list() or {}) do
            local c = HV.card_for_resume(e)
            local gc = bygk[c.gkey]
            if gc then c.key, c.title, c.year, c.raw, c.kindpref, c.shown = gc.key, gc.title, gc.year, gc.raw, gc.kindpref, gc.shown end
            local d = o.merge_seasons and c.gkey or (e.dirpath or "")
            if not seen[d] then seen[d] = true; cards[#cards + 1] = c end
        end
        if #cards > 0 then table.insert(rows, 1, { title = "Continue Watching", cards = cards, shelf = true, off = 0 }) end
    end
    if #groups > 0 then
        local has_mtime = false
        for _, c in ipairs(groups) do if c.mtime > 0 then has_mtime = true break end end
        if has_mtime then
            local rec = {}
            for i, c in ipairs(groups) do rec[i] = c end
            table.sort(rec, function(a, b)
                if a.mtime ~= b.mtime then return a.mtime > b.mtime end
                return U.natural_less(a.name, b.name)
            end)
            local cards = {}
            for i = 1, math.min(#rec, tonumber(o.home_recent_count) or 20) do cards[i] = rec[i] end
            rows[#rows + 1] = { title = "Recently Added", cards = cards, shelf = true, off = 0 }
        end
        local all = {}
        for i, c in ipairs(groups) do all[i] = c end
        local recent = (HV.sort_mode() == "recent")
        table.sort(all, function(a, b)
            if recent and a.mtime ~= b.mtime then return a.mtime > b.mtime end
            return U.natural_less(a.title, b.title)
        end)
        local first = true
        local i = 1
        while i <= #all do
            local cards = {}
            for j = i, math.min(#all, i + m.per - 1) do cards[#cards + 1] = all[j] end
            rows[#rows + 1] = { title = first and string.format("All Titles  ·  %d  ·  Sort: %s (S)", #all, recent and "Recent" or "Name") or nil, cards = cards, off = 0 }
            first = false
            i = i + m.per
        end
    end
    return rows
end

-- ---------- selection ----------
function HV.clamp()
    local n = #HV.rows
    if n == 0 then HV.r, HV.c = 1, 1; return end
    HV.r = hv_clamp(HV.r, 1, n)
    HV.c = hv_clamp(HV.c, 1, #HV.rows[HV.r].cards)
end

function HV.fix_off(m)
    local row = HV.rows[HV.r]
    if not row or not row.shelf then return end
    if HV.c <= row.off then row.off = HV.c - 1
    elseif HV.c > row.off + m.per then row.off = HV.c - m.per end
    row.off = hv_clamp(row.off, 0, math.max(0, #row.cards - m.per))
end

function HV.vcol()
    local row = HV.rows[HV.r]
    return HV.c - ((row and row.off) or 0)
end

function HV.move(dr, dc)
    local m = HV.metrics()
    HV.m = m
    HV.clamp()
    if #HV.rows == 0 then return end
    if dc ~= 0 then
        local row = HV.rows[HV.r]
        local nc = HV.c + dc
        if nc < 1 then
            local prev = HV.rows[HV.r - 1]
            if not row.shelf and prev and not prev.shelf then HV.r = HV.r - 1; nc = #prev.cards else nc = 1 end
        elseif nc > #row.cards then
            local nxt = HV.rows[HV.r + 1]
            if not row.shelf and nxt and not nxt.shelf then HV.r = HV.r + 1; nc = 1 else nc = #row.cards end
        end
        HV.c = nc
        HV.fix_off(m)
        HV.want_vc = HV.vcol()
    end
    if dr ~= 0 then
        local nr = hv_clamp(HV.r + dr, 1, #HV.rows)
        HV.r = nr
        local row = HV.rows[nr]
        HV.c = hv_clamp((row.off or 0) + HV.want_vc, 1, #row.cards)
        HV.fix_off(m)
    end
    render()
end

function HV.edge(first)
    HV.clamp()
    if #HV.rows == 0 then return end
    if first then HV.r, HV.c = 1, 1 else HV.r = #HV.rows; HV.c = #HV.rows[HV.r].cards end
    HV.fix_off(HV.metrics())
    HV.want_vc = HV.vcol()
    render()
end

function HV.selected()
    HV.clamp()
    local row = HV.rows[HV.r]
    return row and row.cards[HV.c] or nil
end

-- ---------- poster pipeline ----------
function HV.lookup(w, st)
    PS.load_index()
    local ik = w.key
    local hit = PS.idx[ik]
    if hit ~= nil then
        if hit == false or hit.none then st.state = "none" else st.entry, st.state = hit, "entry" end
        st.tried = type(hit) == "table" and hit.tried or nil
        return
    end
    st.state = "searching"
    HV.sn = HV.sn + 1
    local qs = PS.queries(w.raw or w.title, w.title, w.year)
    st.tried = {}
    local i, any = 0, nil
    local function finish(r, q)
        HV.sn = HV.sn - 1
        if r == nil then return end
        if r == false then
            PS.idx[ik] = { none = true, tried = st.tried }
            PS.save_index()
            st.state = "none"
        else
            local entry = {
                id = tostring(r.id or "0"), name = r.name or r.title or "?", kind = r.media_type,
                year = (r.first_air_date or r.release_date or ""):sub(1, 4), poster_path = r.poster_path,
                overview = tostring(r.overview or ""):sub(1, 600), backdrop_path = r.backdrop_path or "",
                vote = tonumber(r.vote_average) or 0, q = q,
            }
            PS.idx[ik] = entry
            st.entry, st.state = entry, "entry"
        end
        HV.kick()
    end
    local function step()
        i = i + 1
        if i > #qs then
            if any then finish(any, "(closest result)") else finish(false) end
            return
        end
        st.tried[#st.tried + 1] = qs[i]
        PS.search(qs[i], w.year or "", nil, function(r, err, a)
            if r == nil then
                HV.sn = HV.sn - 1
                st.state, st.err, st.t = "error", err, mp.get_time()
                HV.kick()
                return
            end
            if r then finish(r, qs[i]) return end
            any = any or a
            step()
        end, w.kindpref, true)
    end
    step()
end

function HV.download(st)
    local e = st.entry
    local jpg = string.format("%s/p%s_w342.jpg", PS.dir(), e.id)
    st.jpg, st.base = jpg, "p" .. e.id
    local ji = utils.file_info(jpg)
    if ji and ji.size > 1000 then st.state = "jpg"; return end
    st.state = "downloading"
    HV.dn = HV.dn + 1
    PS.run({ o.curl_path, "-s", "-S", "-m", "30", "--create-dirs", "-o", jpg, o.tmdb_image_base .. "w342" .. e.poster_path },
        function(res)
            HV.dn = HV.dn - 1
            local info = utils.file_info(jpg)
            if not res or res.status ~= 0 or not info or info.size < 1000 then
                st.state, st.err, st.t = "error", "poster download failed", mp.get_time()
            else
                st.state = "jpg"
                PS.st_dirty = true
                PS.save_index()     -- the cache folder exists now
            end
            HV.kick()
        end)
end

function HV.want_bgra(st, dw, dh)
    local sk = dw .. "x" .. dh
    if st.bgra[sk] or st.cq[sk] then return end
    local bgra = string.format("%s/%s_%s.bgra", PS.dir(), st.base or ("p" .. st.entry.id), sk)
    local bi = utils.file_info(bgra)
    if bi and bi.size == dw * dh * 4 then st.bgra[sk] = bgra; return end
    st.cq[sk] = "queued"
    HV.convq[#HV.convq + 1] = { st = st, jpg = st.jpg, bgra = bgra, w = dw, h = dh, sk = sk }
end

function HV.convert_done(batch)
    for _, it in ipairs(batch) do
        local bi = utils.file_info(it.bgra)
        if bi and bi.size == it.w * it.h * 4 then
            it.st.bgra[it.sk] = it.bgra
            it.st.cq[it.sk] = "done"
        else
            it.st.cq[it.sk] = "fail"
        end
    end
    HV.converting = false
    PS.st_dirty = true
    HV.kick()
end

function HV.convert_pump()
    if HV.converting or #HV.convq == 0 then return end
    local batch = {}
    while #HV.convq > 0 and #batch < 12 do batch[#batch + 1] = table.remove(HV.convq, 1) end
    HV.converting = true
    local mode = o.poster_converter
    if mode == "auto" then mode = (package.config:sub(1, 1) == "\\") and "powershell" or "ffmpeg" end
    if mode == "powershell" then
        HV.batch_n = HV.batch_n + 1
        local manifest = string.format("%s/batch_%d.txt", PS.dir(), HV.batch_n % 4)
        local lines = {}
        for _, it in ipairs(batch) do lines[#lines + 1] = string.format("%s|%s|%d|%d", it.jpg, it.bgra, it.w, it.h) end
        local f = io.open(manifest, "wb")
        local ps = PS.dir() .. "/convert_batch.ps1"
        local f2 = io.open(ps, "wb")
        if not f or not f2 then
            if f then f:close() end
            if f2 then f2:close() end
            HV.convert_done(batch); return
        end
        f:write(table.concat(lines, "\n") .. "\n"); f:close()
        f2:write(HV.PS1); f2:close()
        PS.run({ "powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", ps, manifest },
            function() HV.convert_done(batch) end)
    else
        local i = 0
        local function nxt()
            i = i + 1
            local it = batch[i]
            if not it then HV.convert_done(batch); return end
            if mode == "ffmpeg" then
                PS.run({ o.ffmpeg_path, "-v", "error", "-y", "-i", it.jpg, "-vf", string.format("scale=%d:%d", it.w, it.h),
                         "-pix_fmt", "bgra", "-f", "rawvideo", it.bgra }, nxt)
            else
                PS.run({ o.magick_path, it.jpg, "-resize", string.format("%dx%d!", it.w, it.h), "-depth", "8", "bgra:" .. it.bgra }, nxt)
            end
        end
        nxt()
    end
end

function HV.pump()
    if not PS.enabled() then return end
    local m = HV.m
    local now = mp.get_time()
    for _, w in ipairs(HV.wanted) do
        local st = HV.items[w.key]
        if not st then
            st = { state = "new", bgra = {}, cq = {} }
            HV.items[w.key] = st
        end
        if st.state == "error" and st.t and now - st.t > 20 then st.state = "new" end
        if w.still then
            TV.pump_still(w, st, m)
        elseif w.kind == "ep" then
            -- no artwork source for this file (yet): nothing to look up
        else
            if st.state == "new" then
                if HV.sn < 3 then HV.lookup(w, st) end
            end
            if st.state == "entry" and HV.dn < 3 then HV.download(st) end
            if st.state == "jpg" then HV.want_bgra(st, w.dw or m.cw, w.dh or m.ch) end
        end
        if w.need then TV.ensure_season(w.need.entry, w.need.s) end
    end
    if TV.card and HV.mode == "title" then TV.ensure_details() end
    HV.convert_pump()
end

-- ---------- bitmaps on screen ----------
function HV.clear()
    for id in pairs(HV.shown) do pcall(mp.commandv, "overlay-remove", tostring(id)) end
    HV.shown = {}
end

function HV.place()
    local used = {}
    if not MS.debug then
        local sk = HV.m.sk
        for i, cd in ipairs(HV.vis_cards) do
            if i > 60 then break end
            local st = HV.items[cd.card.key]
            local f = st and st.bgra[sk]
            if f then
                local id = i - 1
                local sig = f .. "@" .. cd.x .. "," .. cd.y
                if HV.shown[id] ~= sig then
                    local ok = mp.commandv("overlay-add", tostring(id), tostring(cd.x), tostring(cd.y), f, "0", "bgra",
                        tostring(HV.m.cw), tostring(HV.m.ch), tostring(HV.m.cw * 4))
                    HV.shown[id] = ok and sig or nil
                end
                used[id] = true
            end
        end
    end
    -- hero poster (title page)
    local hero = HV.hero
    if hero and not MS.debug and HV.mode == "title" then
        local st = HV.items[hero.key]
        local f = st and st.bgra[hero.dw .. "x" .. hero.dh]
        if f then
            local sig = f .. "@" .. hero.x .. "," .. hero.y
            if HV.shown[61] ~= sig then
                local ok = mp.commandv("overlay-add", "61", tostring(hero.x), tostring(hero.y), f, "0", "bgra",
                    tostring(hero.dw), tostring(hero.dh), tostring(hero.dw * 4))
                HV.shown[61] = ok and sig or nil
            end
            used[61] = true
        end
    end
    for id in pairs(HV.shown) do
        if not used[id] then
            pcall(mp.commandv, "overlay-remove", tostring(id))
            HV.shown[id] = nil
        end
    end
end

-- ---------- drawing ----------
function HV.wrap2(text, maxw, fs)
    local words = {}
    for wd in tostring(text):gmatch("%S+") do words[#words + 1] = wd end
    local function width(s) return U.utf8_len(s) * fs * 0.62 end
    local l1, i = "", 1
    while i <= #words do
        local try = (l1 == "") and words[i] or (l1 .. " " .. words[i])
        if l1 == "" or width(try) <= maxw then l1 = try; i = i + 1 else break end
    end
    local l2 = (i <= #words) and table.concat(words, " ", i) or ""
    return U.fit_text(l1, maxw, fs), (l2 ~= "" and U.fit_text(l2, maxw, fs) or "")
end

-- Coloured detail line from {t, c, p} parts; the lowest-priority parts are dropped until it fits.
function HV.detail_ass(parts, maxw, fs, default_col)
    local list = {}
    for i, p in ipairs(parts or {}) do list[i] = p end
    local function width()
        local n = 0
        for i, p in ipairs(list) do n = n + U.utf8_len(p.t) + (i > 1 and 3 or 0) end
        return n * fs * 0.6
    end
    while #list > 1 and width() > maxw do
        local lo, idx = 99, #list
        for i = #list, 1, -1 do if list[i].p < lo then lo, idx = list[i].p, i end end
        table.remove(list, idx)
    end
    local out = {}
    for i, p in ipairs(list) do
        if i > 1 then out[#out + 1] = string.format("{\\c%s} · ", U.ass_color(THEME.text_dim)) end
        out[#out + 1] = string.format("{\\c%s}%s", U.ass_color(p.c or default_col or THEME.text_muted), U.ass_escape(p.t))
    end
    return table.concat(out)
end

-- "S02 · VARYG · 1080p": drop the least important parts until the line fits the card width.
function HV.fit_parts(parts, full, maxw, fs)
    parts = parts or {}
    local order = {}
    for i, p in ipairs(parts) do order[i] = p end
    while #order > 1 and U.utf8_len(table.concat(order, " · ")) * fs * 0.62 > maxw do
        -- chips (2nd entry when 3 parts, resolution) go first, then the group
        if #order >= 3 then table.remove(order, 2) else table.remove(order) end
    end
    return U.fit_text(table.concat(order, " · "), maxw, fs)
end

function HV.ensure_visible(m)
    HV.clamp()
    local guard = 0
    while guard < 500 do
        guard = guard + 1
        HV.top = hv_clamp(HV.top, 1, math.max(1, #HV.rows))
        if HV.r < HV.top then HV.top = HV.r
        else
            local last = HV.top
            local y = (m.title and HV.top <= 1) and m.ry1 or m.ry0
            for ri = HV.top, #HV.rows do
                local need = m.block_h + (HV.rows[ri].title and m.sec_h or 0)
                if y + need > m.h - m.foot_h and ri > HV.top then break end
                last = ri
                y = y + need
            end
            if last < HV.r and HV.top < HV.r then HV.top = HV.top + 1 else break end
        end
    end
end

HV.render = function()
    local m = HV.metrics()
    HV.m = m
    local root = find_cached_dir(root_href)
    local sig = table.concat({ HV.mode, tostring(root and root.entries), tostring(get_continue_list()), m.per, tostring(o.continue_row),
        tostring(o.merge_seasons), HV.sort_mode(), PS.eps_ver, MS.cache_version, TV.card and TV.card.key or "", m.cw }, "|")
    if sig ~= HV.sig then
        HV.sig = sig; HV.rows = HV.build(m); HV.clamp()
        if HV.reselect then
            for ri, row in ipairs(HV.rows) do
                for ci, cd in ipairs(row.cards) do
                    if cd.key == HV.reselect then HV.r, HV.c = ri, ci; HV.top = math.max(1, ri - 1) end
                end
            end
            HV.reselect = nil
            HV.fix_off(m); HV.want_vc = HV.vcol()
        end
    end
    overlay.res_x, overlay.res_y = m.w, m.h
    HV.prune_bgra()
    HV.fix_off(m)
    HV.ensure_visible(m)
    HV.ensure_visible(m)       -- once more: the hero band appears / disappears as the top row changes

    local w, h, lfs = m.w, m.h, m.lfs
    local chunks = {}
    local function add(c) chunks[#chunks + 1] = c end
    add(D.ev_rect(0, 0, w, h, THEME.bg_dim, 100, nil, 0, 0))

    -- top bar
    add(D.ev_rect(0, 0, w, m.top_h, THEME.bg_header, 100, nil, 0, 0))
    add(D.ev_rect(0, m.top_h - 2, w, m.top_h, U.pick(o.color_border_grad_top, "909090"), 30, nil, 0, 0))
    add(D.ev_text(m.mx, m.top_h / 2, 4, string.format("\\b1\\fs%d\\c%s", lfs + 10, U.ass_color(THEME.accent)),
        (m.title and TV.card) and U.ass_escape(U.fit_text("‹  " .. TV.card.title, w * 0.5, lfs + 10)) or "WebDAV Library"))
    local any_fail = listing_error[root_href]
    local right = (any_fail and "error") or (is_loading and "loading…") or "connected"
    add(D.ev_text(w - 22, m.top_h / 2, 5, string.format("\\b1\\fs%d\\c%s", lfs + 10, U.ass_color(THEME.text_muted)), "×"))
    add(D.ev_text(w - 50, m.top_h / 2, 6, string.format("\\fs%d\\c%s", lfs, U.ass_color(any_fail and THEME.bad or THEME.text_muted)),
        U.ass_escape(right)))
    add(D.ev_text(w - 50 - U.utf8_len(right) * lfs * 0.62 - 18, m.top_h / 2, 6,
        string.format("\\fs%d\\c%s", lfs + 4, U.ass_color(any_fail and THEME.bad or THEME.good)), "●"))
    if HV.q and not m.title then
        local bx1, bx2 = math.floor(w * 0.26), math.floor(w * 0.70)
        add(D.ev_rect(bx1, m.top_h * 0.16, bx2, m.top_h * 0.84, THEME.bg_panel, 100, THEME.accent, HV.typing and 100 or 35, 1, 8))
        add(D.ev_text(bx1 + 14, m.top_h / 2, 4, string.format("\\fs%d\\c%s", lfs + 2, U.ass_color(THEME.text_primary)),
            U.ass_escape(U.fit_text("Search:  " .. HV.q, bx2 - bx1 - 40, lfs + 2)) .. (HV.typing and string.format("{\\c%s}▏", U.ass_color(THEME.accent)) or "")))
    elseif status_line and status_line ~= "" and status_line ~= "Ready" and not status_line:match("^Loaded") then
        add(D.ev_text(w / 2, m.top_h / 2, 5, string.format("\\fs%d\\c%s", lfs, U.ass_color(status_line:match("^Failed") and THEME.bad or THEME.text_muted)),
            U.ass_escape(U.fit_text(status_line, w * 0.4, lfs))))
    end

    HV.hit, HV.vis_cards, HV.wanted = {}, {}, {}
    if m.title and TV.card and HV.top <= 1 then
        local hw, hh = TV.hero_size(m)
        HV.wanted[1] = { key = TV.card.key, title = TV.card.title, year = TV.card.year, dw = hw, dh = hh }
    end
    local vis = {}
    local y = HV.rows_y(m)
    for ri = HV.top, #HV.rows do
        local row = HV.rows[ri]
        local need = m.block_h + (row.title and m.sec_h or 0)
        if y + need > h - m.foot_h and #vis > 0 then break end
        vis[#vis + 1] = { ri = ri, ty = y, y = y + (row.title and m.sec_h or 0) }
        y = y + need
    end
    HV.vis = vis

    HV.hero = nil
    if m.title and TV.card and HV.top <= 1 then TV.draw_hero(add, m) end

    if #HV.rows == 0 then
        local msg_ = any_fail and ("⚠  " .. tostring(any_fail) .. "     (press R to retry)") or (is_loading and "Loading library…" or "No folders found")
        if HV.q then msg_ = (HV.q == "") and "Type to search the library" or ("No titles match \"" .. HV.q .. "\"" .. ((MS.idx_running or not index_meta.last_full) and "   (the library index is still building)" or "")) end
        add(D.ev_text(w / 2, h / 2, 5, string.format("\\fs%d\\c%s", lfs + 6, U.ass_color(any_fail and THEME.bad or THEME.text_muted)), U.ass_escape(msg_)))
    end

    for _, v in ipairs(vis) do
        local row = HV.rows[v.ri]
        if row.title then
            add(D.ev_text(m.mx, v.ty + m.sec_h * 0.55, 4, string.format("\\b1\\fs%d\\c%s", lfs + 6, U.ass_color(THEME.text_primary)), U.ass_escape(row.title)))
        end
        local off = row.off or 0
        for i = 1, m.per do
            local ci = off + i
            local card = row.cards[ci]
            if not card then break end
            local x = m.mx + (i - 1) * (m.cw + m.gap)
            local py = v.y
            local sel = (v.ri == HV.r and ci == HV.c)
            local hov = HV.hover and HV.hover.r == v.ri and HV.hover.c == ci
            local st = HV.items[card.key]
            local ready = st and st.bgra[m.sk] and not MS.debug
            HV.vis_cards[#HV.vis_cards + 1] = { card = card, x = x, y = py }
            HV.wanted[#HV.wanted + 1] = card
            HV.hit[#HV.hit + 1] = { x1 = x, y1 = py, x2 = x + m.cw, y2 = py + m.ch + m.bar_h + m.label_h, r = v.ri, c = ci }

            if not ready then
                add(D.ev_rect(x, py, x + m.cw, py + m.ch, THEME.bg_panel, 100, nil, 0, 0, 6))
                local ptxt = card.ph or card.shown or card.title
                local t1, t2 = HV.wrap2(ptxt, m.cw - 16, lfs + 3)
                add(D.ev_text(x + m.cw / 2, py + m.ch / 2 - (t2 ~= "" and lfs or 0), 5, string.format("\\b1\\fs%d\\c%s", lfs + 3, U.ass_color(THEME.text_muted)), U.ass_escape(t1)))
                if t2 ~= "" then
                    add(D.ev_text(x + m.cw / 2, py + m.ch / 2 + lfs * 0.9, 5, string.format("\\b1\\fs%d\\c%s", lfs + 3, U.ass_color(THEME.text_muted)), U.ass_escape(t2)))
                end
                if PS.enabled() and st and (st.state == "new" or st.state == "searching" or st.state == "entry" or st.state == "downloading" or st.state == "jpg") and not (st.cq and st.cq[m.sk] == "fail") then
                    add(D.ev_text(x + m.cw / 2, py + m.ch - lfs * 1.6, 5, string.format("\\fs%d\\c%s", lfs, U.ass_color(THEME.text_dim)), "…"))
                end
            end
            -- ring (outside the picture so the bitmap does not cover it)
            if sel or hov then
                add(D.ev_rect(x - 4, py - 4, x + m.cw + 4, py + m.ch + 4, "FFFFFF", 0, sel and THEME.accent or THEME.text_dim, 100, sel and 3 or 2, 8))
            end
            -- progress bar (Continue Watching)
            if card.frac then
                add(D.ev_rect(x, py + m.ch + 3, x + m.cw, py + m.ch + 3 + 4, THEME.track, 100, nil, 0, 0, 2))
                add(D.ev_rect(x, py + m.ch + 3, x + math.max(4, m.cw * card.frac), py + m.ch + 3 + 4, THEME.accent, 100, nil, 0, 0, 2))
            end
            -- label: clean title (up to 2 lines) + muted detail line
            local ly = py + m.ch + m.bar_h + 4
            local t1, t2 = HV.wrap2(card.shown or card.title, m.cw, lfs)
            local tcol = (sel or hov) and "FFFFFF" or "F2EEFA"      -- bright titles; the ring shows the selection
            add(D.ev_text(x, ly, 7, string.format("\\b1\\fs%d\\c%s", lfs, U.ass_color(tcol)), U.ass_escape(t1)))
            if t2 ~= "" then
                add(D.ev_text(x, ly + m.line_h, 7, string.format("\\b1\\fs%d\\c%s", lfs, U.ass_color(tcol)), U.ass_escape(t2)))
            end
            if card.parts and #card.parts > 0 then
                add(D.ev_text(x, ly + m.line_h * ((t2 ~= "") and 2 or 1) + 2, 7, string.format("\\fs%d\\c%s", lfs - 2, U.ass_color(THEME.text_muted)),
                    HV.detail_ass(card.parts, m.cw, lfs - 2)))
            end
        end
        -- shelf arrows
        if row.shelf then
            local mid = v.y + m.ch / 2
            if off > 0 then add(D.ev_text(m.mx / 2, mid, 5, string.format("\\b1\\fs%d\\c%s", lfs + 14, U.ass_color(THEME.text_muted)), "‹")) end
            if off + m.per < #row.cards then add(D.ev_text(w - m.mx / 2, mid, 5, string.format("\\b1\\fs%d\\c%s", lfs + 14, U.ass_color(THEME.text_muted)), "›")) end
        end
    end
    -- extend the wanted list with the next row so it is ready before you scroll to it
    do
        local lastv = vis[#vis]
        local nrow = lastv and HV.rows[lastv.ri + 1]
        if nrow then
            for i = 1, m.per do
                local cd = nrow.cards[(nrow.off or 0) + i]
                if cd then HV.wanted[#HV.wanted + 1] = cd end
            end
        end
    end

    -- footer
    add(D.ev_rect(0, h - m.foot_h, w, h, THEME.bg_header, 100, nil, 0, 0))
    add(D.ev_rect(0, h - m.foot_h, w, h - m.foot_h + 2, U.pick(o.color_border_grad_top, "909090"), 30, nil, 0, 0))
    local ckey = tostring(o.cache_clear_key or ""):match("[^%s,]+") or ""
    local hint
    if HV.q and not m.title then
        hint = HV.typing and "Type to search   ←↑↓→ Move   Enter Open   Backspace Delete   Esc Clear search"
            or "←↑↓→ Move   Enter Open   F Edit search   Esc Clear search"
    elseif m.title then
        hint = "←↑↓→ Move   Enter Play   A Queue   M Watched   S Sort: " .. (HV.sort_mode() == "recent" and "Recent" or "Order") ..
            "   V List   T Re-fetch art   " .. ckey:upper() .. " Clear cache   Esc Back"
    else
        hint = "←↑↓→ Move   Enter Open / Play   S Sort: " .. (HV.sort_mode() == "recent" and "Recent" or "Name") ..
            "   O List   F Search all   T Re-fetch art   " .. ckey:upper() .. " Clear cache   R Refresh   Esc Close"
    end
    add(D.ev_text(m.mx, h - m.foot_h * 0.68, 4, string.format("\\fs%d\\c%s", lfs - 1, U.ass_color(THEME.text_muted)),
        U.ass_escape(U.fit_text(hint, w - 2 * m.mx, lfs - 1))))
    local attr = "This product uses the TMDB API but is not endorsed or certified by TMDB."
    if o.tmdb_key == "" then attr = "Set tmdb_key in webdav-browser.conf to show posters.  " .. attr end
    local cs = PS.stats()
    local ctext = string.format("Cache %s  ·  %d images", U.fmt_bytes(cs.bytes), cs.imgs)
    local cw_px = U.utf8_len(ctext) * (lfs - 3) * 0.62
    add(D.ev_text(m.mx, h - m.foot_h * 0.28, 4, string.format("\\fs%d\\c%s", lfs - 3, U.ass_color(THEME.text_dim)),
        U.ass_escape(U.fit_text(attr, w - 2 * m.mx - cw_px - 30, lfs - 3))))
    add(D.ev_text(w - m.mx, h - m.foot_h * 0.28, 6, string.format("\\fs%d\\c%s", lfs - 3, U.ass_color(HV.clear_armed and THEME.warn or THEME.text_muted)),
        U.ass_escape(ctext)))

    -- debug panel (posters are hidden while it is open, because bitmaps draw above all text)
    if MS.debug then
        local lines = build_debug_lines()
        local dfs = math.max(11, lfs - 1)
        local lh = math.floor(dfs * 1.55)
        local dw = math.min(math.floor(w * 0.5), 760)
        local dx2, dy1 = w - 16, m.top_h + 12
        local dx1, dy2 = dx2 - dw, dy1 + #lines * lh + 16
        add(D.ev_rect(dx1, dy1, dx2, dy2, THEME.bg_header, 92, THEME.accent, 60, 1, 6))
        for i, line in ipairs(lines) do
            add(D.ev_text(dx1 + 12, dy1 + 8 + (i - 0.5) * lh, 4, string.format("\\fs%d\\c%s%s", dfs, U.ass_color(i == 1 and THEME.accent or THEME.text_primary), i == 1 and "\\b1" or ""),
                U.ass_escape(U.fit_text(line, dw - 24, dfs))))
        end
    end

    local data = table.concat(chunks, "\n")
    if data ~= HV.last_data then
        HV.last_data = data
        overlay.data = data
        overlay:update()
    end
    HV.place()
    HV.pump()
end

-- ============================================================
-- TITLE PAGE  (one show: hero + episode stills grouped by season)
-- ============================================================
function TV.season_of(name)
    local fp = o.experimental_clean_titles and CT.parse_folder(name) or nil
    if fp and fp.season then
        local n = fp.season:match("^S(%d+)$") or fp.season:match("^S(%d+)E")
        if n then return tonumber(n) end
    end
    local n = name:match("[Ss]eason[%s%._%-]*(%d+)") or name:match("^[Ss](%d%d?)$")
    return n and tonumber(n) or nil
end

function TV.se_of(name, hint)
    local cp = CT.parse(name)
    local s, e
    if cp and cp.se then
        s, e = cp.se:match("^S(%d+)E(%d+)$")
        if not s then e = cp.se:match("^E(%d+)$") end
    end
    if not e then
        local a, b = name:match("(%d%d?)x(%d%d%d?)")
        if a then s, e = a, b end
    end
    s, e = tonumber(s), tonumber(e)
    if e and not s then s = hint or 1 end
    return s or hint, e
end

function TV.clean_name(name)
    local cp = CT.parse(name)
    if cp and cp.title and cp.title ~= "" then return cp.title .. (cp.year and (" (" .. cp.year .. ")") or "") end
    return (name:gsub("%.[%w]+$", ""):gsub("[%._]+", " "))
end

function TV.ensure(href)
    local now = mp.get_time()
    if TV.req[href] and now - TV.req[href] < 45 then return end
    TV.req[href] = now
    fetch_listing(href, { silent = true })
end

function TV.show_entry()
    local card = TV.card
    if not card or not PS.enabled() then return nil end
    PS.load_index()
    local e = PS.idx[card.key]
    if type(e) == "table" and not e.none and e.id then return e end
    return nil
end

-- All media files of the show (its folders, plus one level of sub-folders such as "Season 1").
function TV.collect()
    local card = TV.card
    local list, loading = {}, 0
    local function visit(folder, depth, hint, top)
        top = top or folder
        local c = find_cached_dir(folder.href)
        if not c or type(c.entries) ~= "table" then TV.ensure(folder.href); loading = loading + 1; return end
        if not cache_is_fresh(c) then TV.ensure(folder.href) end     -- show what we have, refresh quietly
        for _, e in ipairs(c.entries) do
            if e.is_dir then
                if depth < 1 then visit(e, depth + 1, TV.season_of(e.name) or hint, top) end
            elseif U.is_media(e.name) then
                local s, n = TV.se_of(e.name, hint)
                list[#list + 1] = { entry = e, s = s, e = n, folder = folder, top = top }
            end
        end
    end
    for _, f in ipairs(card.folders or {}) do visit(f, 0, TV.season_of(f.name)) end
    return list, loading
end

local function tv_natural(a, b)
    local as, bs = a.s or 0, b.s or 0
    if as ~= bs then return as < bs end
    if a.e and b.e and a.e ~= b.e then return a.e < b.e end
    if (a.e ~= nil) ~= (b.e ~= nil) then return a.e ~= nil end
    return U.natural_less(a.entry.name, b.entry.name)
end

-- Episode info for file (s, e): TMDB's own season first; when TMDB has no such season (or it is shorter), the file's running
-- number is mapped onto TMDB's seasons instead (shows TMDB numbers continuously, absolute-numbered anime...).
-- returns info|nil, season used, episode used, needs-a-season-fetch
function TV.info_for(show, ep, offs)
    if not (show and show.kind ~= "movie" and ep.e) then return nil end
    PS.load_eps()
    local s = ep.s or 1
    local sc = type(show.sc) == "table" and show.sc or nil
    local direct = true
    if sc then
        local cnt = tonumber(sc[tostring(s)])
        if not cnt or ep.e > cnt then direct = false end
    end
    if direct then
        local rec = PS.eps[show.id .. ":" .. s]
        if rec == nil then return nil, s, ep.e, true end
        local info = PS.ep_info(show, s, ep.e)
        if info then return info, s, ep.e end
        if not sc then return nil, s, ep.e end
    end
    if sc then
        local keys = {}
        for k in pairs(sc) do if tonumber(k) and tonumber(k) > 0 then keys[#keys + 1] = tonumber(k) end end
        table.sort(keys)
        local n = (offs[ep.s or 0] or 0) + ep.e
        for _, k in ipairs(keys) do
            local c = tonumber(sc[tostring(k)]) or 0
            if n <= c then
                local rec = PS.eps[show.id .. ":" .. k]
                if rec == nil then return nil, k, n, true end
                return PS.ep_info(show, k, n), k, n
            end
            n = n - c
        end
    end
    return nil, s, ep.e
end

function TV.build(m)
    local card = TV.card
    if not card then return {} end
    local eps, loading = TV.collect()
    TV.loading = loading
    table.sort(eps, tv_natural)
    TV.ordered = eps
    local show = TV.show_entry()
    local recent = (HV.sort_mode() == "recent")

    local seasons, order = {}, {}
    for _, ep in ipairs(eps) do
        local k = ep.s or 0
        if not seasons[k] then seasons[k] = {}; order[#order + 1] = k end
        table.insert(seasons[k], ep)
    end
    table.sort(order)

    -- how many episodes each local season holds, to map running numbers onto TMDB's seasons
    local counts, offs, run = {}, {}, 0
    for _, ep in ipairs(eps) do local k = ep.s or 0; counts[k] = math.max(counts[k] or 0, ep.e or 0, 1) end
    for _, k in ipairs(order) do offs[k] = run; run = run + counts[k] end
    local allmovie = true
    for _, ep in ipairs(eps) do if ep.e then allmovie = false break end end

    local function make_card(ep)
        local e = ep.entry
        local info, ts, te, need = TV.info_for(show, ep, offs)
        local nm = info and info.n ~= "" and info.n or nil
        local c = { kind = "ep", ep = ep, entry = e, name = e.name, year = "" }
        if ep.e then
            c.title = ep.e .. ". " .. (nm or ("Episode " .. ep.e))
            c.ph = "Episode " .. ep.e
        else
            c.title = (#eps == 1 or allmovie) and (card.shown or card.title) or TV.clean_name(e.name)
        end
        local parts = {}
        local hist = watch_history[e.href]
        if watched_set[e.href] then
            c.watched = true
            parts[#parts + 1] = dp("✓ Watched", THEME.good, 10)
        elseif hist and hist.pos and hist.duration and hist.duration > 0 then
            c.frac = math.min(1, hist.pos / hist.duration)
            parts[#parts + 1] = dp(U.fmt_time(math.max(0, hist.duration - hist.pos)) .. " left", THEME.warn, 10)
        end
        local cp = CT.parse(e.name)
        local ffp = o.experimental_clean_titles and CT.parse_folder((ep.top or ep.folder).name) or nil
        local chips = (cp and cp.chips and #cp.chips > 0) and cp.chips or (ffp and ffp.chips) or {}
        for _, p in ipairs(HV.chip_parts(chips)) do parts[#parts + 1] = p end
        if ffp and ffp.group then parts[#parts + 1] = dp(ffp.group, THEME.text_dim, 7) end
        if info and info.v and info.v > 0 then parts[#parts + 1] = dp(string.format("★ %.1f", info.v), THEME.warn, 4) end
        if e.size and e.size > 0 then parts[#parts + 1] = dp(U.fmt_bytes(e.size), THEME.text_muted, 3) end
        if info and info.r and info.r > 0 then parts[#parts + 1] = dp(info.r .. " min", THEME.text_muted, 2) end
        c.parts = parts
        if info and info.st and info.st ~= "" then
            c.key = string.format("still:%s:%d:%d", show.id, ts, te)
            c.still = { size = "w300", path = info.st, base = string.format("s%s_%d_%d", show.id, ts, te) }
        elseif show and not ep.e and show.backdrop_path and show.backdrop_path ~= "" then
            c.key = "bd:" .. show.id
            c.still = { size = "w300", path = show.backdrop_path, base = "b" .. show.id }
        else
            c.key = "file:" .. e.href
            if need then c.need = { entry = show, s = ts } end
        end
        if ep.e and show then
            c.dbg = string.format("S%sE%s -> TMDB S%sE%s%s", tostring(ep.s), tostring(ep.e), tostring(ts), tostring(te),
                info and (info.st ~= "" and " (still)" or " (no still on TMDB)") or (need and " (fetching)" or " (no data)"))
        end
        c.href = card.href
        return c
    end

    local rows = {}
    for _, k in ipairs(order) do
        local list = seasons[k]
        if recent then
            table.sort(list, function(a, b)
                local am, bm = a.entry.mtime or 0, b.entry.mtime or 0
                if am ~= bm then return am > bm end
                return tv_natural(a, b)
            end)
        end
        local title
        if k > 0 then title = string.format("Season %d  ·  %d episode%s", k, #list, #list == 1 and "" or "s")
        elseif #order == 1 and #list == 1 then title = nil
        else title = string.format("Files  ·  %d", #list) end
        local first = true
        local i = 1
        while i <= #list do
            local cards = {}
            for j = i, math.min(#list, i + m.per - 1) do cards[#cards + 1] = make_card(list[j]) end
            rows[#rows + 1] = { title = first and title or nil, cards = cards, off = 0 }
            first = false
            i = i + m.per
        end
    end
    TV.count, TV.seasons, TV.allmovie = #eps, #order, allmovie
    return rows
end

-- Converted bitmaps (.bgra) are re-creatable and one set exists per window size; keep only the sizes in use now
-- so resizing the window over months cannot pile up hundreds of MB. Downloaded images and TMDB data are never pruned.
function HV.prune_bgra()
    if HV.pruned or not PS.enabled() then return end
    HV.pruned = true
    local keep = {}
    local saved = HV.mode
    for _, md in ipairs({ "home", "title" }) do
        HV.mode = md
        local m = HV.metrics()
        keep[m.cw .. "x" .. m.ch] = true
        if md == "title" then local hw, hh = TV.hero_size(m); keep[hw .. "x" .. hh] = true end
    end
    HV.mode = saved
    local dir = PS.dir()
    local list = utils.readdir(dir, "files")
    if type(list) ~= "table" then return end
    for _, f in ipairs(list) do
        local dims = f:match("_(%d+x%d+)%.bgra$")
        if dims and not keep[dims] then pcall(os.remove, dir .. "/" .. f) end
    end
    PS.st_dirty = true
end

-- ---- background work for the page ----
function TV.ensure_season(show, s)
    if not (show and show.id and s) then return end
    PS.load_eps()
    local key = show.id .. ":" .. s
    if PS.eps[key] ~= nil or TV.season_busy and TV.season_busy[key] then return end
    if TV.sn >= 2 then return end
    TV.season_busy = TV.season_busy or {}
    TV.season_busy[key] = true
    TV.sn = TV.sn + 1
    PS.season(show, s, function(err)
        TV.sn = TV.sn - 1
        if err then   -- network trouble: allow a retry after a while, nothing is stored
            mp.add_timeout(30, function() TV.season_busy[key] = nil end)
        else
            TV.season_busy[key] = nil
        end
        HV.kick()
    end)
end

function TV.ensure_details()
    local e = TV.show_entry()
    if not e or e.detail then return end
    if TV.det_busy == e.id then return end
    TV.det_busy = e.id
    PS.details(e, function() HV.kick() end)
end

function TV.pump_still(w, st, m)
    if st.state == "new" then
        if HV.dn >= 3 then return end
        local sp = w.still
        st.base = sp.base
        st.jpg = string.format("%s/%s_%s.jpg", PS.dir(), sp.base, sp.size)
        st.state = "downloading"
        HV.dn = HV.dn + 1
        PS.fetch_image(sp.size, sp.path, st.jpg, function(ok)
            HV.dn = HV.dn - 1
            if ok then st.state = "jpg"; PS.st_dirty = true
            else st.state, st.t, st.err = "error", mp.get_time(), "still download failed" end
            HV.kick()
        end)
    elseif st.state == "jpg" then
        HV.want_bgra(st, m.cw, m.ch)
    end
end

-- ---- hero (poster + title + overview) ----
function TV.hero_size(m)
    local hh = m.hero_h - 20
    return math.floor(hh * 2 / 3), hh
end

function TV.wrap(text, maxw, fs, maxlines)
    local words = {}
    for wd in tostring(text):gmatch("%S+") do words[#words + 1] = wd end
    local lines, cur = {}, ""
    local i = 1
    while i <= #words do
        local try = (cur == "") and words[i] or (cur .. " " .. words[i])
        if cur == "" or U.utf8_len(try) * fs * 0.55 <= maxw then cur = try; i = i + 1
        else
            lines[#lines + 1] = cur; cur = ""
            if #lines >= maxlines then break end
        end
    end
    if cur ~= "" and #lines < maxlines then lines[#lines + 1] = cur
    elseif i <= #words and #lines >= maxlines then lines[#lines] = U.fit_text(lines[#lines] .. " " .. table.concat(words, " ", i), maxw, fs) end
    return lines
end

function TV.draw_hero(add, m)
    local card, lfs, w = TV.card, m.lfs, m.w
    local hw, hh = TV.hero_size(m)
    local x0, y0 = m.mx, m.top_h + 10
    local st = HV.items[card.key]
    local ready = st and st.bgra[hw .. "x" .. hh] and not MS.debug
    HV.hero = { key = card.key, x = x0, y = y0, dw = hw, dh = hh }
    if not ready then
        add(D.ev_rect(x0, y0, x0 + hw, y0 + hh, THEME.bg_panel, 100, nil, 0, 0, 6))
        add(D.ev_text(x0 + hw / 2, y0 + hh / 2, 5, string.format("\\fs%d\\c%s", lfs, U.ass_color(THEME.text_dim)), PS.enabled() and "…" or ""))
    end
    local show = TV.show_entry()
    local tx = x0 + hw + 26
    local maxw = w - tx - m.mx
    add(D.ev_text(tx, y0 + lfs * 1.1, 4, string.format("\\b1\\fs%d\\c%s", lfs + 14, "FFFFFF"), U.ass_escape(U.fit_text(card.shown or card.title, maxw, lfs + 14))))
    local meta = {}
    local year
    if not cut then
        local init2 = 1
        while true do
            local a, _, y = lower:find("[%._%s%(%[](%d%d%d%d)[%._%s%)%]]", init2)
            if not a then break end
            if y:sub(1, 2) == "19" or y:sub(1, 2) == "20" then year = y; cut = a - 1; break end
            init2 = a + 1
        end
    end
    if not cut then
        local best
        for _, tok in ipairs(CT.TOKENS) do
            local a = lower:find("[%._%s%-%[%(]" .. tok)
            if a and (not best or a < best) then best = a end
        end
        if best then cut = best - 1 end
    end
    if not cut and not se_label then return false end

    local title = base:sub(1, cut or #base)
    title = title:gsub("^%b[]%s*", "")
    title = title:gsub("[%._]+", " "):gsub("%s+", " "):gsub("^[%s%-]+", ""):gsub("[%s%-%(%[]+$", "")
    if title == "" and not se_label then return false end

    local chips = {}
    local function has(pat) return lower:find(pat) ~= nil end
    if has("2160p") or has("%f[%w]4k%f[%W]") or has("%f[%a]uhd%f[%A]") then chips[#chips + 1] = "4K"
    elseif has("1080[pi]") then chips[#chips + 1] = "1080p"
    elseif has("720p") then chips[#chips + 1] = "720p"
    elseif has("480p") then chips[#chips + 1] = "480p" end
    if has("hdr10%+") or has("hdr10plus") then chips[#chips + 1] = "HDR10+"
    elseif has("%f[%a]hdr%f[%A]") then chips[#chips + 1] = "HDR" end
    if has("%f[%a]dv%f[%A]") or has("dovi") or has("dolby[%._%s%-]?vision") then chips[#chips + 1] = "DV" end
    if has("atmos") then chips[#chips + 1] = "ATMOS" end
    if has("remux") then chips[#chips + 1] = "REMUX" end
    if has("dual[%._%s%-]?audio") then chips[#chips + 1] = "DUAL" end

    return {
        title = title, se = se_label, year = year, chips = chips,
        label = se_label or (title .. (year and (" (" .. year .. ")") or "")),
    }
end

function CT.parse(name)
    local hit = CT.cache[name]
    if hit ~= nil then return hit end
    local ok, res = pcall(CT.parse_raw, name)
    if not ok then res = false end
    CT.count = CT.count + 1
    if CT.count > 6000 then CT.cache, CT.count = {}, 1 end
    CT.cache[name] = res
    return res
end

-- true when every parsed media file in the list shares one show title (then the title is redundant
-- on each row and only "S01E03" is shown)
function CT.uniform_title(items)
    local first, seen = nil, 0
    for _, it in ipairs(items) do
        if not it.is_dir and U.is_media(it.name) then
            local cp = CT.parse(it.name)
            if cp then
                local tl = cp.title:lower()
                if first == nil then first = tl elseif first ~= tl then return false end
                seen = seen + 1
                if seen >= 60 then break end
            end
        end
    end
    return true
end

-- ---- folder names: "MASHLE.MAGIC.AND.MUSCLES.S01.1080p.BluRay.REMUX.AVC.FLAC.2.0-NAN0" ----
--   -> title "Mashle Magic and Muscles", season "S01", chips {1080p, REMUX}, group "NAN0"
CT.GROUP_BLOCK = { dl = true, hd = true, rip = true, ma = true, hdr = true, dv = true, webdl = true, hevc = true,
    x264 = true, x265 = true, h264 = true, h265 = true, avc = true, aac = true, dts = true, ac3 = true, flac = true }
CT.SMALL_WORDS = { a = true, an = true, ["and"] = true, as = true, at = true, but = true, by = true, ["for"] = true,
    ["in"] = true, of = true, on = true, ["or"] = true, the = true, to = true, vs = true }

-- Only names that are ALL upper or ALL lower case get re-cased; mixed case is how the release was named.
function CT.titlecase(str)
    if str:find("%l") and str:find("%u") then return str end
    local out, first = {}, true
    for w in str:gmatch("%S+") do
        local lw = w:lower()
        if not first and CT.SMALL_WORDS[lw] then out[#out + 1] = lw
        else out[#out + 1] = lw:sub(1, 1):upper() .. lw:sub(2) end
        first = false
    end
    return table.concat(out, " ")
end

function CT.chips_for(lower)
    local chips = {}
    local function has(pat) return lower:find(pat) ~= nil end
    if has("2160p") or has("%f[%w]4k%f[%W]") or has("%f[%a]uhd%f[%A]") then chips[#chips + 1] = "4K"
    elseif has("1080[pi]") then chips[#chips + 1] = "1080p"
    elseif has("720p") then chips[#chips + 1] = "720p"
    elseif has("480p") then chips[#chips + 1] = "480p" end
    if has("hdr10%+") or has("hdr10plus") then chips[#chips + 1] = "HDR10+"
    elseif has("%f[%a]hdr%f[%A]") then chips[#chips + 1] = "HDR" end
    if has("%f[%a]dv%f[%A]") or has("dovi") or has("dolby[%._%s%-]?vision") then chips[#chips + 1] = "DV" end
    if has("atmos") then chips[#chips + 1] = "ATMOS" end
    if has("remux") then chips[#chips + 1] = "REMUX" end
    if has("dual[%._%s%-]?audio") then chips[#chips + 1] = "DUAL" end
    return chips
end

function CT.parse_folder_raw(name)
    local base = name
    local group
    local lead = base:match("^%[([^%]]+)%]")                 -- anime style: "[SubsPlease] Show ..."
    if lead and #lead >= 2 and #lead <= 24 then group = lead end
    local body = base:gsub("^%b[]%s*", "")
    body = body:gsub("%s*%b[]%s*$", "")                       -- trailing [site]/[hash] tags
    local g = body:match("%-([%w_]+)$")                       -- scene style: "...-GROUP"
    if g and not group and #g >= 2 and #g <= 20 and not CT.GROUP_BLOCK[g:lower()] and not g:match("^%d+$") then
        group = g
        body = body:sub(1, #body - #g - 1)
    end

    local lower = body:lower()
    local ls = lower .. "."
    local cut, season, year
    local function mark(a) if a and (not cut or a < cut) then cut = a end end

    local a, _, s1, s2 = ls:find("[%._%s%(%[%-]s(%d%d?)%-s?(%d%d?)[%._%s%)%]%-]")
    if a then season = string.format("S%02d-S%02d", tonumber(s1), tonumber(s2)); mark(a) end
    if not season then
        local b, _, sn, ep = ls:find("[%._%s%(%[%-]s(%d%d?)e(%d%d%d?)[%._%s%)%]%-]")
        if b then season = string.format("S%02dE%02d", tonumber(sn), tonumber(ep)); mark(b) end
    end
    if not season then
        local b, _, sn = ls:find("[%._%s%(%[%-]s(%d%d?)[%._%s%)%]%-]")
        if b then season = string.format("S%02d", tonumber(sn)); mark(b) end
    end
    if not season then
        local b, _, sn = ls:find("[%._%s%(%[%-]season[%._%s]*(%d%d?)[%._%s%)%]%-]")
        if b then season = string.format("S%02d", tonumber(sn)); mark(b) end
    end
    local ca = ls:find("[%._%s%(%[%-]complete[%._%s%)%]%-]")
    if ca then
        mark(ca)
        if not season then season = "Complete" end
    end
    local init = 1
    while true do
        local b, _, y = ls:find("[%._%s%(%[](%d%d%d%d)[%._%s%)%]]", init)
        if not b then break end
        if y:sub(1, 2) == "19" or y:sub(1, 2) == "20" then year = y; mark(b); break end
        init = b + 1
    end
    for _, tok in ipairs(CT.TOKENS) do
        mark(ls:find("[%._%s%-%[%(]" .. tok))
    end

    if not cut and not group then return false end
    local title = body:sub(1, (cut or (#body + 1)) - 1)
    title = title:gsub("[%._]+", " "):gsub("%s+", " ")
    title = title:gsub("^[%s%-]+", ""):gsub("[%s%-%(%[]+$", "")
    local anime_ep = title:match("%s%-%s(%d%d?%d?)$")         -- anime "Show - 12"
    if anime_ep then
        title = title:gsub("%s%-%s%d%d?%d?$", "")
        if not season then season = string.format("E%02d", tonumber(anime_ep)) end
    end
    if title == "" then return false end

    return {
        title = CT.titlecase(title), season = season, year = year, group = group,
        chips = CT.chips_for(lower),
    }
end

CT.fcache, CT.fcount = {}, 0
function CT.parse_folder(name)
    local hit = CT.fcache[name]
    if hit ~= nil then return hit end
    local ok, res = pcall(CT.parse_folder_raw, name)
    if not ok then res = false end
    CT.fcount = CT.fcount + 1
    if CT.fcount > 3000 then CT.fcache, CT.fcount = {}, 1 end
    CT.fcache[name] = res
    return res
end

CT.COLORS = {
    ["4K"] = "accent", ["1080p"] = "muted", ["720p"] = "muted", ["480p"] = "muted",
    ["HDR"] = "warn", ["HDR10+"] = "warn", ["DV"] = "audio", ["ATMOS"] = "video",
    ["REMUX"] = "good", ["DUAL"] = "folder", ["NEXT"] = "accent",
}
function CT.chip_color(label)
    local k = CT.COLORS[label]
    if k == "accent" then return THEME.accent elseif k == "muted" then return THEME.text_muted
    elseif k == "warn" then return THEME.warn elseif k == "audio" then return THEME.audio
    elseif k == "video" then return THEME.video elseif k == "good" then return THEME.good
    elseif k == "folder" then return THEME.folder end
    return THEME.warn   -- resume-time chips
end

-- ============================================================
-- ROW DRAWING (continued)
-- ============================================================
local function draw_sidebar_rows(chunks, hitboxes, rect)
    local header_h = layout.panel_header_h
    local row_h = layout.row_h
    local fs = layout.fs
    local items = get_panel_items("sidebar")
    local selected_idx = sidebar_selected_index
    local scroll_off = scroll_offset_folders
    local vis = visible_rows_for(rect, header_h, row_h)
    local focused = (focus_panel == "sidebar")
    local tree_mode = not (search_scope == "sidebar" and search_query ~= "")

    local body_x1, body_y1 = rect.x1 + 1, rect.y1 + header_h
    local body_x2, body_y2 = rect.x2 - 1, rect.y2 - 1
    local clip = D.clip_tag(body_x1, body_y1, body_x2, body_y2)

    local last_idx = math.min(#items, scroll_off + vis)
    for i = scroll_off + 1, last_idx do
        local node = items[i]
        local row_y1 = body_y1 + (i - scroll_off - 1) * row_h
        local row_y2 = math.min(row_y1 + row_h, body_y2)
        local is_sel = focused and (i == selected_idx)
        local is_hov = (hover_panel == "sidebar" and hover_index == i and not is_sel)

        if is_sel then
            table.insert(chunks, D.ev_rect(rect.x1 + 2, row_y1 + 1, rect.x2 - 2, row_y2 - 1, THEME.accent, 18, nil, 0, 0, o.corner_radius_row))
            table.insert(chunks, D.ev_rect(rect.x1 + 2, row_y1 + 1, rect.x1 + 5, row_y2 - 1, THEME.accent, 100, nil, 0, 0, o.corner_radius_small))
        elseif is_hov then
            table.insert(chunks, D.ev_rect(rect.x1 + 2, row_y1 + 1, rect.x2 - 2, row_y2 - 1, "FFFFFF", 7, nil, 0, 0, o.corner_radius_row))
        end

        local icon, icon_col
        if node.virtual then
            icon, icon_col = "★", THEME.warn
        elseif node.loading then
            icon, icon_col = spinner_frames[spinner_idx], THEME.text_muted
        elseif node.loaded and #node.children == 0 then
            icon, icon_col = ICONS.folder_empty, THEME.text_dim
        elseif node.expanded then
            icon, icon_col = ICONS.folder_open, THEME.folder
        else
            icon, icon_col = ICONS.folder_closed, THEME.folder
        end

        local indent = tree_mode and (math.min(node.depth, o.max_indent_levels) * o.indent_px) or 0
        local arrow_x = rect.x1 + 14 + indent
        local name_x = arrow_x + (tree_mode and 18 or 0)
        local name_y = row_y1 + row_h / 2

        -- expand/collapse arrow: its own click target (toggles WITHOUT opening the folder)
        if tree_mode and not node.virtual and not (node.loaded and #node.children == 0) then
            table.insert(chunks, D.ev_text(arrow_x + 6, name_y, 5,
                string.format("%s\\fs%d\\c%s", clip, fs - 4, U.ass_color(is_sel and THEME.accent or THEME.text_muted)),
                node.expanded and "▾" or "▸"))
            table.insert(hitboxes, {
                panel = "sidebar", index = i, arrow = true,
                x1 = arrow_x - 6, y1 = row_y1, x2 = arrow_x + 20, y2 = row_y2,
            })
        end

        local name_col
        if is_sel then
            name_col = THEME.accent
        elseif node.virtual then
            name_col = THEME.warn
        elseif focused then
            name_col = THEME.text_primary
        else
            name_col = THEME.text_muted
        end

        local active_marker = ""
        if node.href == current_path then
            active_marker = string.format("{\\c%s}%s ", U.ass_color(THEME.accent), ICONS.active_marker)
        end

        local max_name_px = math.max(20, rect.x2 - name_x - 40)
        local display_name = U.fit_text(node.name, max_name_px, fs)
        local suffix = node.virtual and "" or "/"
        local count_txt = ""
        if node.virtual then
            count_txt = string.format("  {\\c%s}%d", U.ass_color(THEME.text_dim), #get_continue_list())
        end

        -- cleaned folder name: Title  S01  1080p REMUX  GROUP   (extras are dropped, last first, if the row is narrow)
        local fp = (o.experimental_clean_titles and o.clean_folder_titles and not node.virtual) and CT.parse_folder(node.name) or nil
        if fp then
            local budget = max_name_px - 30 - (node.href == current_path and 16 or 0)
            local title_min = math.min(U.utf8_len(fp.title) * fs * 0.62, fs * 0.62 * 14)
            local used, extras = 0, {}
            local function add_extra(text, size, col)
                local w = (U.utf8_len(text) + 2) * size * 0.58
                if budget - used - w >= title_min then
                    used = used + w
                    extras[#extras + 1] = string.format("  {\\fs%d\\c%s}%s", size, U.ass_color(col), U.ass_escape(text))
                end
            end
            if fp.season then add_extra(fp.season, fs - 4, THEME.text_muted) end
            if fp.group then add_extra(fp.group, fs - 6, THEME.audio) end
            if o.clean_titles_chips then
                local chip_txt = {}
                for _, c in ipairs(fp.chips) do chip_txt[#chip_txt + 1] = c end
                for k = 1, math.min(#chip_txt, 3) do add_extra(chip_txt[k], fs - 8, CT.chip_color(chip_txt[k])) end
            end
            display_name = U.fit_text(fp.title, budget - used, fs)
            suffix = table.concat(extras)
        end

        local line = string.format("%s{\\c%s}%s  {\\c%s}%s%s%s",
            active_marker, U.ass_color(icon_col), icon, U.ass_color(name_col), U.ass_escape(display_name), suffix, count_txt)

        table.insert(chunks, D.ev_text(name_x, name_y, 4, string.format("%s\\fs%d", clip, fs), line))

        table.insert(hitboxes, {
            panel = "sidebar", index = i,
            x1 = rect.x1, y1 = row_y1, x2 = rect.x2, y2 = row_y2,
        })
    end

    if #items == 0 then
        local msg2 = (search_scope == "sidebar" and search_query ~= "") and "(no matches)" or "(no subfolders)"
        table.insert(chunks, D.ev_text(rect.x1 + 14, rect.y1 + header_h + 22, 4,
            string.format("\\i1\\fs%d\\c%s", fs - 4, U.ass_color(THEME.text_dim)), msg2))
    end

    draw_scrollbar(chunks, rect, header_h, scroll_off, #items, vis, "sidebar")
    if last_idx < #items then
        table.insert(chunks, D.ev_text((rect.x1 + rect.x2) / 2, rect.y2 - 10, 5,
            string.format("\\fs%d\\c%s", fs - 8, U.ass_color(THEME.accent)), "▼"))
    end
end

local function draw_episode_rows(chunks, hitboxes, rect)
    local header_h = layout.panel_header_h
    local row_h = layout.row_h
    local fs = layout.fs
    local items = get_panel_items("episodes")
    local selected_idx = selected_episode
    local scroll_off = scroll_offset_episodes
    local vis = visible_rows_for(rect, header_h, row_h)
    local focused = (focus_panel == "episodes")
    local is_global = (search_scope == "global")

    local body_x1, body_y1 = rect.x1 + 1, rect.y1 + header_h
    local body_x2, body_y2 = rect.x2 - 1, rect.y2 - 1
    local clip = D.clip_tag(body_x1, body_y1, body_x2, body_y2)

    local clean = o.experimental_clean_titles and not is_global
    local uniform = clean and CT.uniform_title(items)
    local cfs = math.max(10, fs - 8)

    -- draws one chip with its LEFT edge at x_left; returns the next chip's left edge
    local function draw_chip(x_left, cy, label, color)
        local w = U.utf8_len(label) * cfs * 0.62 + 12
        local x2 = x_left + w
        table.insert(chunks, D.ev_rect(x_left, cy - cfs * 0.78, x2, cy + cfs * 0.78, color, 16, color, 45, 1, o.corner_radius_small))
        table.insert(chunks, D.ev_text((x_left + x2) / 2, cy, 5,
            string.format("%s\\b1\\fs%d\\c%s", clip, cfs, U.ass_color(color)), U.ass_escape(label)))
        return x2 + 5
    end

    local last_idx = math.min(#items, scroll_off + vis)
    for i = scroll_off + 1, last_idx do
        local item = items[i]
        local row_y1 = body_y1 + (i - scroll_off - 1) * row_h
        local row_y2 = math.min(row_y1 + row_h, body_y2)
        local is_sel = focused and (i == selected_idx)
        local is_hov = (hover_panel == "episodes" and hover_index == i and not is_sel)

        if is_sel then
            table.insert(chunks, D.ev_rect(rect.x1 + 2, row_y1 + 1, rect.x2 - 2, row_y2 - 1, THEME.accent, 18, nil, 0, 0, o.corner_radius_row))
            table.insert(chunks, D.ev_rect(rect.x1 + 2, row_y1 + 1, rect.x1 + 5, row_y2 - 1, THEME.accent, 100, nil, 0, 0, o.corner_radius_small))
        elseif is_hov then
            table.insert(chunks, D.ev_rect(rect.x1 + 2, row_y1 + 1, rect.x2 - 2, row_y2 - 1, "FFFFFF", 7, nil, 0, 0, o.corner_radius_row))
        end

        local icon, icon_col
        if item.is_dir then
            icon, icon_col = ICONS.folder_closed, THEME.folder
        elseif U.is_video(item.name) then
            icon, icon_col = ICONS.video, THEME.video
        elseif U.is_audio(item.name) then
            icon, icon_col = ICONS.audio, THEME.audio
        else
            icon, icon_col = ICONS.file, THEME.file
        end

        local name_x = rect.x1 + 14
        local name_y = row_y1 + row_h / 2
        local name_col = is_sel and THEME.accent or (focused and THEME.text_primary or THEME.text_muted)
        local scroll_pad = (#items > vis) and 10 or 0

        -- right-hand text: path (search results / continue list) or size
        local right_text, right_col = nil, THEME.text_muted
        local hist = watch_history[item.href]
        local use_right_status = o.show_status_text and not is_global and not item.cw and not item.is_dir
        if use_right_status then
            if watched_set[item.href] then
                right_text, right_col = ICONS.watched .. " " .. tostring(o.watched_label or "Watched"), THEME.good
            elseif hist and hist.pos and hist.duration and hist.duration > 0 then
                local pct = math.floor(math.min(1, hist.pos / hist.duration) * 100)
                right_text, right_col = string.format("%s %d%% - %s left", ICONS.watching, pct,
                    U.fmt_time(math.max(0, hist.duration - hist.pos))), THEME.warn
            end
        end
        if is_global then
            right_text = U.fit_text(U.percent_decode(item.dirpath or ""):gsub("^/", ""), (rect.x2 - rect.x1) * 0.34, fs - 6)
            if right_text == "" then right_text = "/" end
        elseif item.cw then
            right_text = U.fit_text(U.basename(item.dirpath or ""), (rect.x2 - rect.x1) * 0.30, fs - 6)
        end
        local right_w = right_text and (U.utf8_len(right_text) * (fs - 6) * 0.55 + 22) or 18
        right_w = right_w + scroll_pad

        -- clean title + chips
        local cp = (clean and not item.is_dir and U.is_media(item.name)) and CT.parse(item.name) or nil
        local shown_name, name_suffix = item.name, ""
        local chip_labels = {}
        if cp then
            if cp.se then
                shown_name = cp.se
                if not uniform and cp.title ~= "" then
                    name_suffix = string.format("  {\\fs%d\\c%s}%s", fs - 4, U.ass_color(THEME.text_muted), U.ass_escape(cp.title))
                end
            else
                shown_name = cp.label
            end
            if o.clean_titles_chips then
                for _, c in ipairs(cp.chips) do chip_labels[#chip_labels + 1] = c end
            end
        end
        if item.cw == "next" then table.insert(chip_labels, 1, "NEXT") end
        if item.cw == "resume" and hist and hist.pos then table.insert(chip_labels, 1, U.fmt_time(hist.pos)) end

        local chips_w = 0
        for _, c in ipairs(chip_labels) do chips_w = chips_w + U.utf8_len(c) * cfs * 0.62 + 12 + 5 end
        local size_text = (not item.is_dir and item.size and item.size > 0) and U.fmt_bytes(item.size) or nil
        local size_w = size_text and (U.utf8_len(size_text) * (fs - 6) * 0.55 + 14) or 0

        local status = ""
        if o.show_watched_status and not use_right_status then
            if watched_set[item.href] then
                status = string.format("{\\c%s} %s", U.ass_color(THEME.good), ICONS.watched)
            elseif hist then
                status = string.format("{\\c%s} %s", U.ass_color(THEME.warn), ICONS.watching)
            end
        end

        local icon_w_est = 30
        local status_w_est = (status ~= "") and 26 or 0
        local suffix_w_est = (name_suffix ~= "") and (U.utf8_len(cp and cp.title or "") * (fs - 4) * 0.55 + 14) or 0
        -- Narrow panel? Give up the extras in priority order (size, then chips, then the status words)
        -- so the name always keeps a readable minimum.
        do
            local keep_px = math.min(U.utf8_len(shown_name) * fs * 0.62, fs * 0.62 * 12)
            local avail = rect.x2 - name_x - icon_w_est - status_w_est - suffix_w_est - 14
            if avail - right_w - chips_w - size_w < keep_px then size_text, size_w = nil, 0 end
            if avail - right_w - chips_w < keep_px then chip_labels, chips_w = {}, 0 end
            if avail - right_w < keep_px and use_right_status and right_text then
                right_text = right_text:match("^%S+")        -- just the tick / progress icon
                right_w = U.utf8_len(right_text) * (fs - 6) * 0.55 + 22 + scroll_pad
            end
        end
        local max_name_px = math.max(20, rect.x2 - name_x - right_w - chips_w - size_w - icon_w_est - status_w_est - suffix_w_est)
        local display_name = U.fit_text(shown_name, max_name_px, fs)
        if item.is_dir then display_name = display_name .. "/" end

        local line = string.format("{\\c%s}%s  {\\c%s}%s%s%s",
            U.ass_color(icon_col), icon, U.ass_color(name_col), U.ass_escape(display_name), name_suffix, status)
        table.insert(chunks, D.ev_text(name_x, name_y, 4, string.format("%s\\fs%d", clip, fs), line))

        if right_text then
            table.insert(chunks, D.ev_text(rect.x2 - 16 - scroll_pad, name_y, 6,
                string.format("%s\\fs%d\\c%s", clip, fs - 6, U.ass_color(right_col)),
                U.ass_escape(right_text)))
        end

        -- chips and size sit right after the name (estimated end of the text), not at the row's edge
        local cx = name_x + icon_w_est + U.utf8_len(display_name) * fs * 0.58 + suffix_w_est + status_w_est + 8
        local limit = rect.x2 - right_w - 4
        for k = 1, #chip_labels do
            if cx > limit then break end
            cx = draw_chip(cx, name_y, chip_labels[k], CT.chip_color(chip_labels[k]))
        end
        if size_text and cx + size_w <= limit + 8 then
            table.insert(chunks, D.ev_text(cx + 2, name_y, 4,
                string.format("%s\\fs%d\\c%s", clip, fs - 6, U.ass_color(THEME.text_dim)), U.ass_escape(size_text)))
        end

        if hist and hist.pos and hist.duration and hist.duration > 0 and not item.is_dir then
            local pct = math.min(1, hist.pos / hist.duration)
            local bx1, bx2 = name_x, rect.x2 - 14
            local by1, by2 = row_y2 - 4, row_y2 - 2
            table.insert(chunks, D.ev_rect(bx1, by1, bx2, by2, THEME.track, 100, nil, 0, 0, o.corner_radius_small))
            table.insert(chunks, D.ev_rect(bx1, by1, bx1 + (bx2 - bx1) * pct, by2, THEME.accent, 100, nil, 0, 0, o.corner_radius_small))
        end

        table.insert(hitboxes, {
            panel = "episodes", index = i,
            x1 = rect.x1, y1 = row_y1, x2 = rect.x2, y2 = row_y2,
        })
    end

    if #items == 0 then
        local msg2 = "(no files)"
        if is_global then
            msg2 = (search_query == "") and "Type to search the folders you have opened" or "(no matches in the folders you have opened)"
        elseif search_scope == "episodes" and search_query ~= "" then
            msg2 = "(no matches)"
        elseif current_path == CW_HREF then
            msg2 = "Nothing to continue yet - watch something and it will show up here"
        elseif hide_watched and #file_entries > 0 then
            msg2 = "(everything here is watched - press H to show watched files)"
        end
        table.insert(chunks, D.ev_text(rect.x1 + 14, rect.y1 + header_h + 22, 4,
            string.format("\\i1\\fs%d\\c%s", fs - 4, U.ass_color(THEME.text_dim)), U.ass_escape(msg2)))
    end

    draw_scrollbar(chunks, rect, header_h, scroll_off, #items, vis, "episodes")
    if last_idx < #items then
        table.insert(chunks, D.ev_text((rect.x1 + rect.x2) / 2, rect.y2 - 10, 5,
            string.format("\\fs%d\\c%s", fs - 8, U.ass_color(THEME.accent)), "▼"))
    end
end

-- ============================================================
-- MAIN RENDER
-- ============================================================
-- ---------- debug overlay ('d') ----------
function U.table_count(tbl) local n = 0 for _ in pairs(tbl) do n = n + 1 end return n end

local function build_debug_lines()
    local L = {}
    local dirs, items = IDX.count_items()
    local cached = find_cached_dir(current_path)
    local rs = req_stats.last
    L[#L + 1] = "DEBUG  -  webdav-browser " .. SCRIPT_VERSION
    L[#L + 1] = "folder: " .. current_path
    L[#L + 1] = "listing: " .. (cached and (string.format("cached %s (%s)", U.fmt_age(cached.ts),
        cache_is_fresh(cached) and "fresh" or "stale")) or "not cached")
    L[#L + 1] = string.format("cache: %d folders, %d items, ttl %ds", dirs, items, o.cache_ttl)
    if rs then
        L[#L + 1] = "last request: " .. rs.path
        L[#L + 1] = string.format("   %d ms   HTTP %s   attempts %d   %s", rs.ms or 0, tostring(rs.code or "-"),
            rs.attempts or 1, U.fmt_age(rs.ts))
        if rs.err then L[#L + 1] = "   error: " .. rs.err end
    else
        L[#L + 1] = "last request: none yet"
    end
    L[#L + 1] = string.format("requests: %d total, %d failed, %d in flight", req_stats.total, req_stats.failures, req_stats.pending)
    L[#L + 1] = IDX.summary()
    L[#L + 1] = string.format("persistence: %s%s", persist_status.ok and "ok" or ("FAILED - " .. tostring(persist_status.err)),
        persist_status.last_save and (", saved " .. U.fmt_age(persist_status.last_save)) or ", not saved yet")
    L[#L + 1] = "data file: " .. tostring(persist_status.path)
    L[#L + 1] = string.format("auth: %s    blur: %s", o.scoped_auth and "scoped (file-local)" or "session-wide", MS.blur_state or "off")
    do
        local ok, chain = pcall(mp.get_property_native, "vf")
        local names = {}
        if ok and type(chain) == "table" then
            for _, f in ipairs(chain) do names[#names + 1] = (f.label and ("@" .. f.label) or tostring(f.name)) end
        end
        L[#L + 1] = "video filters: " .. (#names > 0 and table.concat(names, ", ") or "none")
    end
    do
        local fb = MS.fb
        if fb.active then
            L[#L + 1] = string.format("download-play: %s %s / %s%s", fb.playing and "playing" or "buffering",
                U.fmt_bytes(fb.size or 0), fb.total and U.fmt_bytes(fb.total) or "?", fb.done and "  (complete)" or "")
        end
    end
    L[#L + 1] = string.format("credentials: user '%s', password %d chars, curl via %s", o.user, #o.pass, U.auth_mode())
    for _, n in ipairs(U.conf_notes or {}) do L[#L + 1] = "config: " .. n end
    L[#L + 1] = string.format("watch tracking: %d in progress, %d watched", U.table_count(watch_history), U.table_count(watched_set))
    local errs = U.table_count(listing_error)
    if errs > 0 then L[#L + 1] = string.format("folders with errors: %d", errs) end
    return L
end

-- ============================================================
-- MAIN RENDER
-- ============================================================
render = function()
    if not browser_active then
        overlay:remove()
        MS.last_overlay_data = nil
        return
    end

    layout = compute_layout()
    keep_selection_in_view()

    local w, h = layout.w, layout.h
    local sidebar, list = layout.sidebar, layout.list
    local fs = layout.fs
    local chunks, hitboxes, buttons = {}, {}, {}
    local cur_err = listing_error[current_path]
    local any_fail = cur_err or listing_error[root_href]

    table.insert(chunks, D.ev_rect(0, 0, w, h, THEME.bg_dim, o.dim_background_pct, nil, 0, 0))

    -- ---- header ----
    table.insert(chunks, D.ev_rect(0, 0, w, layout.header_h, THEME.bg_header, o.header_opacity, nil, 0, 0))
    table.insert(chunks, D.ev_rect(0, layout.header_h - 2, w, layout.header_h,
        U.pick(o.color_border_grad_top, "909090"), 35, nil, 0, 0))
    table.insert(chunks, D.ev_text(14, layout.header_h / 2 - 8, 4,
        string.format("\\b1\\fs%d\\c%s", fs + 4, U.ass_color(THEME.text_primary)), "WebDAV Browser"))
    table.insert(chunks, D.ev_text(14, layout.header_h / 2 + 12, 4,
        string.format("\\fs%d\\c%s", fs - 6, U.ass_color(THEME.text_muted)), U.ass_escape(host_label)))

    local dot = any_fail and THEME.bad or THEME.good
    table.insert(chunks, D.ev_text(w - 110, layout.header_h / 2, 6,
        string.format("\\fs%d\\c%s", fs - 2, U.ass_color(dot)), "●"))
    table.insert(chunks, D.ev_text(w - 96, layout.header_h / 2, 4,
        string.format("\\fs%d\\c%s", fs - 6, U.ass_color(THEME.text_muted)),
        any_fail and "error" or "connected"))
    if IDX.running then
        table.insert(chunks, D.ev_text(w - 128, layout.header_h / 2, 6,
            string.format("\\fs%d\\c%s", fs - 6, U.ass_color(THEME.accent)),
            string.format("%s indexing %d", spinner_frames[spinner_idx], IDX.scanned)))
    end

    local cx1, cy1, cx2, cy2 = w - 40, 8, w - 12, layout.header_h - 8
    table.insert(chunks, D.ev_text((cx1 + cx2) / 2, (cy1 + cy2) / 2, 5,
        string.format("\\b1\\fs%d\\c%s", fs + 2, U.ass_color(THEME.text_muted)), "×"))
    table.insert(buttons, { x1 = cx1 - 6, y1 = cy1 - 4, x2 = cx2 + 6, y2 = cy2 + 4, action = "close" })

    local function paint_panel(rect, focused)
        local bg = focused and THEME.bg_panel or THEME.bg_panel_dim
        local bw = focused and o.border_width_focus or o.border_width_unfocus
        local border_alpha = focused and math.min(100, o.border_alpha + 18) or o.border_alpha

        table.insert(chunks, D.ev_rect(rect.x1, rect.y1, rect.x2, rect.y2, bg, o.panel_opacity, nil, 0, 0, o.corner_radius))

        if o.border_gradient_enabled then
            D.draw_gradient_border(chunks, rect.x1, rect.y1, rect.x2, rect.y2, o.corner_radius, bw,
                { U.pick(o.color_border_grad_top, "909090"),
                  U.pick(o.color_border_grad_mid, "404040"),
                  U.pick(o.color_border_grad_bottom, "909090") },
                border_alpha)
        else
            table.insert(chunks, D.ev_rect(rect.x1, rect.y1, rect.x2, rect.y2, THEME.border_unfocus, 0, THEME.border_unfocus, border_alpha, bw, o.corner_radius))
        end

        if o.glass_highlight_enabled then
            D.draw_glass_highlight(chunks, rect.x1, rect.y1, rect.x2, rect.y2, o.corner_radius, bw)
        end
    end
    paint_panel(sidebar, focus_panel == "sidebar")
    paint_panel(list,    focus_panel == "episodes")

    -- ---- Folders panel header ----
    local sb_focus = focus_panel == "sidebar"
    table.insert(chunks, D.ev_text(sidebar.x1 + 12, sidebar.y1 + 16, 4,
        string.format("\\b1\\fs%d\\c%s", fs, U.ass_color(sb_focus and THEME.accent or THEME.text_primary)),
        (sb_focus and "▸  " or "") .. "Folders"))

    if search_scope == "sidebar" and search_active then
        draw_search_indicator(chunks, sidebar, sidebar.y1 + layout.sub_line_y, #get_panel_items("sidebar"), true)
    elseif search_scope == "sidebar" and search_query ~= "" then
        draw_search_indicator(chunks, sidebar, sidebar.y1 + layout.sub_line_y, #get_panel_items("sidebar"), false)
    else
        local crumb = (current_path == CW_HREF) and "Continue Watching"
            or build_breadcrumb(current_path, sidebar.x2 - sidebar.x1 - 24)
        table.insert(chunks, D.ev_text(sidebar.x1 + 12, sidebar.y1 + layout.sub_line_y, 4,
            string.format("\\fs%d\\c%s", fs - 6, U.ass_color(THEME.text_muted)), U.ass_escape(crumb)))
    end

    table.insert(buttons, {
        x1 = sidebar.x1, y1 = sidebar.y1, x2 = sidebar.x2, y2 = sidebar.y1 + layout.panel_header_h,
        action = "focus_sidebar",
    })

    -- ---- Files panel header ----
    local ep_focus = focus_panel == "episodes"
    local title
    if search_scope == "global" then title = "Search: whole library"
    elseif current_path == CW_HREF then title = "Continue Watching"
    else
        title = U.basename(current_path)
        if title == "" then title = "Root" end
        if o.experimental_clean_titles and o.clean_folder_titles then
            local fp = CT.parse_folder(title)
            if fp then
                title = fp.title .. (fp.season and ("  " .. fp.season) or "") .. (fp.group and ("  " .. fp.group) or "")
            end
        end
    end
    table.insert(chunks, D.ev_text(list.x1 + 12, list.y1 + 16, 4,
        string.format("\\b1\\fs%d\\c%s", fs, U.ass_color(ep_focus and THEME.accent or THEME.text_primary)),
        (ep_focus and "▸  " or "") .. U.ass_escape(U.fit_text(title, (list.x2 - list.x1) * 0.55, fs))))

    local ep_items = get_panel_items("episodes")
    local vis_ep = visible_rows_for(list, layout.panel_header_h, layout.row_h)

    if search_scope == "global" and search_active then
        draw_search_indicator(chunks, list, list.y1 + layout.sub_line_y, MS.global_total, true)
    elseif search_scope == "global" and search_query ~= "" then
        draw_search_indicator(chunks, list, list.y1 + layout.sub_line_y, MS.global_total, false)
    elseif search_scope == "episodes" and search_active then
        draw_search_indicator(chunks, list, list.y1 + layout.sub_line_y, #ep_items, true)
    elseif search_scope == "episodes" and search_query ~= "" then
        draw_search_indicator(chunks, list, list.y1 + layout.sub_line_y, #ep_items, false)
    else
        local from = math.min(#ep_items, scroll_offset_episodes + 1)
        local to   = math.min(#ep_items, scroll_offset_episodes + vis_ep)
        local range = (#ep_items == 0) and "0 files" or string.format("%d–%d / %d files", from, to, #ep_items)
        if hide_watched and current_path ~= CW_HREF then range = range .. "   (watched hidden)" end
        table.insert(chunks, D.ev_text(list.x1 + 12, list.y1 + layout.sub_line_y, 4,
            string.format("\\fs%d\\c%s", fs - 6, U.ass_color(THEME.text_muted)), U.ass_escape(range)))
    end

    -- sort chip (per-folder sort memory); not shown for virtual lists
    if current_path ~= CW_HREF and search_scope ~= "global" then
        local recent = (sort_mode_for(current_path) == "recent")
        table.insert(chunks, D.ev_rect(list.x2 - 120, list.y1 + 4, list.x2 - 8, list.y1 + 32,
            "FFFFFF", 6, nil, 0, 0, o.corner_radius_small))
        table.insert(chunks, D.ev_text(list.x2 - 14, list.y1 + 16, 6,
            string.format("\\fs%d\\c%s", fs - 6, U.ass_color(THEME.accent)),
            "Sort: " .. (recent and "Recent" or "Name")))
        table.insert(buttons, { x1 = list.x2 - 120, y1 = list.y1 + 4, x2 = list.x2 - 8, y2 = list.y1 + 32, action = "sort" })
    end
    table.insert(buttons, {
        x1 = list.x1, y1 = list.y1, x2 = list.x2 - 120, y2 = list.y1 + layout.panel_header_h,
        action = "focus_episodes",
    })

    -- ---- bodies ----
    local root_first_load = is_loading and current_path == root_href and #root_children == 0

    if root_first_load then
        table.insert(chunks, D.ev_text((sidebar.x1 + sidebar.x2) / 2, (sidebar.y1 + sidebar.y2) / 2, 5,
            string.format("\\fs%d\\c%s", fs + 2, U.ass_color(THEME.text_muted)),
            spinner_frames[spinner_idx] .. "  Loading..."))
    else
        draw_sidebar_rows(chunks, hitboxes, sidebar)
    end

    local files_loading = is_loading and #file_entries == 0 and current_path ~= CW_HREF and search_scope ~= "global"
    if root_first_load or files_loading then
        table.insert(chunks, D.ev_text((list.x1 + list.x2) / 2, (list.y1 + list.y2) / 2, 5,
            string.format("\\fs%d\\c%s", fs + 2, U.ass_color(THEME.text_muted)),
            spinner_frames[spinner_idx] .. "  Loading..."))
    elseif cur_err and #file_entries == 0 and search_scope ~= "global" then
        local cx_, cy_ = (list.x1 + list.x2) / 2, (list.y1 + list.y2) / 2
        table.insert(chunks, D.ev_text(cx_, cy_ - 10, 5,
            string.format("\\fs%d\\c%s", fs, U.ass_color(THEME.bad)), "⚠  " .. U.ass_escape(cur_err)))
        table.insert(chunks, D.ev_text(cx_, cy_ + 18, 5,
            string.format("\\fs%d\\c%s", fs - 6, U.ass_color(THEME.text_muted)), "Press R to retry"))
    else
        draw_episode_rows(chunks, hitboxes, list)
    end

    -- ---- footer ----
    table.insert(chunks, D.ev_rect(0, h - layout.footer_h, w, h, THEME.bg_header, o.footer_opacity, nil, 0, 0))
    table.insert(chunks, D.ev_rect(0, h - layout.footer_h, w, h - layout.footer_h + 2,
        U.pick(o.color_border_grad_top, "909090"), 35, nil, 0, 0))
    local hint
    if search_active then
        hint = "Type to search   ↑↓ Results   Enter Confirm   Esc Cancel"
    else
        hint = "↑↓ Move   Tab Panel   Enter Play/Open   ←/BS Up   / Filter   F Search all   A Queue   P Download+play   S Sort   R Refresh   M Watched   H Hide   D Debug   Esc Close"
    end
    table.insert(chunks, D.ev_text(14, h - layout.footer_h + 16, 4,
        string.format("\\fs%d\\c%s", fs - 6, U.ass_color(THEME.text_muted)),
        U.ass_escape(U.fit_text(hint, w - 28, fs - 6))))
    local st_col = status_line:match("^Failed") and THEME.bad or THEME.good
    table.insert(chunks, D.ev_text(14, h - layout.footer_h + 38, 4,
        string.format("\\fs%d\\c%s", fs - 4, U.ass_color(st_col)), U.ass_escape(U.fit_text(status_line, w * 0.55, fs - 4))))
    if search_scope == "global" or IDX.running then
        table.insert(chunks, D.ev_text(w - 14, h - layout.footer_h + 38, 6,
            string.format("\\fs%d\\c%s", fs - 6, U.ass_color(THEME.text_muted)),
            U.ass_escape(U.fit_text(IDX.summary(), w * 0.42, fs - 6))))
    end

    -- ---- debug panel ----
    if MS.debug then
        local lines = build_debug_lines()
        local dfs = math.max(11, fs - 8)
        local lh = math.floor(dfs * 1.55)
        local dw = math.min(math.floor(w * 0.5), 760)
        local dx2, dy1 = w - 16, layout.header_h + 12
        local dx1, dy2 = dx2 - dw, dy1 + #lines * lh + 16
        table.insert(chunks, D.ev_rect(dx1, dy1, dx2, dy2, THEME.bg_header, 88, THEME.accent, 60, 1, o.corner_radius_small))
        for i, line in ipairs(lines) do
            table.insert(chunks, D.ev_text(dx1 + 12, dy1 + 8 + (i - 0.5) * lh, 4,
                string.format("\\fs%d\\c%s%s", dfs, U.ass_color(i == 1 and THEME.accent or THEME.text_primary), i == 1 and "\\b1" or ""),
                U.ass_escape(U.fit_text(line, dw - 24, dfs))))
        end
    end

    -- ---- hover tooltip: full release name for rows whose title was cleaned ----
    local tip_name
    if o.experimental_clean_titles and o.clean_titles_tooltip and hover_index and not MS.drag then
        if hover_panel == "episodes" and search_scope ~= "global" then
            local it = ep_items[hover_index]
            if it and not it.is_dir and U.is_media(it.name) and CT.parse(it.name) then tip_name = it.name end
        elseif hover_panel == "sidebar" and o.clean_folder_titles then
            local nd = get_panel_items("sidebar")[hover_index]
            if nd and not nd.virtual and CT.parse_folder(nd.name) then tip_name = nd.name end
        end
    end
    if tip_name then
        do
            local mx, my = U.mouse_xy()
            if mx then
                local tfs = fs - 4
                local txt = U.fit_text(tip_name, w * 0.7, tfs)
                local tw = U.utf8_len(txt) * tfs * 0.58 + 24
                local tx1 = math.min(w - tw - 10, math.max(10, mx + 14))
                local ty1 = math.min(h - layout.footer_h - 34, my + 22)
                table.insert(chunks, D.ev_rect(tx1, ty1, tx1 + tw, ty1 + tfs * 1.9, THEME.bg_header, 94, THEME.accent, 55, 1, o.corner_radius_small))
                table.insert(chunks, D.ev_text(tx1 + 12, ty1 + tfs * 0.95, 4,
                    string.format("\\fs%d\\c%s", tfs, U.ass_color(THEME.text_primary)), U.ass_escape(txt)))
            end
        end
    end

    row_hitboxes, button_hitboxes = hitboxes, buttons
    local data = table.concat(chunks, "\n")
    local res_key = w .. "x" .. h
    if data ~= MS.last_overlay_data or res_key ~= MS.last_res then
        MS.last_overlay_data, MS.last_res = data, res_key
        overlay.data = data
        overlay:update()
    end
end

-- ============================================================
-- MOUSE
-- ============================================================
function U.mouse_xy()
    local m = mp.get_property_native("mouse-pos")
    if not m or m.hover == false then return nil end
    return m.x, m.y
end

function U.point_in(x, y, r)
    return x >= r.x1 and x <= r.x2 and y >= r.y1 and y <= r.y2
end

do   -- mouse handling lives in its own scope (keeps the main chunk under Lua 5.1's 200-local limit)
-- ---------- scrolling helpers ----------
local function scroll_value(panel)
    return (panel == "sidebar") and scroll_offset_folders or scroll_offset_episodes
end

-- Sets a panel's scroll offset directly (wheel / scrollbar). Marks the panel "free" so the view
-- stays where the user put it until the selection moves again.
local function set_scroll(panel, v)
    local info = layout and layout.scroll_info and layout.scroll_info[panel]
    local mx = info and info.max_scroll or 0
    v = math.max(0, math.min(mx, math.floor(v + 0.5)))
    if panel == "sidebar" then scroll_offset_folders = v else scroll_offset_episodes = v end
    free_scroll[panel] = true
end

-- scrollbar under the pointer (the grab area is wider than the drawn bar)
local function scrollbar_at(mx, my)
    if not layout or not layout.scrollbars then return nil end
    for panel, sb in pairs(layout.scrollbars) do
        if mx >= sb.hx1 and mx <= sb.hx2 and my >= sb.y1 and my <= sb.y2 then return panel, sb end
    end
    return nil
end

local function drag_to(y)
    local d = MS.drag
    if not d or not layout then return end
    local sb = layout.scrollbars[d.panel]
    if not sb then return end
    local travel = math.max(1, sb.track_h - sb.thumb_h)
    set_scroll(d.panel, ((y - d.grab - sb.y1) / travel) * sb.max_scroll)
end

-- ---------- clicks ----------
-- Folders panel: the arrow toggles expand/collapse only; the rest of the row opens the folder.
-- Files panel: a click selects, a DOUBLE-click plays (or reveals a folder result).
local function click_row(hb, is_double)
    if hb.arrow then
        local node = get_panel_items("sidebar")[hb.index]
        if node then
            sidebar_selected_index = hb.index
            free_scroll.sidebar = false
            toggle_expand(node)
        end
        return
    end
    if hb.panel == "sidebar" then
        sidebar_selected_index = hb.index
        free_scroll.sidebar = false
        if focus_panel ~= "sidebar" then set_focus("sidebar") end
        local node = get_panel_items("sidebar")[hb.index]
        if node then open_folder_node(node) end
        return
    end
    selected_episode = hb.index
    free_scroll.episodes = false
    if focus_panel ~= "episodes" then set_focus("episodes") end
    if is_double then open_selected(false) else render() end
end

local function mouse_down()
    if not browser_active then return end
    local mx, my = U.mouse_xy()
    if not mx then return end

    for _, b in ipairs(button_hitboxes) do
        if (b.action == "close" or b.action == "sort") and U.point_in(mx, my, b) then
            if b.action == "close" then close_browser() else toggle_sort(current_path) end
            return
        end
    end

    local panel, sb = scrollbar_at(mx, my)
    if panel then
        if my >= sb.ty1 and my <= sb.ty2 then
            MS.drag = { panel = panel, grab = my - sb.ty1 }          -- grab the thumb
        else
            set_scroll(panel, scroll_value(panel) + ((my < sb.ty1) and -sb.vis or sb.vis))   -- page toward the click
        end
        free_scroll[panel] = true
        render()
        return
    end

    for _, hb in ipairs(row_hitboxes) do      -- the expand arrow is listed before its row
        if U.point_in(mx, my, hb) then
            local now = U.now_s()
            local is_double = (not hb.arrow) and MS.last_panel == hb.panel and MS.last_index == hb.index
                and (now - MS.last_down_t) * 1000 <= o.double_click_ms
            MS.last_panel, MS.last_index = hb.panel, hb.index
            if is_double then MS.last_double_t, MS.last_down_t = now, 0 else MS.last_down_t = now end
            click_row(hb, is_double)
            return
        end
    end

    for _, b in ipairs(button_hitboxes) do
        if U.point_in(mx, my, b) then
            if b.action == "focus_sidebar" then set_focus("sidebar")
            elseif b.action == "focus_episodes" then set_focus("episodes") end
            return
        end
    end
end

local function mouse_up()
    if MS.drag then
        MS.drag = nil
        render()
    end
end

-- Some mpv builds report a double-click as MBTN_LEFT_DBL instead of a second MBTN_LEFT.
local function mouse_dbl()
    if not browser_active then return end
    if U.now_s() - MS.last_double_t < 0.3 then return end     -- already handled via our own timing
    local mx, my = U.mouse_xy()
    if not mx then return end
    for _, hb in ipairs(row_hitboxes) do
        if not hb.arrow and U.point_in(mx, my, hb) then
            MS.last_double_t, MS.last_down_t = U.now_s(), 0
            click_row(hb, true)
            return
        end
    end
end
on_dblclick = mouse_dbl

-- Bound as a "complex" binding, so it receives {event = "down" | "up" | ...}.
on_click = function(e)
    if type(e) == "table" then
        if e.event == "down" or e.event == "press" then mouse_down()
        elseif e.event == "up" then mouse_up() end
    else
        mouse_down()
    end
end

-- The wheel scrolls the VIEW of the panel under the pointer (the selection stays put).
on_wheel = function(dir)
    if not browser_active or not layout then return end
    local mx, my = U.mouse_xy()
    local panel
    if mx then
        if U.point_in(mx, my, layout.sidebar) then panel = "sidebar"
        elseif U.point_in(mx, my, layout.list) then panel = "episodes" end
    end
    panel = panel or ((focus_panel == "sidebar") and "sidebar" or "episodes")
    set_scroll(panel, scroll_value(panel) + dir * o.scroll_lines)
    render()
end

mp.observe_property("mouse-pos", "native", function(_, val)
    if not browser_active or not val then return end
    if MS.drag then
        drag_to(val.y)
        local now = U.now_s()
        if now - MS.last_move_render > 0.014 then MS.last_move_render = now; render() end
        return
    end
    local new_panel, new_index = nil, nil
    for _, hb in ipairs(row_hitboxes) do
        if U.point_in(val.x, val.y, hb) then
            new_panel, new_index = hb.panel, hb.index
            break
        end
    end
    local sbp = scrollbar_at(val.x, val.y)
    if new_panel ~= hover_panel or new_index ~= hover_index or sbp ~= MS.hover_sb then
        hover_panel, hover_index, MS.hover_sb = new_panel, new_index, sbp
        render()
    end
end)

end

mp.observe_property("osd-dimensions", "native", function()
    if browser_active then render() end
end)

-- ============================================================
-- KEY BINDINGS
-- ============================================================
-- ONE alias table feeds BOTH browse mode and search mode, so the two can never drift apart again
-- (the on-screen-keyboard bug: search mode had no LEFT/RIGHT/KP_* at all). The Windows on-screen
-- keyboard reports its arrow keys as KP_UP / KP_DOWN / KP_LEFT / KP_RIGHT (not the KP8/KP2/...
-- digit names), so every direction lists both.
local safe_bind, REP, ONCE   -- shared with the playback events further down
do   -- key bindings live in their own scope (Lua 5.1: max 200 locals per function)
local KEYS = {
    up    = { "UP", "KP_UP", "KP8" },
    down  = { "DOWN", "KP_DOWN", "KP2" },
    left  = { "LEFT", "KP_LEFT", "KP4" },
    right = { "RIGHT", "KP_RIGHT", "KP6" },
    enter = { "ENTER", "KP_ENTER", "KP5" },
    pgup  = { "PGUP" }, pgdn = { "PGDWN" }, home = { "HOME" }, end_ = { "END" },
    tab   = { "TAB" }, bs = { "BS" },
}

local function select_edge(first)
    local items = get_panel_items(focus_panel)
    free_scroll[focus_panel == "sidebar" and "sidebar" or "episodes"] = false
    if focus_panel == "sidebar" then sidebar_selected_index = first and 1 or math.max(1, #items)
    else selected_episode = first and 1 or math.max(1, #items) end
    render()
end

local function selected_file()
    if focus_panel ~= "episodes" then return nil end
    return get_panel_items("episodes")[selected_episode]
end

local function toggle_hide_watched()
    hide_watched = not hide_watched
    status_line = hide_watched and "Hiding watched files" or "Showing watched files"
    after_files_set()
    render()
end

local function clear_search_state()
    search_query, search_scope = "", nil
    search_results, MS.global_total = {}, 0
    selected_episode, scroll_offset_episodes = 1, 0
    sidebar_selected_index, scroll_offset_folders = 1, 0
    status_line = "Ready"
    render()
end

local function esc_pressed()
    if search_query ~= "" or search_scope ~= nil then clear_search_state() else close_browser() end
end

REP, ONCE = { repeatable = true }, { repeatable = false }
local CLICK = { complex = true }

local function build_browse_bindings()
    local L = {}
    local function add(key, fn, flags) L[#L + 1] = { key, fn, flags or ONCE } end
    local function many(keys, fn, flags) for _, k in ipairs(keys) do add(k, fn, flags) end end

    many(KEYS.up,    function() move_selection(-1) end, REP);  add("k", function() move_selection(-1) end, REP)
    many(KEYS.down,  function() move_selection(1) end, REP);   add("j", function() move_selection(1) end, REP)
    many(KEYS.pgup,  function() move_selection(-10) end, REP)
    many(KEYS.pgdn,  function() move_selection(10) end, REP)
    many(KEYS.home,  function() select_edge(true) end)
    many(KEYS.end_,  function() select_edge(false) end)
    many(KEYS.enter, function() open_selected(false) end)
    many(KEYS.right, function() open_selected(true) end);      add("l", function() open_selected(true) end)
    many(KEYS.left,  function() collapse_or_parent() end);     add("h", function() collapse_or_parent() end)
    many(KEYS.bs,    function() collapse_or_parent() end)
    many(KEYS.tab,   function() switch_panel() end)
    add("a", function() queue_add_current() end)
    add("s", function() toggle_sort() end)
    add("r", function() refresh_current() end)
    add("R", function() refresh_all() end)
    add("/", function() start_search() end)
    add("f", function() start_search("global") end)
    add("m", function() toggle_watched(selected_file()) end)
    add("p", function() MS.fb_manual(selected_file()) end)
    add("H", function() toggle_hide_watched() end)
    add("d", function() MS.debug = not MS.debug; render() end)
    add("ESC", esc_pressed)
    add("MBTN_LEFT", function(e) on_click(e) end, CLICK)
    add("MBTN_LEFT_DBL", function() on_dblclick() end)
    add("WHEEL_UP",   function() on_wheel(-1) end, REP)
    add("WHEEL_DOWN", function() on_wheel(1) end, REP)
    return L
end

local browse_bound = {}      -- names currently registered, so unbind removes exactly what was bound

safe_bind = function(name, key, fn, flags)
    local ok, err = pcall(mp.add_forced_key_binding, key, name, fn, flags)
    if not ok then msg.warn("webdav-browser: could not bind '" .. key .. "': " .. tostring(err)) end
end

bind_all = function()
    for _, kb in ipairs(build_browse_bindings()) do
        local name = "webdav_" .. kb[1]
        safe_bind(name, kb[1], kb[2], kb[3])
        browse_bound[#browse_bound + 1] = name
    end
end
unbind_all = function()
    for _, name in ipairs(browse_bound) do mp.remove_key_binding(name) end
    browse_bound = {}
end

-- ---------- search mode ----------
local SEARCH_CHARS_LOWER = "abcdefghijklmnopqrstuvwxyz0123456789-_.'()[]!&+,"
local SEARCH_CHARS_UPPER = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
local search_bound = {}

bind_search = function()
    local function add(name, key, fn, flags)
        safe_bind(name, key, fn, flags)
        search_bound[#search_bound + 1] = name
    end
    local function many(prefix, keys, fn, flags)
        for _, k in ipairs(keys) do add(prefix .. k, k, fn, flags) end
    end
    -- typing: named keys first (work on every mpv version)...
    for i = 1, #SEARCH_CHARS_LOWER do
        local ch = SEARCH_CHARS_LOWER:sub(i, i)
        add("search_c_" .. ch, ch, function() search_append(ch) end, REP)
    end
    for i = 1, #SEARCH_CHARS_UPPER do
        local ch = SEARCH_CHARS_UPPER:sub(i, i)
        add("search_C_" .. ch, ch, function() search_append(ch) end, REP)
    end
    add("search_space", "SPACE", function() search_append(" ") end, REP)
    -- ...and any_unicode as the fallback for EVERYTHING else (: ; @ # accents, kana, ...). A named
    -- binding always wins over any_unicode for the same key, so nothing is typed twice.
    add("search_any", "any_unicode", function(e)
        if type(e) ~= "table" then return end
        if e.event ~= "down" and e.event ~= "repeat" and e.event ~= "press" then return end
        local txt = e.key_text
        if txt and txt ~= "" and #txt <= 8 then search_append(txt) end
    end, { repeatable = true, complex = true })

    many("search_", KEYS.bs,    function() search_backspace() end, REP)
    many("search_", KEYS.enter, function() confirm_search() end)
    add("search_cancel", "ESC", function() cancel_search() end)
    many("search_", KEYS.up,    function() move_selection(-1) end, REP)
    many("search_", KEYS.down,  function() move_selection(1) end, REP)
    many("search_", KEYS.pgup,  function() move_selection(-10) end, REP)
    many("search_", KEYS.pgdn,  function() move_selection(10) end, REP)
    many("search_", KEYS.home,  function() select_edge(true) end)
    many("search_", KEYS.end_,  function() select_edge(false) end)
    -- swallowed so they don't seek the video while you type
    many("search_", KEYS.left,  function() end)
    many("search_", KEYS.right, function() end)
    many("search_", KEYS.tab,   function() end)
    add("search_click", "MBTN_LEFT", function(e) on_click(e) end, CLICK)
    add("search_dbl", "MBTN_LEFT_DBL", function() on_dblclick() end)
    add("search_wu", "WHEEL_UP",   function() on_wheel(-1) end, REP)
    add("search_wd", "WHEEL_DOWN", function() on_wheel(1) end, REP)
end

unbind_search = function()
    for _, name in ipairs(search_bound) do mp.remove_key_binding(name) end
    search_bound = {}
end

end

-- ============================================================
-- LIVE CONFIG RELOAD
-- ============================================================
-- Re-reads webdav-browser.conf (+ script-opts) into a fresh copy of the defaults and applies only
-- what changed. Triggered by the on_update callback, by a 2-second poll while the browser is open
-- (editing the .conf file does not fire on_update by itself), and by
-- `script-message webdav-browser-reload-config`.
local function apply_config_changes(changed)
    local old_host = host_label
    normalize_options()
    THEME = build_theme()
    ICONS = build_icons()
    auth_configured = false
    if changed.url or changed.user or changed.pass or changed.start_path then
        dir_cache, tree, root_children, file_entries = {}, {}, {}, {}
        MS.flat, MS.cache_version = nil, MS.cache_version + 1
        listing_error = {}
        index_stop()
        if browser_active then
            root_href = (o.start_path ~= "" and o.start_path or "/")
            load_root()
        end
    end
    if changed.background_blur_enabled or changed.background_blur_mode or changed.background_blur_strength
        or changed.background_blur_max_height or changed.background_blur_force then
        remove_background_blur()
        if browser_active then apply_background_blur() end
    end
    sidebar_frac = want_sidebar_frac()
    if browser_active then render() end
end

local function reload_config()
    local fresh = {}
    for k, v in pairs(DEFAULTS) do fresh[k] = v end
    options.read_options(fresh, "webdav-browser")
    U.conf_notes = U.lenient_conf(fresh)
    normalize_into(fresh)     -- same cleanup as at startup, otherwise "https://host/" would look changed forever
    local changed, any = {}, false
    for k, v in pairs(fresh) do
        if o[k] ~= v then changed[k] = true; any = true end
    end
    if not any then return end
    for k in pairs(changed) do o[k] = fresh[k] end
    apply_config_changes(changed)
    mp.osd_message("webdav-browser: config reloaded", 2)
    status_line = "Config reloaded"
    if browser_active then render() end
end
hot_reload_hook = function() reload_config() end
mp.register_script_message("webdav-browser-reload-config", reload_config)
mp.register_script_message("webdav-browser-reindex", function() index_start(true) end)

-- ============================================================
-- OPEN / CLOSE
-- ============================================================
close_browser = function()
    browser_active = false
    MS.drag = nil
    stop_anim()
    if MS.conf_timer then MS.conf_timer:kill(); MS.conf_timer = nil end
    if search_active then
        unbind_search()
        search_active = false
    end
    unbind_all()
    remove_background_blur()
    -- Flush any pending debounced write immediately instead of leaving it to fire later.
    if persist_debounce_timer then
        persist_debounce_timer:kill()
        persist_debounce_timer = nil
        save_persistence()
    end
    overlay:remove()
    MS.last_overlay_data = nil
end

-- Two webdav-browser scripts can be installed side by side (different open keys). Whichever browser was
-- opened last "owns" playback; the other one closes itself, and the data file is re-read so watch history
-- written by the other script is not overwritten with stale data.
MS.active = true
local function reload_user_data()
    local path = persist_status.path or history_file_path()
    if not path then return end
    local data = try_load_json(path)
    if not data then return end
    watch_history = U.plain(data.history)
    watched_set   = U.plain(data.watched)
    sort_by_dir   = U.plain(data.sort)
    index_meta    = U.plain(data.index)
    if mark_continue_dirty then mark_continue_dirty() end
    if browser_active then render() end
end
-- Hand-over: the instance that loses ownership writes once, then tells the new owner to re-read the file.
mp.register_script_message("webdav-browser-claim", function(who)
    if who == mp.get_script_name() then return end
    if MS.active then
        pcall(save_persistence, true)
        MS.active = false
        if browser_active then close_browser() end
        pcall(mp.commandv, "script-message-to", who, "webdav-browser-reload")
    end
end)
mp.register_script_message("webdav-browser-reload", function() if MS.active then reload_user_data() end end)

open_browser = function()
    if browser_active then close_browser(); return end
    MS.active = true
    reload_user_data()
    mp.commandv("script-message", "webdav-browser-claim", mp.get_script_name())
    if o.url == "" then
        mp.osd_message("webdav-browser: set url= in webdav-browser.conf", 4)
        return
    end

    browser_active = true
    root_href = (o.start_path ~= "" and o.start_path or "/")
    tree = {}
    root_children = {}
    file_entries = {}
    listing_error = {}
    current_path = root_href
    focus_panel = "sidebar"
    sidebar_frac = want_sidebar_frac()
    sidebar_selected_index, selected_episode = 1, 1
    scroll_offset_folders, scroll_offset_episodes = 0, 0
    free_scroll.sidebar, free_scroll.episodes = false, false
    close_pending_for = nil
    search_active = false
    search_query = ""
    search_scope = nil
    search_results = {}

    apply_background_blur()
    bind_all()
    load_root()
    render()
    IDX.maybe_autostart()
    if o.config_poll_secs and o.config_poll_secs > 0 then
        MS.conf_timer = mp.add_periodic_timer(o.config_poll_secs, reload_config)
    end
end

-- Key(s) that open/close the browser: open_key=ctrl+p   or several, separated by spaces/commas: open_key=ctrl+w ctrl+p
do
    local n = 0
    for key in (o.open_key or "ctrl+w"):gmatch("[^%s,]+") do
        n = n + 1
        mp.add_forced_key_binding(key, n == 1 and "webdav_toggle" or ("webdav_toggle_" .. n), open_browser, { repeatable = false })
    end
    if n == 0 then mp.add_forced_key_binding("ctrl+w", "webdav_toggle", open_browser, { repeatable = false }) end
end

-- ============================================================
-- PLAYBACK EVENTS
-- ============================================================
-- time-pos / duration are tracked continuously: by the time "end-file" fires mpv has often already
-- torn the values down, so reading them there returns nil.
mp.observe_property("time-pos", "number", function(_, v) if v then last_known_pos = v end end)
mp.observe_property("duration", "number", function(_, v) if v then last_known_dur = v end end)

-- Records progress for a file. Returns true if something was stored.
--   * past watched_threshold_pct / within watched_tail_secs of the end -> watched
--   * otherwise only counts as "in progress" after watch_min_secs AND watch_min_pct, so merely
--     opening a file for a few seconds doesn't leave an in-progress marker behind
local function record_progress(meta, pos, dur)
    if not (meta and pos and dur and dur > 0) then return false end
    local pct = pos / dur * 100
    if pos >= dur - o.watched_tail_secs or pct >= o.watched_threshold_pct then
        watched_set[meta.href] = os.time()
        watch_history[meta.href] = nil
    elseif pos >= o.watch_min_secs and pct >= o.watch_min_pct then
        watch_history[meta.href] = {
            pos = pos, duration = dur, name = meta.name, dirpath = meta.dirpath, last_played = os.time(),
        }
    else
        return false
    end
    mark_continue_dirty()
    return true
end

local function clear_start_over()
    mp.remove_key_binding("webdav_startover")
    if MS.resume_timer then MS.resume_timer:kill(); MS.resume_timer = nil end
end

-- mpv forgets the "path" of an entry that fails to open, so remember what it started loading.
mp.register_event("start-file", function()
    MS.starting_path = mp.get_property("path")
end)

mp.register_event("file-loaded", function()
    local path = mp.get_property("path")
    -- A blur filter must never outlive the browser: if one is still in the chain while the browser is
    -- closed (e.g. the previous file ended with the browser open), the new video would look soft/low-res.
    if not browser_active and blur_in_chain() then remove_background_blur() end
    if close_pending_for and path == close_pending_for then
        close_pending_for = nil
        if browser_active then close_browser() end
    end
    clear_start_over()
    if MS.fb.active and path ~= MS.fb.local_url then MS.fb_stop(true) end
    local meta = path and pending_meta[path]
    now_playing = meta
    last_known_pos, last_known_dur = nil, nil
    if meta then
        retry_counts[meta.href] = nil              -- it opened fine: reset the retry budget
        loading_meta = nil
        local rec = watch_history[meta.href]
        if rec and rec.pos and rec.pos > o.resume_min_secs then
            pcall(mp.set_property_number, "time-pos", rec.pos)
            if o.resume_notice then
                local key = tostring(o.start_over_key or "b")
                mp.osd_message(string.format("Resumed at %s   -   press %s to start over",
                    U.fmt_time(rec.pos), key:upper()), o.resume_notice_secs)
                safe_bind("webdav_startover", key, function()
                    clear_start_over()
                    pcall(mp.set_property_number, "time-pos", 0)
                    watch_history[meta.href] = nil
                    mark_continue_dirty()
                    mp.osd_message("Starting from the beginning", 2)
                end, ONCE)
                MS.resume_timer = mp.add_timeout(o.resume_notice_secs, clear_start_over)
            end
        end
    end
end)

mp.register_event("end-file", function(event)
    clear_start_over()
    local meta = now_playing

    local fb = MS.fb
    local was_local = fb.active and fb.local_url and mp.get_property("path") == fb.local_url
    if was_local then
        -- The growing local file ran dry (download slower than playback) or ended: reopen it where we were.
        if not fb.done and (fb.restarts or 0) < 30 and event.reason ~= "quit" and event.reason ~= "stop" then
            mp.add_timeout(2, function() if MS.fb == fb and fb.active and not fb.done then MS.fb_play() end end)
        end
    elseif event.reason == "error" then
        -- Works for files that failed to OPEN too (file-loaded never fired, so now_playing is nil):
        -- fall back to the entry mpv was loading.
        local failed = meta
        if not failed then
            local pth = mp.get_property("path") or MS.starting_path
            failed = (pth and pending_meta[pth]) or loading_meta
        end
        if failed then
            local attempts = (retry_counts[failed.href] or 0) + 1
            retry_counts[failed.href] = attempts
            if o.fallback_download and attempts >= (tonumber(o.fallback_after_failures) or 1) and MS.fb_start(failed, "stream failed") then
                retry_counts[failed.href] = nil
                mp.osd_message("Streaming failed - downloading the file instead...", 4)
            elseif attempts <= o.max_retries then
                local retry_url = file_stream_url(failed.href)
                pending_meta[retry_url] = failed
                loading_meta = failed
                mp.osd_message(string.format("Retrying %s (%d/%d)", failed.name, attempts, o.max_retries), 3)
                mp.add_timeout(o.retry_delay, function() queue_load(retry_url, "insert-next-play") end)
            else
                retry_counts[failed.href] = nil
                mp.osd_message("Failed: " .. failed.name .. (event.file_error and (" (" .. tostring(event.file_error) .. ")") or ""), 5)
            end
        end
    end

    if meta and not MS.active then reload_user_data() end     -- never overwrite the owner's newer data with ours
    if meta and record_progress(meta, last_known_pos, last_known_dur) then
        save_persistence(true)
        if not MS.active then pcall(mp.commandv, "script-message", "webdav-browser-reload") end
    end

    now_playing = nil
    last_known_pos, last_known_dur = nil, nil
    if browser_active then render() end
end)

-- Periodic watch-progress snapshot (memory every 15 s, disk at most once a minute)
mp.add_periodic_timer(15, function()
    if now_playing and record_progress(now_playing, last_known_pos, last_known_dur) then
        debounced_save_persistence(60)
    end
end)

-- One-ahead prefetch chain: buffers the NEXT episode once playback crosses prefetch_threshold_pct,
-- then repeats for the episode after that. The next file is inserted directly after the current one.
mp.add_periodic_timer(o.prefetch_check_interval_secs or 5, function()
    if not now_playing or not now_playing.next_item or now_playing.next_queued then return end

    local pos = mp.get_property_number("time-pos")
    local dur = mp.get_property_number("duration")
    if not (pos and dur and dur > 0) then return end

    local threshold = math.max(0, math.min(100, tonumber(o.prefetch_threshold_pct) or 75)) / 100
    if (pos / dur) < threshold then
        local fully_buffered = false
        if o.prefetch_on_buffered then
            local ok, st = pcall(mp.get_property_native, "demuxer-cache-state")
            fully_buffered = ok and type(st) == "table" and st["eof-cached"] == true
        end
        if not fully_buffered then return end
    end

    now_playing.next_queued = true
    local next_item = now_playing.next_item
    local next_url = file_stream_url(next_item.href)

    local chained_next = find_next_media_href(next_item.href)
    pending_meta[next_url] = {
        href = next_item.href, name = next_item.name, dirpath = U.dirname(next_item.href),
        next_queued = false,
        next_item = (o.autoplay_next and chained_next) and { href = chained_next.href, name = chained_next.name } or nil,
    }

    queue_next(next_url)
    status_line = string.format("Buffering next: %s", next_item.name)
    if browser_active then render() end
end)

mp.add_periodic_timer(0.12, function()
    if browser_active and (is_loading or IDX.running) then
        spinner_idx = (spinner_idx % #spinner_frames) + 1
        render()
    end
end)

mp.register_event("shutdown", function()
    index_stop()
    if MS.active then
        if now_playing then record_progress(now_playing, last_known_pos, last_known_dur) end
        save_persistence()
    end
    if MS.fb.active then MS.fb_stop(true) end
    for pth in pairs(MS.fb_dirty_files) do pcall(os.remove, pth) end
end)
MS.fb_purge()
mp.register_event("shutdown", remove_background_blur)

MS.debug = o.debug_overlay
MS.blur_state = "off"
load_persistence()
mp.commandv("script-message", "webdav-browser-claim", mp.get_script_name())   -- the script loaded last owns the data until the other one's key is used
msg.info("webdav-browser " .. SCRIPT_VERSION .. " loaded (Ctrl+W)")
mp.osd_message("webdav-browser " .. SCRIPT_VERSION .. " loaded", 2)
