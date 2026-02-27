local get_time

do
	local tonumber = _G.tonumber
	local has_ffi, ffi = pcall(require, "ffi")

	if not has_ffi then return os.clock end

	if ffi.os == "OSX" then
		ffi.cdef([[
		uint64_t clock_gettime_nsec_np(int clock_id);
	]])
		local C = ffi.C
		local CLOCK_UPTIME_RAW = 8
		local start_time = C.clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
		get_time = function()
			local current_time = C.clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
			return tonumber(current_time - start_time) / 1000000000.0
		end
	elseif ffi.os == "Windows" then
		ffi.cdef([[
		int QueryPerformanceFrequency(int64_t *lpFrequency);
		int QueryPerformanceCounter(int64_t *lpPerformanceCount);
	]])
		local q = ffi.new("int64_t[1]")
		ffi.C.QueryPerformanceFrequency(q)
		local freq = tonumber(q[0])
		local start_time = ffi.new("int64_t[1]")
		ffi.C.QueryPerformanceCounter(start_time)
		get_time = function()
			local time = ffi.new("int64_t[1]")
			ffi.C.QueryPerformanceCounter(time)
			time[0] = time[0] - start_time[0]
			return tonumber(time[0]) / freq
		end
	else
		ffi.cdef([[
		int clock_gettime(int clock_id, void *tp);
	]])
		local ts = ffi.new("struct { long int tv_sec; long int tv_nsec; }[1]")
		local func = ffi.C.clock_gettime
		get_time = function()
			func(1, ts)
			return tonumber(ts[0].tv_sec) + tonumber(ts[0].tv_nsec) * 0.000000001
		end
	end
end

-- Helper dependencies
local jutil = require("jit.util")
local vmdef = require("jit.vmdef")
local jit_attach = _G.jit.attach
local table_concat = _G.table.concat
local table_insert = _G.table.insert
local table_remove = _G.table.remove
local string_format = _G.string.format
local ffnames = vmdef.ffnames

-- --- Helpers ---

local function format_error(err, arg)
	local fmt = vmdef.traceerr[err]

	if not fmt then return "unknown error: " .. err end

	if not arg then return fmt end

	if fmt:sub(1, #"NYI: bytecode") == "NYI: bytecode" then
		local oidx = 6 * arg
		arg = vmdef.bcnames:sub(oidx + 1, oidx + 6):gsub("%s+$", "")
		fmt = "NYI bytecode %s"
	end

	return string_format(fmt, arg)
end

local function create_warn_log(interval)
	local i = 0
	local last_time = 0
	return function()
		i = i + 1

		if last_time < os.clock() then
			last_time = os.clock() + interval
			return i, interval
		end

		return false
	end
end

local function format_func_info(fi, func)
	if fi.loc and fi.currentline ~= 0 then
		local source = fi.source

		if source:sub(1, 1) == "@" then source = source:sub(2) end

		if source:sub(1, 2) == "./" then source = source:sub(3) end

		return source .. ":" .. fi.currentline
	elseif fi.ffid then
		return vmdef.ffnames[fi.ffid]
	elseif fi.addr then
		return string_format("C:%x, %s", fi.addr, tostring(func))
	else
		return "(?)"
	end
end

local function translate_stack(stack)
	stack = stack:gsub("%[builtin#(%d+)%]", function(n)
		local num = tonumber(n)
		return ffnames[num] or ("[builtin#" .. n .. "]")
	end)
	stack = stack:gsub("@0x%x+\n?", "")
	stack = stack:gsub("%(command line%)[^\n]*\n?", "")
	stack = stack:gsub("%s+$", "")
	return stack
end

local function json_string(s)
	s = s:gsub("\\", "\\\\")
	s = s:gsub("\"", "\\\"")
	s = s:gsub("\n", "\\n")
	s = s:gsub("\r", "\\r")
	s = s:gsub("\t", "\\t")
	return "\"" .. s .. "\""
end

-- --- Profiler ---

local HTML_TEMPLATE -- forward declaration, assigned at bottom of file

local FILE_URL_TEMPLATES = {
	vscode = "vscode://file/${path}:${line}:1",
	sublime = "subl://open?url=file://${path}&line=${line}",
	atom = "atom://core/open/file?filename=${path}&line=${line}",
}

local META = {}
META.__index = META

-- --- Event accumulation ---

local function emit(self, event)
	self._event_count = self._event_count + 1
	event.time = self._get_time()
	self._events[self._event_count] = event
end

local function check_flush(self)
	local now = self._get_time()

	if now - self._last_flush_time >= self._flush_interval then
		self._last_flush_time = now
		self:Save()
	end
end

-- --- String interning ---

local function intern(self, s)
	if s == nil then return -1 end

	local idx = self._string_lookup[s]

	if idx then return idx end

	idx = self._string_count
	self._string_count = self._string_count + 1
	self._strings[idx] = s
	self._string_lookup[s] = idx
	return idx
end

local function get_new_strings(self)
	local new = {}

	for i = self._strings_flushed, self._string_count - 1 do
		new[#new + 1] = self._strings[i]
	end

	self._strings_flushed = self._string_count
	return new
end

-- --- Section tracking ---

function META:StartSection(name)
	if not self._running then return end

	-- Simple timing
	self._simple_times[name] = self._simple_times[name] or {total = 0}
	self._simple_times[name].time = self._get_time()
	table_insert(self._simple_stack, name)

	-- Event section tracking
	table_insert(self._section_stack, name)
	self._section_path = table_concat(self._section_stack, " > ")
	emit(self, {type = "section_start", name = name, section_path = self._section_path})
end

function META:StopSection()
	if not self._running then return end

	local name = self._section_stack[#self._section_stack]

	if #self._section_stack > 0 then
		self._section_stack[#self._section_stack] = nil
		self._section_path = table_concat(self._section_stack, " > ")
	end

	emit(self, {type = "section_end", name = name, section_path = self._section_path})

	-- Simple timing
	local sname = table_remove(self._simple_stack)

	if sname and self._simple_times[sname] then
		self._simple_times[sname].total = self._simple_times[sname].total + (self._get_time() - self._simple_times[sname].time)
	end
end

-- --- Trace tracking ---

local function on_trace_start(self, id, func, pc, parent_id, exit_id)
	local fi = jutil.funcinfo(func, pc)
	local loc = format_func_info(fi, func)
	local depth = 0
	local parent = parent_id and self._traces[parent_id]

	if parent then depth = (parent.depth or 0) + 1 end

	self._traces[id] = {id = id, parent_id = parent_id, exit_id = exit_id, depth = depth}
	self._trace_count = self._trace_count + 1
	emit(self,
		{
			type = "trace_start",
			id = id,
			parent_id = parent_id,
			exit_id = exit_id,
			depth = depth,
			func_info = loc,
		}
	)
end

local function on_trace_stop(self, id, func)
	local trace = self._traces[id]

	if not trace then return end

	local ti = jutil.traceinfo(id)
	local fi = jutil.funcinfo(func)
	local loc = format_func_info(fi, func)
	emit(self,
		{
			type = "trace_stop",
			id = id,
			func_info = loc,
			linktype = ti and ti.linktype or nil,
			link_id = ti and ti.link or nil,
			ir_count = ti and ti.nins or nil,
			exit_count = ti and ti.nexit or nil,
		}
	)
end

local function on_trace_abort(self, id, func, pc, code, reason)
	local trace = self._traces[id]

	if not trace then return end

	local fi = jutil.funcinfo(func, pc)
	local loc = format_func_info(fi, func)
	self._aborted[id] = true
	self._traces[id] = nil
	self._trace_count = self._trace_count - 1

	emit(self,
		{
			type = "trace_abort",
			id = id,
			abort_code = code,
			abort_reason = format_error(code, reason),
			func_info = loc,
		}
	)

	if code == 27 then
		local x, interval = self._should_warn_mcode()

		if x then
			io.write(
				format_error(code, reason),
				x == 0 and "" or " [" .. x .. " times the last " .. interval .. " seconds]",
				"\n"
			)
		end
	end
end

local function on_trace_flush(self)
	if self._trace_count > 0 then
		local x, interval = self._should_warn_abort()

		if x then
			io.write(
				"flushing ",
				self._trace_count,
				" traces, ",
				(x == 0 and "" or "[" .. x .. " times the last " .. interval .. " seconds]"),
				"\n"
			)
		end
	end

	self._traces = {}
	self._aborted = {}
	self._trace_count = 0
	emit(self, {type = "trace_flush"})
end

local function attach_traces(self)
	if not jit_attach or not jutil.funcinfo or not jutil.traceinfo then return end

	local prof = self

	self._trace_event_fn = function(what, tr, func, pc, otr, oex)
		if what == "start" then
			on_trace_start(prof, tr, func, pc, otr, oex)
		elseif what == "stop" then
			on_trace_stop(prof, tr, func)
		elseif what == "abort" then
			on_trace_abort(prof, tr, func, pc, otr, oex)
		elseif what == "flush" then
			on_trace_flush(prof)
		end
	end

	self._trace_event_safe_fn = function(what, tr, func, pc, otr, oex)
		local ok, err = pcall(self._trace_event_fn, what, tr, func, pc, otr, oex)

		if not ok then io.write("error in trace event (" .. tostring(what) .. "): " .. tostring(err) .. "\n") end
	end

	jit_attach(self._trace_event_safe_fn, "trace")
end

local function detach_traces(self)
	if self._trace_event_safe_fn then
		jit_attach(self._trace_event_safe_fn)
		self._trace_event_fn = nil
		self._trace_event_safe_fn = nil
	end
end

-- --- JIT sampling ---

local function start_sampling(self)
	local ok, jp = pcall(require, "jit.profile")

	if not ok then return end

	local prof = self
	local dumpstack = jp.dumpstack
	local depth = self._depth
	local section_path_ref = function() return prof._section_path end

	jp.start(
		(self._mode == "line" and "l" or "f") .. "i" .. self._sampling_rate,
		function(thread, sample_count, vmstate)
			emit(prof,
				{
					type = "sample",
					stack = dumpstack(thread, "pl\n", depth),
					sample_count = sample_count,
					vm_state = vmstate,
					section_path = prof._section_path,
				}
			)
			check_flush(prof)
		end
	)

	self._jp = jp
end

-- --- Encoding ---

local function encode_event(self, ev)
	local t = ev.type
	local ti = intern(self, t)

	if t == "sample" then
		local stack_str = ev.stack

		if stack_str and type(stack_str) == "string" then
			stack_str = translate_stack(stack_str)
		end

		local frames = {}

		if stack_str and stack_str ~= "" then
			for line in stack_str:gmatch("[^\n]+") do
				frames[#frames + 1] = intern(self, line)
			end
		end

		return string_format(
			"[%d,%.6f,[%s],%d,%d,%d]",
			ti,
			ev.time,
			table_concat(frames, ","),
			ev.sample_count or 0,
			intern(self, ev.vm_state),
			intern(self, ev.section_path)
		)
	elseif t == "section_start" or t == "section_end" then
		return string_format(
			"[%d,%.6f,%d,%d]",
			ti,
			ev.time,
			intern(self, ev.name),
			intern(self, ev.section_path)
		)
	elseif t == "trace_start" then
		return string_format(
			"[%d,%.6f,%d,%s,%s,%d,%d]",
			ti,
			ev.time,
			ev.id or 0,
			ev.parent_id and tostring(ev.parent_id) or "null",
			ev.exit_id and tostring(ev.exit_id) or "null",
			ev.depth or 0,
			intern(self, ev.func_info)
		)
	elseif t == "trace_stop" then
		return string_format(
			"[%d,%.6f,%d,%d,%d,%s,%d,%d]",
			ti,
			ev.time,
			ev.id or 0,
			intern(self, ev.func_info),
			intern(self, ev.linktype),
			ev.link_id and tostring(ev.link_id) or "null",
			ev.ir_count or 0,
			ev.exit_count or 0
		)
	elseif t == "trace_abort" then
		return string_format(
			"[%d,%.6f,%d,%s,%d,%d]",
			ti,
			ev.time,
			ev.id or 0,
			ev.abort_code and tostring(ev.abort_code) or "null",
			intern(self, ev.abort_reason),
			intern(self, ev.func_info)
		)
	else
		return string_format("[%d,%.6f]", ti, ev.time)
	end
end

local function encode_chunk(self, start_idx, end_idx)
	local event_parts = {}

	for i = start_idx, end_idx do
		event_parts[#event_parts + 1] = encode_event(self, self._events[i])
	end

	local new_strings = get_new_strings(self)
	local string_parts = {}

	for i = 1, #new_strings do
		string_parts[i] = json_string(new_strings[i])
	end

	return "[" .. table_concat(string_parts, ",") .. "]",
		"[" .. table_concat(event_parts, ",") .. "]"
end

-- --- HTML I/O ---

local function begin_html(self)
	local html = HTML_TEMPLATE
	html = html:gsub("%%TITLE%%", self._id)
	html = html:gsub("%%TITLE_JSON%%", function()
		return json_string(self._id)
	end)
	html = html:gsub("%%ROOT_PATH_JSON%%", function()
		return json_string((os.getenv("PWD") or ""):gsub("[\\/]+$", ""))
	end)
	html = html:gsub("%%FILE_URL_JSON%%", function()
		return json_string(self._file_url)
	end)
	local f = assert(io.open(self._path, "w"))
	f:write(html)
	f:flush()
	return f
end

local function write_chunk(self, start_idx, end_idx)
	if start_idx > end_idx then return end
	if not self._file then return end

	local strings_js, events_js = encode_chunk(self, start_idx, end_idx)
	self._file:write("<script>_C(")
	self._file:write(strings_js)
	self._file:write(",")
	self._file:write(events_js)
	self._file:write(");</script>\n")
	self._file:flush()
end

local function finish_html(self)
	if self._file then
		self._file:close()
		self._file = nil
	end
end

-- --- Constructor ---

local function profiler_new(config)
	config = config or {}

	local self = setmetatable({}, META)

	-- Config
	self._id = config.id or "global"
	self._path = config.path or ("profile_summary_" .. self._id .. ".html")
	local file_url = config.file_url or "vscode"
	self._file_url = FILE_URL_TEMPLATES[file_url] or file_url
	self._mode = config.mode or "line"
	self._depth = config.depth or 500
	self._sampling_rate = config.sampling_rate or 1
	self._flush_interval = config.flush_interval or 3
	self._get_time = config.get_time or get_time

	-- Lifecycle
	self._time_start = self._get_time()
	self._running = true

	-- Event accumulation
	self._events = {}
	self._event_count = 0
	self._last_flush_time = 0

	-- String interning
	self._strings = {}
	self._string_lookup = {}
	self._string_count = 0
	self._strings_flushed = 0

	-- Section tracking
	self._section_stack = {}
	self._section_path = ""
	self._simple_times = {}
	self._simple_stack = {}

	-- Trace tracking
	self._traces = {}
	self._trace_count = 0
	self._aborted = {}
	self._should_warn_mcode = create_warn_log(2)
	self._should_warn_abort = create_warn_log(8)

	-- HTML streaming
	self._last_flushed_idx = 0
	self._file = begin_html(self)

	-- Attach trace events
	attach_traces(self)

	-- Start JIT profiler
	start_sampling(self)

	return self
end

-- --- Public API ---

function META:Save()
	if not self._file then return end

	local count = self._event_count

	if count > self._last_flushed_idx then
		write_chunk(self, self._last_flushed_idx + 1, count)
		self._last_flushed_idx = count
	end
end

function META:Stop()
	if not self._running then return end

	self._running = false

	-- Stop JIT profiler
	if self._jp then
		self._jp.stop()
		self._jp = nil
	end

	-- Detach trace events
	detach_traces(self)

	-- Write remaining events and close file
	self:Save()
	finish_html(self)
end

function META:GetEvents()
	return self._events, self._event_count
end

function META:GetSimpleSections()
	return self._simple_times
end

function META:IsRunning()
	return self._running
end

function META:GetElapsed()
	return self._get_time() - self._time_start
end

-- --- HTML Template ---

HTML_TEMPLATE = [==[
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>NattLua Profile — %TITLE%</title>
<style>
:root {
  --accent:      #e0e0e0;
  --accent-dim:  rgba(224,224,224,0.15);
  --bg-base:     #1a1a1a;
  --bg-panel:    #222;
  --bg-elevated: #2a2a2a;
  --bg-hover:    #383838;
  --border:      #333;
  --border-strong:#444;
  --text-muted:  #888;
  --text-dim:    #666;
  --color-ok:    #52b788;
  --color-abort: #ef6461;
  --color-stitch:#e9c46a;
  --color-linked:#ab47bc;
  --color-jit:   #ffd166;
  --color-select:#ffc832;
}
* { margin: 0; padding: 0; box-sizing: border-box; font-family: 'SF Mono', 'Consolas', 'Menlo', monospace; }
body { background: var(--bg-base); color: #e0e0e0; }
#header { padding: 8px 16px; background: var(--bg-panel); border-bottom: 1px solid var(--border); display: flex; align-items: center; gap: 16px; flex-wrap: wrap; }
#header .stats { font-size: 12px; color: var(--text-muted); }
#timeline-container { position: relative; background: #141414; border-bottom: none; overflow: hidden; cursor: crosshair; }
#timeline-canvas { width: 100%; height: 100%; }
#timeline-resize-handle { height: 7px; background: var(--bg-panel); border-bottom: 1px solid var(--border); cursor: ns-resize; display: flex; align-items: center; justify-content: center; flex-shrink: 0; }
#timeline-resize-handle::after { content: ''; width: 40px; height: 2px; background: var(--border-strong); border-radius: 1px; }
#timeline-resize-handle:hover::after, #timeline-resize-handle.dragging::after { background: var(--accent); }
#selection-overlay { position: absolute; top: 0; background: var(--accent-dim); border-left: 2px solid var(--accent); border-right: 2px solid var(--accent); pointer-events: none; display: none; overflow: visible; }

#timeline-controls { padding: 6px 16px; background: var(--bg-panel); border-bottom: 1px solid var(--border); display: flex; gap: 12px; align-items: center; font-size: 12px; flex-wrap: wrap; }
#timeline-controls button { background: var(--bg-elevated); border: 1px solid var(--border-strong); color: #ccc; padding: 4px 12px; border-radius: 3px; cursor: pointer; font-size: 11px; }
#timeline-controls button:hover { background: var(--bg-hover); border-color: var(--accent); }
#selection-info { color: var(--text-muted); }
#fg-section-filter { background: var(--bg-panel); border-bottom: 1px solid var(--border); padding: 6px 16px; display: flex; flex-wrap: wrap; gap: 4px 16px; align-items: center; font-size: 11px; }
#fg-section-filter label { display: flex; align-items: center; gap: 4px; cursor: pointer; white-space: nowrap; color: var(--text-muted); padding: 2px 0; }
#fg-section-filter label:hover { color: var(--accent); }
#fg-section-filter label input { accent-color: var(--accent); cursor: pointer; }
.section-header { padding: 0; background: var(--bg-panel); border-bottom: 1px solid var(--border); display: flex; align-items: stretch; flex-shrink: 0; cursor: pointer; }
.section-header button { background: transparent; border: none; color: var(--accent); padding: 5px 16px; cursor: pointer; font-size: 12px; font-weight: 600; width: 100%; text-align: left; }
.section-header:hover button { color: #fff; background: rgba(255,255,255,0.04); }
#trace-panel { background: var(--bg-panel); border-bottom: 1px solid var(--border); overflow: hidden; height: 0; }
#trace-panel.open { overflow: auto; }
#trace-panel-resize-handle { height: 7px; background: var(--bg-panel); border-bottom: 1px solid var(--border); cursor: ns-resize; display: flex; align-items: center; justify-content: center; flex-shrink: 0; }
#trace-panel-resize-handle::after { content: ''; width: 40px; height: 2px; background: var(--border-strong); border-radius: 1px; }
#trace-panel-resize-handle:hover::after, #trace-panel-resize-handle.dragging::after { background: var(--accent); }
#trace-sticky-top { position: sticky; top: 0; z-index: 2; background: var(--bg-panel); }
#trace-filter-header { padding: 6px 16px; border-bottom: 1px solid var(--border); display: flex; align-items: center; gap: 8px; }
#trace-filter-header:empty { display: none; }
#trace-filter-header button { background: var(--bg-elevated); border: 1px solid var(--border-strong); color: #ccc; padding: 2px 10px; border-radius: 3px; cursor: pointer; font-size: 11px; }
#trace-filter-header button:hover { background: var(--bg-hover); border-color: var(--accent); }
#trace-panel table { width: 100%; border-collapse: collapse; font-size: 11px; }
#trace-panel th { position: sticky; z-index: 2; background: var(--bg-elevated); padding: 6px 10px; text-align: left; color: var(--accent); border-bottom: 1px solid var(--border-strong); font-weight: 600; cursor: pointer; user-select: none; }
#trace-panel th:hover { color: #fff; }
#trace-panel td { padding: 4px 10px; border-bottom: 1px solid var(--bg-panel); }
#trace-panel tr.trace-row { cursor: pointer; }
#trace-panel tr.trace-row:hover td, #trace-panel tr.trace-row.hovered td { background: rgba(255,255,255,0.06); }
#trace-panel tr.trace-row.highlighted td { background: rgba(255,255,255,0.12); outline: 1px solid rgba(255,255,255,0.25); }
#trace-panel tr.trace-row.selected td { background: rgba(255,220,80,0.18); outline: 1px solid rgba(255,220,80,0.55); }
.trace-ok { color: var(--color-ok); }
.trace-linked { color: var(--color-linked); }
.trace-stitch { color: var(--color-stitch); }
.trace-abort { color: var(--color-abort); }
.trace-location { color: #aaa; }
.trace-id { color: #ccc; font-weight: 600; min-width: 40px; }
#filter-panel { background: var(--bg-panel); border-bottom: 1px solid var(--border); overflow: visible; }
#filter-panel .filter-grid { display: flex; flex-wrap: wrap; gap: 4px 16px; padding: 8px 16px; font-size: 11px; }
#filter-panel label { display: flex; align-items: center; gap: 4px; cursor: pointer; padding: 2px 0; white-space: nowrap; }
#filter-panel label:hover { color: #fff; }
#filter-panel .filter-count { color: var(--text-dim); font-size: 10px; }
.custom-cb { font-size: 13px; line-height: 1; font-family: monospace; display: inline-block; width: 1.1em; }
#filter-panel .filter-all-btn, #filter-panel .filter-none-btn { display: flex; align-items: center; gap: 4px; cursor: pointer; padding: 2px 0; white-space: nowrap; font-size: 11px; user-select: none; }
#filter-panel .filter-all-btn:hover, #filter-panel .filter-none-btn:hover { color: #fff; }
#flamegraph-container { overflow: hidden; max-height: 0; transition: max-height 0.3s ease; flex-shrink: 0; }
#flamegraph-container.open { max-height: 3000px; overflow-x: hidden; overflow-y: auto; flex: 1; }
#flamegraph-canvas { width: 100%; min-height: 400px; }
#tooltip { position: fixed; background: var(--bg-panel); border: 1px solid var(--border-strong); padding: 8px 12px; border-radius: 4px; font-size: 11px; pointer-events: none; display: none; z-index: 100; max-width: 500px; white-space: pre-wrap; line-height: 1.5; }
.loc-link { color: var(--accent); text-decoration: none; opacity: 0.8; }
.loc-link:hover { text-decoration: underline; opacity: 1; }
#main { display: flex; flex-direction: column; height: 100vh; }
#vm-pie-wrap { display: flex; align-items: center; flex-shrink: 0; }
#vm-pie-canvas { cursor: pointer; }
</style>
</head>
<body>
<div id="main">
<div id="header">
  <div id="vm-pie-wrap"><canvas id="vm-pie-canvas" width="72" height="72"></canvas></div>
  <span class="stats" id="stats"></span>
</div>
<div id="timeline-controls">
  <button id="btn-reset">reset zoom</button>
  <button id="btn-zoom-sel">zoom to selection</button>
  <span id="selection-info">Click and drag on timeline to select a region</span>
</div>
<div id="timeline-container">
  <canvas id="timeline-canvas"></canvas>
  <div id="selection-overlay"><span id="sel-t-start" style="position:absolute;bottom:2px;left:3px;font-size:9px;color:#e0e0e0;white-space:nowrap;background:rgba(20,20,20,0.8);padding:0 2px"></span><span id="sel-t-end" style="position:absolute;bottom:2px;right:3px;font-size:9px;color:#e0e0e0;white-space:nowrap;background:rgba(20,20,20,0.8);padding:0 2px"></span></div>
</div>
<div id="timeline-resize-handle"></div>
<div class="section-header">
  <button id="btn-toggle-aborts">▼ trace list</button>
</div>
<div id="trace-panel" class="open"></div>
<div id="trace-panel-resize-handle"></div>
<div class="section-header">
  <button id="btn-toggle-fg">▼ flamegraph</button>
</div>
<div id="flamegraph-container" class="open">
  <div id="fg-section-filter"></div>
  <canvas id="flamegraph-canvas"></canvas>
</div>
</div>
<div id="tooltip"></div>

<script>
// --- Data accumulator & decoder ---
var _S=[],_E=[];
function _C(s,e){for(var i=0;i<s.length;i++)_S.push(s[i]);for(var i=0;i<e.length;i++)_E.push(e[i]);}
function _decode(S,E){
  var events=[];
  for(var i=0;i<E.length;i++){
    var d=E[i],type=S[d[0]],ev;
    if(type==='sample'){
      var frames=d[2],stack='';
      for(var j=0;j<frames.length;j++){if(j>0)stack+='\n';stack+=S[frames[j]];}
      ev={type:type,time:d[1],stack:stack,sample_count:d[3],vm_state:S[d[4]],section_path:S[d[5]]};
    }else if(type==='section_start'||type==='section_end'){
      ev={type:type,time:d[1],name:S[d[2]],section_path:S[d[3]]};
    }else if(type==='trace_start'){
      ev={type:type,time:d[1],id:d[2],parent_id:d[3],exit_id:d[4],depth:d[5],func_info:S[d[6]]};
    }else if(type==='trace_stop'){
      ev={type:type,time:d[1],id:d[2],func_info:S[d[3]],linktype:S[d[4]],link_id:d[5],ir_count:d[6],exit_count:d[7]};
    }else if(type==='trace_abort'){
      ev={type:type,time:d[1],id:d[2],abort_code:d[3],abort_reason:S[d[4]],func_info:S[d[5]]};
    }else if(type==='trace_flush'){
      ev={type:type,time:d[1]};
    }else{
      ev={type:type,time:d[1]};
    }
    events.push(ev);
  }
  return events;
}
document.addEventListener('DOMContentLoaded', function() {
const EVENTS = _decode(_S, _E);
_S = null; _E = null;
const TOTAL_TIME = EVENTS.length > 1 ? EVENTS[EVENTS.length-1].time - EVENTS[0].time : 0;
const TITLE = %TITLE_JSON%;
const ROOT_PATH = %ROOT_PATH_JSON%;
const FILE_URL_TEMPLATE = %FILE_URL_JSON%;
// --- File link helper ---
function funcInfoLink(fi, label) {
  if (!fi) return label || '?';
  const display = label || fi;
  // Match "path/or/file.lua:line" — path may be absolute or relative
  const m = fi.match(/^(.+):([0-9]+)$/);
  if (!m) return display;
  const [, filePath, line] = m;
  const absPath = filePath.startsWith('/') ? filePath : ROOT_PATH + '/' + filePath;
  const href = FILE_URL_TEMPLATE.replace(/\$\{path\}/g, absPath).replace(/\$\{line\}/g, line);
  return `<a class="loc-link" href="${href}">${display}</a>`;
}

// --- Colors ---
const COLORS = {
  // Accent / interaction
  accent:     '#e0e0e0',
  accentDim:  'rgba(224,224,224,0.15)',
  // Span / VM state
  ok:         '#52b788',
  abort:      '#ef6461',
  stitch:     '#e9c46a',
  linked:     '#ab47bc',
  jit:        '#ffd166',
  select:     '#ffc832',
  hover:      'rgba(255,255,255,0.06)',
  // Backgrounds / structure
  bgDeep:      '#141414',
  bgBase:      '#1a1a1a',
  bgPanel:     '#222',
  border:      '#333',
  borderStrong:'#444',
  bgSeparator: '#1e1e1e',
  // Text
  white:       '#fff',
  textBright:  '#ccc',
  textMid:     '#bbb',
  textMuted:   '#aaa',
  textDim:     '#888',
  textDimmer:  '#666',
  spanLabel:   '#111',
  // Canvas overlays / tooltips
  tooltipBg:    'rgba(15,15,35,0.75)',
  tooltipBgDim: 'rgba(15,15,35,0.72)',
  jitBand:      'rgba(255,241,118,0.07)',
  abortBand:    'rgba(239,100,97,0.15)',
  flushBand:    'rgba(255,107,107,0.08)',
  // Event / section colors
  okLight:      '#81c784',
  sectionStart: '#fff176',
  sectionEnd:   '#ffd54f',
  textFaint:    '#999',
  textVeryDim:  '#555',
  // Span tree connections
  selectTreeLine: 'rgba(255,200,50,0.85)',
  selectTreeFill: 'rgba(255,200,50,0.3)',
  hoverTreeLine:  'rgba(255,255,200,0.75)',
  hoverTreeFill:  'rgba(255,255,200,0.3)',
  selectGlow:     'rgba(255,200,50,0.9)',
};

// --- VM state helpers ---
const VM_STATE_COLORS = {
  'N': COLORS.ok,     // Native (JIT)
  'I': COLORS.stitch, // Interpreter
  'C': COLORS.linked, // C code
  'G': COLORS.abort,  // GC
  'J': COLORS.jit,    // JIT compile
};
const VM_STATE_LABELS = {
  'N': 'native',
  'I': 'interpreter',
  'C': 'c',
  'G': 'gc',
  'J': 'jit',
};

function sampleColor(e) {
  return VM_STATE_COLORS[e.vm_state] || COLORS.ok;
}

// --- Derived state ---
let timeOrigin = Infinity, timeEnd = -Infinity;
for (const e of EVENTS) {
  if (e.time < timeOrigin) timeOrigin = e.time;
  if (e.time > timeEnd) timeEnd = e.time;
}
const timeDuration = timeEnd - timeOrigin || 1;

let viewStart = 0, viewEnd = timeDuration;
let selStart = 0, selEnd = timeDuration;
let dragMode = null; // null | 'select' | 'pan'
let panStartX = 0, panViewStart0 = 0, panViewEnd0 = 0;
let sampleH = 60; // updated each draw
let tlHovered = false;
let pieHoveredState = null; // vm_state key hovered on pie chart
let hoveredSection = null;  // section name being hovered in fg-section-filter
let pieSlices = [];  // [{state, a0, a1}] built by drawVmPie
let timelineContainerH = 0; // set after totalLanes is known

// --- Section filter ---
const ALL_SECTIONS = [];
const SECTION_OTHER = '__other__';
{
  const seen = new Set();
  let hasOther = false;
  for (const e of EVENTS) {
    if (e.type === 'section_start') {
      const name = e.name || '';
      if (name && !seen.has(name)) { seen.add(name); ALL_SECTIONS.push(name); }
    }
    if (e.type === 'sample' && e.stack && !e.section_path) hasOther = true;
  }
  if (hasOther) ALL_SECTIONS.push(SECTION_OTHER);
}
const enabledSections = new Set(ALL_SECTIONS);

function buildSectionFilter() {
  const wrap = document.getElementById('fg-section-filter');
  if (!wrap) return;
  wrap.innerHTML = '';
  if (ALL_SECTIONS.length === 0) { wrap.style.display = 'none'; return; }
  for (const name of ALL_SECTIONS) {
    const isOther = name === SECTION_OTHER;
    const label = document.createElement('label');
    const isEnabled = enabledSections.has(name);
    
    // Custom checkbox span
    const cbSpan = document.createElement('span');
    cbSpan.className = 'custom-cb';
    cbSpan.textContent = isEnabled ? '☑' : '☐';
    if (!isEnabled) label.style.color = '#888';
    label.appendChild(cbSpan);

    label.addEventListener('click', (ev) => {
      ev.preventDefault();
      if (enabledSections.has(name)) {
        enabledSections.delete(name);
        cbSpan.textContent = '☐';
        label.style.color = '#888';
      } else {
        enabledSections.add(name);
        cbSpan.textContent = '☑';
        label.style.color = '';
      }
      scheduleFlamegraph(selStart, selEnd);
    });

    if (!isOther) {
      label.addEventListener('mouseenter', () => { hoveredSection = name; drawTimeline(); });
      label.addEventListener('mouseleave', () => { hoveredSection = null; drawTimeline(); });
    }
    label.appendChild(document.createTextNode(isOther ? 'other' : name));
    wrap.appendChild(label);
  }
}

// Cached canvas rect — avoids forced layout reflow on every tick
let tlCanvasRectCache = null;
function getTlRect() {
  if (!tlCanvasRectCache) tlCanvasRectCache = tlCanvas.getBoundingClientRect();
  return tlCanvasRectCache;
}
function invalidateTlRect() { tlCanvasRectCache = null; }

// Debounced heavy updates (panels + flamegraph) so continuous wheel/drag only
// rebuilds DOM after the user pauses, keeping canvas draw synchronous.
let panelDebounceTimer = null;
let fgDebounceTimer = null;
function schedulePanelUpdate(lo, hi) {
  if (panelDebounceTimer) clearTimeout(panelDebounceTimer);
  panelDebounceTimer = setTimeout(() => {
    buildTraceListPanel(lo, hi);
    buildFilterPanel(lo, hi);
    drawVmPie(lo, hi);
    panelDebounceTimer = null;
  }, 120);
}
function scheduleFlamegraph(lo, hi) {
  if (fgDebounceTimer) clearTimeout(fgDebounceTimer);
  fgDebounceTimer = setTimeout(() => {
    drawFlamegraph(lo, hi);
    fgDebounceTimer = null;
  }, 120);
}

// --- Stats ---
document.getElementById('stats').textContent = `${EVENTS.length} events | ${TOTAL_TIME.toFixed(3)}s total`;

// --- VM Pie Chart ---
const VM_STATE_ORDER = ['N','I','C','G','J'];
function drawVmPie(lo, hi) {
  const canvas = document.getElementById('vm-pie-canvas');
  if (!canvas) return;
  const dpr = window.devicePixelRatio || 1;
  const size = 72;
  canvas.width = size * dpr;
  canvas.height = size * dpr;
  canvas.style.width = size + 'px';
  canvas.style.height = size + 'px';
  const ctx = canvas.getContext('2d');
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

  // Count samples in range
  const rangeCounts = {};
  let total = 0;
  for (const e of EVENTS) {
    if (e.type !== 'sample') continue;
    const t = e.time - timeOrigin;
    if (t < lo || t > hi) continue;
    const s = e.vm_state || '?';
    rangeCounts[s] = (rangeCounts[s] || 0) + 1;
    total++;
  }

  ctx.clearRect(0, 0, size, size);
  if (total === 0) {
    ctx.fillStyle = COLORS.border;
    ctx.fill();
    pieSlices = [];
    return;
  }

  const cx = size / 2, cy = size / 2;
  const outerR = size / 2 - 3;
  const innerR = outerR * 0.52;
  let angle = -Math.PI / 2;

  ctx.fillStyle = COLORS.bgBase;
  ctx.beginPath();
  ctx.arc(cx, cy, outerR, 0, Math.PI * 2);
  ctx.fill();

  pieSlices = [];
  const sliceData = [];
  for (const key of VM_STATE_ORDER) {
    const count = rangeCounts[key] || 0;
    if (!count) continue;
    const sweep = (count / total) * Math.PI * 2;
    sliceData.push({state: key, a0: angle, a1: angle + sweep, count});
    pieSlices.push({state: key, a0: angle, a1: angle + sweep});
    angle += sweep;
  }
  // Draw non-hovered slices first, then hovered on top
  for (const sl of sliceData) {
    const color = VM_STATE_COLORS[sl.state] || COLORS.textDim;
    const hov = sl.state === pieHoveredState;
    const r = hov ? outerR + 3 : outerR;
    ctx.beginPath();
    ctx.moveTo(cx, cy);
    ctx.arc(cx, cy, r, sl.a0, sl.a1);
    ctx.closePath();
    ctx.fillStyle = color;
    ctx.globalAlpha = hov ? 1 : (pieHoveredState ? 0.45 : 1);
    ctx.fill();
    ctx.globalAlpha = 1;
  }

  // Punch out the center for the donut hole
  ctx.fillStyle = COLORS.bgPanel;
  ctx.beginPath();
  ctx.arc(cx, cy, innerR, 0, Math.PI * 2);
  ctx.fill();

  // Center label: hovered state key or total count
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  if (pieHoveredState) {
    const cnt = rangeCounts[pieHoveredState] || 0;
    const pct = (cnt / total * 100).toFixed(0) + '%';
    const stateColor = VM_STATE_COLORS[pieHoveredState] || COLORS.textMuted;
    // Background pill behind labels
    const bgW = innerR * 1.7, bgH = innerR * 1.25;
    ctx.fillStyle = COLORS.bgDeep;
    ctx.beginPath();
    ctx.roundRect(cx - bgW / 2, cy - bgH / 2, bgW, bgH, 5);
    ctx.fill();
    ctx.fillStyle = stateColor;
    ctx.font = 'bold 9px monospace';
    ctx.fillText(pieHoveredState, cx, cy - 5);
    ctx.fillStyle = COLORS.textBright;
    ctx.font = 'bold 10px monospace';
    ctx.fillText(pct, cx, cy + 6);
  }
}

// --- Trace List ---
function traceStatusClass(span) {
  if (span.outcome === 'abort') return 'trace-abort';
  const lt = span.end.linktype;
  if (lt === 'stitch') return 'trace-stitch';
  if (lt === 'root') return 'trace-linked';
  return 'trace-ok';
}
function traceStatusLabel(span) {
  if (span.outcome === 'abort') return span.end.abort_reason || 'aborted';
  const lt = span.end.linktype || '?';
  const lk = span.end.link_id ? ' → #' + span.end.link_id : '';
  return lt + lk;
}
let traceListSortKey = 'id';
let traceListSortAsc = true;

function buildTraceListPanel(tStart, tEnd) {
  const lo = tStart !== undefined ? tStart : viewStart;
  const hi = tEnd !== undefined ? tEnd : viewEnd;

  // When a span is selected, collect its entire ancestor+descendant tree
  let selectedTree = null;
  if (selectedSpan) {
    selectedTree = new Set();
    // Walk up to root
    let anc = selectedSpan;
    while (anc) {
      selectedTree.add(anc.id);
      anc = anc.start.parent_id ? spanById[anc.start.parent_id] : null;
    }
    // BFS down descendants
    const q = [selectedSpan];
    while (q.length) {
      const n = q.shift();
      selectedTree.add(n.id);
      const kids = childrenOf[n.id];
      if (kids) for (const k of kids) q.push(k);
    }
  }

  const visible = [];
  for (const span of traceSpans) {
    if (!enabledCategories.has(span.category)) continue;
    // If a span is selected, only show its tree; otherwise filter by time range
    if (selectedTree) {
      if (!selectedTree.has(span.id)) continue;
    } else {
      const t = span.t0 - timeOrigin;
      if (t < lo || t > hi) continue;
    }
    visible.push(span);
  }
  const container = document.getElementById('trace-panel');
  if (visible.length === 0) {
    let emptyHdr = '<div id="trace-sticky-top"><div id="trace-filter-header">';
    if (selectedSpan) emptyHdr += ' <span style="font-size:10px;color:#ffc832;margin-left:8px">&#9733; #' + selectedSpan.id + '</span><button id="btn-clear-selection" style="margin-left:6px;font-size:10px;padding:1px 7px">Clear</button>';
    emptyHdr += '</div><div id="filter-panel"></div></div><div style="padding:12px;color:#666">No traces in range.</div>';
    container.innerHTML = emptyHdr;
    buildFilterPanel(lo, hi);
    const clearBtn = document.getElementById('btn-clear-selection');
    if (clearBtn) clearBtn.addEventListener('click', () => { selectedSpan = null; drawTimeline(); buildTraceListPanel(lo, hi); });
    return;
  }

  // Sort
  const cmp = (a, b) => {
    let va, vb;
    switch (traceListSortKey) {
      case 'id': va = a.id; vb = b.id; break;
      case 'status': va = a.outcome + (a.end.linktype||''); vb = b.outcome + (b.end.linktype||''); break;
      case 'depth': va = a.depth; vb = b.depth; break;
      case 'location': va = a.start.func_info||''; vb = b.start.func_info||''; break;
      case 'time': va = a.t0; vb = b.t0; break;
      default: va = a.id; vb = b.id;
    }
    if (va < vb) return traceListSortAsc ? -1 : 1;
    if (va > vb) return traceListSortAsc ? 1 : -1;
    return 0;
  };
  visible.sort(cmp);

  const arrow = traceListSortAsc ? ' ▲' : ' ▼';
  const hdr = (key, label) => {
    const active = traceListSortKey === key;
    return '<th data-sort="' + key + '">' + label + (active ? arrow : '') + '</th>';
  };
  let html = '<div id="trace-sticky-top"><div id="trace-filter-header">';
  if (selectedSpan) {
    html += ' <span style="font-size:10px;color:#ffc832;margin-left:8px">&#9733; Showing tree for #' + selectedSpan.id + '</span>';
    html += ' <button id="btn-clear-selection" style="margin-left:6px;font-size:10px;padding:1px 7px">Clear</button>';
  }
  html += '</div><div id="filter-panel"></div></div>';
  html += '<table><tr>' + hdr('id','id') + hdr('status','status') + hdr('depth','depth') + hdr('location','location') +
    '<th>parent</th>' + hdr('time','time') + '<th>ir</th><th>exits</th></tr>';
  for (const s of visible) {
    const cls = traceStatusClass(s);
    const irCount = s.end.ir_count || '';
    const exitCount = s.end.exit_count || '';
    const parentInfo = s.start.parent_id ? '#' + s.start.parent_id + ' exit ' + s.start.exit_id : '';
    const t = (s.t0 - timeOrigin).toFixed(4) + 's';
    const selCls = (selectedSpan && s.id === selectedSpan.id) ? ' selected' : '';
    html += '<tr class="trace-row' + selCls + '" data-span-id="' + s.id + '">' +
      '<td class="trace-id">#' + s.id + '</td>' +
      '<td class="' + cls + '">' + traceStatusLabel(s) + '</td>' +
      '<td>' + s.depth + '</td>' +
      '<td class="trace-location">' + funcInfoLink(s.start.func_info) + '</td>' +
      '<td>' + parentInfo + '</td>' +
      '<td>' + t + '</td>' +
      '<td>' + irCount + '</td>' +
      '<td>' + exitCount + '</td></tr>';
  }
  html += '</table>';
  container.innerHTML = html;

  buildFilterPanel(lo, hi);
  const clearSelBtn = document.getElementById('btn-clear-selection');
  if (clearSelBtn) {
    clearSelBtn.addEventListener('click', () => {
      selectedSpan = null;
      drawTimeline();
      buildTraceListPanel(lo, hi);
    });
  }
  // Keep th top in sync with sticky wrapper height
  const stickyTop = document.getElementById('trace-sticky-top');
  if (stickyTop) {
    const topH = stickyTop.offsetHeight;
    container.querySelectorAll('th').forEach(th => { th.style.top = topH + 'px'; });
  }

  // Sort header click handlers
  container.querySelectorAll('th[data-sort]').forEach(th => {
    th.addEventListener('click', () => {
      const key = th.dataset.sort;
      if (traceListSortKey === key) traceListSortAsc = !traceListSortAsc;
      else { traceListSortKey = key; traceListSortAsc = true; }
      buildTraceListPanel(lo, hi);
    });
  });

  // Row hover + click handlers
  container.querySelectorAll('tr.trace-row').forEach(row => {
    row.addEventListener('click', (ev) => {
      if (ev.target.closest('a')) return; // let link navigate, don't select row
      const id = parseInt(row.dataset.spanId);
      const span = spanById[id];
      if (!span) return;
      selectedSpan = (selectedSpan === span) ? null : span;
      drawTimeline();
      buildTraceListPanel(lo, hi);
    });
    row.addEventListener('mouseenter', () => {
      const id = parseInt(row.dataset.spanId);
      const span = spanById[id];
      if (span && lastHoveredSpan !== span) {
        lastHoveredSpan = span;
        drawTimeline();
      }
      row.classList.add('hovered');
    });
    row.addEventListener('mouseleave', () => {
      row.classList.remove('hovered');
      if (lastHoveredSpan) {
        lastHoveredSpan = null;
        drawTimeline();
      }
    });
  });
}


document.getElementById('btn-toggle-aborts').addEventListener('click', () => {
  const panel = document.getElementById('trace-panel');
  const btn = document.getElementById('btn-toggle-aborts');
  const rh = document.getElementById('trace-panel-resize-handle');
  const isOpen = panel.classList.toggle('open');
  btn.textContent = isOpen ? '\u25bc trace list' : '\u25b6 trace list';
  panel.style.height = isOpen ? tracePanelH + 'px' : '0px';
  rh.style.display = isOpen ? '' : 'none';
});
document.getElementById('btn-toggle-fg').addEventListener('click', () => {
  const container = document.getElementById('flamegraph-container');
  const btn = document.getElementById('btn-toggle-fg');
  container.classList.toggle('open');
  btn.textContent = container.classList.contains('open') ? '▼ flamegraph' : '▶ flamegraph';
  if (container.classList.contains('open')) drawFlamegraph(viewStart, viewEnd);
});

// Sync: highlight trace list row when timeline hover changes
function syncTraceListHighlight(span) {
  const panel = document.getElementById('trace-panel');
  if (!panel) return;
  // Remove previous transient highlight (not the selected one)
  const prev = panel.querySelector('tr.trace-row.highlighted');
  if (prev) prev.classList.remove('highlighted');
  if (!span) return;
  const row = panel.querySelector('tr.trace-row[data-span-id="' + span.id + '"]');
  if (row) {
    if (!row.classList.contains('selected')) row.classList.add('highlighted');
    if (panel.classList.contains('open')) {
      row.scrollIntoView({block: 'nearest', behavior: 'instant'});
    }
  }
}

// --- Build trace spans (connect start → stop/abort) with depth-based nesting ---
const traceSpans = [];
const spanById = {};
const childrenOf = {};
const flushTimes = [];
{
  const pending = {};
  for (const e of EVENTS) {
    if (e.type === 'trace_start') {
      pending[e.id] = e;
    } else if (e.type === 'trace_stop' || e.type === 'trace_abort') {
      const start = pending[e.id];
      if (start) {
        const span = {
          id: e.id,
          t0: start.time,
          t1: e.time,
          start: start,
          end: e,
          depth: start.depth || 0,
          outcome: e.type === 'trace_stop' ? 'stop' : 'abort',
          category: e.type === 'trace_stop' ? 'completed' : (e.abort_reason || '?'),
        };
        traceSpans.push(span);
        spanById[e.id] = span;
        if (start.parent_id) {
          if (!childrenOf[start.parent_id]) childrenOf[start.parent_id] = [];
          childrenOf[start.parent_id].push(span);
        }
        delete pending[e.id];
      }
    } else if (e.type === 'trace_flush') {
      flushTimes.push(e.time);
      for (const id in pending) delete pending[id];
    }
  }
}
traceSpans.sort((a, b) => a.t0 - b.t0);

// Compute max depth for layout
let maxTraceDepth = 0;
for (const span of traceSpans) {
  if (span.depth > maxTraceDepth) maxTraceDepth = span.depth;
}
const totalLanes = Math.max(5, maxTraceDepth + 1);

let visibleSpanRects = [];
let lastHoveredSpan = null;
let selectedSpan = null;
let panClickSpanCandidate = null; // span under cursor at mousedown in trace area
let lastPanelRangeKey = '';

// --- Trace filter ---
const allTraceCategories = {};
for (const span of traceSpans) {
  allTraceCategories[span.category] = (allTraceCategories[span.category] || 0) + 1;
}
{
  let fc = 0;
  for (const e of EVENTS) if (e.type === 'trace_flush') fc++;
  if (fc > 0) allTraceCategories['trace_flush'] = fc;
}
const enabledCategories = new Set(Object.keys(allTraceCategories));
const categoryList = Object.entries(allTraceCategories).sort((a, b) => b[1] - a[1]);

function buildFilterPanel(tStart, tEnd) {
  const lo = (tStart !== undefined) ? tStart : viewStart;
  const hi = (tEnd !== undefined) ? tEnd : viewEnd;
  const panel = document.getElementById('filter-panel');

  // Recalculate what categories are actually visible in current range
  const zoomCategories = {};
  for (const span of traceSpans) {
    const t = span.t0 - timeOrigin;
    if (span.t1 - timeOrigin < lo || t > hi) continue;
    zoomCategories[span.category] = (zoomCategories[span.category] || 0) + 1;
  }
  {
    for (const e of EVENTS) {
      if (e.type !== 'trace_flush') continue;
      const t = e.time - timeOrigin;
      if (t < lo || t > hi) continue;
      zoomCategories['trace_flush'] = (zoomCategories['trace_flush'] || 0) + 1;
    }
  }

  const allSelected = categoryList.every(([cat]) => enabledCategories.has(cat));
  const noneSelected = enabledCategories.size === 0;
  const allActive = allSelected ? `color:${COLORS.ok}` : '';
  const noneActive = noneSelected ? 'border-color:#ef6461;color:#ef6461;background:#3e1e1e' : '';

  const totalZoom = Object.values(zoomCategories).reduce((a,b)=>a+b,0);
  const allCheckedStyle = allSelected ? `color:${COLORS.ok}` : 'color:#888';
  const noneCheckedStyle = noneSelected ? 'color:#ef6461' : 'color:#888';

  let html = '<div class="filter-grid">';
  html += `<span class="filter-all-btn" id="filter-all" style="${allCheckedStyle}"><span class="custom-cb">${allSelected ? '☑' : '☐'}</span> all <span class="filter-count">(${totalZoom})</span></span>`;
  html += `<span class="filter-none-btn" id="filter-none" style="${noneCheckedStyle}"><span class="custom-cb">${noneSelected ? '☑' : '☐'}</span> none</span>`;
  categoryList.forEach(([cat, count], idx) => {
    const color = cat === 'completed' ? COLORS.ok : COLORS.abort;
    const isEnabled = enabledCategories.has(cat);
    const checkedChar = isEnabled ? '☑' : '☐';
    const checkedStyle = isEnabled ? `` : 'color:#888';
    const escaped = cat.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/"/g,'&quot;');
    const zoomCount = zoomCategories[cat] || 0;
    const countStyle = zoomCount === 0 ? `color:${COLORS.borderStrong}` : `color:${COLORS.textFaint}`;
    html += `<label style="${zoomCount === 0 ? 'opacity:0.5' : ''}; ${checkedStyle}" data-cat-idx="${idx}"><span class="custom-cb">${checkedChar}</span> <span style="color:${color}">■</span> ${escaped} <span class="filter-count" style="${countStyle}">(${zoomCount})</span></label>`;
  });
  html += '</div>';
  panel.innerHTML = html;

  function syncFilterButtonStyles() {
    const allSel = categoryList.every(([c]) => enabledCategories.has(c));
    const noneSel = enabledCategories.size === 0;
    const allBtn = document.getElementById('filter-all');
    const noneBtn = document.getElementById('filter-none');
    if (allBtn) { allBtn.style.color = allSel ? COLORS.ok : COLORS.textDim; allBtn.querySelector('.custom-cb').textContent = allSel ? '☑' : '☐'; }
    if (noneBtn) { noneBtn.style.color = noneSel ? COLORS.abort : COLORS.textDim; noneBtn.querySelector('.custom-cb').textContent = noneSel ? '☑' : '☐'; }
  }

  panel.querySelectorAll('label[data-cat-idx]').forEach(label => {
    label.addEventListener('click', () => {
      const idx = parseInt(label.dataset.catIdx);
      const cat = categoryList[idx][0];
      if (enabledCategories.has(cat)) enabledCategories.delete(cat);
      else enabledCategories.add(cat);
      
      const isEnabled = enabledCategories.has(cat);
      label.querySelector('.custom-cb').textContent = isEnabled ? '☑' : '☐';
      label.style.color = isEnabled ? '' : '#888';

      drawTimeline();
      syncFilterButtonStyles();
      schedulePanelUpdate(lo, hi);
    });
  });
  document.getElementById('filter-all')?.addEventListener('click', () => {
    categoryList.forEach(([cat]) => enabledCategories.add(cat));
    drawTimeline();
    buildFilterPanel(lo, hi);
    schedulePanelUpdate(lo, hi);
  });
  document.getElementById('filter-none')?.addEventListener('click', () => {
    enabledCategories.clear();
    drawTimeline();
    buildFilterPanel(lo, hi);
    schedulePanelUpdate(lo, hi);
  });
}
buildTraceListPanel();

// --- Timeline ---
const tlCanvas = document.getElementById('timeline-canvas');
const tlCtx = tlCanvas.getContext('2d');
const selOverlay = document.getElementById('selection-overlay');
const tooltip = document.getElementById('tooltip');

function eventColor(e) {
  switch(e.type) {
    case 'sample': return sampleColor(e);
    case 'trace_start': return COLORS.okLight;
    case 'trace_stop': return COLORS.ok;
    case 'trace_abort': return COLORS.abort;
    case 'trace_flush': return COLORS.abort;
    case 'section_start': return COLORS.sectionStart;
    case 'section_end': return COLORS.sectionEnd;
    default: return COLORS.textFaint;
  }
}

function resizeCanvas(canvas) {
  const rect = canvas.parentElement.getBoundingClientRect();
  const dpr = window.devicePixelRatio || 1;
  canvas.width = rect.width * dpr;
  canvas.height = rect.height * dpr;
  canvas.style.width = rect.width + 'px';
  canvas.style.height = rect.height + 'px';
  return dpr;
}

function drawTimeline() {
  const dpr = resizeCanvas(tlCanvas);
  const W = tlCanvas.width, H = tlCanvas.height;
  tlCtx.setTransform(dpr, 0, 0, dpr, 0, 0);
  const w = W / dpr, h = H / dpr;

  const currentRange = (selStart !== null && selEnd !== null) 
    ? [Math.min(selStart, selEnd), Math.max(selStart, selEnd)] 
    : [viewStart, viewEnd];

  tlCtx.fillStyle = COLORS.bgDeep;

  const vDur = viewEnd - viewStart || 1;

  // Draw section bands first (background)
  const sectionStarts = {};
  for (const e of EVENTS) {
    const t = e.time - timeOrigin;
    if (t < viewStart || t > viewEnd) continue;
    const x = ((t - viewStart) / vDur) * w;
    if (e.type === 'section_start') {
      const secName = e.name || '';
      if (hoveredSection !== secName) continue;
      sectionStarts[e.section_path || e.name] = x;
    } else if (e.type === 'section_end') {
      const secName = e.name || '';
      if (hoveredSection !== secName) continue;
      const key = (e.section_path ? e.section_path + (e.name ? ' > ' + e.name : '') : e.name) || '';
      for (const k of Object.keys(sectionStarts)) {
        if (key.startsWith(k) || k.startsWith(key) || k === e.name) {
          const sx = sectionStarts[k];
          tlCtx.fillStyle = COLORS.jitBand;
          tlCtx.fillRect(sx, 0, x - sx, h);
          delete sectionStarts[k];
          break;
        }
      }
    }
  }

  // Layout: vm state (top, smaller) + traces (bottom, larger)
  sampleH = Math.min(35, Math.round(h * 0.14));
  const traceY = sampleH + 4; // 4px gap for divider
  const traceH = h - traceY;

  // Draw trace_flush as subtle bands in sample area (prominent rendering is in trace area below)
  if (enabledCategories.has('trace_flush')) {
    for (const ft of flushTimes) {
      const t = ft - timeOrigin;
      if (t < viewStart || t > viewEnd) continue;
      const x = ((t - viewStart) / vDur) * w;
      tlCtx.fillStyle = COLORS.abortBand;
      tlCtx.fillRect(x - 2, 0, 4, sampleH);
      tlCtx.fillStyle = COLORS.abort;
      tlCtx.fillRect(x, 0, 1, sampleH);
    }
  }

  // Draw samples and section boundaries
  for (const e of EVENTS) {
    if (e.type.startsWith('trace_')) continue;
    const t = e.time - timeOrigin;
    if (t < viewStart || t > viewEnd) continue;
    const x = ((t - viewStart) / vDur) * w;

    if (e.type === 'sample') {
      const matchesPie = !pieHoveredState || e.vm_state === pieHoveredState;
      if (!matchesPie) continue;
      tlCtx.fillStyle = sampleColor(e);
      tlCtx.globalAlpha = 0.8;
      tlCtx.fillRect(x, 2, 1.5, sampleH - 4);
      tlCtx.globalAlpha = 1;
    } else if (e.type === 'section_start' || e.type === 'section_end') {
      if (hoveredSection !== (e.name || '')) continue;
      tlCtx.fillStyle = eventColor(e);
      tlCtx.globalAlpha = 0.4;
      tlCtx.fillRect(x, 0, 1, h);
      tlCtx.globalAlpha = 1;
    }
  }

  tlCtx.strokeStyle = COLORS.borderStrong;
  tlCtx.lineWidth = 1;
  tlCtx.beginPath();
  tlCtx.moveTo(0, sampleH + 2);
  tlCtx.lineTo(w, sampleH + 2);
  tlCtx.stroke();

  tlCtx.strokeStyle = COLORS.bgSeparator;
  tlCtx.lineWidth = 0.5;
  // Exponential lane heights clamped between MIN_LANE_H and MAX_LANE_H;
  // excess space distributed evenly so lanes converge as timeline grows.
  const EXP_R = 0.75;
  const MIN_LANE_H = 3, MAX_LANE_H = 20;
  const availLaneH = traceH - 6;
  const h0raw = totalLanes <= 1 ? availLaneH
    : availLaneH * (1 - EXP_R) / (1 - Math.pow(EXP_R, totalLanes));
  const h0 = Math.min(MAX_LANE_H, Math.max(MIN_LANE_H, h0raw));
  const laneHeights = [];
  const laneTops = [];
  let nominalTotal = 0;
  for (let i = 0; i < totalLanes; i++) {
    laneHeights[i] = Math.min(MAX_LANE_H, Math.max(MIN_LANE_H, h0 * Math.pow(EXP_R, i)));
    nominalTotal += laneHeights[i];
  }
  // Distribute leftover space equally so lanes converge as timeline grows
  const bonus = Math.max(0, (availLaneH - nominalTotal) / totalLanes);
  let acc = 0;
  for (let i = 0; i < totalLanes; i++) {
    laneHeights[i] = Math.min(MAX_LANE_H, laneHeights[i] + bonus);
    laneTops[i] = acc;
    acc += laneHeights[i];
  }
  for (let i = 0; i < totalLanes; i++) {
    const ly = traceY + 2 + laneTops[i];
    tlCtx.beginPath();
    tlCtx.moveTo(0, ly + laneHeights[i]);
    tlCtx.lineTo(w, ly + laneHeights[i]);
    tlCtx.stroke();
  }

  // Health-based color for trace spans
  function spanColor(span) {
    if (span.outcome === 'abort') return [COLORS.abort, COLORS.abort];
    const lt = span.end.linktype;
    if (lt === 'stitch') return [COLORS.stitch, COLORS.stitch];
    if (lt === 'root') return [COLORS.linked, COLORS.linked];
    return [COLORS.ok, COLORS.ok];
  }

  // Draw FLUSH lines (prominent, full height of trace region)
  if (enabledCategories.has('trace_flush')) {
    tlCtx.save();
    tlCtx.setLineDash([5, 4]);
    tlCtx.strokeStyle = COLORS.abort;
    tlCtx.lineWidth = 2;
    tlCtx.font = 'bold 9px monospace';
    tlCtx.fillStyle = COLORS.abort;
    for (const ft of flushTimes) {
      const t = ft - timeOrigin;
      if (t < viewStart || t > viewEnd) continue;
      const fx = ((t - viewStart) / vDur) * w;
      // Semi-transparent band
      tlCtx.fillStyle = COLORS.flushBand;
      tlCtx.fillRect(fx - 8, traceY, 16, traceH);
      // Dashed line
      tlCtx.strokeStyle = COLORS.abort;
      tlCtx.beginPath();
      tlCtx.moveTo(fx, traceY);
      tlCtx.lineTo(fx, traceY + traceH);
      tlCtx.stroke();
      // Label
      tlCtx.fillStyle = COLORS.abort;
      tlCtx.fillText('FLUSH', fx + 3, traceY + 10);
    }
    tlCtx.restore();
  }

  // Draw trace spans in depth-based swimlanes
  visibleSpanRects = [];
  let hoveredSpan = null;

  const TRACE_W = 8;
  for (const span of traceSpans) {
    if (!enabledCategories.has(span.category)) continue;
    const st = span.t0 - timeOrigin;
    if (st < viewStart - (TRACE_W / (w / vDur)) || st > viewEnd) continue;

    const x0 = ((st - viewStart) / vDur) * w;
    const bw = TRACE_W;
    const lane = Math.min(span.depth, totalLanes - 1);
    const lh = laneHeights[lane];
    const laneGap = lh > 4 ? 1 : 0.5;
    const barH = lh - laneGap;
    const by = traceY + 2 + laneTops[lane];
    const [fill, stroke] = spanColor(span);

    tlCtx.fillStyle = fill;
    tlCtx.fillRect(x0, by, bw, barH);

    // Label if wide enough
    if (bw > 28) {
      tlCtx.fillStyle = COLORS.spanLabel;
      tlCtx.font = '9px monospace';
      const lb = '#' + span.id + (span.outcome === 'abort' ? ' ✗' : '');
      tlCtx.fillText(lb, x0 + 2, by + barH - 3, bw - 4);
    }

    visibleSpanRects.push({x: x0, y: by, w: bw, h: barH, span: span});
  }

  // Draw parent-child connection lines for the active span (selected takes priority over hovered)
  if (lastHoveredSpan || selectedSpan) {
    tlCtx.save();

    function drawConn(parentSpan, childSpan, color) {
      const pt = parentSpan.t0 - timeOrigin;
      const ct = childSpan.t0 - timeOrigin;
      if (pt > viewEnd || ct > viewEnd) return;
      const px = ((pt - viewStart) / vDur) * w + TRACE_W / 2;
      const pLane = Math.min(parentSpan.depth, totalLanes - 1);
      const py = traceY + 2 + laneTops[pLane] + laneHeights[pLane] / 2;
      const cx2 = ((ct - viewStart) / vDur) * w + TRACE_W / 2;
      const cLane = Math.min(childSpan.depth, totalLanes - 1);
      const cy = traceY + 2 + laneTops[cLane] + laneHeights[cLane] / 2;
      const midY = (py + cy) / 2;
      tlCtx.strokeStyle = color;
      tlCtx.beginPath();
      tlCtx.moveTo(px, py);
      tlCtx.bezierCurveTo(px, midY, cx2, midY, cx2, cy);
      tlCtx.stroke();
      tlCtx.fillStyle = color;
      tlCtx.beginPath(); tlCtx.arc(px, py, 2.5, 0, Math.PI * 2); tlCtx.fill();
      tlCtx.beginPath(); tlCtx.arc(cx2, cy, 2.5, 0, Math.PI * 2); tlCtx.fill();
    }

    function drawSpanTree(hs, hotColor, dimColor) {
      let root = hs;
      while (root.start.parent_id && spanById[root.start.parent_id]) {
        root = spanById[root.start.parent_id];
      }
      tlCtx.setLineDash([3, 3]);
      tlCtx.lineWidth = 1.5;
      const treeQueue = [root];
      while (treeQueue.length > 0) {
        const node = treeQueue.shift();
        const kids = childrenOf[node.id];
        if (!kids) continue;
        for (const child of kids) {
          const isHot = (node === hs || child === hs);
          drawConn(node, child, isHot ? hotColor : dimColor);
          treeQueue.push(child);
        }
      }
    }

    // Draw selected span tree (always visible, golden)
    if (selectedSpan) {
      drawSpanTree(selectedSpan, COLORS.selectTreeLine, COLORS.selectTreeFill);
    }
    // Draw hovered span tree on top (if different from selected, cyan)
    if (lastHoveredSpan && lastHoveredSpan !== selectedSpan) {
      drawSpanTree(lastHoveredSpan, COLORS.hoverTreeLine, COLORS.hoverTreeFill);
    }

    tlCtx.setLineDash([]);

    // Glow selected span
    if (selectedSpan) {
      for (const r of visibleSpanRects) {
        if (r.span === selectedSpan) {
          tlCtx.shadowColor = COLORS.selectGlow;
          tlCtx.shadowBlur = 8;
          tlCtx.strokeStyle = COLORS.select;
          tlCtx.lineWidth = 2;
          tlCtx.strokeRect(r.x, r.y, r.w, r.h);
          tlCtx.shadowBlur = 0;
          break;
        }
      }
    }
    // Highlight hovered span border
    const borderTarget = lastHoveredSpan || selectedSpan;
    if (borderTarget) {
      for (const r of visibleSpanRects) {
        if (r.span === borderTarget && borderTarget !== selectedSpan) {
          tlCtx.strokeStyle = COLORS.white;
          tlCtx.strokeRect(r.x, r.y, r.w, r.h);
          break;
        }
      }
    }
    tlCtx.restore();
  }

  // Region labels + depth labels drawn on top of boxes and hover lines
  function drawCanvasLabel(text, x, y, font) {
    tlCtx.font = font || '9px monospace';
    const tw = tlCtx.measureText(text).width;
    const pad = 2, lh = 9;
    tlCtx.fillStyle = COLORS.tooltipBg;
    tlCtx.fillRect(x - pad, y - lh, tw + pad * 2, lh + 3);
    tlCtx.fillStyle = COLORS.textMuted;
    tlCtx.fillText(text, x, y);
  }
  drawCanvasLabel('vm state', 4, 10);

  // Inline canvas legends — shown only while the timeline is hovered
  if (tlHovered) {
    // Helper: draw a horizontal legend row centered in a band
    function drawInlineLegend(items, centerX, midY) {
      tlCtx.font = '8px monospace';
      const swatchW = 7, swatchH = 7, gap = 4, itemGap = 10;
      // Measure total width
      let totalW = 0;
      for (const {label} of items) totalW += swatchW + gap + tlCtx.measureText(label).width + itemGap;
      totalW -= itemGap;
      let ix = centerX - totalW / 2;
      const bgPad = 5;
      tlCtx.fillStyle = COLORS.tooltipBgDim;
      tlCtx.fillRect(ix - bgPad, midY - 8, totalW + bgPad * 2, 12);
      for (const {color, label, dashed} of items) {
        tlCtx.fillStyle = color;
        if (dashed) {
          tlCtx.strokeStyle = color;
          tlCtx.lineWidth = 1;
          tlCtx.setLineDash([2, 2]);
          tlCtx.strokeRect(ix, midY - swatchH + 1, swatchW, swatchH);
          tlCtx.setLineDash([]);
        } else {
          tlCtx.fillRect(ix, midY - swatchH + 1, swatchW, swatchH);
        }
        tlCtx.fillStyle = COLORS.textMid;
        tlCtx.fillText(label, ix + swatchW + gap, midY);
        ix += swatchW + gap + tlCtx.measureText(label).width + itemGap;
      }
    }
    // VM state legend — bottom-center of vm state area
    const vmItems = [
      {color: COLORS.ok,    label: 'native'},
      {color: COLORS.stitch,label: 'interpreter'},
      {color: COLORS.linked,label: 'c'},
      {color: COLORS.abort, label: 'gc'},
      {color: COLORS.jit,   label: 'jit'},
    ];
    drawInlineLegend(vmItems, w / 2, sampleH - 4);
    // Trace type legend — center of root trace lane (lane 0)
    const rootMidY = h - 3;
    const traceItems = [
      {color: COLORS.ok,    label: 'OK'},
      {color: COLORS.linked,label: 'Linked'},
      {color: COLORS.stitch,label: 'Stitch'},
      {color: COLORS.abort, label: 'Aborted'},
      {color: COLORS.abort, label: 'Flush', dashed: true},
    ];
    drawInlineLegend(traceItems, w / 2, rootMidY);
  }
  // Depth labels: root trace, d1, d2, d3, d.., d{maxDepth}
  {
    const maxDepth = totalLanes - 1;
    // Build list of lane indices to label
    const labelLanes = []; // {lane, text}
    labelLanes.push({lane: 0, text: 'root trace'});
    for (let i = 1; i <= Math.min(3, maxDepth); i++) {
      labelLanes.push({lane: i, text: 'd' + i});
    }
    if (maxDepth > 4) {
      // insert ellipsis after d3 (not a real lane, just drawn at lane 4 position)
      labelLanes.push({lane: 4, text: 'd\u2026'});
    }
    if (maxDepth > 3) {
      labelLanes.push({lane: maxDepth, text: 'd' + maxDepth});
    }
    tlCtx.font = '8px monospace';
    for (const {lane, text} of labelLanes) {
      const li = Math.min(lane, totalLanes - 1);
      const ly = traceY + 2 + laneTops[li] + laneHeights[li] / 2 + 3;
      const tw = tlCtx.measureText(text).width;
      tlCtx.fillStyle = COLORS.tooltipBg;
      tlCtx.fillRect(0, ly - 8, tw + 4, 11);
      tlCtx.fillStyle = COLORS.textDim;
      tlCtx.fillText(text, 2, ly);
    }
  }


  // Schedule panel updates (debounced) — avoids rebuilding DOM on every canvas frame
  const rangeKey = currentRange[0].toFixed(6) + ':' + currentRange[1].toFixed(6);
  if (rangeKey !== lastPanelRangeKey) {
    lastPanelRangeKey = rangeKey;
    schedulePanelUpdate(currentRange[0], currentRange[1]);
  }
}

function tlXToTime(clientX) {
  const rect = getTlRect();
  const frac = (clientX - rect.left) / rect.width;
  return viewStart + frac * (viewEnd - viewStart);
}

// --- Timeline tooltip ---
function formatTooltip(e) {
  const t = (e.time - timeOrigin).toFixed(6);
  let s = `<b>${e.type}</b>  <span style="color:${COLORS.textDimmer}">${t}s</span>`;

  switch(e.type) {
    case 'sample': {
      const stateLabel = VM_STATE_LABELS[e.vm_state] || e.vm_state || '?';
      const stateColor = VM_STATE_COLORS[e.vm_state] || COLORS.textBright;
      s += `\n<span style="color:${stateColor}">● ${stateLabel}</span>`;
      if (e.section_path) s += `\nSection: ${e.section_path}`;
      break;
    }
    case 'trace_start':
      s += `\nTrace <b>#${e.id}</b>`;
      if (e.parent_id) s += `  (side of #${e.parent_id} exit ${e.exit_id})`;
      if (e.func_info) s += `\nLocation: ${funcInfoLink(e.func_info)}`;
      break;
    case 'trace_stop':
      s += `\nTrace <b>#${e.id}</b> completed`;
      if (e.linktype) s += `  link: ${e.linktype}`;
      if (e.link_id) s += ` → #${e.link_id}`;
      if (e.ir_count) s += `\nIR: ${e.ir_count} instructions, ${e.exit_count || 0} exits`;
      if (e.func_info) s += `\nLocation: ${funcInfoLink(e.func_info)}`;
      break;
    case 'trace_abort':
      s += `\nTrace <b>#${e.id}</b> aborted`;
      s += `\n<span style="color:${COLORS.abort}">${e.abort_reason || '?'}</span>`;
      if (e.func_info) s += `\nLocation: ${funcInfoLink(e.func_info)}`;
      break;
    case 'trace_flush':
      s += `\n<span style="color:${COLORS.abort}">All traces flushed — recompilation storm</span>`;
      break;
    case 'section_start':
      s += `\nSection: <b>${e.name}</b>`;
      if (e.section_path) s += `\nPath: ${e.section_path}`;
      break;
    case 'section_end':
      s += `\nSection end: <b>${e.name}</b>`;
      break;
  }
  return s;
}

function formatSpanTooltip(span) {
  const duration = span.t1 - span.t0;
  const dStr = duration < 0.001 ? (duration * 1e6).toFixed(0) + 'µs' : (duration * 1000).toFixed(2) + 'ms';
  const t0 = (span.t0 - timeOrigin).toFixed(6);
  let s = '';
  if (span.outcome === 'stop') {
    const lt = span.end.linktype || '?';
    const ltColor = lt === 'stitch' ? COLORS.stitch : lt === 'root' ? COLORS.linked : COLORS.ok;
    s += `<b style="color:${ltColor}">Trace #${span.id}</b>  <span style="color:${COLORS.textDimmer}">${t0}s</span>  ${dStr}`;
    const e = span.end;
    if (e.linktype) s += `\nLink: <b>${e.linktype}</b>`;
    if (e.link_id) s += ` → #${e.link_id}`;
    if (e.ir_count) s += `\nIR: ${e.ir_count} instructions, ${e.exit_count || 0} exits`;
  } else {
    s += `<b style="color:${COLORS.abort}">Trace #${span.id} aborted</b>  <span style="color:${COLORS.textDimmer}">${t0}s</span>  ${dStr}`;
    s += `\n<span style="color:${COLORS.abort}">${span.end.abort_reason || '?'}</span>`;
  }
  if (span.start.func_info) s += `\n ${funcInfoLink(span.start.func_info)}`;
  if (span.start.parent_id) s += `\n↑ parent #${span.start.parent_id} (exit ${span.start.exit_id})`;
  if (span.end.func_info && span.end.func_info !== span.start.func_info) s += `\n   → ${funcInfoLink(span.end.func_info)}`;
  const kids = childrenOf[span.id];
  if (kids && kids.length > 0) {
    const okKids = kids.filter(k => k.outcome === 'stop').length;
    const abKids = kids.length - okKids;
    s += `\n↓ ${kids.length} side trace${kids.length > 1 ? 's' : ''}`;
    if (abKids > 0) s += ` <span style="color:${COLORS.abort}">(${abKids} aborted)</span>`;
  }
  s += `\n<span style="color:${COLORS.textVeryDim}">depth: ${span.depth}</span>`;
  return s;
}

tlCanvas.addEventListener('mousedown', (ev) => {
  tooltip.style.display = 'none';
  const rect = getTlRect();
  const mouseY = ev.clientY - rect.top;
  const curSampleH = Math.min(35, Math.round(rect.height * 0.14));
  if (mouseY <= curSampleH) {
    // VM state area — draw selection
    dragMode = 'select';
    selStart = tlXToTime(ev.clientX);
    selEnd = selStart;
    selOverlay.style.display = 'block';
    updateSelOverlay();
  } else {
    // Trace area — pan the view (or click to select a span)
    dragMode = 'pan';
    panStartX = ev.clientX;
    panViewStart0 = viewStart;
    panViewEnd0 = viewEnd;
    tlCanvas.style.cursor = 'grabbing';
    // Use the already-accurate hover result as the click candidate
    panClickSpanCandidate = lastHoveredSpan;
  }
});

tlCanvas.addEventListener('mousemove', (ev) => {
  if (dragMode) return;

  const rect = tlCanvas.getBoundingClientRect();
  const t = tlXToTime(ev.clientX);
  const vDur = viewEnd - viewStart || 1;
  const threshold = (vDur / rect.width) * 8;
  const mouseX = ev.clientX - rect.left;
  const mouseY = ev.clientY - rect.top;
  const h = rect.height;
  const curSampleH = Math.min(35, Math.round(h * 0.14));
  const inSampleRegion = mouseY < curSampleH;

  let tooltipContent = null;

  if (inSampleRegion) {
    // Find closest sample
    let closest = null;
    let minDist = threshold;
    for (const e of EVENTS) {
      if (e.type !== 'sample') continue;
      const et = e.time - timeOrigin;
      const d = Math.abs(et - t);
      if (d < minDist) { minDist = d; closest = e; }
    }
    if (closest) tooltipContent = formatTooltip(closest);
  } else {
    // Hit-test trace span rects
    for (let i = visibleSpanRects.length - 1; i >= 0; i--) {
      const r = visibleSpanRects[i];
      if (mouseX >= r.x && mouseX <= r.x + r.w && mouseY >= r.y && mouseY <= r.y + r.h) {
        tooltipContent = formatSpanTooltip(r.span);
        if (lastHoveredSpan !== r.span) {
          lastHoveredSpan = r.span;
          syncTraceListHighlight(r.span);
          drawTimeline();
        }
        break;
      }
    }
    if (!tooltipContent && lastHoveredSpan) {
      lastHoveredSpan = null;
      syncTraceListHighlight(null);
      drawTimeline();
    }
    // Fallback: nearest trace event by time
    if (!tooltipContent) {
      let closest = null;
      let minDist = threshold;
      for (const e of EVENTS) {
        if (!e.type.startsWith('trace_')) continue;
        if (e.type !== 'trace_flush') continue;
        const et = e.time - timeOrigin;
        const d = Math.abs(et - t);
        if (d < minDist) { minDist = d; closest = e; }
      }
      if (closest) tooltipContent = formatTooltip(closest);
    }
  }

  if (tooltipContent) {
    tooltip.innerHTML = tooltipContent;
    tooltip.style.pointerEvents = 'none';
    tooltip.style.display = 'block';
    tooltip.style.left = Math.min(ev.clientX + 15, window.innerWidth - 520) + 'px';
    tooltip.style.top = (ev.clientY + 15) + 'px';
    tlCanvas.style.cursor = 'pointer';
  } else {
    tooltip.style.display = 'none';
    tlCanvas.style.cursor = inSampleRegion ? 'crosshair' : 'grab';
  }
});

tlCanvas.addEventListener('mouseenter', () => {
  tlHovered = true;
  drawTimeline();
});

tlCanvas.addEventListener('mouseleave', () => {
  tlHovered = false;
  if (!dragMode) {
    tooltip.style.display = 'none';
    tlCanvas.style.cursor = 'crosshair';
    if (lastHoveredSpan) {
      lastHoveredSpan = null;
      syncTraceListHighlight(null);
      drawTimeline();
    }
  }
});

window.addEventListener('mousemove', (ev) => {
  if (!dragMode) return;
  if (dragMode === 'select') {
    selEnd = tlXToTime(ev.clientX);
    updateSelOverlay();
  } else if (dragMode === 'pan') {
    const rect = getTlRect();
    const dx = ev.clientX - panStartX;
    const vDur = panViewEnd0 - panViewStart0 || 1;
    const dt = -(dx / rect.width) * vDur;
    let newStart = panViewStart0 + dt;
    let newEnd = panViewEnd0 + dt;
    if (newStart < 0) { newEnd -= newStart; newStart = 0; }
    if (newEnd > timeDuration) { newStart -= (newEnd - timeDuration); newEnd = timeDuration; }
    viewStart = Math.max(0, newStart);
    viewEnd = Math.min(timeDuration, newEnd);
    selStart = viewStart; selEnd = viewEnd;
    document.getElementById('selection-info').textContent = `selected: ${(viewEnd - viewStart).toFixed(4)}s (${viewStart.toFixed(4)}s \u2014 ${viewEnd.toFixed(4)}s)`;
    drawTimeline();
    updateSelOverlay();
    scheduleFlamegraph(viewStart, viewEnd);
  }
});

window.addEventListener('mouseup', () => {
  if (!dragMode) return;
  const mode = dragMode;
  dragMode = null;
  if (mode === 'select') {
    if (selStart !== null && selEnd !== null) {
      let lo = Math.min(selStart, selEnd), hi = Math.max(selStart, selEnd);
      if (hi - lo <= 0.0001) {
        // Single click — select full current view
        selStart = viewStart; selEnd = viewEnd;
        lo = viewStart; hi = viewEnd;
      }
      const info = document.getElementById('selection-info');
      info.textContent = `selected: ${(hi - lo).toFixed(4)}s (${lo.toFixed(4)}s \u2014 ${hi.toFixed(4)}s)`;
      updateSelOverlay();
      drawFlamegraph(lo, hi);
    }
  } else if (mode === 'pan') {
    tlCanvas.style.cursor = 'grab';
    // If the view didn't actually move it's a click — select/deselect the span
    const actualMoved = Math.abs(viewStart - panViewStart0) > 0.000001 ||
                        Math.abs(viewEnd - panViewEnd0) > 0.000001;
    if (!actualMoved && panClickSpanCandidate) {
      const span = panClickSpanCandidate;
      selectedSpan = (selectedSpan === span) ? null : span;
      panClickSpanCandidate = null;
      drawTimeline();
      syncTraceListHighlight(selectedSpan);
      schedulePanelUpdate(selStart, selEnd);
    }
    panClickSpanCandidate = null;
  }
});

function updateSelOverlay() {
  if (selStart === null || selEnd === null) { selOverlay.style.display = 'none'; return; }
  // Use cached rect — getBoundingClientRect forces layout reflow, avoid calling it every tick
  const rect = getTlRect();
  const vDur = viewEnd - viewStart || 1;
  const lo = Math.min(selStart, selEnd), hi = Math.max(selStart, selEnd);
  const lx = ((lo - viewStart) / vDur) * rect.width;
  const rx = ((hi - viewStart) / vDur) * rect.width;
  selOverlay.style.left = lx + 'px';
  selOverlay.style.width = Math.max(1, rx - lx) + 'px';
  selOverlay.style.height = sampleH + 'px';
  selOverlay.style.display = 'block';
  // Time labels
  const startEl = document.getElementById('sel-t-start');
  const endEl = document.getElementById('sel-t-end');
  if (startEl) startEl.textContent = lo.toFixed(4) + 's';
  if (endEl) endEl.textContent = hi.toFixed(4) + 's';
  // NOTE: panels are updated via drawTimeline's debounced schedulePanelUpdate, not here,
  // to avoid double-building them on every wheel/drag tick.
  schedulePanelUpdate(lo, hi);
}

document.getElementById('btn-reset').addEventListener('click', () => {
  viewStart = 0; viewEnd = timeDuration;
  selStart = 0; selEnd = timeDuration;
  document.getElementById('selection-info').textContent = `selected: ${timeDuration.toFixed(4)}s (0.0000s \u2014 ${timeDuration.toFixed(4)}s)`;
  drawTimeline();
  updateSelOverlay();
  drawFlamegraph(0, timeDuration);
  drawVmPie(0, timeDuration);
});

document.getElementById('btn-zoom-sel').addEventListener('click', () => {
  if (selStart !== null && selEnd !== null) {
    const lo = Math.min(selStart, selEnd), hi = Math.max(selStart, selEnd);
    if (hi - lo > 0.0001) {
      viewStart = lo; viewEnd = hi;
      selStart = viewStart; selEnd = viewEnd;
      document.getElementById('selection-info').textContent = `selected: ${(viewEnd - viewStart).toFixed(4)}s (${viewStart.toFixed(4)}s \u2014 ${viewEnd.toFixed(4)}s)`;
      drawTimeline();
      updateSelOverlay();
      drawFlamegraph(viewStart, viewEnd);
    }
  }
});

// Mouse wheel zoom on timeline
tlCanvas.addEventListener('wheel', (ev) => {
  ev.preventDefault();
  const zoomFactor = ev.deltaY > 0 ? 1.2 : 1/1.2;
  const mouseT = tlXToTime(ev.clientX);
  const newStart = mouseT - (mouseT - viewStart) * zoomFactor;
  const newEnd = mouseT + (viewEnd - mouseT) * zoomFactor;
  viewStart = Math.max(0, newStart);
  viewEnd = Math.min(timeDuration, newEnd);
  // Keep selection in sync with view
  selStart = viewStart; selEnd = viewEnd;
  document.getElementById('selection-info').textContent = `selected: ${(viewEnd - viewStart).toFixed(4)}s (${viewStart.toFixed(4)}s \u2014 ${viewEnd.toFixed(4)}s)`;
  // Canvas redraws immediately; panels + flamegraph are debounced to avoid
  // rebuilding expensive DOM on every wheel tick.
  drawTimeline();
  updateSelOverlay();
  scheduleFlamegraph(viewStart, viewEnd);
}, {passive: false});

// --- Timeline resize handle ---
const tlContainer = document.getElementById('timeline-container');
const resizeHandle = document.getElementById('timeline-resize-handle');
const tracePanel = document.getElementById('trace-panel');
const tracePanelResizeHandle = document.getElementById('trace-panel-resize-handle');
const TRACE_PANEL_DEFAULT_H = 280;
let tracePanelH = TRACE_PANEL_DEFAULT_H;
tracePanel.style.height = tracePanelH + 'px';
let tpResizeDragging = false, tpResizeStartY = 0, tpResizeStartH = 0;
tracePanelResizeHandle.addEventListener('mousedown', (ev) => {
  tpResizeDragging = true;
  tpResizeStartY = ev.clientY;
  tpResizeStartH = tracePanelH;
  tracePanelResizeHandle.classList.add('dragging');
  ev.preventDefault();
});
function computeDefaultTimelineH() {
  const r = 0.75, minH = 3, maxH = 20;
  // Sum of clamped exponential lane heights
  let lanesH = 0;
  for (let i = 0; i < totalLanes; i++) lanesH += Math.min(maxH, Math.max(minH, maxH * Math.pow(r, i)));
  // sampleH capped at 35px; traceY = sampleH+4; traceH = lanesH+6
  return Math.max(80, Math.round(35 + 4 + lanesH + 6));
}
let tlResizeDragging = false, tlResizeStartY = 0, tlResizeStartH = 0;
resizeHandle.addEventListener('mousedown', (ev) => {
  tlResizeDragging = true;
  tlResizeStartY = ev.clientY;
  tlResizeStartH = timelineContainerH;
  resizeHandle.classList.add('dragging');
  ev.preventDefault();
});
window.addEventListener('mousemove', (ev) => {
  if (tlResizeDragging) {
    timelineContainerH = Math.max(40, tlResizeStartH + (ev.clientY - tlResizeStartY));
    tlContainer.style.height = timelineContainerH + 'px';
    invalidateTlRect();
    drawTimeline();
    updateSelOverlay();
  }
  if (tpResizeDragging) {
    tracePanelH = Math.max(60, tpResizeStartH + (ev.clientY - tpResizeStartY));
    tracePanel.style.height = tracePanelH + 'px';
  }
});
window.addEventListener('mouseup', () => {
  if (tlResizeDragging) { tlResizeDragging = false; resizeHandle.classList.remove('dragging'); }
  if (tpResizeDragging) { tpResizeDragging = false; tracePanelResizeHandle.classList.remove('dragging'); }
});

// --- Flamegraph ---
const fgCanvas = document.getElementById('flamegraph-canvas');
const fgCtx = fgCanvas.getContext('2d');
let fgRects = [];

function buildFlamegraph(tStart, tEnd) {
  const stacks = [];
  for (const e of EVENTS) {
    if (e.type !== 'sample') continue;
    const t = e.time - timeOrigin;
    if (t < tStart || t > tEnd) continue;
    if (!e.stack) continue;
    // Filter out samples belonging to disabled sections
    if (e.section_path) {
      const rootSec = e.section_path.split(' > ')[0];
      if (ALL_SECTIONS.includes(rootSec) && !enabledSections.has(rootSec)) continue;
    } else {
      if (!enabledSections.has(SECTION_OTHER)) continue;
    }
    const lines = e.stack.split('\n').filter(l => l.trim().length > 0);
    const reversed = lines.slice().reverse();
    stacks.push({frames: reversed, section: e.section_path || ''});
  }

  if (stacks.length === 0) return {root: {children: {}, count: 0, name: 'all'}, maxDepth: 0, totalSamples: 0};

  const root = {name: 'all', children: {}, count: stacks.length, _self: 0};
  let maxDepth = 0;

  for (const s of stacks) {
    let node = root;
    const frames = s.section ? [s.section, ...s.frames] : s.frames;
    for (let i = 0; i < frames.length; i++) {
      const frame = frames[i].trim();
      if (!frame) continue;
      if (!node.children[frame]) {
        node.children[frame] = {name: frame, children: {}, count: 0, _self: 0};
      }
      node.children[frame].count++;
      node = node.children[frame];
      if (i + 1 > maxDepth) maxDepth = i + 1;
    }
    node._self++;
  }

  return {root, maxDepth, totalSamples: stacks.length};
}

const FG_ROW_HEIGHT = 20;
const FG_FONT_SIZE = 11;
const FG_MIN_WIDTH_PX = 2;

function drawFlamegraph(tStart, tEnd) {
  const {root, maxDepth, totalSamples} = buildFlamegraph(tStart, tEnd);
  const dpr = window.devicePixelRatio || 1;
  const containerW = fgCanvas.parentElement.clientWidth;
  const canvasH = Math.max(400, (maxDepth + 2) * FG_ROW_HEIGHT + 40);

  fgCanvas.width = containerW * dpr;
  fgCanvas.height = canvasH * dpr;
  fgCanvas.style.width = containerW + 'px';
  fgCanvas.style.height = canvasH + 'px';
  fgCtx.setTransform(dpr, 0, 0, dpr, 0, 0);

  fgCtx.fillStyle = COLORS.bgBase;
  fgCtx.fillRect(0, 0, containerW, canvasH);

  if (totalSamples === 0) {
    fgCtx.fillStyle = COLORS.textDimmer;
    fgCtx.font = '13px monospace';
    fgCtx.fillText('No samples in selected range', 20, 30);
    fgRects = [];
    return;
  }

  fgCtx.font = FG_FONT_SIZE + 'px monospace';
  fgRects = [];

  fgCtx.fillStyle = COLORS.textDim;
  fgCtx.font = '11px monospace';
  fgCtx.fillText(`${totalSamples} samples in ${(tEnd - tStart).toFixed(4)}s`, 8, 14);

  const yOffset = 24;
  const totalWidth = containerW - 16;
  const xOffset = 8;

  function colorForFrame(name) {
    let h = 0;
    for (let i = 0; i < name.length; i++) h = ((h << 5) - h + name.charCodeAt(i)) | 0;
    h = Math.abs(h);
    const hue = (h % 40) + 10;
    const sat = 60 + (h % 30);
    const lit = 45 + (h % 20);
    return `hsl(${hue}, ${sat}%, ${lit}%)`;
  }

  function drawNode(node, depth, xStart, xEnd) {
    const w = xEnd - xStart;
    if (w < FG_MIN_WIDTH_PX) return;

    const y = yOffset + depth * FG_ROW_HEIGHT;
    const rectH = FG_ROW_HEIGHT - 2;

    fgCtx.fillStyle = depth === 0 ? COLORS.border : colorForFrame(node.name);
    fgCtx.fillRect(xStart, y, w - 1, rectH);
    fgCtx.strokeStyle = COLORS.bgBase;
    fgCtx.strokeRect(xStart, y, w - 1, rectH);

    if (w > 30) {
      fgCtx.fillStyle = COLORS.white;
      fgCtx.font = FG_FONT_SIZE + 'px monospace';
      const label = node.name;
      const textW = fgCtx.measureText(label).width;
      if (textW < w - 6) {
        fgCtx.fillText(label, xStart + 3, y + rectH - 4);
      } else {
        let truncated = label;
        while (truncated.length > 1 && fgCtx.measureText(truncated + '…').width > w - 6) {
          truncated = truncated.slice(0, -1);
        }
        fgCtx.fillText(truncated + '…', xStart + 3, y + rectH - 4);
      }
    }

    fgRects.push({
      x: xStart, y: y, w: w - 1, h: rectH,
      label: node.name,
      count: node.count, self: node._self, total: root.count
    });

    const kids = Object.values(node.children).sort((a, b) => b.count - a.count);
    let cx = xStart;
    for (const child of kids) {
      const cw = (child.count / node.count) * w;
      drawNode(child, depth + 1, cx, cx + cw);
      cx += cw;
    }
  }

  drawNode(root, 0, xOffset, xOffset + totalWidth);
}

// Tooltip on flamegraph
fgCanvas.addEventListener('mousemove', (ev) => {
  const rect = fgCanvas.getBoundingClientRect();
  const mx = ev.clientX - rect.left;
  const my = ev.clientY - rect.top;

  let hit = null;
  for (let i = fgRects.length - 1; i >= 0; i--) {
    const r = fgRects[i];
    if (mx >= r.x && mx <= r.x + r.w && my >= r.y && my <= r.y + r.h) {
      hit = r; break;
    }
  }

  if (hit) {
    const pct = ((hit.count / hit.total) * 100).toFixed(1);
    const selfPct = ((hit.self / hit.total) * 100).toFixed(1);
    tooltip.innerHTML = `<b>${hit.label}</b>\n${hit.count} samples (${pct}%)\nself: ${hit.self} (${selfPct}%)`;
    tooltip.style.pointerEvents = 'none';
    tooltip.style.display = 'block';
    tooltip.style.left = (ev.clientX + 12) + 'px';
    tooltip.style.top = (ev.clientY - 10) + 'px';
    // Show pointer cursor if the frame is navigable
    fgCanvas.style.cursor = hit.label.match(/^.+:[0-9]+$/) ? 'pointer' : 'default';
  } else {
    tooltip.style.display = 'none';
    fgCanvas.style.cursor = 'default';
  }
});

fgCanvas.addEventListener('click', (ev) => {
  const rect = fgCanvas.getBoundingClientRect();
  const mx = ev.clientX - rect.left;
  const my = ev.clientY - rect.top;
  for (let i = fgRects.length - 1; i >= 0; i--) {
    const r = fgRects[i];
    if (mx >= r.x && mx <= r.x + r.w && my >= r.y && my <= r.y + r.h) {
      const link = funcInfoLink(r.label);
      // funcInfoLink returns an <a> tag only when path:line is detected
      const m = r.label.match(/^(.+):([0-9]+)$/);
      if (m) {
        const [, filePath, line] = m;
        const absPath = filePath.startsWith('/') ? filePath : ROOT_PATH + '/' + filePath;
        window.location.href = `vscode://file/${absPath}:${line}:1`;
      }
      break;
    }
  }
});

fgCanvas.addEventListener('mouseleave', () => { tooltip.style.display = 'none'; });

// --- Init ---
timelineContainerH = computeDefaultTimelineH();
tlContainer.style.height = timelineContainerH + 'px';
// Pie chart hover — highlight matching VM state in timeline
const vmPieCanvas = document.getElementById('vm-pie-canvas');
vmPieCanvas.addEventListener('mousemove', (ev) => {
  const rect = vmPieCanvas.getBoundingClientRect();
  const size = 72;
  const cx = size / 2, cy = size / 2;
  const mx = (ev.clientX - rect.left) * (size / rect.width);
  const my = (ev.clientY - rect.top)  * (size / rect.height);
  const dx = mx - cx, dy = my - cy;
  const dist = Math.sqrt(dx*dx + dy*dy);
  const outerR = size / 2 - 3;
  if (dist > outerR + 4) {
    if (pieHoveredState !== null) { pieHoveredState = null; drawTimeline(); drawVmPie(selStart, selEnd); }
    return;
  }
  let a = Math.atan2(dy, dx);
  // normalize to same start (-PI/2) as drawing code
  if (a < -Math.PI / 2) a += Math.PI * 2;
  let found = null;
  for (const sl of pieSlices) {
    let a0 = sl.a0, a1 = sl.a1;
    if (a0 < -Math.PI / 2) { a0 += Math.PI * 2; a1 += Math.PI * 2; }
    if (a >= a0 && a <= a1) { found = sl.state; break; }
  }
  if (found !== pieHoveredState) {
    pieHoveredState = found;
    drawTimeline();
    drawVmPie(selStart, selEnd);
  }
});
vmPieCanvas.addEventListener('mouseleave', () => {
  if (pieHoveredState !== null) {
    pieHoveredState = null;
    drawTimeline();
    drawVmPie(selStart, selEnd);
  }
});

window.addEventListener('resize', () => { invalidateTlRect(); drawTimeline(); updateSelOverlay(); drawFlamegraph(viewStart, viewEnd); drawVmPie(selStart, selEnd); });
document.getElementById('selection-info').textContent = `selected: ${timeDuration.toFixed(4)}s (0.0000s \u2014 ${timeDuration.toFixed(4)}s)`;
drawTimeline();
updateSelOverlay();
drawFlamegraph(0, timeDuration);
drawVmPie(0, timeDuration);
buildSectionFilter();
}); // end DOMContentLoaded
</script>
</body>
</html>
]==]

return {New = profiler_new}
