A luajit profiler that builds an interactive static html page with a timeline. You can refresh the static html page while it's runnning to get updates. It should also be possible to click on file paths to open them in your editor, assuming your editor supports uri schemes.

It's not final yet. I'm looking for some feedback, especially when it comes to the UI design. The HTML portion is mostly vibe coded, though with extensive design feedback, so it's a bit hard to maintain by humans.

```lua
local Profiler = require('profiler')
-- config is optional, all values are default
local p = Profiler.New({
    path = "./output.html",
    file_url = "vscode://file/${path}:${line}:1",
    flush_interval = 3, -- in seconds
    sampling_rate = 1, -- the jit profiler sampling rate in ms
    depth = 500, -- the depth of the callstack when the jit profiler interupts. should be high for a detailed flamegraph.
}) 
do
    -- some expensive code here
end

do
    p:StartSection("foo")
    -- something else here
    p:StopSection()
end
p:Stop()
```

<img width="812" height="1070" alt="image" src="https://github.com/user-attachments/assets/d83823d0-e312-4f67-9801-7d7eea133755" />
