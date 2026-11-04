--!strict
--[[
	Synthetic players for balance sims (brief §9.2): skill profiles, session patterns, a
	deterministic daily schedule, play-time accounting, and milestone tracking.

	Defaults follow the brief: skill mix casual 40% / average 40% / grinder 20%, sessions of
	3, 12 or 40 minutes. Games override any of it through Options.

	  local players = Population.generate(rng, 500)
	  Population.play(players, { days = 14 }, function(player, session)
	      -- simulate `session.duration` seconds of play for `player`
	      -- (player.state is yours; call Population.mark(player, "firstWin", session, t))
	  end)
	  local report = Population.milestoneReport(players, { "firstWin", "world2" })

	Time terms:
	  playSeconds  cumulative seconds the player has been in-game (what "time to X" means)
	  day          1-based simulated day
	  dayMinute    play minutes accumulated within that day when the milestone happened
]]

local Rng = require("./Rng")
local Stats = require("./Stats")

export type SkillProfile = {
	name: string,
	weight: number,
	-- 0..1, how well this player executes; games map it to fail rates, par times etc.
	skill: number,
	-- Session pattern mix for this profile: { [patternName]: weight }.
	sessions: { [string]: number },
	-- Expected sessions per day (fractional part becomes a chance of one more).
	sessionsPerDay: number,
	-- Chance the player plays at all on a given day after day 1.
	returnChance: number,
}

export type SessionPattern = {
	name: string,
	minutes: number,
	-- Uniform ± fraction applied to each session length.
	jitter: number,
}

export type Options = {
	profiles: { SkillProfile }?,
	patterns: { SessionPattern }?,
	-- Standard deviation of per-player skill around the profile's skill. Default 0.05.
	skillSpread: number?,
	-- Waking window for session start times, seconds from midnight. Default 08:00..23:00.
	dayStart: number?,
	dayEnd: number?,
}

export type Milestone = {
	playSeconds: number,
	day: number,
	dayMinute: number,
	session: number,
}

export type SimPlayer = {
	id: number,
	profile: string,
	skill: number,
	pattern: string,
	sessionMinutes: number,
	sessionsPerDay: number,
	returnChance: number,
	rng: Rng.Rng,
	playSeconds: number,
	sessionsPlayed: number,
	daysPlayed: number,
	milestones: { [string]: Milestone },
	-- Free for the game model.
	state: { [string]: any },
}

export type Session = {
	day: number,
	index: number,
	-- Seconds after midnight of `day` the session starts.
	start: number,
	-- Absolute seconds since the sim began (day 1, 00:00).
	absoluteStart: number,
	duration: number,
	-- Player's playSeconds when the session began.
	playStart: number,
	-- Play seconds already used today before this session.
	dayPlayStart: number,
}

export type PlayOptions = {
	days: number,
	-- Called once per player per day before their sessions (daily login rewards, offline income).
	onDayStart: ((player: SimPlayer, day: number) -> ())?,
}

local Population = {}

Population.DEFAULT_PROFILES = {
	{
		name = "casual",
		weight = 0.4,
		skill = 0.35,
		sessions = { short = 0.5, medium = 0.4, long = 0.1 },
		sessionsPerDay = 1.5,
		returnChance = 0.7,
	},
	{
		name = "average",
		weight = 0.4,
		skill = 0.6,
		sessions = { short = 0.3, medium = 0.5, long = 0.2 },
		sessionsPerDay = 2,
		returnChance = 0.85,
	},
	{
		name = "grinder",
		weight = 0.2,
		skill = 0.85,
		sessions = { short = 0.1, medium = 0.4, long = 0.5 },
		sessionsPerDay = 3,
		returnChance = 0.97,
	},
} :: { SkillProfile }

Population.DEFAULT_PATTERNS = {
	{ name = "short", minutes = 3, jitter = 0.25 },
	{ name = "medium", minutes = 12, jitter = 0.25 },
	{ name = "long", minutes = 40, jitter = 0.25 },
} :: { SessionPattern }

local DAY = 86400

-- Splits `count` into integer quotas proportional to weights (largest remainder method), so a
-- 500-player population has exactly 200/200/100 rather than a noisy random split.
function Population.quotas(weights: { number }, count: number): { number }
	local total = 0
	for _, w in weights do
		total += w
	end
	assert(total > 0, "quotas need a positive total weight")
	local result = {}
	local remainders = {}
	local assigned = 0
	for i, w in weights do
		local exact = count * w / total
		result[i] = math.floor(exact)
		assigned += result[i]
		table.insert(remainders, { index = i, frac = exact - result[i] })
	end
	table.sort(remainders, function(a, b)
		if a.frac == b.frac then
			return a.index < b.index
		end
		return a.frac > b.frac
	end)
	for i = 1, count - assigned do
		local r = remainders[i]
		result[r.index] += 1
	end
	return result
end

function Population.generate(rng: Rng.Rng, count: number, options: Options?): { SimPlayer }
	local opts: Options = options or {}
	local profiles = opts.profiles or Population.DEFAULT_PROFILES
	local patterns = opts.patterns or Population.DEFAULT_PATTERNS
	local spread = opts.skillSpread or 0.05

	local patternByName: { [string]: SessionPattern } = {}
	for _, pattern in patterns do
		patternByName[pattern.name] = pattern
	end

	local weights = {}
	for i, profile in profiles do
		weights[i] = profile.weight
	end
	local quotas = Population.quotas(weights, count)

	local assignment: { SkillProfile } = {}
	for i, profile in profiles do
		for _ = 1, quotas[i] do
			table.insert(assignment, profile)
		end
	end
	rng:fork("population-order"):shuffle(assignment)

	local players: { SimPlayer } = {}
	for id, profile in assignment do
		local playerRng = rng:fork("player-" .. id)
		local setupRng = playerRng:fork("setup")
		local patternName = setupRng:weighted(profile.sessions)
		local pattern = patternByName[patternName]
		assert(pattern, "unknown session pattern " .. tostring(patternName))
		table.insert(players, {
			id = id,
			profile = profile.name,
			skill = math.clamp(setupRng:normal(profile.skill, spread), 0.02, 0.99),
			pattern = pattern.name,
			sessionMinutes = pattern.minutes,
			sessionsPerDay = profile.sessionsPerDay,
			returnChance = profile.returnChance,
			rng = playerRng:fork("play"),
			playSeconds = 0,
			sessionsPlayed = 0,
			daysPlayed = 0,
			milestones = {},
			state = {},
		})
	end
	return players
end

-- The deterministic list of sessions a player plays on `day` (1-based). Depends only on the
-- player's seed and the day, never on what happened in earlier sessions.
function Population.sessionsForDay(player: SimPlayer, day: number, options: Options?): { Session }
	local opts: Options = options or {}
	local patterns = opts.patterns or Population.DEFAULT_PATTERNS
	local dayStart = opts.dayStart or 8 * 3600
	local dayEnd = opts.dayEnd or 23 * 3600
	local rng = player.rng:fork("day-" .. day)

	if day > 1 and not rng:chance(player.returnChance) then
		return {}
	end

	local jitter = 0.25
	for _, pattern in patterns do
		if pattern.name == player.pattern then
			jitter = pattern.jitter
		end
	end

	local count = math.floor(player.sessionsPerDay)
	if rng:chance(player.sessionsPerDay - count) then
		count += 1
	end
	if day == 1 then
		count = math.max(count, 1) -- every synthetic player installs and plays on day 1
	end

	local sessions: { Session } = {}
	local starts: { number } = {}
	for _ = 1, count do
		table.insert(starts, rng:range(dayStart, dayEnd))
	end
	table.sort(starts)
	local cursor = 0
	for index, start in starts do
		local duration = math.max(30, rng:jitter(player.sessionMinutes * 60, jitter))
		local begin = math.max(start, cursor)
		cursor = begin + duration + 60
		table.insert(sessions, {
			day = day,
			index = index,
			start = begin,
			absoluteStart = (day - 1) * DAY + begin,
			duration = duration,
			playStart = 0,
			dayPlayStart = 0,
		})
	end
	return sessions
end

-- Plays every player through `days` days. `onSession` simulates one session; play-time
-- counters are updated after it returns. Players are processed one at a time (no shared
-- server state); for shared-server effects use a Scheduler inside onSession or model them
-- as rates.
function Population.play(
	players: { SimPlayer },
	options: PlayOptions,
	onSession: (player: SimPlayer, session: Session) -> (),
	populationOptions: Options?
)
	for _, player in players do
		for day = 1, options.days do
			local sessions = Population.sessionsForDay(player, day, populationOptions)
			if #sessions > 0 then
				player.daysPlayed += 1
				if options.onDayStart then
					options.onDayStart(player, day)
				end
			end
			local dayPlay = 0
			for _, session in sessions do
				session.playStart = player.playSeconds
				session.dayPlayStart = dayPlay
				onSession(player, session)
				player.playSeconds += session.duration
				player.sessionsPlayed += 1
				dayPlay += session.duration
			end
		end
	end
end

-- Records the first time a player reaches a milestone. `elapsed` is seconds into the session.
function Population.mark(player: SimPlayer, name: string, session: Session, elapsed: number): boolean
	if player.milestones[name] then
		return false
	end
	local within = math.clamp(elapsed, 0, session.duration)
	player.milestones[name] = {
		playSeconds = session.playStart + within,
		day = session.day,
		dayMinute = (session.dayPlayStart + within) / 60,
		session = player.sessionsPlayed + 1,
	}
	return true
end

export type MilestoneRow = {
	milestone: string,
	profile: string,
	reached: number,
	total: number,
	share: number,
	playMinutes: Stats.Summary?,
	day: Stats.Summary?,
}

-- Per milestone and profile ("all" included): how many reached it and when.
function Population.milestoneReport(players: { SimPlayer }, milestones: { string }): { MilestoneRow }
	local profiles: { string } = { "all" }
	local seen: { [string]: boolean } = {}
	for _, player in players do
		if not seen[player.profile] then
			seen[player.profile] = true
			table.insert(profiles, player.profile)
		end
	end
	table.sort(profiles, function(a, b)
		if a == "all" then
			return b ~= "all"
		elseif b == "all" then
			return false
		end
		return a < b
	end)

	local rows: { MilestoneRow } = {}
	for _, milestone in milestones do
		for _, profile in profiles do
			local minutes: { number } = {}
			local days: { number } = {}
			local total = 0
			for _, player in players do
				if profile == "all" or player.profile == profile then
					total += 1
					local m = player.milestones[milestone]
					if m then
						table.insert(minutes, m.playSeconds / 60)
						table.insert(days, m.day)
					end
				end
			end
			table.insert(rows, {
				milestone = milestone,
				profile = profile,
				reached = #minutes,
				total = total,
				share = if total > 0 then #minutes / total else 0,
				playMinutes = if #minutes > 0 then Stats.summarize(minutes) else nil,
				day = if #days > 0 then Stats.summarize(days) else nil,
			})
		end
	end
	return rows
end

return Population
