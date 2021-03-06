%%% $Id: tcap_cco_server.erl,v 1.3 2005/08/04 09:33:17 vances Exp $
%%%---------------------------------------------------------------------
%%% @copyright 2010-2011 Harald Welte
%%% @author Harald Welte <laforge@gnumonks.org>
%%% @end
%%%
%%% Copyright (c) 2010-2011, Harald Welte
%%% 
%%% All rights reserved.
%%% 
%%% Redistribution and use in source and binary forms, with or without
%%% modification, are permitted provided that the following conditions
%%% are met:
%%% 
%%%    - Redistributions of source code must retain the above copyright
%%%      notice, this list of conditions and the following disclaimer.
%%%    - Redistributions in binary form must reproduce the above copyright
%%%      notice, this list of conditions and the following disclaimer in
%%%      the documentation and/or other materials provided with the 
%%%      distribution.
%%%    - Neither the name of Motivity Telecom nor the names of its
%%%      contributors may be used to endorse or promote products derived
%%%      from this software without specific prior written permission.
%%%
%%% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
%%% "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
%%% LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
%%% A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
%%% OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
%%% SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
%%% LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
%%% DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
%%% THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT 
%%% (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
%%% OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
%%%
%%%---------------------------------------------------------------------
%%%
%%% @doc TCAP Component Coordinator (CCO) functional block within the
%%% 		component sub-layer of ITU TCAP.
%%%
%%% @reference ITU-T Q.774 (06/97) Annex A Transaction capabilities SDLs
%%%
%%% @private
%%%

-module(tcap_cco_server).
-copyright('Copyright (c) 2010-2011 Harald Welte').
-author('laforge@gnumonks.org').
-vsn('$Revision: 1.3 $').

-behaviour(gen_server).

%% call backs needed for gen_server behaviour
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	terminate/2, code_change/3]).

-include("tcap.hrl").
-include("TR.hrl").
-include("TC.hrl").

-record(state, {supervisor, usap, dialogueID, components, dha, ism}).

-record(component, {asn_ber, user_prim}).

%%----------------------------------------------------------------------
%%  The gen_server call backs
%%----------------------------------------------------------------------

%% initialize the server
init([Supervisor, USAP, DialogueID]) ->
	process_flag(trap_exit, true),
	DHA = list_to_atom("tcap_dha_" ++ integer_to_list(DialogueID)),
	{ok, #state{supervisor = Supervisor, usap = USAP, dha = DHA,
		    dialogueID = DialogueID, components = [], ism = []}}.

%% set the DHA pid
handle_call(set_dha, From, State) ->
	{noreply, State#state{dha = From}};

%% shutdown the server
handle_call(stop, _From, State) ->
	{stop, shutdown, ok, State};

%% unrecognized calls
handle_call(Other, From, State) ->
	error_logger:error_report([{unknown_call, Other}, {from, From}]),
	{noreply, State}.

% from TCU: TC-INVOKE.req
handle_cast({'TC','INVOKE',request, InvParam}, State)
			when is_record(InvParam, 'TC-INVOKE') ->
	% assemble INVOKE component
	AsnRosRec = uprim_to_asn_rec(InvParam),
	Component = #component{user_prim = InvParam, asn_ber = AsnRosRec},
	% mark it as available
	NewState = add_components_to_state(State, Component),
	% what to do with class and timeout?
	{noreply, NewState};

% from TCU: TC-U-CANCEL.req
handle_cast({'TC','U-CANCEL',request, Param}, State)
			when is_record(Param, 'TC-U-CANCEL') ->
	InvokeId = Param#'TC-U-CANCEL'.invokeID,
	OldComps = State#state.components,
	% if there are any INV componnents waiting, discard them
	NewComps = discard_inv_component(OldComps, InvokeId),
	case NewComps of
	    OldComps ->
		% if not, check any active ISM, if yes, terminate ISM
		NewISMs = terminate_active_ISM(State#state.ism,
						InvokeId),
		NewState = State#state{ism = NewISMs};
	    _ ->
		NewState = State#state{components = NewComps}
	end,
	{noreply, NewState};

% from DHA -> CCO: dialogue-terminated
handle_cast('dialogue-terminated', State) ->
	% discard components awaiting transmission
	%	* automatically released
	% if any ISM active, terminate ISM
	%	* ISMs are linked, they should terminate
	terminate_ISMs(State#state.ism),
	% terminate
	{stop, normal, State};

% from TCL -> CHA (CCO): TC-RESULT-{L,NL}, U-ERROR
handle_cast({'TC', Req, request, Param}, State) when 
				Req == 'RESULT-L';
				Req == 'RESULT-NL';
				Req == 'U-ERROR' ->
	% Figure A.6/Q.774 (1 of 4)
	% assemble requested component
	AsnRosRec = uprim_to_asn_rec(Param),
	Component = #component{user_prim = Param, asn_ber = AsnRosRec}, %FIXME
	% mark component available for this dialogue
	NewState = add_components_to_state(State, Component),
	{noreply, NewState};

% TCL->CHA: TC-U-REJECT.req
handle_cast({'TC','U-REJECT',request, Param}, State)
			when is_record(Param, 'TC-U-REJECT') ->
	% assemble reject component
	AsnRosRec = uprim_to_asn_rec(Param),
	Component = #component{user_prim = Param, asn_ber = AsnRosRec}, %FIXME
	% FIXME: if probelm type Result/Error, terminate ISM
	% mark component available for this dialogue
	NewState = add_components_to_state(State, Component),
	{noreply, NewState};

% DHA -> CHA (CCO): Components received
handle_cast({components, Components}, State) ->
	% Figure A.6/Q.774 (2 of 4)
	process_rx_components(State#state.ism, State#state.usap,
			      State#state.dialogueID, Components),
	{noreply, State};

% ISM -> CCO: Generate REJ component
handle_cast({reject_component, Reject}, State) ->
	Component = #component{user_prim = Reject, asn_ber = 0}, %FIXME
	NewState = add_components_to_state(State, Component),
	{noreply, NewState};

% DHA -> CHA (CCO)
handle_cast('request-components', State = #state{components=CompIn}) ->
	% Figure A.6/Q.774 (4 of 4)
	case CompIn of
	    [] ->
		% if no components, signal 'no-components' to DHA
		gen_fsm:send_event(State#state.dha, 'no-component'),
		NewState = State;
	    _ ->
		% for each component
		{CompOut, ISMs} = process_request_components(CompIn, State),
		% signal 'requested-components' to DHA
		gen_fsm:send_event(State#state.dha,
				   {'requested-components', CompOut}),
		NewState = State#state{ism = State#state.ism ++ ISMs,
					components = []}
	end,
	{noreply, NewState};

%% unrecognized casts
handle_cast(Other, State) ->
	error_logger:error_report([{unknown_cast, Other}]),
	{noreply, State}.


%% trapped exit signals
handle_info({'EXIT', _Pid, Reason}, State) ->
	{stop, Reason, State};

%% unknown messages
handle_info(Unknown, State) ->
	error_logger:error_msg("Received unknown message: ~p~n", [Unknown]),
	{noreply, State}.

%% someone wants us to shutdown and cleanup
terminate(_Reason, _State) -> ok.

%% upgrading the running code
code_change(_, _, _) -> ok.

%%%
%%% internal functions
%%%

% convert invoke ID from user-input format to what ASN1RT expects
inv_id_to_asn_rec(undefined) ->
	asn1_NOVALUE;
inv_id_to_asn_rec(Int) when is_integer(Int) ->
	{present, Int}.

inv_id_to_uprim({present, Inv}) ->
	Inv;
inv_id_to_uprim(undefined) ->
	undefined;
inv_id_to_uprim(asn1_NOVALUE) ->
	undefined.

% Figure A.6/Q.774 (4 of 4)
process_request_components(Components, State) when 
			is_list(Components), is_record(State, state) ->
	process_request_components(Components, State, [], []).
process_request_components([], _State, AsnComps, ISMs) ->
	{lists:reverse(AsnComps), ISMs};
process_request_components([Head|Tail], State, AsnComps, ISMs) when
				is_record(Head, component),
			        is_record(State, state)	->
	#component{asn_ber = Asn, user_prim = Uprim} = Head,
	#state{usap = Usap, dialogueID = DialogueId} = State,
	case Uprim of
	    #'TC-INVOKE'{class = Class, timeout = Tout,
	    		 invokeID = InvId} ->
		% if INVOKE component
		% start ISM and store ISM
		{ok, ISM} = tcap_invocation_sup:start_ism(Usap, DialogueId,
							  InvId, self(), Class, Tout),
		% signal 'operation-sent' to ISM
		gen_fsm:send_event(ISM, 'operation-sent'),
		NewISMs = [{InvId, ISM}|ISMs];
	    _ ->
		NewISMs = ISMs
	end,
	process_request_components(Tail, State, [Asn|AsnComps], NewISMs).

% discard components of type INVOKE for matching InvokeID
discard_inv_component(Components, InvId) when is_list(Components) ->
	discard_inv_component(Components, InvId, []).
discard_inv_component([], _InvId, CompOut) ->
	lists:reverse(CompOut);
discard_inv_component([Head|Tail], InvId, CompAcc) ->
	#component{user_prim = Uprim} = Head,
	case Uprim of
	    #'TC-INVOKE'{invokeID = InvId} ->
		CompOut = CompAcc;
	    _ ->
		CompOut = [Head|CompAcc]
	end,
	discard_inv_component(Tail, InvId, CompOut).

% iterate over list of ISMs, terminate the one with matching InvId
terminate_active_ISM(ISMs, InvId) ->
	case lists:keyfind(InvId, 1, ISMs) of
	    {InvId, ISM} ->
		gen_fsm:send_event(ISM, terminate),
		lists:keydelete(InvId, 1, ISMs);
	    false ->
		ISMs
	end.

terminate_ISMs([]) ->
	ok;
terminate_ISMs([{_Id, ISM}|Tail]) ->
	gen_fsm:send_event(ISM, terminate),
	terminate_ISMs(Tail).

undef2empty(undefined) ->
	[];
undef2empty(asn1_NOVALUE) ->
	[];
undef2empty(Foo) ->
	Foo.

% Convert from user-visible primitive records to asn1ct-generated record
uprim_to_asn_rec(Uprim) when is_record(Uprim, 'TC-INVOKE') ->
	{invoke, #'Invoke'{invokeId = inv_id_to_asn_rec(Uprim#'TC-INVOKE'.invokeID),
		  linkedId = inv_id_to_asn_rec(Uprim#'TC-INVOKE'.linkedID),
		  opcode = osmo_util:asn_val(Uprim#'TC-INVOKE'.operation),
		  argument = undef2empty(Uprim#'TC-INVOKE'.parameters)}};
uprim_to_asn_rec(#'TC-RESULT-NL'{invokeID = InvId, operation = Op,
				 parameters = Params}) ->
	ResRes = #'ReturnResult_result'{opcode = osmo_util:asn_val(Op),
					result = osmo_util:asn_val(Params)},
	{returnResultNotLast, #'ReturnResult'{invokeId = inv_id_to_asn_rec(InvId), result = ResRes}};
uprim_to_asn_rec(#'TC-RESULT-L'{invokeID = InvId, operation = Op,
				parameters = Params}) ->
	ResRes = #'ReturnResult_result'{opcode = osmo_util:asn_val(Op),
					result = osmo_util:asn_val(Params)},
	{returnResult, #'ReturnResult'{invokeId = inv_id_to_asn_rec(InvId), result = ResRes}};
uprim_to_asn_rec(#'TC-U-ERROR'{invokeID = InvId, error = Error,
			       parameters = Params}) ->
	{returnError, #'ReturnError'{invokeId = inv_id_to_asn_rec(InvId),
			errcode = osmo_util:asn_val(Error),
			parameter = osmo_util:asn_val(Params)}};
uprim_to_asn_rec(#'TC-R-REJECT'{invokeID = InvId, problemCode = Pcode}) ->
	{reject, #'Reject'{invokeId = InvId, problem = Pcode}};
uprim_to_asn_rec(#'TC-U-REJECT'{invokeID = InvId, problemCode = Pcode}) ->
	{reject, #'Reject'{invokeId = InvId, problem = Pcode}}.

% Convert from asn1ct-generated record to the primitive records
asn_rec_to_uprim({invoke, AsnRec}, DlgId, Last) when is_record(AsnRec, 'Invoke') ->
	#'TC-INVOKE'{dialogueID = DlgId,
		     invokeID = inv_id_to_uprim(AsnRec#'Invoke'.invokeId),
		     linkedID = inv_id_to_uprim(AsnRec#'Invoke'.linkedId),
		     operation = AsnRec#'Invoke'.opcode,
		     parameters = AsnRec#'Invoke'.argument,
		     lastComponent = Last};
asn_rec_to_uprim({returnResultNotLast, AsnRec}, DlgId, Last) when is_record(AsnRec, 'ReturnResult') ->
	case AsnRec#'ReturnResult'.result of
		#'ReturnResult_result'{opcode = Op, result = Result} ->
			ok;
		asn1_NOVALUE ->
			Op = undefined,
			Result = undefined
	end,
	#'TC-RESULT-NL'{dialogueID = DlgId,
			invokeID = inv_id_to_uprim(AsnRec#'ReturnResult'.invokeId),
			operation = Op,
			parameters = Result,
			lastComponent = Last};
asn_rec_to_uprim({returnResult, AsnRec}, DlgId, Last) when is_record(AsnRec, 'ReturnResult') ->
	case AsnRec#'ReturnResult'.result of
		#'ReturnResult_result'{opcode = Op, result = Result} ->
			ok;
		asn1_NOVALUE ->
			Op = undefined,
			Result = undefined
	end,
	#'TC-RESULT-L'{dialogueID = DlgId,
			invokeID = inv_id_to_uprim(AsnRec#'ReturnResult'.invokeId),
			operation = Op,
			parameters = Result,
			lastComponent = Last};
asn_rec_to_uprim({returnError, AsnRec}, DlgId, Last) when is_record(AsnRec, 'ReturnError') ->
	#'TC-U-ERROR'{dialogueID = DlgId,
		      invokeID = inv_id_to_uprim(AsnRec#'ReturnError'.invokeId),
		      error = AsnRec#'ReturnError'.errcode,
		      parameters = AsnRec#'ReturnError'.parameter,
		      lastComponent = Last};
asn_rec_to_uprim({reject, AsnRec}, DlgId, Last) when is_record(AsnRec, 'Reject') ->
	#'TC-U-REJECT'{dialogueID = DlgId,
			invokeID = inv_id_to_uprim(AsnRec#'Reject'.invokeId),
			problemCode = AsnRec#'Reject'.problem,
			lastComponent = Last}.


process_rx_components(ISMs, Usap, DlgId, [Head|[]]) ->
	process_rx_component(ISMs, Usap, DlgId, Head, true),
	ok;
process_rx_components(ISMs, Usap, DlgId, [Head|Tail]) ->
	process_rx_component(ISMs, Usap, DlgId, Head, false),
	process_rx_components(ISMs, Usap, DlgId, Tail).

process_rx_component(ISMs, Usap, DlgId, C={invoke, #'Invoke'{}}, Last) ->
	InvId = get_invoke_id_from_comp(C),
	{invoke, I} = C,
	case I#'Invoke'.linkedId of
	    asn1_NOVALUE ->
		ok;
	    Linked ->
		% check if Linked ISM is in operation sent state
		% FIXME
		ok
	end,
	Prim = asn_rec_to_uprim(C, DlgId, Last),
	gen_fsm:send_event(Usap, {'TC','INVOKE',indication,Prim});
process_rx_component(ISMs, _Usap, DlgId, C={reject, #'Reject'{problem=Problem}}, Last) ->
	InvId = get_invoke_id_from_comp(C),
	ISM = lists:keyfind(InvId, 1, ISMs),
	case Problem of
	    {invoke, _} ->
		% FIXME: ISM active (No -> Inform TC-User)
		gen_fsm:send_event(ISM, terminate);
	    _ ->
		ok
	end,
	% FIXME: decide on TC-U-REJECT or TC-R-REJECT
	Prim = asn_rec_to_uprim(C, DlgId, Last),
	{InvId, ISM} = lists:keyfind(InvId, 1, ISMs),
	gen_fsm:send_event(ISM, Prim);
process_rx_component(ISMs, _Usap, DlgId, Comp, Last) ->
	% syntax error?
	InvId = get_invoke_id_from_comp(Comp),
	{InvId, ISM} = lists:keyfind(InvId, 1, ISMs),
	% FIXME: ISM active (No -> 6)
	Prim = asn_rec_to_uprim(Comp, DlgId, Last),
	gen_fsm:send_event(ISM, Prim).

add_components_to_state(State = #state{components=CompOld}, CompNew) when is_list(CompNew) ->
	State#state{components = CompOld ++ CompNew};
add_components_to_state(State, CompNew) when is_record(CompNew, component) ->
	add_components_to_state(State, [CompNew]).


% get the invokeId from the given asn-record component tuple.
get_invoke_id_from_comp({invoke,
			 #'Invoke'{invokeId = InvId}}) ->
	inv_id_to_uprim(InvId);
get_invoke_id_from_comp({returnResult,
			 #'ReturnResult'{invokeId = InvId}}) ->
	inv_id_to_uprim(InvId);
get_invoke_id_from_comp({returnResultNotLast,
			 #'ReturnResult'{invokeId = InvId}}) ->
	inv_id_to_uprim(InvId);
get_invoke_id_from_comp({returnError,
			 #'ReturnError'{invokeId = InvId}}) ->
	inv_id_to_uprim(InvId);
get_invoke_id_from_comp({reject,
			 #'Reject'{invokeId = InvId}}) ->
	inv_id_to_uprim(InvId).
