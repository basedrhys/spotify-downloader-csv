# YouTube download troubleshooting findings

Investigated 2026-08-21 while downloading a 310-song Chosic CSV. Three separate
failures surfaced in sequence. Recording them here because two are still latent
and the third depends on a YouTube experiment that may change.

Environment at time of investigation: yt-dlp `2026.03.13`, yt-dlp-ejs `0.7.0`,
Deno `2.9.5`, pytube `15.0.0`, ffmpeg `8.1.2`, Python 3.13.14, macOS 26.4.1.

## 1. "You are blocked by YouTube Music" — false positive (FIXED)

**Symptom:** `DownloaderError: You are blocked by YouTube Music. Please use a VPN,
change youtube-music to piped, or use other audio providers` before any song was
touched.

**Root cause:** The preflight gate at `spotdl/console/entry_point.py:97-103` calls
`check_ytmusic_connection()`, which searched with **no `filter`**, while the actual
download path passes `filter="songs"` and `filter="videos"` via
`YouTubeMusic.GET_RESULTS_OPTS` (`spotdl/providers/audio/ytmusic.py:22-25`).

An unfiltered YTM search returns mostly artist/album/playlist cards.
`get_results` discards any row without a `videoId` and `artists`
(`ytmusic.py:62-67`), so the list came back empty and looked identical to a block.

Measured against live YouTube Music:

| Call | Result |
| --- | --- |
| unfiltered `search("a")` (what the gate did) | 1 row, a playlist → 0 after filtering |
| `filter="songs"` (what downloads do) | 60 results |

**Fix:** `spotdl/utils/downloader.py` now iterates `GET_RESULTS_OPTS` so the check
queries the same way the downloader does. Regression test in
`tests/utils/test_downloader.py` asserts a filter is passed.

**Note:** the gate is a hard abort, so `--audio youtube-music youtube` never
reaches its fallback provider. Worth knowing if the gate misfires again.

## 2. `KeyError: 'webCommandMetadata'` in the `youtube` provider (NOT FIXED)

**Symptom:** With `--audio youtube`, some songs failed with `KeyError:
'webCommandMetadata'` immediately followed by `LookupError: No results found for
song: ...`. Roughly 4 of 310, a different set each run.

**Root cause:** `spotdl/providers/audio/youtube.py` searches via `pytube.Search`,
not yt-dlp. `pytube/contrib/search.py:171-172` unconditionally indexes:

```python
vid_channel_uri = vid_renderer['ownerText']['runs'][0][
    'navigationEndpoint']['commandMetadata']['webCommandMetadata']['url']
```

Some result rows are livestream/promo cards whose owner action opens a dialog
rather than linking to a channel. Their `navigationEndpoint` is a
`showDialogCommand` and `commandMetadata` contains only
`interactionLoggingCommandMetadata` — no `webCommandMetadata`, because the row
does not navigate to a URL.

Confirmed example: searching `Disco Lines Push It` returns a row titled
"Disco Lines Live @ Coachella Day 0 2026" that triggers this in every attempt.
One such row raises, which kills the **entire** search for that song — the same
response also held 17 usable video rows.

pytube also silently drops YouTube's newer `lockupViewModel` rows
(`Unexpected renderer encountered`), so this provider loses candidates even when
it doesn't crash. pytube 15.0.0 is the last release (Jul 2023); the project is
abandoned.

**Status:** left as-is, because the `youtube-music` provider is the better path
anyway (it supports ISRC matching; `YouTube.SUPPORTS_ISRC = False`). If this
provider is ever needed, the durable fix is replacing pytube search with yt-dlp's
`ytsearch:` rather than patching pytube's parsing.

## 3. `YT-DLP download error` — PO Token requirement (WORKED AROUND)

**Symptom:** `AudioProviderError: YT-DLP download error - <url>` for a shifting
subset of songs. Search and matching succeeded; the failure was at download.

**Dead ends ruled out first:**

- Not throttling. Persisted with `--threads 1 --delay 5` and browser cookies.
- Not video-specific. All failing tracks resolved to format 251 / https / webm /
  `has_drm=False`, identical to tracks that succeeded.
- Not stale partials. `~/.spotdl/temp/` was empty.
- Not signature solving, auth, or geo. Metadata extraction succeeded for every
  failing URL.

**Root cause:** YouTube runs a per-video experiment binding a GVS PO Token to the
`web_music` client. Visible only with verbose yt-dlp output:

```
[debug] [youtube] [pot] PO Token Providers: none
[debug] [youtube] Detected experiment to bind GVS PO Token to video ID for web_music client
WARNING: web_music client https formats require a GVS PO Token which was not provided.
         They will be skipped as they may yield HTTP Error 403.
ERROR: Requested format is not available.
```

With no PO token provider installed, every https audio format is skipped. spotdl
requests bare `bestaudio` (`spotdl/providers/audio/base.py:101`), nothing
audio-only survives, and yt-dlp raises `Requested format is not available`.

Two things made this hard to see:

- `spotdl/providers/audio/base.py:395-397` logs the real exception at
  `logger.debug` and re-raises a generic `YT-DLP download error - <url>`.
- `base.py:106` sets `no_warnings: True`, suppressing the PO token warning that
  explains it.

Because the experiment is per-video, only a subset failed and the set shifted
between runs. Cookies made it worse: they select the `web_music` client, which is
the one under the experiment. Without cookies the format was selected but the
transfer 403'd — the same underlying cause, failing one stage later.

**Fix:** use the `web_embedded` client, which is not subject to the experiment.
Tested all nine clients against the failing tracks:

| Client | Result |
| --- | --- |
| `tv`, `ios`, `android`, `android_vr`, `mweb`, `web`, `tv_embedded`, default | Requested format is not available |
| `web_embedded` | format 251, opus, 130-149 kbps, no PO token warning |

Set permanently in `~/.spotdl/config.json` (outside this repo):

```json
"yt_dlp_args": "--extractor-args \"youtube:player_client=web_embedded\"",
```

Verified via `get_config()` that this resolves to
`{'youtube': {'player_client': ['web_embedded']}}` while spotdl's own `format`
and `retries` defaults survive the merge in
`args_to_ytdlp_options` (`spotdl/utils/formatter.py:609-636`). Any yt-dlp CLI flag
can be passed this way, since that function delegates to yt-dlp's own
`parse_options`.

**Rejected alternative:** adding `/best` to the mp3 format selector at
`base.py:96-101` (the m4a and opus branches already have `/bestaudio/best`; the
mp3 branch is bare `bestaudio`). It does clear the error, but falls back to format
18 at roughly 96 kbps AAC — a silent quality downgrade. Selecting the right client
keeps 130-149 kbps opus.

**If this returns:** update yt-dlp first. `2026.03.13` was already flagged as more
than 90 days old, and PO token handling changes frequently upstream. The
`web_embedded` workaround holds only while YouTube leaves that client out of the
experiment. The real fix is a PO token provider plugin.

**Update 2026-10-08:** it returned. YouTube extended the experiment to `web_embedded`, and upgrading yt-dlp fixed it. See section 4.

## 4. `web_embedded` pulled into the experiment (FIXED by upgrading yt-dlp)

Investigated 2026-10-08 while refreshing five playlists with `scripts/download-playlists.zsh`. Environment: yt-dlp `2026.03.13` → `2026.08.19`, yt-dlp-ejs `0.7.0` → `0.8.0`, Deno `2.9.5`.

**Symptom:** the section 3 error again, for every new track. The first two playlists downloaded 0 of 13 new tracks, each failing with `AudioProviderError: YT-DLP download error - <url>`.

**Root cause:** YouTube extended the GVS PO Token experiment from section 3 to the `web_embedded` client that section 3 switched to. Running yt-dlp `2026.03.13` directly, a `-v --simulate` pass logged `Detected experiment to bind GVS PO Token to video ID for web_embedded client` and still selected format 251. The real download moments later failed:

```
WARNING: [youtube] <id>: Some web_embedded client https formats have been skipped as they are missing a URL. YouTube may have enabled the SABR-only streaming experiment for the current session. See  https://github.com/yt-dlp/yt-dlp/issues/12482  for more details
ERROR: [youtube] <id>: Requested format is not available. Use --list-formats for a list of available formats
```

That pair shows the failing set shifting between sessions, as in section 3. A later `-g` probe of five failing videos resolved four of them.

**Fix:** upgrade yt-dlp to `2026.08.19` and yt-dlp-ejs to `0.8.0` in `uv.lock` (`pyproject.toml` already allowed both). Measured with `yt-dlp -f bestaudio -g`, which resolves the media URL without transferring it, on five videos that had failed:

| yt-dlp | Client | URLs resolved |
| --- | --- | --- |
| `2026.03.13` | `web_embedded` | 4 of 5 |
| `2026.08.19` | `web_embedded` | 5 of 5 |
| `2026.08.19` | default | 5 of 5 |

`web_embedded` works with the new yt-dlp, so it stays in the script and in `~/.spotdl/config.json`.

**Result:** the first full run downloaded 34 of 38 new tracks. The other 4 failed with the same generic error and all succeeded on one retry, which fits the per-session experiment rather than a hard block. A re-run then reported +0 new and 0 error lines for all five playlists. All 38 new files have cover art, run over 60 s and are at least 120 kbps.

The tests that stream a YouTube URL through FFmpeg (`test_ffmpeg.py::test_convert`, `test_metadata.py::test_embed_metadata`) hit live YouTube and are flaky. Across two runs per version, `test_convert` and `test_embed_metadata[flac]` failed both times on `2026.03.13` and passed both times on `2026.08.19`. No test passed on the old version and failed on the new one.

**If this returns:** same order as section 3. Update yt-dlp, then probe with `-g` across clients. A PO token provider plugin is still the durable fix.

### Running downloads inside a Claude Code session

The Apple Claude Code (ACC) network proxy allows only listed domains. Search and metadata need `music.youtube.com` and `www.youtube.com` (allowlisted 2026-08-21). The audio comes from `*.googlevideo.com` and cover art from `i.ytimg.com`. Until `googlevideo.com` and `ytimg.com` were allowlisted on 2026-10-08, transfers failed with `Unable to connect to proxy ... Tunnel connection failed: 403 Forbidden`, a failure spotdl's generic wrapper (section 3) also hides. The 2026-08-21 session's proxy log shows the same `googlevideo.com` blocks. Lyrics hosts (`api.genius.com`, `www.musixmatch.com`, `www.azlyrics.com`) stay blocked. That only leaves lyrics out, and the existing files checked had none.

Claude Code sessions on this machine have `UV_DEFAULT_INDEX` and `UV_INDEX_URL` set to the internal mirror. They are not set in `~/.zshrc`, `~/.zprofile`, `~/.zshenv` or `~/.config/uv/uv.toml`. This repo resolves from public PyPI, but in those sessions a plain `uv run` or `uv lock` re-locks all 117 package sources onto the mirror. Run with `UV_FROZEN=1` instead, e.g. `UV_FROZEN=1 ./scripts/download-playlists.zsh`. The proxy also blocks `files.pythonhosted.org`, so a lock update inside a session has to resolve through the mirror and then point the registry and file URLs back at `pypi.org` and `files.pythonhosted.org`. The mirror serves the same files at the same paths with the same hashes, so the diff for this upgrade was just 6 changed lines.

## Diagnostic techniques that worked

**Get the real error.** spotdl hides it. Either add `--log-level DEBUG`, or cut
spotdl out entirely and run yt-dlp directly:

```bash
uv run yt-dlp -f bestaudio -v -o '/tmp/ytdlp-probe/%(id)s.%(ext)s' \
  'https://music.youtube.com/watch?v=<id>'
```

**Separate extraction from transfer.** `extract_info(url, download=False)` tests
metadata and format selection with no media transfer. If that succeeds and the
download fails, the problem is format availability or the byte transfer, not
auth/geo/signatures.

**Cookies.** yt-dlp reads them directly; no export needed. `--cookies-from-browser
chrome` works (decrypts via Keychain, with Chrome running).
`--cookies-from-browser safari` fails: the file exists at
`~/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies`
and is mode `-rw-r--r--`, but reads return `PermissionError [Errno 1] Operation
not permitted` — macOS TCC, not POSIX. Safari would need Full Disk Access granted
to the terminal. Cookies were not needed in the end, and hurt (see above).

## Unrelated pre-existing breakage

`tests/conftest.py:14` calls `SpotifyClient.init(client_id, client_secret)`
positionally, but the post-Spotify-removal stub is `init(cls, **kwargs)` and
raises `RuntimeError` regardless (`spotdl/utils/spotify.py:26-34`). This makes
`uv run pytest` fail at collection for **every** test. Tests in this branch were
verified with `--noconftest`.
