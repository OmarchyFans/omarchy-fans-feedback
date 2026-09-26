# Changelog

The bar popup reads the newest sections of this file to tell you what changed
when an update is available. Keep one short line per bullet.

## 0.7.0

- Pop out: the issue list opens in a normal window that stays open and tiles with your other windows
- `omarchy-feedback window` opens, closes or toggles that window
- A report started from the window hides it for the screenshot and brings it back afterwards
- The row buttons say what they do: Mark fixed and Close issue (a plain "Fixed" looked like a status)

## 0.6.0

- Send to your coding agent and Send to Rix work again: what they launch gets your session's PATH
- A Rix worker that dies on start is stopped and reported instead of showing as running
- No Singularix? The Rix button shows what Rix does, with its GitHub and marketplace pages and the install command

## 0.5.4

- Screenshots in the README and on the marketplace listing; a clearer listing description

## 0.5.3

- A hand-off that fails now says so on the desktop instead of writing to a terminal you cannot see

## 0.5.2

- Send to Rix works again after the Agent Launcher plugin was renamed to Singularix

## 0.5.1

- The viewer says when screenshots could not be checked for secrets (tesseract not installed)

## 0.5.0

- Passwords, keys, tokens and account numbers are masked before anything is saved
- Screenshots are read with OCR and secrets painted black; the replay is sampled
- A critical alert tells you to rotate anything captured; author hand-off waits until you mark it rotated
- `omarchy-feedback secrets` and `delete-replay`

## 0.4.1

- Save Markdown and Save PDF put the file in Downloads and show where, with Show in Files and Copy path

## 0.4.0

- The popup tells you when a new version is out, shows what changed, and updates in one click
- `omarchy-feedback update-check`, `update-dismiss` and `update-run` from the command line

## 0.3.3

- The coding-agent check finds agents on your PATH
- Steadier viewer test

## 0.3.2

- Tools resolve from root-owned folders only
- Complete removal steps

## 0.3.1

- Hand issues to Rix, your coding agent or the author from the popup and the viewer
