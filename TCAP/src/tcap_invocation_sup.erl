%%% $Id: tcap_invocation_sup.erl,v 1.2 2005/08/04 09:33:17 vances Exp $
%%%---------------------------------------------------------------------
%%% @copyright 2004-2005 Motivity Telecom
%%% @author Vance Shipley <vances@motivity.ca> [http://www.motivity.ca]
%%% @end
%%%
%%% Copyright (c) 2004-2005, Motivity Telecom
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
         
-module(tcap_invocation_sup).
-copyright('Copyright (c) 2003-2005 Motivity Telecom Inc.').
-author('vances@motivity.ca').
-vsn('$Revision: 1.2 $').

-behaviour(supervisor).

%% call backs needed for supervisor behaviour
-export([init/1]).

%% API to other modules
-export([start_ism/6, start_link/1]).

init([]) ->
	{ok,{{one_for_all, 0, 1}, []}}.

start_ism(USAP, DlgId, InvokeID, CcoPid, OpClass, Timeout) ->
	SupRef = list_to_atom("tcap_invocation_sup_" ++ integer_to_list(DlgId)),
	Name = list_to_atom("tcap_ism_" ++ integer_to_list(DlgId) ++ "_" ++ integer_to_list(InvokeID)),
	StartArgs = [USAP, DlgId, InvokeID, CcoPid, OpClass, Timeout],
	StartFunc = {gen_fsm, start_link, [{local, Name}, tcap_ism_fsm, StartArgs, [{debug,[trace]}]]},
	ChildSpec = {Name, StartFunc, temporary, 4000, worker,
			[tcap_ism_sup]},
	supervisor:start_child(SupRef, ChildSpec).

start_link(ID) ->
	Name = list_to_atom("tcap_invocation_sup_" ++ integer_to_list(ID)),
	supervisor:start_link({local, Name}, ?MODULE, []).
