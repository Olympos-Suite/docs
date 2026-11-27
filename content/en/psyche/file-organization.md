---
title: "File Organization"
description: "How completed downloads become library files: folder templates, canonical naming, NFO and artwork sidecars, and file links."
section: "User Guide"
order: 80
---

The file organizer is the last pipeline stage: it turns completed downloads into library files. Because Psyche is [metadata-first](./invariants#metadata-first), the organizer **never creates, re-scores, or re-identifies entities**. It resolves each queue row → release request → subscription → the **pre-existing entity**, then moves and links files to it. The target season/episode comes from the request; release-name parsing only *confirms* pack file names.

## When organization runs

The **library-organizer** job sweeps every 5 minutes (essential — it cannot be stopped). It processes queue rows in `completed` or `seeding` state:

1. Resolve the linkage (request → subscription → entity). Rows with incomplete linkage are skipped with a warning.
2. List the torrent's files on the client and select the video files.
3. Move the torrent's data into the library layout **via the client** (`setTorrentLocation`), then rename files in-torrent — seeding metadata stays intact.
4. Persist one file-link row per linked file.
5. Write best-effort NFO + poster sidecars from cached metadata.

Each row is isolated: one bad row never fails the sweep. A row that maps zero files keeps its status with an error message, so the next sweep retries. Organized rows are terminal; the [retention sweep](./download-management#retention) later removes the redundant client copy.

## Folder templates

Two settings define the layout under the resolved library root ([Files & storage](./configuration#settings-groups)):

| Setting | Default template |
|---------|------------------|
| `files.folderStructureTv` | `{seriesTitle}/Season {seasonNumber}/{seriesTitle} - S{seasonNumber}E{episodeNumber}` |
| `files.folderStructureMovies` | `{movieTitle} ({year})/{movieTitle} ({year})` |

Available tokens:

| Template | Tokens |
|----------|--------|
| TV | `{seriesTitle}`, `{seasonNumber}`, `{episodeNumber}` |
| Movies | `{movieTitle}`, `{year}` |

Titles are sanitized for the filesystem; season/episode numbers are zero-padded (`Season 01`, `S01E02`). Only the **folder portion** of the template (everything before the last `/`) is expanded — the file-name portion is intentionally not applied, because canonical file names are owned by the linking logic (below). A missing token (a movie with no year) collapses its empty parenthetical, so the default reproduces `Title` / `Title (Year)` exactly.

The root itself comes from the [storage paths](./download-management#storage-paths) resolution (`tv`/`movies` usage), falling back to `library.seriesRoot` / `library.moviesRoot`.

With the default templates, an organized library looks like this:

```text
/media/tv/
  Show Name/
    tvshow.nfo
    poster.jpg
    Season 01/
      Show Name - S01E01.mkv
      Show Name - S01E02.mkv
/media/movies/
  Movie Name (2024)/
    movie.nfo
    poster.jpg
    Movie Name (2024).mkv
```

Sidecar file names (`tvshow.nfo`, `movie.nfo`, the poster copy) are fixed; only the folder layout and the canonical media file names follow the rules above and below.

## File naming

Renames happen **inside the torrent** (client-side `renameFile`), so the persisted paths are truthful and seeding continues:

- **Episodes** — `Series Title - S01E02.ext`. For episode requests the request's numbers win even if the file name disagrees (mismatches are debug-logged, linking proceeds). For season packs, each file must parse to an episode of the pack's season; files matching no episode row are skipped — **partial packs import only what they contain**. Anime packs numbered absolutely resolve against `episodes.absolute_number`.
- **Movies** — the **largest** video file becomes `Title (Year).ext`. Other video files (extras) keep their names and are linked in place inside the movie folder.

## NFO and artwork

After linking, the organizer writes minimal sidecars from **cached** TMDB metadata — best-effort, with its own guard, so a sidecar failure never fails organizing:

| Target | Files |
|--------|-------|
| Movie | `movie.nfo` + poster copy in the movie folder |
| Series | `tvshow.nfo` + poster copy in the **series** folder (parent of `Season NN`) |

The NFOs are Kodi-shaped minimal XML — enough for library managers to anchor the file. Posters come from the artwork cache (`/data/metadata/artwork`); a cold cache simply skips the copy — the organizer never fetches from TMDB itself.

## File links

Each linked on-disk file gets exactly one row:

| Table | Links to | Key columns |
|-------|----------|-------------|
| `episode_files` | episode (cascade) | `file_path` (absolute, UNIQUE), `size_bytes`, `quality_tag` |
| `movie_files` | movie (cascade) | `file_path` (absolute, UNIQUE), `size_bytes`, `quality_tag` |

`file_path` is unique — one file links exactly once. The `quality_tag` is parsed from the file name as **read-only provenance**; it is never used to re-score or re-identify anything. Deleting an entity cascades its file links (the files themselves are not deleted by that cascade).

## Orphan audit

Files can end up in your storage roots outside Psyche's links (manual copies, old imports). **Settings → Files & storage** exposes the library audit (`POST /api/library/audit`): it scans the active storage roots for orphan video files and distinguishes duplicates of linked files from unique orphans. A follow-up delete action (`POST /api/library/audit/delete`) removes selected orphans — only inside active storage roots, and **never linked files**.