# CAB Data Contract

The CAB iOS app has **no backend of its own**. It consumes the same Cloudflare R2
JSON feeds that the CABReact web app uses. The backend is owned and updated by a
separate pipeline (Python cron jobs on a private VM) and must be treated as a
**versioned API contract**: if any shape below changes, both the web app and this
iOS app need to be updated in step.

Base host: `https://assets.cabroadcasting.com`

> Note: In the web app, these feeds are fetched and aggregated server-side by
> Next.js API routes (`/api/data`, `/api/resources`) which also add caching (KV)
> and derive extra fields (duration in seconds, parsed dates). The iOS app has no
> server, so it performs the equivalent fetch + aggregation + parsing on-device.
> See Task 3/Task 4 in the project plan.

---

## 1. Shows index — `GET /audio/shows.json`

Returns a **JSON array** of show objects.

| Field              | Type   | Notes |
|--------------------|--------|-------|
| `id`               | string | Unique show id; used in routing and as cache/resume key prefix. |
| `title`            | string | Display title. |
| `owner`            | string | Creator/ministry name (shown as subtitle). May be absent. |
| `image`            | string | Absolute URL to artwork (square). |
| `description`      | string | Long description (shown in the About/description sheet). |
| `category`         | string | One of: `afr-stream`, `afr-podcast`, `fortis-podcast`, `other-podcast`. |
| `order`            | number | Sort order within its category (ascending). May be absent → sorts last. |
| `url`              | string | **Streams only** (`category === "afr-stream"`): the live stream URL. |
| `json_url`         | string | **Podcasts only**: URL of this show's episode feed (see §2). |
| `current_play_url` | string | **Streams only**: now-playing metadata endpoint (see §4). Optional. |
| `update_interval`  | number \| string | **Streams only**: now-playing poll interval in seconds. Default 30 when absent/invalid. |

Derived on-device (mirrors web `/api/data`):
- `streamUrl` = `url` when `category === "afr-stream"`, else `null`.
- Shows are grouped by `category`; each group sorted by `order` ascending.
- A `showsById` lookup is built keyed by `id`.

Categories map to the Home screen tabs:
- `afr-stream` → "AFR Streams" (opens stream player)
- `afr-podcast` → "AFR Podcasts" (opens podcast player)
- `fortis-podcast` → "Fortis Podcasts" (opens podcast player)
- `other-podcast` → "Other Podcasts" (opens podcast player)

Special case: show id `afr-music` is a stream that should **not** seek to the live
edge on play (all other streams do).

---

## 2. Per-show episode feed — `GET <show.json_url>` (podcasts only)

Returns an object:

```json
{
  "episodes": [
    {
      "name": "Episode title",
      "url": "https://.../episode.mp3",
      "date": "10/14/2026",
      "duration": "1:02:33"
    }
  ]
}
```

| Field      | Type   | Notes |
|------------|--------|-------|
| `name`     | string | Episode title. |
| `url`      | string | Direct audio URL (streamed, never re-hosted). Also the resume-position key. |
| `date`     | string | Format `MM/DD/YYYY`. |
| `duration` | string | Format `H:MM:SS` or `MM:SS`. |

Additional fields may be present and should be ignored if unrecognized.

Derived on-device (mirrors web `/api/data`):
- `durationSeconds` — parsed from `duration`:
  - 3 parts `H:MM:SS` → `h*3600 + m*60 + s`
  - 2 parts `MM:SS` → `m*60 + s`
  - 1 part → that number of seconds
  - unparseable → `null`
- `dateParsed` — `MM/DD/YYYY` → a `Date` (local). Unparseable → `null`.
- Episode lists are displayed **newest first** (sorted by `dateParsed` descending).

---

## 3. Resources — `GET /resources/resources.json`

Returns an object with three arrays:

```json
{
  "categories": [ { "id": "...", "label": "...", "order": 0 } ],
  "sources":    [ { "id": "...", "title": "...", "image": "..." } ],
  "items":      [ { "id": "...", "sourceId": "...", "category": "...", "title": "...", "excerpt": "...", "url": "..." } ]
}
```

**categories[]**
| Field   | Type   | Notes |
|---------|--------|-------|
| `id`    | string | Category id (matches `items[].category`). |
| `label` | string | Display label (tab). |
| `order` | number | Ascending sort. |

**sources[]** (content providers)
| Field   | Type   | Notes |
|---------|--------|-------|
| `id`    | string | Source id (matches `items[].sourceId`). |
| `title` | string | Provider name. |
| `image` | string | Provider logo URL (optional). |

**items[]** (article cards)
| Field      | Type   | Notes |
|------------|--------|-------|
| `id`       | string | Unique item id. |
| `sourceId` | string | FK → `sources[].id`. |
| `category` | string | FK → `categories[].id`. |
| `title`    | string | Article title. |
| `excerpt`  | string | Short excerpt (web shows up to ~50 words). Optional. |
| `url`      | string | External article URL — opened in in-app Safari (`SFSafariViewController`). |

UI behavior (mirrors web resources page):
- Tabs: "All" + each category (sorted by `order`).
- A provider filter lists only providers that have **at least one item**, sorted by title.
- Articles link back to the source; content is never re-hosted.

---

## 4. Stream now-playing — `GET <show.current_play_url>` (streams only)

Polled every `update_interval` seconds (default **30**). Returns:

```json
{
  "items": [
    {
      "playsMusic": true,
      "showName": "Program name",
      "startTime": "9:00 AM",
      "endTime": "10:00 AM",
      "song": { "title": "Song title", "artist": "Artist name" }
    }
  ]
}
```

Only the **first** item (`items[0]`) is used.

| Field        | Type    | Notes |
|--------------|---------|-------|
| `playsMusic` | bool    | Branch selector (see below). |
| `showName`   | string  | Program name (used when `playsMusic === false`). |
| `startTime`  | string  | Program start (used when `playsMusic === false`). |
| `endTime`    | string  | Program end (used when `playsMusic === false`). |
| `song.title` | string  | Song title (used when `playsMusic !== false`). |
| `song.artist`| string  | Artist (used when `playsMusic !== false`). |

Display mapping (mirrors web):
- `playsMusic === false` → primary = `showName` (or "Live audio"), secondary = `startTime - endTime`.
- otherwise → primary = `song.title` (or "Live music"), secondary = `song.artist`.

This same primary/secondary pair feeds the lock-screen / Control Center / CarPlay
now-playing metadata for streams.

---

## Caching (parity with web TTLs)

| Feed            | Web KV TTL | iOS on-device cache target |
|-----------------|-----------|----------------------------|
| shows (aggregated) | 5 min  | 5 min |
| resources          | 15 min | 15 min |
| now-playing        | not cached (polled) | not cached (polled) |

---

## Change management

- Treat this file as the source of truth for the shared data shapes.
- If the backend changes a field, update this file and both consuming apps.
- Unknown/extra fields must be tolerated (decode leniently; ignore what you don't use).
