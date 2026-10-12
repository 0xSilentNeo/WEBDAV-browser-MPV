<div align="center">

# webdav-browser

Browse and play a WebDAV video library (built for Real-Debrid, works with any WebDAV server) inside [MPV](https://mpv.io).

</div>

<p align="center">The script has two UIs to choose from:</p>

<div align="center">

| Script | Look | Opens with |
|---|---|---|
| `webdav-browser-posters.lua` | Netflix-style posters, title pages, episode stills | `Ctrl+P` |

<img width="85%" alt="webdav-browser-posters" src="https://github.com/user-attachments/assets/7c1c5cee-3bd2-48e4-b5d4-f46a209ba23e" />

<br/><br/>

| Script | Look | Opens with |
|---|---|---|
| `webdav-browser.lua` | Fast two-panel list (Folders \| Files) | `Ctrl+W` |

<img width="55%" alt="webdav-browser" src="https://github.com/user-attachments/assets/fede1596-b8ff-4095-a579-49964efa24d1" />

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

Needs `curl` (built into Windows 10+). Installing **ffmpeg** makes artwork conversion much faster.

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
- **Next episode in 10…** card at the end credits, compatible with chapter-skip scripts.
- Audio and subtitle language remembered per show.
- Download-while-playing fallback when a stream fails.

### Poster edition
- **Home:** Continue Watching (episode stills) and All Titles, sortable.
- **Title pages:** rating, years, genres, "You have 61 of 366 episodes", one card per episode with its TMDB still and synopsis; season grid for long shows.
- **Anime matching:** romaji names resolved through AniList and the anime-lists id map, including "Part 2" and odd season numbers.
- **Missing episodes:** greyed cards, with the reason from Real-Debrid if you add an API token.
- **Polish:** rounded corners, shadows, a growing selected card, artwork prepared ahead of scrolling, sharp images on 4K.
- **Couch mode:** gamepad / TV-remote control with a large focus ring.

## Keys

| | Keyboard | Gamepad |
|---|---|---|
| Move | Arrows, PgUp / PgDn | D-pad, LB / RB |
| Open / play | `Enter` | A |
| Back / close | `Esc`, Backspace, mouse-back | B |
| Watched / queue | `M` / `A` | X / Y |
| Sort | `S` | Start |
| Search | `F` (edit with ← → Home End Del, ↓ to results) | – |
| Refresh / re-fetch art | `R` / `T` | – |
| Open / close | `Ctrl+P` / `Ctrl+W` | View |

## Configuration

Every option is explained in `webdav-browser.conf`. The ones most people change: `start_path`, `ui_scale`,
`home_card_pct`, `merge_seasons`, `poster_overrides`, `rd_api_token`, `next_episode_card`, `couch_mode`.

## Recommended/Used companion scripts

- [ModernZ](https://github.com/Samillion/ModernZ) – A sleek and modern OSC for mpv..
- [thumbfast](https://github.com/po5/thumbfast) – seek-bar thumbnails for uosc and other OSCs.
- [op-ed-pv-skip](https://github.com/awaken1ng/mpv-op-ed-pv-skip) or another chapter skipper – skips openings / endings; the next-episode card adapts to it.
- [autosubsync-mpv](https://github.com/joaquintorres/autosubsync-mpv) – fixes out-of-sync subtitles with one key.
- [Anime4K](https://github.com/bloc97/Anime4K) – GPU shaders that upscale anime sharply on a 4K screen.
- [hold-speed](https://github.com/0xSilentNeo/Hold-Speed) – A Lua script for mpv that mimics YouTube’s playback speed feature.

## Credits

Metadata and artwork from [TMDB](https://www.themoviedb.org) – this product uses the TMDB API but is not endorsed or
certified by TMDB. Anime matching via [AniList](https://anilist.co) and [Fribb/anime-lists](https://github.com/Fribb/anime-lists).
