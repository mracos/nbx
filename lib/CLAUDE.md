# nbx

## Output

Use the display helpers from `lib-display.bash` for all user-facing output:

| Function | Purpose |
|----------|---------|
| `plain`  | Normal output |
| `info`   | Dim/secondary text |
| `warn`   | Errors and warnings (stderr) |
| `result` | Step result: `→ $slot (type)` |

Do not use raw `echo` or `printf` for user-facing messages. Reserve `echo`/`printf` for data piping (e.g. feeding jq, writing to files, building slot content).
