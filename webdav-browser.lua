--[[
webdav-browser v13.1  -  two-panel (Folders | Files) WebDAV browser for mpv, for a Real-Debrid (or any) WebDAV library

Ctrl+W opens / closes it. Settings: script-opts/webdav-browser.conf (shared with webdav-browser-posters.lua, the
poster edition; both can be installed side by side - the one opened
last owns playback and the data file). Every feature and option is described in README.md and in
the comments of the conf.
]]--

local mp      = require("mp")
local utils   = require("mp.utils")
local msg     = require("mp.msg")
local options = require("mp.options")

-- Namespaces (Lua 5.1 allows only 200 local variables per function, so pure helpers live in tables)
local U = {}   -- utilities: text / url / time / matching helpers
local D = {}   -- ASS drawing primitives

local SCRIPT_VERSION = "v13.1"

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
    merge_seasons = true, queue_folder = true, queue_max = 200,   -- poster edition only (listed so the shared conf does not warn)
    cache_clear_key = "ctrl+x",        -- Press twice to clear the folder-listing cache (watch history is never touched)
    rd_api_token = "", rd_api_base = "https://api.real-debrid.com/rest/1.0", experimental_merge_by_tmdb = false,
    poster_overrides = "", show_missing_episodes = true,   -- poster edition only
    ui_scale = 1.0, continue_landscape = true, experimental_animations = false,   -- poster edition only
    open_key_posters = "ctrl+p", experimental_posters = true, tmdb_key = "", poster_column_pct = 17,
    poster_converter = "auto", poster_cache_dir = "", ffmpeg_path = "ffmpeg", magick_path = "magick",
    tmdb_api_base = "", tmdb_image_base = "",
    -- New in 13 (poster edition only, listed so the shared conf does not warn)
    anime_lookup = true, anime_map_url = "", anilist_api = "", card_radius = 6, card_shadows = true, selected_grow = 1.06,
    idle_prefetch_rows = 3, couch_mode = "auto", couch_open_keys = "GAMEPAD_BACK",
    experimental_backdrop = false,
    remember_tracks = true,            -- Remember the audio + subtitle language per show (pick once, every episode starts that way)
    next_episode_card = true,          -- "Next episode in 10..." card near the end credits (Esc = stay, Enter = play now)
    next_episode_secs = 10,            -- Length of that countdown
    next_episode_timing = "auto",      -- auto | credits | before (before = ends where the ED begins, for chapter-skip scripts)
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

-- Folder listings live in their own file (dirs.json, shared with the poster edition), so saving them never
-- rewrites the watch history, and the history file stays small.
function MS.cache_dir()
    if MS._cdir then return MS._cdir end
    local d = tostring(o.poster_cache_dir or "")
    if d == "" then
        local base = data_dir()
        d = base and utils.join_path(base, "webdav_posters")
            or ((os.getenv("TEMP") or os.getenv("TMP") or os.getenv("TMPDIR") or "/tmp"):gsub("\\", "/") .. "/webdav_posters")
    end
    MS._cdir = (d:gsub("\\", "/"):gsub("/+$", ""))
    return MS._cdir
end
function MS.mkdir()
    if MS._made then return end
    local d = MS.cache_dir()
    local is_win = package.config:sub(1, 1) == "\\"
    local args = is_win and { "cmd", "/c", "mkdir", (d:gsub("/", "\\")) } or { "mkdir", "-p", d }
    pcall(mp.command_native, { name = "subprocess", args = args, capture_stdout = true, capture_stderr = true, playback_only = false })
    MS._made = true
end
local function dircache_path() return MS.cache_dir() .. "/dirs.json" end

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
        MS.hints      = U.plain(data.hints)
        MS.tracks     = U.plain(data.tracks)
        MS.rev        = tonumber(data.rev) or 0
    end
    if o.persist_dir_cache then
        local cp = dircache_path()
        local c = cp and try_load_json(cp)
        if type(c) == "table" and type(c.dir_cache) == "table" then dir_cache = U.plain(c.dir_cache)
        elseif data and type(data.dir_cache) == "table" then dir_cache = U.plain(data.dir_cache) end   -- older versions kept it in the history file
        MS.cache_version = MS.cache_version + 1
    end
    persist_status.ok = true
end

-- History file: small, written often, only ever by the instance that owns playback (MS.active).
save_persistence = function(force)
    if MS.active == false and not force then return end
    local path = persist_status.path or history_file_path()
    if not path then return end
    MS.rev = (MS.rev or 0) + 1
    local json = safe_json({ v = 3, rev = MS.rev, history = watch_history, watched = watched_set, sort = sort_by_dir,
        index = index_meta, hints = MS.hints, tracks = MS.tracks })
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

local function save_dircache()
    if not o.persist_dir_cache or MS.active == false then return end
    local cp = dircache_path()
    if not cp then return end
    local json = safe_json({ v = 1, dir_cache = dir_cache })
    if not json then return end
    local ok = atomic_write(cp, json)
    if not ok then
        -- the cache folder may not exist yet
        MS.mkdir()
        ok = atomic_write(cp, json)
    end
    if ok then MS.cache_dirty = false; persist_status.cache_bytes = #json end
end

-- Directory-cache writes are batched: the first dirty change schedules ONE flush; further changes
-- inside that window ride along. Watch-history saves (end-file) stay immediate.
local persist_debounce_timer = nil
-- what = "cache" (a folder listing changed) only rewrites dirs.json; anything else also saves the history file.
local function debounced_save_persistence(delay, what)
    if what ~= "cache" then MS.hist_dirty = true end
    MS.cache_dirty = MS.cache_dirty or (what == "cache")
    if persist_debounce_timer then return end
    persist_debounce_timer = mp.add_timeout(delay or 3, function()
        persist_debounce_timer = nil
        if MS.hist_dirty then MS.hist_dirty = false; save_persistence() end
        if MS.cache_dirty then save_dircache() end
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
    -- Real-Debrid fills a big torrent folder gradually (it prepares the links one by one): a listing that grew since
    -- the last look is "still filling" - it is re-checked every few seconds while you look at it and never counts
    -- as fresh in the cache until two checks in a row return the same number of entries.
    local oldn = old and type(old.entries) == "table" and #old.entries or nil
    MS.seen[href] = (MS.seen[href] or 0) + 1
    local g = MS.grow[href]
    if oldn and #entries > oldn then
        MS.grow[href] = { n = #entries, stable = 0, t = os.time() }
        dir_cache[href].stale = true
    elseif g then
        g.stable = g.stable + 1
        if g.stable >= 2 then MS.grow[href] = nil else dir_cache[href].stale = true end
    end
    if href == current_path then
        if MS.grow[href] then status_line = string.format("Real-Debrid is still adding files to this folder…  %d so far", #entries)
        elseif g and status_line:find("still adding files", 1, true) then status_line = string.format("All %d entries listed", #entries) end
    end
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
        if not opts.silent and opts.status and not MS.grow[href] then status_line = "Loaded: " .. (U.basename(href) ~= "" and U.basename(href) or "root") end
        render()
        -- during a library crawl write less often (every ~30 s): the data file holds the whole index
        debounced_save_persistence(opts.silent and (MS.idx_running and 30 or 8) or 3, "cache")
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

-- Playlist entries get the FILE NAME as their title (instead of the long stream link) by loading
-- them through an in-memory m3u ("#EXTINF:-1,<name>"). mpv shows that title in the playlist and
-- as the media title. Falls back to a plain loadfile when loadlist refuses (very old mpv).
local function m3u_title(t)
    t = tostring(t or ""):gsub("[\r\n]+", " ")
    return t
end
local function queue_many(items, mode)
    ensure_http_options()
    if #items == 0 then return end
    local lines = { "#EXTM3U" }
    for _, it in ipairs(items) do
        if it.title and it.title ~= "" then lines[#lines + 1] = "#EXTINF:-1," .. m3u_title(it.title) end
        lines[#lines + 1] = it.url
    end
    local list = "memory://" .. table.concat(lines, "\n")
    local insert = mode:find("^insert%-next") ~= nil
    -- mpv < 0.38 has no insert-next for loadlist: append instead (keeps the titles); asked once, then remembered
    if not (insert and MS.no_insert_next) then
        if mp.commandv("loadlist", list, mode) then return end
        if insert then MS.no_insert_next = true end
    end
    if insert and mp.commandv("loadlist", list, mode == "insert-next-play" and "append-play" or "append") then return end
    -- fallback: plain loadfile (no titles)
    local first = true
    for _, it in ipairs(items) do
        local m = mode
        if not first then m = "append" end
        if not mp.commandv("loadfile", it.url, m) and m:find("^insert%-next") then
            mp.commandv("loadfile", it.url, m == "insert-next-play" and "append-play" or "append")
        end
        first = false
    end
end
local function queue_load(url, mode, title)
    queue_many({ { url = url, title = title } }, mode)
end

-- Queue `url` directly AFTER the current file (so it plays next even if you queued other things
-- with 'a'); older mpv without "insert-next" falls back to appending.
local function queue_next(url, title)
    queue_many({ { url = url, title = title } }, "insert-next")
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
        queue_load(stream_url, "append-play", entry.name)
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

    queue_load(stream_url, "replace", entry.name)
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
    ensure_http_options(); mp.commandv("loadfile", fb.local_url, "replace")   -- local growing file: plain loadfile
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
MS.grow, MS.seen = {}, {}         -- folders whose listing is still growing / how often each was listed this session

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
    MS.scur = 0
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

-- Text cursor in the search box: MS.scur = bytes before it. Left / Right / Home / End / Ctrl+arrows / Del edit in place.
function MS.s_cont(s, i) local b = s:byte(i); return b and b >= 128 and b < 192 end
function MS.scur_get() MS.scur = math.max(0, math.min(#search_query, MS.scur or #search_query)); return MS.scur end
function MS.scur_prev(q, c) c = c - 1; while c > 0 and MS.s_cont(q, c + 1) do c = c - 1 end; return math.max(0, c) end
function MS.scur_next(q, c) c = c + 1; while c < #q and MS.s_cont(q, c + 1) do c = c + 1 end; return math.min(#q, c) end
function MS.search_changed()
    if search_scope == "global" then run_global_search() end
    search_reset_selection()
    render()
end

search_append = function(ch)
    local c = MS.scur_get()
    search_query = search_query:sub(1, c) .. ch .. search_query:sub(c + 1)
    MS.scur = c + #ch
    MS.search_changed()
end

search_backspace = function()
    local c = MS.scur_get()
    if c == 0 then return end
    local p = MS.scur_prev(search_query, c)
    search_query, MS.scur = search_query:sub(1, p) .. search_query:sub(c + 1), p
    MS.search_changed()
end

function MS.search_delete()
    local c = MS.scur_get()
    if c >= #search_query then return end
    search_query = search_query:sub(1, c) .. search_query:sub(MS.scur_next(search_query, c) + 1)
    MS.search_changed()
end

-- dir = -1 / 1 one character, -2 / 2 one word, "home" / "end"
function MS.scur_move(dir)
    local q, c = search_query, MS.scur_get()
    if dir == "home" then c = 0
    elseif dir == "end" then c = #q
    elseif dir == -1 then c = MS.scur_prev(q, c)
    elseif dir == 1 then c = MS.scur_next(q, c)
    elseif dir == -2 then
        while c > 0 and q:sub(c, c) == " " do c = c - 1 end
        while c > 0 and q:sub(c, c) ~= " " do c = c - 1 end
    elseif dir == 2 then
        while c < #q and q:sub(c + 1, c + 1) == " " do c = c + 1 end
        while c < #q and q:sub(c + 1, c + 1) ~= " " do c = c + 1 end
    end
    MS.scur = c
    render()
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
        local c = MS.scur_get and MS.scur_get() or #search_query
        local text = string.format("{\\b0}%s{\\b1} %s▏%s", ICONS.search, U.ass_escape(search_query:sub(1, c)), U.ass_escape(search_query:sub(c + 1)))
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
    table.insert(chunks, D.ev_rect(bx1, y1, x2, y2, THEME.track, 100, nil, 0, 0, o.corner_radius_small))
    table.insert(chunks, D.ev_rect(bx1, thumb_y, x2, thumb_y + thumb_h, THEME.accent, hot and 100 or 80, nil, 0, 0, o.corner_radius_small))
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

-- Characters some upload tools substitute for ones Windows forbids in file names ("Time?!" saved as U+F025),
-- plus the double-encoded form of the same ("ï€¥"). Turned back into the real character for display.
CT.SFM = { [0xF020] = '"', [0xF021] = "*", [0xF022] = ":", [0xF023] = "<", [0xF024] = ">", [0xF025] = "?",
    [0xF026] = "\\", [0xF027] = "|", [0xF028] = " ", [0xF029] = "." }
function CT.fix_chars(s)
    if not s or not s:find("[\195\239\234]") then return s end
    local function map(cp)
        local m = CT.SFM[cp]
        if m then return m end
        if cp >= 0xF030 and cp <= 0xF07F then return string.char(cp - 0xF000) end
        return nil
    end
    s = s:gsub("\239([\128\129])([\128-\191])", function(b2, b3)
        local cp = 0xF000 + (b2:byte() - 0x80) * 64 + (b3:byte() - 0x80)
        return map(cp) or ("\239" .. b2 .. b3)
    end)
    -- the same bytes read as Windows-1252 and saved again as UTF-8: "ï" "€" + (C2 xx)
    s = s:gsub("\195\175\226\130\172\194([\160-\191])", function(b3)
        return map(0xF000 + (b3:byte() - 0x80)) or ("\195\175\226\130\172\194" .. b3)
    end)
    s = s:gsub("\234\158\137", ":")                            -- U+A789 colon look-alike
    return s
end

-- words that end an episode title taken from a file name ("S02E01.You.Arent.E.Rank.Are.You.1080p.WEB")
CT.EP_STOP = {}
for w in ([[1080p 2160p 720p 480p 1080i 4k uhd web webdl web-dl webrip bluray blu-ray bdrip brrip bd hdtv dvdrip remux
    x264 x265 h264 h265 hevc avc av1 hdr hdr10 dv dovi atmos dts ddp dd aac flac opus multi dual dubbed subbed
    proper repack internal real vostfr nf amzn dsnp atvp hmax max hulu pcok cr crunchyroll hidive ita eng fre ger spa
    jpn kor 10bit 8bit hi10p complete]]):gmatch("%S+") do CT.EP_STOP[w] = true end

-- Episode title from the part of a file name that follows the episode token.
function CT.ep_title(rest)
    if not rest or rest == "" then return nil end
    rest = rest:gsub("^[%s%._%-:]+", "")
    if rest:find("^[eE]%d") or rest:find("^%-") then return nil end    -- "S01E01-E13" ranges
    if rest:find("^[%[%(]") then return nil end
    local words = {}
    for w in rest:gsub("[%._]", " "):gmatch("%S+") do
        local lw = w:lower():gsub("[%[%]%(%)]", "")
        if CT.EP_STOP[lw] or lw:find("^%d%d%d%d?p$") or w:find("^[%[%(]") then break end
        if lw:find("^%d%d%d%d$") and tonumber(lw) >= 1900 and tonumber(lw) <= 2099 then break end
        words[#words + 1] = w
        if #words >= 16 then break end
    end
    local t = table.concat(words, " "):gsub("%s*%-%s*$", "")
    t = t:gsub("^%-%s*", ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if not t:find("%a%a") then return nil end
    return t
end

function CT.parse_raw(name)
    local base = CT.fix_chars(name)
    local ext = U.ext_of(base)
    if ext and (U.video_exts[ext:lower()] or U.audio_exts[ext:lower()]) then
        base = base:sub(1, #base - #ext - 1)
    end
    local lower = base:lower()

    -- season/episode token: must start a "word" (so "class01e02" doesn't match)
    local cut, se_label, ep_from = nil, nil, nil
    local init = 1
    while true do
        local a, b, s, e = lower:find("s(%d%d?)[%._%s]?e(%d%d%d?%d?)", init)
        if not a then break end
        if a == 1 or not lower:sub(a - 1, a - 1):match("%w") then
            se_label = string.format("S%02dE%02d", tonumber(s), tonumber(e))
            cut, ep_from = a - 1, b + 1
            break
        end
        init = a + 1
    end
    if not se_label then   -- "1x05"
        local a, b, s, e = lower:find("%f[%w](%d%d?)x(%d%d%d?)%f[%W]")
        if a and tonumber(s) < 60 then
            se_label = string.format("S%02dE%02d", tonumber(s), tonumber(e)); cut, ep_from = a - 1, b + 1
        end
    end
    if not se_label then   -- "Episode 001 Title", "Ep 10 - Title", "Episode.10"
        local a, b, e = lower:find("%f[%w]episode[%s%._%-]*(%d%d?%d?%d?)%f[%D]")
        if not a then a, b, e = lower:find("%f[%w]ep[%s%._%-]*(%d%d?%d?%d?)%f[%D]") end
        if a then se_label = string.format("E%02d", tonumber(e)); cut, ep_from = a - 1, b + 1 end
    end
    if not se_label then   -- anime style: "Show Name - 03 [1080p]" / "Show Name - 03 - Title"
        local a, b, e = lower:find("%s%-%s(%d%d%d?%d?)[%s%[%(%.]")
        if not a then a, b, e = lower:find("%s%-%s(%d%d%d?%d?)$") end
        if a then
            local v = tonumber(e)
            if not (v >= 1900 and v <= 2099 and #e == 4) and v ~= 1080 and v ~= 720 and v ~= 2160 then
                se_label = string.format("E%02d", v); cut, ep_from = a - 1, b
            end
        end
    end

    local year
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
    local ep = ep_from and CT.ep_title(base:sub(ep_from)) or nil

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
        title = title, se = se_label, year = year, chips = chips, ep = ep,
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
    local base = CT.fix_chars(name)
    local group
    local body = base
    for _ = 1, 4 do                                          -- leading tags: "[SubsPlease] Show", "[v2] Show"
        local lead = body:match("^%[([^%]]+)%]")
        if not lead then break end
        local ll = lead:lower()
        if not group and #lead >= 2 and #lead <= 24 and not ll:find("^v%d+$") and not ll:find("^%d+p$")
           and not ll:find("^%d+$") then group = lead end
        body = body:gsub("^%b[]%s*", "")
    end
    local alt                                                 -- "(Demon Slayer) Kimetsu no Yaiba ..."
    local pin, prest = body:match("^%((.-)%)%s*(.+)$")
    if pin and pin:find("%a%a") and not pin:find("^%d+$") then alt, body = pin, prest end
    body = body:gsub("^[Bb][Oo][Nn][Dd][%s%._]*50[%s%._%-]+", "")   -- "Bond 50 The Spy Who Loved Me"
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
        title = CT.titlecase(title), season = season, year = year, group = group, alt = alt,
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
    -- Column widths shared by every visible row, so labels, chips, sizes and episode names line up
    -- (they used to follow each name's estimated text width and drift from row to row).
    local COL = { label = 0, chips = 0, size = 0 }
    for i = scroll_off + 1, last_idx do
        local it = items[i]
        local cp = (clean and it and not it.is_dir and U.is_media(it.name)) and CT.parse(it.name) or nil
        if cp and cp.se then
            COL.label = math.max(COL.label, U.utf8_len(cp.se) * fs * 0.62)
            local cw = 0
            if o.clean_titles_chips then
                for _, c in ipairs(cp.chips) do cw = cw + U.utf8_len(c) * cfs * 0.62 + 12 + 5 end
            end
            if it.cw == "next" then cw = cw + 4 * cfs * 0.62 + 17 end
            COL.chips = math.max(COL.chips, cw)
            if it.size and it.size > 0 then COL.size = math.max(COL.size, U.utf8_len(U.fmt_bytes(it.size)) * (fs - 6) * 0.58 + 12) end
            COL.any = true
        end
    end
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
        local shown_name, name_suffix = CT.fix_chars(item.name), ""
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

        local columns = cp and cp.se and COL.any
        if columns then
            -- E01 | chips | size | episode name (title first when the folder mixes shows)
            local tail = {}
            if not uniform and cp.title ~= "" then tail[#tail + 1] = cp.title end
            if cp.ep then tail[#tail + 1] = cp.ep end
            local tail_txt = table.concat(tail, "  ·  ")
            local x_label = name_x + 30
            local x_chips = x_label + COL.label + 14
            local x_size = x_chips + COL.chips
            local x_ep = x_size + COL.size + (COL.size > 0 and 10 or 0)
            local x_end = rect.x2 - right_w - 8
            local status_txt = ""
            if o.show_watched_status and not use_right_status then
                if watched_set[item.href] then status_txt = ICONS.watched
                elseif hist then status_txt = ICONS.watching end
            end
            table.insert(chunks, D.ev_text(name_x, name_y, 4, string.format("%s\\fs%d\\c%s", clip, fs, U.ass_color(icon_col)), icon))
            table.insert(chunks, D.ev_text(x_label, name_y, 4, string.format("%s\\fs%d\\c%s", clip, fs, U.ass_color(name_col)),
                U.ass_escape(shown_name)))
            local cx = x_chips
            if x_size <= x_end then
                for k = 1, #chip_labels do cx = draw_chip(cx, name_y, chip_labels[k], CT.chip_color(chip_labels[k])) end
            end
            if item.size and item.size > 0 and x_ep <= x_end + 10 then
                table.insert(chunks, D.ev_text(x_size, name_y, 4,
                    string.format("%s\\fs%d\\c%s", clip, fs - 6, U.ass_color(THEME.text_dim)), U.ass_escape(U.fmt_bytes(item.size))))
            end
            if x_end - x_ep > 30 and (tail_txt ~= "" or status_txt ~= "") then
                local rowclip = D.clip_tag(x_ep, body_y1, math.min(body_x2, x_end), body_y2)
                local fit = U.fit_text(tail_txt, x_end - x_ep - (status_txt ~= "" and 26 or 0), fs - 4)
                local st = (status_txt ~= "") and string.format("{\\c%s}  %s", U.ass_color(watched_set[item.href] and THEME.good or THEME.warn), status_txt) or ""
                table.insert(chunks, D.ev_text(x_ep, name_y, 4, string.format("%s\\fs%d\\c%s", rowclip, fs - 4,
                    U.ass_color(is_sel and THEME.accent or THEME.text_muted)), U.ass_escape(fit) .. st))
            end
            if right_text then
                table.insert(chunks, D.ev_text(rect.x2 - 16 - scroll_pad, name_y, 6,
                    string.format("%s\\fs%d\\c%s", clip, fs - 6, U.ass_color(right_col)), U.ass_escape(right_text)))
            end
        end

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

        if not columns then
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
        local ck = (tostring(o.cache_clear_key or ""):match("[^%s,]+") or ""):upper()
        hint = "↑↓ Move   Tab Panel   Enter Play/Open   ←/BS Up   / Filter   F Search all   A Queue   P Download+play   S Sort   R Refresh   M Watched   H Hide   "
            .. (ck ~= "" and (ck .. " Clear cache   ") or "") .. "D Debug   Esc Close"
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
    else
        local dirs = MS.cache_stats()
        local ctext = string.format("Cache %d folders%s", dirs,
            (persist_status.cache_bytes and persist_status.cache_bytes > 0) and ("  ·  " .. ((persist_status.cache_bytes < 1048576)
                and string.format("%d KB", math.ceil(persist_status.cache_bytes / 1024)) or U.fmt_bytes(persist_status.cache_bytes))) or "")
        table.insert(chunks, D.ev_text(w - 14, h - layout.footer_h + 38, 6,
            string.format("\\fs%d\\c%s", fs - 6, U.ass_color(MS.clear_armed and THEME.warn or THEME.text_muted)), U.ass_escape(ctext)))
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
    local function hover_is_live()
        local mx, my = U.mouse_xy()
        if not mx then return false end
        for _, hb in ipairs(hitboxes) do
            if hb.panel == hover_panel and hb.index == hover_index and mx >= hb.x1 and mx <= hb.x2 and my >= hb.y1 and my <= hb.y2 then
                return true
            end
        end
        return false
    end
    if o.experimental_clean_titles and o.clean_titles_tooltip and hover_index and not MS.drag and hover_is_live() then
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

-- Listing cache (folder listings kept in the data file so the library opens instantly). The cache
-- clear key (default ctrl+x) must be pressed twice; watch history, watched marks and sort choices stay.
function MS.cache_stats()
    local dirs, items = 0, 0
    for _, c in pairs(dir_cache) do
        if type(c) == "table" and type(c.entries) == "table" then dirs = dirs + 1; items = items + #c.entries end
    end
    return dirs, items
end
function MS.clear_cache_key()
    local now = U.now_s()
    local key = (tostring(o.cache_clear_key or ""):match("[^%s,]+") or "key"):upper()
    if MS.clear_armed and now - MS.clear_armed < 6 then
        MS.clear_armed = nil
        local dirs = MS.cache_stats()
        dir_cache = {}
        MS.cache_version = (MS.cache_version or 0) + 1
        MS.cache_dirty = true
        save_dircache()
        status_line = string.format("Cache cleared (%d folder listings). Watch history was not touched.", dirs)
        refresh_current()
    else
        MS.clear_armed = now
        local dirs, items = MS.cache_stats()
        status_line = string.format("Press %s again to clear the listing cache (%d folders, %d items)", key, dirs, items)
        mp.add_timeout(6, function() if MS.clear_armed == now then MS.clear_armed = nil; if browser_active then render() end end end)
    end
    render()
end

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
    add("MBTN_BACK", function() collapse_or_parent() end)
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
    for k in tostring(o.cache_clear_key or ""):gmatch("[^%s,]+") do add(k, function() MS.clear_cache_key() end) end
    add("ESC", esc_pressed)
    -- gamepads (mpv: input-gamepad=yes) and TV remotes
    many({ "GAMEPAD_DPAD_UP", "GAMEPAD_LEFT_STICK_UP" },       function() move_selection(-1) end, REP)
    many({ "GAMEPAD_DPAD_DOWN", "GAMEPAD_LEFT_STICK_DOWN" },   function() move_selection(1) end, REP)
    many({ "GAMEPAD_DPAD_RIGHT", "GAMEPAD_LEFT_STICK_RIGHT" }, function() open_selected(true) end)
    many({ "GAMEPAD_DPAD_LEFT", "GAMEPAD_LEFT_STICK_LEFT" },   function() collapse_or_parent() end)
    many({ "GAMEPAD_LEFT_SHOULDER", "CHANNEL_UP" },    function() move_selection(-10) end, REP)
    many({ "GAMEPAD_RIGHT_SHOULDER", "CHANNEL_DOWN" }, function() move_selection(10) end, REP)
    many({ "GAMEPAD_ACTION_DOWN", "PLAY", "PLAYPAUSE", "PLAYONLY" }, function() open_selected(false) end)
    many({ "GAMEPAD_ACTION_RIGHT", "BACK", "CANCEL" }, esc_pressed)
    add("GAMEPAD_ACTION_LEFT", function() toggle_watched(selected_file()) end)
    add("GAMEPAD_ACTION_UP", function() queue_add_current() end)
    many({ "GAMEPAD_START", "MENU" }, function() switch_panel() end)
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
    -- the text cursor
    many("search_", KEYS.home,  function() MS.scur_move("home") end)
    many("search_", KEYS.end_,  function() MS.scur_move("end") end)
    many("search_", KEYS.left,  function() MS.scur_move(-1) end, REP)
    many("search_", KEYS.right, function() MS.scur_move(1) end, REP)
    add("search_cl", "ctrl+LEFT",  function() MS.scur_move(-2) end, REP)
    add("search_cr", "ctrl+RIGHT", function() MS.scur_move(2) end, REP)
    add("search_del", "DEL", function() MS.search_delete() end, REP)
    add("search_kpdel", "KP_DEL", function() MS.search_delete() end, REP)
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
    MS.hints      = U.plain(data.hints)
    MS.tracks     = U.plain(data.tracks)
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
    if meta and meta.finished and dur then pos = dur end        -- left through the "Next episode" card: watched
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

-- ============================================================
-- PER-SHOW AUDIO / SUBTITLE LANGUAGE
-- ============================================================
-- Pick Japanese audio + English subtitles once in any Bleach episode and every Bleach episode starts that way.
-- Stored in the history file as tracks[show] = { a = audio language, s = subtitle language or "no" }.
-- The show is the nearest folder above the file that has a real title (season / disc folders are skipped).
MS.tracks = MS.tracks or {}
function MS.show_key(href)
    if not href then return nil end
    local d = U.dirname(href)
    local rootn = tostring(root_href or "/"):gsub("/+$", "")
    for _ = 1, 4 do
        local dn = d:gsub("/+$", "")
        if dn == "" or dn == rootn then return nil end
        local name = U.basename(d)
        local fp = CT.parse_folder(name)
        local t = tostring((fp and fp.title) or name)
        local low = t:lower():gsub("^%s+", ""):gsub("%s+$", "")
        local generic = low == "" or low:match("^season") or low:match("^s%d+$") or low:match("^disc") or low:match("^dis[ck]%s*%d")
            or low:match("^specials?$") or low:match("^extras?$") or low:match("^%d+$") or low:match("^part%s*%d+$")
        if not generic then return (low:gsub("[^%w]+", "")) end
        d = U.dirname(d)
    end
    return nil
end

local function trk_lang(t)
    if type(t) ~= "table" then return nil end
    if t.lang and t.lang ~= "" then return tostring(t.lang):lower() end
    if t.title and t.title ~= "" then return "title:" .. tostring(t.title):lower() end
    return nil
end

-- Called from file-loaded: switch to the remembered languages (when this file has them).
function MS.tracks_apply(meta)
    MS.trk_loaded = mp.get_time()
    MS.trk_key = nil
    if not o.remember_tracks or not meta then return end
    local key = MS.show_key(meta.href)
    MS.trk_key = key
    local rec = key and MS.tracks[key]
    if type(rec) ~= "table" then return end
    local list = mp.get_property_native("track-list") or {}
    local function find(kind, want)
        local best
        for _, t in ipairs(list) do
            if t.type == kind and trk_lang(t) == want then
                local signs = tostring(t.title or ""):lower():find("sign") ~= nil
                if not best or (best.forced and not t.forced) or (best.signs and not signs) then
                    best = { id = t.id, forced = t.forced, signs = signs }
                end
            end
        end
        return best and best.id
    end
    local done = {}
    if rec.a then
        local id = find("audio", rec.a)
        if id and id ~= mp.get_property_number("aid") then mp.set_property_number("aid", id) end
        if id then done[#done + 1] = "audio " .. rec.a end
    end
    if rec.s == "no" then
        mp.set_property("sid", "no"); done[#done + 1] = "no subtitles"
    elseif rec.s then
        local id = find("sub", rec.s)
        if id and id ~= mp.get_property_number("sid") then mp.set_property_number("sid", id) end
        if id then done[#done + 1] = "subtitles " .. rec.s end
    end
    MS.trk_loaded = mp.get_time()
    if #done > 0 then msg.info("remembered tracks for " .. key .. ": " .. table.concat(done, ", ")) end
end

-- A track change by YOU (not mpv's own pick at load, not ours) is remembered for the show.
local function trk_changed(kind)
    if not o.remember_tracks or not now_playing or not MS.trk_key then return end
    if mp.get_time() - (MS.trk_loaded or 0) < 1.5 then return end
    local rec = MS.tracks[MS.trk_key] or {}
    if kind == "audio" then
        local l = trk_lang(mp.get_property_native("current-tracks/audio"))
        if not l or rec.a == l then return end
        rec.a = l
    else
        local sid = mp.get_property("sid")
        local l = (sid == "no" or sid == nil) and "no" or trk_lang(mp.get_property_native("current-tracks/sub"))
        if not l or rec.s == l then return end
        rec.s = l
    end
    rec.t = os.time()
    MS.tracks[MS.trk_key] = rec
    debounced_save_persistence(2)
end
mp.observe_property("aid", "string", function() trk_changed("audio") end)
mp.observe_property("sid", "string", function() trk_changed("sub") end)

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
    pcall(MS.tracks_apply, meta)
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
                mp.add_timeout(o.retry_delay, function() queue_load(retry_url, "insert-next-play", failed.name) end)
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

    queue_next(next_url, next_item.name)
    status_line = string.format("Buffering next: %s", next_item.name)
    if browser_active then render() end
end)

mp.add_periodic_timer(0.12, function()
    if browser_active and (is_loading or IDX.running) then
        spinner_idx = (spinner_idx % #spinner_frames) + 1
        render()
    end
end)

-- Every 4 s while the browser is open: re-list the folders you are looking at that are still filling up, and give
-- each one a second look 5 s after its first listing this session (that is how a growing folder is noticed).
MS.inview = MS.inview or function() return { current_path } end
mp.add_periodic_timer(4, function()
    if not browser_active then return end
    local ok, list = pcall(MS.inview)
    if not ok or type(list) ~= "table" then return end
    local now = os.time()
    for _, href in ipairs(list) do
        local c = href and find_cached_dir(href)
        if c and type(c.entries) == "table" and not MS.inflight[href] then
            local again = MS.grow[href] ~= nil
            if not again and (MS.seen[href] or 0) == 1 and now - (c.ts or now) >= 5 then again = true end
            if again then fetch_listing(href, { silent = true }) end
        end
    end
    render()
end)

-- ============================================================
-- "NEXT EPISODE IN 10..." CARD
-- ============================================================
-- A card with the next episode's still (poster edition) and name, counting down while the next playlist entry is one
-- of ours. The countdown follows the playback position, so pausing pauses it. Esc keeps watching, Enter plays now.
-- When it is shown depends on the file's chapters and on whether a chapter-skip script is installed:
--   * credits: the card appears when the trailing ED / Ending / Credits / Preview chapters start; at 0 the next episode
--              starts (the rest of the credits is skipped and the episode counts as watched).
--   * before:  a skip script (op-ed-pv-skip and the like) jumps over those chapters - straight to the next file when they
--              are the last ones - so the countdown runs in the last seconds BEFORE them and ends where they begin.
--   * no named chapters: the last next_episode_secs of the file.
MS.ep_meta = MS.ep_meta or {}
local NX = { id = 60, shown = nil, dismissed = nil, ov = nil, bound = false }

-- Chapter names a skip script skips (the op-ed-pv-skip lists, plus "credits / ending / outro / preview" anywhere).
NX.EXACT = {}
for _, t in ipairs({ "op", "opening", "opening theme", " - op", "recap", "title", "#prologue", "intermission", "eye-catchers",
    "ed", "ending", " - ed", "ending credits", "credits", "ending theme", "pv", "preview", "next episode preview",
    "next ep. preview", "nextp ep. preview", "next", "next time", "endcard", " - ed card", "ed+cast", "cast" }) do NX.EXACT[t] = true end
NX.START = { "opening theme", "recap", "title", "eye-catchers", "intermission", "#prologue", "op by ", "ed song - ", "ending theme",
    "next episode preview" }
NX.END = { " (opening theme)", " (#prologue)", " (title)", " (eye-catchers)", " (intermission)", " (recap)", " (ending theme)",
    " (opening)", " - opening", " - op", " (ending)", "- ending", " - ed", " preview", " (next episode preview)" }
function NX.tail_name(title)
    local t = tostring(title or ""):lower()
    if NX.EXACT[t] then return true end
    for _, p in ipairs(NX.START) do if t:sub(1, #p) == p then return true end end
    for _, p in ipairs(NX.END) do if #t >= #p and t:sub(-#p) == p then return true end end
    return t:find("credits", 1, true) or t:find("ending", 1, true) or t:find("outro", 1, true) or t:find("preview", 1, true)
        or t:match("^ed[%s%d:%-]") ~= nil
end

-- Is a chapter-skip script loaded? (its key bindings show up in mpv's input-bindings list)
function NX.skipper()
    if NX.sk_t and mp.get_time() - NX.sk_t < 60 then return NX.sk end
    local ok, list = pcall(mp.get_property_native, "input-bindings")
    local found = false
    for _, b in ipairs(ok and type(list) == "table" and list or {}) do
        local c = (tostring(b.cmd or "") .. " " .. tostring(b.section or "")):lower()
        if c:find("op_ed_pv_skip", 1, true) or c:find("op-ed-pv-skip", 1, true) or c:find("chapterskip", 1, true)
            or c:find("chapter_skip", 1, true) or c:find("skip_intro", 1, true) or c:find("skipintro", 1, true)
            or c:find("autoskip", 1, true) then found = true; break end
    end
    NX.sk, NX.sk_t = found, mp.get_time()
    return found
end

-- Start of the trailing ED / credits / preview chapters (nil when the file has none in its second half).
function NX.tail_start(dur, skipper)
    local list = mp.get_property_native("chapter-list") or {}
    local n = #list
    if n < 2 then return nil end
    local named = false
    for _, ch in ipairs(list) do
        local t = tostring(ch.title or "")
        if t ~= "" and not t:match("^Chapter ") then named = true; break end
    end
    local start
    if named then
        for i = n, 1, -1 do
            if NX.tail_name(list[i].title) and (list[i].time or 0) > dur * 0.5 then start = list[i].time else break end
        end
    elseif skipper then
        -- unnamed chapters: the skip script goes by length (PV 14-26 s as the last chapter, OP/ED 88-102 s)
        for i = n, math.max(1, n - 2), -1 do
            local len = ((list[i + 1] and list[i + 1].time) or dur) - (list[i].time or 0)
            local pv = (i == n and len >= 14 and len <= 26)
            if (pv or (len >= 88 and len <= 102)) and (list[i].time or 0) > dur * 0.5 then start = list[i].time else break end
        end
    end
    return start
end

function NX.next_entry()
    local pos = mp.get_property_number("playlist-pos")
    local pl = mp.get_property_native("playlist")
    if not (pos and type(pl) == "table") then return nil end
    local nx = pl[pos + 2]           -- playlist-pos is 0-based, Lua tables 1-based
    return nx and pending_meta[nx.filename]
end

function NX.hide()
    if NX.shown then
        if NX.ov then NX.ov.data = ""; NX.ov:update() end
        pcall(mp.commandv, "overlay-remove", tostring(NX.id))
        NX.shown, NX.bmp = nil, nil
    end
    if NX.bound then
        for _, k in ipairs(NX.keys) do pcall(mp.remove_key_binding, "webdav_nx_" .. k) end
        NX.bound = false
    end
end

function NX.next()
    NX.hide()
    if now_playing then now_playing.finished = true end
    mp.command("playlist-next")
end

NX.keys = { "ESC", "ENTER", "KP_ENTER", "GAMEPAD_ACTION_DOWN", "GAMEPAD_ACTION_RIGHT" }
function NX.bind(href)
    if NX.bound then return end
    NX.bound = true
    local function stay() NX.dismissed = href; NX.hide() end
    for _, k in ipairs(NX.keys) do
        local fn = (k == "ESC" or k == "GAMEPAD_ACTION_RIGHT") and stay or NX.next
        mp.add_forced_key_binding(k, "webdav_nx_" .. k, fn)
    end
end

-- Label ("S02E28"), episode name and show for the card: the title page's TMDB data when known, else the file name.
function NX.info(meta)
    local em = MS.ep_meta[meta.href] or {}
    local cp = CT.parse(meta.name or "")
    local name = em.name or (cp and cp.ep) or (cp and cp.title) or meta.name or ""
    return em.label or (cp and cp.se), name
end

function NX.draw(meta, left, sw, sh, f)
    local ww, wh = mp.get_osd_size()
    if not ww or ww <= 0 then return end
    NX.ov = NX.ov or mp.create_osd_overlay("ass-events")
    local S = wh / 1080
    local fs = math.max(14, math.floor(21 * S))
    local pad = math.floor(14 * S)
    local has_still = sw > 0
    local tw = has_still and math.floor(sw * 1.15) or math.floor(wh * 0.30)     -- text column (beside the still)
    local pw = (has_still and (sw + pad) or 0) + tw + 2 * pad
    local ph = math.max(has_still and sh or 0, math.floor(fs * 6.4)) + 2 * pad
    local x1 = ww - pw - math.floor(40 * S)
    local y1 = wh - ph - math.floor(100 * S)
    local sy = y1 + math.floor((ph - sh) / 2)                -- the still, centred vertically
    local label, name = NX.info(meta)
    local ev = {}
    ev[#ev + 1] = D.ev_rect(x1, y1, x1 + pw, y1 + ph, THEME.bg_header, 92, THEME.accent, 55, 1, math.floor(12 * S))
    if has_still and not f then ev[#ev + 1] = D.ev_rect(x1 + pad, sy, x1 + pad + sw, sy + sh, THEME.bg_panel, 100, nil, 0, 0, NX.radius or 0) end
    local tx, ty = x1 + pad + (has_still and (sw + pad) or 0), y1 + pad
    local function line(y, tags, txt) ev[#ev + 1] = D.ev_text(tx, y, 7, tags, txt) end
    line(ty, string.format("\\b1\\fs%d\\c%s", fs + 3, U.ass_color("FFFFFF")), "Next episode in " .. math.max(0, math.ceil(left)))
    local ny = ty + fs * 1.6
    if label then
        line(ny, string.format("\\b1\\fs%d\\c%s", fs, U.ass_color(THEME.accent)), U.ass_escape(label))
        ny = ny + fs * 1.3
    end
    line(ny, string.format("\\fs%d\\c%s", fs, U.ass_color(THEME.text_primary)), U.ass_escape(U.fit_text(name, tw, fs)))
    ev[#ev + 1] = D.ev_text(tx, y1 + ph - pad, 1, string.format("\\fs%d\\c%s", fs - 5, U.ass_color(THEME.text_muted)),
        U.ass_escape(U.fit_text("Enter play  ·  Esc stay", tw, fs - 5)))
    -- countdown bar along the bottom of the card
    local frac = math.max(0, math.min(1, left / math.max(1, tonumber(o.next_episode_secs) or 10)))
    local bh = math.max(3, math.floor(4 * S))
    ev[#ev + 1] = D.ev_rect(x1 + pad, y1 + ph - bh - 2, x1 + pad + (pw - 2 * pad) * frac, y1 + ph - 2, THEME.accent, 100, nil, 0, 0, 2)
    NX.ov.res_x, NX.ov.res_y = ww, wh
    NX.ov.data = table.concat(ev, "\n")
    NX.ov:update()
    if f then
        local bx, by = math.floor(x1 + pad), math.floor(sy)
        local sig = f .. "@" .. bx .. "," .. by
        if NX.bmp ~= sig then
            NX.bmp = mp.commandv("overlay-add", tostring(NX.id), tostring(bx), tostring(by), f, "0", "bgra",
                tostring(sw), tostring(sh), tostring(sw * 4)) and sig or nil
        end
    end
    NX.shown = true
end


-- list edition: no artwork, just the text
function NX.size() return 0, 0 end
function NX.still() return nil end

mp.add_periodic_timer(0.2, function()
    if not o.next_episode_card or not now_playing or browser_active then NX.hide(); return end
    local href = now_playing.href
    if NX.dismissed and NX.dismissed ~= href then NX.dismissed = nil end
    local pos, dur = mp.get_property_number("time-pos"), mp.get_property_number("duration")
    if not (pos and dur and dur > 60) or NX.dismissed == href then NX.hide(); return end
    local secs = math.max(3, tonumber(o.next_episode_secs) or 10)
    local timing = tostring(o.next_episode_timing or "auto"):lower()
    local skipper = NX.skipper()
    if timing ~= "credits" and timing ~= "before" then timing = skipper and "before" or "credits" end
    local tail = NX.tail_start(dur, skipper or timing == "before")
    local t0, t_go
    if tail and timing == "before" then t0, t_go = tail - secs, tail - 0.45   -- leave just before the skip script jumps
    elseif tail then t0, t_go = tail, tail + secs
    else t0 = dur - secs - 1 end
    if pos < t0 - 90 then NX.hide(); return end
    local meta = NX.next_entry()
    if not meta then NX.hide(); return end
    local sw, sh = NX.size()
    local f = NX.still(meta, sw, sh)                 -- starts early, so the still is ready when the card appears
    if pos < t0 or pos >= dur - 0.3 then NX.hide(); return end
    local left = (t_go or (t0 + secs)) - pos
    if left <= 0 then
        NX.hide()
        if t_go then NX.dismissed = href; NX.next() end
        return
    end
    NX.bind(href)
    NX.draw(meta, left, sw, sh, f)
end)

mp.register_event("shutdown", function()
    index_stop()
    if MS.active then
        if now_playing then record_progress(now_playing, last_known_pos, last_known_dur) end
        save_persistence()
        if MS.cache_dirty then save_dircache() end
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
