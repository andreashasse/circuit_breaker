* circuit_breaker

This is a simple circuit breaker.
Pros: Doesn't copy the payload to the circuit breaker process.
Cons: Not well tested, might have perfomance bottlenecks.

Start one circuir_breaker per thing you want to protect. You are responsible for supervising the circuit breaker yourself.

** Options when starting

allowed_errors: Number of consecutive failures before the circuit breaker opens.
try_timeout: How long the circuit breaker should be open before switching to half open.

** Example

%% Registering the process locally as cbtest
{ok, _} = circuit_breaker:start_link({local, cbtest}, []),
%% Doing a call
circuit_breaker:call(cbtest, fun() -> io:format("wow") end),
%% Manually switch the state of the circuit breaker to open 
%% (this is not normal operations, but is handy when your system is acting up).
circuit_breaker:switch_state(cbtest, open),
circuit_breaker:call(cbtest, fun() -> io:format("you should not see this") end),
