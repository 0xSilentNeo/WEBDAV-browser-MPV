<div align="center">

# webdav-browser

Browse and play a WebDAV video library (built for Real-Debrid, works with any WebDAV server) inside [MPV](https://mpv.io).

</div>

<p align="center">The script has two UIs to choose from:</p>

<div align="center">

| Script | Look | Opens with |
|---|---|---|
| `webdav-browser-posters.lua` | Netflix-style posters, title pages, episode stills | `Ctrl+P` |
<kbd width="84%"> 
<img width="85%" alt="webdav-browser-posters" src="https://github.com/user-attachments/assets/7c1c5cee-3bd2-48e4-b5d4-f46a209ba23e" />
</kbd>


<br/><br/>

| Script | Look | Opens with |
|---|---|---|
| `webdav-browser.lua` | Fast two-panel list (Folders \| Files) | `Ctrl+W` |

<img width="85%" alt="webdav-browser" src="https://github.com/user-attachments/assets/fede1596-b8ff-4095-a579-49964efa24d1" />

</div>

<br/>

Both share one config file and one watch history, and can be installed side by side.

## Install

1. Put the `.lua` file(s) in `<mpv config>/scripts/` (Windows: `%APPDATA%\mpv\scripts\`).

2. Put `webdav-browser.conf` in `<mpv config>/script-opts/` and add your login:
   ```ini
   user=YOUR_USERNAME
   pass=YOUR_WEBDAV_PASSWORD
   ```
3. Poster edition: add a free TMDB key (`tmdb_key=`, from themoviedb.org → Settings → API).

4. Optional (poster edition):
   - `rd_api_token=` ([real-debrid.com/apitoken](https://real-debrid.com/apitoken)) – adding releases, missing-episode reasons.
   - `addon_urls=` – your Stremio add-on manifest URLs (AIOStreams, Comet, Torrentio…) for the add screen.
   - [rqbit](https://github.com/ikatson/rqbit/releases) – rename the Windows build to `rqbit.exe` and put it next to
     `mpv.exe`; streams torrents that Real-Debrid refuses.

Needs `curl` (built into Windows 10+). Installing **ffmpeg** makes artwork conversion much faster.
`vo=gpu-next` in `mpv.conf` enables the frosted-glass blur on the on-screen cards.

Press `F1` at any time for a **setup check**: every service and folder is tested and failures say what to change.

## Features

### Browsing
- Clean titles: `S01E03` plus quality chips (4K, HDR, DV, Atmos, Remux).
- Continue Watching, watched ticks, resume with a start-over key.
- Listings are cached and refreshed quietly; folders Real-Debrid is still filling are re-checked until complete.

### Search
- Typo-tolerant title search with a real text cursor.
- Filters: `genre:anime  year:2010s  type:tv  rating:8  unwatched` (also as clickable chips).
- Optional file-name index of your library.

### Playback
- Following episodes play as a playlist; the next one is buffered ahead.
- **Up next** glass card with the episode still and a countdown ring, timed to the end credits or to where a chapter-skip script jumps.
- **Now playing** card for a few seconds when a file starts: title, episode, resolution and source.
- Both cards and the startup note can be turned off and placed in any corner.
- **Skip intro / skip credits:** a small "Skip intro · S" note while a named opening chapter plays (unless a
  chapter-skip script is loaded), and S on the Up next card skips the credits (to the preview when there is one).
- Audio and subtitle language remembered per show (`remember_tracks`); the title page says what will be picked.
- Download-while-playing fallback when a stream fails, shown on a floating glass card with a live progress bar.
- **Downloaded files play from your computer** (`play_local_first`): once an episode is in `download_dir`, its
  card says "⤓ on your PC" and Play uses the local copy — the start of offline viewing.
- While the browser is open over a video, the player's controller and its seekbar thumbnails stay hidden (`hide_osc`).

### Poster edition
- **Home:** Continue Watching (episode stills) and All Titles, sortable. One clean title per card with
  `★ 8.1 · 2024 · Series` under it (Series, Movie or Anime; seasons and quality when there is room).
  **Filter chips** (TV, Movies, Unwatched, ★ 8+, your library's genres and decades) filter All Titles and are
  remembered between sessions (`home_filter_chips`).
- **Title pages:** rating, years, runtime and outlined chips (4K, HDR, age rating), genres, "You have 61 of 366
  episodes", the synopsis with More / Less, and buttons: **Play / Resume S01E05**, **Queue**, **Mark watched**,
  **Find more** and **Download** (↑ from the cards reaches them). One card per episode with its TMDB still and
  synopsis; season grid for long shows.
- **Downloads:** the Download button opens a small popover above it: tick the files (Space, A for all), Enter
  starts and it gets out of the way. The **↓ Downloads** pill in the footer says "Download started" / "Queued · #3"
  with a short animation, shows the current file's progress and a count badge, and opens the queue window (also
  `Shift+D`): every file of every title, pause / resume, Stop, remove (Del), reorder (Shift+↑↓), retry what failed.
  Files go to `download_dir/<Title>/`; half-finished ones are continued.
- **Tracked shows:** **+ Track** on a title page (library or add screen) keeps it in the **Tracked** flyout on the top
  bar (`U`): poster, next episode with its date and countdown (anime: AniList's exact airing time), "Date TBA", or
  the release date for movies. While mpv runs it checks every few hours and tells you in one toast when something
  new is out — and whether your add-ons already have a cached release of it (`track_cached_check`); each title's bell
  sets every episode / new seasons only / off. A **calendar view** (`track_view=calendar`, or the ▦ pill) shows the
  week on top and groups the titles by day; a tracked show's library page says when its next episode is due.
- **Unavailable files:** when Real-Debrid removed a title's files, a card says why and offers Retry, Find another
  release, Stream as a torrent (`T`, unless nobody seeds it) and the setup check.
- **Anime matching:** romaji names resolved through AniList and the anime-lists id map, including "Part 2" and odd season numbers.
- **Missing episodes:** greyed cards, with the reason from Real-Debrid if you add an API token.
- **Responsive layout:** sizes snap to steps of the window height, so resize, maximise and full screen reflow instantly without re-converting artwork; blurred placeholders while images load. Card sizes are adjustable (`home_card_pct`, `landscape_card_pct`, `episode_card_pct`).
- **Transitions:** opening a title flies its poster out of the card into place, the backdrop settles in and the lines
  and rows follow one after another; Back flies the poster home. Play fades to black with a "Starting…" note until the
  video is up (mpv 0.38+, `transitions`, `transition_style`).
- **Focus:** the selected card grows and the others dim around it (`focus_style=dim`, mpv 0.38+; the accent outline is
  optional, `focus_ring`); a row cut off at the bottom fades out instead of ending in a hard line.
- **Smooth scrolling:** the rows glide, like a website (`smooth_scroll`).
- **Themes:** `theme=classic | graphite | netflix | rose | ios`, every colour overridable; the glass toasts and cards
  have their own `toast_theme`.
- **Polish:** rounded corners, shadows, a growing selected card, a season heading that stays pinned while you scroll, artwork prepared ahead of scrolling, sharp images on 4K, animations at your display's refresh rate (up to 90 fps).
- **Offline-friendly cache:** TMDB matches, episode data and downloaded artwork are kept for good; a different card size or window reuses them instead of downloading again. Pictures cut off by a dropped connection are found and fetched again.
- **Search by any name:** original and other titles and the film series are searched too (`search_cast`,
  `search_keywords` for more).
- **Couch mode:** gamepad / TV-remote control with a large focus ring.
- **`?`** on any page: a sheet with the keys of that page.
- **Setup check (`F1`):** every service and folder tested for real, one row per add-on with a stream question and its
  answer time; `C` copies the report to the clipboard (and saves it in the cache folder).
- **Glass bars (experimental):** `experimental_glass_bars=yes` turns the top and bottom bars into thin floating pills: Home, clickable breadcrumbs, a status pill that opens the setup check (its dot breathes, `pulse`), and the keys and cache at the bottom - also on the add screen, with the title details in a floating card. The classic top bar's height is set with `top_bar_scale`.
- **Experimental visuals (26.4, off by default):** the paused video visible and blurred behind the browser
  (`experimental_video_glass`), a colour wash in the poster's colour behind the title page's text
  (`experimental_hero_wash`), TMDB's title logo instead of the title text (`experimental_title_logo`), NEW on this
  week's episodes and the next episode on tracked shows' cards (`experimental_new_badges`), cards that grow under the
  mouse (`experimental_hover_lift`), pop-ups that fade out (`experimental_exit_anim`) and drawn empty states
  (`experimental_empty_states`).

### Add from add-ons (poster edition, `N`)
- Home page with trending (TOP 10 badges), streaming-service, airing-anime and new-season rows (TMDB + AniList);
  arrows over the row's edge page through it.
- A title page for every title, laid out like the library's (poster, the details centred beside it, the backdrop
  faded in on the right): **Search movie / show / anime on AIOStreams**, **Search Nyaa.si** (anime) and **+ Track**,
  with the next episode or release date, and a row of its seasons (straight to that season's releases) or
  "More like this".
- Search any title and list its releases from your Stremio add-ons; every season pack and complete-series pack, sortable and filterable (`dual 1080 -hevc`).
- Each release shows folder and file name, cached or not, quality, codec, audio, languages, group and both sizes.
- File checklist before anything is added; releases already on your Real-Debrid are reused, never added twice.
- **Nyaa.si** as a second source (`Tab`). When the add-ons find only a few releases, a button offers Nyaa.si for the
  same title (`nyaa_fallback=ask`; `auto` sends anime there by itself).
- **Torrent streaming:** releases Real-Debrid refuses ("infringing file") are streamed through rqbit automatically,
  with a compact progress card until enough is buffered (`torrent_fallback=manual` asks first); a torrent nobody
  seeds says so.

## Keys

| | Keyboard | Gamepad |
|---|---|---|
| Move | Arrows, PgUp / PgDn | D-pad, LB / RB |
| Open / play | `Enter` | A |
| Back / close | `Esc`, Backspace, mouse-back | B |
| Watched / queue | `M` / `A` | X / Y |
| Sort | `S` | Start |
| Search | `F` (edit with ← → Home End Del, ↓ to results) | – |
| Add from add-ons | `N` (there: `T` streams a release as a torrent) | – |
| Refresh / re-fetch art | `R` / `T` (on a title Real-Debrid removed: stream it as a torrent) | – |
| Whole synopsis | `I` (title page) | – |
| Download queue | `Shift+D` (anywhere in the library) | – |
| Tracked shows | `U` | – |
| Keys of this page | `?` | – |
| Setup check | `F1` (anywhere) | – |
| Open / close | `Ctrl+P` / `Ctrl+W` | View |

Every key can be changed in `webdav-browser.conf` (`key_up`, `key_open`, `key_back`, …). Browser keys only exist
while the browser is open.

## Configuration

Every option is explained in `webdav-browser.conf`. The ones most people change: `start_path`, `ui_scale`,
`home_card_pct`, `merge_seasons`, `poster_overrides`, `rd_api_token`, `addon_urls`, `next_episode_card`,
`next_card_position`, `now_playing_position`, `torrent_fallback`, `transitions`, `couch_mode`, `theme`,
`toast_theme`, `focus_style`, `download_dir`, `play_local_first`, `track_shows`. Settings added in a version are listed
at the end of the file under "New in …"; a misspelt value falls back to the default with a line in mpv's log. The
file is grouped by topic (connection, services, library, playback, cards, look, poster screens, artwork, add-ons,
torrents, keys). See `CHANGELOG` for what each version brought.


## Recommended/Used companion scripts

- [ModernZ](https://github.com/Samillion/ModernZ) – A sleek and modern OSC for mpv.
- [thumbfast](https://github.com/po5/thumbfast) – seek-bar thumbnails for uosc and other OSCs. Set `network=yes` in `thumbfast.conf` for streams.
- [op-ed-pv-skip](https://github.com/awaken1ng/mpv-op-ed-pv-skip) or another chapter skipper – skips openings / endings; the next-episode card adapts to it.
- [autosubsync-mpv](https://github.com/joaquintorres/autosubsync-mpv) – fixes out-of-sync subtitles with one key.
- [Anime4K](https://github.com/bloc97/Anime4K) – GPU shaders that upscale anime sharply on a 4K screen.
- [hold-speed](https://github.com/0xSilentNeo/Hold-Speed) – A Lua script for mpv that mimics YouTube's playback speed feature.

## Credits

Metadata and artwork from [TMDB](https://www.themoviedb.org) – this product uses the TMDB API but is not endorsed or
certified by TMDB. Anime matching via [AniList](https://anilist.co) and [Fribb/anime-lists](https://github.com/Fribb/anime-lists).
Torrent streaming via [rqbit](https://github.com/ikatson/rqbit).
