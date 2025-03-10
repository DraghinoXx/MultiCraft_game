mobs = {
	mod = "redo",
	version = "20210405",
	invis = minetest.global_exists("invisibility") and invisibility or {}
}

local translator = minetest.get_translator
mobs.S = translator and translator("mobs") or intllib.make_gettext_pair()

if translator and not minetest.is_singleplayer() then
	local lang = minetest.settings:get("language")
	if lang and lang == "ru" then
		mobs.S = intllib.make_gettext_pair()
	end
end

local S = mobs.S

-- localize common functions
local abs = math.abs
local atan = function(x)
	return x and math.atan(x) or 0
end
local ceil = math.ceil
local cos = math.cos
local floor = math.floor
local min = math.min
local max = math.max
local pi = math.pi
local rad = math.rad
local random = math.random
local sin = math.sin
local vadd = vector.add
local vdistance = vector.distance
local vdirection = vector.direction
local vmultiply = vector.multiply
local vsubtract = vector.subtract
local table_copy = table.copy
local table_remove = table.remove
local upper = string.upper
local settings = minetest.settings

-- creative check
local creative = settings:get_bool("creative_mode")
function mobs.is_creative(name)
	return creative or minetest.check_player_privs(name, {creative = true})
end

-- Load settings
local damage_enabled = settings:get_bool("enable_damage")
local mobs_spawn = settings:get_bool("mobs_spawn") ~= false
local peaceful_only = false
local disable_blood = true
local mobs_griefing = true
local spawn_protected = settings:get_bool("mobs_spawn_protected") ~= false
local remove_far = false
local difficulty = tonumber(settings:get("mob_difficulty")) or 1.0
local show_health = settings:get_bool("mob_show_health") ~= false
local max_per_block = tonumber(settings:get("max_objects_per_block"))
local singleplayer = minetest.is_singleplayer()
local lifetime = 900 -- 15 min
local active_limit = tonumber(settings:get("mob_active_limit")) or 0
local active_mobs = 0
local spawn_interval = 20

-- calculate aoc range for mob count
local aoc_range = tonumber(settings:get("active_block_range")) * 16

if not singleplayer then
	lifetime = 300 -- 5 min
	spawn_interval = 60
	active_limit = 1000
end

-- pathfinding settings
local enable_pathfinding = singleplayer -- disable pathfinder in multiplayer
local stuck_timeout = 3 -- how long before stuck mod starts searching
local stuck_path_timeout = 10 -- how long will mob follow path before giving up

-- default nodes
local node_fire = "fire:basic_flame"
local node_permanent_flame = "fire:permanent_flame"
local node_ice = "default:ice"
local node_snowblock = "default:snowblock"
local node_snow = "default:snow"
mobs.fallback_node = minetest.registered_aliases["mapgen_dirt"] or "default:dirt"

local mob_class = {
	description = nil,
	attack_type = "dogfight",
	stepheight = 1.1,
	fly_in = "air",
	owner = "",
	infotext = "",
	order = "",
	jump_height = 4,
	lifetimer = lifetime,
	physical = true,
	collisionbox = {-0.25, -0.25, -0.25, 0.25, 0.25, 0.25},
	visual_size = {x = 1, y = 1},
	texture_mods = "",
	makes_footstep_sound = false,
	view_range = 5,
	walk_velocity = 1,
	run_velocity = 2,
	light_damage = 0,
	light_damage_min = 12,
	light_damage_max = 15,
	water_damage = 0,
	lava_damage = 5,
	fire_damage = 4,
	air_damage = 0,
	suffocation = 2,
	fall_damage = 1,
	fall_speed = -9.81, -- must be lower than -2
	drops = {},
	armor = 100,
	runaway = false,
	sounds = {},
	jump = true,
	knock_back = true,
	walk_chance = 50,
	stand_chance = 30,
	attack_chance = 5,
	passive = false,
	blood_amount = 5,
	blood_texture = "mobs_blood.png",
	shoot_offset = 0,
	floats = true, -- floats in water by default
	replace_offset = 0,
	timer = 0,
	env_damage_timer = 0, -- only used when state = "attack"
	tamed = false,
	pause_timer = 0,
	horny = false,
	hornytimer = 0,
	child = false,
	gotten = false,
	health = 0,
	reach = 2,
	htimer = 0,
	docile_by_day = false,
	time_of_day = 0.5,
	fear_height = 0,
	runaway_timer = 0,
	immune_to = {},
	explosion_timer = 3,
	allow_fuse_reset = true,
	stop_to_explode = true,
	dogshoot_count = 0,
	dogshoot_count_max = 5,
	dogshoot_count2_max = 5,
	group_attack = false,
	attack_monsters = false,
	attack_animals = false,
	attack_players = true,
	attack_npcs = false,
	facing_fence = false,
	obj_is_mob = true
}

local mob_class_meta = {__index = mob_class}


-- play sound
function mob_class:mob_sound(sound)
	if not sound then
		return
	end

	local pitch = 1.0

	-- higher pitch for a child
	if self.child then pitch = pitch * 1.5 end

	-- a little random pitch to be different
	pitch = pitch + random(-10, 10) * 0.005

	minetest.sound_play(sound, {
		object = self.object,
		gain = 1.0,
		max_hear_distance = self.sounds.distance,
		pitch = pitch
	})
end


-- attack player/mob
function mob_class:do_attack(player)
	if self.state == "attack" then
		return
	end

	self.attack = player
	self.state = "attack"

	if random(0, 10) < 9 then
		self:mob_sound(self.sounds.war_cry)
	end
end


-- collision function based on jordan4ibanez' open_ai mod
function mob_class:collision()
	local pos = self.object:get_pos()
	local x, z = 0, 0
	local width = -self.collisionbox[1] + self.collisionbox[4] + 0.5

	for _, object in pairs(minetest.get_objects_inside_radius(pos, width)) do
		if object:is_player()
				or (object:get_luaentity()
				and object:get_luaentity().obj_is_mob
				and object ~= self.object) then
			local pos2 = object:get_pos()
			local vec = {x = pos.x - pos2.x, z = pos.z - pos2.z}

			x = x + vec.x
			z = z + vec.z
		end
	end

	return ({x, z})
end


-- check if string exists in another string or table
local check_for = function(look_for, look_inside)
	if type(look_inside) == "string" and look_inside == look_for then
		return true

	elseif type(look_inside) == "table" then
		for _, str in pairs(look_inside) do
			if str == look_for then
				return true
			end

			if str:find("group:") then
				local group = str:split(":")[2]

				if minetest.get_item_group(look_for, group) ~= 0 then
					return true
				end
			end
		end
	end

	return false
end


-- move mob in facing direction
function mob_class:set_velocity(v)
	-- halt mob if it has been ordered to stay
	if self.order == "stand" then
		local cy = self.object:get_velocity().y
		self.object:set_velocity({x = 0, y = cy, z = 0})
		return
	end

	local c_x, c_y = 0, 0

	-- can mob be pushed, if so calculate direction
	if self.pushable then
		c_x, c_y = unpack(self:collision())
	end

	local yaw = (self.object:get_yaw() or 0) + (self.rotate or 0)

	-- nil check for velocity
	v = v or 0.01

	-- check if standing in liquid with max viscosity of 7
	local visc = min(minetest.registered_nodes[self.standing_in].liquid_viscosity, 7)

	-- only slow mob trying to move while inside a viscous fluid that
	-- they aren't meant to be in (fish in water, spiders in cobweb etc)
	if v > 0 and visc and visc > 0
	and not check_for(self.standing_in, self.fly_in) then
		v = v / (visc + 1)
	end

	-- set velocity
	local vel = self.object:get_velocity() or 0

	local new_vel = {
		x = (sin(yaw) * -v) + c_x,
		y = vel.y,
		z = (cos(yaw) * v) + c_y}

	self.object:set_velocity(new_vel)
end

-- global version of above function
function mobs:set_velocity(entity, v)
	mob_class.set_velocity(entity, v)
end


-- calculate mob velocity
function mob_class:get_velocity()
	local v = self.object:get_velocity()
	if not v then return 0 end

	return (v.x * v.x + v.z * v.z) ^ 0.5
end


-- set and return valid yaw
function mob_class:set_yaw(yaw, delay)
	if not yaw or yaw ~= yaw then
		yaw = 0
	end

	delay = delay or 0

	if delay == 0 then
		self.object:set_yaw(yaw)
		return yaw
	end

	self.target_yaw = yaw
	self.delay = delay
	return self.target_yaw
end

-- global function to set mob yaw
function mobs:yaw(entity, yaw, delay)
	mob_class.set_yaw(entity, yaw, delay)
end


-- set defined animation
function mob_class:set_animation(anim, force)
	if not self.animation or not anim then return end

	self.animation.current = self.animation.current or ""

	-- only use different animation for attacks when using same set
	if force ~= true and anim ~= "punch" and anim ~= "shoot"
			and self.animation.current:find(anim) then
		return
	end

	local num = 0

	-- check for more than one animation (max 4)
	for n = 1, 4 do
		if self.animation[anim .. n .. "_start"]
				and self.animation[anim .. n .. "_end"] then
			num = n
		end
	end

	-- choose random animation from set
	if num > 0 then
		num = random(0, num)
		anim = anim .. (num ~= 0 and num or "")
	end

	if anim == self.animation.current
			or not self.animation[anim .. "_start"]
			or not self.animation[anim .. "_end"] then
		return
	end

	self.animation.current = anim
	self.object:set_animation({
		x = self.animation[anim .. "_start"],
		y = self.animation[anim .. "_end"]
	},
		self.animation[anim .. "_speed"] or
				self.animation.speed_normal or 15,
		0, self.animation[anim .. "_loop"] ~= false)
end

-- above function exported for mount.lua
function mobs:set_animation(entity, anim)
	entity.set_animation(entity, anim)
end


-- check line of sight (BrunoMine)
local line_of_sight = function(self, pos1, pos2, stepsize)
	stepsize = stepsize or 1
	local s, pos = minetest.line_of_sight(pos1, pos2, stepsize)

	-- normal walking and flying mobs can see you through air
	if s then return true end

	-- New pos1 to be analyzed
	local npos1 = {x = pos1.x, y = pos1.y, z = pos1.z}

	local r, pos = minetest.line_of_sight(npos1, pos2, stepsize)

	-- Checks the return
	if r then return true end

	-- Nodename found
	local nn = minetest.get_node(pos).name

	-- Target Distance (td) to travel
	local td = vdistance(pos1, pos2)

	-- Actual Distance (ad) traveled
	local ad = 0

	-- It continues to advance in the line of sight in search of a real
	-- obstruction which counts as 'walkable' nodebox.
	while minetest.registered_nodes[nn]
			and not minetest.registered_nodes[nn].walkable do

		-- Check if you can still move forward
		if td < ad + stepsize then
			return true -- Reached the target
		end

		-- Moves the analyzed pos
		local d = vdistance(pos1, pos2)

		npos1.x = ((pos2.x - pos1.x) / d * stepsize) + pos1.x
		npos1.y = ((pos2.y - pos1.y) / d * stepsize) + pos1.y
		npos1.z = ((pos2.z - pos1.z) / d * stepsize) + pos1.z

		-- NaN checks
		if d == 0
				or npos1.x ~= npos1.x
				or npos1.y ~= npos1.y
				or npos1.z ~= npos1.z then
			return false
		end

		ad = ad + stepsize

		-- scan again
		r, pos = minetest.line_of_sight(npos1, pos2, stepsize)

		if r then return true end

		-- New Nodename found
		nn = minetest.get_node(pos).name
	end

	return false
end


-- check line of sight (by BrunoMine, tweaked by Astrobe)
local new_line_of_sight = function(self, pos1, pos2, stepsize)
	if not pos1 or not pos2 then return end

	stepsize = stepsize or 1
	local stepv = vmultiply(vdirection(pos1, pos2), stepsize)
	local s, pos = minetest.line_of_sight(pos1, pos2, stepsize)

	-- normal walking and flying mobs can see you through air
	if s then return true end

	-- New pos1 to be analyzed
	local npos1 = {x = pos1.x, y = pos1.y, z = pos1.z}
	local r, pos = minetest.line_of_sight(npos1, pos2, stepsize)

	-- Checks the return
	if r then return true end

	-- Nodename found
	local nn = minetest.get_node(pos).name

	-- It continues to advance in the line of sight in search of a real
	-- obstruction which counts as 'walkable' nodebox.
	while minetest.registered_nodes[nn]
			and not minetest.registered_nodes[nn].walkable do

		npos1 = vadd(npos1, stepv)

		if vdistance(npos1, pos2) < stepsize then return true end

		-- scan again
		r, pos = minetest.line_of_sight(npos1, pos2, stepsize)

		if r then return true end

		-- New Nodename found
		nn = minetest.get_node(pos).name
	end

	return false
end

-- check line of sight using raycasting (thanks Astrobe)
local ray_line_of_sight = function(self, pos1, pos2)
	local ray = minetest.raycast(pos1, pos2, true, false)
	local thing = ray:next()

	while thing do -- thing.type, thing.ref
		if thing.type == "node" then
			local name = minetest.get_node(thing.under).name

			if minetest.registered_items[name]
			and minetest.registered_items[name].walkable then
				return false
			end
		end

		thing = ray:next()
	end

	return true
end

function mob_class:line_of_sight(pos1, pos2, stepsize)
	if minetest.raycast then -- only use if minetest 5.0 is detected
		return ray_line_of_sight(self, pos1, pos2)
	end

	return line_of_sight(self, pos1, pos2, stepsize)
end

-- global function
function mobs:line_of_sight(entity, pos1, pos2, stepsize)
	return entity:line_of_sight(pos1, pos2, stepsize)
end


function mob_class:attempt_flight_correction(override)
	if self:flight_check() and override ~= true then return true end

	-- We are not flying in what we are supposed to.
	-- See if we can find intended flight medium and return to it
	local pos = self.object:get_pos()
	local searchnodes = self.fly_in

	if type(searchnodes) == "string" then
		searchnodes = {self.fly_in}
	end

	local flyable_nodes = minetest.find_nodes_in_area(
		{x = pos.x - 1, y = pos.y - 1, z = pos.z - 1},
		{x = pos.x + 1, y = pos.y + 0, z = pos.z + 1}, searchnodes)
		-- pos.y + 0 hopefully fixes floating swimmers

	if #flyable_nodes < 1 then
		return false
	end

	local escape_target = flyable_nodes[random(#flyable_nodes)]
	local escape_direction = vdirection(pos, escape_target)

	self.object:set_velocity(
		vmultiply(escape_direction, 1)) --self.run_velocity))

	return true
end


-- are we flying in what we are suppose to? (taikedz)
function mob_class:flight_check()
	local def = minetest.registered_nodes[self.standing_in]
	if not def then return false end

	-- are we standing inside what we should be to fly/swim?
	if check_for(self.standing_in, self.fly_in) then
		return true
	end

	-- stops mobs getting stuck inside stairs and plantlike nodes
	if def.drawtype ~= "airlike"
			and def.drawtype ~= "liquid"
			and def.drawtype ~= "flowingliquid" then
		return true
	end

	return false
end


-- turn mob to face position
local yaw_to_pos = function(self, target, rot)

	rot = rot or 0

	local pos = self.object:get_pos()
	local vec = {x = target.x - pos.x, z = target.z - pos.z}
	local yaw = (atan(vec.z / vec.x) + rot + pi / 2) - self.rotate

	if target.x > pos.x then
		yaw = yaw + pi
	end

	yaw = self:set_yaw(yaw, rot)

	return yaw
end

function mobs:yaw_to_pos(self, target, rot)
	return yaw_to_pos(self, target, rot)
end


-- if stay near set then check periodically for nodes and turn towards them
function mob_class:do_stay_near()
	if not self.stay_near then return false end

	local pos = self.object:get_pos()
	local searchnodes = self.stay_near[1]
	local chance = self.stay_near[2] or 10

	if not pos or random(chance) > 1 then
		return false
	end

	if type(searchnodes) == "string" then
		searchnodes = {self.stay_near[1]}
	end

	local r = self.view_range
	local nearby_nodes = minetest.find_nodes_in_area(
		{x = pos.x - r, y = pos.y - 1, z = pos.z - r},
		{x = pos.x + r, y = pos.y + 1, z = pos.z + r},
		searchnodes)

	if #nearby_nodes < 1 then
		return false
	end

	yaw_to_pos(self, nearby_nodes[random(#nearby_nodes)])
	self:set_animation("walk")
	self:set_velocity(self.walk_velocity)
	return true
end


-- custom particle effects
local effect = function(pos, amount, texture, min_size, max_size,
		radius, gravity, glow, fall)
	if not minetest.is_valid_pos(pos) then return end

	radius = radius or 2
	min_size = min_size or 1
	max_size = max_size or 1
	gravity = gravity or -9.81
	glow = glow or 0

	if fall == true then
		fall = 0
	elseif fall == false then
		fall = radius
	else
		fall = -radius
	end

	minetest.add_particlespawner({
		amount = amount,
		time = 0.25,
		minpos = pos,
		maxpos = pos,
		minvel = {x = -radius, y = fall, z = -radius},
		maxvel = {x = radius, y = radius, z = radius},
		minacc = {x = 0, y = gravity, z = 0},
		maxacc = {x = 0, y = gravity, z = 0},
		minexptime = 0.25,
		maxexptime = 1,
		minsize = min_size,
		maxsize = max_size,
		texture = texture,
		glow = glow
	})
end


function mobs:effect(pos, amount, texture, min_size, max_size,
		radius, gravity, glow, fall)
	effect(pos, amount, texture, min_size, max_size, radius, gravity, glow, fall)
end


-- update nametag colour
function mob_class:update_tag()
	local col = "#00FF00"
	local qua = self.hp_max / 4

	if self.health <= floor(qua * 3) then
		col = "#FFFF00"
	end

	if self.health <= floor(qua * 2) then
		col = "#FF6600"
	end

	if self.health <= floor(qua) then
		col = "#FF0000"
	end

	self.object:set_properties({
		nametag = self.nametag,
		nametag_color = col
	})
end


-- drop items
function mob_class:item_drop()
	-- no drops if disabled by setting or mob is child
	if self.child then return end

	local pos = self.object:get_pos()

	-- check for drops function
	self.drops = type(self.drops) == "function"
		and self.drops(pos) or self.drops

	-- check for nil or no drops
	if not self.drops or #self.drops == 0 then
		return
	end

	-- was mob killed by player?
	local death_by_player = self.cause_of_death
		and self.cause_of_death.puncher
		and self.cause_of_death.puncher:is_player()

	local obj, item, num

	for n = 1, #self.drops do
		if random(self.drops[n].chance or 1) == 1 then
			num = random(self.drops[n].min or 1, self.drops[n].max or 1)
			item = self.drops[n].name

			-- cook items on a hot death
			if self.cause_of_death.hot then
				local output = minetest.get_craft_result({
					method = "cooking",
					width = 1,
					items = {item}
				})

				if output and output.item and not output.item:is_empty() then
					item = output.item:get_name()
				end
			end

			-- only drop rare items (drops.min=0) if killed by player
			if death_by_player then
				obj = minetest.add_item(pos, ItemStack(item .. " " .. num))

			elseif self.drops[n].min ~= 0 then
				obj = minetest.add_item(pos, ItemStack(item .. " " .. num))
			end

			if obj and obj:get_luaentity() then

				obj:set_velocity({
					x = random(-10, 10) / 9,
					y = 6,
					z = random(-10, 10) / 9
				})

			elseif obj then
				obj:remove() -- item does not exist
			end
		end
	end
	self.drops = {}
end


-- remove mob and descrease counter
local remove_mob = function(self, decrease)
	self.object:remove()

	if decrease and active_limit > 0 then
		active_mobs = active_mobs - 1

		if active_mobs < 0 then
			active_mobs = 0
		end
	end
--	print("-- active mobs: " .. active_mobs .. " / " .. active_limit)
end


-- global function for removing mobs
function mobs:remove(self, decrease)
	remove_mob(self, decrease)
end


-- check if mob is dead or only hurt
function mob_class:check_for_death(cmi_cause)
	-- We dead already
	if self.state == "die" then
		return true
	end

	-- has health actually changed?
	if self.health == self.old_health and self.health > 0 then
		return false
	end

	local damaged = self.health < self.old_health

	self.old_health = self.health

	-- still got some health? play hurt sound
	if self.health > 0 then
		-- only play hurt sound if damaged
		if damaged then
			self:mob_sound(self.sounds.damage)
		end

		-- make sure health isn't higher than max
		if self.health > self.hp_max then
			self.health = self.hp_max
		end

		-- backup nametag so we can show health stats
		if not self.nametag2 then
			self.nametag2 = self.nametag or ""
		end

		if show_health
				and (cmi_cause and cmi_cause.type == "punch") then
			self.htimer = 2
			self.nametag = S("Health:") .. " " .. self.health .. " / " .. self.hp_max
			self:update_tag()
		end

		return false
	end

	self.cause_of_death = cmi_cause

	-- drop items
	self:item_drop()

	local pos = self.object:get_pos()

	if pos then
		self:mob_sound(self.sounds.death)

		-- execute custom death function
		if self.on_die then
			self:on_die(pos)
			remove_mob(self, true)

			return true
		end
	end

	-- check for custom death function and die animation
	if self.animation
			and self.animation.die_start
			and self.animation.die_end then

		local frames = self.animation.die_end - self.animation.die_start
		local speed = self.animation.die_speed or 15
		local length = max((frames / speed), 0)
		local rot = self.animation.die_rotate and 5

		self.attack = nil
		self.following = nil
		self.v_start = false
		self.timer = 0
		self.blinktimer = 0
		self.passive = true
		self.state = "die"
		self.object:set_properties({
			pointable = false, collide_with_objects = false,
			automatic_rotate = rot, static_save = false
		})
		self:set_velocity(0)
		self:set_animation("die")

		minetest.after(length, function(self)
			if self.object:get_luaentity() then
				remove_mob(self, true)
			end
		end, self)
	elseif pos then -- otherwise remove mob
		remove_mob(self, true)
	end

	return true
end


-- get node but use fallback for nil or unknown
local node_ok = function(pos, fallback)
	fallback = fallback or mobs.fallback_node
	local node = minetest.get_node_or_nil(pos)

	if node and minetest.registered_nodes[node.name] then
		return node
	end

	return minetest.registered_nodes[fallback]
end


-- Returns true is node can deal damage to self
local is_node_dangerous = function(self, nodename)
	if self.water_damage > 0
	and minetest.get_item_group(nodename, "water") ~= 0 then
		return true
	end

	if self.lava_damage > 0
	and minetest.get_item_group(nodename, "lava") ~= 0 then
		return true
	end

	if self.fire_damage > 0
	and minetest.get_item_group(nodename, "fire") ~= 0 then
		return true
	end

	if minetest.registered_nodes[nodename].damage_per_second > 0 then
		return true
	end

	return false
end


-- is mob facing a cliff
function mob_class:is_at_cliff()
	if self.fear_height == 0 then -- 0 for no falling protection!
		return false
	end

	-- get yaw but if nil returned object no longer exists
	local yaw = self.object:get_yaw()
	if not yaw then return false end

	local dir_x = -sin(yaw) * (self.collisionbox[4] + 0.5)
	local dir_z = cos(yaw) * (self.collisionbox[4] + 0.5)
	local pos = self.object:get_pos()
	local ypos = pos.y + self.collisionbox[2] -- just above floor

	local free_fall, blocker = minetest.line_of_sight(
		{x = pos.x + dir_x, y = ypos, z = pos.z + dir_z},
		{x = pos.x + dir_x, y = ypos - self.fear_height, z = pos.z + dir_z})

	-- check for straight drop
	if free_fall then
		return true
	end

	local bnode = node_ok(blocker)

	-- will we drop onto dangerous node?
	if is_node_dangerous(self, bnode.name) then
		return true
	end

	local def = minetest.registered_nodes[bnode.name]

	return (not def and def.walkable)
end


-- environmental damage (water, lava, fire, light etc.)
function mob_class:do_env_damage()
	-- feed/tame text timer (so mob 'full' messages dont spam chat)
	if self.htimer > 0 then
		self.htimer = self.htimer - 1
	end

	-- reset nametag after showing health stats
	if self.htimer < 1 and self.nametag2 then
		self.nametag = self.nametag2
		self.nametag2 = nil
		self:update_tag()
	end

	local pos = self.object:get_pos()
	if not pos then return end

	pos.y = pos.y + 1 -- for particle effect position
	self.time_of_day = minetest.get_timeofday()

	-- halt mob if standing inside ignore node
	if self.standing_in == "ignore" then
		self.object:set_velocity({x = 0, y = 0, z = 0})
		return true
	end

	local nodef = minetest.registered_nodes[self.standing_in]

	-- water
	if self.water_damage ~= 0 and nodef.groups.water then
		self.health = self.health - self.water_damage

		effect(pos, 5, "bubble.png", nil, nil, 1, nil)

		if self:check_for_death({type = "environment", pos = pos,
				node = self.standing_in, hot = true}) then
			return true
		end

	-- lava damage
	elseif self.lava_damage ~= 0 and nodef.groups.lava  then
		self.health = self.health - self.lava_damage

		effect(pos, 15, "fire_basic_flame.png", 1, 5, 1, 0.2, 15, true)

		if self:check_for_death({type = "environment", pos = pos,
				node = self.standing_in, hot = true}) then
			return true
		end

	-- fire damage
	elseif self.fire_damage ~= 0 and nodef.groups.fire then
		self.health = self.health - self.fire_damage

		effect(pos, 15, "fire_basic_flame.png", 1, 5, 1, 0.2, 15, true)

		if self:check_for_death({type = "environment", pos = pos,
				node = self.standing_in, hot = true}) then
			return true
		end

	-- damage_per_second node check (not fire and lava)
	elseif nodef.damage_per_second ~= 0
	and nodef.groups.lava == 0 and nodef.groups.fire == 0 then
		self.health = self.health - nodef.damage_per_second

		effect(pos, 5, "tnt_smoke.png")

		if self:check_for_death({type = "environment",
				pos = pos, node = self.standing_in}) then
			return true
		end
	end

	-- air damage
	if self.air_damage ~= 0 and self.standing_in == "air" then
		self.health = self.health - self.air_damage

		effect(pos, 3, "bubble.png", 1, 1, 1, 0.2)

		if self:check_for_death({type = "environment",
				pos = pos, node = self.standing_in}) then
			return true
		end
	end

	-- is mob light sensative, or scared of the dark :P
	if self.light_damage ~= 0 then
		local light = minetest.get_node_light(pos) or 0

		if light >= self.light_damage_min
		and light <= self.light_damage_max then
			self.health = self.health - self.light_damage

			effect(pos, 3, "fire_basic_flame.png", 4, 4, 2, nil, 5)

			if show_health then
				self.nametag = S("Health:") .. " " .. self.health .. " / " .. self.hp_max
				self:update_tag()
			end

			if self:check_for_death({type = "light"}) then
				return true
			end
		end
	end

	-- suffocation inside solid node
	if self.suffocation and self.suffocation ~= 0
	and nodef.walkable
	and nodef.groups.disable_suffocation ~= 1
	and nodef.drawtype == "normal" then
		local damage

		if self.suffocation == true then
			damage = 2
		else
			damage = (self.suffocation or 2)
		end

		self.health = self.health - damage

		if self:check_for_death({type = "suffocation",
				pos = pos, node = self.standing_in}) then
			return true
		end
	end

	return self:check_for_death({type = "unknown"})
end


-- jump if facing a solid node (not fences or gates)
function mob_class:do_jump()
	if not self.jump
			or self.jump_height == 0
			or self.fly
			or self.child
			or self.order == "stand" then
		return false
	end

	self.facing_fence = false

	-- something stopping us while moving?
	if self.state ~= "stand"
			and self:get_velocity() > 0.5
			and self.object:get_velocity().y ~= 0 then
		return false
	end

	local pos = self.object:get_pos()
	local yaw = self.object:get_yaw()

	-- sanity check
	if not yaw then return false end

	-- we can only jump if standing on solid node
	if minetest.registered_nodes[self.standing_on].walkable == false then
		return false
	end

	-- where is front
	local dir_x = -sin(yaw) * (self.collisionbox[4] + 0.5)
	local dir_z = cos(yaw) * (self.collisionbox[4] + 0.5)

	-- set y_pos to base of mob
	pos.y = pos.y + self.collisionbox[2]

	-- what is in front of mob?
	local nod = node_ok({
		x = pos.x + dir_x, y = pos.y + 0.5, z = pos.z + dir_z
	})

	-- what is above and in front?
	local nodt = node_ok({
		x = pos.x + dir_x, y = pos.y + 1.5, z = pos.z + dir_z
	})

	local blocked = minetest.registered_nodes[nodt.name].walkable

--	print("standing on:", self.standing_on, pos.y - 0.25)
--	print("in front:", nod.name, pos.y + 0.5)
--	print("in front above:", nodt.name, pos.y + 1.5)

	-- jump if standing on solid node (not snow) and not blocked above
	if (self.walk_chance == 0 or minetest.registered_items[nod.name].walkable)
	and not blocked
	and nod.name ~= node_snow then
		if not nod.name:find("fence")
				and not nod.name:find("gate")
				and not nod.name:find("wall") then
			local v = self.object:get_velocity()
			v.y = self.jump_height

			self:set_animation("jump") -- only when defined
			self.object:set_velocity(v)

			-- when in air move forward
			minetest.after(0.3, function(self, v)
				if self.object:get_luaentity() then
					self.object:set_acceleration({
						x = v.x * 2,
						y = 0,
						z = v.z * 2
					})
				end
			end, self, v)

			if self:get_velocity() > 0 then
				self:mob_sound(self.sounds.jump)
			end

			return true
		else
			self.facing_fence = true
		end
	end

	-- if blocked against a block/wall for 5 counts then turn
	if not self.following
	and (self.facing_fence or blocked) then
		self.jump_count = (self.jump_count or 0) + 1
		if self.jump_count > 4 then
			local yaw = self.object:get_yaw() or 0
			local turn = random(0, 2) + 1.35

			yaw = self:set_yaw(yaw + turn, 12)
			self.jump_count = 0
		end
	end

	return false
end


-- blast damage to entities nearby (modified from TNT mod)
local entity_physics = function(pos, radius)
	radius = radius * 2
	local objs = minetest.get_objects_inside_radius(pos, radius)
	local obj_pos, dist

	for n = 1, #objs do
		obj_pos = objs[n]:get_pos()
		dist = vdistance(pos, obj_pos)

		if dist < 1 then dist = 1 end

		local damage = floor((4 / dist) * radius)
		local ent = objs[n]:get_luaentity()

		-- punches work on entities AND players
		objs[n]:punch(objs[n], 1.0, {
			full_punch_interval = 1.0,
			damage_groups = {fleshy = damage},
		}, pos)
	end
end


-- can mob see player
local is_invisible = function(self, player_name)
	if mobs.invis[player_name] and not self.ignore_invisibility then
		return true
	end
end


-- should mob follow what I'm holding?
function mob_class:follow_holding(clicker)
	if is_invisible(self, clicker:get_player_name()) then
		return false
	end

	local item = clicker:get_wielded_item()

	-- are we holding an item mob can follow?
	if check_for(item:get_name(), self.follow) then
		return true
	end

	return false
end

local HORNY_TIME = 30
local HORNY_AGAIN_TIME = 300
local CHILD_GROW_TIME = 60 * 20 -- 20 minutes

-- find two animals of same type and breed if nearby and horny
function mob_class:breed()
	-- child takes a long time before growing into adult
	if self.child then
		self.hornytimer = self.hornytimer + 1

		if self.hornytimer > CHILD_GROW_TIME then
			self.child = false
			self.hornytimer = 0
			self.object:set_properties({
				textures = self.base_texture,
				mesh = self.base_mesh,
				visual_size = self.base_size,
				collisionbox = self.base_colbox,
				selectionbox = self.base_selbox
			})

			-- custom function when child grows up
			if self.on_grown then
				self.on_grown(self)
			else
				-- jump when fully grown so as not to fall into ground
				local pos = self.object:get_pos()
				if not pos then return end
				local ent = self.object:get_luaentity()
				pos.y = pos.y + (ent.collisionbox[2] * -1) - 0.4
				self.object:set_pos(pos)
			end

			self:mob_sound("mobs_spell")
		end
		return
	end

	-- horny animal can mate for HORNY_TIME seconds,
	-- afterwards horny animal cannot mate again for HORNY_AGAIN_TIME seconds
	if self.horny and self.hornytimer < HORNY_TIME + HORNY_AGAIN_TIME then
		self.hornytimer = self.hornytimer + 1

		if self.hornytimer >= HORNY_TIME + HORNY_AGAIN_TIME then
			self.hornytimer = 0
			self.horny = false
		end
	end

	-- find another same animal who is also horny and mate if nearby
	if self.horny and self.hornytimer <= HORNY_TIME then
		local pos = self.object:get_pos()

		effect({x = pos.x, y = pos.y + 1.5, z = pos.z}, 8, "heart.png", 3, 4, 1, 0.1)

		local objs = minetest.get_objects_inside_radius(pos, 3)
		local ent

		for n = 1, #objs do
			ent = objs[n]:get_luaentity()

			-- check for same animal with different colour
			local canmate = false
			if ent then
				if ent.name == self.name then
					canmate = true
				else
					local entname = ent.name:split(":")
					local selfname = self.name:split(":")

					if entname[1] == selfname[1] then
						entname = entname[2]:split("_")
						selfname = selfname[2]:split("_")

						if entname[1] == selfname[1] then
							canmate = true
						end
					end
				end
			end

			-- found another similar horny animal that isn't self?
			if ent and ent.object ~= self.object
			and canmate
			and ent.horny
			and ent.hornytimer <= 40 then
				local pos2 = ent.object:get_pos()

				-- Have mobs face one another
				yaw_to_pos(self, pos2)
				yaw_to_pos(ent, self.object:get_pos())

				self.hornytimer = HORNY_TIME + 1
				ent.hornytimer = HORNY_TIME + 1

				-- have we reached active mob limit
				if active_limit > 0 and active_mobs >= active_limit then
					minetest.chat_send_player(self.owner,
							S("Active Mob Limit Reached!")
							.. "  (" .. active_mobs
							.. " / " .. active_limit .. ")")
					return
				end

				-- spawn baby
				minetest.after(5, function(self, ent)
					if not self.object:get_luaentity() then
						return
					end

					-- custom breed function
					if self.on_breed then
						-- when false skip going any further
						if self:on_breed(ent) == false then
							return
						end
					else
						effect(pos, 15, "heart.png", 1, 2, 2, 15, 5)
						self:mob_sound("mobs_spell")
					end

					pos.y = pos.y + 0.5 -- spawn child a little higher

					local mob = minetest.add_entity(pos, self.name)
					local ent2 = mob:get_luaentity()
					local textures = self.base_texture

					-- using specific child texture (if found)
					if self.child_texture then
						textures = self.child_texture[1]
					end

					local owner = type(self.owner) == "string" and self.owner or ""

					local infotext = S("Owned by @1", S(owner))

					-- and resize to half height
					mob:set_properties({
						textures = textures,
						visual_size = {
							x = self.base_size.x * .5,
							y = self.base_size.y * .5
						},
						collisionbox = {
							self.base_colbox[1] * .5,
							self.base_colbox[2] * .5,
							self.base_colbox[3] * .5,
							self.base_colbox[4] * .5,
							self.base_colbox[5] * .5,
							self.base_colbox[6] * .5
						},
						selectionbox = {
							self.base_selbox[1] * .5,
							self.base_selbox[2] * .5,
							self.base_selbox[3] * .5,
							self.base_selbox[4] * .5,
							self.base_selbox[5] * .5,
							self.base_selbox[6] * .5
						},
						infotext = infotext
					})
					-- tamed and owned by parents' owner
					ent2.child = true
					ent2.tamed = true
					ent2.owner = self.owner
					ent2.infotext = infotext
				end, self, ent)

				break
			end
		end
	end
end


-- find and replace what mob is looking for (grass, wheat etc.)
function mob_class:replace(pos)
	local vel = self.object:get_velocity()
	if not vel then return end

	if not mobs_griefing
			or not self.replace_rate
			or not self.replace_what
			or self.child
			or vel.y ~= 0
			or random(self.replace_rate) > 1 then
		return
	end

	local what, with, y_offset

	if type(self.replace_what[1]) == "table" then
		local num = random(#self.replace_what)
		what = self.replace_what[num][1] or ""
		with = self.replace_what[num][2] or ""
		y_offset = self.replace_what[num][3] or 0
	else
		what = self.replace_what
		with = self.replace_with or ""
		y_offset = self.replace_offset or 0
	end

	pos.y = pos.y + y_offset

	if #minetest.find_nodes_in_area(pos, pos, what) > 0 then
	--	print("replace node = ".. minetest.get_node(pos).name, pos.y)

		if self.on_replace then
			local oldnode = what
			local newnode = with

			-- convert any group: replacements to actual node name
			if oldnode:find("group:") then
				oldnode = minetest.get_node(pos).name
			end

			if self:on_replace(pos, oldnode, newnode) == false or newnode == "" then
				return
			end
		end

		minetest.set_node(pos, {name = with})
	end
end


-- check if daytime and also if mob is docile during daylight hours
function mob_class:day_docile()
	if not self.docile_by_day then
		return false
	elseif self.docile_by_day
			and self.time_of_day > 0.2
			and self.time_of_day < 0.8 then
		return true
	end
end


local los_switcher = false
local height_switcher = false

-- path finding and smart mob routine by rnd,
-- line_of_sight and other edits by Elkien3
function mob_class:smart_mobs(s, p, dist, dtime)
	local s1 = self.path.lastpos
	local target_pos = p

	-- is it becoming stuck?
	if abs(s1.x - s.x) + abs(s1.z - s.z) < .5 then
		self.path.stuck_timer = self.path.stuck_timer + dtime
	else
		self.path.stuck_timer = 0
	end

	self.path.lastpos = {x = s.x, y = s.y, z = s.z}

	local use_pathfind = false
	local has_lineofsight = minetest.line_of_sight(
		{x = s.x, y = (s.y) + .5, z = s.z},
		{x = target_pos.x, y = (target_pos.y) + 1.5, z = target_pos.z}, .2)

	-- im stuck, search for path
	if not has_lineofsight then
		if los_switcher then
			use_pathfind = true
			los_switcher = false
		end -- cannot see target!
	else
		if not los_switcher then
			los_switcher = true
			use_pathfind = false

			minetest.after(1, function(self)
				if self.object:get_luaentity() then
					if has_lineofsight then
						self.path.following = false
					end
				end
			end, self)
		end -- can see target!
	end

	if (self.path.stuck_timer > stuck_timeout and not self.path.following) then
		use_pathfind = true
		self.path.stuck_timer = 0

		minetest.after(1, function(self)
			if self.object:get_luaentity() then
				if has_lineofsight then
					self.path.following = false
				end
			end
		end, self)
	end

	if (self.path.stuck_timer > stuck_path_timeout and self.path.following) then
		use_pathfind = true
		self.path.stuck_timer = 0

		minetest.after(1, function(self)
			if self.object:get_luaentity() then
				if has_lineofsight then
					self.path.following = false
				end
			end
		end, self)
	end

	if abs(vsubtract(s, target_pos).y) > self.stepheight then
		if height_switcher then
			use_pathfind = true
			height_switcher = false
		end
	else
		if not height_switcher then
			use_pathfind = false
			height_switcher = true
		end
	end

	-- lets try find a path, first take care of positions
	-- since pathfinder is very sensitive
	if use_pathfind then
		-- round position to center of node to avoid stuck in walls
		-- also adjust height for player models!
		s.x = floor(s.x + 0.5)
		s.z = floor(s.z + 0.5)

		local ssight, sground = minetest.line_of_sight(s, {
			x = s.x, y = s.y - 4, z = s.z}, 1)

		-- determine node above ground
		if not ssight then
			s.y = sground.y + 1
		end

		local p1 = self.attack:get_pos()

		p1.x = floor(p1.x + 0.5)
		p1.y = floor(p1.y + 0.5)
		p1.z = floor(p1.z + 0.5)

		local dropheight = 6
		if self.fear_height ~= 0 then dropheight = self.fear_height end

		local jumpheight = 0

		if self.jump and self.jump_height >= 4 then
			jumpheight = min(ceil(self.jump_height / 4), 4)
		elseif self.stepheight > 0.5 then
			jumpheight = 1
		end

		self.path.way = minetest.find_path(s, p1, 16, jumpheight,
				dropheight, "Dijkstra")

--[[
		-- show path using particles
		if self.path.way and #self.path.way > 0 then
			print("-- path length:" .. tonumber(#self.path.way))
			for _, pos in pairs(self.path.way) do
				minetest.add_particle({
				pos = pos,
				velocity = {x=0, y=0, z=0},
				acceleration = {x=0, y=0, z=0},
				expirationtime = 1,
				size = 4,
				collisiondetection = false,
				vertical = false,
				texture = "heart.png"
				})
			end
		end
]]

		self.state = ""

		if self.attack then
			self:do_attack(self.attack)
		end

		-- no path found, try something else
		if not self.path.way then
			self.path.following = false

			-- lets make way by digging/building if not accessible
			if self.pathfinding == 2 and mobs_griefing then

				-- is player higher than mob?
				if s.y < p1.y then

					-- build upwards
					if not minetest.is_protected(s, "") then
						local ndef1 = minetest.registered_nodes[self.standing_in]

						if ndef1 and (ndef1.buildable_to or ndef1.groups.liquid) then
							minetest.set_node(s, {name = mobs.fallback_node})
						end
					end

					local sheight = ceil(self.collisionbox[5]) + 1

					-- assume mob is 2 blocks high so it digs above its head
					s.y = s.y + sheight

					-- remove one block above to make room to jump
					if not minetest.is_protected(s, "") then

						local node1 = node_ok(s, "air").name
						local ndef1 = minetest.registered_nodes[node1]

						if node1 ~= "air"
								and node1 ~= "ignore"
								and ndef1
								and not ndef1.groups.level
								and not ndef1.groups.unbreakable
								and not ndef1.groups.liquid then

							minetest.set_node(s, {name = "air"})
							minetest.add_item(s, ItemStack(node1))
						end
					end

					s.y = s.y - sheight
					self.object:set_pos({x = s.x, y = s.y + 2, z = s.z})

				else -- dig 2 blocks to make door toward player direction

					local yaw1 = self.object:get_yaw() + pi / 2
					local p1 = {
						x = s.x + cos(yaw1),
						y = s.y,
						z = s.z + sin(yaw1)
					}

					if not minetest.is_protected(p1, "") then
						local node1 = node_ok(p1, "air").name
						local ndef1 = minetest.registered_nodes[node1]

						if node1 ~= "air"
								and node1 ~= "ignore"
								and ndef1
								and not ndef1.groups.level
								and not ndef1.groups.unbreakable
								and not ndef1.groups.liquid then
							minetest.add_item(p1, ItemStack(node1))
							minetest.set_node(p1, {name = "air"})
						end

						p1.y = p1.y + 1
						node1 = node_ok(p1, "air").name
						ndef1 = minetest.registered_nodes[node1]

						if node1 ~= "air"
								and node1 ~= "ignore"
								and ndef1
								and not ndef1.groups.level
								and not ndef1.groups.unbreakable
								and not ndef1.groups.liquid then
							minetest.add_item(p1, ItemStack(node1))
							minetest.set_node(p1, {name = "air"})
						end
					end
				end
			end

			-- will try again in 2 second
			self.path.stuck_timer = stuck_timeout - 2

		elseif s.y < p1.y and (not self.fly) then
			self:do_jump() --add jump to pathfinding
			self.path.following = true
		else
			-- yay i found path
			if self.attack then
				self:mob_sound(self.sounds.war_cry)
			else
				self:mob_sound(self.sounds.random)
			end
			self:set_velocity(self.walk_velocity)

			-- follow path now that it has it
			self.path.following = true
		end
	end
end


-- general attack function for all mobs
function mob_class:general_attack()
	-- return if already attacking, passive or docile during day
	if self.passive
			or self.state == "runaway"
			or self.state == "attack"
			or self:day_docile() then
		return
	end

	local s = self.object:get_pos()
	if not s then return end
	local objs = minetest.get_objects_inside_radius(s, self.view_range)

	-- remove entities we aren't interested in
	for n = 1, #objs do
		local ent = objs[n]:get_luaentity()
		-- are we a player?
		if objs[n]:is_player() then
			-- if player invisible or mob cannot attack then remove from list
			if not damage_enabled
					or not self.attack_players
					or (self.owner and self.type ~= "monster")
					or is_invisible(self, objs[n]:get_player_name())
					or mobs.is_creative(objs[n]:get_player_name())
					or (self.specific_attack
							and not check_for("player", self.specific_attack)) then
				objs[n] = nil
			--	print("- pla", n)
			end
			-- or are we a mob?
		elseif ent and ent.obj_is_mob then
			-- remove mobs not to attack
			if self.name == ent.name
					or (not self.attack_animals and ent.type == "animal")
					or (not self.attack_monsters and ent.type == "monster")
					or (not self.attack_npcs and ent.type == "npc") then
				if not self.specific_attack or not check_for(ent.name, self.specific_attack) then
					objs[n] = nil
				end
			--	print("- mob", n, self.name, ent.name)
			end

			-- remove all other entities
		else
		--	print(" -obj", n)
			objs[n] = nil
		end
	end

	local p, sp, dist, min_player
	local min_dist = self.view_range + 1

	-- go through remaining entities and select closest
	for _, player in pairs(objs) do
		p = player:get_pos()
		sp = s

		dist = vdistance(p, s)

		-- aim higher to make looking up hills more realistic
		p.y = p.y + 1
		sp.y = sp.y + 1

		-- choose closest player to attack that isnt self
		if dist ~= 0
				and dist < min_dist
				and self:line_of_sight(sp, p, 2) then
			min_dist = dist
			min_player = player
		end
	end

	-- attack closest player or mob
	if min_player and random(100) > self.attack_chance then
		self:do_attack(min_player)
	end
end


-- find someone to runaway from
function mob_class:do_runaway_from()
	if not self.runaway_from then
		return
	end

	local s = self.object:get_pos()
	if not s then return end

	local p, sp, dist, pname
	local player, obj, min_player, name
	local min_dist = self.view_range + 1
	local objs = minetest.get_objects_inside_radius(s, self.view_range)

	for n = 1, #objs do
		if objs[n]:is_player() then
			pname = objs[n]:get_player_name()

			if is_invisible(self, pname)
					or mobs.is_creative(pname)
					or self.owner == pname then
				name = ""
			else
				player = objs[n]
				name = "player"
			end
		else
			obj = objs[n]:get_luaentity()

			if obj then
				player = obj.object
				name = obj.name or ""
			end
		end

		-- find specific mob to runaway from
		if name ~= "" and name ~= self.name
		and (self.runaway_from and check_for(name, self.runaway_from)) then
			sp = s
			p = player and player:get_pos() or s

			-- aim higher to make looking up hills more realistic
			p.y = p.y + 1
			sp.y = sp.y + 1

			dist = vdistance(p, s)

			-- choose closest player/mob to runaway from
			if dist < min_dist
					and self:line_of_sight(sp, p, 2) then
				min_dist = dist
				min_player = player
			end
		end
	end

	if min_player then
		yaw_to_pos(self, min_player:get_pos(), 3)

		self.state = "runaway"
		self.runaway_timer = 3
		self.following = nil
	end
end


-- follow player if owner or holding item, if fish outta water then flop
function mob_class:follow_flop()
	-- find player to follow
	if (self.follow ~= "" or self.order == "follow")
			and not self.following
			and self.state ~= "attack"
			and self.state ~= "runaway" then
		local s = self.object:get_pos()
		if not s then return end

		if self.player_iter == nil then
			self.player_iter = minetest.get_player_iter()
		end

		for _ = 1, players_per_step do
			local name = self.player_iter()
			if not name then
				self.player_iter = nil
				break
			end
			local player = minetest.get_player_by_name(name)
			if player and not is_invisible(self, name) and
					vdistance(player:get_pos(), s) < self.view_range then
				self.following = player
				break
			end
		end
	end

	if self.type == "npc"
			and self.order == "follow"
			and self.state ~= "attack"
			and self.owner ~= "" then
		-- npc stop following player if not owner
		if self.following
				and self.owner
				and self.owner ~= self.following:get_player_name() then
			self.following = nil
		end
	else
		-- stop following player if not holding specific item or mob is horny
		if self.following
		and self.following:is_player()
		and (self:follow_holding(self.following) == false
		or self.horny) then
			self.following = nil
		end
	end

	-- follow that thing
	if self.following then
		local s = self.object:get_pos()
		if not s then return end
		local p

		if self.following:is_player() then
			p = self.following:get_pos()
		elseif self.following.object then
			p = self.following.object:get_pos()
		end

		if p then
			local dist = vdistance(p, s)

			-- dont follow if out of range
			if dist > self.view_range then
				self.following = nil
			else
				yaw_to_pos(self, p)

				-- anyone but standing npc's can move along
				if dist > self.reach
						and self.order ~= "stand" then
					self:set_velocity(self.walk_velocity)

					if self.walk_chance ~= 0 then
						self:set_animation("walk")
					end
				else
					self:set_velocity(0)
					self:set_animation("stand")
				end
				return
			end
		end
	end

	-- swimmers flop when out of their element, and swim again when back in
	if self.fly then
		if not self:attempt_flight_correction() then
			self.state = "flop"

			-- do we have a custom on_flop function?
			if self.on_flop then
				if self:on_flop(self) then
					return
				end
			end

			self.object:set_velocity({x = 0, y = -5, z = 0})
			self:set_animation("stand")
			return
		elseif self.state == "flop" then
			self.state = "stand"
		end
	end
end


-- dogshoot attack switch and counter function
function mob_class:dogswitch(dtime)
	-- switch mode not activated
	if not self.dogshoot_switch
			or not dtime then
		return 0
	end

	self.dogshoot_count = self.dogshoot_count + dtime

	if (self.dogshoot_switch == 1
			and self.dogshoot_count > self.dogshoot_count_max)
			or (self.dogshoot_switch == 2
			and self.dogshoot_count > self.dogshoot_count2_max) then

		self.dogshoot_count = 0

		if self.dogshoot_switch == 1 then
			self.dogshoot_switch = 2
		else
			self.dogshoot_switch = 1
		end
	end
	return self.dogshoot_switch
end


-- execute current state (stand, walk, run, attacks)
function mob_class:do_states(dtime)
	local yaw = self.object:get_yaw()
	if not yaw then return end

	if self.state == "stand" then
		if self.randomly_turn and random(4) == 1 then
			local lp
			local s = self.object:get_pos()
			local objs = minetest.get_objects_inside_radius(s, 3)

			for n = 1, #objs do
				if objs[n]:is_player() then
					lp = objs[n]:get_pos()
					break
				end
			end

			-- look at any players nearby, otherwise turn randomly
			if lp then
				yaw = yaw_to_pos(self, lp)
			else
				yaw = yaw + random(-0.5, 0.5)
			end

			yaw = self:set_yaw(yaw, 8)
		end

		self:set_velocity(0)
		self:set_animation("stand")

		-- mobs ordered to stand stay standing
		if self.order ~= "stand"
				and self.walk_chance ~= 0
				and self.facing_fence ~= true
				and random(100) <= self.walk_chance
				and not self.at_cliff then
			self:set_velocity(self.walk_velocity)
			self.state = "walk"
			self:set_animation("walk")
		end
	elseif self.state == "walk" then
		local s = self.object:get_pos()
		local lp

		-- is there something I need to avoid?
		if self.water_damage > 0
				and self.lava_damage > 0 then
			lp = minetest.find_node_near(s, 1, {"group:water", "group:igniter"})
		elseif self.water_damage > 0 then
			lp = minetest.find_node_near(s, 1, {"group:water"})
		elseif self.lava_damage > 0 then
			lp = minetest.find_node_near(s, 1, {"group:igniter"})
		end

		if lp then
			-- if mob in dangerous node then look for land
			if not is_node_dangerous(self, self.standing_in) then
				lp = minetest.find_nodes_in_area_under_air(
					{s.x - 5, s.y - 1, s.z - 5},
					{s.x + 5, s.y + 2, s.z + 5},
					{"group:soil", "group:stone", "group:sand",
							node_ice, node_snowblock})

				-- select position of random block to climb onto
				lp = #lp > 0 and lp[random(#lp)]

				-- did we find land?
				if lp then
					yaw = yaw_to_pos(self, lp)

					self:do_jump()
					self:set_velocity(self.walk_velocity)
				else
					yaw = yaw + random(-0.5, 0.5)
				end
			end

			yaw = self:set_yaw(yaw, 8)

		-- otherwise randomly turn
		elseif self.randomly_turn and random(10) <= 3 then
			yaw = yaw + random(-0.5, 0.5)
			yaw = self:set_yaw(yaw, 8)

			-- for flying/swimming mobs randomly move up and down also
			if self.fly_in
			and not self.following then
				self:attempt_flight_correction(true)
			end
		end

		-- stand for great fall in front
		if self.facing_fence or self.at_cliff
				or random(100) <= self.stand_chance then
			-- don't stand if mob flies and keep_flying set
			if (self.fly and not self.keep_flying)
			or not self.fly then
			self:set_velocity(0)
			self.state = "stand"
			self:set_animation("stand", true)
			end
		else
			self:set_velocity(self.walk_velocity)

			if self:flight_check()
					and self.animation
					and self.animation.fly_start
					and self.animation.fly_end then
				self:set_animation("fly")
			else
				self:set_animation("walk")
			end
		end

	-- runaway when punched
	elseif self.state == "runaway" then
		self.runaway_timer = self.runaway_timer + 1

		-- stop after 5 seconds or when at cliff
		if self.runaway_timer > 5
				or self.at_cliff
				or self.order == "stand" then
			self.runaway_timer = 0
			self:set_velocity(0)
			self.state = "stand"
			self:set_animation("stand")
		else
			self:set_velocity(self.run_velocity)
			self:set_animation("walk")
		end

	-- attack routines (explode, dogfight, shoot, dogshoot)
	elseif self.state == "attack" then
		-- get mob and enemy positions and distance between
		local s = self.object:get_pos()
		local p = self.attack and self.attack:get_pos()
		local dist = p and vdistance(p, s) or 500

		-- stop attacking if player out of range or invisible
		if dist > self.view_range
				or not self.attack
				or not self.attack:get_pos()
				or self.attack:get_hp() <= 0
				or (self.attack:is_player()
				and is_invisible(self, self.attack:get_player_name())) then
		--	print(" ** stop attacking **", dist, self.view_range)
			self.state = "stand"
			self:set_velocity(0)
			self:set_animation("stand")
			self.attack = nil
			self.v_start = false
			self.timer = 0
			self.blinktimer = 0
			self.path.way = nil
			return
		end

		if self.attack_type == "explode" then
			yaw = yaw_to_pos(self, p)

			local node_break_radius = self.explosion_radius or 1
			local entity_damage_radius = self.explosion_damage_radius
					or (node_break_radius * 2)

			-- look a little higher to fix raycast
			s.y = s.y + 0.5 ; p.y = p.y + 0.5

			-- start timer when in reach and line of sight
			if not self.v_start and dist <= self.reach
					and self:line_of_sight(s, p, 2) then
				self.v_start = true
				self.timer = 0
				self.blinktimer = 0
				self:mob_sound(self.sounds.fuse)
			--	print("=== explosion timer started", self.explosion_timer)

			-- stop timer if out of reach or direct line of sight
			elseif self.allow_fuse_reset
					and self.v_start and (dist > self.reach
					or not self:line_of_sight(s, p, 2)) then
				self.v_start = false
				self.timer = 0
				self.blinktimer = 0
				self.blinkstatus = false
				self.object:set_texture_mod("")
			end

			-- walk right up to player unless the timer is active
			if self.v_start and (self.stop_to_explode or dist < 1.5) then
				self:set_velocity(0)
			else
				self:set_velocity(self.run_velocity)
			end

			if self.animation and self.animation.run_start then
				self:set_animation("run")
			else
				self:set_animation("walk")
			end

			if self.v_start then
				self.timer = self.timer + dtime
				self.blinktimer = (self.blinktimer or 0) + dtime

				if self.blinktimer > 0.2 then
					self.blinktimer = 0

					if self.blinkstatus then
						self.object:set_texture_mod(self.texture_mods)
					else
						self.object:set_texture_mod(self.texture_mods .. "^[brighten")
					end
					self.blinkstatus = not self.blinkstatus
				end

			--	print("=== explosion timer", self.timer)

				if self.timer > self.explosion_timer then
					local pos = self.object:get_pos()

					-- dont damage anything if area protected or next to water
					if minetest.find_node_near(pos, 1, {"group:water"})
							or minetest.is_protected(pos, "") then

						node_break_radius = 1
					end

					remove_mob(self, true)

					if minetest.get_modpath("tnt") and tnt and tnt.boom
							and not minetest.is_protected(pos, "") then
						tnt.boom(pos, {
							radius = node_break_radius,
							damage_radius = entity_damage_radius,
							sound = self.sounds.explode
						})
					else
						minetest.sound_play(self.sounds.explode, {
							pos = pos,
							gain = 1.0,
							max_hear_distance = self.sounds.distance or 32
						})

						entity_physics(pos, entity_damage_radius)
						effect(pos, 32, "bubble.png", nil, nil, node_break_radius, 1, 0)
					end

					return true
				end
			end
		elseif self.attack_type == "dogfight"
				or (self.attack_type == "dogshoot" and self:dogswitch(dtime) == 2)
				or (self.attack_type == "dogshoot" and dist <= self.reach
				and self:dogswitch() == 0) then
			if self.fly and dist > self.reach then
				local p1 = s
				local me_y = floor(p1.y)
				local p2 = p
				local p_y = floor(p2.y + 1)
				local v = self.object:get_velocity()

				if self:flight_check() then
					if me_y < p_y then
						self.object:set_velocity({
							x = v.x,
							y = 1 * self.walk_velocity,
							z = v.z
						})
					elseif me_y > p_y then
						self.object:set_velocity({
							x = v.x,
							y = -1 * self.walk_velocity,
							z = v.z
						})
					end
				else
					if me_y < p_y then
						self.object:set_velocity({
							x = v.x,
							y = 0.01,
							z = v.z
						})

					elseif me_y > p_y then
						self.object:set_velocity({
							x = v.x,
							y = -0.01,
							z = v.z
						})
					end
				end
			end

			-- rnd: new movement direction
			if self.path.following and self.path.way
					and self.attack_type ~= "dogshoot" then
				-- no paths longer than 50
				if #self.path.way > 50
						or dist < self.reach then
					self.path.following = false
					return
				end

				local p1 = self.path.way[1]
				if not p1 then
					self.path.following = false
					return
				end

				if abs(p1.x - s.x) + abs(p1.z - s.z) < 0.6 then
					-- reached waypoint, remove it from queue
					table_remove(self.path.way, 1)
				end

				-- set new temporary target
				p = {x = p1.x, y = p1.y, z = p1.z}
			end

			yaw = yaw_to_pos(self, p)

			-- move towards enemy if beyond mob reach
			if dist > self.reach and (p.y - s.y) < 4 then
				-- path finding by rnd
				if self.pathfinding -- only if mob has pathfinding enabled
						and enable_pathfinding then
					self:smart_mobs(s, p, dist, dtime)
				end

				if self.at_cliff then
					self:set_velocity(0)
					self:set_animation("stand")
				else
					if self.path.stuck then
						self:set_velocity(self.walk_velocity)
					else
						self:set_velocity(self.run_velocity)
					end

					if self.animation and self.animation.run_start then
						self:set_animation("run")
					else
						self:set_animation("walk")
					end
				end
			else -- rnd: if inside reach range
				self.path.stuck = false
				self.path.stuck_timer = 0
				self.path.following = false -- not stuck anymore
				self:set_velocity(0)

				if self.timer > 1 then
					-- no custom attack or custom attack returns true to continue
					if not self.custom_attack
					or self:custom_attack(self, p) == true then
						self.timer = 0
						self:set_animation("punch")

						local p2 = p
						local s2 = s

						p2.y = p2.y + .5
						s2.y = s2.y + .5

						if self:line_of_sight(p2, s2) and (p.y - s.y) < 4 then
							-- play attack sound
							self:mob_sound(self.sounds.attack)

							-- punch player (or what player is attached to)
							local attached = self.attack:get_attach()
							if attached then
								self.attack = attached
							end
							self.attack:punch(self.object, 1.0, {
								full_punch_interval = 1.0,
								damage_groups = {fleshy = self.damage}
							}, nil)
						end
					end
				end
			end
		elseif self.attack_type == "shoot"
				or (self.attack_type == "dogshoot" and self:dogswitch(dtime) == 1)
				or (self.attack_type == "dogshoot" and dist > self.reach and self:dogswitch() == 0) then

			p.y = p.y - .5
			s.y = s.y + .5

			local vec = {x = p.x - s.x, y = p.y - s.y, z = p.z - s.z}

			yaw = yaw_to_pos(self, p)

			self:set_velocity(0)

			if self.shoot_interval
					and self.timer > self.shoot_interval
					and random(10) <= 6 then
				self.timer = 0
				self:set_animation("shoot")

				-- play shoot attack sound
				self:mob_sound(self.sounds.shoot_attack)

				local p = self.object:get_pos()

				p.y = p.y + (self.collisionbox[2] + self.collisionbox[5]) / 2

				if minetest.registered_entities[self.arrow] then
					local obj = minetest.add_entity(p, self.arrow)
					local ent = obj:get_luaentity()
					local amount = (vec.x * vec.x + vec.y * vec.y + vec.z * vec.z) ^ 0.5
					local v = ent.velocity or 1 -- or set to default

					ent.switch = 1
					ent.owner_id = tostring(self.object) -- add unique owner id to arrow

					-- offset makes shoot aim accurate
					vec.y = vec.y + self.shoot_offset
					vec.x = vec.x * (v / amount)
					vec.y = vec.y * (v / amount)
					vec.z = vec.z * (v / amount)

					obj:set_velocity(vec)
				end
			end
		end
	end
end


-- falling and fall damage
function mob_class:falling(pos)
	if self.fly or self.disable_falling then
		return
	end

	-- floating in water (or falling)
	local v = self.object:get_velocity()

	-- sanity check
	if not v then return end

	if v.y > 0 then
		-- apply gravity when moving up
		self.object:set_acceleration({
			x = 0,
			y = -9.81,
			z = 0
		})

	elseif v.y <= 0 and v.y > self.fall_speed then
		-- fall downwards at set speed
		self.object:set_acceleration({
			x = 0,
			y = self.fall_speed,
			z = 0
		})
	else
		-- stop accelerating once max fall speed hit
		self.object:set_acceleration({x = 0, y = 0, z = 0})
	end

	-- in water then float up
	if self.standing_in
	and minetest.registered_nodes[self.standing_in].groups.water then
		if self.floats then
			self.object:set_acceleration({
				x = 0,
				y = -self.fall_speed / (max(1, v.y) ^ 8),
				z = 0
			})
		end
	else
		-- fall damage onto solid ground
		if self.fall_damage == 1
		and self.object:get_velocity().y == 0 then
			local d = (self.old_y or 0) - self.object:get_pos().y

			if d > 5 then
				self.object:punch(self.object, 1.0, {
					full_punch_interval = 1.0,
					damage_groups = {fleshy = floor(d - 5)},
				}, nil)

				effect(pos, 5, "item_smoke.png", 1, 2, 2, nil)

				if self:check_for_death({type = "fall"}) then
					return true
				end
			end

			self.old_y = self.object:get_pos().y
		end
	end
end


-- is Took Ranks mod active?
local tr = minetest.get_modpath("toolranks")

-- deal damage and effects when mob punched
function mob_class:on_punch(hitter, tflp, tool_capabilities, dir, damage)
	-- mob health check
	if self.health <= 0 then
		return true
	end

	-- custom punch function
	if self.do_punch and not self:do_punch(hitter, tflp, tool_capabilities, dir) then
		return true
	end

	-- error checking when mod profiling is enabled
	if not tool_capabilities then
		minetest.log("warning", "[mobs] Mod profiling enabled, damage not enabled")
		return true
	end

	-- is mob protected
	if self.tamed then
		-- did player hit mob and if so is it in protected area
		if hitter:is_player() then
			local player_name = hitter:get_player_name()

			if player_name ~= self.owner
			and minetest.is_protected(self.object:get_pos(), player_name) then
				minetest.chat_send_player(player_name,
						S("Mob has been protected!"))

				return true
			end
		end
	end

	local weapon = hitter:get_wielded_item()
	local weapon_def = weapon:get_definition() or {}
	local punch_interval = 1.4

	-- calculate mob damage
	local damage = 0
	local armor = self.object:get_armor_groups() or {}
	local tmp

	-- quick error check incase it ends up 0 (serialize.h check test)
	if tflp == 0 then
		tflp = 0.2
	end

	for group, _ in pairs((tool_capabilities.damage_groups or {})) do
		tmp = tflp / (tool_capabilities.full_punch_interval or 1.4)
		if tmp < 0 then
			tmp = 0.0
		elseif tmp > 1 then
			tmp = 1.0
		end

		damage = damage + (tool_capabilities.damage_groups[group] or 0)
				* tmp * ((armor[group] or 0) / 100.0)
	end

	-- check for tool immunity or special damage
	for n = 1, #self.immune_to do
		if self.immune_to[n][1] == weapon_def.name then
			damage = self.immune_to[n][2] or 0
			break

		-- if "all" then no tools deal damage unless it's specified in list
		elseif self.immune_to[n][1] == "all" then
			damage = self.immune_to[n][2] or 0
		end
	end

-- print("Mob Damage is ", damage)

	-- healing
	if damage <= -1 then
		self.health = self.health - floor(damage)
		return true
	end

	-- add weapon wear
	punch_interval = tool_capabilities.full_punch_interval or 1.4

	-- toolrank support
	local wear = floor((punch_interval / 75) * 9000)

	if tr then
		if weapon_def.original_description then
			toolranks.new_afteruse(weapon, hitter, nil, {wear = wear})
		end
	else
		weapon:add_wear(wear)
	end

	hitter:set_wielded_item(weapon)

	-- only play hit sound and show blood effects if damage is 1 or over
	if damage >= 1 then
		-- blood_particles
		if not disable_blood and self.blood_amount > 0 then
			local pos = self.object:get_pos()
			local blood = self.blood_texture
			local amount = self.blood_amount
			pos.y = pos.y + (-self.collisionbox[2] + self.collisionbox[5]) * .5

			-- lots of damage = more blood :)
			if damage > 10 then
				amount = self.blood_amount * 2
			end

			-- do we have a single blood texture or multiple?
			if type(self.blood_texture) == "table" then
				blood = self.blood_texture[random(#self.blood_texture)]
			end

			effect(pos, amount, blood, 1, 2, 1.75, nil, nil, true)
		end

		-- do damage
		self.health = self.health - floor(damage)
		-- exit here if dead, check for tools with fire damage
		local hot = tool_capabilities and tool_capabilities.damage_groups
				and tool_capabilities.damage_groups.fire

		if self:check_for_death({
			type = "punch",
			puncher = hitter,
			hot = hot
		}) then
			return true
		end

		-- add healthy afterglow when hit (can cause lag with larger textures)
		minetest.after(0.1, function()
			if not self.object:get_luaentity() then return end

			self.object:set_texture_mod(self.texture_mods
								.. "^[colorize:#ff000085")

			minetest.after(0.5, function()
				if not self.object:get_luaentity() then return end
				self.object:set_texture_mod(self.texture_mods)
			end)
		end)
	end -- END if damage

	-- knock back effect (only on full punch)
	if self.knock_back and tflp >= punch_interval then
		local v = self.object:get_velocity()

		-- sanity check
		if not v then return true end

		local kb = damage or 1
		local up = 2

		-- if already in air then dont go up anymore when hit
		if v.y > 0 or self.fly then
			up = 0
		end

		-- direction error check
		dir = dir or {x = 0, y = 0, z = 0}

		-- use tool knockback value or default
		kb = tool_capabilities.damage_groups["knockback"] or kb

		self.object:set_velocity({
			x = dir.x * kb,
			y = up,
			z = dir.z * kb
		})

		self.pause_timer = 0.25
	end

	-- if skittish then run away
	if self.runaway and self.order ~= "stand" then
		local lp = hitter:get_pos()
		local yaw = yaw_to_pos(self, lp, 3)

		self.state = "runaway"
		self.runaway_timer = 0
		self.following = nil
	end

	local name = hitter:get_player_name() or ""

	-- attack puncher and call other mobs for help
	if not self.passive
			and self.state ~= "flop"
			and not self.child
			and self.attack_players
			and hitter:get_player_name() ~= self.owner
			and not is_invisible(self, name)
			and self.object ~= hitter then
		-- attack whoever punched mob
		self.state = ""
		self:do_attack(hitter)

		-- alert others to the attack
		local objs = minetest.get_objects_inside_radius(
				hitter:get_pos(), self.view_range)
		local obj

		for n = 1, #objs do
			obj = objs[n]:get_luaentity()

			if obj and obj.obj_is_mob then
				-- only alert members of same mob
				if obj.group_attack
						and obj.state ~= "attack"
						and obj.owner ~= name
						and (obj.name == self.name
								or obj.name == self.group_helper) then
					obj:do_attack(hitter)
				end

				-- have owned mobs attack player threat
				if obj.owner == name and obj.owner_loyal then
					obj:do_attack(self.object)
				end
			end
		end
	end
end


-- get entity staticdata
function mob_class:mob_staticdata()
	-- this handles mob count for mobs activated, unloaded, reloaded
	if active_limit > 0 and self.active_toggle then
		active_mobs = active_mobs + self.active_toggle
		self.active_toggle = -self.active_toggle
--	print("-- staticdata", active_mobs, active_limit, self.active_toggle)
	end

	-- remove mob when out of range unless tamed
	if remove_far
			and self.remove_ok
			and self.type ~= "npc"
			and self.state ~= "attack"
			and not self.tamed
			and self.lifetimer < 20000 then
	--	print("REMOVED " .. self.name)

		remove_mob(self, true)

		return minetest.serialize({remove_ok = true, static_save = true})
	end

	self.remove_ok = true
	self.attack = nil
	self.following = nil
	self.state = "stand"

	-- used to rotate older mobs
	if self.drawtype and self.drawtype == "side" then
		self.rotate = rad(90)
	end

	local tmp, t = {}

	for _, stat in pairs(self) do
		t = type(stat)

		if  t ~= "function"
		and t ~= "nil"
		and t ~= "userdata"
		and _ ~= "object"
		and _ ~= "_cmi_components" then
			tmp[_] = self[_]
		end
	end

--	print('===== '..self.name..'\n'.. dump(tmp)..'\n=====\n')
	return minetest.serialize(tmp)
end


-- activate mob and reload settings
function mob_class:mob_activate(staticdata, def, dtime)
	-- if dtime == 0 then entity has just been created
	-- anything higher means it is respawning (thanks SorceryKid)
	if dtime == 0 and active_limit > 0 then
		self.active_toggle = 1
	end

	-- remove mob if not tamed and mob total reached
	if active_limit > 0 and active_mobs >= active_limit and not self.tamed then

		remove_mob(self)
--print("-- mob limit reached, removing " .. self.name)
		return
	end

	-- remove monsters in peaceful mode
	if self.type == "monster" and peaceful_only then
		remove_mob(self, true)
		return
	end

	-- load entity variables
	local tmp = minetest.deserialize(staticdata)

	if tmp then
		local t

		for _, stat in pairs(tmp) do
			t = type(stat)

			if  t ~= "function"
			and t ~= "nil"
			and t ~= "userdata" then
				self[_] = stat
			end
		end
	end

	-- force current model into mob
	self.mesh = def.mesh
	self.base_mesh = def.mesh
	self.collisionbox = def.collisionbox
	self.selectionbox = def.selectionbox

	-- select random texture, set model and size
	if not self.base_texture then
		-- compatiblity with old simple mobs textures
		if def.textures and type(def.textures[1]) == "string" then
			def.textures = {def.textures}
		end

		self.base_texture = def.textures and def.textures[random(#def.textures)]
		self.base_mesh = def.mesh
		self.base_size = self.visual_size
		self.base_colbox = self.collisionbox
		self.base_selbox = self.selectionbox
	end

	-- for current mobs that dont have this set
	if not self.base_selbox then
		self.base_selbox = self.selectionbox or self.base_colbox
	end

	-- set texture, model and size
	local textures = self.base_texture
	local mesh = self.base_mesh
	local vis_size = self.base_size
	local colbox = self.base_colbox
	local selbox = self.base_selbox

	-- specific texture if gotten
	if self.gotten and def.gotten_texture then
		textures = def.gotten_texture
	end

	-- specific mesh if gotten
	if self.gotten and def.gotten_mesh then
		mesh = def.gotten_mesh
	end

	-- set child objects to half size
	if self.child then
		vis_size = {
			x = self.base_size.x * .5,
			y = self.base_size.y * .5
		}

		if def.child_texture then
			textures = def.child_texture[1]
		end

		colbox = {
			self.base_colbox[1] * .5, self.base_colbox[2] * .5,
			self.base_colbox[3] * .5, self.base_colbox[4] * .5,
			self.base_colbox[5] * .5, self.base_colbox[6] * .5
		}
		selbox = {
			self.base_selbox[1] * .5, self.base_selbox[2] * .5,
			self.base_selbox[3] * .5, self.base_selbox[4] * .5,
			self.base_selbox[5] * .5, self.base_selbox[6] * .5
		}
	end

	if self.health == 0 then
		self.health = random(self.hp_min, self.hp_max)
	end

	-- pathfinding init
	self.path = {}
	self.path.way = {} -- path to follow, table of positions
	self.path.lastpos = {x = 0, y = 0, z = 0}
	self.path.stuck = false
	self.path.following = false -- currently following path?
	self.path.stuck_timer = 0 -- if stuck for too long search for path

	-- Armor groups (immortal = 1 for custom damage handling)
	local armor
	if type(self.armor) == "table" then
		armor = table_copy(self.armor)
		armor.immortal = 1
	else
		armor = {immortal = 1, fleshy = self.armor}
	end
	self.object:set_armor_groups(armor)

	-- mob defaults
	self.old_y = self.object:get_pos().y
	self.old_health = self.health
	self.sounds.distance = self.sounds.distance or 10
	self.textures = textures
	self.mesh = mesh
	self.collisionbox = colbox
	self.selectionbox = selbox
	self.visual_size = vis_size
	self.standing_in = "air"
	self.standing_on = "air"

	-- check existing nametag
	if not self.nametag then
		self.nametag = def.nametag
	end

	-- set anything changed above
	self.object:set_properties(self)
	self:set_yaw((random(0, 360) - 180) / 180 * pi, 6)
	self:update_tag()
	self:set_animation("stand")

	-- apply any texture mods
	self.object:set_texture_mod(self.texture_mods)

	-- set 5.x flag to remove monsters when map area unloaded
	if remove_far and self.type == "monster" then
		self.static_save = false
	end

	-- run on_spawn function if found
	if self.on_spawn and not self.on_spawn_run then
		if self.on_spawn(self) then
			self.on_spawn_run = true -- if true, set flag to run once only
		end
	end

	-- run after_activate
	if def.after_activate then
		def.after_activate(self, staticdata, def, dtime)
	end
end


-- handle mob lifetimer and expiration
function mob_class:mob_expire(pos, dtime)
	-- when lifetimer expires remove mob (except tamed)
	if not self.tamed
			and self.state ~= "attack"
			and remove_far ~= true
			and self.lifetimer < 20000 then
		self.lifetimer = self.lifetimer - dtime

		if self.lifetimer <= 0 then
			-- only despawn away from player
			local objs = minetest.get_objects_inside_radius(pos, 15)

			for n = 1, #objs do
				if objs[n]:is_player() then
					self.lifetimer = 20
					return
				end
			end

--			minetest.log("action",
--				S("lifetimer expired, removed @1", self.name))

--			effect(pos, 15, "item_smoke.png", 2, 4, 2, 0)

			remove_mob(self, true)

			return
		end
	end
end


-- main mob function
function mob_class:on_step(dtime)
	if self.state == "die" then return end

	local pos = self.object:get_pos()
	local yaw = self.object:get_yaw()

	-- early warning check, if no yaw then no entity, skip rest of function
	if not yaw then return end

	-- get node at foot level every quarter second
	self.node_timer = (self.node_timer or 0) + dtime

	if self.node_timer > 0.25 then
		self.node_timer = 0
		local y_level = self.collisionbox[2]
		if self.child then
			y_level = self.collisionbox[2] * 0.5
		end

		-- what is mob standing in?
		self.standing_in = node_ok({
			x = pos.x,
			y = pos.y + y_level + 0.5,
			z = pos.z
		}, "air").name

		self.standing_on = node_ok({
			x = pos.x,
			y = pos.y + y_level - 0.25,
			z = pos.z
		}, "air").name

--		print("standing in " .. self.standing_in)

		-- if standing inside solid block then jump to escape
		if minetest.registered_nodes[self.standing_in].walkable and
				minetest.registered_nodes[self.standing_in].drawtype == "normal" then
			self.object:set_velocity({
				x = 0,
				y = self.jump_height,
				z = 0
			})
		end

		-- check and stop if standing at cliff and fear of heights
		self.at_cliff = self:is_at_cliff()

		if self.at_cliff then
			self:set_velocity(0)
		end

		-- has mob expired (0.25 instead of dtime since were in a timer)
		self:mob_expire(pos, 0.25)
	end

	-- check if falling, flying, floating and return if player died
	if self:falling(pos) then
		return
	end

	-- smooth rotation by ThomasMonroe314
	if self.delay and self.delay > 0 then
		if self.delay == 1 then
			yaw = self.target_yaw
		else
			local dif = abs(yaw - self.target_yaw)

			if yaw > self.target_yaw then
				if dif > pi then
					dif = 2 * pi - dif -- need to add
					yaw = yaw + dif / self.delay
				else
					yaw = yaw - dif / self.delay -- need to subtract
				end
			elseif yaw < self.target_yaw then
				if dif > pi then
					dif = 2 * pi - dif
					yaw = yaw - dif / self.delay -- need to subtract
				else
					yaw = yaw + dif / self.delay -- need to add
				end
			end

			if yaw > (pi * 2) then yaw = yaw - (pi * 2) end
			if yaw < 0 then yaw = yaw + (pi * 2) end
		end

		self.delay = self.delay - 1
		self.object:set_yaw(yaw)
	end

	-- knockback timer
	if self.pause_timer > 0 then
		self.pause_timer = self.pause_timer - dtime
		return
	end

	-- run custom function (defined in mob lua file)
	if self.do_custom then
		-- when false skip going any further
		if self:do_custom(dtime) == false then
			return
		end
	end

	-- attack timer
	self.timer = self.timer + dtime

	if self.state ~= "attack" then
		if self.timer < 1 then
			return
		end
		self.timer = 0
	end

	-- never go over 100
	if self.timer > 100 then
		self.timer = 1
	end

	-- mob plays random sound at times
	if random(100) == 1 then
		self:mob_sound(self.sounds.random)
	end

	-- environmental damage timer (every 1 second)
	self.env_damage_timer = self.env_damage_timer + dtime

	if (self.state == "attack" and self.env_damage_timer > 1)
			or self.state ~= "attack" then
		self.env_damage_timer = 0

		-- check for environmental damage (water, fire, lava etc.)
		if self:do_env_damage() then return end

		-- node replace check (cow eats grass etc.)
		self:replace(pos)
	end

	self:general_attack()

	self:breed()

	self:follow_flop()

	if self:do_states(dtime) then return end

	self:do_jump()

	self:do_runaway_from(self)

	self:do_stay_near()
end


-- default function when mobs are blown up with TNT
function mob_class:on_blast(damage)
--	print("-- blast damage", damage)

	self.object:punch(self.object, 1.0, {
		full_punch_interval = 1.0,
		damage_groups = {fleshy = damage},
	}, nil)

	-- return no damage, no knockback, no item drops, mob api handles all
	return false, false, {}
end


mobs.spawning_mobs = {}

-- register mob entity
function mobs:register_mob(name, def)
	mobs.spawning_mobs[name] = {}

	minetest.register_entity(name, setmetatable({
		description = def.description or
			name:split(":")[2]:split("_")[1]:gsub("^%l", upper),
		stepheight = def.stepheight,
		name = name,
		type = def.type,
		attack_type = def.attack_type,
		fly = def.fly,
		fly_in = def.fly_in,
		keep_flying = def.keep_flying,
		owner = def.owner,
		order = def.order,
		on_die = def.on_die,
		on_flop = def.on_flop,
		do_custom = def.do_custom,
		jump_height = def.jump_height,
		drawtype = def.drawtype, -- DEPRECATED, use rotate instead
		rotate = rad(def.rotate or 0), -- 0=front, 90=side, 180=back, 270=side2
		glow = def.glow,
		lifetimer = def.lifetimer,
		hp_min = max(1, (def.hp_min or 5) * difficulty),
		hp_max = max(1, (def.hp_max or 10) * difficulty),
		collisionbox = def.collisionbox,
		selectionbox = def.selectionbox or def.collisionbox,
		visual = def.visual,
		visual_size = def.visual_size,
		mesh = def.mesh,
		makes_footstep_sound = def.makes_footstep_sound,
		view_range = def.view_range,
		walk_velocity = def.walk_velocity,
		run_velocity = def.run_velocity,
		damage = max(0, (def.damage or 0) * difficulty),
		light_damage = def.light_damage,
		light_damage_min = def.light_damage_min,
		light_damage_max = def.light_damage_max,
		water_damage = def.water_damage,
		lava_damage = def.lava_damage,
		fire_damage = def.fire_damage,
		air_damage = def.air_damage,
		suffocation = def.suffocation,
		fall_damage = def.fall_damage,
		fall_speed = def.fall_speed,
		drops = def.drops,
		armor = def.armor,
		on_rightclick = def.on_rightclick,
		on_punch = def.on_punch,
		arrow = def.arrow,
		shoot_interval = def.shoot_interval,
		sounds = def.sounds,
		animation = def.animation,
		follow = def.follow,
		jump = def.jump,
		walk_chance = def.walk_chance,
		stand_chance = def.stand_chance,
		attack_chance = def.attack_chance,
		passive = def.passive,
		knock_back = def.knock_back,
		blood_amount = def.blood_amount,
		blood_texture = def.blood_texture,
		shoot_offset = def.shoot_offset,
		floats = def.floats,
		replace_rate = def.replace_rate,
		replace_what = def.replace_what,
		replace_with = def.replace_with,
		replace_offset = def.replace_offset,
		on_replace = def.on_replace,
		reach = def.reach,
		texture_list = def.textures,
		texture_mods = def.texture_mods or "",
		child_texture = def.child_texture,
		docile_by_day = def.docile_by_day,
		fear_height = def.fear_height,
		runaway = def.runaway,
		pathfinding = def.pathfinding,
		immune_to = def.immune_to,
		explosion_radius = def.explosion_radius,
		explosion_damage_radius = def.explosion_damage_radius,
		explosion_timer = def.explosion_timer,
		allow_fuse_reset = def.allow_fuse_reset,
		stop_to_explode = def.stop_to_explode,
		custom_attack = def.custom_attack,
		double_melee_attack = def.double_melee_attack,
		dogshoot_switch = def.dogshoot_switch,
		dogshoot_count_max = def.dogshoot_count_max,
		dogshoot_count2_max = def.dogshoot_count2_max or def.dogshoot_count_max,
		group_attack = def.group_attack,
		group_helper = def.group_helper,
		attack_monsters = def.attacks_monsters,
		attack_animals = def.attack_animals,
		attack_players = def.attack_players,
		attack_npcs = def.attack_npcs,
		specific_attack = def.specific_attack,
		runaway_from = def.runaway_from,
		owner_loyal = def.owner_loyal,
		pushable = def.pushable,
		stay_near = def.stay_near,
		randomly_turn = def.randomly_turn ~= false,

		on_spawn = def.on_spawn,
		on_blast = def.on_blast, -- class redifinition

		do_punch = def.do_punch,
		on_breed = def.on_breed,
		on_grown = def.on_grown,
		on_activate = function(self, staticdata, dtime)
			return self:mob_activate(staticdata, def, dtime)
		end,

		get_staticdata = function(self)
			return self:mob_staticdata(self)
		end
	}, mob_class_meta))
end
-- END mobs:register_mob function


-- count how many mobs of one type are inside an area
-- will also return true for second value if player is inside area
local count_mobs = function(pos, type)
	local total = 0
	local objs = minetest.get_objects_inside_radius(pos, aoc_range)
	local ent
	local players

	for n = 1, #objs do
		if not objs[n]:is_player() then
			ent = objs[n]:get_luaentity()
			-- count mob type and add to total also
			if ent and ent.name and ent.name == type then
				total = total + 1
			end
		else
			players = true
		end
	end
	return total, players
end


-- global functions

function mobs:spawn_abm_check(pos, node, name)
	-- global function to add additional spawn checks
	-- return true to stop spawning mob
end


function mobs:spawn_specific(name, nodes, neighbors, min_light, max_light, interval,
		chance, aoc, min_height, max_height, day_toggle, on_spawn, map_load)
	-- Do mobs spawn at all?
	if not mobs_spawn or not mobs.spawning_mobs[name] then
		return
	end

	-- chance/spawn number override in minetest.conf for registered mob
	local numbers = settings:get(name)

	if numbers then
		numbers = numbers:split(",")
		chance = tonumber(numbers[1]) or chance
		aoc = tonumber(numbers[2]) or aoc

		if chance == 0 then
			minetest.log("warning", string.format("[mobs] %s has spawning disabled", name))
			return
		end

		minetest.log("action",
			string.format("[mobs] Chance setting for %s changed to %s (total: %s)",
				name, chance, aoc))
	end

	mobs.spawning_mobs[name].aoc = aoc

	local spawn_action = function(pos, node, active_object_count,
			active_object_count_wider)

		-- use instead of abm's chance setting when using lbm
		if map_load and random(max(1, chance)) > 1 then
			return
		end

		-- use instead of abm's neighbor setting when using lbm
		if map_load and not minetest.find_node_near(pos, 1, neighbors) then
--			print("--- lbm neighbors not found")
			return
		end

		-- is mob actually registered?
		if not mobs.spawning_mobs[name]
				or not minetest.registered_entities[name] then
		--	print("--- mob doesn't exist", name)
			return
		end

		-- are we over active mob limit
		if active_limit > 0 and active_mobs >= active_limit then
		--	print("--- active mob limit reached", active_mobs, active_limit)
			return
		end

		-- additional custom checks for spawning mob
		if mobs:spawn_abm_check(pos, node, name) then
			return
		end

		-- do not spawn if too many entities in area
		if active_object_count_wider
		and active_object_count_wider >= max_per_block then
		--	print("--- too many entities in area", active_object_count_wider)
			return
		end

		-- get total number of this mob in area
		local num_mob, is_pla = count_mobs(pos, name)

		if not is_pla then
		--	print("--- no players within active area, will not spawn " .. name)
			return
		end

		if num_mob >= aoc then
		--	print("--- too many " .. name .. " in area", num_mob .. "/" .. aoc)
			return
		end

		-- mobs cannot spawn in protected areas when enabled
		if spawn_protected
				and minetest.is_protected(pos, "") then
		--	print("--- inside protected area", name)
			return
		end

		-- if toggle set to nil then ignore day/night check
		if day_toggle ~= nil then
			local tod = (minetest.get_timeofday() or 0) * 24000

			if tod > 4500 and tod < 19500 then
				-- daylight, but mob wants night
				if not day_toggle then
				-- print("--- mob needs night", name)
					return
				end
			else
				-- night time but mob wants day
				if day_toggle then
				-- print("--- mob needs day", name)
					return
				end
			end
		end

		-- spawn above node
		pos.y = pos.y + 1

		-- are we spawning within height limits?
		if pos.y > max_height
				or pos.y < min_height then
		--	print("--- height limits not met", name, pos.y)
			return
		end

		-- are light levels ok?
		if min_light ~= 0 or max_light ~= 15 then
			local light = minetest.get_node_light(pos)
			if not light
					or light > max_light
					or light < min_light then
			--	print("--- light limits not met", name, light)
				return
			end
		end

		-- do we have enough height clearance to spawn mob?
		local ent = minetest.registered_entities[name]
		local height = max(0, ent.collisionbox[5] - ent.collisionbox[2])

		for n = 0, floor(height) do
			local pos2 = {x = pos.x, y = pos.y + n, z = pos.z}

			if minetest.registered_nodes[node_ok(pos2).name].walkable then
			--	print("--- inside block", name, node_ok(pos2).name)
				return
			end
		end

		if pos then
			-- adjust for mob collision box
			pos.y = pos.y + (ent.collisionbox[2] * -1) - 0.4

			local mob = minetest.add_entity(pos, name)

		--	print("[mobs] Spawned " .. name .. " at "
		--	.. minetest.pos_to_string(pos) .. " on "
		--	.. node.name .. " near " .. neighbors[1])

			if on_spawn then
				on_spawn(mob:get_luaentity(), pos)
			end
		else
		--	print("--- not enough space to spawn", name)
		end
	end


	-- are we registering an abm or lbm?
	if map_load == true then
		minetest.register_lbm({
			name = name .. "_spawning",
			label = name .. " spawning",
			nodenames = nodes,
			run_at_every_load = false,
			action = spawn_action
		})
	else
		minetest.register_abm({
			label = name .. " spawning",
			nodenames = nodes,
			neighbors = neighbors,
			interval = interval,
			chance = max(1, chance),
			catch_up = false,
			action = spawn_action
		})
	end
end


-- MarkBu's spawn function
function mobs:spawn(def)
	mobs:spawn_specific(
		def.name,
		def.nodes or {"group:soil", "group:stone"},
		def.neighbors or {"air"},
		def.min_light or 0,
		def.max_light or 15,
		def.interval or spawn_interval,
		def.chance or 5000,
		def.active_object_count or 1,
		def.min_height or -31000,
		def.max_height or 31000,
		def.day_toggle,
		def.on_spawn,
		def.on_map_load)
end


--[[
-- register arrow for shoot attack
function mobs:register_arrow(name, def)
	if not name or not def then return end

	minetest.register_entity(name, {
		physical = false,
		visual = def.visual,
		visual_size = def.visual_size,
		textures = def.textures,
		velocity = def.velocity,
		hit_player = def.hit_player,
		hit_node = def.hit_node,
		hit_mob = def.hit_mob,
		hit_object = def.hit_object,
		drop = def.drop or false, -- drops arrow as registered item when true
		collisionbox = def.collisionbox or {-.1, -.1, -.1, .1, .1, .1},
		timer = 0,
		lifetime = def.lifetime or 4.5,
		switch = 0,
		owner_id = def.owner_id,
		rotate = def.rotate,
		automatic_face_movement_dir = def.rotate
			and (def.rotate - (pi / 180)) or false,
		on_activate = def.on_activate,
		on_punch = def.on_punch or function(self, hitter, tflp, tool_capabilities, dir)
		end,

		on_step = def.on_step or function(self, dtime)
			self.timer = self.timer + dtime
			local pos = self.object:get_pos()
			if self.switch == 0
			or self.timer > self.lifetime then
				self.object:remove()
				return
			end

			-- does arrow have a tail (fireball)
			if def.tail
			and def.tail == 1
			and def.tail_texture then

				minetest.add_particle({
					pos = pos,
					velocity = {x = 0, y = 0, z = 0},
					acceleration = {x = 0, y = 0, z = 0},
					expirationtime = def.expire or 0.25,
					collisiondetection = false,
					texture = def.tail_texture,
					size = def.tail_size or 5,
					glow = def.glow or 0
				})
			end

			if self.hit_node then
				local node = node_ok(pos).name

				if minetest.registered_nodes[node].walkable then
					self:hit_node(pos, node)
					if self.drop then
						pos.y = pos.y + 1
						self.lastpos = (self.lastpos or pos)
						minetest.add_item(self.lastpos, self.object:get_luaentity().name)
					end
					self.object:remove()
					return
				end
			end

			if self.hit_player or self.hit_mob then
				for _, player in pairs(minetest.get_objects_inside_radius(pos, 1.0)) do
					if self.hit_player
					and player:is_player() then
						self:hit_player(player)
						self.object:remove()
						return
					end

					local entity = player:get_luaentity()

					if entity
					and self.hit_mob
					and entity.obj_is_mob
					and tostring(player) ~= self.owner_id
					and entity.name ~= self.object:get_luaentity().name then
						self:hit_mob(player)
						self.object:remove()
						return
					end
				end
			end
			self.lastpos = pos
		end
	})
end


-- compatibility function
function mobs:explosion(pos, radius)
	mobs:boom({sounds = {explode = "tnt_explode"}}, pos, radius)
end


-- no damage to nodes explosion
function mobs:safe_boom(self, pos, radius)
	minetest.sound_play(self.sounds and self.sounds.explode or "tnt_explode", {
		pos = pos,
		gain = 1.0,
		max_hear_distance = self.sounds and self.sounds.distance or 32
	})
	entity_physics(pos, radius)
--	effect(pos, 32, "item_smoke.png", radius * 3, radius * 5, radius, 1, 0)
end


-- make explosion with protection and tnt mod check
function mobs:boom(self, pos, radius)
	if mobs_griefing
			and minetest.get_modpath("tnt") and tnt and tnt.boom
			and not minetest.is_protected(pos, "") then
		tnt.boom(pos, {
			radius = radius,
			damage_radius = radius,
			sound = self.sounds and self.sounds.explode,
			explode_center = true,
		})
	else
		mobs:safe_boom(self, pos, radius)
	end
end
]]

-- Mob spawning, returns true on successful placement
local function spawn_mob(pos, mob, data, placer, drop)
	if not pos or not placer or not minetest.registered_entities[mob] then
		return false
	end

	local player_name = placer:get_player_name()

	if minetest.is_protected(pos, player_name) then
		if drop then
			minetest.add_item(pos, mob)
		end

		return false
	end

	-- have we reached active mob limit
	if active_limit > 0 and active_mobs >= active_limit then
		minetest.chat_send_player(player_name,
		S("Active Mob Limit Reached!")
		.. "  (" .. active_mobs
		.. " / " .. active_limit .. ")")
		if drop then
			minetest.add_item(pos, mob)
		end

		return false
	end

	pos.y = pos.y + 1
	local obj = minetest.add_entity(pos, mob)
	if obj then
		local ent = obj:get_luaentity()
		if ent then
			-- set owner if not a monster
			if ent.type ~= "monster" then
				ent.owner = player_name
				ent.tamed = true
				local infotext = S("Owned by @1", S(player_name))
				ent.infotext = infotext
				obj:set_properties({
					infotext = infotext
				})
			end
			return true
		else
			obj:remove()
		end
	end
end


-- Spawn egg throwing
local function throw_spawn_egg(itemstack, user, pointed_thing)
	local playerpos = user:get_pos()
	if not minetest.is_valid_pos(playerpos) then
		return
	end

	local mob = itemstack:get_name():gsub("_set$", "")
	local egg_impact = function(thrower, pos, dir, hit_object)
		spawn_mob(pos, mob, itemstack:get_metadata(), user, true)
	end
	local obj = minetest.item_throw(mob .. "_set", user, 19, -3, egg_impact)
	if obj then
		local def = minetest.registered_items[mob .. "_set"]
		if def and def.inventory_image and def.inventory_image ~= "" then
			obj:set_properties({
				visual = "sprite",
				visual_size = {x = 0.5, y = 0.5},
				textures = {def.inventory_image}
			})
		end
		minetest.sound_play("throwing_sound", {
			pos = playerpos,
			gain = 0.7,
			max_hear_distance = 10
		})
		if not mobs.is_creative(user) or not singleplayer then
			itemstack:take_item()
		end
	end
	return itemstack
end

-- Register spawn eggs

-- Note: This also introduces the "spawn_egg" group:
-- * spawn_egg=1: Spawn egg (generic mob, no metadata)
-- * spawn_egg=2: Spawn egg (captured/tamed mob, metadata)
function mobs:register_egg(mob, desc, background, addegg, no_creative)
	local grp = {spawn_egg = 1}

	-- do NOT add this egg to creative inventory (e.g. dungeon master)
	if creative and no_creative then
		grp.not_in_creative_inventory = 1
	end

	local invimg = background
	if addegg then
		invimg = "(" .. invimg ..
				"^[resize:64x64^[mask:mobs_egg_overlay.png)"
	end

	-- register new spawn egg containing mob information
	minetest.register_craftitem(mob .. "_set", {
		description = S("@1 (Tamed)", desc),
		inventory_image = invimg,
		groups = {spawn_egg = 2, not_in_creative_inventory = 1},
		stack_max = 1,
		on_use = throw_spawn_egg,
		on_place = function(itemstack, placer, pointed_thing)
			local pos = pointed_thing.above

			-- does existing on_rightclick function exist?
			local under = minetest.get_node(pointed_thing.under)
			local def = minetest.registered_nodes[under.name]
			if def and def.on_rightclick then
				return def.on_rightclick(
						pointed_thing.under, under, placer, itemstack)
			end

			local mob = itemstack:get_name():gsub("_set$", "")
			if spawn_mob(pos, mob, itemstack:get_metadata(), placer) then
				-- since mob is unique we remove egg once spawned
				itemstack:take_item()
			end
			return itemstack
		end
	})


	-- register old stackable mob egg
	minetest.register_craftitem(mob, {
		description = desc,
		inventory_image = invimg,
		groups = grp,
		stack_max = 1,
		on_use = throw_spawn_egg,
		on_place = function(itemstack, placer, pointed_thing)
			local pos = pointed_thing.above

			-- does existing on_rightclick function exist?
			local under = minetest.get_node(pointed_thing.under)
			local def = minetest.registered_nodes[under.name]
			if def and def.on_rightclick then
				return def.on_rightclick(
					pointed_thing.under, under, placer, itemstack)
			end

			local mob = itemstack:get_name():gsub("_set$", "")
			if spawn_mob(pos, mob, itemstack:get_metadata(), placer) then
				-- if not in creative then take item and minimal protection
				-- against creating a large number of mobs on the server
				if not mobs.is_creative(placer) or not singleplayer then
					itemstack:take_item()
				end
			end
			return itemstack
		end
	})
end

--[[
-- force capture a mob if space available in inventory, or drop as spawn egg
function mobs:force_capture(self, clicker)
	-- add special mob egg with all mob information
	local new_stack = ItemStack(self.name .. "_set")
	local tmp, t = {}

	for _, stat in pairs(self) do
		t = type(stat)

		if  t ~= "function"
		and t ~= "nil"
		and t ~= "userdata" then
			tmp[_] = self[_]
		end
	end

	local data_str = minetest.serialize(tmp)
	new_stack:set_metadata(data_str)
	local inv = clicker:get_inventory()

	if inv:room_for_item("main", new_stack) then
		inv:add_item("main", new_stack)
	else
		minetest.add_item(clicker:get_pos(), new_stack)
	end

	self:mob_sound("default_place_node_hard")

	remove_mob(self, true)
end


-- capture critter (thanks to blert2112 for idea)
function mobs:capture_mob(self, clicker, chance_hand, chance_net,
		chance_lasso, force_take, replacewith)
	if self.child
			or not clicker:is_player()
			or not clicker:get_inventory() then
		return false
	end

	-- get name of clicked mob
	local mobname = self.name

	-- if not nil change what will be added to inventory
	if replacewith then
		mobname = replacewith
	end

	local name = clicker:get_player_name()
	local tool = clicker:get_wielded_item()

	-- are we using hand, net or lasso to pick up mob?
	if tool:get_name() ~= ""
			and tool:get_name() ~= "mobs:net"
			and tool:get_name() ~= "mobs:lasso" then
		return false
	end

	-- is mob tamed?
	if not self.tamed and not force_take then
		minetest.chat_send_player(name, S("Not tamed!"))
		return false
	end

	-- cannot pick up if not owner
	if self.owner ~= name and not force_take then
		minetest.chat_send_player(name, S("@1 is owner!", self.owner))
		return false
	end

	if clicker:get_inventory():room_for_item("main", mobname) then
		-- was mob clicked with hand, net, or lasso?
		local chance = 0
		if tool:get_name() == "" then
			chance = chance_hand

		elseif tool:get_name() == "mobs:net" then
			chance = chance_net
			tool:add_wear(4000) -- 17 uses
			clicker:set_wielded_item(tool)
		elseif tool:get_name() == "mobs:lasso" then
			chance = chance_lasso
			tool:add_wear(650) -- 100 uses
			clicker:set_wielded_item(tool)
		end

		-- calculate chance.. add to inventory if successful?
		if chance and chance > 0 and random(100) <= chance then
			-- default mob egg
			local new_stack = ItemStack(mobname)

			-- add special mob egg with all mob information
			-- unless 'replacewith' contains new item to use
			if not replacewith then
				new_stack = ItemStack(mobname .. "_set")
				local tmp, t = {}

				for _, stat in pairs(self) do
					t = type(stat)

					if  t ~= "function"
					and t ~= "nil"
					and t ~= "userdata" then
						tmp[_] = self[_]
					end
				end

				local data_str = minetest.serialize(tmp)
				new_stack:set_metadata(data_str)
			end

			local inv = clicker:get_inventory()

			if inv:room_for_item("main", new_stack) then
				inv:add_item("main", new_stack)
			else
				minetest.add_item(clicker:get_pos(), new_stack)
			end

			remove_mob(self, true)

			self:mob_sound("default_place_node_hard")

			return new_stack

			-- when chance above fails or set to 0, miss!
		elseif chance and chance ~= 0 then
			minetest.chat_send_player(name, S("Missed!"))
			self:mob_sound("mobs_swing")
			return false

		-- when chance is nil always return a miss (used for npc walk/follow)
		elseif not chance then
			return false
		end
	end
	return true
end
]]


local mob_obj = {}
local mob_sta = {}

-- feeding, taming and breeding (thanks blert2112)
function mobs:feed_tame(self, clicker, feed_count, breed, tame)
	local name = clicker and clicker:get_player_name() or ""

	-- can eat/tame with item in hand
	if self.follow and self:follow_holding(clicker) then
		-- if not in creative then take item
		if not mobs.is_creative(name) then
			local item = clicker:get_wielded_item()
			item:take_item()
			clicker:set_wielded_item(item)
		end

		-- increase health
		self.health = self.health + 4

		if self.health >= self.hp_max then
			self.health = self.hp_max

			if self.htimer < 1 then
				minetest.chat_send_player(name,
					S("\"@1\" at full health: @2",
						self.description, tostring(self.health)))
				self.htimer = 5
			end
		end

		self.object:set_hp(self.health)

		self:update_tag()

		-- make children grow quicker
		if self.child then
--			self.hornytimer = self.hornytimer + 20
			-- deduct 10% of the time to adulthood
			self.hornytimer = self.hornytimer + (
					(CHILD_GROW_TIME - self.hornytimer) * 0.1)
			return true
		end

		-- feed and tame
		self.food = (self.food or 0) + 1

		if self.food >= feed_count then
			self.food = 0

			if breed and self.hornytimer == 0 then
				self.horny = true
			end

			if tame then
				if self.tamed == false then
					minetest.chat_send_player(name,
						S("\"@1\" has been tamed!", self.description))
					self:mob_sound("mobs_spell")
				end

				self.tamed = true
				if not self.owner or self.owner == "" then
					self.owner = name

					local infotext = S("Owned by @1", S(name))
					self.infotext = infotext
					self.object:set_properties({
						infotext = infotext
					})
				end
			end

			-- make sound when fed so many times
			self:mob_sound(self.sounds.random)
		end
		return true
	end

	local item = clicker:get_wielded_item()

	-- if mob has been tamed you can name it with a nametag
	if item:get_name() == "mobs:nametag"
			and (name == self.owner
			or minetest.check_player_privs(name, {server = true})) then
		-- store mob and nametag stack in external variables
		mob_obj[name] = self
		mob_sta[name] = item
		local tag = self.nametag or ""
		local esc = minetest.formspec_escape

		minetest.show_formspec(name, "mobs_nametag",
				"size[5,3]" ..
				"background[0,0;0,0;formspec_background_color.png^formspec_backround.png;true]" ..
				"field[1.35,1.25;2.9,1;name;" ..
				esc(S("Enter name:")) ..
				";" .. esc(tag) .. "]" ..
				"button_exit[1.06,1.65;2.9,1;mob_rename;" ..
				esc(S("Rename")) .. "]")

		return true
	end

	return false
end


-- inspired by blockmen's nametag mod
minetest.register_on_player_receive_fields(function(player, formname, fields)
	-- right-clicked with nametag and name entered?
	if formname == "mobs_nametag"
			and fields.name
			and fields.name ~= "" then
		local name = player:get_player_name()

		if not mob_obj[name]
		or not mob_obj[name].object then
			return
		end

		-- make sure nametag is being used to name mob
		local item = player:get_wielded_item()

		if item:get_name() ~= "mobs:nametag" then
			return
		end

		if fields.name == "{remove_owner}" then
			mob_obj[name].nametag = nil
			mob_obj[name]:update_tag()

			mob_obj[name].infotext = ""
			mob_obj[name].object:set_properties({
				infotext = ""
			})

			mob_obj[name].owner = nil
			mob_obj[name].tamed = false
		else
			-- limit name entered to 48 characters long
			fields.name = fields.name:sub(1, 48)

			-- update nametag
			mob_obj[name].nametag = fields.name
			mob_obj[name]:update_tag()

			-- if not in creative then take item
			if not mobs.is_creative(name) then
				mob_sta[name]:take_item()
				player:set_wielded_item(mob_sta[name])
			end
		end

		-- reset external variables
		mob_obj[name] = nil
		mob_sta[name] = nil
	end
end)


function mobs:alias_mob(old_name, new_name)
	-- check old_name entity doesnt already exist
	if minetest.registered_entities[old_name] then
		return
	end

	-- entity
	minetest.register_entity(":" .. old_name, {
		physical = false,

		on_activate = function(self, staticdata)
			if minetest.registered_entities[new_name] then
				minetest.add_entity(self.object:get_pos(), new_name, staticdata)
			end

			remove_mob(self)
		end,

		get_staticdata = function(self)
			return self
		end
	})
end
