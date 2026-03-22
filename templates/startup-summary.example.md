Session started 🟢

Memory: {memory_count} files loaded
Tasks: {tasks_found} found / {tasks_registered} registered / {tasks_skipped} skipped

Registered tasks:
{registered_list}

Skipped:
{skipped_list}

{stale_warnings}

<!-- Format guide (not sent to Telegram):
  {memory_count}     — integer, e.g. "13"
  {tasks_found}      — integer, e.g. "3"
  {tasks_registered} — integer, e.g. "2"
  {tasks_skipped}    — integer, e.g. "1"
  {registered_list}  — bullet list: "• task-name — HH:MM" per line
  {skipped_list}     — bullet list: "• task-name (reason)" per line
  {stale_warnings}   — "⚠️ Stale memory: file1.md, file2.md (not updated in 30+ days)"
  If {tasks_skipped} is 0, omit the "Skipped:" section entirely.
  If no stale memories, omit {stale_warnings} entirely.
-->
