# FlowLite manual test checklist

Build with `Scripts/build.sh --run`. For each app: click into a text field with some existing text,
put the cursor mid-sentence, then run each check.

| App | Dictation (hold fn) | Mid-sentence spacing | Command mode (select text, hold Control then fn, "make this more formal") | Inserted via (History) |
|---|---|---|---|---|
| Notes | | | | ax |
| TextEdit | | | | ax |
| Safari (Gmail compose) | | | | ax or paste |
| Chrome / Brave (any textarea) | | | | paste |
| Slack | | | | paste |
| VS Code / Cursor | | | | paste |
| Terminal | | | | paste |
| Messages | | | | ax or paste |

Also check:
- [ ] Tap fn quickly (< 0.3 s): nothing is inserted, overlay disappears.
- [ ] Double-tap fn: recording stays on hands-free; tap fn once more to stop and insert.
- [ ] Hold fn and press an arrow key: recording cancels.
- [ ] Esc while recording: cancels.
- [ ] Copy something, dictate into Slack, then ⌘V elsewhere: your original clipboard is back.
- [ ] Password field (e.g. a login form): dictation works, and History shows no field text was used.
- [ ] Turn Wi-Fi off and dictate a sentence: raw text is inserted with "Inserted without cleanup".
- [ ] Remove the API key: dictation still inserts raw text.
- [ ] Switch input device (connect headphones) between dictations: next dictation still records.
- [ ] Latency: in History, for 10 typical dictations (5–15 s of speech), transcribe + cleanup is under 1.5 s for most.
