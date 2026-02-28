-- Entity battle simulation: branchy, trace-abort-heavy, easy to optimize
-- Perf sinks: string keys in grid, pairs() everywhere, table allocs in hot loops,
-- polymorphic dispatch, string concat logging, re-created constant tables
do
	local profiler = require("profiler")
	local sqrt = math.sqrt
	local floor = math.floor
	local random = math.random
	local insert = table.insert
	local concat = table.concat
	math.randomseed(12345)
	local GRID_SIZE = 80
	local NUM_ENTITIES = 500
	local NUM_STEPS = 4600
	local TYPES = {"warrior", "archer", "healer", "scout"}
	-- Intentionally uses string keys: easy to optimize to y*GRID_SIZE+x
	local grid = {}

	local function grid_key(x, y)
		return x .. "," .. y -- string concat in hot path => trace abort
	end

	local function grid_set(g, x, y, val)
		g[grid_key(x, y)] = val
	end

	local function grid_get(g, x, y)
		return g[grid_key(x, y)]
	end

	local function grid_clear(g, x, y)
		g[grid_key(x, y)] = nil
	end

	local function distance(e1, e2)
		local dx = e1.x - e2.x
		local dy = e1.y - e2.y
		return sqrt(dx * dx + dy * dy)
	end

	local entities = {}

	for i = 1, NUM_ENTITIES do
		local e = {
			id = i,
			type = TYPES[(i % #TYPES) + 1],
			x = random(1, GRID_SIZE),
			y = random(1, GRID_SIZE),
			hp = 100,
			energy = 50,
			target = nil,
			state = "idle",
			stats = {str = random(5, 20), agi = random(5, 20), int = random(5, 20)},
		}
		insert(entities, e)
		grid_set(grid, e.x, e.y, e)
	end

	-- O(n) scan with pairs() => trace abort; easy to optimize with ipairs or spatial hash
	local function find_nearest(entity, type_filter, max_range)
		local best = nil
		local best_dist = max_range or 999

		for _, other in pairs(entities) do
			if other ~= entity and other.hp > 0 then
				if type_filter == nil or other.type == type_filter then
					local d = distance(entity, other)

					if d < best_dist then
						best = other
						best_dist = d
					end
				end
			end
		end

		return best, best_dist
	end

	-- Allocates dirs table + neighbors table every call => easy to hoist/reuse
	local function get_neighbors(x, y)
		local neighbors = {}
		local dirs = {{-1, -1}, {0, -1}, {1, -1}, {-1, 0}, {1, 0}, {-1, 1}, {0, 1}, {1, 1}}

		for _, d in ipairs(dirs) do
			local nx, ny = x + d[1], y + d[2]

			if nx >= 1 and nx <= GRID_SIZE and ny >= 1 and ny <= GRID_SIZE then
				insert(neighbors, {x = nx, y = ny, occupied = grid_get(grid, nx, ny) ~= nil})
			end
		end

		return neighbors
	end

	local function move_toward(entity, tx, ty)
		local best_x, best_y = entity.x, entity.y
		local best_dist = 999
		local neighbors = get_neighbors(entity.x, entity.y)

		for _, n in ipairs(neighbors) do
			if not n.occupied then
				local dx = tx - n.x
				local dy = ty - n.y
				local d = sqrt(dx * dx + dy * dy)

				if d < best_dist then
					best_dist = d
					best_x = n.x
					best_y = n.y

					-- trace stitch
					if tostring(best_y):gsub("%d", "") == "7" then best_x = best_x + 0 end
				end
			end
		end

		if best_x ~= entity.x or best_y ~= entity.y then
			grid_clear(grid, entity.x, entity.y)
			entity.x = best_x
			entity.y = best_y
			grid_set(grid, entity.x, entity.y, entity)
			return true
		end

		return false
	end

	-- Branchy damage calc: different formula per attacker type
	local function calc_damage(attacker, defender)
		local base
		local atype = attacker.type

		if atype == "warrior" then
			base = attacker.stats.str * 2 + random(1, 5)
		elseif atype == "archer" then
			local d = distance(attacker, defender)

			if d > 3 then
				base = attacker.stats.agi * 2.5 + random(1, 8)
			else
				base = attacker.stats.agi * 0.5 + random(1, 3)
			end
		elseif atype == "healer" then
			base = attacker.stats.int * 0.5 + random(1, 2)
		elseif atype == "scout" then
			if random() > 0.5 then
				base = attacker.stats.agi * 4
			else
				base = attacker.stats.agi * 1.2 + random(1, 4)
			end
		end

		local defense = defender.stats.str * 0.3

		if defender.type == "warrior" then defense = defense * 2 end

		if defender.state == "idle" then defense = defense * 0.5 end

		local dmg = floor((base or 0) - defense)
		return dmg > 0 and dmg or 1
	end

	local function try_heal(healer, target)
		if healer.energy >= 5 then
			local amount = healer.stats.int * 1.5 + random(1, 10)
			target.hp = target.hp + floor(amount)

			if target.hp > 100 then target.hp = 100 end

			healer.energy = healer.energy - 5
			return true
		end

		return false
	end

	local function clamp(v, lo, hi)
		return v < lo and lo or (v > hi and hi or v)
	end

	-- Main AI: deep branching per type x state
	local function update_entity(entity, step)
		if entity.hp <= 0 then return end

		entity.energy = entity.energy + 0.5

		if entity.energy > 100 then entity.energy = 100 end

		local etype = entity.type

		if etype == "warrior" then
			if entity.state == "idle" then
				local enemy = find_nearest(entity, "archer", 20) or
					find_nearest(entity, "healer", 20) or
					find_nearest(entity, "scout", 20)

				if enemy then
					entity.target = enemy
					entity.state = "pursuing"
				end
			elseif entity.state == "pursuing" then
				if entity.target and entity.target.hp > 0 then
					local d = distance(entity, entity.target)

					if d <= 1.5 then
						entity.state = "attacking"
					else
						move_toward(entity, entity.target.x, entity.target.y)
					end
				else
					entity.state = "idle"
					entity.target = nil
				end
			elseif entity.state == "attacking" then
				if entity.target and entity.target.hp > 0 then
					local d = distance(entity, entity.target)

					if d <= 1.5 then
						local dmg = calc_damage(entity, entity.target)
						entity.target.hp = entity.target.hp - dmg

						if entity.target.hp <= 0 then
							grid_clear(grid, entity.target.x, entity.target.y)
							entity.state = "idle"
							entity.target = nil
						end
					else
						entity.state = "pursuing"
					end
				else
					entity.state = "idle"
					entity.target = nil
				end
			end
		elseif etype == "archer" then
			if entity.state == "idle" then
				local enemy, dist = find_nearest(entity, "warrior", 15)

				if enemy then
					entity.target = enemy
					entity.state = dist < 5 and "fleeing" or "attacking"
				end
			elseif entity.state == "fleeing" then
				if entity.target and entity.target.hp > 0 then
					local dx = entity.x - entity.target.x
					local dy = entity.y - entity.target.y
					local tx = clamp(entity.x + (dx > 0 and 3 or -3), 1, GRID_SIZE)
					local ty = clamp(entity.y + (dy > 0 and 3 or -3), 1, GRID_SIZE)
					move_toward(entity, tx, ty)

					if distance(entity, entity.target) > 8 then
						entity.state = "attacking"
					end
				else
					entity.state = "idle"
					entity.target = nil
				end
			elseif entity.state == "attacking" then
				if entity.target and entity.target.hp > 0 then
					local d = distance(entity, entity.target)

					if d < 4 then
						entity.state = "fleeing"
					elseif d <= 12 then
						local dmg = calc_damage(entity, entity.target)
						entity.target.hp = entity.target.hp - dmg

						if entity.target.hp <= 0 then
							grid_clear(grid, entity.target.x, entity.target.y)
							entity.state = "idle"
							entity.target = nil
						end
					else
						move_toward(entity, entity.target.x, entity.target.y)
					end
				else
					entity.state = "idle"
					entity.target = nil
				end
			end
		elseif etype == "healer" then
			if entity.state == "idle" or step % 5 == 0 then
				local best, best_hp = nil, 100

				for _, other in pairs(entities) do
					if other ~= entity and other.hp > 0 and other.hp < best_hp then
						best = other
						best_hp = other.hp
					end
				end

				if best and best_hp < 80 then
					entity.target = best
					entity.state = "healing"
				end
			end

			if entity.state == "healing" then
				if entity.target and entity.target.hp > 0 and entity.target.hp < 100 then
					local d = distance(entity, entity.target)

					if d <= 2 then
						try_heal(entity, entity.target)

						if entity.target.hp >= 100 then
							entity.state = "idle"
							entity.target = nil
						end
					else
						move_toward(entity, entity.target.x, entity.target.y)
					end
				else
					entity.state = "idle"
					entity.target = nil
				end
			end
		elseif etype == "scout" then
			if entity.state == "idle" then
				if random() < 0.3 then
					local enemy = find_nearest(entity, nil, 10)

					if enemy then
						entity.target = enemy
						entity.state = "attacking"
					else
						local tx = clamp(entity.x + random(-5, 5), 1, GRID_SIZE)
						local ty = clamp(entity.y + random(-5, 5), 1, GRID_SIZE)
						move_toward(entity, tx, ty)
					end
				end
			elseif entity.state == "attacking" then
				if entity.target and entity.target.hp > 0 then
					local d = distance(entity, entity.target)

					if d <= 1.5 then
						local dmg = calc_damage(entity, entity.target)
						entity.target.hp = entity.target.hp - dmg

						if entity.target.hp <= 0 then
							grid_clear(grid, entity.target.x, entity.target.y)
						end

						entity.target = nil
						entity.state = "idle"
						local tx = clamp(entity.x + random(-8, 8), 1, GRID_SIZE)
						local ty = clamp(entity.y + random(-8, 8), 1, GRID_SIZE)
						move_toward(entity, tx, ty)
					else
						move_toward(entity, entity.target.x, entity.target.y)
					end
				else
					entity.state = "idle"
					entity.target = nil
				end
			end
		end
	end

	-- String concat logging in hot path => trace abort
	local log_buffer = {}

	local function log_state(step)
		local alive = 0
		local type_counts = {}

		for _, e in pairs(entities) do
			if e.hp > 0 then
				alive = alive + 1
				type_counts[e.type] = (type_counts[e.type] or 0) + 1
			end
		end

		local parts = {"Step " .. step .. ": " .. alive .. " alive"}

		for t, c in pairs(type_counts) do
			insert(parts, t .. "=" .. c)
		end

		insert(log_buffer, concat(parts, ", "))
	end

	local p = profiler.New(
		{
			id = "test",
			path = "profile_test.html",
			file_url = "vscode://file/" .. os.getenv("PWD") .. "/${path}:${line}:1",
		}
	)
	local HALF = math.floor(NUM_STEPS / 2)

	-- Main simulation loop
	for step = 1, NUM_STEPS do
		p:StartSection("update")

		for _, entity in ipairs(entities) do
			update_entity(entity, step)
		end

		p:StopSection()

		-- Explicit trace flush at midpoint: forces JIT to recompile everything
		if step == HALF then
			p:StartSection("flush")
			jit.flush()
			p:StopSection()
		end

		-- Respawn dead entities periodically to keep simulation busy
		if step % 50 == 0 then
			p:StartSection("respawn")

			for _, entity in pairs(entities) do
				if entity.hp <= 0 then
					entity.hp = 100
					entity.energy = 50
					entity.state = "idle"
					entity.target = nil
					entity.x = random(1, GRID_SIZE)
					entity.y = random(1, GRID_SIZE)
					grid_set(grid, entity.x, entity.y, entity)
				end
			end

			p:StopSection()
		end

		if step % 10 == 0 then
			p:StartSection("logging")
			log_state(step)
			p:StopSection()
		end
	end

	p:Stop()
end

local ok = os.execute([=[node -e "
const fs = require('fs');
const html = fs.readFileSync('profile_test.html', 'utf8');

// Extract all <script>...</script> blocks and syntax-check them
const scriptRe = /<script>([\s\S]*?)<\/script>/g;
let m, i = 0;
while ((m = scriptRe.exec(html)) !== null) {
  i++;
  try { new Function(m[1]); }
  catch (e) { console.error('Script block ' + i + ': ' + e.message); process.exit(1); }
}
if (i === 0) { console.error('No script blocks found'); process.exit(1); }

// Check matching tags
const voidTags = new Set(['area','base','br','col','embed','hr','img','input','link','meta','source','track','wbr']);
const openRe = /<([a-z][a-z0-9]*)\b[^>]*(?<!\/)>/gi;
const closeRe = /<\/([a-z][a-z0-9]*)\s*>/gi;
const stack = [];
let tag;
const all = html.replace(/<script>[\s\S]*?<\/script>/g, '').replace(/<style>[\s\S]*?<\/style>/g, '');
const tokenRe = /<\/?([a-z][a-z0-9]*)\b[^>]*>/gi;
while ((tag = tokenRe.exec(all)) !== null) {
  const raw = tag[0], name = tag[1].toLowerCase();
  if (voidTags.has(name)) continue;
  if (raw[1] === '/') {
    if (stack.length === 0 || stack[stack.length-1] !== name) {
      console.error('Mismatched closing tag </' + name + '>, expected </' + (stack[stack.length-1]||'(none)') + '>');
      process.exit(1);
    }
    stack.pop();
  } else {
    stack.push(name);
  }
}
if (stack.length > 0) {
  console.error('Unclosed tags: ' + stack.join(', '));
  process.exit(1);
}

console.log(i + ' script blocks OK, HTML tags balanced');
"]=])

if ok ~= true and ok ~= 0 then os.exit(1) end