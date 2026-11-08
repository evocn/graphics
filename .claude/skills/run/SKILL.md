---
description: Build and launch the Graphics renderer for any automated run — required for EVERY execution, so the window never takes the user's focus.
---

# Run Graphics

1. Build from the project root: `jai build.jai`. Report compiler errors and stop.
2. Launch with `-automation`, always: `bin/Graphics.exe -automation -frames 120 2>&1 | tail -40`
   - `-automation` opens the window at the bottom of the z-order without activating it. Never launch without it; the user is working while this runs.
   - `-frames N` quits after N frames, which also exercises teardown (exit code 0 means the deinit waits didn't hang). Omit it only for a hand-off launch the user will close.
   - Pipe the output: it's a GUI program on Windows, so a bare launch prints nothing and doesn't wait.
3. To see a frame: `bin/Graphics.exe -automation -screenshot -frames 10 2>&1 | tail -40`. This saves the last frame to `bin/screenshots/<timestamp>.png` and quits; read the PNG it names. Never delete screenshots.
4. If you launched without `-frames`, kill the process when done (`Stop-Process -Id <pid>`). A stray instance locks `bin/Graphics.exe` against the next build.

## Hand-off launch

When there's something for the user to look at, launch detached and leave it running:
`Start-Process bin\Graphics.exe -ArgumentList "-automation" -PassThru`. Report the pid. The window opens behind their work; they bring it forward from the taskbar.
