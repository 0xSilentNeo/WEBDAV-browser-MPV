<div align="center">

# webdav-browser

**Your Real-Debrid library, inside mpv.**<br/>
Browse, search and play a WebDAV video library without leaving the player.<br/>
Built for Real-Debrid, works with any WebDAV server.

<br/>

![version](https://img.shields.io/badge/version-26.11-1f6feb?style=flat-square)
![mpv](https://img.shields.io/badge/mpv-0.37%2B-6e40c9?style=flat-square)
![lua](https://img.shields.io/badge/Lua-script-2c2d72?style=flat-square&logo=lua&logoColor=white)
![tmdb](https://img.shields.io/badge/artwork-TMDB-01b4e4?style=flat-square&logo=themoviedatabase&logoColor=white)

[Install](#Install) · [Features](#Features) · [Keys](#Keys) · [Settings](#Settings) · [Changelog](CHANGELOG.md)

</div>

<br/>

## Two editions

Pick one, or install both side by side. They share one config file and one watch history.

<div align="center">

| | Edition | Look | Opens with |
|:-:|---|---|:-:|
| 🎬 | `webdav-browser-posters.lua` | Netflix-style posters, title pages, episode stills | `Ctrl+P` |
| 📁 | `webdav-browser.lua` | A fast two-panel list: Folders │ Files | `Ctrl+W` |

<img width="85%" alt="The poster edition" src="https://github.com/user-attachments/assets/7c1c5cee-3bd2-48e4-b5d4-f46a209ba23e" />
<br/><sub><b>Poster edition</b></sub>
<br/><br/>
<img width="85%" alt="The list edition" src="https://github.com/user-attachments/assets/fede1596-b8ff-4095-a579-49964efa24d1" />
<br/><sub><b>List edition</b></sub>

</div>

<br/>

## Install

1. Copy the `.lua` file(s) into `<mpv config>/scripts/` (on Windows, `%APPDATA%\mpv\scripts\`).
2. Copy `webdav-browser.conf` into `<mpv config>/script-opts/` and fill in your login:
   ```ini
   user=YOUR_REAL_DEBRID_USERNAME
   pass=YOUR_WEBDAV_PASSWORD
   ```
3. **Poster edition:** add a free TMDB key as `tmdb_key=` (themoviedb.org → Settings → API).
4. Press `F1`. The **setup check** tests every service and folder for real and tells you what to change if
   something fails.

**Needs** `curl` (built into Windows 10 and later). **Recommended:** ffmpeg for much faster artwork, and
`vo=gpu-next` in `mpv.conf` for the frosted-glass blur behind the cards.

<details>
<summary><b>Optional extras for the poster edition</b></summary>
<br/>

| Add | What it unlocks |
|---|---|
| `rd_api_token=` ([real-debrid.com/apitoken](https://real-debrid.com/apitoken)) | Adding releases, and the reason a missing episode is missing |
| `addon_urls=` | Your Stremio add-on manifests (AIOStreams, Comet, Torrentio…) for the add screen |
| [rqbit](https://github.com/ikatson/rqbit/releases) | Streams the torrents Real-Debrid refuses. Rename the Windows build to `rqbit.exe` and put it next to `mpv.exe` |

</details>

> [!NOTE]
> Your login reaches curl through a small file next to the data file (`webdav_browser_curl.cfg`), so it never shows up
> in mpv's log. mpv's own *verbose* log still records the playback login header, so trim it before sharing a full log.
> The `F1` report never contains it.

<br/>

## Features

### Everywhere
- **Clean titles** with `S01E03` and quality chips: 4K, HDR, DV, Atmos, Remux.
- **Continue Watching**, watched ticks, and resume with a start-over key.
- **Typo-tolerant search** with filters: `genre:anime  year:2010s  type:tv  rating:8  unwatched`, plus an optional
  index of every file name in your library.
- **Listings are cached** and refreshed quietly; folders Real-Debrid is still filling are re-checked until complete.
- **One click opens** a title or plays a file (`single_click_open`).

### Playback
- Following episodes play as a playlist, with the next one buffered ahead.
- **Up next** glass card with the episode still and a countdown ring, timed to the end credits (or to wherever your
  chapter-skip script jumps).
- **Now playing** card when a file starts. Resuming slides out "Resumed at 12:34 · B start over" beside it.
- Messages while playing (Retrying, Couldn't play, Buffering, Starting…) are glass pills too (`playback_toasts`).
- **Skip intro · S** while a named opening plays; S on the Up next card skips the credits.
- Audio and subtitle languages remembered per show (`remember_tracks`).
- If a stream fails, the file downloads while you watch, with a progress card. Files you've downloaded play from your
  computer (`play_local_first`).
- Every card can be switched off and placed in any corner. The player's own controller stays hidden while the browser
  is open over a video (`hide_osc`).

### Poster edition
| | |
|---|---|
| **Home** | Continue Watching (episode stills) and All Titles, sortable, with `★ 8.1 · 2024 · Series` under each card. Search right on the page, and filter chips for TV, Movies, Unwatched, ★ 8+, genres and decades. |
| **Title pages** | Rating, runtime, 4K/HDR/age chips, genres, "You have 61 of 366 episodes", the synopsis, and Play / Resume, Queue, Mark watched, Find more and Download. One card per episode with its TMDB still. |
| **Add from add-ons** (`N`) | Trending, streaming-service, airing-anime and new-season rows. Search any title, see every release from your add-ons with quality, codec, audio, languages and size, tick the files and add. Nyaa.si as a second source, and rqbit for torrents Real-Debrid refuses. |
| **Tracked shows** (`U`) | "+ Track" any show. Next episode, date and countdown in your time zone, a calendar view, a toast when something new is out, and a sound when it's actually cached and streamable. |
| **Downloads** | Tick files in a small popover and press **↓ Download**. A footer pill shows progress; the queue window (`Shift+D`) pauses, reorders, retries and removes. |
| **Smart matching** | Anime resolved through AniList, box sets get their TMDB collection, and missing episodes show greyed out with Real-Debrid's reason. |
| **Motion** | Posters fly into the title page and back, the rows glide, the selected card grows while the rest dims, and posters blur while moving so a 4K screen stays smooth. |
| **Looks** | Five themes (`classic` `graphite` `netflix` `rose` `ios`), title logos, a colour wash from the poster, rounded glass cards, sharp pictures on 4K, never stretched. |
| **Your way** | Mouse, keys or a gamepad (couch mode). `?` shows the keys of every page. |

<details>
<summary><b>More about the add screen</b></summary>
<br/>

- Every title gets a page laid out like the library's: **Search movie / show / anime on AIOStreams**, **Search
  Nyaa.si** (anime) and **+ Track**, with the next episode or release date and a row of its seasons or "More like
  this".
- Every season pack and complete-series pack is listed, sortable and filterable (`dual 1080 -hevc`).
- Each release shows folder and file name, cached or not, quality, codec, audio, languages, group and both sizes.
- You tick the files before anything is added, and releases already on your Real-Debrid are reused, never added
  twice.
- When the add-ons find only a few releases, a button offers Nyaa.si for the same title (`nyaa_fallback=ask`, or
  `auto` for anime).
- Releases Real-Debrid calls "infringing" stream through rqbit with a small progress card (`torrent_fallback`); a
  torrent nobody seeds says so.

</details>

<details>
<summary><b>More about tracked shows</b></summary>
<br/>

- The flyout shows the poster, next episode with date and countdown, "Date TBA", or a film's release date.
- Air times come from TVmaze (no key needed) and AniList for anime, shown in your own time zone (`track_air_times`,
  `clock_24h`).
- Checks run shortly after mpv starts and every few hours after; what's new arrives in one toast, with whether your
  add-ons already have it cached (`track_cached_check`).
- Once an episode airs, your add-ons are asked every 15 minutes until a cached release appears, then a toast and a
  sound tell you, even mid-video (`track_watch_release`, `track_poll_mins`, `track_sound`).
- Each show has a bell: every episode, new seasons only, or off. The pill's bell rings until you've looked
  (`track_bell_anim`).

</details>

<details>
<summary><b>Experimental, off unless you switch it on</b></summary>
<br/>

Each has its own setting. All of them are switched on in the conf that ships with the script, so you can try them.

| Setting | What it does |
|---|---|
| `experimental_mouse_ui` | Hover buttons on cards, clickable key hints, a right-click menu, a draggable scroll bar, full titles on hover, click-outside-to-close, sideways swipe |
| `experimental_row_drag` | Drag rows sideways; flick them, and they spring back at the ends |
| `experimental_glass_bars` | Top and bottom bars become thin floating pills |
| `experimental_video_glass` | The paused video shows, blurred, behind the browser |
| `experimental_rubberband` | A springy bounce at the end of a row or the page |
| `experimental_parallax` | Continue Watching pictures and episode stills float against the pointer |
| `experimental_caret` | A blinking cursor, and letters that fade in as you type *(both editions)* |
| `experimental_exit_to_video` | The page fades into the video as the browser closes *(both editions)* |
| `experimental_play_tilt` | The Play button tilts towards the pointer |
| `experimental_search_collapse` | The search pill rests as just its magnifier |
| `experimental_live_search` | Results follow every key you type |
| `experimental_chip_stagger` | Filter chips pop in one after another |
| `experimental_decode` | Titles and notices decode themselves in |

</details>

<br/>

## Keys

| | Keyboard / mouse | Gamepad |
|---|---|:-:|
| Open / close | `Ctrl+P` (posters) · `Ctrl+W` (list) | View |
| Move | Arrows, `PgUp` / `PgDn`, the wheel | D-pad, LB / RB |
| Open / play | `Enter`, or a click | A |
| Back / close | `Esc`, `Backspace`, mouse back | B |
| Watched / queue | `M` / `A` | X / Y |
| Sort | `S` | Start |
| Search | `F` | – |
| Add from add-ons | `N` | – |
| Refresh / re-fetch art | `R` / `T` | – |
| Whole synopsis | `I` | – |
| Downloads | `Shift+D` | – |
| Tracked shows | `U` | – |
| Keys of this page | `?` | – |
| Setup check | `F1` | – |
| Title menu | Right-click a card | – |

Every key can be changed in the conf (`key_up`, `key_open`, `key_back`…). The browser's keys only exist while it's
open.

<br/>

## Settings

Everything is explained in `webdav-browser.conf`, grouped by topic: connection, services, library, playback, cards,
look, poster screens, artwork, add-ons, torrents and keys. Settings added in each version sit at the end of the file
under "New in …", and a misspelt value falls back to its default with a line in mpv's log.

The ones people change most: `start_path` · `ui_scale` · `home_card_pct` · `merge_seasons` · `poster_overrides` ·
`theme` · `toast_theme` · `focus_style` · `transitions` · `next_card_position` · `now_playing_position` ·
`download_dir` · `play_local_first` · `track_shows` · `single_click_open` · `couch_mode`

<br/>


## Goes well with

- [ModernZ](https://github.com/Samillion/ModernZ): a sleek, modern OSC for mpv
- [thumbfast](https://github.com/po5/thumbfast): seekbar thumbnails (set `network=yes` in `thumbfast.conf` for streams)
- [op-ed-pv-skip](https://github.com/awaken1ng/mpv-op-ed-pv-skip): skips openings and endings; the Up next card adapts
  to it
- [autosubsync-mpv](https://github.com/joaquintorres/autosubsync-mpv): fixes out-of-sync subtitles with one key
- [Anime4K](https://github.com/bloc97/Anime4K): sharp anime upscaling on a 4K screen
- [hold-speed](https://github.com/0xSilentNeo/Hold-Speed): YouTube-style hold-to-speed-up

<br/>

---

<div align="center">
<sub>
Metadata and artwork from <a href="https://www.themoviedb.org">TMDB</a>. This product uses the TMDB API but is not
endorsed or certified by TMDB.<br/>
Anime matching via <a href="https://anilist.co">AniList</a> and
<a href="https://github.com/Fribb/anime-lists">Fribb/anime-lists</a> · Torrent streaming via
<a href="https://github.com/ikatson/rqbit">rqbit</a>
</sub>
</div>
