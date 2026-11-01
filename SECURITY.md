# Security

macTEM is a desktop application that reads microscopy files you choose. It runs in the macOS App Sandbox, makes no
network connection, and has no telemetry or analytics. It reads and writes only the files you pick; security-scoped
bookmarks let it reopen them.

To report a vulnerability (a crafted file that crashes the app or escapes the sandbox, or a problem in the
redistributed HDF5 libraries), use GitHub's private reporting: the repository's **Security** tab, then *Report a
vulnerability*. Please do not open a public issue for it. You will get a reply in the advisory thread; fixes ship as a
normal release and are noted in `CHANGELOG.md`.
