# CAB Data Contract

The CAB iOS app has **no backend of its own**. It consumes the same Cloudflare R2
JSON feeds that the CABReact web app uses. The backend is owned and updated by a
separate pipeline (Python cron jobs on a private VM) and must be treated as a
**versioned API contract**: if any shape below changes, both the web app and this
iOS app need to be updated in step.

Base host: `https://assets.cabroadcasting.com`

> **Status: verified against the live feeds (Nov 11, 2026).** Snapshots of each
> feed are saved as test fixtures in `CABTests/Fixtures/`, and the decoding tests
> in `CABTests/ModelDecodingTests.swift` check the models against them.
> Swift models: `CAB/Models/`.

> Note: In the web app, these feeds are fetched and aggregated server-side by
> Next.js API routes (`/api/data`, `/api/resources`), which also add caching (KV)
> and derive extra fields (duration in seconds, parsed dates). The iOS app has no
> server, so it performs the equivalent fetch, aggregation and parsing on-device
> (Tasks 3 and 4).

## Decoding rules (iOS)

- Unknown fields are ignored.
- A malformed element in an array (a show, an episode, a resource item, a
  now-playing item) is **skipped**, not fatal. One bad entry from the pipeline must
  not blank a whole screen.
- A missing or `null` array becomes an empty array.
- Field values are kept as the raw strings the feed sends. Dates, durations and
  URLs are parsed later (Task 3), so an odd value never fails decoding.

---

## 1. Shows index — `GET /audio/shows.json`

Returns a **JSON array** of show objects. Snapshot: 29 shows (2 `afr-stream`,
11 `afr-podcast`, 7 `fortis-podcast`, 9 `other-podcast`). In the live feed every
key is present on every show; values marked "nullable" are sent as `null`.

| Field              | Type            | iOS | Notes |
|--------------------|-----------------|-----|-------|
| `id`               | string          | required | Unique show id; routing key and resume key prefix. |
| `title`            | string          | required | Display title. |
| `category`         | string          | required | `afr-stream`, `afr-podcast`, `fortis-podcast`, or `other-podcast`. Kept as a raw string so a new category doesn't break decoding (`Show.knownCategory` is `nil` for unknown values). |
| `type`             | string          | optional | Feed source type: `afr-json`, `xml`, or `afr-stream`. Informational. |
| `order`            | number (int)    | optional | Sort order within the category, ascending. A non-number sorts last (decodes as `nil`). **In practice it's per category, not per show:** every live show in a category has the same value (`afr-stream` 1, `afr-podcast` 2, `fortis-podcast` 3, `other-podcast` 4). So on-screen order within a tab is the **feed order**, kept by a stable sort. To reorder shows in a tab, reorder them in `shows.json` (or start giving shows distinct `order` values). |
| `owner`            | string          | optional | Creator or ministry name. |
| `description`      | string          | optional | Long description. |
| `image`            | string (URL)    | optional | Square artwork. |
| `link`             | string (URL)    | optional | Creator website. |
| `url`              | string (URL)    | optional | **Streams:** the live stream URL (e.g. `https://mediaserver3.afa.net/talk.mp4`). **Podcasts:** the creator's original source feed. The app doesn't use it for podcasts. |
| `json_url`         | string \| null  | optional | **Podcasts:** URL of the episode feed (§2). `null` for streams. |
| `current_play_url` | string \| null  | optional | **Streams:** now-playing endpoint (§4). `null` for podcasts. |
| `update_interval`  | string \| null  | optional | **Streams:** poll interval in seconds, **sent as a string** (`"45"`, `"15"`). A number is also accepted. Default 30 when missing or invalid (Task 8). |
| `latest_update`    | string          | optional | ISO-8601 without timezone (`2026-11-11T14:06:01.112349`). Informational. |

Derived on-device (mirrors web `/api/data`, Task 3):
- `streamUrl` = `url` when `category === "afr-stream"`, else `null`.
- Shows are grouped by `category`; each group sorted by `order` ascending.
- A `showsById` lookup keyed by `id`.

Categories map to the Home screen tabs:
- `afr-stream` → "AFR Streams" (opens stream player)
- `afr-podcast` → "AFR Podcasts" (opens podcast player)
- `fortis-podcast` → "Fortis Podcasts" (opens podcast player)
- `other-podcast` → "Other Podcasts" (opens podcast player)

Live streams: `afr-talk` (now-playing every 45 s) and `afr-music` (every 15 s).
Show id `afr-music` should **not** seek to the live edge on play; all other
streams do.

---

## 2. Per-show episode feed — `GET <show.json_url>` (podcasts only)

Returns `{ "episodes": [...] }` with no other top-level keys. Snapshot: all 27
podcast feeds loaded, none empty, 702 episodes in total.

```json
{
  "episodes": [
    {
      "name": "Sharing the Gospel One Conversation at a Time",
      "owner": "American Family Radio",
      "date": "11/10/2026",
      "url": "https://streamer1.afa.net/.../ETW_20261110.mp3",
      "duration": "0:50:50"
    }
  ]
}
```

| Field      | Type   | iOS | Notes |
|------------|--------|-----|-------|
| `url`      | string | required | Direct audio URL (streamed, never re-hosted). Also the resume-position key. An episode without it is skipped. |
| `name`     | string | optional | Episode title. |
| `date`     | string | optional | `MM/DD/YYYY`, zero-padded (all 702 live episodes). |
| `duration` | string | optional | `H:MM:SS` in every live episode (e.g. `0:50:50`). `MM:SS` is still handled for safety. |
| `owner`    | string | optional | Present in `afr-json` feeds, **absent** in `xml` feeds. Not used by the web app. |

Derived on-device (mirrors web `/api/data`, Task 3):
- `durationSeconds` from `duration`:
  - 3 parts `H:MM:SS` → `h*3600 + m*60 + s`
  - 2 parts `MM:SS` → `m*60 + s`
  - 1 part → that number of seconds
  - unparseable → `null`
- `dateParsed`: `MM/DD/YYYY` → a local `Date`. Unparseable → `null`.
- Episode lists display **newest first** (by `dateParsed`, descending).
- A missing `episodes` key, or a feed that fails to load, means no episodes for
  that show (web: `payload.episodes || []`).

---

## 3. Resources — `GET /resources/resources.json`

Returns an object. Snapshot: 3 categories, 7 sources, 70 items.

```json
{
  "generatedAt": "2026-11-11T14:16:10.780883Z",
  "categories": [ { "id": "news", "label": "News & Commentary", "order": 1 } ],
  "sources": [ { "id": "fortis-news", "title": "Fortis Institute", "url": "https://fortisinstitute.org", "category": "news", "logo": "https://assets.cabroadcasting.com/resource_images/fortis-news.png" } ],
  "items": [ { "id": "alex-mcfarland-8c63939d8b7a", "sourceId": "alex-mcfarland", "category": "apologetics", "title": "...", "excerpt": "...", "url": "https://...", "author": "Alex McFarland", "publishedAt": "2026-11-11T18:58:17+00:00", "thumbnail": null } ],
  "stats": { "totalItems": 70, "sourcesSucceeded": 7, "sourcesFailed": 0 }
}
```

Top level: `generatedAt` (ISO-8601 UTC) is optional. `stats` is pipeline
metadata and is ignored by both apps.

**categories[]** — live ids: `news`, `teaching`, `apologetics`.
| Field   | Type   | iOS | Notes |
|---------|--------|-----|-------|
| `id`    | string | required | Matches `items[].category`. |
| `label` | string | required | Tab label. |
| `order` | number | optional | Ascending sort. |

**sources[]** (content providers)
| Field      | Type   | iOS | Notes |
|------------|--------|-----|-------|
| `id`       | string | required | Matches `items[].sourceId`. |
| `title`    | string | required | Provider name. |
| `url`      | string | optional | Provider website. |
| `category` | string | optional | The provider's primary category. |
| `logo`     | string | optional | Provider logo URL. Used as the card image when an item has no thumbnail. |

**items[]** (article cards)
| Field         | Type           | iOS | Notes |
|---------------|----------------|-----|-------|
| `id`          | string         | required | Unique item id. |
| `sourceId`    | string         | required | FK → `sources[].id`. Every live item references a known source. |
| `title`       | string         | required | Article title. |
| `url`         | string         | required | External article URL ("Read at source"), opened in in-app Safari. |
| `category`    | string         | optional | FK → `categories[].id`. |
| `excerpt`     | string         | optional | Short excerpt; often ends with `[…]`. |
| `author`      | string         | optional | Not shown by the web app. |
| `publishedAt` | string         | optional | ISO-8601. **Two formats occur:** with offset (`2026-11-11T18:58:17+00:00`, 60 items) and without (`2026-11-11T04:00:00`, 10 items). Offset-less values are read as **device-local** time, like the web app. They all fall at 04:00 or 05:00, which looks like midnight US Eastern in UTC with the `Z` dropped. Reading them as local keeps the right calendar date for US readers; reading them as UTC would show the day before. **Backend suggestion:** emit an explicit offset for these. |
| `thumbnail`   | string \| null | optional | `null` for 38 of 70 items. |

UI behavior (mirrors web `ResourceCard` and resources page):
- Card image = `thumbnail`, else the source's `logo`, else no image.
- Card shows title, excerpt, formatted `publishedAt` (e.g. "Nov 11, 2026"), the
  source title (fallback: `sourceId`), and a "Read at source" link.
- Tabs: "All" + each category sorted by `order`.
- The provider filter lists only providers with **at least one item**, sorted by title.
- Content is never re-hosted; articles link back to the source.

---

## 4. Stream now-playing — `GET <show.current_play_url>` (streams only)

Hosted by AFR (`afr.net`), **not** by `assets.cabroadcasting.com`. Polled every
`update_interval` seconds (default 30). Only `items[0]` is used.

Talk (`afr-talk`):
```json
{"items":[{"id":91891,"showName":"Grace to You with John MacArthur","startTime":"6:30PM","endTime":"7:00PM","amPm":"PM","link":"https://www.gty.org/","dayS":"Weekdays","showImage":null,"playsMusic":false}]}
```

Music (`afr-music`, URL includes `IncludeMusic=true`):
```json
{"items":[{"id":92001,"showName":"Music","startTime":"9:30AM","endTime":"12:00AM","amPm":"AM","link":null,"dayS":"Weekdays","showImage":null,"playsMusic":true,"song":{"id":442048,"artist":"Ryan Stevenson","title":"Reflection","album":"Flying","albumArt":"https://...450x450bb.jpg","storeUrl":"https://music.apple.com/..."}}]}
```

| Field           | Type    | iOS | Notes |
|-----------------|---------|-----|-------|
| `playsMusic`    | bool    | optional | Branch selector (see below). |
| `showName`      | string  | optional | Program name. |
| `startTime`     | string  | optional | e.g. `6:30PM`. |
| `endTime`       | string  | optional | e.g. `7:00PM`. |
| `song`          | object  | optional | Present only on music items. |
| `song.title`    | string  | optional | |
| `song.artist`   | string  | optional | |
| `song.album`    | string  | optional | Not used by the web app. |
| `song.albumArt` | string  | optional | Not used by the web app. Candidate for lock-screen artwork (Task 9). |

Ignored: `id`, `amPm`, `link`, `dayS`, `showImage`, `song.id`, `song.storeUrl`.

Display mapping (mirrors web, Task 8):
- `playsMusic === false` → primary = `showName` (or "Live audio"), secondary = `startTime - endTime`.
- otherwise → primary = `song.title` (or "Live music"), secondary = `song.artist`.

This same primary/secondary pair feeds the lock-screen, Control Center and
CarPlay now-playing metadata for streams.

---

## Caching (parity with web TTLs)

| Feed               | Web KV TTL | iOS on-device cache target |
|--------------------|------------|----------------------------|
| shows (aggregated) | 5 min      | 5 min |
| resources          | 15 min     | 15 min |
| now-playing        | not cached (polled) | not cached (polled) |

---

## Change management

- Treat this file as the source of truth for the shared data shapes.
- If the backend changes a field, update this file, both consuming apps, and the
  fixtures in `CABTests/Fixtures/`. Refreshing fixtures means updating the
  snapshot counts asserted in `ModelDecodingTests`.
- Unknown or extra fields must be tolerated (decode leniently; ignore what you don't use).
