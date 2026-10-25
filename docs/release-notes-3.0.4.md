# Myra 3.0.4 — Tonight's pick and mood recommendations

- Home opens with a **Tonight's pick** banner: one unwatched title for right
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

Validation on macOS 27.0.1: `zsh Scripts/verify-update.sh` passed Swift
format/lint, project-file lint and the full package suite (168 tests, 13
skipped, zero failures), including isolated recommender fixtures (constraints,
determinism, a 20,000-title runtime check, feedback persistence) and headless
Home/Why/feedback renders. The Release build, deep strict code-signature check
and `hdiutil verify` passed. The final build-number assertion in the script
initially still expected build 11. After it was corrected to 12, that check
and the remaining signature and linkage checks were run against the same DMG
and passed. Interactive use of the new Home controls in a running app, and
native context menus, were not exercised.

DMG SHA-256: `3aef39d5338536908f362bf343cdb34b1cb3239f6c74e05ec7457ee3f468b473`

Apple Silicon, macOS 14 or later. This personal build is ad-hoc signed, not
notarized. Install in Applications before updating; keep the previous app/DMG
for rollback. Existing categories, settings, downloads and personal library data
remain in their current locations.
