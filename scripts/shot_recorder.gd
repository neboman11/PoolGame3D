class_name ShotRecorder
extends RefCounted

## Records solver-observable shots for deterministic regression and debugging.
## It is intentionally in-memory; callers choose if/where a replay is persisted.

var active_record: Dictionary = {}
var last_record: Dictionary = {}

func begin(initial_snapshot: Dictionary, strike: Dictionary) -> void:
	active_record = {
		"initial": initial_snapshot.duplicate(true),
		"strike": strike.duplicate(true),
		"events": [],
	}

func record_event(kind: String, payload: Dictionary) -> void:
	if active_record.is_empty():
		return
	var events: Array = active_record["events"].duplicate(true)
	events.append({"kind": kind, "payload": payload.duplicate(true)})
	active_record["events"] = events

func complete(final_snapshot: Dictionary, result: Dictionary) -> Dictionary:
	if active_record.is_empty():
		return {}
	var completed := active_record.duplicate(true)
	completed["final"] = final_snapshot.duplicate(true)
	completed["result"] = result.duplicate(true)
	last_record = completed.duplicate(true)
	active_record = {}
	return completed.duplicate(true)

func cancel() -> void:
	active_record = {}

func to_json(record: Dictionary = last_record) -> String:
	return JSON.stringify(record)
