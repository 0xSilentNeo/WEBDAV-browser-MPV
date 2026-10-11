# webdav-browser for mpv

Browse and play a WebDAV video library (built for Real-Debrid, works with any WebDAV server) from inside mpv.
Two editions share one config file and one watch history:

| Script | What it is | Opens with |
|---|---|---|
| `webdav-browser-posters.lua` | Netflix-style poster browser (TMDB artwork, title pages, episode stills) | `Ctrl+P` |
| `webdav-browser.lua` | Fast two-panel list browser (Folders \| Files), no artwork | `Ctrl+W` |

Both can be installed side by side; whichever you opened last owns playback and the data file.

## Install

1. Copy the `.lua` file(s) to `<mpv config>/scripts/` (Windows: `%APPDATA%\mpv\scripts\`).
2. Copy `webdav-browser.conf` to `<mpv config>/script-opts/` and add your own credentials:
   ```
   user=YOUR_USERNAME
   pass=YOUR_WEBDAV_PASSWORD
   ```
3. Poster edition only: set `tmdb_key=` (free at themoviedb.org → Settings → API).

Needs `curl` (built into Windows 10+). Artwork is converted with **ffmpeg** when it is installed (fast), otherwise
PowerShell on Windows or ImageMagick elsewhere. Gamepads need `input-gamepad=yes` (the poster script turns it on).

## Features

### Both editions
- **Clean titles** – release names become `S01E03` + quality chips (4K, HDR, DV, Atmos, Remux…), file rows line up in
  columns, the full name is in a tooltip.
- **Watch tracking** – resume where you stopped ("Resumed at 12:34", `B` starts over), watched ticks, Continue
  Watching, hide watched (`H`), mark watched (`M`).
- **Playback** – plays the following episodes as a playlist, buffers the next one ahead, retries failed streams,
  reconnects dropped HTTP streams.
- **Download-while-playing fallback** – when streaming fails (e.g. Real-Debrid answering 503), the file is downloaded
  with curl and played while it downloads (`P` starts it by hand).
- **Per-show audio & subtitle language** – pick Japanese audio + English subs once, every episode of that show starts
  that way; other shows keep their own choice.
- **Library search** (`F`) – a persistent index of the folders you open (or the whole library), typo-tolerant, with a
  real text cursor (arrows, Home/End, Ctrl+arrows, Del).
- **"Next episode in 10…"** – near the end credits (or the ED chapter) a card counts down to the next episode and
  plays it (skipping the rest of the credits), `Esc` stays, `Enter` plays now. Works with chapter-skip scripts such as
  op-ed-pv-skip: then the countdown ends right where the skipped chapters begin. The poster edition shows the
  episode's still and TMDB name.
- **Gamepad & TV remote** – D-pad / stick, A, B, X, Y, shoulder buttons.
- **Real-Debrid aware cache** – listings are cached and refreshed quietly; folders Real-Debrid is still filling are
  re-checked every few seconds until they stop growing. `Ctrl+X` twice clears the cache (never the history).
- **Comfort** – live config reload, per-folder sort memory, mouse support (double-click, wheel, draggable scrollbar,
  mouse-back), background blur, Sakura Night palette, debug panel (`D`). Credentials are only ever sent to your server.

### Poster edition
- **Home screen** – Continue Watching (episode stills with progress bars) and All Titles (sort by name / recent),
  clickable breadcrumbs, mouse-back / Backspace goes up, `V` / `O` switch to the classic list with a poster column.
- **Matching** – TMDB lookup that understands release names, alternative titles and seasons; anime folders are
  matched through **AniList + the anime-lists id map**, which also knows that a "Part 2" folder is episodes 13–24 or
  that a Bleach "S17" folder is TMDB season 2. `poster_overrides` pins anything by hand; `T` looks a title up again.
- **Title pages** – poster, rating, years, age rating, genres, runtime, status, "You have 61 of 366 episodes",
  qualities and size; one card per episode with its TMDB still, name, synopsis and rating; multi-season shows open on a
  season grid with season posters. Release numbering that differs from TMDB (absolute numbers, extra seasons) is mapped.
- **Missing episodes** – gaps in the numbering get a greyed card; with an optional Real-Debrid API token it says *why*
  (hoster unavailable, file unavailable, torrent dead…). While Real-Debrid is still adding files the top bar shows its
  progress. `Ctrl+D` writes a diagnostics report.
- **Search** – typo-tolerant, with filters: `genre:anime year:2010s type:tv rating:8 unwatched` (also as clickable chips);
  filters look up every title they need in the background. `Down` leaves the box for the results, a click puts the
  cursor where you clicked.
- **Polish** – rounded corners and soft shadows on all artwork, the selected card grows slightly, the next row peeks in
  under the last one, artwork for the next rows is prepared while idle, 4K screens get sharper images, one `ui_scale`
  for every screen, optional animations.
- **Couch mode** – as soon as a gamepad or remote is used: a bigger focus ring, bigger text and a button legend.
- **Backdrop hero** *(experimental)* – a large TMDB backdrop beside the text on title pages, faded into the background.

## Keys

| | Keyboard | Gamepad |
|---|---|---|
| Move | Arrows / `hjkl`, PgUp/PgDn | D-pad / left stick, LB/RB |
| Open / play | `Enter` | A |
| Back / close | `Esc`, Backspace, mouse-back | B |
| Watched / queue | `M` / `A` | X / Y |
| Sort | `S` | Start |
| Search (edit with ←/→, Home/End, Del) | `F` or `/` | – |
| Refresh / re-fetch art | `R` / `T` | – |
| Open / close the browser | `Ctrl+P` (posters), `Ctrl+W` (list) | View |

## Configuration

Everything is in `webdav-browser.conf`; each option is explained there, grouped by the version that introduced it.
The most useful ones: `start_path`, `default_sort`, `ui_scale`, `home_card_pct`, `merge_seasons`, `poster_overrides`,
`anime_lookup`, `rd_api_token`, `remember_tracks`, `next_episode_card`, `next_episode_timing`, `couch_mode`,
`card_radius`, `selected_grow`.

## Credits

Artwork and metadata from [TMDB](https://www.themoviedb.org) – this product uses the TMDB API but is not endorsed or
certified by TMDB. Anime matching uses [AniList](https://anilist.co) and
[Fribb/anime-lists](https://github.com/Fribb/anime-lists).
