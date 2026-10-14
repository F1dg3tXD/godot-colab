@tool
## Simple token-bucket rate limiter used to throttle untrusted message types
## (cursor updates, scene operations, transfers) and rendezvous lookups.
class_name CollabRateLimiter
extends RefCounted

var _capacity: float = 1.0
var _refill_per_second: float = 1.0
var _tokens: float = 1.0
var _last_refill_ms: int = 0
var _strikes: int = 0


func _init(capacity: float = 30.0, refill_per_second: float = 30.0) -> void:
	_capacity = maxf(1.0, capacity)
	_refill_per_second = maxf(0.001, refill_per_second)
	_tokens = _capacity
	_last_refill_ms = Time.get_ticks_msec()


func _refill() -> void:
	var now: int = Time.get_ticks_msec()
	var elapsed: float = float(now - _last_refill_ms) / 1000.0
	if elapsed <= 0.0:
		return
	_last_refill_ms = now
	_tokens = minf(_capacity, _tokens + elapsed * _refill_per_second)


## Consumes [param cost] tokens. Returns true when allowed.
func try_consume(cost: float = 1.0) -> bool:
	_refill()
	if _tokens >= cost:
		_tokens -= cost
		return true
	_strikes += 1
	return false


## Number of consecutive rejected attempts since the last success.
func strikes() -> int:
	return _strikes


func reset() -> void:
	_tokens = _capacity
	_strikes = 0
	_last_refill_ms = Time.get_ticks_msec()


## Convenience factory for "N messages per second, burst of N".
static func per_second(rate: float, burst: float = -1.0) -> CollabRateLimiter:
	var b: float = rate if burst < 0.0 else burst
	return CollabRateLimiter.new(b, rate)
