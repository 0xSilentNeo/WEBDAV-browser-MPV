--[[
webdav-browser-posters v13.1  -  Netflix-style poster browser for a WebDAV library (Real-Debrid and others) in mpv

Ctrl+P opens / closes it (gamepad: View button). Settings: script-opts/webdav-browser.conf (shared with
webdav-browser.lua, the plain list edition; both can be installed side by side - the one opened last owns
playback and the data file). Every feature and option is described in README.md and in the conf's comments.

TMDB artwork: this product uses the TMDB API but is not endorsed or certified by TMDB.
Anime matching: AniList (anilist.co) and Fribb's anime-lists id map (github.com/Fribb/anime-lists).
]]--

local mp      = require("mp")
local utils   = require("mp.utils")
local msg     = require("mp.msg")
local options = require("mp.options")

-- Namespaces (Lua 5.1 allows only 200 local variables per function, so pure helpers live in tables)
local U = {}   -- utilities: text / url / time / matching helpers
local D = {}   -- ASS drawing primitives

local SCRIPT_VERSION = "v13.1-posters"

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
    -- ===== Posters (EXPERIMENTAL, poster edition) =====
    experimental_posters = true,    -- Show the TMDB poster of the open folder in a column on the right (needs tmdb_key)
    tmdb_key = "",                  -- TMDB v3 API key (32 chars) or v4 read-access token (starts with eyJ)
    poster_column_pct = 17,         -- Width of the poster column, percent of the window (the file list gets narrower)
    poster_converter = "auto",      -- auto | powershell | ffmpeg | magick  (auto = ffmpeg when it is installed, else PowerShell on Windows)
    poster_cache_dir = "",          -- Folder for downloaded posters; empty = <mpv config>/script-opts/webdav_posters
    ffmpeg_path = "ffmpeg",
    magick_path = "magick",
    tmdb_api_base = "https://api.themoviedb.org/3",
    tmdb_image_base = "https://image.tmdb.org/t/p/",

    open_key = "ctrl+w",               -- (used by the plain webdav-browser.lua only; listed so the shared conf does not warn)
    open_key_posters = "ctrl+p",       -- Key(s) that open/close THIS (poster) browser; the plain browser uses open_key (default ctrl+w)
    home_view = true,               -- Open on the Netflix-style poster home screen (no = classic list view)
    home_card_pct = 19,             -- Poster card width as percent of the window height (bigger = fewer, larger posters)
    home_recent_count = 20,         -- (unused since v11.1: the Recently Added row is gone; kept so older confs do not warn)
    merge_seasons = true,           -- Home screen: all seasons of one show become ONE card (the title page lists every season)
    queue_folder = true,            -- Playing a file also queues the files that follow it (like a playlist)
    queue_max = 200,                -- Never queue more than this many files at once
    ui_scale = 1.0,                 -- Size of the poster screens (1.0 = sized to the window; 1.2 = 20% bigger, 0.85 = smaller)
    continue_landscape = true,      -- Continue Watching shows the episode's still (16:9) instead of the poster
    experimental_animations = false,-- Gliding selection, fade-ins and smooth scrolling (off while a video plays)
    cache_clear_key = "ctrl+x",     -- Home screen: press twice to delete the poster / still / listing cache (history is never touched)
    -- New in 11
    show_missing_episodes = true,   -- Title page: warn about (and show greyed cards for) episodes WebDAV does not list
    rd_api_token = "",              -- OPTIONAL Real-Debrid API token (real-debrid.com/apitoken): says WHY an episode is missing
    rd_api_base = "https://api.real-debrid.com/rest/1.0",
    experimental_merge_by_tmdb = false,  -- Home screen: folders that match the same TMDB title become ONE card (all seasons inside)
    poster_overrides = "",          -- Pin titles to TMDB ids: "boku no hero=tv:65930; sennen kessen=tv:30984:17; my film=movie:603"
    -- New in 13
    anime_lookup = true,            -- Anime folders: find the exact TMDB title through AniList + the anime-lists id map (romaji names)
    anime_map_url = "https://raw.githubusercontent.com/Fribb/anime-lists/master/anime-list-mini.json",
    anilist_api = "https://graphql.anilist.co",
    card_radius = 6,                -- Rounded corners on posters and stills (px at 1080p, 0 = square)
    card_shadows = true,            -- Soft shadow under every card
    selected_grow = 1.06,           -- The selected card grows by this factor (1 = off)
    idle_prefetch_rows = 3,         -- While nothing else is loading, prepare the artwork this many rows ahead (and the next shelf page)
    couch_mode = "auto",            -- auto | yes | no : bigger focus ring for TV / gamepad use (auto = after a gamepad or remote key)
    couch_open_keys = "GAMEPAD_BACK", -- Gamepad / remote key(s) that open and close the poster browser (not used with couch_mode=no)
    remember_tracks = true,         -- Remember the audio + subtitle language per show (pick once, every episode starts that way)
    next_episode_card = true,       -- "Next episode in 10..." card near the end credits / ED chapter (Esc = stay, Enter = play now)
    next_episode_secs = 10,         -- Length of that countdown
    next_episode_timing = "auto",   -- auto | credits | before : before = the countdown ends where the ED / credits begin (for
                                    -- chapter-skip scripts like op-ed-pv-skip); auto = before when such a script is loaded
    experimental_backdrop = false,  -- Title page: large TMDB backdrop beside the text, faded into the background

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
local PS                           -- poster module (assigned in the POSTERS section)
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
             tooltip_x = 0, tooltip_y = 0, inflight = {}, hints = {}, rev = 0 }
local CW_HREF = "webdav-browser://continue-watching"
-- One line per screen change ("VIEW home", "VIEW title-page", "VIEW classic-list"): makes it easy to see that the poster UI
-- never drops back to the list UI by itself (mpv --log-file=... and search for "VIEW ").
local function log_view(name) msg.info("VIEW " .. name) end

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

-- Invalid UTF-8 (odd file names on a server) makes utils.format_json fail, which used to silently lose the
-- whole save. This replaces every byte that is not part of a valid UTF-8 sequence with "?".
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
    for k, x in pairs(v) do
        t[type(k) == "string" and U.clean_utf8(k) or k] = U.clean_tree(x, depth + 1)
    end
    return t
end

local function safe_json(payload)
    local ok, json = pcall(utils.format_json, payload)
    if ok and type(json) == "string" then return json end
    ok, json = pcall(utils.format_json, U.clean_tree(payload))
    if ok and type(json) == "string" then return json end
    return nil
end

-- The big, re-creatable cache (folder listings) lives in the cache folder next to the posters, NOT in the
-- history file: a problem with it can never cost you your watch history, and "clear cache" never touches history.
local function dircache_path()
    local ok, d = pcall(function() return PS.dir() end)
    if ok and d then return d .. "/dirs.json" end
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
        PS.mkdir()
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
function MS.fetch_dir_now(path, callback)
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

-- At most 3 folder listings are requested at once; the rest wait their turn (the title page of a show with
-- many season folders used to fire them all together, and the server refused part of the burst).
-- Listings you are looking at (urgent) go to the front of the line.
MS.dav_q, MS.dav_running = {}, 0
local function fetch_dir_async(path, callback, urgent)
    local function start()
        MS.dav_running = MS.dav_running + 1
        MS.fetch_dir_now(path, function(a, b, c)
            MS.dav_running = MS.dav_running - 1
            local nxt = table.remove(MS.dav_q, 1)
            if nxt then nxt() end
            callback(a, b, c)
        end)
    end
    if MS.dav_running < 3 then start()
    elseif urgent then table.insert(MS.dav_q, 1, start)
    else MS.dav_q[#MS.dav_q + 1] = start end
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
        if MS.on_listing then MS.on_listing(href, err) end
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
    end, opts.urgent or not opts.silent)
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
        local hint = MS.hints[d]
        if not (cached and type(cached.entries) == "table") and hint and hint.href
           and not watched_set[hint.href] and not watch_history[hint.href] then
            table.insert(nxt, { name = hint.name or U.basename(hint.href), href = hint.href, is_dir = false,
                size = hint.size, cw = "next", dirpath = d, ts = ts })
        elseif cached and type(cached.entries) == "table" then
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

-- Media files that come AFTER `href` in its own folder (natural filename order), from the cached listing.
local function folder_followers(href)
    local d = find_cached_dir(U.dirname(href))
    if not d or type(d.entries) ~= "table" then return {} end
    local media = {}
    for _, e in ipairs(d.entries) do
        if not e.is_dir and U.is_media(e.name) then media[#media + 1] = e end
    end
    table.sort(media, function(a, b) return U.natural_less(a.name, b.name) end)
    for i, e in ipairs(media) do
        if e.href == href then
            local out = {}
            for j = i + 1, #media do out[#out + 1] = media[j] end
            return out
        end
    end
    return {}
end

play_entry = function(entry, append, playlist)
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
    -- Queue the files that follow (a real mpv playlist: next/previous keys work, the playlist shows it).
    local followers = {}
    if o.queue_folder then followers = playlist or folder_followers(entry.href) end
    local qmax = math.max(0, tonumber(o.queue_max) or 200)
    while #followers > qmax do followers[#followers] = nil end
    local queued = #followers > 0

    local next_entry = (o.autoplay_next and not queued) and find_next_media_href(entry.href) or nil
    local meta = {
        href = entry.href, name = entry.name, dirpath = dirpath,
        next_queued = false,
        next_item = next_entry and { href = next_entry.href, name = next_entry.name } or nil,
    }
    pending_meta[stream_url] = meta
    loading_meta = meta

    local batch = { { url = stream_url, title = entry.name } }
    for _, f in ipairs(followers) do
        local u = file_stream_url(f.href)
        pending_meta[u] = { href = f.href, name = f.name, dirpath = U.dirname(f.href) }
        batch[#batch + 1] = { url = u, title = f.name }
    end
    queue_many(batch, "replace")
    if queued then pcall(mp.set_property, "prefetch-playlist", "yes") end
    status_line = "Playing: " .. entry.name .. (queued and string.format("  (+%d queued)", #followers) or "")
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
    save_dircache()
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
    if search_scope ~= scope then search_query = "" end
    MS.scur = #search_query
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
    local list_x2, poster = inner_x2, nil
    if o.experimental_posters and w >= 900 then
        local pwid = math.max(170, math.min(300, math.floor(w * (tonumber(o.poster_column_pct) or 17) / 100)))
        list_x2 = inner_x2 - pwid - gap
        poster = { x1 = list_x2 + gap, y1 = inner_y1, x2 = inner_x2, y2 = inner_y2 }
        usable = usable - pwid - gap
    end
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
        poster = poster,
        sidebar = { x1 = inner_x1, y1 = inner_y1, x2 = inner_x1 + sb_w, y2 = inner_y2 },
        list    = { x1 = inner_x1 + sb_w + gap, y1 = inner_y1, x2 = list_x2, y2 = inner_y2 },
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
        title = title, se = se_label, year = year, chips = chips, ep = ep, group = CT.file_group(base),
        label = se_label or (title .. (year and (" (" .. year .. ")") or "")),
    }
end

-- Release group of a FILE name: "...x265-VARYG" or "[SubsPlease] ..."
function CT.file_group(base)
    local g = base:match("%-([%w_]+)$")
    if g and #g >= 2 and #g <= 20 and not (CT.GROUP_BLOCK or {})[g:lower()] and not g:match("^%d+$") and not g:lower():match("^%d+p$")
       and not g:lower():match("^[ex]%d+$") and not g:lower():match("^s%d") then return g end
    local lead = base:match("^%[([^%]]+)%]")
    if lead and #lead >= 2 and #lead <= 24 and not lead:lower():match("^v%d+$") then return lead end
    return nil
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

PS.IDX_VERSION = 8     -- bump when the matching rules change: older lookups (and "not found" results) are dropped once
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

-- Romaji / alternative names TMDB does not find on its own -> what to search for instead (s = season the folder holds).
PS.ALIASES = {
    { "bokunoheroacademia", "My Hero Academia" }, { "bokunohero", "My Hero Academia" },
    { "shingekinokyojin", "Attack on Titan" }, { "kimetsunoyaiba", "Demon Slayer: Kimetsu no Yaiba" },
    { "sousounofrieren", "Frieren: Beyond Journey's End" }, { "kaguyasamawakokurasetai", "Kaguya-sama: Love Is War" },
    { "yakusokunoneverland", "The Promised Neverland" }, { "tenseishitaraslimedattaken", "That Time I Got Reincarnated as a Slime" },
    { "oredakelevelupnaken", "Solo Leveling" }, { "kusuriyanohitorigoto", "The Apothecary Diaries" },
    { "bokunokokoronoyabaiyatsu", "The Dangers in My Heart" }, { "shigatsuwakiminouso", "Your Lie in April" },
    { "kiminonawa", "Your Name." }, { "sentochihironokamikakushi", "Spirited Away" },
    { "dungeonmeshi", "Delicious in Dungeon" }, { "kaijuu8gou", "Kaiju No. 8" }, { "kaiju8gou", "Kaiju No. 8" },
    { "ookamitokoushinryou", "Spice and Wolf" }, { "honzukinogekokujou", "Ascendance of a Bookworm" },
    { "tatenoyuushanonariagari", "The Rising of the Shield Hero" }, { "konosubarashiisekainishukufukuwo", "KonoSuba: God's Blessing on This Wonderful World!" },
    { "rezerokarahajimeruisekaiseikatsu", "Re:ZERO -Starting Life in Another World-" }, { "haganenorenkinjutsushi", "Fullmetal Alchemist: Brotherhood" },
    { "mahoushoujomadokamagica", "Puella Magi Madoka Magica" }, { "seishunbutayarou", "Rascal Does Not Dream of Bunny Girl Senpai" },
    { "kanojookarishimasu", "Rent-a-Girlfriend" }, { "bocchitherock", "Bocchi the Rock!" },
    { "bleachsennenkessenhen", "Bleach", 17 }, { "bleachthousandyearbloodwar", "Bleach", 17 },
}
-- poster_overrides = "boku no hero=tv:65930; sennen kessen=tv:30984:17; some film=movie:603"
function PS.overrides()
    local src = tostring(o.poster_overrides or "")
    if PS.ov_src == src then return PS.ov end
    PS.ov_src, PS.ov = src, {}
    for part in src:gmatch("[^;|]+") do
        local text, kind, id, s = part:match("^%s*(.-)%s*=%s*(%a+)%s*:%s*(%d+)%s*:?%s*[Ss]?(%d*)%s*$")
        if text and text ~= "" and (kind == "tv" or kind == "movie") then
            PS.ov[#PS.ov + 1] = { n = PS.norm(text), kind = kind, id = id, s = tonumber(s) }
        end
    end
    return PS.ov
end
function PS.override_for(raw, title)
    local a, b = PS.norm(raw or ""), PS.norm(title or "")
    for _, ov in ipairs(PS.overrides()) do
        if ov.n ~= "" and (a:find(ov.n, 1, true) or b:find(ov.n, 1, true)) then return ov end
    end
    return nil
end
function PS.alias_for(raw, title)
    local cands = { PS.norm(title or "") }
    local fp = raw and CT.parse_folder(raw)
    if fp and fp.title then cands[#cands + 1] = PS.norm(fp.title) end
    for _, n in ipairs(cands) do
        for _, al in ipairs(PS.ALIASES) do
            if n:sub(1, #al[1]) == al[1] then return al end
        end
    end
    return nil
end
-- Looks like anime? (fansub tags, absolute numbers, dual audio...) - then TMDB's Animation results win ties.
function PS.animeish(raw)
    local l = tostring(raw or ""):lower()
    return l:find("^%[") or l:find("dual[%s%._%-]?audio") or l:find("%[dual%]") or l:find("raws") or l:find("subs")
        or l:find("%(%d%d%d?%d?%-%d%d%d?%d?%)") or l:find("%[%d%d%d?%-%d%d%d?%]") or l:find("opus") or l:find("hi10")
end
-- Share of words two names have in common (either direction), 0..1.
function PS.overlap(a, b)
    local function words(s)
        local t, n = {}, 0
        for w in tostring(s):lower():gsub("[^%w%s]", " "):gmatch("%S+") do if not t[w] then t[w] = true; n = n + 1 end end
        return t, n
    end
    local wa, na = words(a)
    local wb, nb = words(b)
    if na == 0 or nb == 0 then return 0 end
    local hit = 0
    for w in pairs(wa) do if wb[w] then hit = hit + 1 end end
    return math.max(hit / na, hit / nb)
end

-- ---------- anime lookup: AniList + the anime-lists id map (no keys needed) ----------
-- Romaji folder names ("Vanitas no Carte", "Sousou no Frieren") often find nothing - or the wrong thing - on TMDB.
-- 1. AniList (GraphQL, no key) is searched with the folder title; it knows romaji, English, native names and synonyms.
-- 2. The AniList id is mapped to the exact TMDB entry (and TMDB / TVDB season + episode offset) with Fribb's
--    anime-lists file, downloaded once and refreshed weekly (stored compact as anime_map.txt).
-- 3. Not in the map: TMDB is searched with AniList's English, then native title; the result must match the year
--    (+-1) and the type (film / series).
-- Only anime-looking folders and weak / failed TMDB matches get here; every answer is cached.
PS.AM = { map = nil, state = nil, waiters = {} }
PS.AL = { q = {}, busy = false, last = -10, cache = nil }
PS.AL_GQL = "query($s:String){Page(perPage:8){media(search:$s,type:ANIME,sort:SEARCH_MATCH){id format episodes seasonYear "
    .. "startDate{year} title{romaji english native} synonyms}}}"

function PS.am_path() return PS.dir() .. "/anime_map.txt" end

function PS.am_load()
    if PS.AM.map then return end
    local f = io.open(PS.am_path(), "rb")
    if not f then return end
    local map = {}
    for line in f:lines() do
        local aid, kind, id, s, tvs, off = line:match("^(%d+)|(%a+)|(%d+)|(%d*)|(%d*)|(%d*)")
        if aid then map[aid] = { kind = kind, id = id, s = tonumber(s), tvs = tonumber(tvs), off = tonumber(off) } end
    end
    f:close()
    PS.AM.map = map
end

-- The big JSON (~6 MB) is boiled down to "anilist|tv|tmdb|tmdb season|tvdb season|episode offset" lines.
function PS.am_compact(src)
    local f = io.open(src, "rb")
    if not f then return false end
    local txt = f:read("*a"); f:close()
    local ok, data = pcall(utils.parse_json, txt)
    txt = nil
    if not ok or type(data) ~= "table" then return false end
    local function n(x) x = tonumber(x); return x and string.format("%d", x) or "" end
    local out = {}
    for _, e in ipairs(data) do
        local tm = type(e.themoviedb_id) == "table" and e.themoviedb_id or nil
        if tonumber(e.anilist_id) and tm then
            local kind, id = "tv", tm.tv
            if id == nil then kind, id = "movie", tm.movie end
            if type(id) == "table" then id = id[1] end
            if tonumber(id) then
                local se = type(e.season) == "table" and e.season or {}
                local eo = type(e.episode_offset) == "table" and e.episode_offset or {}
                out[#out + 1] = table.concat({ n(e.anilist_id), kind, n(id), n(se.tmdb), n(se.tvdb), n(eo.tmdb) }, "|")
            end
        end
    end
    data = nil
    collectgarbage()
    if #out < 500 then return false end
    return atomic_write(PS.am_path(), table.concat(out, "\n") .. "\n") and true or false
end

function PS.am_fetch()
    local AM = PS.AM
    if AM.state == "fetching" or (AM.state == "failed" and os.time() - (AM.fail_t or 0) < 3600) then return end
    AM.state = "fetching"
    PS.mkdir()
    local tmp = PS.dir() .. "/anime_map.download"
    PS.run({ o.curl_path, "-s", "-S", "-L", "-m", "180", "--create-dirs", "-o", tmp, o.anime_map_url }, function(res)
        local ok = res and res.status == 0 and PS.am_compact(tmp)
        pcall(os.remove, tmp)
        if ok then AM.state, AM.map = "done", nil; PS.am_load()
        else AM.state, AM.fail_t = "failed", os.time(); msg.warn("anime-lists map could not be downloaded") end
        local ws = AM.waiters
        AM.waiters = {}
        for _, cb in ipairs(ws) do cb() end
    end)
end

-- cb() once the map is loaded, or known to be unavailable (then only the title fallback is used).
function PS.am_ready(cb)
    local info = utils.file_info(PS.am_path())
    if info then
        PS.am_load()
        if os.time() - (info.mtime or 0) > 7 * 86400 then PS.am_fetch() end      -- weekly refresh, in the background
        cb(); return
    end
    if PS.AM.state == "failed" and os.time() - (PS.AM.fail_t or 0) < 3600 then cb(); return end
    table.insert(PS.AM.waiters, cb)
    PS.am_fetch()
end

function PS.al_cache()
    local AL = PS.AL
    if AL.cache then return AL.cache end
    AL.cache = {}
    local f = io.open(PS.dir() .. "/anilist.json", "rb")
    if f then
        local ok, d = pcall(utils.parse_json, f:read("*a")); f:close()
        if ok and type(d) == "table" then AL.cache = d end
    end
    return AL.cache
end

-- AniList search, at most one request every 2 s (AniList allows 30 a minute right now). cb(list | nil, err)
function PS.al_search(query, cb)
    local key = PS.norm(query)
    local hit = PS.al_cache()[key]
    local ttl = (type(hit) == "table" and type(hit.r) == "table" and #hit.r > 0) and 30 or 3     -- days; "nothing found" is re-asked sooner
    if type(hit) == "table" and os.time() - (tonumber(hit.t) or 0) < ttl * 86400 then cb(hit.r or {}) return end
    table.insert(PS.AL.q, { q = query, key = key, cb = cb })
    PS.al_pump()
end

function PS.al_pump()
    local AL = PS.AL
    if AL.busy or #AL.q == 0 then return end
    local wait = AL.last + 2.05 - mp.get_time()
    if wait > 0 then
        if not AL.timer then AL.timer = mp.add_timeout(wait, function() AL.timer = nil; PS.al_pump() end) end
        return
    end
    local it = table.remove(AL.q, 1)
    AL.busy, AL.last = true, mp.get_time()
    local bf = PS.dir() .. "/anilist_query.json"
    PS.mkdir()
    local f = io.open(bf, "wb")
    if not f then AL.busy = false; it.cb(nil, "cannot write query"); return end
    local body = safe_json({ query = PS.AL_GQL, variables = { s = it.q } })
    if not body then f:close(); AL.busy = false; it.cb(nil, "bad query"); PS.al_pump(); return end
    f:write(body); f:close()
    PS.run({ o.curl_path, "-s", "-S", "-m", "15", "-w", "\n%{http_code}", "-X", "POST", "-H", "Content-Type: application/json",
             "-H", "Accept: application/json", "--data-binary", "@" .. bf, o.anilist_api }, function(res)
        AL.busy = false
        local reply, code = tostring(res and res.stdout or ""):match("^(.*)\n(%d%d%d)$")
        if code == "429" then              -- rate limited: wait a minute, then try again
            table.insert(AL.q, 1, it); AL.last = mp.get_time() + 58
        elseif code ~= "200" then
            local why = "AniList " .. (code and ("HTTP " .. code) or ("unreachable: " .. tostring(res and res.stderr or ""):sub(1, 120)))
            msg.warn(why .. " (anime titles fall back to the TMDB search for now)")
            it.cb(nil, why)
        else
            local ok, d = pcall(utils.parse_json, reply)
            local media = ok and type(d) == "table" and d.data and d.data.Page and d.data.Page.media
            local list = {}
            for _, m in ipairs(type(media) == "table" and media or {}) do
                local t = type(m.title) == "table" and m.title or {}
                list[#list + 1] = { id = tonumber(m.id), format = m.format, eps = tonumber(m.episodes),
                    year = tonumber(type(m.startDate) == "table" and m.startDate.year or nil) or tonumber(m.seasonYear),
                    romaji = t.romaji, english = t.english, native = t.native,
                    syn = type(m.synonyms) == "table" and m.synonyms or {} }
            end
            local c = PS.al_cache()
            c[it.key] = { t = os.time(), r = list }
            pcall(atomic_write, PS.dir() .. "/anilist.json", safe_json(c) or "{}")
            it.cb(list)
        end
        PS.al_pump()
    end)
end

-- Season number written in an AniList title ("2nd Season", "Season 3", "Part 2" does not count).
local function al_season_of(name)
    local l = tostring(name or ""):lower()
    local n = l:match("(%d+)%a%a season") or l:match("season (%d+)") or l:match("%s(%d)$")
    if n then return tonumber(n) end
    if l:match("%sii$") then return 2 end
    if l:match("%siii$") then return 3 end
    return nil
end

-- "Part 2", "Part II", "2nd Cour", "Cour 2" -> 2
local function al_part_of(name)
    local l = " " .. tostring(name or ""):lower() .. " "
    local n = l:match("part%s*(%d+)") or l:match("(%d+)%a%a cour") or l:match("cour%s*(%d+)")
    if n then return tonumber(n) end
    local r = l:match("part%s+([ivx]+)[%s%p]")
    return ({ i = 1, ii = 2, iii = 3, iv = 4, v = 5 })[r or ""]
end

-- Best AniList entry for a folder: names must really match (exact, or 60 % of the words), year and type help.
function PS.al_pick(list, title, year, kindpref, season)
    local want = PS.norm(title)
    local part = al_part_of(title)
    local best, best_score
    for i, m in ipairs(list or {}) do
        local names = { m.romaji, m.english, m.native }
        for _, sy in ipairs(m.syn or {}) do names[#names + 1] = sy end
        local exact, ov, sn, pn = false, 0, nil, nil
        for _, nm in ipairs(names) do
            if nm and nm ~= "" then
                if PS.norm(nm) == want then exact = true end
                ov = math.max(ov, PS.overlap(nm, title))
                sn = sn or al_season_of(nm)
                pn = pn or al_part_of(nm)
            end
        end
        if exact or ov >= 0.6 then
            local score = exact and 3 or ov * 2
            local wy, my = tonumber(year) or 0, tonumber(m.year) or 0
            if wy > 0 and my > 0 then
                if wy == my then score = score + 2 elseif math.abs(wy - my) == 1 then score = score + 1 else score = score - 1 end
            end
            local film = (m.format == "MOVIE")
            if kindpref == "movie" then score = score + (film and 1 or -0.5)
            elseif kindpref == "tv" then score = score + (film and -1 or 0.5) end
            if season and season > 1 then score = score + ((sn == season) and 1.5 or -0.5)
            elseif sn and sn > 1 then score = score - 0.7 end
            -- "Part 2" folder -> the "Part 2" entry; "Part 1" (or no part) -> the entry without a later part
            if part and part > 1 then score = score + ((pn == part) and 1.5 or -1)
            elseif pn and pn > 1 then score = score - 1 end
            score = score - (i - 1) * 0.05                -- AniList's own order breaks ties
            if not best_score or score > best_score then best, best_score = m, score end
        end
    end
    return best
end

-- cb(r | nil): r = { d = TMDB details (media_type set), q = how it was found, s = local season, ms / mo / me = TMDB
-- season, episode offset and episode count of this part }
-- AniList's search is literal: "Vanitas no Carte Part 1" finds nothing ("Vanitas no Karte" is the AniList name), so the
-- title is also tried without "Part 1" / "Season 2" / "2nd Cour". (Dropping more words picks the wrong show:
-- "Dragon Ball Kai" -> "Dragon Ball".)
function PS.al_queries(title)
    local out, seen = {}, {}
    local function add(q)
        q = tostring(q or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        if #q >= 3 and not seen[q:lower()] then seen[q:lower()] = true; out[#out + 1] = q end
    end
    add(title)
    local t = tostring(title)
    local core = t:gsub("%s+[Pp]art%s*%d+$", ""):gsub("%s+[Pp]art%s+[IVX]+$", ""):gsub("%s+%d+%a%a%s+[Cc]our$", "")
        :gsub("%s+[Cc]our%s*%d+$", ""):gsub("%s+[Ss]eason%s*%d+$", ""):gsub("%s+%d+%a%a%s+[Ss]eason$", ""):gsub("%s+[Ss]%d+$", "")
    add(core)
    return out
end

function PS.anime_lookup(w, tried, cb)
    local fp = w.raw and CT.parse_folder(w.raw) or nil
    local season = fp and fp.season and tonumber(fp.season:match("^S(%d+)")) or nil
    local title = w.title
    local qs = PS.al_queries(title)
    local qi, net_err = 0, nil
    local function search_next()
        qi = qi + 1
        local q = qs[qi]
        if not q then cb(nil, net_err) return end
        tried[#tried + 1] = "AniList: " .. q
        PS.al_search(q, function(list, err)
            if not list then
                net_err = err
                tried[#tried + 1] = "AniList failed: " .. tostring(err)
                cb(nil, err)                    -- the service is down: no point trying the shorter forms now
                return
            end
            local m = PS.al_pick(list, title, w.year, w.kindpref, season)
            if m then PS.anime_map(w, m, season, tried, cb) else search_next() end
        end)
    end
    search_next()
end

function PS.anime_map(w, m, season, tried, cb)
    PS.am_ready(function()
        local mp_ = PS.AM.map and PS.AM.map[tostring(m.id)]
        local function done(kind, id, how, extra)
            PS.api(string.format("/%s/%s?language=en-US", kind, id), function(d, e2)
                if not d then cb(nil, e2) return end
                d.media_type = kind
                local r = { d = d, q = how }
                for k, v in pairs(extra or {}) do r[k] = v end
                cb(r)
            end)
        end
        if mp_ then
            tried[#tried + 1] = string.format("anime-lists: AniList %d -> %s:%s", m.id, mp_.kind, mp_.id)
            local extra = {}
            -- the folder has no season tag, or the same one as the map: use the map's season / offset
            if mp_.kind == "tv" and (not season or season == (mp_.tvs or mp_.s)) then
                extra.s = (not season) and mp_.tvs or nil
                extra.ms, extra.mo, extra.me = mp_.s, mp_.off, m.eps
            end
            done(mp_.kind, mp_.id, "AniList " .. m.id, extra)
            return
        end
        -- not in the map: TMDB search with the English / native title, checked against AniList's year and type
        local qs = {}
        if m.english and m.english ~= "" then qs[#qs + 1] = m.english end
        if m.native and m.native ~= "" then qs[#qs + 1] = m.native end
        local kp = (m.format == "MOVIE") and "movie" or "tv"
        local i = 0
        local function step()
            i = i + 1
            if not qs[i] then cb(nil) return end
            tried[#tried + 1] = "TMDB (AniList title): " .. qs[i]
            PS.search(qs[i], m.year and tostring(m.year) or "", nil, function(r)
                local ry = r and tonumber(((r.first_air_date or r.release_date or "")):sub(1, 4)) or nil
                if r and r.media_type == kp and (not m.year or (ry and math.abs(ry - m.year) <= 1)) then
                    done(kp, r.id, "AniList " .. m.id .. " title")
                else step() end
            end, kp, true, { anime = true })
        end
        step()
    end)
end

-- Romaji-looking title ("... no ...", "-hen", "-kun", "shita")? Then the AniList lookup is worth it even without fansub tags.
function PS.romaji(title)
    local l = " " .. tostring(title or ""):lower():gsub("[%._]", " ") .. " "
    for _, pat in ipairs({ "%a no %a", "%a wa %a", "%a ga %a", "%a wo %a", "%a ni %a", "[%s%-]kun ", "[%s%-]chan ", "[%s%-]sama ",
                           "shita ", "%-hen ", "%a hen ", "[%s%-]sensei ", "monogatari", "gakuen", "isekai", "tensei" }) do
        if l:find(pat) then return true end
    end
    return false
end

-- ---------- Real-Debrid API (optional: rd_api_token) ----------
-- Only used to explain episodes that WebDAV does not list ("hoster unavailable", "torrent dead"...).
-- The token is sent to rd_api_base only, through a header file (never on the command line, so it
-- cannot show up in the process list or the mpv log).
function PS.kick() if PS.on_kick then PS.on_kick() end end
PS.RD = { list = nil, list_t = 0, info = {}, checks = nil, inflight = {}, running = 0, ver = 0, err = nil }
PS.RD_REASONS = { [16] = "Hoster unsupported", [17] = "Hoster in maintenance", [18] = "Hoster limit reached",
    [19] = "Hoster unavailable", [20] = "Hoster not available for free users", [23] = "Traffic exhausted",
    [24] = "File unavailable", [35] = "Infringing file", [36] = "Fair usage limit" }
PS.RD_STATUS = { magnet_error = "Magnet error", magnet_conversion = "Still converting on Real-Debrid",
    waiting_files_selection = "Waiting for file selection", queued = "Queued on Real-Debrid",
    downloading = "Still downloading on Real-Debrid", error = "Torrent error on Real-Debrid", virus = "Virus detected",
    compressing = "Compressing on Real-Debrid", uploading = "Uploading on Real-Debrid", dead = "Torrent dead on Real-Debrid" }
function PS.rd_on() return tostring(o.rd_api_token or "") ~= "" end
function PS.rd_hfile()
    local RD = PS.RD
    if RD.hfile and RD.hfile_tok == o.rd_api_token and utils.file_info(RD.hfile) then return RD.hfile end
    PS.mkdir()
    local path = PS.dir() .. "/rd_header.txt"
    local f = io.open(path, "wb")
    if not f then return nil end
    f:write("Authorization: Bearer " .. tostring(o.rd_api_token):gsub("%s", "") .. "\n"); f:close()
    RD.hfile, RD.hfile_tok = path, o.rd_api_token
    return path
end
function PS.rd_req(path, post, cb)
    local hf = PS.rd_hfile()
    if not hf then cb(nil, "cannot write the header file", 0) return end
    local args = { o.curl_path, "-s", "-S", "-m", "20", "-H", "@" .. hf, "-w", "\n%{http_code}" }
    if post then
        for k, v in pairs(post) do args[#args + 1] = "--data-urlencode"; args[#args + 1] = k .. "=" .. v end
    end
    args[#args + 1] = tostring(o.rd_api_base or ""):gsub("/+$", "") .. path
    PS.run(args, function(res)
        if not res or res.status ~= 0 then cb(nil, "request failed", 0) return end
        local body, code = tostring(res.stdout):match("^(.*)\n(%d%d%d)$")
        code = tonumber(code) or 0
        local ok, data = pcall(utils.parse_json, body or "")
        cb(ok and data or nil, nil, code)
    end)
end
function PS.rd_load_checks()
    local t = {}
    local f = io.open(PS.dir() .. "/rd_checks.json", "rb")
    if f then
        local ok, d = pcall(utils.parse_json, f:read("*a")); f:close()
        if ok and type(d) == "table" then t = U.plain(d) end
    end
    return t
end
function PS.rd_save_checks()
    local txt = safe_json(PS.RD.checks or {})
    if txt then PS.mkdir(); pcall(atomic_write, PS.dir() .. "/rd_checks.json", txt) end
end
-- The torrent behind one WebDAV folder: { state = "loading" | "unknown" | "ready" | "error", data = torrent info }
function PS.rd_folder(name)
    local RD = PS.RD
    local now = os.time()
    if not RD.list or now - RD.list_t > 600 then
        if not RD.busy_list then
            RD.busy_list = true
            PS.rd_req("/torrents?limit=2500", nil, function(data, err, code)
                RD.busy_list = false
                if type(data) == "table" and code == 200 then
                    RD.list, RD.list_t, RD.err = {}, os.time(), nil
                    for _, t in ipairs(data) do
                        if type(t) == "table" and t.filename then RD.list[tostring(t.filename):lower()] = { id = t.id, status = t.status } end
                    end
                else
                    RD.err = (code == 401 or code == 403) and "Real-Debrid rejected rd_api_token"
                        or ("Real-Debrid: " .. tostring(err or ("HTTP " .. code)))
                    RD.list, RD.list_t = RD.list or {}, os.time() - 480      -- try again in 2 minutes
                end
                RD.ver = RD.ver + 1
                PS.kick()
            end)
        end
        if not RD.list then return { state = "loading" } end
    end
    if RD.err and not next(RD.list) then return { state = "error" } end
    local t = RD.list[tostring(name):gsub("/+$", ""):lower()]
    if not t then return { state = "unknown" } end
    local inf = RD.info[t.id]
    if not inf or (not inf.busy and now - inf.t > 600) then
        RD.info[t.id] = { busy = true, t = inf and inf.t or 0, data = inf and inf.data }
        PS.rd_req("/torrents/info/" .. t.id, nil, function(data, err, code)
            RD.info[t.id] = { t = os.time(), data = (type(data) == "table" and code == 200) and data or (inf and inf.data) }
            RD.ver = RD.ver + 1
            PS.kick()
        end)
        inf = RD.info[t.id]
    end
    if not inf.data then return { state = "loading" } end
    return { state = "ready", data = inf.data }
end
-- Why Real-Debrid cannot serve one link (cached for 6 hours). nil while the answer is pending.
function PS.rd_check(link)
    local RD = PS.RD
    RD.checks = RD.checks or PS.rd_load_checks()
    local c = RD.checks[link]
    if c and c.r and os.time() - (c.t or 0) < 6 * 3600 then return c end
    if c and c.fail and os.time() - (c.t or 0) < 90 then return { r = "Could not reach Real-Debrid" } end
    if RD.inflight[link] or RD.running >= 2 then return nil end
    RD.inflight[link] = true
    RD.running = RD.running + 1
    PS.rd_req("/unrestrict/check", { link = link }, function(data, err, code)
        RD.running = RD.running - 1
        RD.inflight[link] = nil
        local r
        if type(data) == "table" and data.error_code then
            r = PS.RD_REASONS[tonumber(data.error_code)] or (tostring(data.error or "error"):gsub("_", " "))
        elseif code == 503 then r = "File unavailable"
        elseif code == 200 and type(data) == "table" and tonumber(data.supported) == 0 then r = "Hoster unavailable"
        elseif code == 200 then r = "Available on Real-Debrid, not listed by WebDAV yet"
        elseif code == 0 then RD.checks[link] = { fail = true, t = os.time() }
        else r = "Real-Debrid HTTP " .. code end
        if r then RD.checks[link] = { r = r, t = os.time() }; PS.rd_save_checks() end
        RD.ver = RD.ver + 1
        PS.kick()
    end)
    return nil
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
function PS.pick(results, title, year, kindpref, strict, opts)
    local best, best_score, any
    local want = PS.norm(title)
    opts = opts or {}
    for _, r in ipairs(results or {}) do
        if (r.media_type == "tv" or r.media_type == "movie") and r.poster_path and r.poster_path ~= "" then
            local date = r.first_air_date or r.release_date or ""
            local nm, on = PS.norm(r.name or r.title or ""), PS.norm(r.original_name or r.original_title or "")
            local exact = (nm == want or on == want)
            local related = exact or (#want >= 4 and ((nm ~= "" and (nm:find(want, 1, true) or want:find(nm, 1, true)))
                or (on ~= "" and (on:find(want, 1, true) or want:find(on, 1, true)))))
            -- a shortened query ("Boku no") must still resemble the full title, or "Boku no Nee-chan" wins
            if related and opts.full and not exact then
                related = PS.overlap(r.name or r.title or "", opts.full) >= 0.6 or PS.overlap(r.original_name or r.original_title or "", opts.full) >= 0.6
            end
            local score = exact and 3 or (related and 1 or 0)
            if opts.anime then
                local anim = false
                for _, g in ipairs(type(r.genre_ids) == "table" and r.genre_ids or {}) do if tonumber(g) == 16 then anim = true end end
                if anim then score = score + 2 end
                if r.original_language == "ja" then score = score + 0.5 end
            end
            local ry = tonumber(date:sub(1, 4)) or 0
            local wy = tonumber(year) or 0
            if wy > 0 and ry > 0 then
                if ry == wy then score = score + 2 elseif math.abs(ry - wy) == 1 then score = score + 1 end
            end
            if kindpref and kindpref ~= "" and r.media_type == kindpref then score = score + 1.5 end
            score = score + math.min(0.9, (tonumber(r.popularity) or 0) / 1000)
            if not any and (not opts.full or PS.overlap(r.name or r.title or "", opts.full) >= 0.6) then any = r end
            if (not strict or related) and (not best_score or score > best_score) then best, best_score = r, score end
        end
    end
    return best, any
end

function PS.search(title, year, gen, cb, kindpref, strict, opts)
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
        local best, any = PS.pick(data.results, title, year, kindpref, strict, opts)
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
PS.eps, PS.eps_ver, PS.idx_ver = nil, 0, 0
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
    local mv = entry.kind == "movie"
    PS.api(string.format("/%s/%s?language=en-US&append_to_response=%s", mv and "movie" or "tv", entry.id,
        mv and "release_dates" or "content_ratings"), function(d)
        if d then
            -- rich details: genres, runtime, status, age rating, tagline, years, creators
            local gen = {}
            for _, g in ipairs(type(d.genres) == "table" and d.genres or {}) do if g.name then gen[#gen + 1] = g.name end end
            entry.gen = gen
            entry.lang = d.original_language or entry.lang
            local rt = tonumber(d.runtime)
            if not rt and type(d.episode_run_time) == "table" then rt = tonumber(d.episode_run_time[1]) end
            entry.rt = rt or 0
            entry.status = d.status or ""
            entry.tag = d.tagline or ""
            entry.neps = tonumber(d.number_of_episodes) or entry.neps
            entry.yr2 = tostring(d.last_air_date or ""):sub(1, 4)
            local by = {}
            for _, c in ipairs(type(d.created_by) == "table" and d.created_by or {}) do if c.name and #by < 2 then by[#by + 1] = c.name end end
            entry.by = table.concat(by, ", ")
            local cert = ""
            local function pick_cert(list, field)
                for _, r in ipairs(list or {}) do
                    if r.iso_3166_1 == "US" then
                        if field then
                            for _, rd in ipairs(r.release_dates or {}) do if rd.certification and rd.certification ~= "" then return rd.certification end end
                        elseif r.rating and r.rating ~= "" then return r.rating end
                    end
                end
                return ""
            end
            if mv and type(d.release_dates) == "table" then cert = pick_cert(d.release_dates.results, true)
            elseif type(d.content_ratings) == "table" then cert = pick_cert(d.content_ratings.results, false) end
            entry.cert = cert
            entry.overview = tostring(d.overview or "")
            entry.backdrop_path = d.backdrop_path or entry.backdrop_path or ""
            entry.seasons = tonumber(d.number_of_seasons) or entry.seasons
            entry.vote = tonumber(d.vote_average) or entry.vote
            local sc, sp, snm = {}, {}, {}
            local n = 0
            if type(d.seasons) == "table" then
                for _, se in ipairs(d.seasons) do
                    local sn, cnt = tonumber(se.season_number), tonumber(se.episode_count)
                    if sn and sn >= 1 and cnt then sc[tostring(sn)] = cnt; n = n + 1 end
                    if sn then
                        if se.poster_path and se.poster_path ~= "" then sp[tostring(sn)] = se.poster_path end
                        if se.name and se.name ~= "" then snm[tostring(sn)] = se.name end
                    end
                end
            end
            entry.sc = (n > 0) and sc or false
            entry.sp, entry.sn = sp, snm
            if (entry.poster_path or "") == "" then entry.poster_path = d.poster_path end
            if not entry.name or entry.name == "?" then entry.name = d.name or d.title end
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
    local mode = PS.conv_mode and PS.conv_mode() or o.poster_converter
    if mode == "auto" or not mode then mode = (package.config:sub(1, 1) == "\\") and "powershell" or "ffmpeg" end
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
-- HOME: Netflix-style poster grid (poster edition only)
-- Rows of poster cards with the clean title underneath: Continue Watching and All Titles. Enter opens a
-- title page (episodes with TMDB stills) or resumes a Continue Watching card. Artwork is fetched from TMDB
-- lazily (what is on screen first, the next rows while idle), cached on disk, converted to BGRA with rounded
-- corners and shown with overlay-add. This product uses the TMDB API but is not endorsed or certified by TMDB.
-- ============================================================
local HV = {
    r = 1, c = 1, want_vc = 1, top = 1, rows = {}, sig = nil,
    items = {}, sn = 0, dn = 0, convq = {}, converting = false, batch_n = 0,
    shown = {}, hover = nil, vis = {}, hit = {}, vis_cards = {}, wanted = {},
    last_data = nil, last_click_t = 0, last_click = nil, m = nil, mode = "home",
}
local TV = { req = {}, sn = 0, card = nil }     -- title page of one show (episodes with TMDB stills)
HV.tv = TV

HV.PS1 = [==[
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
        if ($p.Length -ge 5 -and $p[4] -ne '') {
            # backdrop: fade the left 45 %, the bottom 30 % and the top 12 % into the background colour
            $c = [System.Drawing.ColorTranslator]::FromHtml('#' + $p[4])
            $on = [System.Drawing.Color]::FromArgb(255, $c); $off = [System.Drawing.Color]::FromArgb(0, $c)
            $blend = New-Object System.Drawing.Drawing2D.Blend(5)
            $blend.Positions = [single[]](0, 0.25, 0.5, 0.75, 1); $blend.Factors = [single[]](0, 0.156, 0.5, 0.844, 1)
            $parts = @(
                @((New-Object System.Drawing.RectangleF(0, 0, [single]($W * 0.45), $H)), $on, $off, 0),
                @((New-Object System.Drawing.RectangleF(0, [single]($H * 0.70), $W, [single]($H * 0.30 + 1))), $off, $on, 1),
                @((New-Object System.Drawing.RectangleF(0, 0, $W, [single]($H * 0.12))), $on, $off, 1))
            foreach ($q in $parts) {
                $br = New-Object System.Drawing.Drawing2D.LinearGradientBrush($q[0], $q[1], $q[2], [System.Drawing.Drawing2D.LinearGradientMode]$q[3])
                $br.Blend = $blend; $br.WrapMode = [System.Drawing.Drawing2D.WrapMode]::TileFlipXY
                $g.FillRectangle($br, $q[0]); $br.Dispose()
            }
        }
        $g.Dispose(); $src.Dispose()
        $rect = New-Object System.Drawing.Rectangle(0, 0, $W, $H)
        $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, $fmt)
        $bytes = New-Object byte[] ($data.Stride * $H)
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
        $bmp.UnlockBits($data); $bmp.Dispose()
        [System.IO.File]::WriteAllBytes($p[1], $bytes)
    } catch { }
}
]==]

local function hv_clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

function HV.active() return browser_active and MS.view == "home" end
-- The hero band is only shown while the first row is at the top; scrolling down gives the rows the full height.
function HV.rows_y(m) return ((m.title and HV.top <= 1) and m.ry1 or m.ry0) + ((HV.q and not m.title) and m.chip_h or 0) end
function HV.kick() if HV.active() then render() end end
PS.on_kick = function() HV.kick() end
PS.conv_mode = function() return HV.conv_mode() end

-- ---------- geometry ----------
function HV.metrics()
    local w, h = U.canvas_size()
    local pct = tonumber(o.home_card_pct) or 19
    local title = (HV.mode == "title")
    -- ONE scale for every screen, from the window height (1080 px = 1.0) times ui_scale. Cards and text used to have
    -- separate pixel caps per screen, so on a 4K window the home / season screens and the episode screen looked like
    -- two different zoom levels.
    local S = h / 1080 * (tonumber(o.ui_scale) or 1)
    local lfs = math.max(12, math.floor(20 * S + 0.5))
    HV.R = ((tonumber(o.card_radius) or 0) > 0) and math.max(1, math.floor(o.card_radius * S + 0.5)) or 0
    HV.couch = HV.couch_on()
    if HV.couch then lfs = math.floor(lfs * 1.12 + 0.5) end
    local cw = hv_clamp(math.floor(h * pct / 100 * (tonumber(o.ui_scale) or 1) + 0.5), 90, math.floor(h * 0.45))
    local grid = title and TV.grid()
    if title and not grid then
        cw = hv_clamp(math.floor(h * 0.33 * (tonumber(o.ui_scale) or 1)), 150, math.floor(w * 0.45))   -- 16:9 episode stills
    end
    local gap = math.max(10, math.floor(cw * 0.09))
    local side = math.max(24, math.floor(w * 0.025)) * 2            -- side margins grow with the window
    local per = math.max(2, math.floor((w - side + gap) / (cw + gap)))
    local used = per * cw + (per - 1) * gap
    local m = { w = w, h = h, cw = cw, ch = (title and not grid) and math.floor(cw * 9 / 16) or math.floor(cw * 1.5), gap = gap, per = per, lfs = lfs }
    m.title = title
    m.mx = math.floor((w - used) / 2)
    m.top_h = math.max(48, math.floor(lfs * 3.2))
    m.hero_h = title and math.floor(h * 0.27) or 0
    m.foot_h = math.max(44, math.floor(lfs * 3.5))
    m.sec_h = math.floor(lfs * 2.3)
    m.bar_h = math.max(4, math.floor(8 * S))
    m.chip_h = math.floor(lfs * 2.4)
    m.S = S
    m.line_h = math.floor(lfs * 1.3)
    m.label_h = m.line_h * 2 + math.floor(lfs * 1.2) + 6
    m.block_h = m.ch + m.bar_h + m.label_h + math.floor(lfs * 1.1)
    m.ry0, m.ry1 = m.top_h + 6, m.top_h + m.hero_h + 6     -- first row's y without / with the hero band
    m.sk = HV.skey(m.cw, m.ch)
    HV.grown(m)
    -- landscape rows (Continue Watching): 16:9 cards of their own size
    do
        local lw = hv_clamp(math.floor(h * 0.30 * (tonumber(o.ui_scale) or 1)), 150, math.floor(w * 0.45))
        local L = { cw = lw, ch = math.floor(lw * 9 / 16), gap = gap }
        L.per = math.max(1, math.floor((w - 2 * m.mx + gap) / (lw + gap)))
        L.block_h = L.ch + m.bar_h + m.label_h + math.floor(lfs * 1.1)
        L.sk = HV.skey(L.cw, L.ch)
        HV.grown(L)
        m.L = L
    end
    return m
end

-- Size of the selected (slightly bigger) card: an even number of pixels more on each axis, so it stays centred.
function HV.grown(d)
    local g = math.max(1, math.min(1.15, tonumber(o.selected_grow) or 1))
    local ex = 2 * math.floor(d.cw * (g - 1) / 2 + 0.5)
    local ey = 2 * math.floor(d.ch * (g - 1) / 2 + 0.5)
    if ex < 2 or ey < 2 then d.gw = nil; return end
    d.gw, d.gh = d.cw + ex, d.ch + ey
    d.gsk = HV.skey(d.gw, d.gh)
end

-- Card size / cards per row / row height for one row (landscape rows have their own).
function HV.rowdim(row, m)
    if row and row.land and m.L then return m.L end
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
-- "Bleach USBD Remux TL" / "Bleach - Box 01" (no season tag, no year) used to get a key of their own and ended up as
-- a separate "Bleach (Box 01)" card next to "Bleach" (S17); now everything without a year joins the show's card.
function HV.gkey(name)
    local id = HV.ident(name)
    if o.merge_seasons and ((id.fp and id.fp.season) or id.year == "") then return PS.norm(id.title) end
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
    if PS.enabled() then
        PS.load_index()
        local ix = PS.idx[id.key]
        if type(ix) == "table" and (tonumber(ix.vote) or 0) > 0 then parts[#parts + 1] = dp(string.format("★ %.1f", ix.vote), THEME.warn, 6) end
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
                if fp and fp.season then seasons[fp.season] = true end
            end
            local nseasons = 0
            for _ in pairs(seasons) do nseasons = nseasons + 1 end
            c.parts = {}
            if nseasons > 1 then c.parts[1] = dp(string.format("%d seasons", nseasons), THEME.text_muted, 9)
            elseif c.kindpref ~= "movie" then
                local tagged = 0
                for _, f in ipairs(c.folders) do local fp_ = CT.parse_folder(f.name); if fp_ and fp_.season then tagged = tagged + 1 end end
                local one = (tagged == #c.folders) and next(seasons) or nil
                c.parts[1] = dp((one and (one .. " · ") or "") .. string.format("%d folders", #c.folders), THEME.text_muted, 9)
            else c.parts[1] = dp(string.format("%d versions", #c.folders), THEME.text_muted, 9) end
            local ixm = PS.enabled() and PS.idx and PS.idx[c.key]
            if type(ixm) == "table" and (tonumber(ixm.vote) or 0) > 0 then c.parts[#c.parts + 1] = dp(string.format("★ %.1f", ixm.vote), THEME.warn, 6) end
            for _, p in ipairs(HV.chip_parts(fl.parts and (function() local ch = {} for _, x in ipairs(fl.parts) do if CT.COLORS[x.t] then ch[#ch + 1] = x.t end end return ch end)())) do
                c.parts[#c.parts + 1] = p
            end
        end
    end
    if o.experimental_merge_by_tmdb and PS.enabled() then order = HV.merge_by_tmdb(order) end
    -- two different titles that read the same (a 2019 film and a 2024 series): add the year / type to the label
    local count = {}
    for _, c in ipairs(order) do local k = PS.norm(c.title); count[k] = (count[k] or 0) + 1 end
    for _, c in ipairs(order) do
        if count[PS.norm(c.title)] > 1 then
            local tag
            if c.kindpref == "tv" then tag = (c.year ~= "") and (c.year .. " series") or "series"
            elseif c.kindpref == "movie" or c.year ~= "" then tag = (c.year ~= "") and c.year or "movie"
            else
                -- no season, no year: tell them apart by the folder name's own extra words ("Box 01", "USBD")
                local extra = tostring(c.raw or ""):gsub("%b[]", ""):gsub("%b()", ""):gsub("[%._]+", " ")
                extra = extra:gsub("^%s*" .. c.title:gsub("%p", "%%%0") .. "%s*", "", 1):gsub("^[%s%-:]+", ""):gsub("%s+$", "")
                tag = (extra ~= "" and #extra <= 18) and extra or nil
            end
            if tag then c.shown = c.title .. " (" .. tag .. ")" end
        end
    end
    return order
end

-- experimental_merge_by_tmdb: cards whose lookups found the same TMDB title become one card.
function HV.merge_by_tmdb(order)
    PS.load_index()
    local by, out = {}, {}
    for _, c in ipairs(order) do
        local e = PS.idx[c.key]
        local tk = (type(e) == "table" and not e.none and e.id) and (tostring(e.kind) .. ":" .. e.id) or nil
        local g = tk and by[tk]
        if g then
            for _, f in ipairs(c.folders) do g.folders[#g.folders + 1] = f end
            if c.mtime > g.mtime then g.mtime = c.mtime end
            g.merged = (g.merged or 1) + 1
        else
            if tk then by[tk] = c; c.tmdb = e end
            out[#out + 1] = c
        end
    end
    for _, c in ipairs(out) do
        if c.merged and c.tmdb then
            c.title, c.shown = c.tmdb.name or c.title, nil
            c.kindpref = c.tmdb.kind or c.kindpref
            local seasons = {}
            for _, f in ipairs(c.folders) do
                local s_ = TV.folder_season(f.name)
                if s_ then seasons[s_] = true end
            end
            local n = 0
            for _ in pairs(seasons) do n = n + 1 end
            c.parts = { dp(string.format("%d folders", #c.folders), THEME.text_muted, 9) }
            if n > 1 then c.parts[1] = dp(string.format("%d seasons · %d folders", n, #c.folders), THEME.text_muted, 9) end
            c.parts[#c.parts + 1] = dp("merged", THEME.accent, 3)
        end
    end
    return out
end

-- TMDB image size for a card px wide on screen (4K screens get sharper downloads instead of upscaled w300/w342 ones).
function HV.img_size(kind, px)
    px = px or 0
    if kind == "poster" then return (px <= 342 and "w342") or (px <= 500 and "w500") or "w780" end
    if kind == "backdrop" then return (px <= 300 and "w300") or (px <= 780 and "w780") or "w1280" end
    return (px <= 300) and "w300" or "original"            -- episode stills: w92 / w185 / w300 / original only
end

-- Continue Watching in landscape: the still of the episode you are in (TMDB), else the show's backdrop.
function HV.cw_still(c, e)
    local lw = HV.m and HV.m.L and HV.m.L.cw or 300
    if not PS.enabled() then return end
    PS.load_index()
    local show = PS.idx[c.key]
    if type(show) ~= "table" or show.none or not show.id then return end
    local hint = TV.season_of(U.basename(e.dirpath or U.dirname(e.href)))
    local s_, e_ = TV.se_of(e.name, hint)
    if show.kind ~= "movie" and s_ and e_ then
        local info = PS.ep_info(show, s_, e_)
        if info and info.st and info.st ~= "" then
            c.key = string.format("still:%s:%d:%d", show.id, s_, e_)
            c.still = { size = HV.img_size("still", lw), path = info.st, base = string.format("s%s_%d_%d", show.id, s_, e_) }
            c.ep_name = info.n
            return
        end
        PS.load_eps()
        if PS.eps[show.id .. ":" .. s_] == nil then c.need = { entry = show, s = s_ } end
    end
    if show.backdrop_path and show.backdrop_path ~= "" then
        c.key = "bd:" .. show.id
        c.still = { size = HV.img_size("backdrop", lw), path = show.backdrop_path, base = "b" .. show.id }
    end
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
    -- the cursor stays where it is on screen (it used to follow the selected card, which could be anywhere after re-sorting)
    HV.sig = nil
    status_line = "Sort: " .. (nm == "recent" and "Recent first" or (HV.mode == "title" and "Episode order" or "Name"))
    save_persistence()
    render()
end

-- ---------- search: typo-tolerant title matching + filters ----------
-- Filters typed into the search box (or toggled with the chips under it):
--   genre:anime  genre:"sci-fi"  year:2004  year:2000-2010  year:2010s  year:>2015  type:tv|movie  rating:8  unwatched  watched
HV.GENRES = { [28] = "Action", [12] = "Adventure", [16] = "Animation", [35] = "Comedy", [80] = "Crime", [99] = "Documentary",
    [18] = "Drama", [10751] = "Family", [14] = "Fantasy", [36] = "History", [27] = "Horror", [10402] = "Music", [9648] = "Mystery",
    [10749] = "Romance", [878] = "Science Fiction", [10770] = "TV Movie", [53] = "Thriller", [10752] = "War", [37] = "Western",
    [10759] = "Action & Adventure", [10762] = "Kids", [10763] = "News", [10764] = "Reality", [10765] = "Sci-Fi & Fantasy",
    [10766] = "Soap", [10767] = "Talk", [10768] = "War & Politics" }

HV.FILTER_KEYS = { genre = true, g = true, type = true, kind = true, rating = true, r = true, year = true, y = true }
function HV.parse_query(q)
    local f = { text = {}, genre = {}, tokens = {} }
    q = tostring(q or "")
    local rest = q:gsub('(%a+):"([^"]*)"', function(k, v) f.tokens[#f.tokens + 1] = { k:lower(), v } return " " end)
    for w in rest:gmatch("%S+") do
        local k, v = w:match("^(%a+):(.+)$")
        local lw = w:lower()
        if k and not HV.FILTER_KEYS[k:lower()] then k = nil end          -- "re:zero" is a title, not a filter
        if k then f.tokens[#f.tokens + 1] = { k:lower(), v }
        elseif lw == "unwatched" or lw == "is:unwatched" then f.unwatched = true
        elseif lw == "watched" or lw == "is:watched" then f.watched = true
        else f.text[#f.text + 1] = w end
    end
    for _, t in ipairs(f.tokens) do
        local k, v = t[1], t[2]:lower()
        if k == "genre" or k == "g" then f.genre[#f.genre + 1] = v
        elseif k == "type" or k == "kind" then f.kind = (v:match("^mov") or v:match("^film")) and "movie" or "tv"
        elseif k == "rating" or k == "r" then f.rmin = tonumber((v:gsub("[^%d%.]", "")))
        elseif k == "year" or k == "y" then
            local a, b = v:match("^(%d%d%d%d)%-(%d%d%d%d)$")
            local dec = v:match("^(%d%d%d)0s$")
            if a then f.y1, f.y2 = tonumber(a), tonumber(b)
            elseif dec then f.y1, f.y2 = tonumber(dec) * 10, tonumber(dec) * 10 + 9
            elseif v:match("^>=") then f.y1 = tonumber(v:match("%d+"))
            elseif v:match("^<=") then f.y2 = tonumber(v:match("%d+"))
            elseif v:match("^>") then f.y1 = (tonumber(v:match("%d+")) or 0) + 1
            elseif v:match("^<") then f.y2 = (tonumber(v:match("%d+")) or 10000) - 1
            elseif v:match("^%d%d%d%d$") then f.y1, f.y2 = tonumber(v), tonumber(v) end
        end
    end
    f.query = table.concat(f.text, " ")
    f.any = (#f.genre > 0 or f.kind or f.rmin or f.y1 or f.y2 or f.unwatched or f.watched) and true or false
    return f
end
function HV.text_of(q) return HV.parse_query(q).query end

-- Damerau-Levenshtein distance (small strings only).
function HV.dist(a, b)
    local la, lb = #a, #b
    if math.abs(la - lb) > 2 then return 99 end
    local d = {}
    for i = 0, la do d[i] = { [0] = i } end
    for j = 0, lb do d[0][j] = j end
    for i = 1, la do
        for j = 1, lb do
            local cost = (a:sub(i, i) == b:sub(j, j)) and 0 or 1
            local v = math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
            if i > 1 and j > 1 and a:sub(i, i) == b:sub(j - 1, j - 1) and a:sub(i - 1, i - 1) == b:sub(j, j) then
                v = math.min(v, d[i - 2][j - 2] + 1)
            end
            d[i][j] = v
        end
    end
    return d[la][lb]
end
-- 0 = no match, up to 1 = exact. Every word you type has to match a word of the name: exactly, as its start, inside it,
-- or with a typo or two ("bleahc", "shipuden").
function HV.fuzzy(query, name)
    local qw, nw = {}, {}
    for w in query:lower():gmatch("[%w]+") do qw[#qw + 1] = w end
    for w in tostring(name):lower():gsub("['’]", ""):gmatch("[%w]+") do nw[#nw + 1] = w end
    if #qw == 0 or #nw == 0 then return 0 end
    local joined = table.concat(nw)
    local total = 0
    for _, q in ipairs(qw) do
        local best = 0
        for _, n in ipairs(nw) do
            local sc = 0
            if n == q then sc = 1
            elseif n:sub(1, #q) == q then sc = 0.9
            elseif #q >= 3 and n:find(q, 1, true) then sc = 0.75
            elseif #q >= 4 then
                local lim = (#q >= 8) and 2 or 1
                local d1 = HV.dist(q, n)
                local d2 = (#n > #q) and HV.dist(q, n:sub(1, #q)) or 99
                if math.min(d1, d2) <= lim then sc = 0.6 end
            end
            if sc > best then best = sc end
        end
        if best == 0 and #q >= 4 and joined:find(q, 1, true) then best = 0.7 end
        if best == 0 then return 0 end
        total = total + best
    end
    return total / #qw
end

-- Facts a filter needs about one title card.
function HV.card_facts(c)
    PS.load_index()
    local e = PS.idx[c.key]
    e = (type(e) == "table" and not e.none) and e or nil
    local gen = {}
    if e and type(e.gen) == "table" and #e.gen > 0 then for _, g in ipairs(e.gen) do gen[#gen + 1] = tostring(g):lower() end
    elseif e and type(e.g) == "table" then for _, id in ipairs(e.g) do if HV.GENRES[tonumber(id)] then gen[#gen + 1] = HV.GENRES[tonumber(id)]:lower() end end end
    local year = tonumber((e and e.year ~= "" and e.year) or c.year)
    -- not matched (yet): the folder names still tell anime apart (fansub tags, romaji titles)
    local hint = nil
    if not e then
        hint = PS.romaji(c.title) and true or false
        for _, fo in ipairs(c.folders or {}) do if PS.animeish(fo.name) then hint = true end end
    end
    return { gen = gen, year = year, kind = (e and e.kind) or (c.kindpref ~= "" and c.kindpref or nil), known = e ~= nil,
             anime_hint = hint, vote = e and tonumber(e.vote) or nil, lang = e and e.lang or nil, names = { c.title, c.shown, e and e.name } }
end

-- top-level folders you have watched something in / finished something in
function HV.watch_sets()
    local rootn = root_href:gsub("/+$", "")
    local any = {}
    local function top(h)
        local t = tostring(h):match("^(" .. rootn:gsub("%p", "%%%0") .. "/[^/]+)")
        return t
    end
    for h in pairs(watched_set) do local t = top(h); if t then any[t] = true end end
    for h, rec in pairs(watch_history) do if rec.pos then local t = top(h); if t then any[t] = true end end end
    return any
end

function HV.passes(c, f, facts, watched_any)
    if f.kind and facts.kind ~= f.kind then return false end
    if f.rmin and not (facts.vote and facts.vote >= f.rmin) then return false end
    if f.y1 and not (facts.year and facts.year >= f.y1) then return false end
    if f.y2 and not (facts.year and facts.year <= f.y2) then return false end
    for _, g in ipairs(f.genre) do
        local ok = false
        if g == "anime" then
            for _, x in ipairs(facts.gen) do if x == "animation" then ok = (facts.lang == "ja") or facts.lang == nil end end
            if not facts.known and facts.anime_hint then ok = true end
        else
            local gn = g:gsub("[^%w]", "")
            for _, x in ipairs(facts.gen) do if x:gsub("[^%w]", ""):find(gn, 1, true) then ok = true end end
        end
        if not ok then return false end
    end
    if f.unwatched or f.watched then
        local seen = false
        for _, fo in ipairs(c.folders or {}) do if watched_any[fo.href:gsub("/+$", "")] then seen = true end end
        if f.unwatched and seen then return false end
        if f.watched and not seen then return false end
    end
    return true
end

-- Show cards for the library search: fuzzy title matches first, then titles whose files/folders matched, then filters.
function HV.search_cards(groups)
    local f = HV.parse_query(HV.q)
    local scored, seen = {}, {}
    local function add(c, sc)
        if seen[c] then if sc > seen[c].sc then seen[c].sc = sc end return end
        local item = { c = c, sc = sc }
        seen[c] = item
        scored[#scored + 1] = item
    end
    if f.query == "" then
        if f.any then for _, c in ipairs(groups) do add(c, 1) end end
    else
        for _, c in ipairs(groups) do
            local facts = HV.card_facts(c)
            local best = 0
            for _, nm in ipairs(facts.names) do if nm then best = math.max(best, HV.fuzzy(f.query, nm)) end end
            for _, fo in ipairs(c.folders or {}) do
                local fp = CT.parse_folder(fo.name)
                if fp and fp.alt then best = math.max(best, HV.fuzzy(f.query, fp.alt)) end
            end
            if best > 0 then add(c, 1 + best) end
        end
        -- files / folders inside titles (library index)
        local byhref = {}
        for _, c in ipairs(groups) do for _, fo in ipairs(c.folders) do byhref[fo.href:gsub("/+$", "")] = c end end
        for _, r in ipairs(search_results or {}) do
            local h = (r.is_dir and r.href or r.dirpath or r.href):gsub("/+$", "")
            local guard = 0
            while guard < 12 and h ~= "" and not byhref[h] do
                local up = U.dirname(h .. "/"):gsub("/+$", "")
                if up == h then break end
                h = up
                guard = guard + 1
            end
            if byhref[h] then add(byhref[h], 0.5) end
        end
    end
    local out = {}
    local wa = (f.unwatched or f.watched) and HV.watch_sets() or {}
    -- filters need TMDB data, which is normally only fetched for what is on screen: look the rest up in the background
    HV.filter_pending = nil
    if f.any and PS.enabled() then
        PS.load_index()
        local pend = {}
        for _, it in ipairs(scored) do if PS.idx[it.c.key] == nil then pend[#pend + 1] = it.c end end
        HV.filter_pending = (#pend > 0) and pend or nil
    end
    for _, it in ipairs(scored) do
        if not f.any or HV.passes(it.c, f, HV.card_facts(it.c), wa) then out[#out + 1] = it end
    end
    table.sort(out, function(a, b)
        if a.sc ~= b.sc then return a.sc > b.sc end
        return U.natural_less(a.c.title, b.c.title)
    end)
    local cards = {}
    for i, it in ipairs(out) do cards[i] = it.c end
    return cards
end

-- Filter chips under the search box (click to toggle; they just edit the text in the box).
function HV.chip_defs(groups)
    local defs = {
        { label = "TV", tok = "type:tv" }, { label = "Movies", tok = "type:movie" }, { label = "Unwatched", tok = "unwatched" },
        { label = "★ 8+", tok = "rating:8" }, { label = "Anime", tok = "genre:anime" },
    }
    -- the library's most common genres and decades
    local gc, dc = {}, {}
    for _, c in ipairs(groups or {}) do
        local fa = HV.card_facts(c)
        for _, g in ipairs(fa.gen) do gc[g] = (gc[g] or 0) + 1 end
        if fa.year then local d = math.floor(fa.year / 10) * 10; dc[d] = (dc[d] or 0) + 1 end
    end
    local gl, dl = {}, {}
    for g in pairs(gc) do if g ~= "animation" then gl[#gl + 1] = g end end
    table.sort(gl, function(a, b) return gc[a] > gc[b] end)
    for i = 1, math.min(5, #gl) do
        local name = gl[i]:gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end)
        defs[#defs + 1] = { label = name, tok = 'genre:"' .. gl[i] .. '"' }
    end
    for d in pairs(dc) do dl[#dl + 1] = d end
    table.sort(dl, function(a, b) return a > b end)
    for i = 1, math.min(4, #dl) do defs[#defs + 1] = { label = dl[i] .. "s", tok = "year:" .. dl[i] .. "s" } end
    return defs
end
-- Words of the query; a quoted value (genre:"science fiction") stays one word.
function HV.q_words(q)
    local out, i = {}, 1
    q = tostring(q or "")
    while i <= #q do
        local a, b = q:find("^%S-\"[^\"]*\"", i)
        if not a then a, b = q:find("^%S+", i) end
        if a then out[#out + 1] = q:sub(a, b); i = b + 1 else i = i + 1 end
    end
    return out
end

function HV.toggle_token(tok)
    local words, kept, had = HV.q_words(HV.q), {}, false
    local key = tok:match("^(%a+):")
    for _, w in ipairs(words) do
        if w:lower() == tok:lower() then had = true
        elseif key == "type" and w:lower():match("^type:") then -- "type:tv" and "type:movie" exclude each other
        else kept[#kept + 1] = w end
    end
    if not had then kept[#kept + 1] = tok end
    local q = table.concat(kept, " ")
    HV.q = (q:gsub("^%s+", ""):gsub("%s+$", ""))
    HV.cur = #HV.q
    search_query = HV.text_of(HV.q)
    run_global_search_hook()
    HV.r, HV.c, HV.top, HV.want_vc = 1, 1, 1, 1
    HV.sig = nil
    render()
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
        HV.chips = HV.chip_defs(groups)
        local cards = HV.search_cards(groups)
        local q = HV.q
        local note = (MS.idx_running or not index_meta.last_full) and "  ·  index still building, results may be incomplete" or ""
        if HV.filter_pending then note = string.format("  ·  looking up %d more title%s for the filter…", #HV.filter_pending, #HV.filter_pending == 1 and "" or "s") .. note end
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
            if o.continue_landscape then HV.cw_still(c, e) end
            local d = o.merge_seasons and c.gkey or (e.dirpath or "")
            if not seen[d] then seen[d] = true; cards[#cards + 1] = c end
        end
        if #cards > 0 then table.insert(rows, 1, { title = "Continue Watching", cards = cards, shelf = true, off = 0, land = o.continue_landscape or nil }) end
    end
    if #groups > 0 then
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
            rows[#rows + 1] = { title = first and string.format("All Titles  ·  %d  ·  Sort: %s  ⇅", #all, recent and "Recently added" or "Name") or nil,
                sort_hdr = first or nil, cards = cards, off = 0 }
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
    local per = HV.rowdim(row, m).per
    if HV.c <= row.off then row.off = HV.c - 1
    elseif HV.c > row.off + per then row.off = HV.c - per end
    row.off = hv_clamp(row.off, 0, math.max(0, #row.cards - per))
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
    -- matched while AniList was unreachable: ask again once per session (the old answer stays until a better one comes)
    if type(hit) == "table" and hit.ale and o.anime_lookup and not (PS.ale_retry or {})[ik] then
        PS.ale_retry = PS.ale_retry or {}
        PS.ale_retry[ik] = true
        hit = nil
    end
    if hit ~= nil then
        if hit == false or hit.none then st.state = "none" else st.entry, st.state = hit, "entry" end
        st.tried = type(hit) == "table" and hit.tried or nil
        return
    end
    st.state = "searching"
    st.tried = {}
    local ale = nil         -- set when AniList could not be reached
    HV.sn = HV.sn + 1
    local function store(r, q, extra)
        local entry = {
            id = tostring(r.id or "0"), name = r.name or r.title or "?", kind = r.media_type,
            year = (r.first_air_date or r.release_date or ""):sub(1, 4), poster_path = r.poster_path,
            overview = tostring(r.overview or ""):sub(1, 600), backdrop_path = r.backdrop_path or "",
            vote = tonumber(r.vote_average) or 0, q = q,
            g = type(r.genre_ids) == "table" and r.genre_ids or nil, lang = r.original_language, tried = st.tried,
        }
        if type(r.genres) == "table" and not entry.g then          -- details replies list genres as objects
            entry.g = {}
            for _, gg in ipairs(r.genres) do entry.g[#entry.g + 1] = gg.id end
        end
        for k, v in pairs(extra or {}) do entry[k] = v end   -- s (season the folder holds), ms / mo / me (anime map)
        PS.idx[ik] = entry
        PS.idx_ver = PS.idx_ver + 1
        st.entry, st.state = entry, "entry"
    end
    local function finish(r, q, extra)            -- r: TMDB result | false (nothing) ; nil = network error (st set)
        HV.sn = HV.sn - 1
        if r == false then
            PS.idx[ik] = { none = true, tried = st.tried, ale = ale }
            st.state = "none"
        elseif r then
            extra = extra or {}
            extra.ale = ale
            store(r, q, extra)
        end
        if r ~= nil then PS.save_index() end
        HV.kick()
    end
    local function net_error(err)
        HV.sn = HV.sn - 1
        st.state, st.err, st.t = "error", err, mp.get_time()
        HV.kick()
    end
    -- 1. poster_overrides from the conf always win
    local ov = PS.override_for(w.raw, w.title)
    if ov then
        st.tried[#st.tried + 1] = "poster_overrides: " .. ov.kind .. ":" .. ov.id
        PS.api(string.format("/%s/%s?language=en-US", ov.kind, ov.id), function(d, err, code)
            if d then d.media_type = ov.kind; finish(d, "poster_overrides", { s = ov.s })
            elseif code == 404 then st.tried[#st.tried + 1] = "(not on TMDB)"; finish(false)
            else net_error(err) end
        end)
        return
    end
    local anime = (PS.animeish(w.raw or "") or PS.romaji(w.title)) and true or false
    local al_tried = false
    -- 2. anime: AniList + the anime-lists map (exact TMDB id, season, episode offset)
    local function via_anilist(fallback)
        al_tried = true
        PS.anime_lookup(w, st.tried, function(r, err)
            if r then
                local extra = { s = r.s, ms = r.ms, mo = r.mo, me = r.me }
                finish(r.d, r.q, extra)
            else
                if err and tostring(err):find("AniList", 1, true) then ale = true end
                fallback()
            end
        end)
    end
    -- 3. TMDB search ladder: alias / alternative title first, then the folder title, then shorter forms
    local function ladder()
        local qs, seen = {}, {}
        local function addq(q, trust, season)
            if not q or q == "" or seen[q:lower()] then return end
            seen[q:lower()] = true
            qs[#qs + 1] = { q = q, trust = trust, s = season }
        end
        local al = PS.alias_for(w.raw, w.title)
        if al then addq(al[2], true, al[3]) end
        local fp = w.raw and CT.parse_folder(w.raw) or nil
        if fp and fp.alt then addq(fp.alt, true) end
        for i, q in ipairs(PS.queries(w.raw or w.title, w.title, w.year)) do addq(q, i <= 2) end
        -- no season tag and no year: release names of films nearly always carry a year, so lean towards TV
        local kp = w.kindpref
        if (kp or "") == "" and (anime or (w.year or "") == "") then kp = "tv" end
        local i, any = 0, nil
        local function accept(r, q, season, weak)
            -- a weak answer (closest result, shortened query, nothing) gets a second opinion from AniList first
            if weak and o.anime_lookup and not al_tried then
                via_anilist(function() if r then finish(r, q, { s = season }) else finish(false) end end)
            elseif r then finish(r, q, { s = season })
            else finish(false) end
        end
        local function step()
            i = i + 1
            if i > #qs then accept(any, "(closest result)", nil, true) return end
            local item = qs[i]
            st.tried[#st.tried + 1] = item.q
            PS.search(item.q, w.year or "", nil, function(r, err, a)
                if r == nil then net_error(err) return end
                if r then accept(r, item.q, item.s, not item.trust) return end
                any = any or a
                step()
            end, kp, true, { full = (not item.trust) and w.title or nil, anime = anime })
        end
        step()
    end
    if o.anime_lookup and anime then via_anilist(ladder) else ladder() end
end

function HV.download(st)
    local e = st.entry
    local size = HV.img_size("poster", HV.m and (HV.m.gw or HV.m.cw) or 300)
    local jpg = string.format("%s/p%s_%s.jpg", PS.dir(), e.id, size)
    st.jpg, st.base = jpg, "p" .. e.id
    local ji = utils.file_info(jpg)
    if ji and ji.size > 1000 then st.state = "jpg"; return end
    st.state = "downloading"
    HV.dn = HV.dn + 1
    PS.run({ o.curl_path, "-s", "-S", "-m", "30", "--create-dirs", "-o", jpg, o.tmdb_image_base .. size .. e.poster_path },
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

-- ---------- artwork conversion (jpg -> raw BGRA for overlay-add) ----------
-- auto: ffmpeg when it runs (a single fast process per image), else PowerShell + GDI+ on Windows, else ImageMagick.
-- ffmpeg is probed once per session.
function HV.conv_mode()
    local mode = o.poster_converter
    if mode ~= "auto" then return mode end
    if HV.ff_ok ~= nil then
        if HV.ff_ok then return "ffmpeg" end
        return (package.config:sub(1, 1) == "\\") and "powershell" or "magick"
    end
    if not HV.ff_probe then
        HV.ff_probe = true
        PS.run({ o.ffmpeg_path, "-hide_banner", "-version" }, function(res)
            HV.ff_ok = (res and res.status == 0) and true or false
            msg.info("artwork converter: " .. HV.conv_mode())
            HV.convert_pump()
        end)
    end
    return nil       -- still probing
end

-- Size key of one converted image: "300x450" + style (".r6" rounded corners, ".f08050F" faded into that colour).
function HV.skey(w, h, fade)
    local r = fade and 0 or (HV.R or 0)
    return w .. "x" .. h .. (fade and (".f" .. fade) or "") .. (r > 0 and (".r" .. r) or "")
end

-- Coverage (0..1) of the pixels in an r x r corner, 4x4 supersampled: cov[y][x], (0,0) = the outermost pixel.
function HV.corner_cov(r)
    HV.cov_cache = HV.cov_cache or {}
    if HV.cov_cache[r] then return HV.cov_cache[r] end
    local cov = {}
    for y = 0, r - 1 do
        cov[y] = {}
        for x = 0, r - 1 do
            local n = 0
            for j = 0, 3 do
                for i = 0, 3 do
                    local dx, dy = r - (x + (i + 0.5) / 4), r - (y + (j + 0.5) / 4)
                    if dx * dx + dy * dy <= r * r then n = n + 1 end
                end
            end
            cov[y][x] = n / 16
        end
    end
    HV.cov_cache[r] = cov
    return cov
end

-- Cuts rounded corners into a converted (premultiplied) BGRA file in place: only the 4 corner squares are touched,
-- so this is the same for every converter and costs next to nothing.
function HV.round_corners(path, w, h, r)
    if not r or r < 1 or w < 2 * r or h < 2 * r then return true end
    local f = io.open(path, "r+b")
    if not f then return false end
    local cov = HV.corner_cov(r)
    local function patch(off, row, mirrored)
        f:seek("set", off)
        local s = f:read(r * 4)
        if not s or #s < r * 4 then return end
        local b = { s:byte(1, -1) }
        for x = 0, r - 1 do
            local c = row[mirrored and (r - 1 - x) or x]
            if c < 1 then
                for k = 1, 4 do b[x * 4 + k] = math.floor(b[x * 4 + k] * c + 0.5) end
            end
        end
        f:seek("set", off)
        f:write(string.char((table.unpack or unpack)(b)))
    end
    for y = 0, r - 1 do
        for _, py in ipairs({ y, h - 1 - y }) do
            patch(py * w * 4, cov[y], false)
            patch((py * w + w - r) * 4, cov[y], true)
        end
    end
    f:close()
    return true
end

-- ffmpeg filter for the backdrop: fade the left 45 %, the bottom 30 % and the top 12 % into the background colour.
function HV.fade_filter(w, h, hex)
    local R, G, B = tonumber(hex:sub(1, 2), 16) or 0, tonumber(hex:sub(3, 4), 16) or 0, tonumber(hex:sub(5, 6), 16) or 0
    local k = "st(0,clip(X/(W*0.45),0,1));st(0,ld(0)*ld(0)*(3-2*ld(0)));st(1,clip((H-1-Y)/(H*0.30),0,1));"
        .. "st(1,ld(1)*ld(1)*(3-2*ld(1)));st(2,clip(Y/(H*0.12),0,1));st(2,ld(2)*ld(2)*(3-2*ld(2)));ld(0)*ld(1)*ld(2)"
    local function ch(fn, c) return string.format("%d+(%s(X,Y)-%d)*(%s)", c, fn, c, k) end
    return string.format("scale=%d:%d,format=gbrp,geq=r='%s':g='%s':b='%s',format=bgra", w, h, ch("r", R), ch("g", G), ch("b", B))
end

function HV.want_bgra(st, dw, dh, fade)
    local sk = HV.skey(dw, dh, fade)
    if st.bgra[sk] or st.cq[sk] or not st.jpg then return end
    local bgra = string.format("%s/%s_%s.bgra", PS.dir(), st.base or ("p" .. st.entry.id), sk)
    local bi = utils.file_info(bgra)
    if bi and bi.size == dw * dh * 4 then st.bgra[sk] = bgra; return end
    st.cq[sk] = "queued"
    HV.convq[#HV.convq + 1] = { st = st, jpg = st.jpg, bgra = bgra, w = dw, h = dh, sk = sk, fade = fade,
                                r = (not fade) and (HV.R or 0) or 0 }
end

function HV.convert_done(batch)
    for _, it in ipairs(batch) do
        local bi = utils.file_info(it.bgra)
        if bi and bi.size == it.w * it.h * 4 and HV.round_corners(it.bgra, it.w, it.h, it.r) then
            it.st.bgra[it.sk] = it.bgra
            it.st.cq[it.sk] = "done"
        else
            if bi then pcall(os.remove, it.bgra) end
            it.st.cq[it.sk] = "fail"
        end
    end
    HV.converting = false
    PS.st_dirty = true
    HV.kick()
    HV.convert_pump()
end

function HV.convert_pump()
    if HV.converting or #HV.convq == 0 then return end
    local mode = HV.conv_mode()
    if not mode then return end
    local batch = {}
    while #HV.convq > 0 and #batch < 12 do batch[#batch + 1] = table.remove(HV.convq, 1) end
    HV.converting = true
    if mode == "powershell" then
        HV.batch_n = HV.batch_n + 1
        local manifest = string.format("%s/batch_%d.txt", PS.dir(), HV.batch_n % 4)
        local lines = {}
        for _, it in ipairs(batch) do lines[#lines + 1] = string.format("%s|%s|%d|%d|%s", it.jpg, it.bgra, it.w, it.h, it.fade or "") end
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
        return
    end
    -- ffmpeg / magick: one process per image, three at a time
    local next_i, left = 0, #batch
    local function worker()
        next_i = next_i + 1
        local it = batch[next_i]
        if not it then return end
        local function fin() left = left - 1; if left == 0 then HV.convert_done(batch) else worker() end end
        if mode == "ffmpeg" then
            local vf = it.fade and HV.fade_filter(it.w, it.h, it.fade) or string.format("scale=%d:%d:flags=bicubic", it.w, it.h)
            PS.run({ o.ffmpeg_path, "-v", "error", "-y", "-i", it.jpg, "-vf", vf, "-frames:v", "1",
                     "-pix_fmt", "bgra", "-f", "rawvideo", it.bgra }, fin)
        elseif it.fade then
            fin()       -- the faded backdrop needs ffmpeg or PowerShell
        else
            PS.run({ o.magick_path, it.jpg, "-resize", string.format("%dx%d!", it.w, it.h), "-depth", "8", "bgra:" .. it.bgra }, fin)
        end
    end
    for _ = 1, math.min(3, #batch) do worker() end
end

-- Idle prefetch: when everything on screen is done, the cards of the next rows (and the next page of each visible
-- shelf) are looked up, downloaded and converted too, so scrolling finds them ready.
function HV.prefetch_list(m)
    local n = math.max(0, math.floor(tonumber(o.idle_prefetch_rows) or 0))
    if n == 0 or not HV.vis or #HV.vis == 0 then return nil end
    local list = {}
    local function add_row(row, from)
        if not row then return end
        local d = HV.rowdim(row, m)
        for i = from + 1, from + d.per do
            local cd = row.cards[i]
            if not cd then break end
            if row.land then cd.dw, cd.dh = d.cw, d.ch end
            list[#list + 1] = cd
        end
    end
    for _, v in ipairs(HV.vis) do
        local row = HV.rows[v.ri]
        if row.shelf then add_row(row, (row.off or 0) + HV.rowdim(row, m).per) end
    end
    local last = HV.vis[#HV.vis].ri
    for ri = last + 1, last + n do add_row(HV.rows[ri], HV.rows[ri] and HV.rows[ri].off or 0) end
    if HV.vis[1].ri > 1 then local pr = HV.rows[HV.vis[1].ri - 1]; add_row(pr, pr.off or 0) end
    return list
end

function HV.idle()
    return #HV.convq == 0 and not HV.converting and HV.sn == 0 and HV.dn == 0 and TV.sn == 0
end

function HV.pump()
    if not PS.enabled() then return end
    local m = HV.m
    local now = mp.get_time()
    local gw = HV.grow_want
    if gw then
        local st = HV.items[gw.card.key]
        if st and st.jpg then HV.want_bgra(st, gw.w, gw.h) end
    end
    local wanted = HV.wanted
    if HV.idle() then
        local extra = HV.prefetch_list(m)
        if extra and #extra > 0 then
            wanted = {}
            for _, w in ipairs(HV.wanted) do wanted[#wanted + 1] = w end
            for _, w in ipairs(extra) do wanted[#wanted + 1] = w end
        end
    end
    for _, w in ipairs(wanted) do
        local st = HV.items[w.key]
        if not st then
            st = { state = "new", bgra = {}, cq = {} }
            HV.items[w.key] = st
        end
        if st.state == "error" and st.t and now - st.t > 20 then st.state = "new" end
        if w.still then
            TV.pump_still(w, st, m)
        elseif w.kind == "ep" or w.kind == "missing" or w.kind == "season" then
            -- no artwork source for this card (yet): nothing to look up
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
    if HV.q and HV.filter_pending and HV.mode ~= "title" then
        for _, c in ipairs(HV.filter_pending) do
            if HV.sn >= 3 then break end
            local st = HV.items[c.key]
            if not st then st = { state = "new", bgra = {}, cq = {} }; HV.items[c.key] = st end
            if st.state == "new" then HV.lookup(c, st) end
        end
    end
    HV.convert_pump()
end

-- ---------- bitmaps on screen ----------
function HV.clear_anim()
    HV.A.ring_cur, HV.A.ring_dst, HV.A.sc_t0, HV.A.sc_cur = nil, nil, nil, 0
    HV.A.enter_t = U.now_s()
    if HV.anim_on() then HV.anim_kick(0.25) end
end

function HV.clear()
    HV.clear_anim()
    HV.ids = {}
    for id in pairs(HV.shown) do pcall(mp.commandv, "overlay-remove", tostring(id)) end
    HV.shown = {}
end

function HV.place()
    local used = {}
    if not MS.debug then
        local sk = HV.m.sk
        -- Every card keeps its overlay id while it stays on screen (ids used to follow the screen position, so during a
        -- scroll each id was handed a different picture and mpv briefly showed posters in the wrong places).
        HV.ids = HV.ids or {}
        local live = {}
        for i, cd in ipairs(HV.vis_cards) do if i <= 60 then live[cd.uid] = true end end
        local taken = {}
        for uid, id in pairs(HV.ids) do
            if live[uid] then taken[id] = true else HV.ids[uid] = nil end
        end
        local nextfree = 0
        local function alloc()
            while taken[nextfree] do nextfree = nextfree + 1 end
            taken[nextfree] = true
            return nextfree
        end
        for i, cd in ipairs(HV.vis_cards) do
            if i > 60 then break end
            local st = HV.items[cd.card.key]
            local f = st and st.bgra[cd.sk or sk]
            if f then
                local id = HV.ids[cd.uid]
                if not id then id = alloc(); HV.ids[cd.uid] = id end
                local cw_, ch_ = cd.w or HV.m.cw, cd.h or HV.m.ch
                local px, py = math.floor(cd.x + 0.5), math.floor(cd.y + 0.5)        -- overlay-add needs whole pixels
                -- a peeking row is cut at the footer: only the top lines of the bitmap are handed to mpv
                local vh = cd.cut and math.min(ch_, math.floor(cd.cut) - py) or ch_
                if vh > 0 then
                    local sig = f .. "@" .. px .. "," .. py .. "/" .. vh
                    if HV.shown[id] ~= sig then
                        local ok = mp.commandv("overlay-add", tostring(id), tostring(px), tostring(py), f, "0", "bgra",
                            tostring(cw_), tostring(vh), tostring(cw_ * 4))
                        HV.shown[id] = ok and sig or nil
                    end
                    used[id] = true
                end
            end
        end
    end
    -- hero poster (title page)
    local hero = HV.hero
    if hero and not MS.debug and HV.mode == "title" then
        local st = HV.items[hero.key]
        local f = st and st.bgra[HV.skey(hero.dw, hero.dh)]
        if f then
            local hx, hy = math.floor(hero.x + 0.5), math.floor(hero.y + 0.5)
            local sig = f .. "@" .. hx .. "," .. hy
            if HV.shown[61] ~= sig then
                local ok = mp.commandv("overlay-add", "61", tostring(hx), tostring(hy), f, "0", "bgra",
                    tostring(hero.dw), tostring(hero.dh), tostring(hero.dw * 4))
                HV.shown[61] = ok and sig or nil
            end
            used[61] = true
        end
    end
    -- experimental backdrop (title page, beside the text)
    local bd = HV.backdrop
    if bd and not MS.debug and HV.mode == "title" then
        local st = HV.items[bd.key]
        local f = st and st.bgra[bd.sk]
        if f then
            local sig = f .. "@" .. bd.x .. "," .. bd.y
            if HV.shown[62] ~= sig then
                local ok = mp.commandv("overlay-add", "62", tostring(math.floor(bd.x)), tostring(math.floor(bd.y)), f, "0", "bgra",
                    tostring(bd.dw), tostring(bd.dh), tostring(bd.dw * 4))
                HV.shown[62] = ok and sig or nil
            end
            used[62] = true
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
-- Soft shadow under a card (libass blur; drawn first, the card's bitmap covers the middle).
function HV.shadow(x1, y1, x2, y2, b, opacity)
    return string.format("{\\an7\\pos(0,0)\\bord0\\shad0\\blur%d\\1c&H000000&\\1a%s\\3a&HFF&\\p1}%s{\\p0}",
        b, U.ass_alpha(opacity), D.rounded_path(x1, y1, x2, y2, (HV.R or 0) + b / 2))
end

-- Couch mode: on with couch_mode=yes, or (auto) after a gamepad / remote key until the mouse moves again.
function HV.couch_on()
    local c = tostring(o.couch_mode or "auto"):lower()
    if c == "yes" or c == "true" then return true end
    if c == "no" or c == "false" then return false end
    return HV.pad_used == true
end
function HV.ring_pad(m) return HV.couch and math.max(6, math.floor(6 * m.S + 0.5)) or 4 end
-- Focus ring around a card; in couch mode thicker and with a glow, readable from across the room.
function HV.ring(x1, y1, x2, y2, sel, m)
    local r = (HV.R or 0) + HV.ring_pad(m)
    local col = sel and THEME.accent or THEME.text_dim
    if HV.couch and sel then
        local bw = math.max(4, math.floor(3.5 * m.S + 0.5))
        local glow = string.format("{\\an7\\pos(0,0)\\bord%d\\shad0\\blur%d\\1a&HFF&\\3c%s\\3a%s\\p1}%s{\\p0}",
            bw * 2, bw * 2, U.ass_color(col), U.ass_alpha(45), D.rounded_path(x1, y1, x2, y2, r))
        return glow .. "\n" .. D.ev_rect(x1, y1, x2, y2, "FFFFFF", 0, "FFFFFF", 100, bw, r)
    end
    return D.ev_rect(x1, y1, x2, y2, "FFFFFF", 0, col, 100, sel and 3 or 2, r)
end

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


function HV.sec_of(row, m)
    if not row.title then return 0 end
    return m.sec_h + (row.note and math.floor(m.lfs * 1.5) or 0)
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
            local y = HV.rows_y(m)
            for ri = HV.top, #HV.rows do
                local need = HV.rowdim(HV.rows[ri], m).block_h + HV.sec_of(HV.rows[ri], m)
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
        tostring(o.merge_seasons), HV.sort_mode(), PS.eps_ver, MS.cache_version, TV.card and TV.card.key or "", m.cw,
        (o.experimental_merge_by_tmdb or HV.q) and PS.idx_ver or 0, PS.RD.ver, tostring(TV.season), HV.q or "" }, "|")
    if sig ~= HV.sig then
        HV.sig = sig; HV.rows = HV.build(m); HV.clamp()
        if TV.relayout then          -- the title page switched between season folders and episodes: new card shape
            TV.relayout = nil
            HV.sig = nil
            return HV.render()
        end
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
    -- breadcrumbs: WebDAV Library › Title › Season N   (each part is clickable; the mouse back button goes up one)
    HV.links = {}
    do
        local crumbs = { { t = "WebDAV Library", act = HV.go_home } }
        if HV.q and m.title then crumbs[#crumbs + 1] = { t = "Search “" .. HV.q .. "”", act = TV.back } end
        if m.title and TV.card then
            crumbs[#crumbs + 1] = { t = TV.card.shown or TV.card.title, act = (TV.season and TV.multi) and TV.leave_season or nil }
            if TV.season and TV.multi then crumbs[#crumbs + 1] = { t = (TV.season > 0) and ("Season " .. TV.season) or "Other files" } end
        end
        local cfs = lfs + 8
        local x = m.mx
        local limit = (HV.q and not m.title) and (w * 0.26 - 12) or (w * 0.62)
        for i, cr in ipairs(crumbs) do
            local last = (i == #crumbs)
            local txt = U.fit_text(cr.t, math.max(60, limit - x), cfs)
            local tw = U.utf8_len(txt) * cfs * 0.5
            local hot = HV.link_hover and HV.link_hover == i and cr.act
            local col = last and THEME.accent or (hot and "FFFFFF" or THEME.text_muted)
            add(D.ev_text(x, m.top_h / 2, 4, string.format("\\b1\\fs%d\\c%s", cfs, U.ass_color(col)), U.ass_escape(txt)))
            if cr.act then HV.links[#HV.links + 1] = { x1 = x - 4, x2 = x + tw + 4, y1 = 0, y2 = m.top_h, act = cr.act, crumb = i } end
            x = x + tw + 10
            if not last then
                add(D.ev_text(x, m.top_h / 2, 4, string.format("\\fs%d\\c%s", cfs, U.ass_color(THEME.text_dim)), "›"))
                x = x + cfs * 0.9
            end
            if x > limit then break end
        end
    end
    local any_fail = listing_error[root_href]
    local right = (any_fail and "error") or (is_loading and "loading…") or "connected"
    add(D.ev_text(w - 22, m.top_h / 2, 5, string.format("\\b1\\fs%d\\c%s", lfs + 10, U.ass_color(THEME.text_muted)), "×"))
    add(D.ev_text(w - 50, m.top_h / 2, 6, string.format("\\fs%d\\c%s", lfs, U.ass_color(any_fail and THEME.bad or THEME.text_muted)),
        U.ass_escape(right)))
    add(D.ev_text(w - 50 - U.utf8_len(right) * lfs * 0.62 - 18, m.top_h / 2, 6,
        string.format("\\fs%d\\c%s", lfs + 4, U.ass_color(any_fail and THEME.bad or THEME.good)), "●"))
    if HV.q and not m.title then
        local bx1, bx2 = math.floor(w * 0.26), math.floor(w * 0.70)
        HV.links[#HV.links + 1] = { x1 = bx1, x2 = bx2, y1 = 0, y2 = m.top_h,
            act = function(mx) if not HV.typing then HV.start_search() end; HV.cur_click(mx) end }
        add(D.ev_rect(bx1, m.top_h * 0.16, bx2, m.top_h * 0.84, THEME.bg_panel, 100, THEME.accent, HV.typing and 100 or 35, 1, 8))
        -- the text with a cursor where you are editing; a long query scrolls so the cursor stays in view
        local fs2 = lfs + 2
        local cw = fs2 * 0.52
        local label = "Search:  "
        local q, c = HV.q or "", HV.cur_get()
        local maxc = math.max(4, math.floor((bx2 - bx1 - 40) / cw) - U.utf8_len(label))
        local first = 0                                     -- bytes hidden on the left
        while U.utf8_len(q:sub(first + 1, c)) > maxc - 1 do first = HV.cur_next(q, first) end
        local shown = q:sub(first + 1)
        local before, after = q:sub(first + 1, c), q:sub(c + 1)
        if U.utf8_len(shown) > maxc then after = U.utf8_sub(after, math.max(0, maxc - U.utf8_len(before))) end
        HV.box = { x0 = bx1 + 14 + U.utf8_len(label) * cw - U.utf8_len(q:sub(1, first)) * cw, cw = cw }
        local tcol = U.ass_color(THEME.text_primary)
        local caret = HV.typing and string.format("{\\c%s\\fscx35}▏{\\fscx100\\c%s}", U.ass_color(THEME.accent), tcol) or ""
        add(D.ev_text(bx1 + 14, m.top_h / 2, 4, string.format("\\fs%d\\c%s", fs2, tcol),
            U.ass_escape(label .. (first > 0 and "…" or "") .. before) .. caret .. U.ass_escape(after)))
    elseif m.title and TV.loading_links then
        local txt
        if PS.rd_on() and (TV.rd_want or 0) > 0 then
            txt = string.format("Loading links from Real-Debrid  ·  %d / %d", TV.rd_have or 0, TV.rd_want)
            local frac = math.min(1, (TV.rd_have or 0) / math.max(1, TV.rd_want))
            add(D.ev_rect(0, m.top_h - 3, w, m.top_h, THEME.track, 100, nil, 0, 0))
            add(D.ev_rect(0, m.top_h - 3, w * frac, m.top_h, THEME.accent, 100, nil, 0, 0))
        else
            txt = "Real-Debrid is still adding files to this title…  (" .. tostring(TV.count or 0) .. " so far)"
        end
        add(D.ev_text(w / 2, m.top_h / 2, 5, string.format("\\fs%d\\c%s", lfs, U.ass_color(THEME.warn)), U.ass_escape(U.fit_text(txt, w * 0.4, lfs))))
    elseif HV.status_visible() then
        add(D.ev_text(w / 2, m.top_h / 2, 5, string.format("\\fs%d\\c%s", lfs, U.ass_color(status_line:match("^Failed") and THEME.bad or THEME.text_muted)),
            U.ass_escape(U.fit_text(status_line, w * 0.4, lfs))))
    end

    -- filter chips under the search box
    if HV.q and not m.title and HV.chips then
        local x, cy = m.mx, m.top_h + 6 + m.chip_h / 2
        local cfs = lfs - 2
        for _, ch in ipairs(HV.chips) do
            local tw = U.utf8_len(ch.label) * cfs * 0.52 + cfs * 1.4
            if x + tw > w - m.mx then break end
            local on = (" " .. HV.q .. " "):find(" " .. ch.tok .. " ", 1, true) ~= nil
            add(D.ev_rect(x, cy - cfs * 0.95, x + tw, cy + cfs * 0.95, on and THEME.accent or THEME.bg_panel, on and 85 or 100,
                on and THEME.accent or THEME.text_dim, on and 100 or 45, 1, cfs))
            add(D.ev_text(x + tw / 2, cy, 5, string.format("\\fs%d\\c%s%s", cfs, U.ass_color(on and "FFFFFF" or THEME.text_muted), on and "\\b1" or ""), U.ass_escape(ch.label)))
            local tok = ch.tok
            HV.links[#HV.links + 1] = { x1 = x, x2 = x + tw, y1 = cy - cfs, y2 = cy + cfs, act = function() HV.toggle_token(tok) end }
            x = x + tw + cfs * 0.6
        end
    end

    HV.hit, HV.vis_cards, HV.wanted, HV.grow_want = {}, {}, {}, nil
    if m.title and TV.card and HV.top <= 1 then
        local hw, hh = TV.hero_size(m)
        HV.wanted[1] = { key = TV.card.key, title = TV.card.title, year = TV.card.year, dw = hw, dh = hh }
    end
    local vis = {}
    local anim = HV.anim_on()
    local A = HV.A
    local now = U.now_s()
    -- No eased scrolling: mpv moves bitmaps one overlay-add at a time and draws frames in between, so every frame of a
    -- glide showed half the posters at the old row and half at the new one. One jump per key press stays clean.
    local scroll = 0
    A.top, A.mode, A.card = HV.top, HV.mode, TV.card
    local y = HV.rows_y(m) + scroll
    local bottom = h - m.foot_h
    for ri = HV.top, #HV.rows do
        local row = HV.rows[ri]
        local need = HV.rowdim(row, m).block_h + HV.sec_of(row, m)
        if y + need > bottom and #vis > 0 then
            -- the next row peeks in at the bottom (its posters cut off at the footer), so scrolling never jumps
            -- into a blank area and you can see what comes next
            local cy = y + HV.sec_of(row, m)
            if cy + math.max(24, HV.rowdim(row, m).ch * 0.08) < bottom and y >= m.top_h - 2 then
                vis[#vis + 1] = { ri = ri, ty = y, y = cy, cut = bottom }
            end
            break
        end
        if y >= m.top_h - 2 then vis[#vis + 1] = { ri = ri, ty = y, y = y + HV.sec_of(row, m) } end
        y = y + need
    end
    HV.vis = vis

    HV.hero, HV.backdrop = nil, nil
    if m.title and TV.card and HV.top <= 1 then TV.draw_hero(add, m) end

    if #HV.rows == 0 then
        local msg_ = any_fail and ("⚠  " .. tostring(any_fail) .. "     (press R to retry)") or (is_loading and "Loading library…" or "No folders found")
        if HV.q then msg_ = (HV.q == "") and "Type to search the library" or ("No titles match \"" .. HV.q .. "\"" .. ((MS.idx_running or not index_meta.last_full) and "   (the library index is still building)" or "")) end
        add(D.ev_text(w / 2, h / 2, 5, string.format("\\fs%d\\c%s", lfs + 6, U.ass_color(any_fail and THEME.bad or THEME.text_muted)), U.ass_escape(msg_)))
    end

    for _, v in ipairs(vis) do
        local row = HV.rows[v.ri]
        local d = HV.rowdim(row, m)
        if row.title then
            local hdr_hot = row.sort_hdr and HV.hdr_hover
            add(D.ev_text(m.mx, v.ty + m.sec_h * 0.55, 4, string.format("\\b1\\fs%d\\c%s", lfs + 6, U.ass_color(hdr_hot and THEME.accent or THEME.text_primary)), U.ass_escape(row.title)))
            if row.sort_hdr then
                HV.links[#HV.links + 1] = { x1 = m.mx, x2 = m.mx + U.utf8_len(row.title) * (lfs + 6) * 0.58, y1 = v.ty, y2 = v.ty + m.sec_h,
                    act = function() HV.toggle_sort() end, hdr = true }
            end
            if row.note then
                add(D.ev_text(m.mx, v.ty + m.sec_h * 0.55 + lfs * 1.45, 4, string.format("\\fs%d\\c%s", lfs, U.ass_color(THEME.warn)),
                    U.ass_escape(U.fit_text(row.note, w - 2 * m.mx, lfs))))
            end
        end
        local off = row.off or 0
        for i = 1, d.per do
            local ci = off + i
            local card = row.cards[ci]
            if not card then break end
            local x = m.mx + (i - 1) * (d.cw + m.gap)
            local py = v.y
            local sel = (v.ri == HV.r and ci == HV.c)
            local hov = HV.hover and HV.hover.r == v.ri and HV.hover.c == ci
            local st = HV.items[card.key]
            local ready = st and st.bgra[d.sk] and not MS.debug
            if row.land then card.dw, card.dh = d.cw, d.ch end
            local vc = { card = card, x = x, y = py, w = d.cw, h = d.ch, sk = d.sk, cut = v.cut,
                         uid = card.key .. "|" .. v.ri .. "|" .. ci }
            HV.vis_cards[#HV.vis_cards + 1] = vc
            HV.wanted[#HV.wanted + 1] = card
            HV.hit[#HV.hit + 1] = { x1 = x, y1 = py, x2 = x + d.cw, y2 = math.min(v.cut or 1e9, py + d.ch + m.bar_h + m.label_h), r = v.ri, c = ci }
            -- the selected card grows a little (its own, bigger bitmap - only for this one card)
            local gx1, gy1, gx2, gy2 = x, py, x + d.cw, py + d.ch
            if sel and d.gw and ready and not v.cut then
                HV.grow_want = { card = card, w = d.gw, h = d.gh }
                if st.bgra[d.gsk] then
                    local ex, ey = (d.gw - d.cw) / 2, (d.gh - d.ch) / 2
                    vc.x, vc.y, vc.w, vc.h, vc.sk = x - ex, py - ey, d.gw, d.gh, d.gsk
                    gx1, gy1, gx2, gy2 = x - ex, py - ey, x + d.cw + ex, py + d.ch + ey
                end
            end
            if o.card_shadows and not MS.debug then
                local b = math.max(4, math.floor(7 * m.S + 0.5))
                add(HV.shadow(gx1 + 2, gy1 + b * 0.6, gx2 - 2, gy2 + b * 0.9, b, sel and 62 or 48))
            end

            if not ready then
                add(D.ev_rect(x, py, x + d.cw, py + d.ch, THEME.bg_panel, 100, nil, 0, 0, HV.R))
                local loading_art = st and (st.state == "new" or st.state == "searching" or st.state == "entry" or st.state == "downloading"
                    or st.state == "jpg") and not (st.cq and st.cq[d.sk] == "fail")
                if anim and PS.enabled() and card.kind ~= "missing" and loading_art and not MS.debug then
                    local ph = (now * 0.9) % 1.6 - 0.3
                    local bx1 = math.max(x, x + ph * d.cw)
                    local bx2 = math.min(x + d.cw, x + (ph + 0.25) * d.cw)
                    if bx2 > bx1 then add(D.ev_rect(bx1, py, bx2, py + d.ch, "FFFFFF", 5, nil, 0, 0, 0)) end
                    A.shimmer_seen = true
                end
                local ptxt = card.ph or card.shown or card.title
                local t1, t2 = HV.wrap2(ptxt, d.cw - 16, lfs + 3)
                add(D.ev_text(x + d.cw / 2, py + d.ch / 2 - (t2 ~= "" and lfs or 0), 5, string.format("\\b1\\fs%d\\c%s", lfs + 3, U.ass_color(THEME.text_muted)), U.ass_escape(t1)))
                if t2 ~= "" then
                    add(D.ev_text(x + d.cw / 2, py + d.ch / 2 + lfs * 0.9, 5, string.format("\\b1\\fs%d\\c%s", lfs + 3, U.ass_color(THEME.text_muted)), U.ass_escape(t2)))
                end
                if PS.enabled() and st and (st.state == "new" or st.state == "searching" or st.state == "entry" or st.state == "downloading" or st.state == "jpg") and not (st.cq and st.cq[d.sk] == "fail") then
                    add(D.ev_text(x + d.cw / 2, py + d.ch - lfs * 1.6, 5, string.format("\\fs%d\\c%s", lfs, U.ass_color(THEME.text_dim)), "…"))
                end
            end
            -- ring (outside the picture so the bitmap does not cover it; thicker in couch mode)
            local rp = HV.ring_pad(m)
            if sel and anim then
                A.ring_to = { gx1 - rp, gy1 - rp - scroll, gx2 + rp, gy2 + rp - scroll }
            elseif sel or hov then
                add(HV.ring(gx1 - rp, gy1 - rp, gx2 + rp, gy2 + rp, sel, m))
            end
            local below = gy2 - (py + d.ch)          -- the grown card reaches this far below the normal one
            -- progress bar (Continue Watching)
            if card.frac then
                local by = py + d.ch + 3 + below
                add(D.ev_rect(x, by, x + d.cw, by + 4, THEME.track, 100, nil, 0, 0, 2))
                add(D.ev_rect(x, by, x + math.max(4, d.cw * card.frac), by + 4, THEME.accent, 100, nil, 0, 0, 2))
            end
            -- label: clean title (up to 2 lines) + muted detail line
            local ly = py + d.ch + m.bar_h + 4 + below
            local t1, t2 = HV.wrap2(card.shown or card.title, d.cw, lfs)
            local tcol = (sel or hov) and "FFFFFF" or "F2EEFA"      -- bright titles; the ring shows the selection
            add(D.ev_text(x, ly, 7, string.format("\\b1\\fs%d\\c%s", lfs, U.ass_color(tcol)), U.ass_escape(t1)))
            if t2 ~= "" then
                add(D.ev_text(x, ly + m.line_h, 7, string.format("\\b1\\fs%d\\c%s", lfs, U.ass_color(tcol)), U.ass_escape(t2)))
            end
            if card.parts and #card.parts > 0 then
                add(D.ev_text(x, ly + m.line_h * ((t2 ~= "") and 2 or 1) + 2, 7, string.format("\\fs%d\\c%s", lfs - 2, U.ass_color(THEME.text_muted)),
                    HV.detail_ass(card.parts, d.cw, lfs - 2)))
            end
        end
        -- shelf arrows
        if row.shelf then
            local mid = v.y + d.ch / 2
            if off > 0 then add(D.ev_text(m.mx / 2, mid, 5, string.format("\\b1\\fs%d\\c%s", lfs + 14, U.ass_color(THEME.text_muted)), "‹")) end
            if off + d.per < #row.cards then add(D.ev_text(w - m.mx / 2, mid, 5, string.format("\\b1\\fs%d\\c%s", lfs + 14, U.ass_color(THEME.text_muted)), "›")) end
        end
    end
    -- extend the wanted list with the next row so it is ready before you scroll to it
    do
        local lastv = vis[#vis]
        local nrow = lastv and HV.rows[lastv.ri + 1]
        if nrow then
            for i = 1, HV.rowdim(nrow, m).per do
                local cd = nrow.cards[(nrow.off or 0) + i]
                if cd then HV.wanted[#HV.wanted + 1] = cd end
            end
        end
    end

    if anim and A.ring_to then
        local to = A.ring_to
        local dst = A.ring_dst
        if not A.ring_cur then A.ring_cur, A.ring_from, A.ring_t0 = to, to, now end
        if not dst or dst[1] ~= to[1] or dst[2] ~= to[2] or dst[3] ~= to[3] then
            A.ring_from, A.ring_dst, A.ring_t0 = A.ring_cur, to, now
            HV.anim_kick(0.16)
        end
        local k = HV.ease((now - A.ring_t0) / 0.13)
        local cur = {}
        for i = 1, 4 do cur[i] = A.ring_from[i] + (to[i] - A.ring_from[i]) * k end
        A.ring_cur = cur
        add(HV.ring(cur[1], cur[2] + scroll, cur[3], cur[4] + scroll, true, m))
    end
    A.ring_to = nil
    A.shimmer, A.shimmer_seen = A.shimmer_seen, nil
    if anim and A.shimmer then HV.anim_kick(0.05) end
    if anim and A.enter_t and now - A.enter_t < 0.22 then
        local k = HV.ease((now - A.enter_t) / 0.22)
        add(D.ev_rect(0, m.top_h, w, h - m.foot_h, THEME.bg_dim, math.floor((1 - k) * 100), nil, 0, 0))
    end

    -- footer
    add(D.ev_rect(0, h - m.foot_h, w, h, THEME.bg_header, 100, nil, 0, 0))
    add(D.ev_rect(0, h - m.foot_h, w, h - m.foot_h + 2, U.pick(o.color_border_grad_top, "909090"), 30, nil, 0, 0))
    local ckey = tostring(o.cache_clear_key or ""):match("[^%s,]+") or ""
    local hint
    if HV.q and not m.title then
        hint = HV.typing and "Type to search (typos are fine)   genre:anime  year:2010-2020  type:tv  rating:8  unwatched   ←→ Home End Edit   ↓ Results   Enter Open   Esc Clear"
            or "←↑↓→ Move   Enter Open   F or click the box: edit search   Esc / Mouse-back Clear search"
    elseif m.title and TV.grid() then
        hint = "←↑↓→ Move   Enter Open season   R Refresh   V List   T Re-fetch art   Ctrl+D Report   " .. ckey:upper() .. " Clear cache   Esc / Mouse-back Back"
    elseif m.title then
        hint = "←↑↓→ Move   Enter Play   A Queue   M Watched   S Sort: " .. (HV.sort_mode() == "recent" and "Recent" or "Order") ..
            "   R Refresh   V List   T Re-fetch art   Ctrl+D Report   " .. ckey:upper() .. " Clear cache   Esc / Mouse-back Back"
    else
        hint = "←↑↓→ Move   Enter Open / Play   S Sort: " .. (HV.sort_mode() == "recent" and "Recent" or "Name") ..
            "   R Refresh   O List   F Search all   T Re-fetch art   " .. ckey:upper() .. " Clear cache   Esc Close"
    end
    if HV.couch then
        hint = "(A) " .. ((m.title and not TV.grid()) and "Play" or "Open") .. "    (B) Back    (X) Watched    (Y) Queue    LB / RB Page    Start: Sort    View: Close"
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
    local abs = (e ~= nil and s == nil and hint == nil)      -- a running number with no season anywhere
    if e and not s then s = hint or 1 end
    return s or hint, e, abs
end

function TV.clean_name(name)
    local cp = CT.parse(name)
    if cp and cp.title and cp.title ~= "" then return cp.title .. (cp.year and (" (" .. cp.year .. ")") or "") end
    return (CT.fix_chars(name):gsub("%.[%w]+$", ""):gsub("[%._]+", " "))
end

-- Listing of one folder of the open title. A failed listing is retried after 8, 16, 32... seconds (it used to wait
-- 45 s and fail silently, so episodes simply looked missing).
TV.fail = {}
function TV.ensure(href)
    local now = mp.get_time()
    local f = TV.fail[href]
    local wait = f and math.min(120, 8 * 2 ^ math.min(4, f.n - 1)) or 45
    if TV.req[href] and now - TV.req[href] < wait then return end
    TV.req[href] = now
    fetch_listing(href, { silent = true, urgent = true })
end
MS.on_listing = function(href, err)
    if not TV.card then return end
    if err and err ~= "superseded" then
        local f = TV.fail[href] or { n = 0 }
        f.n, f.err = f.n + 1, err
        TV.fail[href] = f
        TV.req[href] = mp.get_time()
        HV.sig = nil
        mp.add_timeout(0.05, HV.kick)          -- show the failure (after this callback has finished)
    else
        TV.fail[href] = nil
    end
end

function TV.show_entry()
    local card = TV.card
    if not card or not PS.enabled() then return nil end
    PS.load_index()
    local e = PS.idx[card.key]
    if type(e) == "table" and not e.none and e.id then return e end
    return nil
end

-- TMDB lookup result of one folder (with the anime map's season / offset, if any).
function TV.folder_entry(name)
    if not PS.enabled() then return nil end
    PS.load_index()
    local e = PS.idx[HV.ident(name).key]
    return (type(e) == "table" and not e.none) and e or nil
end

-- Season a whole folder holds when its name does not say (poster_overrides "...:17" or a built-in alias).
function TV.folder_season(name)
    local s = TV.season_of(name)
    if s then return s end
    if not PS.enabled() then return nil end
    PS.load_index()
    local e = PS.idx[HV.ident(name).key]
    return type(e) == "table" and tonumber(e.s) or nil
end

-- All media files of the show: its folders and up to three levels of sub-folders ("Season 05/Disc 1/...").
function TV.collect()
    local card = TV.card
    local list, loading = {}, 0
    local names = {}
    TV.failed, TV.waiting, TV.dirs, TV.dirs_of = {}, {}, {}, {}
    local function visit(folder, depth, hint, top)
        top = top or folder
        TV.dirs[#TV.dirs + 1] = folder.href
        TV.dirs_of[top.href] = TV.dirs_of[top.href] or {}
        table.insert(TV.dirs_of[top.href], folder.href)
        local c = find_cached_dir(folder.href)
        if not c or type(c.entries) ~= "table" then
            TV.ensure(folder.href); loading = loading + 1
            if TV.fail[folder.href] then TV.failed[#TV.failed + 1] = { name = folder.name, href = folder.href, err = TV.fail[folder.href].err }
            else TV.waiting[#TV.waiting + 1] = folder.name end
            return
        end
        if not cache_is_fresh(c) then TV.ensure(folder.href) end     -- show what we have, refresh quietly
        for _, e in ipairs(c.entries) do
            if e.is_dir then
                if depth < 3 then visit(e, depth + 1, TV.season_of(e.name) or hint, top) end
            elseif U.is_media(e.name) then
                local s, n, abs = TV.se_of(e.name, hint)
                -- "Part 2" folders numbered from 1 again: the map's episode offset makes E01 the season's E14
                local fe = TV.cur_fe
                if fe and tonumber(fe.mo) and n and not abs and (not tonumber(fe.me) or n <= tonumber(fe.me)) then n = n + tonumber(fe.mo) end
                list[#list + 1] = { entry = e, s = s, e = n, abs = abs, folder = folder, top = top }
                names[e.name:lower()] = true
            end
        end
    end
    TV.explicit = {}
    for _, f in ipairs(card.folders or {}) do
        local fe = TV.folder_entry(f.name)
        local k = TV.season_of(f.name) or (fe and tonumber(fe.s))
        if fe and fe.ms and k then TV.explicit[k] = tonumber(fe.ms) end
        TV.cur_fe = fe
        visit(f, 0, TV.folder_season(f.name))
    end
    TV.cur_fe = nil
    TV.names = names
    return list, loading
end

local function tv_natural(a, b)
    local as, bs = a.s or 0, b.s or 0
    if as ~= bs then return as < bs end
    if a.e and b.e and a.e ~= b.e then return a.e < b.e end
    if (a.e ~= nil) ~= (b.e ~= nil) then return a.e ~= nil end
    return U.natural_less(a.entry.name, b.entry.name)
end

-- Spreads running numbers (absolute-numbered anime, "Episode 137") over TMDB's seasons.
function TV.spread(list, sc)
    if type(sc) ~= "table" then return end
    local keys = {}
    for k in pairs(sc) do local n = tonumber(k); if n and n > 0 then keys[#keys + 1] = n end end
    table.sort(keys)
    if #keys < 2 then return end
    for _, ep in ipairs(list) do
        if ep.abs and ep.e then
            local n = ep.e
            for _, k in ipairs(keys) do
                local c = tonumber(sc[tostring(k)]) or 0
                if n <= c then ep.s, ep.e, ep.absn = k, n, ep.e; break end
                n = n - c
            end
            if not ep.absn then ep.unmapped = true end      -- past TMDB's last episode (movies, specials...)
        end
    end
end

-- "2, 11–12, 15–16"
function TV.ranges(nums)
    table.sort(nums)
    local out, i = {}, 1
    while i <= #nums do
        local j = i
        while j < #nums and nums[j + 1] == nums[j] + 1 do j = j + 1 end
        out[#out + 1] = (j > i) and (nums[i] .. "–" .. nums[j]) or tostring(nums[i])
        i = j + 1
    end
    return table.concat(out, ", ")
end

-- Files Real-Debrid has for this title that WebDAV does not list, each with Real-Debrid's reason.
-- returns list|nil (no token), state ("ready" | "loading" | "checking" | "error" | "off")
function TV.rd_missing(show)
    if not PS.rd_on() then return nil, "off" end
    local out, state = {}, "ready"
    TV.rd_want, TV.rd_have, TV.rd_short = 0, 0, {}
    for _, f in ipairs(TV.card.folders or {}) do
        local rec = PS.rd_folder(f.name)
        local want, miss = 0, 0
        if rec.state == "loading" then state = "loading"
        elseif rec.state == "error" then state = "error"
        elseif rec.state == "ready" then
            local d = rec.data
            local bad = d.status and d.status ~= "downloaded" and (PS.RD_STATUS[d.status] or tostring(d.status))
            local links, li = type(d.links) == "table" and d.links or {}, 0
            for _, fl in ipairs(type(d.files) == "table" and d.files or {}) do
                if tonumber(fl.selected) == 1 then
                    li = li + 1
                    local path = tostring(fl.path or "")
                    local base = path:match("([^/]+)$") or path
                    if U.is_media(base) then want = want + 1 end
                    if U.is_media(base) and not (TV.names or {})[base:lower()] then
                        miss = miss + 1
                        local reason = bad
                        if not reason then
                            local link = links[li]
                            if link then
                                local c = PS.rd_check(link)
                                if c then reason = c.r else reason = "Checking Real-Debrid…"; if state == "ready" then state = "checking" end end
                            else
                                reason = "No link on Real-Debrid"
                            end
                        end
                        local hint = TV.folder_season(f.name)
                        for seg in path:gmatch("[^/]+") do if seg ~= base then hint = TV.season_of(seg) or hint end end
                        local s, e, abs = TV.se_of(base, hint)
                        out[#out + 1] = { s = s or 0, e = e, abs = abs, name = base, reason = reason }
                    end
                end
            end
            if not bad then
                TV.rd_want, TV.rd_have = TV.rd_want + want, TV.rd_have + (want - miss)
                if miss > 0 then TV.rd_short[f.href] = true end
            end
        end
    end
    return out, state
end

-- Is Real-Debrid still adding files to this title? With a token: WebDAV lists fewer files than Real-Debrid says the
-- torrents hold AND that number still moved within the last 20 s. Without one: one of its folders is still growing.
function TV.links_loading()
    local now = os.time()
    for _, h in ipairs(TV.dirs or {}) do if MS.grow[h] and not MS.grow[h].forced then TV.grow_t = now; break end end
    if PS.rd_on() and (TV.rd_want or 0) > 0 then
        local p = TV.rd_prog
        if not p or p.card ~= TV.card or p.have ~= TV.rd_have then TV.rd_prog = { card = TV.card, have = TV.rd_have, t = now } end
        if TV.rd_have < TV.rd_want and now - TV.rd_prog.t < 20 then return true end
    end
    return TV.grow_t ~= nil and now - TV.grow_t < 8
end

-- Missing episodes per season: Real-Debrid's list when a token is set, plus gaps in the numbering.
function TV.find_missing(seasons, order, show)
    local out = {}
    TV.rd_state = "off"
    if not o.show_missing_episodes then return out end
    local rdm, rst = TV.rd_missing(show)
    TV.rd_state = rst
    TV.loading_links = TV.links_loading()
    if TV.loading_links then return out end
    if rdm then
        TV.spread(rdm, show and show.sc)
        for _, x in ipairs(rdm) do
            local k = x.s or 0
            local have = (k == 0 or not x.e)                 -- extras / unnumbered files: no place in a season
            for _, ep in ipairs(seasons[k] or {}) do if x.e and ep.e == x.e then have = true break end end
            if not have then
                out[k] = out[k] or {}
                table.insert(out[k], x)
            end
        end
    end
    -- gaps are looked for inside each folder's own range (a "1-13" pack next to a "27-40" pack is not a gap)
    for _, k in ipairs(order) do
        if k > 0 then
            local have, ranges, rorder = {}, {}, {}
            for _, ep in ipairs(seasons[k]) do
                if ep.e then have[ep.e] = true end
                if ep.e and not ep.unmapped then
                    local fk = (ep.top or ep.folder or {}).href or "?"
                    local r = ranges[fk]
                    if not r then r = { lo = ep.e, hi = ep.e }; ranges[fk] = r; rorder[#rorder + 1] = fk end
                    r.lo, r.hi = math.min(r.lo, ep.e), math.max(r.hi, ep.e)
                end
            end
            out[k] = out[k] or {}
            local known = {}
            for _, x in ipairs(out[k]) do if x.e then known[x.e] = true end end
            for _, fk in ipairs(rorder) do
                local r = ranges[fk]
                if r.hi - r.lo < 500 then
                    for n = (r.lo <= 3) and 1 or r.lo, r.hi do
                        if not have[n] and not known[n] then known[n] = true; table.insert(out[k], { s = k, e = n, gap = true }) end
                    end
                end
            end
        end
    end
    for k, v in pairs(out) do
        if #v == 0 then out[k] = nil
        else table.sort(v, function(a, b) return (a.e or 99999) < (b.e or 99999) end) end
    end
    return out
end

-- Season folders view: the title page of a show with several seasons first lists the seasons.
function TV.grid()
    return HV.mode == "title" and TV.multi and not TV.season
end
function TV.enter_season(k)
    TV.grid_pos = { r = HV.r, c = HV.c, top = HV.top, want_vc = HV.want_vc }
    TV.season = k
    HV.r, HV.c, HV.top, HV.want_vc, HV.hover = 1, 1, 1, 1, nil
    HV.sig, HV.last_data = nil, nil
    HV.clear()
    log_view("title-season")
    render()
end
function TV.leave_season()
    TV.season = nil
    local s = TV.grid_pos or {}
    HV.r, HV.c, HV.top, HV.want_vc, HV.hover = s.r or 1, s.c or 1, s.top or 1, s.want_vc or 1, nil
    HV.sig, HV.last_data = nil, nil
    HV.clear()
    log_view("title-page")
    render()
end

MS.inview = function()
    if MS.view == "home" and HV.mode == "title" and TV.card and TV.dirs then
        local list = {}
        for _, h in ipairs(TV.dirs) do list[#list + 1] = h end
        HV.sig = nil                       -- re-check the title (progress, missing episodes) every poll
        if TV.loading_links and TV.rd_short then
            for fh in pairs(TV.rd_short) do
                for _, h in ipairs(TV.dirs_of and TV.dirs_of[fh] or {}) do MS.grow[h] = MS.grow[h] or { n = 0, stable = 0, t = os.time(), forced = true } end
            end
        end
        return list
    end
    return { current_path }
end

function TV.reason_text(x)
    if x.reason then return x.reason end
    if TV.rd_state == "off" then return "Missing · set rd_api_token to see why" end
    if TV.rd_state == "loading" or TV.rd_state == "checking" then return "Checking Real-Debrid…" end
    if TV.rd_state == "error" then return "Missing · " .. tostring(PS.RD.err or "Real-Debrid unreachable") end
    return "Not in this torrent"
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
    local show = TV.show_entry()
    TV.spread(eps, show and show.sc)
    table.sort(eps, tv_natural)
    TV.ordered = eps
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

    -- Release season numbers that are not TMDB's (Bleach: releases count 17 seasons, TMDB has 2 - season 2 is the
    -- Thousand-Year Blood War). When the files go past TMDB's last season, TMDB data is looked up by running episode
    -- number over the local seasons; a lone far season (only S17 here) maps onto TMDB's last season.
    local plan, keysT, maxT, offsR = nil, {}, 0, {}
    local scT = show and type(show.sc) == "table" and show.sc or nil
    if scT then
        for k in pairs(scT) do local n = tonumber(k); if n and n > 0 then keysT[#keysT + 1] = n; maxT = math.max(maxT, n) end end
        table.sort(keysT)
        local maxL = 0
        for _, k in ipairs(order) do maxL = math.max(maxL, k) end
        if maxT >= 1 and maxL > maxT then
            plan = {}
            local sum_prev = 0               -- episodes in TMDB's seasons before its last one
            for _, k in ipairs(keysT) do if k < maxT then sum_prev = sum_prev + (tonumber(scT[tostring(k)]) or 0) end end
            local run_ = 0
            for _, k in ipairs(order) do
                if k > 0 then
                    local contiguous = true
                    for j = 1, k - 1 do if not seasons[j] then contiguous = false break end end
                    offsR[k] = run_
                    if k <= maxT then plan[k] = "run"
                    elseif not contiguous then
                        -- holes before it: "last" only for a far-off season with nothing between (S01, S02 ... S17)
                        local between = false
                        for j = maxT + 1, k - 1 do if seasons[j] then between = true break end end
                        plan[k] = between and "run" or "last"
                    elseif run_ + 1 > sum_prev - 3 then plan[k] = "last"   -- starts where TMDB's earlier seasons end
                    else plan[k] = "run" end
                    run_ = run_ + (counts[k] or 0)
                end
            end
        end
    end
    -- the anime-lists map said exactly which TMDB season a folder is (Bleach TYBW folder "S17" = TMDB season 2)
    if scT and TV.explicit and next(TV.explicit) then
        plan = plan or {}
        for k, ms in pairs(TV.explicit) do if scT[tostring(ms)] then plan[k] = "map:" .. ms end end
    end
    TV.plan = plan
    local function tmdb_coords(ep)
        if not plan or not ep.e or not plan[ep.s or 0] then return ep end
        if plan[ep.s] == "last" then return { s = maxT, e = ep.e } end
        local mt = tostring(plan[ep.s]):match("^map:(%d+)$")
        if mt then return { s = tonumber(mt), e = ep.e } end
        local n = (offsR[ep.s] or 0) + ep.e
        for _, k in ipairs(keysT) do
            local c = tonumber(scT[tostring(k)]) or 0
            if n <= c then return { s = k, e = n } end
            n = n - c
        end
        return { s = ep.s, e = ep.e, beyond = true }
    end

    TV.coords_impl = tmdb_coords
    TV.offs = offs
    local function add_info_parts(parts, info)
        if info and info.v and info.v > 0 then parts[#parts + 1] = dp(string.format("★ %.1f", info.v), THEME.warn, 4) end
    end

    local function make_card(ep)
        local e = ep.entry
        local tc = tmdb_coords(ep)
        local info, ts, te, need
        if tc.beyond then info, ts, te = nil, tc.s, tc.e
        else info, ts, te, need = TV.info_for(show, tc, offs) end
        local nm = info and info.n ~= "" and info.n or nil
        local cp = CT.parse(e.name)
        local c = { kind = "ep", ep = ep, entry = e, name = e.name, year = "", info = info, ts = ts, te = te }
        if ep.e then
            c.title = ep.e .. ". " .. (nm or (cp and cp.ep) or ("Episode " .. ep.e))
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
        local ffp = o.experimental_clean_titles and CT.parse_folder((ep.top or ep.folder).name) or nil
        local chips = (cp and cp.chips and #cp.chips > 0) and cp.chips or (ffp and ffp.chips) or {}
        for _, p in ipairs(HV.chip_parts(chips)) do parts[#parts + 1] = p end
        local grp = (cp and cp.group) or (ffp and ffp.group)
        if grp then parts[#parts + 1] = dp(grp, THEME.text_dim, 7) end
        add_info_parts(parts, info)
        if e.size and e.size > 0 then parts[#parts + 1] = dp(U.fmt_bytes(e.size), THEME.text_muted, 3) end
        if info and info.r and info.r > 0 then parts[#parts + 1] = dp(info.r .. " min", THEME.text_muted, 2) end
        c.parts = parts
        if info and info.st and info.st ~= "" then
            c.key = string.format("still:%s:%d:%d", show.id, ts, te)
            c.still = { size = HV.img_size("still", m.cw), path = info.st, base = string.format("s%s_%d_%d", show.id, ts, te) }
        elseif show and not ep.e and show.backdrop_path and show.backdrop_path ~= "" then
            c.key = "bd:" .. show.id
            c.still = { size = HV.img_size("backdrop", m.cw), path = show.backdrop_path, base = "b" .. show.id }
        else
            c.key = "file:" .. e.href
            if need then c.need = { entry = show, s = ts } end
        end
        if ep.e and show then
            c.dbg = string.format("S%sE%s -> TMDB S%sE%s%s", tostring(ep.s), tostring(ep.e), tostring(ts), tostring(te),
                info and (info.st ~= "" and " (still)" or " (no still on TMDB)") or (need and " (fetching)" or " (no data)"))
            if plan then c.dbg = c.dbg .. "  [numbering " .. tostring(plan[ep.s] or "direct") .. "]" end
        end
        ep.dbg = c.dbg
        c.href = card.href
        -- what the "Next episode in 10..." card shows for this file
        MS.ep_meta[e.href] = { label = ep.e and string.format("S%02dE%02d", tonumber(ts or ep.s) or 0, tonumber(te or ep.e) or 0) or nil,
            name = nm, show = card.shown or card.title, key = c.still and c.key or nil, still = c.still }
        return c
    end

    -- a greyed card for an episode that is not on WebDAV
    local function missing_card(k, x)
        local info, _, _, need
        if show and x.e then
            local tc = tmdb_coords({ s = k, e = x.e })
            if not tc.beyond then info, _, _, need = TV.info_for(show, tc, offs) end
        end
        local nm = info and info.n ~= "" and info.n or nil
        local c = { kind = "missing", miss = x, year = "", href = card.href,
            key = "miss:" .. card.key .. ":" .. k .. ":" .. tostring(x.e or x.name), ph = "Unavailable" }
        c.title = x.e and (x.e .. ". " .. (nm or ("Episode " .. x.e))) or TV.clean_name(x.name or "?")
        c.reason = TV.reason_text(x)
        c.parts = { dp("⚠ " .. c.reason, THEME.warn, 10) }
        if need then c.need = { entry = show, s = k } end
        return c
    end

    local missing = TV.find_missing(seasons, order, show)
    TV.last_missing = missing
    local function note_for(k)
        local mlist = missing[k]
        if not mlist or #mlist == 0 then return nil, 0 end
        local nums, why = {}, {}
        for _, x in ipairs(mlist) do
            if x.e then nums[#nums + 1] = x.e end
            local r = TV.reason_text(x)
            why[r] = (why[r] or 0) + 1
        end
        local txt = string.format("⚠  %d episode%s missing", #mlist, #mlist == 1 and "" or "s")
        if #nums > 0 then txt = txt .. " (" .. U.fit_text(TV.ranges(nums), m.w * 0.4, m.lfs) .. ")" end
        if TV.rd_state == "off" then
            txt = txt .. ".  Possibly hoster unavailable on Real-Debrid."
        else
            local parts = {}
            for r, n in pairs(why) do parts[#parts + 1] = (n > 1) and (r .. " (" .. n .. ")") or r end
            table.sort(parts)
            txt = txt .. ".  " .. table.concat(parts, ", ")
        end
        return txt, #mlist
    end

    local real = 0
    for _, k in ipairs(order) do if k > 0 then real = real + 1 end end
    local multi = (#order > 1)
    if TV.multi ~= multi then TV.multi = multi; TV.relayout = true end
    if TV.season and not seasons[TV.season] then TV.season = nil end
    TV.count, TV.seasons, TV.allmovie, TV.real_seasons = #eps, #order, allmovie, real

    local rows = {}
    local function add_cards(list, title, note)
        local first, i = true, 1
        if #list == 0 and title then rows[#rows + 1] = { title = title, note = note, cards = {}, off = 0 } end
        while i <= #list do
            local cards = {}
            for j = i, math.min(#list, i + m.per - 1) do cards[#cards + 1] = list[j] end
            rows[#rows + 1] = { title = first and title or nil, note = first and note or nil, cards = cards, off = 0 }
            first = false
            i = i + m.per
        end
    end

    if multi and not TV.season then
        -- season folders
        local cards = {}
        for _, k in ipairs(order) do
            local list = seasons[k]
            local c = { kind = "season", season = k, year = "", href = card.href }
            local fe = list[1] and list[1].e or 1
            local tk = (k > 0) and tmdb_coords({ s = k, e = fe }).s or k          -- TMDB's season for this one
            local sname = show and type(show.sn) == "table" and show.sn[tostring(tk)] or nil
            if tk ~= k and sname and sname:lower():match("^season%s*%d+$") then sname = nil end
            if sname and show and PS.norm(sname) == PS.norm(show.name or "") then sname = nil end   -- TMDB calls it "Bleach"
            c.title = (k > 0) and ("Season " .. k) or "Other files"
            if sname and sname ~= "" and not sname:lower():match("^season%s*%d+$") and k > 0 then c.title = c.title .. " · " .. sname end
            c.ph = (k > 0) and ("Season " .. k) or "Other files"
            local parts = { dp(#list .. (allmovie and " files" or (#list == 1 and " episode" or " episodes")), THEME.text_muted, 9) }
            local _, nmiss = note_for(k)
            if nmiss > 0 then parts[#parts + 1] = dp("⚠ " .. nmiss .. " missing", THEME.warn, 10) end
            local w_ = 0
            for _, ep in ipairs(list) do if watched_set[ep.entry.href] then w_ = w_ + 1 end end
            if w_ > 0 then parts[#parts + 1] = dp(string.format("✓ %d/%d", w_, #list), THEME.good, 6) end
            c.parts = parts
            local sp = show and type(show.sp) == "table" and show.sp[tostring(tk)] or nil
            if sp and sp ~= "" then
                c.key = string.format("spost:%s:%d", show.id, tk)
                c.still = { size = HV.img_size("poster", m.gw or m.cw), path = sp, base = string.format("sp%s_%d", show.id, tk) }
            elseif show and show.poster_path and show.poster_path ~= "" then
                c.key = "spost:" .. show.id .. ":show"
                c.still = { size = HV.img_size("poster", m.gw or m.cw), path = show.poster_path, base = "p" .. show.id }
            else
                c.key = "season:" .. card.key .. ":" .. k
            end
            cards[#cards + 1] = c
        end
        local has0 = seasons[0] ~= nil
        add_cards(cards, string.format("%d season%s%s  ·  Enter to open", real, real == 1 and "" or "s", has0 and " + other files" or ""))
    else
        for _, k in ipairs(order) do
            if not TV.season or TV.season == k then
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
                local cards = {}
                for _, ep in ipairs(list) do cards[#cards + 1] = make_card(ep) end
                local note = note_for(k)
                if note and o.show_missing_episodes then
                    -- placeholders in episode order (not when sorted by date)
                    local ms = {}
                    for _, x in ipairs(missing[k]) do ms[#ms + 1] = missing_card(k, x) end
                    if recent then
                        for _, c in ipairs(ms) do cards[#cards + 1] = c end
                    else
                        local merged, mi = {}, 1
                        for _, c in ipairs(cards) do
                            local e_ = c.ep and c.ep.e
                            while ms[mi] and e_ and ms[mi].miss.e and ms[mi].miss.e < e_ do merged[#merged + 1] = ms[mi]; mi = mi + 1 end
                            merged[#merged + 1] = c
                        end
                        while ms[mi] do merged[#merged + 1] = ms[mi]; mi = mi + 1 end
                        cards = merged
                    end
                    if not title then title = "Files" end
                end
                add_cards(cards, title, note)
            end
        end
    end
    return rows
end

-- Ctrl+D (poster screens) / script-message webdav-browser-diagnose: writes a plain-text report of what this screen is
-- built from - every matching library folder, how it was grouped and matched, every folder of the open title with its
-- listing state, every file with the season/episode read from it. No user name, password, server address or token.
function TV.diagnose()
    local L = {}
    local function add(fmt, ...) L[#L + 1] = (select("#", ...) > 0) and string.format(fmt, ...) or fmt end
    local function q(v) return tostring(v == nil and "-" or v) end
    PS.load_index()
    add("webdav-browser diagnostics   %s   %s   mpv %s", SCRIPT_VERSION, os.date("%Y-%m-%d %H:%M"), q(mp.get_property("mpv-version")))
    add("options: merge_seasons=%s  experimental_merge_by_tmdb=%s  clean_titles=%s  show_missing_episodes=%s  rd_api_token=%s  tmdb_key=%s",
        q(o.merge_seasons), q(o.experimental_merge_by_tmdb), q(o.experimental_clean_titles), q(o.show_missing_episodes),
        PS.rd_on() and "set" or "empty", (o.tmdb_key ~= "") and "set" or "empty")
    add("folder listings: %d in flight, %d waiting", MS.dav_running or 0, #(MS.dav_q or {}))
    local sel = HV.selected()
    local needle = (HV.mode == "title" and TV.card and TV.card.title) or (HV.q ~= "" and HV.q) or (sel and sel.title) or ""
    local word = PS.norm((tostring(needle):match("^[%[%(]?[^%s%]%)]*") or needle):gsub("^%W+", ""))
    if #word < 3 then word = PS.norm(needle) end
    add("")
    add("== library folders containing '%s' ==", word)
    local root = find_cached_dir(root_href)
    local n = 0
    for _, e in ipairs(root and type(root.entries) == "table" and root.entries or {}) do
        if e.is_dir and PS.norm(e.name):find(word, 1, true) then
            n = n + 1
            local id = HV.ident(e.name)
            local fp = id.fp or {}
            local ix = PS.idx[id.key]
            local tm = (type(ix) == "table" and ix.id) and string.format("%s %s '%s' via '%s'%s", q(ix.kind), q(ix.id), q(ix.name), q(ix.q), ix.s and (" season " .. ix.s) or "")
                or ((type(ix) == "table" and ix.none) and ("not found after: " .. table.concat(ix.tried or {}, " | ")) or "not looked up yet")
            local c = find_cached_dir(e.href)
            add("%s", e.name)
            add("    title '%s'  year '%s'  season-tag %s  group %s  kind-hint %s  card-key %s", q(id.title), q(id.year), q(fp.season), q(fp.group), q(id.kindpref), HV.gkey(e.name))
            add("    TMDB: %s", tm)
            add("    listing: %s", c and type(c.entries) == "table" and string.format("%d entries, %ds old", #c.entries, os.time() - (c.ts or os.time()))
                or (listing_error[e.href] and ("ERROR " .. tostring(listing_error[e.href])) or "not loaded"))
        end
    end
    if n == 0 then add("(none - the library root may not be loaded yet)") end
    local card = (HV.mode == "title" and TV.card) or nil
    if card then
        local show = TV.show_entry()
        add("")
        add("== title page '%s'  (card key %s, %d folder%s) ==", q(card.title), q(card.key), #(card.folders or {}), #(card.folders or {}) == 1 and "" or "s")
        if show then
            local sc = {}
            if type(show.sc) == "table" then
                local ks = {}
                for k in pairs(show.sc) do ks[#ks + 1] = tonumber(k) end
                table.sort(ks)
                for _, k in ipairs(ks) do sc[#sc + 1] = string.format("S%d=%s%s", k, q(show.sc[tostring(k)]),
                    (type(show.sn) == "table" and show.sn[tostring(k)]) and (" '" .. show.sn[tostring(k)] .. "'") or "") end
            end
            add("TMDB: %s %s '%s'  seasons: %s", q(show.kind), q(show.id), q(show.name), (#sc > 0) and table.concat(sc, ", ") or "(details not loaded)")
        else
            add("TMDB: no match")
        end
        if TV.plan then
            local ps = {}
            for k, v in pairs(TV.plan) do ps[#ps + 1] = "S" .. k .. "=" .. v end
            table.sort(ps)
            add("season numbering differs from TMDB: %s", table.concat(ps, " "))
        end
        local byhref = {}
        for _, ep in ipairs(TV.ordered or {}) do byhref[ep.entry.href] = ep end
        local function walk(folder, depth, indent)
            local c = find_cached_dir(folder.href)
            local st
            if c and type(c.entries) == "table" then st = string.format("%d entries", #c.entries)
            elseif TV.fail[folder.href] then st = "FAILED: " .. tostring(TV.fail[folder.href].err) .. " (" .. TV.fail[folder.href].n .. "x)"
            elseif listing_error[folder.href] then st = "ERROR: " .. tostring(listing_error[folder.href])
            else st = "not loaded yet" end
            add("%s[%s]  season hint %s  - %s", indent, folder.name, q(depth == 0 and TV.folder_season(folder.name) or TV.season_of(folder.name)), st)
            if not (c and type(c.entries) == "table") then return end
            for _, e in ipairs(c.entries) do
                if e.is_dir then
                    if depth < 3 then walk(e, depth + 1, indent .. "    ")
                    else add("%s    [%s]  (deeper than 3 levels - not read)", indent, e.name) end
                elseif U.is_media(e.name) then
                    local ep = byhref[e.href]
                    local cp = CT.parse(e.name)
                    if ep and not ep.dbg and ep.e and show and TV.coords_impl then
                        local tc = TV.coords_impl(ep)
                        local info = (not tc.beyond) and TV.info_for(show, tc, TV.offs or {}) or nil
                        ep.dbg = string.format("S%sE%s -> TMDB S%sE%s%s", q(ep.s), q(ep.e), q(tc.s), q(tc.e),
                            info and (" '" .. tostring(info.n) .. "'") or (tc.beyond and " (past TMDB's episodes)" or " (TMDB data not loaded yet)"))
                    end
                    add("%s    %s", indent, e.name)
                    add("%s        parsed %s  ->  shown in Season %s as episode %s%s%s", indent, q(cp and cp.se),
                        q(ep and ep.s), q(ep and ep.e), (ep and ep.absn) and (" (running number " .. ep.absn .. ")") or "",
                        (ep and ep.dbg) and ("   " .. ep.dbg) or "")
                else
                    add("%s    %s  (not a media file - skipped)", indent, e.name)
                end
            end
        end
        add("")
        for _, f in ipairs(card.folders or {}) do walk(f, 0, "") end
        if TV.last_missing then
            add("")
            add("missing episodes (Real-Debrid: %s%s):", q(TV.rd_state), PS.RD.err and (", " .. PS.RD.err) or "")
            local ks = {}
            for k in pairs(TV.last_missing) do ks[#ks + 1] = k end
            table.sort(ks)
            for _, k in ipairs(ks) do
                for _, x in ipairs(TV.last_missing[k]) do
                    add("    S%s E%s  %s  %s", q(k), q(x.e), x.name and ("'" .. x.name .. "'") or "(gap in numbering)", TV.reason_text(x))
                end
            end
        end
    end
    local path = mp.command_native({ "expand-path", "~~/webdav-diagnostics.txt" })
    local f = io.open(path, "wb")
    if f then
        f:write(table.concat(L, "\n"), "\n"); f:close()
        status_line = "Report saved: " .. path
        mp.osd_message("Diagnostics saved to " .. path, 5)
    else
        status_line = "Could not write " .. path
    end
    render()
end
mp.register_script_message("webdav-browser-diagnose", function() TV.diagnose() end)

-- Converted bitmaps (.bgra) are re-creatable and one set exists per window size; keep only the sizes in use now
-- so resizing the window over months cannot pile up hundreds of MB. Downloaded images and TMDB data are never pruned.
-- ---------- experimental animations (experimental_animations=yes) ----------
-- Gliding selection outline, a quick fade-in when a screen opens, shimmering placeholders while art loads and a short
-- smooth scroll. Posters are images mpv cannot fade, so they appear at once; everything runs only while no video plays.
HV.A = {}
function HV.ease(k) k = math.max(0, math.min(1, k)); return 1 - (1 - k) ^ 3 end
function HV.anim_on()
    if not o.experimental_animations then return false end
    local playing = mp.get_property("path") ~= nil and mp.get_property_native("pause") == false
    return not playing
end
function HV.anim_kick(dur)
    local A = HV.A
    A.till = math.max(A.till or 0, U.now_s() + (dur or 0.2))
    if A.timer then return end
    A.timer = mp.add_periodic_timer(1 / 45, function()
        local live = browser_active and MS.view == "home" and HV.anim_on()
        if not live or (U.now_s() > (A.till or 0) and not A.shimmer) then
            A.timer:kill(); A.timer = nil
            if browser_active then HV.last_data = nil; render() end
            return
        end
        HV.last_data = nil
        render()
    end)
end

function HV.prune_bgra()
    if HV.pruned or not PS.enabled() then return end
    HV.pruned = true
    local keep = {}
    local saved = HV.mode
    local saved_multi = TV.multi
    for _, md in ipairs({ "home", "title" }) do
        HV.mode = md
        TV.multi = false
        local m = HV.metrics()
        for _, d in ipairs({ m, m.L }) do
            keep[d.sk] = true
            if d.gsk then keep[d.gsk] = true end
        end
        if md == "title" then
            local hw, hh = TV.hero_size(m); keep[HV.skey(hw, hh)] = true
            local bw, bh = TV.backdrop_size(m); keep[HV.skey(bw, bh, THEME.bg_dim)] = true
        end
        local nw, nh = HV.next_card_size(m.h); keep[HV.skey(nw, nh)] = true
    end
    HV.mode, TV.multi = saved, saved_multi
    local dir = PS.dir()
    local list = utils.readdir(dir, "files")
    if type(list) ~= "table" then return end
    for _, f in ipairs(list) do
        local dims = f:match("_(%d+x%d+[%w%.]*)%.bgra$")
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
    if not e or (e.detail and (e.kind == "movie" or e.sp ~= nil) and e.gen ~= nil) then return end
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
        HV.want_bgra(st, w.dw or m.cw, w.dh or m.ch, w.fade)
    end
end

-- ---- hero (poster + title + overview) ----
function TV.hero_size(m)
    local hh = m.hero_h - 20
    return math.floor(hh * 2 / 3), hh
end

-- Experimental backdrop: the whole hero band's height, flush with the right edge, beside (never behind) the text.
function TV.backdrop_size(m)
    local bh = m.hero_h
    return math.min(math.floor(bh * 16 / 9), math.floor(m.w * 0.5)), bh
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
    local ready = st and st.bgra[HV.skey(hw, hh)] and not MS.debug
    HV.hero = { key = card.key, x = x0, y = y0, dw = hw, dh = hh }
    if not ready then
        add(D.ev_rect(x0, y0, x0 + hw, y0 + hh, THEME.bg_panel, 100, nil, 0, 0, 6))
        add(D.ev_text(x0 + hw / 2, y0 + hh / 2, 5, string.format("\\fs%d\\c%s", lfs, U.ass_color(THEME.text_dim)), PS.enabled() and "…" or ""))
    end
    local show = TV.show_entry()
    local tx = x0 + hw + 26
    local maxw = w - tx - m.mx
    HV.backdrop = nil
    if o.experimental_backdrop and show and (show.backdrop_path or "") ~= "" and not MS.debug and HV.conv_mode() ~= "magick" then
        local bw, bh = TV.backdrop_size(m)
        local bx = w - bw
        if bx - tx > w * 0.3 then          -- only when enough room is left for the text
            local key = "bdhero:" .. show.id
            HV.backdrop = { key = key, x = bx, y = m.top_h, dw = bw, dh = bh, sk = HV.skey(bw, bh, THEME.bg_dim) }
            HV.wanted[#HV.wanted + 1] = { key = key, dw = bw, dh = bh, fade = THEME.bg_dim,
                still = { size = HV.img_size("backdrop", bw), path = show.backdrop_path, base = "b" .. show.id } }
            maxw = bx - tx - lfs
        end
    end
    add(D.ev_text(tx, y0 + lfs * 1.1, 4, string.format("\\b1\\fs%d\\c%s", lfs + 14, "FFFFFF"), U.ass_escape(U.fit_text(card.shown or card.title, maxw, lfs + 14))))
    -- line 2: rating (gold) · years · age rating · genres · runtime · status
    local L2 = {}
    if show and show.vote and show.vote > 0 then L2[#L2 + 1] = dp(string.format("★ %.1f", show.vote), THEME.warn, 10) end
    local year = (show and show.year ~= "" and show.year) or card.year
    if year and year ~= "" then
        local y2 = show and show.yr2 or ""
        L2[#L2 + 1] = dp((y2 ~= "" and y2 ~= year and show.kind ~= "movie") and (year .. "–" .. y2) or year, THEME.text_primary, 9)
    end
    if show and show.cert and show.cert ~= "" then L2[#L2 + 1] = dp(show.cert, THEME.text_primary, 7) end
    if show and type(show.gen) == "table" and #show.gen > 0 then
        L2[#L2 + 1] = dp(table.concat(show.gen, ", ", 1, math.min(3, #show.gen)), THEME.text_muted, 6)
    end
    if show and (show.rt or 0) > 0 then L2[#L2 + 1] = dp(show.rt .. " min", THEME.text_muted, 5) end
    if show and show.status and show.status ~= "" and show.kind ~= "movie" then
        L2[#L2 + 1] = dp(show.status, show.status == "Ended" and THEME.text_muted or THEME.good, 4)
    end
    if TV.loading and TV.loading > 0 then L2[#L2 + 1] = dp(string.format("loading %d folder%s…", TV.loading, TV.loading == 1 and "" or "s"), THEME.text_dim, 3) end
    add(D.ev_text(tx, y0 + lfs * 3.0, 4, string.format("\\fs%d", lfs), HV.detail_ass(L2, maxw, lfs)))
    -- line 3: what YOU have - episodes (of TMDB's total), seasons, qualities, size
    local L3 = {}
    if TV.count and TV.count > 0 then
        local real = TV.real_seasons or 0
        local tot = show and tonumber(show.neps) or nil
        if TV.allmovie then L3[#L3 + 1] = dp(TV.count .. (TV.count == 1 and " file" or " files"), THEME.text_muted, 9)
        else L3[#L3 + 1] = dp(tot and tot > 0 and string.format("You have %d of %d episodes", TV.count, tot) or (TV.count .. " episodes"), THEME.text_muted, 9) end
        if real > 0 then L3[#L3 + 1] = dp(real .. (real == 1 and " season" or " seasons"), THEME.text_muted, 8) end
        local q, bytes = {}, 0
        for _, ep in ipairs(TV.ordered or {}) do
            bytes = bytes + (tonumber(ep.entry.size) or 0)
            local cp = CT.parse(ep.entry.name)
            for _, ch in ipairs(cp and cp.chips or {}) do q[ch] = (q[ch] or 0) + 1 end
        end
        local ql = {}
        for k in pairs(q) do ql[#ql + 1] = k end
        table.sort(ql, function(a, b) return q[a] > q[b] end)
        for i = 1, math.min(4, #ql) do L3[#L3 + 1] = dp(ql[i], CT.chip_color(ql[i]), 6 - i) end
        if bytes > 0 then L3[#L3 + 1] = dp(U.fmt_bytes(bytes), THEME.text_dim, 1) end
    end
    local yy = 4.4
    if #L3 > 0 then
        add(D.ev_text(tx, y0 + lfs * yy, 4, string.format("\\fs%d", lfs - 1), HV.detail_ass(L3, maxw, lfs - 1)))
        yy = yy + 1.4
    end
    if TV.failed and #TV.failed > 0 then
        local f1 = TV.failed[1]
        local txt = string.format("⚠  %d folder%s could not be listed (%s: %s) - retrying, R to retry now, Ctrl+D for a report",
            #TV.failed, #TV.failed == 1 and "" or "s", U.basename(f1.href) ~= "" and U.basename(f1.href) or f1.name, tostring(f1.err))
        add(D.ev_text(tx, y0 + lfs * yy, 4, string.format("\\fs%d\\c%s", lfs, U.ass_color(THEME.warn)), U.ass_escape(U.fit_text(txt, maxw, lfs))))
        yy = yy + 1.4
    end
    -- body: the selected episode (synopsis, air date, runtime, rating) or the show's overview
    local sel = HV.selected()
    local body, head
    if sel and sel.kind == "ep" and sel.info and HV.mode == "title" then
        local i = sel.info
        local hp = { dp(string.format("S%02dE%02d", tonumber(sel.ts) or 0, tonumber(sel.te) or 0), THEME.accent, 10) }
        if i.n and i.n ~= "" then hp[#hp + 1] = dp(i.n, "FFFFFF", 9) end
        if i.v and i.v > 0 then hp[#hp + 1] = dp(string.format("★ %.1f", i.v), THEME.warn, 8) end
        if i.d and i.d ~= "" then hp[#hp + 1] = dp(i.d, THEME.text_muted, 6) end
        if i.r and i.r > 0 then hp[#hp + 1] = dp(i.r .. " min", THEME.text_muted, 5) end
        head = hp
        body = (i.o and i.o ~= "") and i.o or "No synopsis on TMDB for this episode."
    else
        body = show and show.overview or ""
        if show and show.tag and show.tag ~= "" then
            add(D.ev_text(tx, y0 + lfs * yy, 4, string.format("\\i1\\fs%d\\c%s", lfs, U.ass_color(THEME.text_muted)), U.ass_escape(U.fit_text(show.tag, maxw, lfs))))
            yy = yy + 1.4
        end
    end
    if head then
        add(D.ev_text(tx, y0 + lfs * yy, 4, string.format("\\b1\\fs%d", lfs), HV.detail_ass(head, maxw, lfs)))
        yy = yy + 1.45
    end
    if body == "" and not PS.enabled() then body = "Set tmdb_key in webdav-browser.conf to see descriptions, posters and episode stills." end
    if body ~= "" then
        local lines = TV.wrap(body, maxw, lfs, math.max(1, math.floor((hh - lfs * (yy - 0.6)) / (lfs * 1.35))))
        for i, ln in ipairs(lines) do
            add(D.ev_text(tx, y0 + lfs * yy + (i - 1) * lfs * 1.35, 4, string.format("\\fs%d\\c%s", lfs, "E4DEF0"), U.ass_escape(ln)))
        end
    end
end

-- ---- actions ----
function TV.open(card)
    if not card then return end
    HV.saved = { r = HV.r, c = HV.c, top = HV.top, want_vc = HV.want_vc }
    TV.card = card
    TV.req = {}
    TV.season, TV.multi, TV.grid_pos = nil, nil, nil
    HV.mode = "title"
    log_view("title-page")
    HV.r, HV.c, HV.top, HV.want_vc, HV.hover = 1, 1, 1, 1, nil
    HV.sig, HV.last_data = nil, nil
    HV.clear()
    render()
end

function TV.back()
    HV.mode = "home"
    log_view(HV.q and "search-results" or "home")
    TV.card = nil
    HV.hero = nil
    local s = HV.saved or {}
    HV.r, HV.c, HV.top, HV.want_vc = s.r or 1, s.c or 1, s.top or 1, s.want_vc or 1
    HV.sig, HV.last_data, HV.hover = nil, nil, nil
    HV.clear()
    render()
end

-- What plays after `ep`: the following episodes, one file per episode - when a title holds two versions of the same
-- episode (two releases), the one from the same folder as the episode you started wins.
function TV.playlist_from(ep)
    local after, found = {}, false
    for _, x in ipairs(TV.ordered or {}) do
        if found then after[#after + 1] = x end
        if x.entry.href == ep.entry.href then found = true end
    end
    local list, slot = {}, {}
    local mytop = (ep.top or ep.folder or {}).href
    for _, x in ipairs(after) do
        local k = x.e and ((x.s or 0) .. ":" .. x.e) or nil
        if not k then list[#list + 1] = x.entry
        elseif k ~= ((ep.s or 0) .. ":" .. tostring(ep.e)) then
            local i = slot[k]
            if not i then list[#list + 1] = x.entry; slot[k] = #list
            elseif (x.top or x.folder or {}).href == mytop then list[i] = x.entry end
        end
    end
    return list
end

function TV.play(card)
    play_entry(card.entry, false, TV.playlist_from(card.ep))
end

-- ---------- library search inside the poster UI ----------
function HV.start_search()
    if not browser_active then return end
    if HV.typing then return end
    if HV.mode == "title" then HV.mode, HV.tv.card = "home", nil end
    unbind_all()
    HV.q = HV.q or ""
    HV.cur = #HV.q
    HV.typing = true
    search_query = HV.text_of(HV.q)
    run_global_search_hook()
    IDX.maybe_autostart()
    HV.r, HV.c, HV.top, HV.want_vc = 1, 1, 1, 1
    HV.sig, HV.last_data = nil, nil
    HV.clear()
    HV.bind_search()
    log_view("search-typing")
    render()
end

-- ---- the search box: a text cursor (HV.cur = bytes before it) that arrows, Home/End, Ctrl+arrows and clicks move ----
local function u8_is_cont(s, i) local b = s:byte(i); return b and b >= 128 and b < 192 end
function HV.cur_get() local q = HV.q or ""; HV.cur = math.max(0, math.min(#q, HV.cur or #q)); return HV.cur end
function HV.cur_prev(q, c) c = c - 1; while c > 0 and u8_is_cont(q, c + 1) do c = c - 1 end; return math.max(0, c) end
function HV.cur_next(q, c) c = c + 1; while c < #q and u8_is_cont(q, c + 1) do c = c + 1 end; return math.min(#q, c) end

function HV.search_changed()
    search_query = HV.text_of(HV.q)
    run_global_search_hook()
    HV.r, HV.c, HV.top, HV.want_vc = 1, 1, 1, 1
    HV.sig = nil
    render()
end

function HV.search_append(ch)
    local q, c = HV.q or "", HV.cur_get()
    HV.q = q:sub(1, c) .. ch .. q:sub(c + 1)
    HV.cur = c + #ch
    HV.search_changed()
end

function HV.search_backspace()
    local q, c = HV.q or "", HV.cur_get()
    if c == 0 then return end
    local p = HV.cur_prev(q, c)
    HV.q, HV.cur = q:sub(1, p) .. q:sub(c + 1), p
    HV.search_changed()
end

function HV.search_delete()
    local q, c = HV.q or "", HV.cur_get()
    if c >= #q then return end
    HV.q = q:sub(1, c) .. q:sub(HV.cur_next(q, c) + 1)
    HV.search_changed()
end

-- dir = -1 / 1 one character, -2 / 2 one word, "home" / "end"
function HV.cur_move(dir)
    local q, c = HV.q or "", HV.cur_get()
    if dir == "home" then c = 0
    elseif dir == "end" then c = #q
    elseif dir == -1 then c = HV.cur_prev(q, c)
    elseif dir == 1 then c = HV.cur_next(q, c)
    elseif dir == -2 then
        while c > 0 and q:sub(c, c) == " " do c = c - 1 end
        while c > 0 and q:sub(c, c) ~= " " do c = c - 1 end
    elseif dir == 2 then
        while c < #q and q:sub(c + 1, c + 1) == " " do c = c + 1 end
        while c < #q and q:sub(c + 1, c + 1) ~= " " do c = c + 1 end
    end
    HV.cur = c
    HV.last_data = nil
    render()
end

-- A click in the box puts the cursor at the nearest character (widths estimated like the rest of the layout).
function HV.cur_click(x)
    local b = HV.box
    if not b then return end
    local q = HV.q or ""
    local best, best_d, c = #q, math.huge, 0
    while true do
        local d = math.abs(b.x0 + U.utf8_len(q:sub(1, c)) * b.cw - x)
        if d < best_d then best, best_d = c, d end
        if c >= #q then break end
        c = HV.cur_next(q, c)
    end
    HV.cur = best
    HV.last_data = nil
    render()
end

function HV.stop_typing()
    if HV.typing then
        unbind_all()          -- also removes the typing keys
        bind_all()
    end
end

function HV.search_cancel()
    HV.q = nil
    search_query, search_scope = "", nil
    search_results, MS.global_total = {}, 0
    HV.stop_typing()
    HV.r, HV.c, HV.top, HV.want_vc = 1, 1, 1, 1
    HV.sig, HV.last_data = nil, nil
    HV.clear()
    log_view("home")
    render()
end

-- Leave the box for the results (the query stays; F or a click on the box edits it again).
function HV.to_results()
    HV.stop_typing()
    HV.typing = false
    HV.last_data = nil
    render()
end

function HV.search_enter()
    local card = HV.selected()
    if not card then return end
    HV.stop_typing()
    HV.activate()
end

MS.debug_extra = function()
    local L = {}
    if HV.mode == "title" and HV.tv.card then
        L[#L + 1] = "title page: " .. tostring(HV.tv.card.title) .. "  key " .. tostring(HV.tv.card.key)
    end
    local card = HV.selected()
    if card then
        local st = HV.items[card.key]
        local e = PS.idx and PS.idx[card.key]
        if card.kind == "ep" then
            L[#L + 1] = "episode: " .. tostring(card.dbg or "-")
        elseif card.kind == "missing" then
            L[#L + 1] = "missing: " .. tostring(card.miss and card.miss.name or ("E" .. tostring(card.miss and card.miss.e))) .. "  -  " .. tostring(card.reason)
        elseif card.kind == "season" then
            L[#L + 1] = "season folder " .. tostring(card.season) .. "  art " .. tostring(card.still and card.still.path or "none")
        else
            L[#L + 1] = string.format("selected: '%s' (%s%s)", card.title, card.kindpref ~= "" and card.kindpref or "any kind", card.year ~= "" and (", " .. card.year) or "")
            if type(e) == "table" and e.id then
                L[#L + 1] = string.format("TMDB: %s %s '%s' via '%s'", e.kind or "?", e.id, e.name or "?", tostring(e.q))
            elseif st and st.tried then
                L[#L + 1] = "TMDB: not found after: " .. table.concat(st.tried, " | ")
            else
                L[#L + 1] = "TMDB: " .. tostring(st and st.state or "pending")
            end
        end
    end
    if HV.mode == "title" then
        L[#L + 1] = "Real-Debrid: " .. (PS.rd_on() and (tostring(TV.rd_state) .. (PS.RD.err and ("  (" .. PS.RD.err .. ")") or "")) or "off (no rd_api_token)")
    end
    return L
end


function HV.show()
    log_view("home")
    MS.view = "home"
    HV.mode, TV.card = "home", nil
    PS.hide()
    HV.last_data, HV.sig = nil, nil
    unbind_all(); bind_all()
    render()
end

-- classic list view of a folder
function HV.open_folder(href)
    if not href then return end
    log_view("classic-list")
    MS.view = "browse"
    HV.clear()
    HV.last_data = nil
    unbind_all(); bind_all()
    reveal_path(href)
    set_focus("episodes")
    render()
end


function HV.activate()
    HV.last_act = U.now_s()
    local card = HV.selected()
    if not card then return end
    if card.kind == "ep" then TV.play(card)
    elseif card.kind == "season" then TV.enter_season(card.season)
    elseif card.kind == "missing" then
        status_line = "Unavailable: " .. tostring(card.reason)
        mp.osd_message("Not available on WebDAV: " .. tostring(card.reason), 3)
        render()
    elseif card.kind == "play" then play_entry(card.entry, false)
    else TV.open(card) end
end

function HV.open_list()
    local card = HV.selected()
    if HV.mode == "title" and TV.card then HV.open_folder(TV.card.href)
    elseif card then HV.open_folder(card.href) end
end

function HV.queue_selected()
    local card = HV.selected()
    if card and card.kind == "ep" then play_entry(card.entry, true) end
end

function HV.toggle_watched()
    local card = HV.selected()
    if card and card.kind == "ep" then toggle_watched(card.entry); HV.sig = nil; render() end
end

-- Forget the cached TMDB match of the selected title (and its episode data) so it is looked up again.
function HV.refetch()
    local card = HV.selected()
    if HV.mode == "title" then card = TV.card end
    if not card or not card.key then return end
    PS.load_index()
    local e = PS.idx[card.key]
    if type(e) == "table" and e.id then
        PS.load_eps()
        for k in pairs(PS.eps) do if k:match("^" .. e.id .. ":") then PS.eps[k] = nil end end
        PS.save_eps()
        PS.eps_ver = PS.eps_ver + 1
    end
    PS.idx[card.key] = nil
    PS.save_index()
    HV.items[card.key] = nil
    for k in pairs(HV.items) do if k:match("^still:") or k:match("^bd:") then HV.items[k] = nil end end
    TV.det_busy, TV.season_busy = nil, nil
    status_line = "Looking up " .. tostring(card.title) .. " again"
    HV.sig = nil
    render()
end

function HV.clear_cache_key()
    local now = U.now_s()
    local st = PS.stats(true)
    if HV.clear_armed and now - HV.clear_armed < 6 then
        HV.clear_armed = nil
        local n = PS.clear_cache()
        HV.clear()
        HV.items, HV.convq, HV.sig = {}, {}, nil
        PS.hide()
        TV.req, TV.season_busy, TV.det_busy = {}, nil, nil
        status_line = string.format("Cache cleared (%d files). Watch history was not touched.", n)
        load_root()
        render()
    else
        HV.clear_armed = now
        status_line = string.format("Press %s again to clear the cache (%s)",
            (tostring(o.cache_clear_key):match("[^%s,]+") or "key"):upper(), U.fmt_bytes(st.bytes))
        mp.add_timeout(6, function() if HV.clear_armed == now then HV.clear_armed = nil; HV.sig = nil; if browser_active then render() end end end)
        render()
    end
end

-- Messages in the top bar disappear 6 s after they appear ("Sort: Name", "Config reloaded"...); warnings stay longer.
function HV.status_visible()
    local st = status_line
    if not st or st == "" or st == "Ready" or st:match("^Loaded") then return false end
    local now = U.now_s()
    if st ~= HV.st_last then
        HV.st_last, HV.st_t = st, now
        mp.add_timeout(6.1, function() if HV.st_last == st and browser_active then HV.last_data = nil; render() end end)
        mp.add_timeout(15.1, function() if HV.st_last == st and browser_active then HV.last_data = nil; render() end end)
    end
    local keep = (st:match("^Failed") or st:match("^Press") or st:find("still adding", 1, true)) and 15 or 6
    return now - HV.st_t < keep
end

-- "WebDAV Library" crumb: straight back to the home screen (out of a title, out of a search).
function HV.go_home()
    if HV.mode == "title" then TV.back() end
    if HV.q or HV.typing then HV.search_cancel() return end
    HV.r, HV.c, HV.top, HV.want_vc = 1, 1, 1, 1
    HV.sig = nil
    render()
end
-- Mouse back button / Backspace: one level up, never closes the browser.
function HV.back()
    if HV.typing then HV.search_cancel()
    elseif HV.mode == "title" and TV.season and TV.multi then TV.leave_season()
    elseif HV.mode == "title" then TV.back()
    elseif HV.q then HV.search_cancel() end
end

function HV.esc()
    if HV.mode == "title" and TV.season and TV.multi then TV.leave_season()
    elseif HV.mode == "title" then TV.back()
    elseif HV.q then HV.search_cancel()
    else close_browser() end
end

function HV.hit_at(x, y)
    for _, hb in ipairs(HV.hit) do
        if x >= hb.x1 and x <= hb.x2 and y >= hb.y1 and y <= hb.y2 then return hb end
    end
    return nil
end

function HV.pad_hit()
    if not HV.pad_used then HV.pad_used = true; HV.last_data = nil end
end

function HV.on_move(val)
    if not HV.active() or not val then return end
    if HV.pad_used and HV.last_mouse and (math.abs(val.x - HV.last_mouse.x) > 3 or math.abs(val.y - HV.last_mouse.y) > 3) then
        HV.pad_used = false; HV.last_data = nil; render()            -- the mouse is back: normal focus ring again
    end
    HV.last_mouse = { x = val.x, y = val.y }
    local lh, hh = nil, nil
    for _, ln in ipairs(HV.links or {}) do
        if val.x >= ln.x1 and val.x <= ln.x2 and val.y >= ln.y1 and val.y <= ln.y2 then
            if ln.crumb then lh = ln.crumb end
            if ln.hdr then hh = true end
        end
    end
    if lh ~= HV.link_hover or hh ~= HV.hdr_hover then HV.link_hover, HV.hdr_hover = lh, hh; HV.last_data = nil; render() end
    local hb = HV.hit_at(val.x, val.y)
    local nh = hb and { r = hb.r, c = hb.c } or nil
    local same = (nh == nil and HV.hover == nil) or (nh and HV.hover and nh.r == HV.hover.r and nh.c == HV.hover.c)
    if not same then HV.hover = nh; render() end
end

function HV.mouse_down()
    if not HV.active() then return end
    local mx, my = U.mouse_xy()
    if not mx then return end
    if mx >= HV.m.w - 44 and my <= HV.m.top_h then close_browser(); return end
    for _, ln in ipairs(HV.links or {}) do
        if mx >= ln.x1 and mx <= ln.x2 and my >= ln.y1 and my <= ln.y2 then ln.act(mx, my); return end
    end
    local hb = HV.hit_at(mx, my)
    if not hb then return end
    local now = U.now_s()
    local dbl = HV.last_click and HV.last_click.r == hb.r and HV.last_click.c == hb.c and (now - HV.last_click_t) * 1000 <= o.double_click_ms
    HV.last_click, HV.last_click_t = { r = hb.r, c = hb.c }, now
    HV.r, HV.c = hb.r, hb.c
    HV.fix_off(HV.m)
    HV.want_vc = HV.vcol()
    if dbl then HV.last_click = nil; HV.activate() else render() end
end

function HV.mouse_dbl()
    if not HV.active() then return end
    if U.now_s() - (HV.last_act or 0) < 0.4 then return end
    local mx, my = U.mouse_xy()
    local hb = mx and HV.hit_at(mx, my)
    if not hb then return end
    HV.r, HV.c = hb.r, hb.c
    HV.last_click = nil
    HV.activate()
end

function HV.on_wheel(dir)
    if not HV.active() then return end
    HV.move(dir, 0)
end

function HV.refresh()
    HV.sig = nil
    if HV.mode == "title" and TV.card then
        TV.req, TV.fail = {}, {}
        local list, seen = {}, {}
        local function walk(href, depth)
            if seen[href] or depth > 3 then return end
            seen[href] = true
            list[#list + 1] = href
            local c = find_cached_dir(href)
            if c and type(c.entries) == "table" then
                for _, e in ipairs(c.entries) do if e.is_dir then walk(e.href, depth + 1) end end
            end
        end
        for _, f in ipairs(TV.card.folders or {}) do walk(f.href, 0) end
        local left = #list
        status_line = string.format("Refreshing %d folder%s…", left, left == 1 and "" or "s")
        for _, href in ipairs(list) do
            local c = find_cached_dir(href)
            if c then c.stale = true end
            fetch_listing(href, { silent = true, urgent = true }, function()
                left = left - 1
                if left <= 0 then status_line = "Refreshed"; HV.sig = nil; render() end
            end)
        end
        if PS.RD then PS.RD.list_t, PS.RD.info = 0, {} end
        render()
    else
        refresh_all()
    end
end


-- ============================================================
-- MAIN RENDER
-- ============================================================
render = function()
    if not browser_active then
        overlay:remove()
        MS.last_overlay_data = nil
        PS.hide()
        HV.clear()
        return
    end
    if MS.view == "home" then return HV.render() end

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
    if layout.poster then PS.draw_panel(chunks, layout.poster, paint_panel) end

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
        hint = "↑↓ Move   Tab Panel   Enter Play/Open   ←/BS Up   / Filter   F Search all   A Queue   P Download+play   S Sort   R Refresh   M Watched   H Hide   D Debug   V Home   Esc " .. (MS.from_home and "Back" or "Close")
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
                local tx1 = math.min((layout.poster and (layout.poster.x1 - 6) or w - 10) - tw, math.max(10, mx + 14))
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
    PS.update()
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
    if MS.view == "home" then return HV.on_move(val) end
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
    if search_query ~= "" or search_scope ~= nil then clear_search_state()
    elseif MS.from_home then HV.show()
    else close_browser() end
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
    add("v", function() HV.show() end)
    add("ESC", esc_pressed)
    add("MBTN_LEFT", function(e) on_click(e) end, CLICK)
    add("MBTN_LEFT_DBL", function() on_dblclick() end)
    add("WHEEL_UP",   function() on_wheel(-1) end, REP)
    add("WHEEL_DOWN", function() on_wheel(1) end, REP)
    return L
end

local function build_home_bindings()
    local L = {}
    local function add(key, fn, flags) L[#L + 1] = { key, fn, flags or ONCE } end
    local function many(keys, fn, flags) for _, k in ipairs(keys) do add(k, fn, flags) end end
    many(KEYS.up,    function() HV.move(-1, 0) end, REP);  add("k", function() HV.move(-1, 0) end, REP)
    many(KEYS.down,  function() HV.move(1, 0) end, REP);   add("j", function() HV.move(1, 0) end, REP)
    many(KEYS.left,  function() HV.move(0, -1) end, REP);  add("h", function() HV.move(0, -1) end, REP)
    many(KEYS.right, function() HV.move(0, 1) end, REP);   add("l", function() HV.move(0, 1) end, REP)
    many(KEYS.pgup,  function() HV.move(-2, 0) end, REP)
    many(KEYS.pgdn,  function() HV.move(2, 0) end, REP)
    many(KEYS.home,  function() HV.edge(true) end)
    many(KEYS.end_,  function() HV.edge(false) end)
    many(KEYS.enter, function() HV.activate() end)
    add("o", function() HV.open_list() end)
    add("v", function() HV.open_list() end)
    add("f", function() HV.start_search() end)
    add("/", function() HV.start_search() end)
    add("s", function() HV.toggle_sort() end)
    add("a", function() HV.queue_selected() end)
    add("m", function() HV.toggle_watched() end)
    add("t", function() HV.refetch() end)
    for key in tostring(o.cache_clear_key or "ctrl+x"):gmatch("[^%s,]+") do add(key, function() HV.clear_cache_key() end) end
    add("BS", function() HV.back() end)
    add("MBTN_BACK", function() HV.back() end)
    add("ctrl+d", function() TV.diagnose() end)
    add("r", function() HV.refresh() end)
    add("R", function() HV.refresh() end)
    add("d", function() MS.debug = not MS.debug; render() end)
    add("ESC", function() HV.esc() end)
    -- gamepads (mpv: input-gamepad=yes) and TV remotes; using one turns couch mode on (couch_mode=auto)
    local function pad(keys, fn, flags)
        for _, k in ipairs(keys) do add(k, function(...) HV.pad_hit(); fn(...) end, flags) end
    end
    pad({ "GAMEPAD_DPAD_UP", "GAMEPAD_LEFT_STICK_UP" },       function() HV.move(-1, 0) end, REP)
    pad({ "GAMEPAD_DPAD_DOWN", "GAMEPAD_LEFT_STICK_DOWN" },   function() HV.move(1, 0) end, REP)
    pad({ "GAMEPAD_DPAD_LEFT", "GAMEPAD_LEFT_STICK_LEFT" },   function() HV.move(0, -1) end, REP)
    pad({ "GAMEPAD_DPAD_RIGHT", "GAMEPAD_LEFT_STICK_RIGHT" }, function() HV.move(0, 1) end, REP)
    pad({ "GAMEPAD_LEFT_SHOULDER", "CHANNEL_UP" },    function() HV.move(-2, 0) end, REP)
    pad({ "GAMEPAD_RIGHT_SHOULDER", "CHANNEL_DOWN" }, function() HV.move(2, 0) end, REP)
    pad({ "GAMEPAD_ACTION_DOWN", "PLAY", "PLAYPAUSE", "PLAYONLY" }, function() HV.activate() end)
    pad({ "GAMEPAD_ACTION_RIGHT", "BACK", "CANCEL" }, function() HV.esc() end)
    pad({ "GAMEPAD_ACTION_LEFT" }, function() HV.toggle_watched() end)
    pad({ "GAMEPAD_ACTION_UP" }, function() HV.queue_selected() end)
    pad({ "GAMEPAD_START", "MENU" }, function() HV.toggle_sort() end)
    add("MBTN_LEFT", function(e)
        if type(e) == "table" then
            if e.event == "down" or e.event == "press" then HV.mouse_down() end
        else HV.mouse_down() end
    end, CLICK)
    add("MBTN_LEFT_DBL", function() HV.mouse_dbl() end)
    add("WHEEL_UP",   function() HV.on_wheel(-1) end, REP)
    add("WHEEL_DOWN", function() HV.on_wheel(1) end, REP)
    return L
end

local browse_bound = {}      -- names currently registered, so unbind removes exactly what was bound

safe_bind = function(name, key, fn, flags)
    local ok, err = pcall(mp.add_forced_key_binding, key, name, fn, flags)
    if not ok then msg.warn("webdav-browser: could not bind '" .. key .. "': " .. tostring(err)) end
end

bind_all = function()
    for _, kb in ipairs((MS.view == "home") and build_home_bindings() or build_browse_bindings()) do
        local name = "webdav_" .. kb[1]
        safe_bind(name, kb[1], kb[2], kb[3])
        browse_bound[#browse_bound + 1] = name
    end
end
unbind_all = function()
    for _, name in ipairs(browse_bound) do mp.remove_key_binding(name) end
    browse_bound = {}
    if HV.typing then HV.typing = false; unbind_search() end
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

-- Typing keys for the poster UI's own search box (same key set as the list UI's search).
HV.bind_search = function()
    local function add(name, key, fn, flags)
        safe_bind(name, key, fn, flags)
        search_bound[#search_bound + 1] = name
    end
    local function many(prefix, keys, fn, flags)
        for _, k in ipairs(keys) do add(prefix .. k, k, fn, flags) end
    end
    for i = 1, #SEARCH_CHARS_LOWER do
        local ch = SEARCH_CHARS_LOWER:sub(i, i)
        add("hvs_c_" .. ch, ch, function() HV.search_append(ch) end, REP)
    end
    for i = 1, #SEARCH_CHARS_UPPER do
        local ch = SEARCH_CHARS_UPPER:sub(i, i)
        add("hvs_C_" .. ch, ch, function() HV.search_append(ch) end, REP)
    end
    add("hvs_space", "SPACE", function() HV.search_append(" ") end, REP)
    add("hvs_any", "any_unicode", function(e)
        if type(e) ~= "table" then return end
        if e.event ~= "down" and e.event ~= "repeat" and e.event ~= "press" then return end
        local txt = e.key_text
        if txt and txt ~= "" and #txt <= 8 then HV.search_append(txt) end
    end, { repeatable = true, complex = true })
    many("hvs_", KEYS.bs,    function() HV.search_backspace() end, REP)
    add("hvs_del", "DEL", function() HV.search_delete() end, REP)
    add("hvs_kpdel", "KP_DEL", function() HV.search_delete() end, REP)
    many("hvs_", KEYS.enter, function() HV.search_enter() end)
    add("hvs_cancel", "ESC", function() HV.search_cancel() end)
    -- Left / Right / Home / End edit the text; Down (or Tab) goes to the results, F or a click comes back to the box
    many("hvs_", KEYS.left,  function() HV.cur_move(-1) end, REP)
    many("hvs_", KEYS.right, function() HV.cur_move(1) end, REP)
    add("hvs_cl", "ctrl+LEFT",  function() HV.cur_move(-2) end, REP)
    add("hvs_cr", "ctrl+RIGHT", function() HV.cur_move(2) end, REP)
    many("hvs_", KEYS.home,  function() HV.cur_move("home") end)
    many("hvs_", KEYS.end_,  function() HV.cur_move("end") end)
    many("hvs_", KEYS.down,  function() HV.to_results() end)
    many("hvs_", KEYS.tab,   function() HV.to_results() end)
    many("hvs_", KEYS.up,    function() end)
    many("hvs_", KEYS.pgdn,  function() HV.to_results() end)
    add("hvs_click", "MBTN_LEFT", function(e)
        if type(e) == "table" then
            if e.event == "down" or e.event == "press" then HV.mouse_down() end
        else HV.mouse_down() end
    end, CLICK)
    add("hvs_dbl", "MBTN_LEFT_DBL", function() HV.mouse_dbl() end)
    add("hvs_back", "MBTN_BACK", function() HV.back() end)
    add("hvs_wu", "WHEEL_UP",   function() HV.on_wheel(-1) end, REP)
    add("hvs_wd", "WHEEL_DOWN", function() HV.on_wheel(1) end, REP)
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
        save_dircache()
    end
    overlay:remove()
    MS.last_overlay_data = nil
    PS.hide()
    HV.clear()
    HV.hover = nil
    HV.mode, HV.tv.card, HV.q, HV.typing = "home", nil, nil, false
    MS.view = nil
end

-- Two webdav-browser scripts can be installed side by side (different open keys). Whichever browser was
-- opened last "owns" playback; the other one closes itself, and the data file is re-read so watch history
-- written by the other script is not overwritten with stale data.
MS.active = true
local function reload_user_data()
    local path = persist_status.path or history_file_path()
    if not path then return end
    local data = try_load_json(path) or try_load_json(path .. ".bak")
    if not data then return end
    watch_history = U.plain(data.history)
    watched_set   = U.plain(data.watched)
    sort_by_dir   = U.plain(data.sort)
    index_meta    = U.plain(data.index)
    MS.hints      = U.plain(data.hints)
    MS.tracks     = U.plain(data.tracks)
    MS.rev        = tonumber(data.rev) or MS.rev
    mark_continue_dirty()
    if browser_active then render() end
end
-- Hand-over: the instance that loses ownership writes its data once, then tells the new owner to re-read it,
-- so whichever script saves last always holds everything. An inactive instance never writes on its own.
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

    MS.view = o.home_view and "home" or "browse"
    MS.from_home = o.home_view and true or false
    HV.mode, HV.tv.card, HV.saved, HV.pruned, HV.q, HV.typing = "home", nil, nil, false, nil, false
    log_view(MS.view == "home" and "home" or "classic-list")
    HV.sig, HV.last_data, HV.r, HV.c, HV.top, HV.hover = nil, nil, 1, 1, 1, nil
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
    for key in (o.open_key_posters or "ctrl+p"):gmatch("[^%s,]+") do
        n = n + 1
        mp.add_forced_key_binding(key, n == 1 and "webdav_toggle" or ("webdav_toggle_" .. n), open_browser, { repeatable = false })
    end
    if n == 0 then mp.add_forced_key_binding("ctrl+p", "webdav_toggle", open_browser, { repeatable = false }) end
    -- gamepad / remote: the View button (or the remote's menu key) opens and closes the browser too
    if tostring(o.couch_mode):lower() ~= "no" and tostring(o.couch_mode):lower() ~= "false" then
        for key in tostring(o.couch_open_keys or ""):gmatch("[^%s,]+") do
            n = n + 1
            mp.add_forced_key_binding(key, "webdav_toggle_" .. n, function() HV.pad_used = true; open_browser() end, { repeatable = false })
        end
        if mp.get_property_native("input-gamepad") == false then pcall(mp.set_property, "input-gamepad", "yes") end
    end
end

-- ============================================================
-- PLAYBACK EVENTS
-- ============================================================
-- time-pos / duration are tracked continuously: by the time "end-file" fires mpv has often already
-- torn the values down, so reading them there returns nil.
mp.observe_property("time-pos", "number", function(_, v) if v then last_known_pos = v end end)
mp.observe_property("duration", "number", function(_, v) if v then last_known_dur = v end end)

-- Remember "what comes after this episode" in the history file itself, so Continue Watching does not depend on
-- the folder listing still being cached.
function MS.note_next_hint(href)
    local d = U.dirname(href)
    local nx = find_next_media_href(href)
    if nx then
        MS.hints[d] = { href = nx.href, name = nx.name, size = nx.size, ts = os.time() }
    elseif MS.hints[d] then
        MS.hints[d].ts = os.time()
    else
        MS.hints[d] = { ts = os.time() }
    end
end

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
    if watched_set[meta.href] then MS.note_next_hint(meta.href) end
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

    if meta then
        if not MS.active then reload_user_data() end          -- never overwrite the owner's newer data with ours
        if record_progress(meta, last_known_pos, last_known_dur) then
            save_persistence(true)
            if not MS.active then pcall(mp.commandv, "script-message", "webdav-browser-reload") end
        end
    end

    now_playing = nil
    last_known_pos, last_known_dur = nil, nil
    if browser_active then render() end
end)

-- Periodic watch-progress snapshot (memory every 15 s, disk at most once a minute)
mp.add_periodic_timer(15, function()
    if now_playing and MS.active and record_progress(now_playing, last_known_pos, last_known_dur) then
        save_persistence()      -- the history file is tiny, so write it every time instead of risking a lost session
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


-- poster edition: the next episode's TMDB still, from the same cache as the title page
function HV.next_card_size(h)
    local sw = math.floor(h * 0.18)
    return sw, math.floor(sw * 9 / 16)
end
function NX.size()
    local _, oh = mp.get_osd_size()
    NX.radius = HV.R
    return HV.next_card_size(oh or 1080)
end
function NX.still(meta, sw, sh)
    local em = MS.ep_meta[meta.href]
    if not (em and em.still and em.key and PS.enabled()) then return nil end
    local st = HV.items[em.key]
    if not st then st = { state = "new", bgra = {}, cq = {} }; HV.items[em.key] = st end
    TV.pump_still({ key = em.key, still = em.still, dw = sw, dh = sh }, st, nil)
    HV.convert_pump()
    return st.bgra[HV.skey(sw, sh)]
end

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
msg.info("webdav-browser " .. SCRIPT_VERSION .. " loaded (" .. tostring(o.open_key_posters) .. ")  - poster edition")
mp.osd_message("webdav-browser " .. SCRIPT_VERSION .. " loaded", 2)
