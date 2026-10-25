# Myra 3.0.4 — Redesigned Home, Tonight's pick and mood recommendations

- Home follows Apple's media-app layout. Search ("Search or ask Myra"), Pick
  Something, Myra AI, Filters and More are in the window toolbar; filters open
  in a popover with an active-filter summary. The sidebar is grouped into Watch
  Now, Library (Sources, Downloaded), Torrents (Transfers) and Myra (Settings).
- Up Next replaces Continue Watching with wide tiles showing progress and time
  left. Title cards are slimmer, with Play and Watchlist on hover and every
  other action in the ⋯ and right-click menus.
- The Myra AI menu is reduced to Recommend for Tonight, Ask Myra and Make a
  Collection. A multi-word search offers Ask Myra, which opens the assistant
  with that text; nothing is sent until the request is made.
- Home opens with a wide **Tonight's pick** backdrop banner that always shows a reason: one unwatched title for right
  now, with Play/Resume, **Another** (next suggestion) and **Why?** (the
  reasons behind it). Suggestions are ranked on this Mac from the selected
  mood, the time of day, an explicit or estimated time budget, viewing history,
  feedback and rating. No AI request is made.
- An **In the mood for** row offers eight presets — Cosy, Thrilling, Funny,
  Mind-bending, Feel-good, Something short, Background and Learn something.
  Choosing one adds a ranked mood shelf that respects the current Home filters.
- The banner and card menus add **More Like This**, **Less Like This** and
  **Not Tonight**. Not Tonight hides a title for about 18 hours. Feedback is
  stored in personal data and included in export; profiles from earlier
  versions load unchanged, and import-merge combines feedback.
- Watched, disliked and dismissed titles are never suggested, and an explicit
  time budget is never exceeded. Late weeknights use a shorter estimated
  budget; titles without a known runtime remain eligible only when the budget
  is estimated.

Validation on macOS 27.0.1: `zsh Scripts/verify-update.sh` passed end to end:
Swift format/lint, project-file lint and the full package suite (168 tests, 13
skipped, zero failures), including isolated recommender fixtures (constraints,
determinism, a 20,000-title runtime check, feedback persistence) and headless
renders of the redesigned Home, toolbar, Tonight banner, Why? popover and
feedback items. The Release build, version/build assertions (3.0.4, build 12),
deep strict code-signature check and `hdiutil verify` passed. Interactive use of
the new controls in a running app, hover states and native menus were not
exercised.

DMG SHA-256: `6a9e3226ff46d1a30c6ab113bbbcf40267c7412dc7d306999b938a49b7e84496`

Apple Silicon, macOS 14 or later. This personal build is ad-hoc signed, not
notarized. Install in Applications before updating; keep the previous app/DMG
for rollback. Existing categories, settings, downloads and personal library data
remain in their current locations.
