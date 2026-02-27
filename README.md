# luajit-profiler

a luajit profiler that builds an interactive static html page with a timeline. you can refresh the static html page while it's runnning to get updates.

`luajit -e "local p = require('profiler').New() require('bench') p:Stop()"`

<img width="1552" height="1120" alt="image" src="https://github.com/user-attachments/assets/34ecc54a-cc80-4c27-89f7-ed852c3eeb8e" />

## API Reference

### `profiler.New(config)`
creates and starts a new profiler instance. (i know jit profiling only supports 1 running function but whatever)
*   `config.id`: (string) uid for the profile. default: `"global"`
*   `config.path`: (string) output path for the HTML file. default: `"profile_summary_[id].html"`
*   `config.file_url`: (string) `"vscode" | "sublime" | "atom"` or custom template string for file location links. default: `"vscode"`
*   `config.depth`: (number) maximum stack depth. default: `500`
*   `config.sampling_rate`: (number) seconds between samples. default: `1`
*   `config.flush_interval`: (number) onterval for steaming data updates. default: `3` seconds

### `p:Stop()`
stops the profiler and finishes writing the html page.

### `p:Save()`
flushes any pending events to the html page without stopping.

### `p:StartSection(name)`
marks the start of a logical section in the timeline and flamegraph.

### `p:StopSection()`
marks the end of the current section.


### `p:IsRunning()`
...

### `p:GetElapsed()`
returns the seconds since the profiler started

