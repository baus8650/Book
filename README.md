# Next Chapter

A native SwiftUI iPhone/iPad app for following authors and tracking upcoming books. iOS 16+, no third-party dependencies. Catalog search and release lookup now use Hardcover instead of Google Books.

## Configure catalog access (app operator)

Readers can browse upcoming releases and search without a Hardcover account or API login. The app uses a read-only backend that adds your Hardcover API token on the server. The existing OAuth client ID is public registration metadata, not a catalog credential.

The phone app is configured to use `https://catalog-production-5f6f.up.railway.app/catalog` in Debug and Release. The gateway is deployed as a Railway Function, with its source saved in `Backend/railway.ts`.

1. Obtain your API token from https://hardcover.app/account/api.
2. In the Next Chapter Railway project, open the catalog service → Variables and add `HARDCOVER_API_TOKEN`. Apply the variable change so Railway redeploys the service.
3. Rebuild and run the app on your phone. Readers do not need a Hardcover login.

Railway service: https://railway.com/project/719a605f-a342-4ec4-8e34-5f7b5c97eab9/service/c8427a96-d0cb-472e-945e-7494a238ba59?environmentId=2f7266ac-9d48-4e34-81cb-3a3ded4ef1ae

`GET /health` reports whether the token is configured without exposing it. Token configuration is still required before live catalog requests succeed. The gateway allows only known catalog queries, validates variables, caches results for 15 minutes, and spaces upstream requests. Credentials are never embedded in the app. Multiple readers share the operator’s provider quota.

The Python gateway remains available for other hosts: configure `HARDCOVER_API_TOKEN`, run `python3 Backend/server.py` (Python 3.9+), and put it behind HTTPS. Change `CATALOG_API_URL` in both Xcode build configurations if moving hosts.

## Run on an iPhone

1. Open `NextChapter.xcodeproj` in Xcode.
2. Select the target → Signing & Capabilities, choose your Apple development team, and use a unique bundle identifier.
3. Select an iPhone simulator and press Run, or connect your iPhone and choose it as the destination.
4. Configure the catalog backend URL as above.
5. Enable release-day reminders in Following when ready.

TestFlight distribution requires an Apple Developer account plus release testing. App Store distribution also needs an icon, screenshots, privacy disclosures, and review.

## Included

- Hardcover author and book search, with separate Authors/Books controls.
- Following by Hardcover author ID. Existing saved author names are resolved to an exact catalog match on refresh; ambiguous/unmatched names are reported so you can search and select the correct author.
- Upcoming shows the next 100 catalog releases by date, including authors you do not follow. Following is optional and controls reminders.
- Local persistence of authors, cached books, and manual entries. Failed refreshes keep cached data.
- Manual announced-book entry; swipe a manual entry to delete it and re-add with a revised date.
- Opt-in local release-day notifications at 9 AM (up to 60 upcoming books).
- Provider errors for missing server configuration, expired server credentials, permissions, and quota states.

## Limits

Hardcover coverage depends on its catalog and is not guaranteed to include every upcoming announcement. The app uses a book's original publication date, not separate regional/format edition dates. Multiple new editions of an already-published work do not generate release alerts. Entries with no complete date do not schedule reminders. Manual announcements remain useful when catalog metadata is missing.

Updates happen when the app opens, becomes active, or is refreshed. The catalog gateway handles requests; there is no background release discovery, push delivery, or cross-device synchronization. Reminders only cover known dates. Open the app regularly to fetch new announcements and reschedule changed dates.

## Verification

Regression checks use a stub HTTP transport and validate backward-compatible saved-author decoding, author IDs, search variables/mapping, the future-date query, empty results, and authentication/quota/GraphQL error handling. Run:

```sh
swiftc NextChapter/Models.swift NextChapter/HardcoverService.swift Tests/HardcoverServiceCheck.swift -o /tmp/nextchapter-hardcover-check
/tmp/nextchapter-hardcover-check
```

Catalog checks cover author migration, author-specific queries, browsing with no author filter, search mapping, and provider errors. Live catalog access requires the operator’s deployed gateway and API token. Test reminders and persistence on a real iPhone before distribution.

## Official documentation

- Access and limits: https://github.com/hardcoverapp/hardcover-docs/blob/main/src/content/docs/api/Getting-Started.mdx
- Native OAuth: https://github.com/hardcoverapp/hardcover-docs/blob/main/src/content/docs/api/OAuth/Getting-Started-Device.mdx
- Search: https://github.com/hardcoverapp/hardcover-docs/blob/main/src/content/docs/api/guides/Searching.mdx
- Catalog scopes: https://github.com/hardcoverapp/hardcover-docs/blob/main/src/content/docs/api/GraphQL/Actions.mdx
- Book fields: https://github.com/hardcoverapp/hardcover-docs/blob/main/src/content/docs/api/GraphQL/Schemas/Books.mdx
