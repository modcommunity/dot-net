@tool
class_name DotNetInterestAll
extends DotNetInterest

## Replicates everything to everyone.
##
## The right choice more often than it looks: a co-op game with eight players and
## thirty entities has nothing to gain from filtering, and interest management that
## does no filtering still costs a query per observer per snapshot.
##
## The wrong choice for anything competitive, because a client that receives every
## position can draw every position. See [DotNetInterest].

func _init() -> void:
	strategy_name = "all"
	# Nothing to cache — the answer is always the same, and re-deriving it is free.
	evaluation_interval_sec = 0.0


func _is_relevant(
	_observer: DotNetIdentity,
	_entity: DotNetIdentity,
	_context: Dictionary
) -> bool:
	return true
