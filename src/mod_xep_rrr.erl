%%%-------------------------------------------------------------------
%%% File    : mod_xep_rrr.erl
%%% Author  : Andrey Gagarin <andrey.gagarin@redsolution.com>
%%% Purpose : XEP-0RRR: Message Delete and Rewrite
%%% Created : 17 May 2018 by Andrey Gagarin <andrey.gagarin@redsolution.com>
%%%
%%%
%%% xabberserver, Copyright (C) 2007-2019   Redsolution OÜ
%%%
%%% This program is free software: you can redistribute it and/or
%%% modify it under the terms of the GNU Affero General Public License as
%%% published by the Free Software Foundation, either version 3 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%-------------------------------------------------------------------

-module(mod_xep_rrr).
-author('andrey.gagarin@redsolution.com').
-behaviour(gen_mod).
-behavior(gen_server).
-compile([{parse_transform, ejabberd_sql_pt}]).

-protocol({xep, '0RRR', '0.1.0'}).
%% gen_mod callbacks.
-export([start/2,stop/1,reload/3,depends/2,mod_options/1]).

%% ejabberd_hooks callbacks.
-export([disco_sm_features/5]).

%% retract hooks
-export([
  have_right_to_delete_all_incoming/6,
  have_right_to_delete_all/6,
  message_exist/6,
  replace_message/6,
  delete_message/6,
  delete_all_message/6,
  delete_all_incoming_messages/6,
  store_event/6,
  notificate/6,
  save_id_in_conversation/4,
  get_version/2,get_count_events/3
]).

%% gen_iq_handler callback.
-export([process_iq/1, create_replace/0]).

%% gen_server callbacks.
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
  terminate/2, code_change/3]).

-export([check_iq/1,get_rewrite_job/6, get_rewrite_session/2]).

-include("ejabberd.hrl").
-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").

-record(state, {host = <<"">> :: binary()}).
-record(rewrite_session,
{
  us = {<<"">>, <<"">>}                  :: {binary(), binary()},
  resource = <<"">>                      :: binary()
}).

-record(rewrite_job,
{
  server_id = <<>>                       :: binary() | '_',
  iq_id = <<>>                           :: binary() | '_',
  message_id = <<>>                      :: non_neg_integer() | '_',
  usr = {<<>>, <<>>, <<>>}               :: {binary(), binary(), binary()} | '_',
  rewrite_ask = none                     :: rewriteask() | '_',
  rewrite_message = []                   :: rewrite_message() | '_'
}).

-type rewriteask() :: none | retract | retractall | rewrite.
-type rewrite_message() :: [{from,jid()} | {to,jid()} | {text,binary()} | {by, jid()}].
%%--------------------------------------------------------------------
%% gen_mod callbacks.
%%--------------------------------------------------------------------
-spec start(binary(), gen_mod:opts()) -> ok.
start(Host, Opts) ->
  gen_mod:start_child(?MODULE, Host, Opts).

-spec stop(binary()) -> ok.
stop(Host) ->
  gen_mod:stop_child(?MODULE, Host).

-spec reload(binary(), gen_mod:opts(), gen_mod:opts()) -> ok.
reload(Host, NewOpts, OldOpts) ->
  NewMod = gen_mod:db_mod(Host, NewOpts, ?MODULE),
  OldMod = gen_mod:db_mod(Host, OldOpts, ?MODULE),
  if NewMod /= OldMod ->
    NewMod:init(Host, NewOpts);
    true ->
      ok
  end.

-spec depends(binary(), gen_mod:opts()) -> [{module(), hard | soft}].
depends(_Host, _Opts) ->
  [].

mod_options(_Host) ->
  [].

%%--------------------------------------------------------------------
%% gen_server callbacks.
%%--------------------------------------------------------------------
init([Host, _Opts]) ->
  ejabberd_mnesia:create(?MODULE, rewrite_job,
    [{disc_only_copies, [node()]},
      {attributes, record_info(fields, rewrite_job)}]),
  ejabberd_mnesia:create(?MODULE, rewrite_session,
    [{disc_only_copies, [node()]},
      {type, bag},
      {attributes, record_info(fields, rewrite_session)}]),
  clean_tables(),
  register_iq_handlers(Host),
  register_hooks(Host),
  {ok, #state{host = Host}}.

terminate(_Reason, State) ->
  Host = State#state.host,
  unregister_hooks(Host),
  unregister_iq_handlers(Host).

handle_call(_Request, _From, State) ->
  Reply = ok,
  {reply, Reply, State}.

handle_cast({From,#iq{id = IQID,type = set, sub_els = [#xabber_retract_message{id = StanzaID}]}=IQ}, State) ->
  {LUser,LServer,LResource} = jid:tolower(From),
  NewID = randoms:get_alphanum_string(32),
  NewIQ = IQ#iq{id = NewID},
  set_rewrite_job(NewID,retract,{LUser,LServer,LResource},StanzaID,IQID,[]),
  ?DEBUG("Change iq ~p",[NewIQ]),
  ejabberd_router:route(NewIQ),
  {noreply, State};
handle_cast({From,#iq{id = IQID,type = set, sub_els = [#xabber_retract_all{conversation = BarePeer}]}=IQ}, State) ->
  {LUser,LServer,LResource} = jid:tolower(From),
  NewID = randoms:get_alphanum_string(32),
  NewIQ = IQ#iq{id = NewID},
  set_rewrite_job(NewID,retractall,{LUser,LServer,LResource},BarePeer,IQID,[]),
  ?DEBUG("Change iq ~p",[NewIQ]),
  ejabberd_router:route(NewIQ),
  {noreply, State};
handle_cast({From,#iq{id = IQID,type = set, sub_els = [#xabber_replace{id = StanzaID, xabber_replace_message = Message}]}=IQ}, State) ->
  {LUser,LServer,LResource} = jid:tolower(From),
  NewID = randoms:get_alphanum_string(32),
  NewIQ = IQ#iq{id = NewID},
  #xabber_replace_message{from = MFrom, to = MTo, body = MBody, stanza_id = Stanza} = Message,
  #stanza_id{by = By} = Stanza,
  set_rewrite_job(NewID,rewrite,{LUser,LServer,LResource},StanzaID,IQID,[{from,MFrom},{to,MTo},{text,MBody},{by,By}]),
  ?DEBUG("Change iq ~p",[NewIQ]),
  ejabberd_router:route(NewIQ),
  {noreply, State};
handle_cast(#iq{type = error, id = ID} = IQ, State) ->
  ?DEBUG("Got retract error ~p",[IQ]),
  case get_rewrite_job(ID,'_','_',{'_','_','_'},'_','_') of
    [] ->
      ?DEBUG("Do nothing",[]),
      ok;
    [#rewrite_job{usr = {LUser, LServer, LResource}, iq_id = IQID} = Job] ->
      delete_job(Job),
      FullJID = jid:make(LUser, LServer, LResource),
      NewIQ = IQ#iq{id = IQID, to = FullJID},
      ejabberd_router:route(NewIQ)
  end,
  {noreply, State};
handle_cast(#iq{from = From, to = To, type = result, id = ID} = IQ, State) ->
  ?DEBUG("Got result ~p",[ID]),
  case get_rewrite_job(ID,'_','_',{'_','_','_'},'_','_') of
    [] ->
      LServer = To#jid.lserver,
      ?DEBUG("Start hook",[]),
      ejabberd_hooks:run(iq_result_from_remote_server, LServer, [IQ]),
      ok;
    [#rewrite_job{message_id = StanzaID, rewrite_ask = rewrite, usr = {LUser, LServer, LResource}, iq_id = IQID,
      rewrite_message = [{from,MFrom},{to,MTo},{text,MBody},{by,By}]} = Job] when From#jid.lresource == <<>> ->
      delete_job(Job),
      Replaced = #replaced{stamp = erlang:timestamp()},
      Replace = #xabber_replace_message{from = MFrom,to = MTo, body = MBody, stanza_id = #stanza_id{by = By,id = integer_to_binary(StanzaID)}, replaced = Replaced},
      start_rewrite_job(rewrite, LUser, LServer, LResource, StanzaID, IQID, {From,Replace});
    [#rewrite_job{message_id = StanzaID, rewrite_ask = Type, usr = {LUser, LServer, LResource}, iq_id = IQID} = Job] when From#jid.lresource == <<>> ->
      delete_job(Job),
      ?DEBUG("Start ~p message ~p for ~p~p~p ",[Type,StanzaID,LUser,LServer,LResource]),
      start_rewrite_job(Type, LUser, LServer, LResource, StanzaID, IQID, From);
    _ ->
      ok
  end,
  {noreply, State};
handle_cast(_Msg, State) ->
  ?DEBUG("Drop packet",[]),
  {noreply, State}.

handle_info({mnesia_system_event, {mnesia_down, _Node}}, State) ->
  clean_tables(),
  {noreply, State};
handle_info(_Info, State) ->
  {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%--------------------------------------------------------------------
%% Service discovery.
%%--------------------------------------------------------------------
-spec disco_sm_features(empty | {result, [binary()]} | {error, stanza_error()},
    jid(), jid(), binary(), binary())
      -> {result, [binary()]} | {error, stanza_error()}.
disco_sm_features(empty, From, To, Node, Lang) ->
  disco_sm_features({result, [?NS_XABBER_REWRITE]}, From, To, Node, Lang);
disco_sm_features({result, OtherFeatures}, _From, _To, <<"">>, _Lang) ->
  {result, [?NS_XABBER_REWRITE | OtherFeatures]};
disco_sm_features(Acc, _From, _To, _Node, _Lang) ->
  Acc.

%%--------------------------------------------------------------------
%% Register/unregister hooks.
%%--------------------------------------------------------------------
-spec register_hooks(binary()) -> ok.
register_hooks(Host) ->
  ejabberd_hooks:add(save_previous_id,
    Host, ?MODULE, save_id_in_conversation, 50),
  ejabberd_hooks:add(s2s_receive_packet, Host, ?MODULE,
    check_iq, 30),
  %% add retract rewrite message hooks
  ejabberd_hooks:add(rewrite_local_message, Host, ?MODULE,
    message_exist, 10),
  ejabberd_hooks:add(rewrite_local_message, Host, ?MODULE,
    replace_message, 15),
  ejabberd_hooks:add(rewrite_local_message, Host, ?MODULE,
    store_event, 20),
  ejabberd_hooks:add(rewrite_local_message, Host, ?MODULE,
    notificate, 25),
  %% add retract one message hooks
  ejabberd_hooks:add(retract_local_message, Host, ?MODULE,
    message_exist, 10),
  ejabberd_hooks:add(retract_local_message, Host, ?MODULE,
    delete_message, 15),
  ejabberd_hooks:add(retract_local_message, Host, ?MODULE,
    store_event, 20),
  ejabberd_hooks:add(retract_local_message, Host, ?MODULE,
    notificate, 25),
  %% add retract all local messages hooks
  ejabberd_hooks:add(retract_all_messages, Host, ?MODULE,
    have_right_to_delete_all, 10),
  ejabberd_hooks:add(retract_all_messages, Host, ?MODULE,
    delete_all_message, 15),
  ejabberd_hooks:add(retract_all_messages, Host, ?MODULE,
    store_event, 20),
  ejabberd_hooks:add(retract_all_messages, Host, ?MODULE,
    notificate, 25),
  %% add retract all incoming messages hooks
  ejabberd_hooks:add(retract_all_in_messages, Host, ?MODULE,
    have_right_to_delete_all_incoming, 10),
  ejabberd_hooks:add(retract_all_in_messages, Host, ?MODULE,
    delete_all_incoming_messages, 15),
  ejabberd_hooks:add(retract_all_in_messages, Host, ?MODULE,
    store_event, 20),
  ejabberd_hooks:add(retract_all_in_messages, Host, ?MODULE,
    notificate, 25),
  %% end retract
  ejabberd_hooks:add(disco_local_features, Host, ?MODULE,
    disco_sm_features, 50),
  ejabberd_hooks:add(disco_sm_features, Host, ?MODULE,
    disco_sm_features, 50).

-spec unregister_hooks(binary()) -> ok.
unregister_hooks(Host) ->
  ejabberd_hooks:delete(save_previous_id,
    Host, ?MODULE, save_id_in_conversation, 50),
  ejabberd_hooks:delete(s2s_in_handle_call, Host, ?MODULE,
    check_iq, 10),
  %% delete retract one message hooks
  ejabberd_hooks:delete(retract_local_message, Host, ?MODULE,
    have_right_to_delete, 10),
  ejabberd_hooks:delete(retract_local_message, Host, ?MODULE,
    delete_message, 15),
  ejabberd_hooks:delete(retract_local_message, Host, ?MODULE,
    store_event, 20),
  ejabberd_hooks:delete(retract_local_message, Host, ?MODULE,
    notificate, 25),
  %% end retract
  ejabberd_hooks:delete(disco_local_features, Host, ?MODULE,
    disco_sm_features, 50),
  ejabberd_hooks:delete(disco_sm_features, Host, ?MODULE,
    disco_sm_features, 50).

%%--------------------------------------------------------------------
%% IQ handlers.
%%--------------------------------------------------------------------
-spec register_iq_handlers(binary()) -> ok.
register_iq_handlers(Host) ->
  gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_XABBER_REWRITE,
    ?MODULE, process_iq).

-spec unregister_iq_handlers(binary()) -> ok.
unregister_iq_handlers(Host) ->
  gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_XABBER_REWRITE).

-spec process_iq(iq()) -> iq().
process_iq(#iq{type = get, lang = Lang} = IQ) ->
  Txt = <<"Value 'get' of 'type' attribute is not allowed">>,
  xmpp:make_error(IQ, xmpp:err_not_allowed(Txt, Lang));
process_iq(#iq{from = From, type = set, sub_els = [#xabber_retract_activate{version = undefined, 'less-than' = undefined}]} = IQ) ->
  {LUser, LServer, LResource} = jid:tolower(From),
  set_rewrite_notification(LServer,LUser,LResource),
  ?DEBUG("Activate notifications for ~p ~p ~p",[LUser, LServer, LResource]),
  xmpp:make_iq_result(IQ);
process_iq(#iq{from = From, type = set, sub_els = [#xabber_retract_activate{version = Version, 'less-than' = undefined}]} = IQ) ->
  {LUser, LServer, LResource} = jid:tolower(From),
  set_rewrite_notification(LServer,LUser,LResource),
  RetractNotifications = get_query(LServer,LUser,Version),
  MsgHead = lists:map(fun(El) ->
    {Element} = El,
    EventNotDecoded= fxml_stream:parse_element(Element),
    Event = xmpp:decode(EventNotDecoded),
    #message{from = jid:remove_resource(From), to = From,
      type = headline, id= randoms:get_string(), sub_els = [Event]} end, RetractNotifications
  ),
  lists:foreach(fun(M) -> ejabberd_router:route(M) end, MsgHead),
  xmpp:make_iq_result(IQ);
process_iq(#iq{from = From, type = set, sub_els = [#xabber_retract_activate{version = Version, 'less-than' = Less}]} = IQ) ->
  case Less of
    _ when Less =/= undefined andalso Version =/= undefined ->
      {LUser, LServer, LResource} = jid:tolower(From),
      set_rewrite_notification(LServer,LUser,LResource),
      Count = get_count_events(LServer,LUser,Version),
      case Count of
        _ when Count >= Less ->
          LastVersion = get_version(LServer,LUser),
          xmpp:make_iq_result(IQ, #xabber_retract_invalidate{version = LastVersion});
        _ ->
          RetractNotifications = get_query(LServer,LUser,Version),
          MsgHead = lists:map(fun(El) ->
            {Element} = El,
            EventNotDecoded= fxml_stream:parse_element(Element),
            Event = xmpp:decode(EventNotDecoded),
            #message{from = jid:remove_resource(From), to = From,
              type = headline, id= randoms:get_string(), sub_els = [Event]} end, RetractNotifications
          ),
          lists:foreach(fun(M) -> ejabberd_router:route(M) end, MsgHead),
          xmpp:make_iq_result(IQ)
      end;
    _ ->
      xmpp:make_error(IQ, xmpp:err_not_allowed())
  end;
process_iq(#iq{from = From, to = To, type = set, sub_els = [#xabber_retract_message{symmetric = false, id = StanzaID}]} = IQ) ->
  A = (To == jid:remove_resource(From)),
  case A of
    true ->
      LUser = To#jid.luser,
      LServer = To#jid.lserver,
      PeerString = get_bare_peer(LServer,LUser,StanzaID),
      PeerJID = jid:from_string(PeerString),
      Version = get_version(LServer,LUser) + 1,
      Retract = #xabber_retract_message{by = To, id = StanzaID, conversation = PeerJID, symmetric = false, version = Version},
      start_retract_message(LUser, LServer, StanzaID, IQ, Retract, Version);
    _ ->
      xmpp:make_error(IQ, xmpp:err_bad_request())
  end;
process_iq(#iq{from = From,
  to = To, type = set,
  sub_els = [#xabber_retract_message{by = RetractUserJID, symmetric = true, id = StanzaID}]} = IQ) ->
  LServer = To#jid.lserver,
  A = (jid:remove_resource(To) == jid:remove_resource(From)),
  case From#jid.lresource of
    <<>> when LServer =/= From#jid.lserver ->
      BarePeer = jid:to_string(jid:remove_resource(RetractUserJID)),
      case get_our_stanza_id(LServer,BarePeer,StanzaID) of
        not_ok ->
          ?DEBUG("Not found ~p ~p~n iq~p",[BarePeer,StanzaID,IQ]),
          xmpp:make_error(IQ, xmpp:err_item_not_found());
        {OurUser,OurStanzaID} when is_integer(OurStanzaID) == true ->
          OurUserJID = jid:from_string(OurUser),
          LUser = OurUserJID#jid.luser,
          Version = get_version(LServer,LUser) + 1,
          OurRetractAsk = #xabber_retract_message{
            by = OurUserJID,
            conversation = RetractUserJID,
            id = OurStanzaID,
            version = Version,
            xmlns = ?NS_XABBER_REWRITE_NOTIFY},
          ?DEBUG("Delete message ~p in chat ~p by ~p~n Retract ~p",[StanzaID,jid:to_string(To),BarePeer,OurRetractAsk]),
          start_retract_message(LUser, LServer, OurStanzaID, IQ, OurRetractAsk, Version);
        _ ->
          ?DEBUG("Unknow error during retract ~p",[IQ]),
          xmpp:make_error(IQ, xmpp:err_item_not_found())
      end;
    _ when A == true ->
      LUser = To#jid.luser,
      PeerString = get_bare_peer(LServer,LUser,StanzaID),
      case PeerString of
        not_found ->
          ?DEBUG("Not found ",[]),
          xmpp:make_error(IQ, xmpp:err_item_not_found());
        _ ->
          PeerJID = jid:from_string(PeerString),
          case PeerJID#jid.lserver of
            LServer ->
              start_local_retract(LUser,PeerJID#jid.luser,LServer,StanzaID,IQ);
            _ ->
              IQS = xmpp:set_from_to(IQ,jid:remove_resource(From),PeerJID),
              Proc = gen_mod:get_module_proc(LServer, ?MODULE),
              gen_server:cast(Proc, {From,IQS})
          end
      end;
    <<>> when To#jid.lresource == <<>> andalso To#jid.lserver == LServer ->
      ?DEBUG("Start deleting local messages ~p",[IQ]),
      ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_bad_request()));
    _ ->
      ?DEBUG("Bad symmetric retract",[]),
      xmpp:make_error(IQ, xmpp:err_bad_request())
  end;
process_iq(#iq{from = From, to = To, type = set, sub_els = [#xabber_retract_all{conversation = RetractUserJID, symmetric = false}]} = IQ) ->
  A = (jid:remove_resource(To) == jid:remove_resource(From)),
  ?DEBUG("Ask to retract all ~p",[RetractUserJID]),
  LServer = From#jid.lserver,
  LUser = From#jid.luser,
  case A of
    true ->
      Version = get_version(LServer,LUser) + 1,
      NewRetractAsk = #xabber_retract_all{conversation = RetractUserJID, version = Version, xmlns = ?NS_XABBER_REWRITE_NOTIFY},
      start_retract_all_message(LUser, LServer, IQ, NewRetractAsk, Version);
    _ ->
      xmpp:make_error(IQ, xmpp:err_bad_request())
  end;
process_iq(#iq{
  from = From,
  to = To, type = set,
  sub_els = [#xabber_retract_all{conversation = RetractUserJID, symmetric = true}]} = IQ) ->
  A = (To == jid:remove_resource(From)),
  LServer = To#jid.lserver,
  case From#jid.lresource of
    <<>> when LServer =/= From#jid.lserver->
      LUser = To#jid.luser,
      Version = get_version(LServer,LUser) + 1,
      RetractAsk = #xabber_retract_all{conversation = From, version = Version, xmlns = ?NS_XABBER_REWRITE_NOTIFY},
      start_retract_all_incoming_message(LUser, LServer, IQ, RetractAsk, Version);
    _ when A == true ->
      case RetractUserJID#jid.lserver of
        LServer ->
          User1 = From#jid.luser,
          User2 = RetractUserJID#jid.luser,
          start_local_retract_all(User1,User2,LServer,IQ);
        _ ->
          IQS = xmpp:set_from_to(IQ,To,RetractUserJID),
          Proc = gen_mod:get_module_proc(LServer, ?MODULE),
          gen_server:cast(Proc, {From,IQS})
      end
  end;
process_iq(#iq{
  from = From,
  to = To, type = set,
  sub_els = [#xabber_replace{id = StanzaID, xabber_replace_message = Message}]} = IQ) ->
  A = (To == jid:remove_resource(From)),
  LServer = To#jid.lserver,
  case From#jid.lresource of
    <<>> when LServer =/= From#jid.lserver->
      BarePeer = jid:to_string(From),
      case get_our_stanza_id(LServer,BarePeer,StanzaID) of
        not_ok ->
          ?DEBUG("Not found ~p ~p~n iq~p",[BarePeer,StanzaID,IQ]),
          xmpp:make_error(IQ, xmpp:err_item_not_found());
        {OurUser,OurStanzaID} when is_integer(OurStanzaID) == true ->
          OurUserJID = jid:from_string(OurUser),
          LUser = OurUserJID#jid.luser,
          Version = get_version(LServer,LUser) + 1,
          Replaced = #replaced{stamp = erlang:timestamp()},
          NewMessage = Message#xabber_replace_message{replaced = Replaced},
          OurReplaceAsk = #xabber_replace{by = OurUserJID, conversation = From, id = OurStanzaID, xabber_replace_message = NewMessage, xmlns = ?NS_XABBER_REWRITE_NOTIFY},
          ?DEBUG("Replace message ~p in chat ~p by ~p~n Retract ~p",[StanzaID,jid:to_string(To),BarePeer,OurReplaceAsk]),
          start_rewrite_message(LUser, LServer, OurStanzaID, IQ, OurReplaceAsk, Version);
        _ ->
          ?DEBUG("Unknow error during retract ~p",[IQ]),
          xmpp:make_error(IQ, xmpp:err_item_not_found())
        end;
    _ when A == true ->
      LUser = To#jid.luser,
      PeerString = get_bare_peer(LServer,LUser,StanzaID),
      PeerJID = jid:from_string(PeerString),
      case PeerJID#jid.lserver of
        LServer ->
          start_local_replace(LUser,PeerJID#jid.luser,LServer,StanzaID,Message,IQ);
        _ ->
          IQS = xmpp:set_from_to(IQ,To,PeerJID),
          Proc = gen_mod:get_module_proc(LServer, ?MODULE),
          gen_server:cast(Proc, {From,IQS})
      end
  end;
process_iq(IQ) ->
  ?DEBUG("IQ ~p",[IQ]),
  xmpp:make_error(IQ, xmpp:err_not_allowed()).

start_local_retract_all(User1,User2,LServer,IQ) ->
  User1JID = jid:make(User1,LServer),
  User2JID = jid:make(User2,LServer),
  Version2 = get_version(LServer,User2) + 1,
  RetractAsk2 = #xabber_retract_all{conversation = User1JID, version = Version2, xmlns = ?NS_XABBER_REWRITE_NOTIFY},
  Res = ejabberd_hooks:run_fold(retract_all_in_messages, LServer, [], [RetractAsk2, User2, LServer, <<>>, Version2]),
  case Res of
    ok ->
      Version1 = get_version(LServer,User1) + 1,
      RetractAsk1 = #xabber_retract_all{conversation = User2JID, version = Version1, xmlns = ?NS_XABBER_REWRITE_NOTIFY},
      start_retract_all_message(User1, LServer, IQ, RetractAsk1, Version1);
    _ ->
      ?DEBUG("Smth wrong ~p",[Res]),
      xmpp:make_error(IQ, xmpp:err_not_allowed())
  end.

start_local_replace(User1,User2,LServer,StanzaID,Message,IQ) ->
  User1JID = jid:make(User1,LServer),
  User2JID = jid:make(User2,LServer),
  User1String = jid:to_string(User1JID),
  User2String = jid:to_string(User2JID),
  case get_our_stanza_id(LServer,User1String,StanzaID) of
    {User2String,OurStanzaID} when is_integer(OurStanzaID) == true ->
      Replaced = #replaced{stamp = erlang:timestamp()},
      NewMessage = Message#xabber_replace_message{replaced = Replaced},
      User1Version = get_version(LServer,User1) + 1,
      RetractAskUser1 = #xabber_replace{
        xabber_replace_message = NewMessage,
        by = User1JID,
        xmlns = ?NS_XABBER_REWRITE_NOTIFY,
        conversation = User2JID,
        version = User1Version,
        id = StanzaID},
      User2Version = get_version(LServer,User2) + 1,
      RetractAskUser2 = #xabber_replace{
        xabber_replace_message = NewMessage,
        by = User2JID,
        xmlns = ?NS_XABBER_REWRITE_NOTIFY,
        conversation = User1JID,
        version = User2Version,
        id = OurStanzaID},
      case ejabberd_hooks:run_fold(rewrite_local_message,
        LServer, [], [RetractAskUser2,User2, LServer, OurStanzaID, User2Version]) of
        ok ->
          start_rewrite_message(User1, LServer, StanzaID, IQ, RetractAskUser1, User1Version);
        _ ->
          xmpp:make_error(IQ, xmpp:err_not_allowed())
      end;
    _ ->
      ?DEBUG("Not found ~p ~p",[StanzaID,IQ]),
      xmpp:make_error(IQ, xmpp:err_item_not_found())
  end.

start_local_retract(User1,User2,LServer,StanzaID,IQ) ->
  User1JID = jid:make(User1,LServer),
  User2JID = jid:make(User2,LServer),
  BarePeer = jid:to_string(User1JID),
  User2String = jid:to_string(User2JID),
  case get_our_stanza_id(LServer,BarePeer,StanzaID) of
    {User2String,OurStanzaID} when is_integer(OurStanzaID) == true ->
      User1Version = get_version(LServer,User1) + 1,
      RetractAskUser1 = #xabber_retract_message{
        by = User1JID,
        xmlns = ?NS_XABBER_REWRITE_NOTIFY,
        conversation = User2JID,
        version = User1Version,
        id = StanzaID},
      User2Version = get_version(LServer,User2) + 1,
      RetractAskUser2 = #xabber_retract_message{
        by = User2JID,
        xmlns = ?NS_XABBER_REWRITE_NOTIFY,
        conversation = User1JID,
        version = User2Version,
        id = OurStanzaID},
      case ejabberd_hooks:run_fold(retract_local_message,
        LServer, [], [RetractAskUser2,User2, LServer, OurStanzaID, User2Version]) of
        ok ->
          start_retract_message(User1, LServer, StanzaID, IQ, RetractAskUser1, User1Version);
        _ ->
          xmpp:make_error(IQ, xmpp:err_not_allowed())
      end;
    _ ->
      ?DEBUG("Not found ~p ~p~n iq~p",[BarePeer,StanzaID,IQ]),
      xmpp:make_error(IQ, xmpp:err_item_not_found())
  end.


start_rewrite_message(LUser, LServer, StanzaID, IQ, RetractAsk, Version) ->
  ?DEBUG("Start rewrite~p~nIQ ~p~n USER ~p~n StanzaID ~p~n Server ~p",[RetractAsk,IQ,LUser,StanzaID,LServer]),
  case ejabberd_hooks:run_fold(rewrite_local_message, LServer, [], [RetractAsk,LUser, LServer, StanzaID, Version]) of
    ok ->
      ?DEBUG("SUCCESS REPLACE ~p~n IQ ~p ",[StanzaID,IQ]),
      xmpp:make_iq_result(IQ);
    not_found ->
      xmpp:make_error(IQ, xmpp:err_item_not_found());
    _ ->
      xmpp:make_error(IQ, xmpp:err_bad_request())
  end.

start_retract_message(LUser, LServer, StanzaID, IQ, RetractAsk, Version) ->
  ?DEBUG("Start retact ~p~nIQ ~p~n USER ~p~n StanzaID ~p~n Server ~p",[RetractAsk,IQ,LUser,StanzaID,LServer]),
  case ejabberd_hooks:run_fold(retract_local_message, LServer, [], [RetractAsk,LUser, LServer, StanzaID, Version]) of
    ok ->
      ?DEBUG("SUCCESS RETRACT ~p~n IQ ~p ",[StanzaID,IQ]),
      xmpp:make_iq_result(IQ);
    not_found ->
      xmpp:make_error(IQ, xmpp:err_item_not_found());
    _ ->
      xmpp:make_error(IQ, xmpp:err_bad_request())
  end.

start_retract_all_incoming_message(LUser, LServer, IQ, RetractAsk, Version) ->
  case ejabberd_hooks:run_fold(retract_all_in_messages, LServer, [], [RetractAsk, LUser, LServer, <<>>, Version]) of
    ok ->
      ?DEBUG("retract all incoming ~p",[RetractAsk]),
      xmpp:make_iq_result(IQ);
    not_found ->
      xmpp:make_error(IQ, xmpp:err_item_not_found());
    _ ->
      xmpp:make_error(IQ, xmpp:err_bad_request())
  end.

start_retract_all_message(LUser, LServer, IQ, RetractAsk, Version) ->
  case ejabberd_hooks:run_fold(retract_all_messages, LServer, [], [RetractAsk, LUser, LServer, <<>>, Version]) of
    ok ->
      ?DEBUG("retract all ~p",[RetractAsk]),
      xmpp:make_iq_result(IQ);
    not_found ->
      xmpp:make_error(IQ, xmpp:err_item_not_found());
    _ ->
      xmpp:make_error(IQ, xmpp:err_bad_request())
  end.

start_rewrite_job(rewrite, LUser, LServer, LResource, StanzaID, IQID, {From,Message}) ->
  ?DEBUG("Start rewrite message ~p for ~p",[StanzaID,LUser]),
  BareJID = jid:make(LUser,LServer),
  JID = jid:make(LUser,LServer,LResource),
  Version = get_version(LServer,LUser) + 1,
  RetractAsk = #xabber_replace{xabber_replace_message = Message, id = StanzaID, by = BareJID, conversation = From, version = Version, xmlns = ?NS_XABBER_REWRITE_NOTIFY},
  IQ = #iq{id = IQID, type = set, to = BareJID, from = JID},
  NewIQ = case ejabberd_hooks:run_fold(rewrite_local_message, LServer, [], [RetractAsk, LUser, LServer, StanzaID, Version]) of
            ok ->
              xmpp:make_iq_result(IQ);
            not_found ->
              xmpp:make_error(IQ, xmpp:err_item_not_found());
            _ ->
              xmpp:make_error(IQ, xmpp:err_bad_request())
          end,
  ?DEBUG("got result of replace ~p",[NewIQ]),
  ejabberd_router:route(NewIQ);
start_rewrite_job(retract, LUser, LServer, LResource, StanzaID, IQID, _From) ->
  ?DEBUG("Start delete message ~p for ~p",[StanzaID,LUser]),
  BareJID = jid:make(LUser,LServer),
  JID = jid:make(LUser,LServer,LResource),
  BarePeer = get_bare_peer(LServer,LUser,StanzaID),
  Version = get_version(LServer,LUser) + 1,
  RetractAsk = #xabber_retract_message{by = BareJID, id = StanzaID, conversation = jid:from_string(BarePeer), version = Version, xmlns = ?NS_XABBER_REWRITE_NOTIFY},
  IQ = #iq{id = IQID, type = set, to = BareJID, from = JID},
  NewIQ = case ejabberd_hooks:run_fold(retract_local_message, LServer, [], [RetractAsk, LUser, LServer, StanzaID, Version]) of
         ok ->
           xmpp:make_iq_result(IQ);
         not_found ->
           xmpp:make_error(IQ, xmpp:err_item_not_found());
         _ ->
           xmpp:make_error(IQ, xmpp:err_bad_request())
       end,
  ejabberd_router:route(NewIQ);
start_rewrite_job(retractall, LUser, LServer, LResource, _StanzaID, IQID, From) ->
  BareJID = jid:make(LUser,LServer),
  JID = jid:make(LUser,LServer,LResource),
  Version = get_version(LServer,LUser) + 1,
  RetractAsk = #xabber_retract_all{conversation = From, version = Version, xmlns = ?NS_XABBER_REWRITE_NOTIFY},
  IQ = #iq{id = IQID, type = set, to = BareJID, from = JID},
  ?DEBUG("Start delete all message for ~p in chat ~p",[LUser,From]),
  NewIQ = start_retract_all_message(LUser, LServer, IQ, RetractAsk, Version),
  ?DEBUG("Result of hook ~p",[NewIQ]),
  ejabberd_router:route(NewIQ).

have_right_to_delete_all(_Acc, RewriteAsk,LUser,LServer,_StanzaID, _Version)->
  #xabber_retract_all{conversation = Conversation} = RewriteAsk,
  BarePeer = jid:to_string(Conversation),
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(timestamp)d from archive where bare_peer=%(BarePeer)s and username=%(LUser)s")) of
    {selected,[]} ->
      {stop,not_found};
    {selected,[{}]} ->
      {stop,not_found};
    _ ->
      ok
  end.

delete_all_message(_Acc, RewriteAsk, LUser, LServer,_StanzaID, _Version) ->
  #xabber_retract_all{conversation = Conversation} = RewriteAsk,
  BarePeer = jid:to_string(Conversation),
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("delete from archive where bare_peer=%(BarePeer)s and username=%(LUser)s and %(LServer)H")) of
    {updated,0} ->
      ?DEBUG("No sush message",[]),
      {stop,not_found};
    {updated,_} ->
      ok;
    _ ->
      ?DEBUG("Error during delete",[]),
      {stop,error}
  end.

have_right_to_delete_all_incoming(_Acc, RewriteAsk,LUser,LServer,_StanzaID, _Version) ->
  OurUsername  = jid:to_string(jid:make(LUser,LServer)),
  #xabber_retract_all{conversation = Conversation} = RewriteAsk,
  BarePeer = jid:to_string(Conversation),
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(our_stanza_id)d from foreign_message_stanza_id where our_username=%(OurUsername)s and foreign_username=%(BarePeer)s")) of
    {selected,[]} ->
      {stop,not_found};
    {selected,[{}]} ->
      {stop,not_found};
    {selected,Messages} ->
      Messages;
    _ ->
      {stop,not_found}
  end.

delete_all_incoming_messages(Messages, RewriteAsk,LUser,LServer,_StanzaID, _Version) ->
  [F|R] = Messages,
  #xabber_retract_all{conversation = Conversation} = RewriteAsk,
  BarePeer = jid:to_string(Conversation),
  {FI} = F,
  First = integer_to_binary(FI),
  M1 = <<"timestamp = ", First/binary >>,
  StanzaIDs = lists:map(fun(Stanza) ->
    {ID} = Stanza,
    IDBinary = integer_to_binary(ID),
    <<" or timestamp = ", IDBinary/binary>>
     end, R
  ),
  MessagesToDelete = list_to_binary([M1,StanzaIDs]),
  case ejabberd_sql:sql_query(
    LServer,
    [<<"delete from archive where username = '">>, LUser,<<"' and bare_peer = '">>,BarePeer,<<"' and (">>,MessagesToDelete, <<");">>]) of
    {updated,_N} ->
      ok;
    _ ->
      {stop,error}
  end.


message_exist(_Acc,_RewriteAsk,LUser,LServer,StanzaID, _Version)->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(xml)s from archive where timestamp=%(StanzaID)d and username=%(LUser)s")) of
    {selected,[]} ->
      {stop,not_found};
    {selected,[{}]} ->
      {stop,not_found};
    {selected,[{XML}]} ->
      XML;
    _ ->
      {stop,not_found}
  end.

delete_message(_Acc,_RewriteAsk,LUser,LServer,StanzaID, _Version) ->
  NextID = select_next_id(LServer,StanzaID),
  case NextID of
    [] ->
      delete_message(LServer,LUser,StanzaID);
    _ ->
      PreviousID = select_previous_id(LServer,StanzaID),
      delete_message(LServer,LUser,StanzaID),
      ejabberd_sql:sql_query(
        LServer,
        ?SQL_INSERT(
          "previous_id",
          [ "id=%(PreviousID)d",
            "server_host=%(LServer)s",
            "stanza_id=%(NextID)d"
          ])),
      ok
  end.

replace_message(XML, RewriteAsk, LUser,LServer,StanzaID, _Version) ->
  #xabber_replace{xabber_replace_message = ReplaceMessage, sub_els = Sub} = RewriteAsk,
  SubNewFil = filter_els(Sub),
  OldMessage = xmpp:decode(fxml_stream:parse_element(XML)),
  Lang = xmpp:get_lang(OldMessage),
  SubEls = xmpp:get_els(OldMessage),
  RefOld = filter_els(SubEls),
  RefReplaced = #xmppreference{type = <<"replaced">>, sub_els = RefOld},
  Replaced = ReplaceMessage#xabber_replace_message.replaced,
  NewSubEls = filter_markup_mention(SubEls),
  NewEls = [Replaced] ++ NewSubEls ++ [RefReplaced] ++ SubNewFil,
  NewTXT = ReplaceMessage#xabber_replace_message.body,
  NewMessage = OldMessage#message{body = [#text{data = NewTXT,lang = Lang}], sub_els = NewEls},
  NewXML = fxml:element_to_binary(xmpp:encode(NewMessage)),
  ?DEBUG("Try replace  msg ~p~n user ~p~n xml ~p~n txt ~p",[StanzaID,LUser,NewXML,NewTXT]),
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("update archive set xml = %(NewXML)s, txt = %(NewTXT)s where timestamp=%(StanzaID)d and username=%(LUser)s and %(LServer)H")).


store_event(_Acc,RewriteAsk,LUser,LServer,_StanzaID, Version) ->
  ?DEBUG("start storing ~p ",[RewriteAsk]),
  RA = xmpp:encode(RewriteAsk),
  Txt = fxml:element_to_binary(RA),
  insert_event(LServer,LUser,Txt,Version),
  ok.

notificate(_Acc, RewriteAsk,LUser,LServer,_StanzaID, _Version) ->
  BareJID = jid:make(LUser,LServer),
  Message = #message{id = randoms:get_string(), type = headline, from = BareJID, to = BareJID, sub_els = [RewriteAsk]},
  send_notification(LUser,LServer,Message),
  {stop,ok}.

send_notification(LUser,LServer,Message) ->
    BareJID = jid:make(LUser,LServer),
    NewMessage = Message#message{to = BareJID},
    ejabberd_router:route(NewMessage).

%% sql functions

get_bare_peer(LServer,LUser,ID) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(bare_peer)s from archive where timestamp=%(ID)d and username=%(LUser)s and %(LServer)H")) of
    {selected,[]} ->
      not_found;
    {selected,[{}]} ->
      not_found;
    {selected,[{Peer}]} ->
      Peer;
    _ ->
      not_found
  end.

get_count_events(Server,Username,Version) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(count(*))d from message_retract where username = %(Username)s and version > %(Version)d and %(Server)H")) of
    {selected, [{Count}]} ->
     Count
  end.

get_query(Server,Username,Version) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(xml)s from message_retract"
    " where username=%(Username)s and version > %(Version)d and %(Server)H")) of
    {selected,[<<>>]} ->
      [];
    {selected,Query} ->
      Query
  end.

get_version(Server,Username) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(version)d from message_retract where username = %(Username)s and %(Server)H order by version desc limit 1")) of
    {selected,[<<>>]} ->
      0;
    {selected,[{null}]} ->
      0;
    {selected,[null]} ->
      0;
    {selected,[]} ->
      0;
    {selected,[{Version}]} ->
      Version;
    Err ->
      ?ERROR_MSG("failed to get retract version: ~p", [Err]),
      Err
  end.

insert_event(LServer,Username,Txt,Version) ->
  ejabberd_sql:sql_query(
    LServer,
    ?SQL_INSERT(
      "message_retract",
      [ "username=%(Username)s",
        "server_host=%(LServer)s",
        "xml=%(Txt)s",
        "version=%(Version)d"
      ])).

select_previous_id(Server,ID) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(id)d from previous_id"
    " where stanza_id=%(ID)d and %(Server)H")) of
    {selected,[<<>>]} ->
      [];
    {selected,[{Query}]} ->
      Query;
    _ ->
      []
  end.

select_next_id(Server,ID) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(stanza_id)d from previous_id"
    " where id=%(ID)d and %(Server)H")) of
    {selected,[<<>>]} ->
      [];
    {selected,[{Query}]} ->
      Query;
    _ ->
      []
  end.

delete_message(LServer,LUser,StanzaID) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("delete from archive where timestamp=%(StanzaID)d and username=%(LUser)s and %(LServer)H")) of
    {updated,1} ->
      ?DEBUG("Message ~p deleted",[StanzaID]),
      ok;
    {updated,0} ->
      ?DEBUG("No sush message",[]),
      {stop,not_found};
    _ ->
      ?DEBUG("Error during delete",[]),
      {stop,error}
  end.

%% check iq if it's result for us
-spec check_iq({stanza(), ejabberd_s2s_in:state()}) ->
  {stanza(), ejabberd_s2s_in:state()}.
check_iq({Packet, #{lserver := LServer} = S2SState}) ->
  Proc = gen_mod:get_module_proc(LServer, ?MODULE),
  gen_server:cast(Proc, Packet),
  {Packet, S2SState}.

%% retract jobs

set_rewrite_job(ServerID, Type, {LUser,LServer,LResource}, StanzaIDBinary, IQID, RewriteMessage) ->
  RewriteJob = #rewrite_job{server_id = ServerID, iq_id = IQID, message_id =  StanzaIDBinary, usr = {LUser,LServer,LResource}, rewrite_ask = Type, rewrite_message = RewriteMessage},
  mnesia:dirty_write(RewriteJob).

get_rewrite_job(ServerID,IQID,Type,{LUser,LServer,LResource},StanzaIDBinary,RewriteMessage) ->
  FN = fun()->
    mnesia:match_object(rewrite_job,
      {rewrite_job, ServerID, IQID, StanzaIDBinary, {LUser,LServer,LResource}, Type,RewriteMessage},
      read)
       end,
  {atomic,Jobs} = mnesia:transaction(FN),
  Jobs.

-spec delete_job(#rewrite_job{}) -> ok.
delete_job(#rewrite_job{} = J) ->
  mnesia:dirty_delete_object(J).

%% active users

set_rewrite_notification(LServer,LUser,LResource) ->
  Session = #rewrite_session{resource = LResource, us = {LUser,LServer}},
  mnesia:dirty_write(Session).

get_rewrite_session(LServer,LUser) ->
  mnesia:dirty_read(rewrite_session, {LUser, LServer}).

-spec delete_session(#rewrite_session{}) -> ok.
delete_session(#rewrite_session{} = S) ->
  mnesia:dirty_delete_object(S).

%% clean mnesia

clean_tables() ->
  Jobs =
    get_rewrite_job('_','_','_',{'_','_','_'},'_','_'),
  Sessions = get_rewrite_session('_','_'),
  lists:foreach(
    fun(S) ->
      mnesia:dirty_delete_object(S)
    end, Sessions),
  lists:foreach(
    fun(J) ->
      mnesia:dirty_delete_object(J)
    end, Jobs).

%% save foreign stanza-id

save_foreign_id_and_jid(LServer,FUsername,FID,OurUser,OurID) ->
  ejabberd_sql:sql_query(
    LServer,
    ?SQL_INSERT(
      "foreign_message_stanza_id",
      [ "foreign_username=%(FUsername)s",
        "our_username=%(OurUser)s",
        "server_host=%(LServer)s",
        "foreign_stanza_id=%(FID)d",
        "our_stanza_id=%(OurID)d"
      ])).

get_our_stanza_id(LServer,FUsername,FID) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(our_username)s,@(our_stanza_id)d from foreign_message_stanza_id"
    " where foreign_stanza_id=%(FID)d and foreign_username =%(FUsername)s and %(LServer)H")) of
    {selected,[<<>>]} ->
      not_ok;
    {selected,[{User,ID}]} ->
      {User,ID};
    _ ->
      not_ok
  end.

-spec save_id_in_conversation({ok, message()}, binary(),
    binary(), null | binary()) -> {ok, message()} | any().
save_id_in_conversation({ok, OriginPkt}, LServer, StanzaId, _PreviousId) ->
  A = xmpp:get_subtag(OriginPkt, #stanza_id{}),
  PktGrpOnly = filter_all_exept_groupchat(OriginPkt),
  Reference = xmpp:get_subtag(PktGrpOnly, #xmppreference{type = <<"groupchat">>}),
  case A of
    #stanza_id{id = FID, by = JID} when Reference == false ->
      To = xmpp:get_to(OriginPkt),
      FUsername = jid:to_string(jid:remove_resource(JID)),
      OurUser = jid:to_string(jid:remove_resource(To)),
      save_foreign_id_and_jid(LServer,FUsername,FID,OurUser,StanzaId);
    _ ->
      ok
  end,
  {ok, OriginPkt}.

create_replace() ->
  #replaced{stamp = erlang:timestamp()}.

filter_els(Els) ->
  NewEls = lists:filter(
    fun(El) ->
      Name = xmpp:get_name(El),
      NS = xmpp:get_ns(El),
      if (Name == <<"reference">> andalso NS == ?NS_REFERENCE_0) ->
        try xmpp:decode(El) of
          #xmppreference{type = <<"markup">>} ->
            true;
          #xmppreference{type = <<"mention">>} ->
            true;
          #xmppreference{type = _Any} ->
            false
        catch _:{xmpp_codec, _} ->
          false
        end;
        true ->
          true
      end
    end, Els),
  NewEls.

filter_markup_mention(Els) ->
  NewEls = lists:filter(
    fun(El) ->
      Name = xmpp:get_name(El),
      NS = xmpp:get_ns(El),
      if (Name == <<"reference">> andalso NS == ?NS_REFERENCE_0) ->
        try xmpp:decode(El) of
          #xmppreference{type = <<"groupchat">>} ->
            false;
          #xmppreference{type = <<"markup">>} ->
            false;
          #xmppreference{type = <<"mention">>} ->
            false;
          #xmppreference{type = _Any} ->
            true
        catch _:{xmpp_codec, _} ->
          false
        end;
        true ->
          true
      end
    end, Els),
  NewEls.

filter_all_exept_groupchat(Pkt) ->
  Els = xmpp:get_els(Pkt),
  NewEls = lists:filter(
    fun(El) ->
      Name = xmpp:get_name(El),
      NS = xmpp:get_ns(El),
      if (Name == <<"reference">> andalso NS == ?NS_REFERENCE_0) ->
        try xmpp:decode(El) of
          #xmppreference{type = <<"groupchat">>} ->
            true;
          #xmppreference{type = _Any} ->
            false
        catch _:{xmpp_codec, _} ->
          false
        end;
        true ->
          true
      end
    end, Els),
  xmpp:set_els(Pkt,NewEls).