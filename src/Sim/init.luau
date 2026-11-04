--!strict
--[[
	Sim: harness for balance and gameplay simulations (brief §9.2, §9.3).

	  Sim.Rng         deterministic random streams (xoshiro128**), fork per player/day
	  Sim.Scheduler   discrete-event loop (at/after/every) + fixedStep for kinematic loops
	  Sim.Population  synthetic players: skill mix, session patterns, play time, milestones
	  Sim.Recorder    rows + metrics, CSV and JSON output
	  Sim.Stats       mean/percentiles/summaries/histograms/shares
	  Sim.Targets     pass/fail targets with a report
	  Sim.Tune        bounded parameter search for the auto-fix loop
	  Sim.Runner      define/run sims; lune, Studio and Open Cloud entry points
	  Sim.Json        deterministic JSON encoder

	Everything here is pure Luau: no services, no real time, no math.random.
]]

local Json = require("@self/Json")
local Population = require("@self/Population")
local Recorder = require("@self/Recorder")
local Rng = require("@self/Rng")
local Runner = require("@self/Runner")
local Scheduler = require("@self/Scheduler")
local Stats = require("@self/Stats")
local Targets = require("@self/Targets")
local Tune = require("@self/Tune")

export type Rng = Rng.Rng
export type Scheduler = Scheduler.Scheduler
export type SimPlayer = Population.SimPlayer
export type Session = Population.Session
export type Recorder = Recorder.Recorder
export type Targets = Targets.Targets
export type Context = Runner.Context
export type Definition = Runner.Definition
export type Result = Runner.Result
export type Summary = Stats.Summary

return {
	Json = Json,
	Population = Population,
	Recorder = Recorder,
	Rng = Rng,
	Runner = Runner,
	Scheduler = Scheduler,
	Stats = Stats,
	Targets = Targets,
	Tune = Tune,
}
