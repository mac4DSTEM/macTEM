# Mac App Store listing: macTEM

Drafts for Paul's approval, kept current with the app; the name, the subtitle and the screenshots are his.

One plain UTF-8 file per App Store Connect field. Counts are characters (`wc -m` in a UTF-8 locale), no trailing newline in the limited fields.

- `name.txt`: 6 / 30
- `subtitle.txt`: 28 / 30
- `promotional-text.txt`: 162 / 170
- `description.txt`: 3881 / 4000 (plain text, no markdown)
- `keywords.txt`: 97 / 100 (comma-separated, no spaces after commas; no word from the name or subtitle, which Apple indexes already, and no other product names)
- `whats-new.txt`: 35 / 4000 (Apple does not show What's New for a first version; this is for the record and the first update)
- `category.txt`: primary Education, secondary Productivity (no limit)
- `urls.txt`: support, marketing and privacy policy URLs on mac4dstem.com (no limit)
- `age-rating.txt`: questionnaire answers, all None, rating 4+ (no limit)
- `app-privacy.txt`: Data Not Collected; macTEM has no network entitlement (no limit)
- `review-notes.txt`: 2660 / 4000; walks a reviewer through every room with Help > Open Demo Data

Every claim comes from the README and the app's code as of 2026-11-10; nothing from the roadmap. Every signed build is
sandboxed. The formats read with a file of the same name beside them (EDAX .spd and .lsd with their .spc, EDAX .up1 and
.up2 with their .ang, Oxford .ebsp with its .ctf) get that file through the related-item grant (`RelatedFileAccess`,
macTEM#395); open one of each in the signed store build before a submission. The texts leave out NORDIF Pattern.dat,
which asks for its folder once (macTEM#403) and has not been opened in a signed build yet, and JEOL .asw, whose other
files the sandboxed app is not given.
