# Golden set

Clips for tuning the cleanup prompt.

1. Dictate with FlowLite as usual. The last 5 recordings are saved as WAV files in
   `~/Library/Application Support/FlowLite/Recordings/`.
2. Copy good examples here and add one entry per clip to `cases.json`, with the app it was
   meant for, any text before the cursor, and the exact text you wanted.
3. Run:

       cd FlowLiteKit
       ANTHROPIC_API_KEY=sk-ant-... swift run -c release flowlite-golden ../Tools/golden
       swift run -c release flowlite-golden ../Tools/golden --no-clean   # transcription only

Aim for about 20 clips covering chat, email, code, lists, self-corrections and questions.
