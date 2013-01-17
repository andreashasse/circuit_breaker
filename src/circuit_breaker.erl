%%% @doc
%%%
%%% @end
-module(circuit_breaker).

-behaviour(gen_fsm).

%% API
-export([start_link/2, call/2, stop/1, state/1, switch_state/2]).

%% gen_fsm callbacks
-export([init/1,
         closed/3, half_open/3, open/3,
         handle_event/3, handle_sync_event/4,
         handle_info/3, terminate/3, code_change/4]).


%% callbacks.
-ignore_xref([call/2, closed/3, half_open/3, open/3,
              start_link/2, state/1, stop/1]).

-record(state, {config = [] :: [{atom(), term()}],
                errors = 0 :: non_neg_integer()
               }).

%%%===================================================================
%%% API
%%%===================================================================

call(Name, Work) ->
    case gen_fsm:sync_send_event(Name, call) of
        ok -> do_work(Name, Work);
        {circuit_breaker, Error} -> {circuit_breaker, Error}
    end.

start_link(Name, Opts) ->
    gen_fsm:start_link(Name, ?MODULE, [Opts], []).

stop(Name) ->
    gen_fsm:sync_send_all_state_event(Name, stop).

switch_state(Name, NewStateName) ->
    gen_fsm:sync_send_all_state_event(Name, {switch_state, NewStateName}).

%% for debug purposes.
state(Name) ->
    gen_fsm:sync_send_all_state_event(Name, state).

%%%===================================================================
%%% gen_fsm callbacks
%%%===================================================================

init([Opts]) ->
    State = #state{config = config(Opts)},
    StartState = get_opt(Opts, start_state, closed),
    maybe_send_half_open(StartState, State),
    {ok, StartState, State}.

closed(call, _From, State) ->
    {reply, ok, closed, State}.

half_open(call, _From, State) ->
    {reply, ok, closed, State}.

open(call, _From, State) ->
    {reply, {circuit_breaker, service_down}, open, State}.

handle_event(Event, StateName, StateData) ->
    error_logger:error_msg("Got not recognized event ~p ~p ~p",
                           [Event, StateName, StateData]),
    {next_state, StateName, StateData}.

handle_sync_event({switch_state, NewStateName}, _From, StateName, StateData) ->
    log(StateName, NewStateName),
    maybe_send_half_open(NewStateName, StateData),
    {reply, ok, NewStateName, StateData};
handle_sync_event(stop, _From, StateName, StateData) ->
    log(StateName, stop),
    {stop, normal, ok, StateData};
handle_sync_event(state, _From, StateName, StateData) ->
    {reply,{StateName, StateData},StateName,StateData};
handle_sync_event(Event, _From, StateName, StateData) ->
    error_logger:error_msg("Got not recognized event ~p ~p ~p",
                           [Event, StateName, StateData]),
    %% next_state on handle_sync_event/4?
    {next_state, StateName, StateData}.

handle_info({call_result, Result}, StateName, State) ->
    {NewStateName, NewState} = handle_call_result(Result, StateName, State),
    log(StateName, NewStateName),
    {next_state, NewStateName, NewState};
handle_info(try_half_open, open, State) ->
    log(open, half_open),
    {next_state, half_open, State};
handle_info(try_half_open, StateName, State) ->
    {next_state, StateName, State}.

terminate(_Reason, _StateName, _State) ->
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

handle_call_result({error, _Reason}, _StateName, State0) ->
    handle_error_result(State0);
handle_call_result({'EXIT', _Result}, _StateName, State0) ->
    handle_error_result(State0);
handle_call_result(_Result, closed, State) -> {closed, clr_error(State)};
handle_call_result(_Result, open, State) -> {closed, clr_error(State)};
handle_call_result(_Result, half_open, State) -> {closed, clr_error(State)}.

handle_error_result(State0) ->
    State = inc_error(State0),
    case conf(allowed_errors, State) of
        Error when Error < State#state.errors ->
            maybe_send_half_open(open, State),
            {open, State};
        _ ->
            {closed, State}
    end.

maybe_send_half_open(open, State) ->
    case conf(try_timeout, State) of
        false   -> ok;
        Timeout -> timer:send_after(Timeout, try_half_open)
    end;
maybe_send_half_open(_MS, _State) -> ok.

log(State, State) -> ok;
log(Old, New) ->
    switch_alarm(New),
    error_logger:error_msg(
      "Circuit breaker ~p whiching from ~p to ~p",
      [name(), Old, New]),
    ok.

%% ---------------------------------------------------------------------------
%% ALARM HANDLING

switch_alarm(closed) ->
    alarm_handler:clear_alarm(alarm_id(name()));
switch_alarm(open) ->
    Name = name(),
    Id = alarm_id(Name),
    case lists:keyfind(Id, 1, alarm_handler:get_alarms()) of
        {Id, _} -> ok; %% already set
        false -> alarm_handler:set_alarm({Id, alarm_desc(Name)})
    end;
switch_alarm(_) ->
    ok.

alarm_id(Name) ->
    {circuit_breaker, Name}.

alarm_desc(Name) ->
    list_to_binary(io_lib:format("Circuit breaker ~p open", [Name])).

name() ->
    case lists:keyfind(registered_name, 1, process_info(self())) of
        {registered_name, Name} -> Name;
        false -> self()
    end.

clr_error(State) -> State#state{errors = 0}.

inc_error(State) -> State#state{errors = State#state.errors + 1}.

do_work(Name, Work) ->
    Result = (catch do_work(Work)),
    Name ! {call_result, Result},
    Result.

do_work({M,F,A}) -> erlang:apply(M, F, A);
do_work(F) -> F().


%%%-------------------------------------------------------------------
%%% Config

config(Conf) ->
    lists:map(
      fun({Key, Default}) -> {Key, get_opt(Conf, Key, Default)} end,
      default_configs()).

get_opt(Conf, Key, Default) ->
    case lists:keyfind(Key, 1, Conf) of
        {Key, Val} -> Val;
        false -> Default
    end.

default_configs() ->
    [{try_timeout, 5000},
     {allowed_errors, 0}].

conf(Key, #state{config = Conf}) ->
    {Key, Val} = lists:keyfind(Key, 1, Conf),
    Val.

%%%===================================================================
%%% Tests
%%%===================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

test_ok_call() ->
    circuit_breaker:call(tester, {math, log, [1]}).

test_crash_call() ->
    circuit_breaker:call(tester, {math, log, [0]}).

try_timeout_test_() ->
    Tester =
        fun() ->
                ?assertEqual(300, conf(try_timeout, element(2, state(tester)))),
                ?assertEqual(0.0, test_ok_call()),
                ?assertMatch({'EXIT', _}, test_crash_call()),
                ?assertMatch({circuit_breaker, service_down}, test_crash_call()),
                ?assertEqual({circuit_breaker, service_down}, test_ok_call()),
                timer:sleep(300),
                ?assertEqual(0.0, test_ok_call())
        end,
    {setup, setup([{try_timeout, 300}]), fun cleanup/1,
     [?_test(Tester())]
    }.

two_error_test_() ->
    Tester =
        fun() ->
                ?assertEqual(1, conf(allowed_errors, element(2, state(tester)))),
                ?assertEqual(0.0, test_ok_call()),
                ?assertMatch({'EXIT', _}, test_crash_call()),
                ?assertMatch({'EXIT', _}, test_crash_call()),
                ?assertEqual({circuit_breaker, service_down}, test_ok_call())
        end,
    {setup, setup([{allowed_errors, 1}]), fun cleanup/1,
     [?_test(Tester())]
    }.

not_two_error_test_() ->
    Tester =
        fun() ->
                ?assertEqual(0.0, test_ok_call()),
                ?assertMatch({'EXIT', _}, test_crash_call()),
                ?assertEqual(0.0, test_ok_call()),
                ?assertMatch({'EXIT', _}, test_crash_call()),
                ?assertEqual(0.0, test_ok_call())
        end,
    {setup, setup([{allowed_errors, 1}]), fun cleanup/1,
     [?_test(Tester())]
    }.

setup(Conf) ->
    fun() ->
            {ok, _} = circuit_breaker:start_link({local, tester}, Conf),
            []
    end.

cleanup(_Conf) ->
    ok = circuit_breaker:stop(tester).

-endif.
