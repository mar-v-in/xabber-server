%%%-------------------------------------------------------------------
%%% File    : mod_xep_ccc.erl
%%% Author  : Andrey Gagarin <andrey.gagarin@redsolution.com>
%%% Purpose : XEP:  Fast Client Synchronization
%%% Created : 21 May 2019 by Andrey Gagarin <andrey.gagarin@redsolution.com>
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

-module(mod_xep_ccc).
-author('andrey.gagarin@redsolution.com').

-behaviour(gen_mod).
-behavior(gen_server).
-compile([{parse_transform, ejabberd_sql_pt}]).

-protocol({xep, '0CCC', '0.9.0'}).

-include("ejabberd.hrl").
-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").

%% gen_mod callbacks.
-export([start/2,stop/1,reload/3,depends/2,mod_options/1]).

%% gen_server callbacks.
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
  terminate/2, code_change/3]).

%% hooks
-export([c2s_stream_features/2, sm_receive_packet/1, user_send_packet/1, groupchat_send_message/3, groupchat_got_displayed/3]).

%% iq
-export([process_iq/1]).

%%
-export([get_count/4, delete_msg/5, get_last_message/4, get_last_messages/4,get_actual_last_call/4,get_last_call/4]).

%%
-export([get_last_message/3, get_count_messages/4, get_last_groupchat_message/4, get_last_previous_message/4]).

%%
-export([get_stanza_id/2, update_retract/4, check_user_for_sync/5, try_to_sync/5, make_responce_to_sync/5, iq_result_from_remote_server/1]).
-export([get_last_sync/4, make_responce_to_sync/3, get_last_ccc_state/3]).
-type c2s_state() :: ejabberd_c2s:state().
%% records
-record(state, {host = <<"">> :: binary()}).

-record(last_msg,
{
  us = {<<"">>, <<"">>}                :: {binary(), binary()} | '_',
  bare_peer = {<<"">>, <<"">>, <<"">>} :: ljid() | '_',
  id = <<>>                       :: binary() | '_',
  user_id = <<>>                       :: binary() | '_',
  packet = #xmlel{}                    :: xmlel() | message() | '_'
}
).

-record(last_sync,
{
  us = {<<"">>, <<"">>}                :: {binary(), binary()} | '_',
  bare_peer = {<<"">>, <<"">>, <<"">>} :: ljid() | '_',
  packet = #xmlel{}                    :: xmlel() | '_',
  id = <<>>                            :: binary() | '_'
}
).

-record(last_call,
{
  us = {<<"">>, <<"">>}                :: {binary(), binary()} | '_',
  bare_peer = {<<"">>, <<"">>, <<"">>} :: ljid() | '_',
  id = <<>>                            :: binary() | '_',
  packet = #xmlel{}                    :: xmlel() | message() | '_'
}
).

-record(unread_msg_counter,
{
  us = {<<"">>, <<"">>}                :: {binary(), binary()} | '_',
  bare_peer = {<<"">>, <<"">>, <<"">>} :: ljid() | '_',
  user_id = <<>>                       :: binary() | '_',
  id = <<>>                            :: binary() | '_'
}).

-record(request_job,
{
  server_id = <<>>                       :: binary() | '_',
  cs = {<<>>, <<>>}                      :: {binary(), binary()} | '_',
  usr = {<<>>, <<>>, <<>>}               :: {binary(), binary(), binary()} | '_'
}).

-define(TABLE_SIZE_LIMIT, 2000000000). % A bit less than 2 GiB.
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
  ejabberd_mnesia:create(?MODULE, request_job,
    [{disc_only_copies, [node()]},
      {attributes, record_info(fields, request_job)}]),
  ejabberd_mnesia:create(?MODULE, last_msg,
    [{disc_only_copies, [node()]},
      {type, bag},
      {attributes, record_info(fields, last_msg)}]),
  ejabberd_mnesia:create(?MODULE, last_sync,
    [{disc_only_copies, [node()]},
      {type, bag},
      {attributes, record_info(fields, last_sync)}]),
  ejabberd_mnesia:create(?MODULE, last_call,
    [{disc_only_copies, [node()]},
      {type, bag},
      {attributes, record_info(fields, last_call)}]),
  ejabberd_mnesia:create(?MODULE, unread_msg_counter,
    [{disc_only_copies, [node()]},
      {type, bag},
      {attributes, record_info(fields, unread_msg_counter)}]),
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

handle_cast({request,User,Chat}, State) ->
  {LUser,LServer,LResource} = jid:tolower(User),
  From = jid:remove_resource(User),
  {PUser,PServer,_R} = jid:tolower(Chat),
  NewID = randoms:get_alphanum_string(32),
  NewIQ = #iq{type = get, id = NewID, from = From, to = Chat, sub_els = [#xabber_synchronization_query{stamp = <<"0">>}]},
  set_request_job(NewID,{LUser,LServer,LResource},{PUser,PServer}),
  ejabberd_router:route(NewIQ),
  {noreply, State};
handle_cast({user_send,#message{type = chat, from = #jid{luser =  LUser,lserver = LServer}, to = #jid{lserver = PServer, luser = PUser}, meta = #{stanza_id := TS, mam_archived := true}} = Pkt}, State) ->
  Invite = xmpp:get_subtag(Pkt, #xabbergroupchat_invite{}),
  case Invite of
    false ->
      Conversation = jid:to_string(jid:make(PUser,PServer)),
      update_metainfo(message, LServer,LUser,Conversation,TS),
      update_metainfo(read, LServer,LUser,Conversation,TS);
    _ ->
      ok
  end,
  {noreply, State};
handle_cast({user_send,#message{type = chat, from = #jid{luser =  LUser,lserver = LServer}, to = #jid{luser =  PUser,lserver = PServer}} = Pkt}, State) ->
  Displayed = xmpp:get_subtag(Pkt, #message_displayed{}),
  case Displayed of
    #message_displayed{} ->
      BareJID = jid:make(LUser,LServer),
      Displayed2 = filter_packet(Displayed,BareJID),
      StanzaID = get_stanza_id(Displayed2,BareJID),
      Conversation = jid:to_string(jid:make(PUser,PServer)),
      update_metainfo(read, LServer,LUser,Conversation,StanzaID),
      delete_msg(LUser, LServer, PUser, PServer, StanzaID);
    _ ->
      ok
  end,
  {noreply, State};
handle_cast({sm,#message{type = chat, body = [], from = From, to = To, sub_els = SubEls}}, State) ->
  DecSubEls = lists:map(fun(El) -> xmpp:decode(El) end, SubEls),
  handle_sub_els(chat,DecSubEls,From,To),
  {noreply, State};
handle_cast({sm,#message{type = chat, from = Peer, to = To, sub_els = SubELs, meta = #{stanza_id := TS}} = Pkt}, State) ->
  {LUser, LServer, _ } = jid:tolower(To),
  {PUser, PServer, _} = jid:tolower(Peer),
  PktRefGrp = filter_reference(Pkt,<<"groupchat">>),
  X = xmpp:get_subtag(PktRefGrp, #xmppreference{type = <<"groupchat">>}),
  Propose = xmpp:get_subtag(PktRefGrp, #jingle_propose{}),
  Accept = xmpp:get_subtag(PktRefGrp, #jingle_accept{}),
  Reject = xmpp:get_subtag(PktRefGrp, #jingle_reject{}),
  Conversation = jid:to_string(jid:make(PUser,PServer)),
  case X of
    #xmppreference{} ->
      Conversation = jid:to_string(jid:make(PUser,PServer)),
      update_metainfo(<<"groupchat">>, LServer,LUser,Conversation,<<>>);
    _ ->
      ok
  end,
  case Propose of
    #jingle_propose{} ->
      store_last_call(Pkt, Peer, LUser, LServer, TS);
    _ ->
      ok
  end,
  case Accept of
    #jingle_accept{} ->
      delete_last_call(Peer, LUser, LServer);
    _ ->
      ok
  end,
  case Reject of
    #jingle_reject{} ->
      delete_last_call(Peer, LUser, LServer);
    _ ->
      ok
  end,
  Type = get_conversation_type(LServer,LUser,Conversation),
  Invite = xmpp:get_subtag(PktRefGrp, #xabbergroupchat_invite{}),
  XEl = lists:keyfind(xabbergroupchat_x,1, SubELs),
  IsLocal = lists:member(PServer,ejabberd_config:get_myhosts()),
  case Type of
    _ when Invite =/= false ->
%%      BareJID = jid:remove_resource(To),
      #xabbergroupchat_invite{jid = ChatJID} = Invite,
      Chat = jid:to_string(jid:remove_resource(ChatJID)),
%%      UserJIDString = jid:to_string(BareJID),
      store_special_message_id(LServer,LUser,Chat,TS,<<"invite">>),
%%      store_special_message_id(LServer,LUser,Conversation,TS,<<"invite">>),
      update_metainfo(<<"groupchat">>, LServer,LUser,Chat,TS);
    _ when XEl =/= false ->
      FilPacket = filter_packet(Pkt,jid:remove_resource(Peer)),
      StanzaID = xmpp:get_subtag(FilPacket, #stanza_id{}),
      TSGroupchat = StanzaID#stanza_id.id,
      Chat = jid:to_string(jid:remove_resource(Peer)),
      store_special_message_id(LServer,LUser,Conversation,binary_to_integer(TSGroupchat),<<"service">>),
      update_metainfo(<<"groupchat">>, LServer,LUser,Chat,TS),
      update_metainfo(message, LServer,LUser,Conversation,TS);
    <<"groupchat">> when IsLocal == false ->
      FilPacket = filter_packet(Pkt,jid:remove_resource(Peer)),
      StanzaID = xmpp:get_subtag(FilPacket, #stanza_id{}),
      TSGroupchat = StanzaID#stanza_id.id,
      store_last_msg(Pkt, Peer, LUser, LServer,TSGroupchat),
      update_metainfo(message, LServer,LUser,Conversation,binary_to_integer(TSGroupchat));
    <<"groupchat">> ->
      update_metainfo(message, LServer,LUser,Conversation,TS);
    _ ->
      update_metainfo(message, LServer,LUser,Conversation,TS)
  end,
  {noreply, State};
handle_cast({sm,#message{type = headline, body = [], from = From, to = To, sub_els = SubEls}}, State) ->
  DecSubEls = lists:map(fun(El) -> xmpp:decode(El) end, SubEls),
  handle_sub_els(headline,DecSubEls,From,To),
  {noreply, State};
handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info(_Info, State) ->
  {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%--------------------------------------------------------------------
%% Hooks handlers.
%%--------------------------------------------------------------------
register_hooks(Host) ->
  ejabberd_hooks:add(iq_result_from_remote_server, Host, ?MODULE,
    iq_result_from_remote_server, 10),
  ejabberd_hooks:add(synchronization_event, Host, ?MODULE,
    get_last_ccc_state, 10),
  ejabberd_hooks:add(synchronization_event, Host, ?MODULE,
    make_responce_to_sync, 20),
  ejabberd_hooks:add(synchronization_request, Host, ?MODULE,
    check_user_for_sync, 10),
  ejabberd_hooks:add(synchronization_request, Host, ?MODULE,
    try_to_sync, 20),
  ejabberd_hooks:add(synchronization_request, Host, ?MODULE,
    make_responce_to_sync, 30),
  ejabberd_hooks:add(groupchat_send_message, Host, ?MODULE,
    groupchat_send_message, 10),
  ejabberd_hooks:add(groupchat_got_displayed, Host, ?MODULE,
    groupchat_got_displayed, 10),
  ejabberd_hooks:add(user_send_packet, Host, ?MODULE,
    user_send_packet, 101),
  ejabberd_hooks:add(sm_receive_packet, Host, ?MODULE,
    sm_receive_packet, 55),
  ejabberd_hooks:add(c2s_post_auth_features, Host, ?MODULE,
    c2s_stream_features, 50).

unregister_hooks(Host) ->
  ejabberd_hooks:delete(iq_result_from_remote_server, Host, ?MODULE,
    iq_result_from_remote_server, 10),
  ejabberd_hooks:delete(synchronization_event, Host, ?MODULE,
    get_last_ccc_state, 10),
  ejabberd_hooks:delete(synchronization_event, Host, ?MODULE,
    make_responce_to_sync, 20),
  ejabberd_hooks:delete(synchronization_request, Host, ?MODULE,
    check_user_for_sync, 10),
  ejabberd_hooks:delete(synchronization_request, Host, ?MODULE,
    try_to_sync, 20),
  ejabberd_hooks:delete(synchronization_request, Host, ?MODULE,
    make_responce_to_sync, 30),
  ejabberd_hooks:delete(groupchat_send_message, Host, ?MODULE,
    groupchat_send_message, 10),
  ejabberd_hooks:delete(groupchat_got_displayed, Host, ?MODULE,
    groupchat_got_displayed, 10),
  ejabberd_hooks:delete(user_send_packet, Host, ?MODULE,
    user_send_packet, 101),
  ejabberd_hooks:delete(sm_receive_packet, Host, ?MODULE,
    sm_receive_packet, 55),
  ejabberd_hooks:delete(c2s_post_auth_features, Host, ?MODULE,
    c2s_stream_features, 50).

iq_result_from_remote_server(#iq{
  from = #jid{luser = ChatName, lserver = ChatServer},
  to = #jid{luser = LUser, lserver = LServer},
  type = result, id = ID} =IQ) ->
  case get_request_job(ID,{'_','_'},{'_','_','_'}) of
    [] ->
      ?DEBUG("Not our id ~p",[ID]);
    [#request_job{server_id = ID, usr = {LUser,LServer,_R}, cs = {ChatName,ChatServer}} = Job] ->
      Els = xmpp:get_els(IQ),
      Sync = case Els of
               [] ->
                 [];
               [F|_Rest] ->
                 F;
               _ ->
                 []
             end,
      SyncD = xmpp:decode(Sync),
      #xabber_synchronization{conversation = [Conv],stamp = Stamp} = SyncD,
      store_last_sync(Conv, ChatName, ChatServer, LUser,LServer, Stamp),
      delete_job(Job);
    _ ->
      ok
  end.

check_user_for_sync(_Acc,LServer,User,Chat,_Stamp) ->
  UserSubscription = mod_groupchat_users:check_user_if_exist(LServer,User,Chat),
  BlockToRead = mod_groupchat_restrictions:is_restricted(<<"read-messages">>,User,Chat),
  case UserSubscription of
    <<"both">> when BlockToRead == no ->
      ok;
    _ ->
      {stop,not_ok}
  end.

try_to_sync(_Acc,LServer,User,Chat,StampBinary) ->
  ChatJID = jid:from_string(Chat),
  Stamp = binary_to_integer(StampBinary),
  LUser = ChatJID#jid.luser,
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select
    @(conversation)s,
    @(retract)d,
    @(type)s,
    @(conversation_thread)s,
    @(read_until)s,
    @(delivered_until)s,
    @(displayed_until)s,
    @(updated_at)d
     from conversation_metadata"
    " where username=%(LUser)s and updated_at >= %(Stamp)d and conversation=%(User)s and %(LServer)H order by updated_at desc")) of
    {selected,[<<>>]} ->
      {stop,not_ok};
    {selected,[]} ->
      {stop,not_ok};
    {selected,[Sync]} ->
      Sync;
    _ ->
      {stop,not_ok}
  end.

make_responce_to_sync(Sync,LServer,User,Chat,_StampBinary) ->
  {Conversation,Retract,_T,Thread,_Read,Delivered,Display,UpdateAt} = Sync,
  {PUser, PServer,_} = jid:tolower(jid:from_string(Chat)),
  {LUser, UServer,_} = jid:tolower(jid:from_string(User)),
  LastRead = get_groupchat_last_readed(PServer,PUser,UServer,LUser),
  Chat = jid:to_string(jid:make(PUser,PServer)),
  Status = mod_groupchat_users:check_user_if_exist(LServer,User,Chat),
  Count = get_count_groupchat_messages(PServer,PUser,binary_to_integer(LastRead),Conversation,Status),
  LastMessage = get_last_groupchat_message(PServer,PUser,Status,LUser),
  LastCall = get_actual_last_call(LUser, UServer, PUser, PServer),
  Unread = #xabber_conversation_unread{count = Count, 'after' = LastRead},
  XabberDelivered = #xabber_conversation_delivered{id = Delivered},
  XabberDisplayed = #xabber_conversation_displayed{id = Display},
  Conv = #xabber_conversation{retract = #xabber_conversation_retract{version = Retract},
    jid = jid:from_string(Chat),
    type = <<"groupchat">>,
    thread = Thread,
    stamp = integer_to_binary(UpdateAt),
    delivered = XabberDelivered,
    displayed = XabberDisplayed,
    last = LastMessage,
    call = LastCall,
    unread = Unread},
  Res = #xabber_synchronization{conversation = [Conv], stamp = integer_to_binary(UpdateAt)},
  {stop,{ok,Res}}.

c2s_stream_features(Acc, Host) ->
  case gen_mod:is_loaded(Host, ?MODULE) of
    true ->
      [#xabber_synchronization{}|Acc];
    false ->
      Acc
  end.

groupchat_send_message(From,ChatJID,Pkt) ->
  #jid{luser =  LUser,lserver = LServer} = ChatJID,
  #jid{lserver = PServer, luser = PUser} = From,
  #message{meta = #{stanza_id := TS, mam_archived := true}} = Pkt,
  Conversation = jid:to_string(jid:make(PUser,PServer)),
  update_metainfo(read, LServer,LUser,Conversation,TS).

groupchat_got_displayed(From,ChatJID,TS) ->
  #jid{luser =  LUser,lserver = LServer} = ChatJID,
  #jid{lserver = PServer, luser = PUser} = From,
  Conversation = jid:to_string(jid:make(PUser,PServer)),
  update_metainfo(read, LServer,LUser,Conversation,TS).

-spec sm_receive_packet(stanza()) -> stanza().
sm_receive_packet(#message{to = #jid{lserver = LServer}} = Pkt) ->
  Proc = gen_mod:get_module_proc(LServer, ?MODULE),
  gen_server:cast(Proc, {sm,Pkt}),
  Pkt;
sm_receive_packet(Acc) ->
  Acc.

-spec user_send_packet({stanza(), c2s_state()})
      -> {stanza(), c2s_state()}.
user_send_packet({#message{} = Pkt, #{lserver := LServer}} = Acc) ->
  Proc = gen_mod:get_module_proc(LServer, ?MODULE),
  gen_server:cast(Proc, {user_send,Pkt}),
  Acc;
user_send_packet(Acc) ->
  Acc.

%%--------------------------------------------------------------------
%% IQ handlers.
%%--------------------------------------------------------------------
-spec register_iq_handlers(binary()) -> ok.
register_iq_handlers(Host) ->
  gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_XABBER_SYNCHRONIZATION,
    ?MODULE, process_iq).

-spec unregister_iq_handlers(binary()) -> ok.
unregister_iq_handlers(Host) ->
  gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_XABBER_SYNCHRONIZATION).

process_iq(#iq{from = #jid{luser = LUser, lserver = LServer}, type = get, sub_els = [#xabber_synchronization_query{stamp = undefined, rsm = undefined}]} = IQ) ->
  Sync = make_result(LServer, LUser, 0),
  xmpp:make_iq_result(IQ,Sync);
process_iq(#iq{from = #jid{luser = LUser, lserver = LServer}, type = get, sub_els = [#xabber_synchronization_query{stamp = <<>>, rsm = undefined}]} = IQ) ->
  Sync = make_result(LServer, LUser, 0),
  xmpp:make_iq_result(IQ,Sync);
process_iq(#iq{from = #jid{luser = LUser, lserver = LServer}, type = get, sub_els = [#xabber_synchronization_query{stamp = Stamp, rsm = undefined}]} = IQ) ->
  Sync = make_result(LServer, LUser, binary_to_integer(Stamp)),
  xmpp:make_iq_result(IQ,Sync);
process_iq(#iq{from = #jid{luser = LUser, lserver = LServer}, type = get, sub_els = [#xabber_synchronization_query{stamp = undefined, rsm = RSM}]} = IQ) ->
  Sync = make_result(LServer, LUser, <<"0">>, RSM),
  xmpp:make_iq_result(IQ,Sync);
process_iq(#iq{from = #jid{luser = LUser, lserver = LServer}, type = get, sub_els = [#xabber_synchronization_query{stamp = <<>>, rsm = RSM}]} = IQ) ->
  Sync = make_result(LServer, LUser, <<"0">>, RSM),
  xmpp:make_iq_result(IQ,Sync);
process_iq(#iq{from = #jid{luser = LUser, lserver = LServer}, type = get, sub_els = [#xabber_synchronization_query{stamp = Stamp, rsm = RSM}]} = IQ) ->
  Sync = make_result(LServer, LUser, Stamp, RSM),
  xmpp:make_iq_result(IQ,Sync);
process_iq(#iq{from = UserJID, type = set, sub_els = [#xabber_delete{conversation = Conversations}]} = IQ ) ->
  case delete_conversations(UserJID,Conversations) of
    ok ->
      xmpp:make_iq_result(IQ);
    _ ->
      xmpp:make_error(IQ, xmpp:err_bad_request())
  end;
process_iq(IQ) ->
  xmpp:make_error(IQ, xmpp:err_bad_request()).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

make_result(LServer, LUser, Stamp, RSM) ->
  {QueryChats, QueryCount} = make_sql_query(LServer, LUser, Stamp, RSM),
  {selected, _, Res} = ejabberd_sql:sql_query(LServer, QueryChats),
  {selected, _, [[CountBinary]]} = ejabberd_sql:sql_query(LServer, QueryCount),
  Count = binary_to_integer(CountBinary),
  ConvRes = convert_result(Res),
  Conv = lists:map(fun(El) ->
    make_result_el(LServer, LUser, El)
                   end, ConvRes
  ),
  ReplacedConv = replace_invites(LServer, LUser, Conv),
  LastStamp = get_last_stamp(LServer, LUser),
  ResRSM = case ReplacedConv of
             [_|_] when RSM /= undefined ->
               #xabber_conversation{stamp = First} = hd(ReplacedConv),
               #xabber_conversation{stamp = Last} = lists:last(ReplacedConv),
               #rsm_set{first = #rsm_first{data = First},
                 last = Last,
                 count = Count};
             [] when RSM /= undefined ->
               #rsm_set{count = Count};
             _ ->
               undefined
           end,
  #xabber_synchronization{conversation = ReplacedConv, stamp = LastStamp, rsm = ResRSM}.

make_result(LServer, LUser, Stamp) ->
  Sync = get_sync(LServer, LUser, Stamp),
  Conv = lists:map(fun(El) ->
    make_result_el(LServer, LUser, El)
     end, Sync
  ),
  ReplacedConv = replace_invites(LServer, LUser, Conv),
  LastStamp = get_last_stamp(LServer, LUser),
  #xabber_synchronization{conversation = ReplacedConv, stamp = LastStamp}.

convert_result(Result) ->
  lists:map(fun(El) ->
    [Conversation,Retract,Type,Thread,Read,Delivered,Display,UpdateAt] = El,
    {Conversation,binary_to_integer(Retract),Type,Thread,Read,Delivered,Display,binary_to_integer(UpdateAt)} end, Result
  ).


make_result_el(LServer, LUser, El) ->
  {Conversation,Retract,Type,Thread,Read,Delivered,Display,UpdateAt} = El,
  {PUser, PServer,_} = jid:tolower(jid:from_string(Conversation)),
  IsLocal = lists:member(PServer,ejabberd_config:get_myhosts()),
  case Type of
    <<"groupchat">> when IsLocal == true ->
      LastRead = get_groupchat_last_readed(PServer,PUser,LServer,LUser),
      User = jid:to_string(jid:make(LUser,LServer)),
      Chat = jid:to_string(jid:make(PUser,PServer)),
      Status = mod_groupchat_users:check_user_if_exist(LServer,User,Chat),
      Count = get_count_groupchat_messages(PServer,PUser,binary_to_integer(LastRead),Conversation,Status),
      LastMessage = get_last_groupchat_message(PServer,PUser,Status,LUser),
      LastCall = get_actual_last_call(LUser, LServer, PUser, PServer),
      Unread = #xabber_conversation_unread{count = Count, 'after' = LastRead},
      XabberDelivered = #xabber_conversation_delivered{id = Delivered},
      XabberDisplayed = #xabber_conversation_displayed{id = Display},
      #xabber_conversation{retract = #xabber_conversation_retract{version = Retract},
        jid = jid:from_string(Conversation),
        type = Type,
        thread = Thread,
        stamp = integer_to_binary(UpdateAt),
        delivered = XabberDelivered,
        displayed = XabberDisplayed,
        last = LastMessage,
        call = LastCall,
        unread = Unread};
    <<"groupchat">> when IsLocal == false ->
      Count = length(get_count(LUser, LServer, PUser, PServer)),
      LastMessage = get_last_message(LUser, LServer, PUser, PServer),
      LastCall = get_actual_last_call(LUser, LServer, PUser, PServer),
      Unread = #xabber_conversation_unread{count = Count, 'after' = Read},
      XabberDelivered = #xabber_conversation_delivered{id = Delivered},
      XabberDisplayed = #xabber_conversation_displayed{id = Display},
      #xabber_conversation{retract = #xabber_conversation_retract{version = Retract},
        jid = jid:from_string(Conversation),
        type = Type,
        thread = Thread,
        stamp = integer_to_binary(UpdateAt),
        delivered = XabberDelivered,
        displayed = XabberDisplayed,
        last = LastMessage,
        call = LastCall,
        unread = Unread};
    _ ->
      Count = get_count_messages(LServer,LUser,Conversation,binary_to_integer(Read)),
      LastMessage = get_last_message(LServer,LUser,Conversation),
      LastCall = get_actual_last_call(LUser, LServer, PUser, PServer),
      Unread = #xabber_conversation_unread{count = Count, 'after' = Read},
      XabberDelivered = #xabber_conversation_delivered{id = Delivered},
      XabberDisplayed = #xabber_conversation_displayed{id = Display},
      #xabber_conversation{retract = #xabber_conversation_retract{version = Retract},
        jid = jid:from_string(Conversation),
        type = Type,
        thread = Thread,
        stamp = integer_to_binary(UpdateAt),
        delivered = XabberDelivered,
        displayed = XabberDisplayed,
        last = LastMessage,
        call = LastCall,
        unread = Unread}
  end.

replace_invites(LServer, LUser, Conversations) ->
  AllConversations = lists:map(fun(Conv) ->
    #xabber_conversation{jid = JID,last = Last, type = Type} = Conv,
    case Last of
      undefined ->
        ok;
      #xabber_conversation_last{sub_els = [Message]} when Message == undefined ->
        ok;
      _ when Type == <<"groupchat">> ->
        ok;
      _ when Type =/= <<"groupchat">> ->
        #xabber_conversation_last{sub_els = [Message]} = Last,
        Invite = xmpp:get_subtag(Message, #xabbergroupchat_invite{}),
        case Invite of
          false -> ok;
          #xabbergroupchat_invite{jid = ChatJID} ->
            {JID,ChatJID,Message}
        end
    end end, Conversations
  ),
  Invites = lists:delete(ok,lists:usort(AllConversations)),
  case length(Invites) of
    0 ->
      Conversations;
    _ ->
     change_invites(LServer, LUser, Conversations,Invites)
  end.

change_invites(LServer, LUser, Conversations,Invites) ->
  Conv = lists:map(fun(C) ->
    #xabber_conversation{jid = JID, type = Type} = C,
    case Type of
      <<"groupchat">> ->
        LastMessages = [L||{_J,Chat,L} <- Invites, Chat == JID],
        maybe_replace_last_message(C,LastMessages);
      _ ->
        LastMessages = [L||{J,_Chat,L} <- Invites, J == JID],
        maybe_change_to_previous(LServer, LUser, C,LastMessages)
    end
            end, Conversations),
  replace_invites(LServer, LUser, Conv).

maybe_change_to_previous(LServer, LUser, Conversation,LastMessages) ->
  #xabber_conversation{last = Last, jid = #jid{luser = PUser, lserver = PServer}} = Conversation,
  case LastMessages of
    [] ->
      Conversation;
    _ when Last =/= undefined ->
      #xabber_conversation_last{sub_els = [Msg]} = Last,
      TS = get_stanza_id(Msg),
      BarePeer = jid:to_string(jid:make(PUser,PServer)),
      Count = get_count_messages(LServer,LUser,BarePeer,binary_to_integer(TS)),
      Unread = #xabber_conversation_unread{count = Count, 'after' = TS},
      Previous = get_last_previous_message(LServer,LUser,BarePeer,TS),
      NewConv = Conversation#xabber_conversation{last = Previous, unread = Unread},
      NewConv;
    _ when Last == undefined ->
      Conversation
  end.

maybe_replace_last_message(Conversation,LastMessages) ->
  #xabber_conversation{last = Last} = Conversation,
  case LastMessages of
    [] ->
      Conversation;
    _ when Last =/= undefined ->
      #xabber_conversation_last{sub_els = [Msg]} = Last,
      NewestLast = get_newest_last([Msg|LastMessages]),
      NewLast = #xabber_conversation_last{sub_els = [NewestLast]},
      NewConv = Conversation#xabber_conversation{last = NewLast},
      NewConv;
    _ when Last == undefined ->
      NewestLast = get_newest_last(LastMessages),
      NewLast = #xabber_conversation_last{sub_els = [NewestLast]},
      NewConv = Conversation#xabber_conversation{last = NewLast},
      NewConv
  end.

get_newest_last(Msgs) ->
  Sorted = lists:reverse(lists:sort(lists:map(fun(Msg)-> {get_stanza_id(Msg),Msg} end,Msgs))),
  [First|_R] = Sorted,
  {_StanzaID, Message}=First,
  Message.

get_stanza_id(Pkt) ->
  case xmpp:get_subtag(Pkt, #stanza_id{}) of
    #stanza_id{id = StanzaID} ->
      StanzaID;
    _ ->
      <<"0">>
  end.


store_last_call(Pkt, Peer, LUser, LServer, TS) ->
  case {mnesia:table_info(last_call, disc_only_copies),
    mnesia:table_info(last_call, memory)} of
    {[_|_], TableSize} when TableSize > ?TABLE_SIZE_LIMIT ->
      ?ERROR_MSG("Unread message counter too large, won't store message id for ~s@~s",
        [LUser, LServer]),
      {error, overflow};
    _ ->
      {PUser, PServer, _} = jid:tolower(Peer),
      F1 = fun() ->
        mnesia:write(
          #last_call{us = {LUser, LServer},
            id = integer_to_binary(TS),
            bare_peer = {PUser, PServer, <<>>},
            packet = Pkt
          })
           end,
      delete_last_call(Peer, LUser, LServer),
      case mnesia:transaction(F1) of
        {atomic, ok} ->
          ?DEBUG("Save call ~p to ~p~n TS ~p ",[LUser,Peer,TS]),
          ok;
        {aborted, Err1} ->
          ?DEBUG("Cannot add message id to unread message counter of ~s@~s: ~s",
            [LUser, LServer, Err1]),
          Err1
      end
  end.

delete_last_call(Peer, LUser, LServer) ->
  {PUser, PServer, _} = jid:tolower(Peer),
  F1 = get_last_call(LUser, LServer, PUser, PServer),
  ?DEBUG("Delete call ~p to ~p~n Call ~p ",[LUser,Peer,F1]),
  lists:foreach(
    fun(Msg) ->
      mnesia:dirty_delete_object(Msg)
    end, F1).

get_last_call(LUser, LServer, PUser, PServer) ->
  FN = fun()->
    mnesia:match_object(last_call,
      {last_call, {LUser, LServer}, {PUser, PServer,<<>>},'_','_'},
      read)
       end,
  {atomic,MsgRec} = mnesia:transaction(FN),
  MsgRec.

get_actual_last_call(LUser, LServer, PUser, PServer) ->
  FN = fun()->
    mnesia:match_object(last_call,
      {last_call, {LUser, LServer}, {PUser, PServer,<<>>},'_','_'},
      read)
       end,
  {atomic,MsgRec} = mnesia:transaction(FN),
  TS = time_now(),
  TS10 = TS - 600000000,
  ActualCall = [X||X <- MsgRec, binary_to_integer(X#last_call.id) =< TS, binary_to_integer(X#last_call.id) >= TS10],
  OldCallToDelete = [X||X <- MsgRec, binary_to_integer(X#last_call.id) < TS10],
  lists:foreach(
    fun(Msg) ->
      mnesia:dirty_delete_object(Msg)
    end, OldCallToDelete),
  ?DEBUG("actual call ~p~n~n TS NOW ~p TS10 ~p",[ActualCall,TS,TS10]),
  case ActualCall of
    [] -> undefined;
    [#last_call{packet = Pkt}] -> #xabber_conversation_call{sub_els = [Pkt]};
    _ -> undefined
  end.

store_last_msg(Pkt, Peer, LUser, LServer, TS) ->
  case {mnesia:table_info(last_msg, disc_only_copies),
    mnesia:table_info(last_msg, memory)} of
    {[_|_], TableSize} when TableSize > ?TABLE_SIZE_LIMIT ->
      ?ERROR_MSG("Last messages too large, won't store message id for ~s@~s",
        [LUser, LServer]),
      {error, overflow};
    _ ->
      {PUser, PServer, _} = jid:tolower(Peer),
      UserID = get_user_id(Pkt),
      case UserID of
        false -> ok;
        _ ->
          F1 = fun() ->
            mnesia:write(
              #last_msg{us = {LUser, LServer},
                bare_peer = {PUser, PServer, <<>>},
                id = TS,
                user_id = UserID,
                packet = Pkt
              })
               end,
          delete_last_msg(Peer, LUser, LServer),
          case mnesia:transaction(F1) of
            {atomic, ok} ->
              ?DEBUG("Save last msg ~p to ~p~n",[LUser,Peer]),
              store_last_msg_in_counter(Peer, LUser, LServer, UserID, TS),
              ok;
            {aborted, Err1} ->
              ?DEBUG("Cannot add last msg for ~s@~s: ~s",
                [LUser, LServer, Err1]),
              Err1
          end
      end
  end.


get_user_id(Pkt) ->
  PktRefGrp = filter_reference(Pkt,<<"groupchat">>),
  X = xmpp:get_subtag(PktRefGrp, #xmppreference{type = <<"groupchat">>}),
  case X of
    false ->
      not_ok;
    _ ->
      Card = xmpp:get_subtag(X, #xabbergroupchat_user_card{}),
      case Card of
        false ->
          not_ok;
        _ ->
          Card#xabbergroupchat_user_card.id
      end
  end.

store_last_msg_in_counter(Peer, LUser, LServer, UserID, TS) ->
  case {mnesia:table_info(last_msg, disc_only_copies),
    mnesia:table_info(last_msg, memory)} of
    {[_|_], TableSize} when TableSize > ?TABLE_SIZE_LIMIT ->
      ?ERROR_MSG("Unread counter too large, won't store message id for ~s@~s",
        [LUser, LServer]),
      {error, overflow};
    _ ->
      {PUser, PServer, _} = jid:tolower(Peer),
      F1 = fun() ->
        mnesia:write(
          #unread_msg_counter{us = {LUser, LServer},
            bare_peer = {PUser, PServer, <<>>},
            user_id = UserID,
            id = TS
          })
           end,
      case mnesia:transaction(F1) of
        {atomic, ok} ->
          ?DEBUG("Save last msg ~p to ~p~n",[LUser,Peer]),
          ok;
        {aborted, Err1} ->
          ?DEBUG("Cannot add unread counter for ~s@~s: ~s",
            [LUser, LServer, Err1]),
          Err1
      end
  end.

delete_last_msg(Peer, LUser, LServer) ->
  {PUser, PServer,_R} = jid:tolower(Peer),
  Msgs = get_last_messages(LUser, LServer, PUser, PServer),
  lists:foreach(
    fun(Msg) ->
      mnesia:dirty_delete_object(Msg)
    end, Msgs).

get_count(LUser, LServer, PUser, PServer) ->
  FN = fun()->
    mnesia:match_object(unread_msg_counter,
      {unread_msg_counter, {LUser, LServer}, {PUser, PServer,<<>>},'_','_'},
      read)
       end,
  {atomic,Msgs} = mnesia:transaction(FN),
  Msgs.

get_last_message(LUser, LServer, PUser, PServer) ->
  FN = fun()->
    mnesia:match_object(last_msg,
      {last_msg, {LUser, LServer}, {PUser, PServer,<<>>},'_','_','_'},
      read)
       end,
  {atomic,MsgRec} = mnesia:transaction(FN),
  case MsgRec of
    [] ->
      Chat = jid:to_string(jid:make(PUser,PServer)),
      get_invite(LServer,LUser,Chat);
    _ ->
      [Msg] = MsgRec,
      #last_msg{packet = Packet} = Msg,
      #xabber_conversation_last{sub_els = [Packet]}
  end.

get_last_messages(LUser, LServer, PUser, PServer) ->
  FN = fun()->
    mnesia:match_object(last_msg,
      {last_msg, {LUser, LServer}, {PUser, PServer,<<>>},'_','_','_'},
      read)
       end,
  {atomic,MsgRec} = mnesia:transaction(FN),
  MsgRec.

delete_msg(_LUser, _LServer, _PUser, _PServer, empty) ->
  ok;
delete_msg(LUser, LServer, PUser, PServer, TS) ->
  Msgs = get_count(LUser, LServer, PUser, PServer),
  MsgsToDelete = [X || X <- Msgs, X#unread_msg_counter.id =< TS],
  ?DEBUG("to delete ~p~n~n TS ~p",[MsgsToDelete,TS]),
  lists:foreach(
    fun(Msg) ->
      mnesia:dirty_delete_object(Msg)
    end, MsgsToDelete).

delete_one_msg(LUser, LServer, PUser, PServer, TS) ->
  Msgs = get_count(LUser, LServer, PUser, PServer),
  LastMsg = get_last_messages(LUser, LServer, PUser, PServer),
  case LastMsg of
    [#last_msg{id = TS,packet = _Pkt}] ->
      lists:foreach(
        fun(LMsg) ->
          mnesia:dirty_delete_object(LMsg)
        end, LastMsg);
    _ ->
      ok
  end,
  MsgsToDelete = [X || X <- Msgs, X#unread_msg_counter.id == TS],
  lists:foreach(
    fun(Msg) ->
      mnesia:dirty_delete_object(Msg)
    end, MsgsToDelete).

delete_user_msg(LUser, LServer, PUser, PServer, UserID) ->
  Msgs = get_count(LUser, LServer, PUser, PServer),
  MsgsToDelete = [X || X <- Msgs, X#unread_msg_counter.user_id == UserID],
  LastMsg = get_last_messages(LUser, LServer, PUser, PServer),
  case LastMsg of
    [#last_msg{user_id = UserID,packet = _Pkt}] ->
      lists:foreach(
        fun(LMsg) ->
          mnesia:dirty_delete_object(LMsg)
        end, LastMsg);
    _ ->
      ok
  end,
  lists:foreach(
    fun(Msg) ->
      mnesia:dirty_delete_object(Msg)
    end, MsgsToDelete).

delete_all_msgs(LUser, LServer, PUser, PServer) ->
  Msgs = get_count(LUser, LServer, PUser, PServer),
  Peer = jid:make(PUser,PServer),
  delete_last_msg(Peer, LUser, LServer),
  lists:foreach(
    fun(Msg) ->
      mnesia:dirty_delete_object(Msg)
    end, Msgs).

get_stanza_id(Pkt,BareJID) ->
  case xmpp:get_subtag(Pkt, #stanza_id{}) of
    #stanza_id{by = BareJID, id = StanzaID} ->
      StanzaID;
    _ ->
      empty
  end.

store_last_sync(Sync, ChatName, ChatServer, PUser, PServer, TS) ->
  case {mnesia:table_info(last_sync, disc_only_copies),
    mnesia:table_info(last_sync, memory)} of
    {[_|_], TableSize} when TableSize > ?TABLE_SIZE_LIMIT ->
      ?ERROR_MSG("Last sync too large, won't store message id for ~s@~s",
        [PUser, PServer]),
      {error, overflow};
    _ ->
      F1 = fun() ->
        mnesia:write(
          #last_sync{us = {ChatName, ChatServer},
            id = TS,
            bare_peer = {PUser, PServer, <<>>},
            packet = Sync
          })
           end,
      delete_last_sync(ChatName, ChatServer, PUser, PServer),
      case mnesia:transaction(F1) of
        {atomic, ok} ->
          ok;
        {aborted, Err1} ->
          ?DEBUG("Cannot add message id to last sync of ~s@~s: ~s",
            [PUser, PServer, Err1]),
          Err1
      end
  end.

delete_last_sync(ChatName, ChatServer, PUser, PServer) ->
  F1 = get_last_sync(ChatName, ChatServer, PUser, PServer),

  lists:foreach(
    fun(Msg) ->
      mnesia:dirty_delete_object(Msg)
    end, F1).

get_last_sync(ChatName, ChatServer, PUser, PServer) ->
  FN = fun()->
    mnesia:match_object(last_sync,
      {last_sync, {ChatName, ChatServer}, {PUser, PServer,<<>>}, '_','_'},
      read)
       end,
  {atomic,MsgRec} = mnesia:transaction(FN),
  MsgRec.

update_metainfo(_Any, _LServer,_LUser,_Conversation, empty) ->
  ?DEBUG("No id in displayed",[]),
  ok;
update_metainfo(<<"groupchat">>, LServer,LUser,Conversation,_StanzaID) ->
  Type = <<"groupchat">>,
  ?DEBUG("save groupchat ~p ~p",[LUser,Conversation]),
  TS = time_now(),
  ?SQL_UPSERT(
    LServer,
    "conversation_metadata",
    ["!username=%(LUser)s",
      "!conversation=%(Conversation)s",
      "type=%(Type)s",
      "updated_at=%(TS)d",
      "server_host=%(LServer)s"]);
update_metainfo(message, LServer,LUser,Conversation,_StanzaID) ->
  ?DEBUG("save new message ~p ~p ",[LUser,Conversation]),
  TS = time_now(),
  ?SQL_UPSERT(
    LServer,
    "conversation_metadata",
    ["!username=%(LUser)s",
      "!conversation=%(Conversation)s",
      "updated_at=%(TS)d",
      "server_host=%(LServer)s"]);
update_metainfo(delivered, LServer,LUser,Conversation,StanzaID) ->
  ?DEBUG("save delivered ~p ~p ~p",[LUser,Conversation,StanzaID]),
  ?SQL_UPSERT(
    LServer,
    "conversation_metadata",
    ["!username=%(LUser)s",
      "!conversation=%(Conversation)s",
      "delivered_until=%(StanzaID)s",
      "server_host=%(LServer)s"]);
update_metainfo(read, LServer,LUser,Conversation,StanzaID) ->
  ?DEBUG("save read ~p ~p ~p",[LUser,Conversation,StanzaID]),
  ?SQL_UPSERT(
    LServer,
    "conversation_metadata",
    ["!username=%(LUser)s",
      "!conversation=%(Conversation)s",
      "read_until=%(StanzaID)s",
      "server_host=%(LServer)s"]);
update_metainfo(displayed, LServer,LUser,Conversation,StanzaID) ->
  ?DEBUG("save displayed ~p ~p ~p",[LUser,Conversation,StanzaID]),
  ?SQL_UPSERT(
    LServer,
    "conversation_metadata",
    ["!username=%(LUser)s",
      "!conversation=%(Conversation)s",
      "displayed_until=%(StanzaID)s",
      "server_host=%(LServer)s"]).

get_sync(LServer, LUser,Stamp) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select
    @(conversation)s,
    @(retract)d,
    @(type)s,
    @(conversation_thread)s,
    @(read_until)s,
    @(delivered_until)s,
    @(displayed_until)s,
    @(updated_at)d
     from conversation_metadata"
    " where username=%(LUser)s and updated_at >= %(Stamp)d and %(LServer)H order by updated_at desc")) of
    {selected,[<<>>]} ->
      not_ok;
    {selected,Sync} ->
      Sync;
    _ ->
      not_ok
  end.

get_conversation_type(LServer,LUser,Conversation) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select
    @(type)s
     from conversation_metadata"
    " where username=%(LUser)s and conversation=%(Conversation)s and %(LServer)H")) of
    {selected,[<<>>]} ->
      not_ok;
    {selected,[{Type}]} ->
      Type;
    _ ->
      not_ok
  end.

update_retract(LServer,LUser,Conversation,NewVersion) ->
ejabberd_sql:sql_query(
    LServer,
    ?SQL("update conversation_metadata set
    retract = %(NewVersion)d
     where username=%(LUser)s and conversation=%(Conversation)s and retract < %(NewVersion)d and %(LServer)H")).

get_last_stamp(LServer, LUser) ->
  case ejabberd_sql:sql_query(
    LServer,
    [<<"select max(updated_at) from conversation_metadata where username = '">>,LUser,<<"' ;">>]) of
    {selected,_MAX,[[null]]} ->
      <<"0">>;
    {selected,_MAX,[[Version]]} ->
      Version
  end.

get_last_message(LServer,LUser,PUser) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select
    @(timestamp)d, @(xml)s, @(peer)s, @(kind)s, @(nick)s
     from archive"
    " where username=%(LUser)s and bare_peer=%(PUser)s and %(LServer)H and txt notnull and txt !='' order by timestamp desc limit 1")) of
    {selected,[<<>>]} ->
      undefined;
    {selected,[{TS, XML, Peer, Kind, Nick}]} ->
      convert_message(TS, XML, Peer, Kind, Nick, LUser, LServer);
    _ ->
      undefined
  end.

get_last_previous_message(LServer,LUser,PUser,TS) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select
    @(timestamp)d, @(xml)s, @(peer)s, @(kind)s, @(nick)s
     from archive"
    " where username=%(LUser)s and bare_peer=%(PUser)s and timestamp < %(TS)d and txt notnull and txt !='' and %(LServer)H order by timestamp desc limit 1")) of
    {selected,[<<>>]} ->
      undefined;
    {selected,[{NewTS, XML, Peer, Kind, Nick}]} ->
      convert_message(NewTS, XML, Peer, Kind, Nick, LUser, LServer);
    _ ->
      undefined
  end.

%%make_archive_el(TS, XML, Peer, Kind, Nick, MsgType, JidRequestor, JidArchive)

get_count_messages(LServer,LUser,PUser,TS) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select
    @(count(*))d
     from archive"
    " where username=%(LUser)s and bare_peer=%(PUser)s and txt notnull and txt !='' and timestamp > %(TS)d and timestamp not in (select timestamp from special_messages where conversation = %(PUser)s ) and %(LServer)H")) of
    {selected,[{Count}]} ->
      Count;
    _ ->
      0
  end.

get_last_groupchat_message(LServer,LUser,Status,User) ->
  Chat = jid:to_string(jid:make(LUser,LServer)),
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select
    @(timestamp)d, @(xml)s, @(peer)s, @(kind)s, @(nick)s
     from archive"
    " where username=%(LUser)s  and txt notnull and txt !='' and %(LServer)H order by timestamp desc limit 1")) of
    {selected,[<<>>]} ->
      get_invite(LServer,User,Chat);
    {selected,[{TS, XML, Peer, Kind, Nick}]} when Status == <<"both">> ->
      convert_message(TS, XML, Peer, Kind, Nick, LUser, LServer);
    _ ->
      get_invite(LServer,User,Chat)
  end.

get_invite(LServer,LUser,Chat) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select
    @(timestamp)d
     from special_messages"
    " where username=%(LUser)s and conversation = %(Chat)s and type = 'invite' and %(LServer)H order by timestamp desc limit 1")) of
    {selected,[<<>>]} ->
      undefined;
    {selected,[{TS}]} ->
      case ejabberd_sql:sql_query(
        LServer,
        ?SQL("select
    @(timestamp)d, @(xml)s, @(peer)s, @(kind)s, @(nick)s
     from archive"
        " where username = %(LUser)s and timestamp = %(TS)d and %(LServer)H order by timestamp desc limit 1")) of
        {selected,[<<>>]} ->
          undefined;
        {selected,[{TS, XML, Peer, Kind, Nick}]}->
          convert_message(TS, XML, Peer, Kind, Nick, LUser, LServer);
        _ ->
          undefined
      end;
    _ ->
      undefined
  end.

get_count_groupchat_messages(LServer,LUser,TS,Conversation,Status) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select
    @(count(*))d
     from archive"
    " where username=%(LUser)s  and txt notnull and txt !='' and timestamp > %(TS)d and timestamp not in (select timestamp from special_messages where conversation = %(Conversation)s and %(LServer)H ) and %(LServer)H")) of
    {selected,[{Count}]} when Status == <<"both">> ->
      Count;
    _ ->
      0
  end.

get_count_groupchat_messages(LServer,LUser,TS,Conversation) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select
    @(count(*))d
     from archive"
    " where username=%(LUser)s  and txt notnull and txt !='' and timestamp > %(TS)d and timestamp not in (select timestamp from special_messages where conversation = %(Conversation)s and %(LServer)H ) and %(LServer)H")) of
    {selected,[{Count}]} ->
      Count;
    _ ->
      0
  end.

get_groupchat_last_readed(PServer,PUser,LServer,LUser) ->
  Conv = jid:to_string(jid:make(LUser,LServer)),
  case ejabberd_sql:sql_query(
    PServer,
    ?SQL("select
    @(read_until)s
     from conversation_metadata"
    " where username=%(PUser)s and conversation=%(Conv)s and %(PServer)H order by updated_at")) of
    {selected,[<<>>]} ->
      <<"0">>;
    {selected,[{Sync}]} ->
      Sync;
    _ ->
      <<"0">>
  end.

get_groupchat_last_readed(PServer,PUser) ->
  case ejabberd_sql:sql_query(
    PServer,
    ?SQL("select
    @(read_until)s
     from conversation_metadata"
    " where username=%(PUser)s and %(PServer)H order by updated_at desc limit 1")) of
    {selected,[<<>>]} ->
      <<"0">>;
    {selected,[]} ->
      <<"0">>;
    {selected,[{Sync}]} ->
      Sync;
    _ ->
      <<"0">>
  end.

get_last_groupchat_message(LServer,LUser) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select
    @(timestamp)d, @(xml)s, @(peer)s, @(kind)s, @(nick)s
     from archive"
    " where username=%(LUser)s  and txt notnull and txt !='' and %(LServer)H order by timestamp desc limit 1")) of
    {selected,[<<>>]} ->
      undefined;
    {selected,[{TS, XML, Peer, Kind, Nick}]} ->
      convert_message(TS, XML, Peer, Kind, Nick, LUser, LServer);
    _ ->
      undefined
  end.

store_special_message_id(LServer,LUser,Conv,TS,Type) ->
  ejabberd_sql:sql_query(
    LServer,
  ?SQL_INSERT(
    "special_messages",
    ["username=%(LUser)s",
      "conversation=%(Conv)s",
      "timestamp=%(TS)d",
      "type=%(Type)s",
      "server_host=%(LServer)s"])).


convert_message(TS, XML, Peer, Kind, Nick, LUser, LServer) ->
  case mod_mam_sql:make_archive_el(integer_to_binary(TS), XML, Peer, Kind, Nick, chat, jid:make(LUser,LServer), jid:make(LUser,LServer)) of
    {ok, ArchiveElement} ->
      #forwarded{sub_els = [Message]} = ArchiveElement,
      #xabber_conversation_last{sub_els = [Message]};
    _ ->
      undefined
  end.

%%%===================================================================
%%% Handle sub_els
%%%===================================================================

handle_sub_els(chat, [#message_displayed{} = Displayed], From, To) ->
  {PUser, PServer, _} = jid:tolower(From),
  Conversation = jid:to_string(jid:make(PUser,PServer)),
  {LUser,LServer,_} = jid:tolower(To),
  BareJID = jid:make(LUser,LServer),
  Type = get_conversation_type(LServer,LUser,Conversation),
  PeerJID = jid:make(PUser,PServer),
  case Type of
    <<"groupchat">> ->
      Displayed2= filter_packet(Displayed,PeerJID),
      StanzaID = get_stanza_id(Displayed2,PeerJID),
      update_metainfo(displayed, LServer,LUser,Conversation,StanzaID);
    _ ->
      Displayed2 = filter_packet(Displayed,BareJID),
      StanzaID = get_stanza_id(Displayed2,BareJID),
      update_metainfo(displayed, LServer,LUser,Conversation,StanzaID)
  end;
handle_sub_els(chat, [#message_received{} = Delivered], From, To) ->
  {PUser, PServer, _} = jid:tolower(From),
  Conversation = jid:to_string(jid:make(PUser,PServer)),
  {LUser,LServer,_} = jid:tolower(To),
  BareJID = jid:make(LUser,LServer),
  Delivered2 = filter_packet(Delivered,BareJID),
  StanzaID1 = get_stanza_id(Delivered2,BareJID),
  update_metainfo(delivered, LServer,LUser,Conversation,StanzaID1);
handle_sub_els(headline, [#unique_received{} = UniqueReceived], From, To) ->
  case UniqueReceived of
    #unique_received{forwarded = Forwarded} when Forwarded =/= undefined ->
      #forwarded{sub_els = [Message]} = Forwarded,
      MessageD = xmpp:decode(Message),
      {PUser, PServer, _} = jid:tolower(From),
      PeerJID = jid:make(PUser, PServer),
      {LUser,LServer,_} = jid:tolower(To),
      Conversation = jid:to_string(PeerJID),
      StanzaID = get_stanza_id(MessageD,PeerJID),
      IsLocal = lists:member(PServer,ejabberd_config:get_myhosts()),
      case IsLocal of
        false ->
          store_last_msg(MessageD, PeerJID, LUser, LServer, StanzaID),
          delete_msg(LUser, LServer, PUser, PServer, StanzaID),
          update_metainfo(delivered, LServer,LUser,Conversation,StanzaID);
        _ ->
          update_metainfo(delivered, LServer,LUser,Conversation,StanzaID)
      end;
    _ ->
      ok
  end;
handle_sub_els(headline, [#xabber_retract_message{version = _Version, conversation = _Conv, id = undefined}], _From, _To) ->
  ok;
handle_sub_els(headline, [#xabber_retract_message{version = _Version, conversation = undefined, id = _ID}], _From, _To) ->
  ok;
handle_sub_els(headline, [#xabber_retract_message{version =  undefined, conversation = _Conv, id = _ID}], _From, _To) ->
  ok;
handle_sub_els(headline, [#xabber_retract_message{version = Version, conversation = ConversationJID, id = StanzaID}], _From, To) ->
  #jid{luser = LUser, lserver = LServer} = To,
  #jid{luser = PUser, lserver = PServer} = ConversationJID,
  delete_one_msg(LUser, LServer, PUser, PServer, integer_to_binary(StanzaID)),
  Conversation = jid:to_string(ConversationJID),
  update_retract(LServer,LUser,Conversation,Version),
  ok;
handle_sub_els(headline, [#xabber_retract_user{version = Version, id = UserID, conversation = ConversationJID}], _From, To) ->
  #jid{luser = LUser, lserver = LServer} = To,
  #jid{luser = PUser, lserver = PServer} = ConversationJID,
  delete_user_msg(LUser, LServer, PUser, PServer, UserID),
  Conversation = jid:to_string(ConversationJID),
  update_retract(LServer,LUser,Conversation,Version),
  ok;
handle_sub_els(headline, [#xabber_retract_all{version = Version, conversation = ConversationJID}], _From, To) ->
  #jid{luser = LUser, lserver = LServer} = To,
  #jid{luser = PUser, lserver = PServer} = ConversationJID,
  Conversation = jid:to_string(ConversationJID),
  delete_all_msgs(LUser, LServer, PUser, PServer),
  update_retract(LServer,LUser,Conversation,Version),
  ok;
handle_sub_els(_Type, _SubEls, _From, _To) ->
  ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

filter_packet(Pkt,BareJID) ->
  Els = xmpp:get_els(Pkt),
  NewEls = lists:filtermap(
    fun(El) ->
      Name = xmpp:get_name(El),
      NS = xmpp:get_ns(El),
      if (Name == <<"stanza-id">> andalso NS == ?NS_SID_0) ->
        try xmpp:decode(El) of
          #stanza_id{by = By} ->
            By == BareJID
        catch _:{xmpp_codec, _} ->
          false
        end;
        true ->
          true
      end
    end, Els),
  xmpp:set_els(Pkt, NewEls).

filter_reference(Pkt,Type) ->
  Els = xmpp:get_els(Pkt),
  NewEls = lists:filtermap(
    fun(El) ->
      Name = xmpp:get_name(El),
      NS = xmpp:get_ns(El),
      if (Name == <<"reference">> andalso NS == ?NS_REFERENCE_0) ->
        try xmpp:decode(El) of
          #xmppreference{type = TypeRef} ->
            TypeRef == Type
        catch _:{xmpp_codec, _} ->
          false
        end;
        true ->
          true
      end
    end, Els),
  xmpp:set_els(Pkt, NewEls).


time_now() ->
  {MSec, Sec, USec} = erlang:timestamp(),
  (MSec*1000000 + Sec)*1000000 + USec.

make_sql_query(LServer, User, TS, RSM) ->
  {Max, Direction, Chat} = get_max_direction_chat(RSM),
  SServer = ejabberd_sql:escape(LServer),
  SUser = ejabberd_sql:escape(User),
  Timestamp = ejabberd_sql:escape(TS),
  LimitClause = if is_integer(Max), Max >= 0 ->
    [<<" limit ">>, integer_to_binary(Max)];
                  true ->
                    []
                end,
  Conversations = [<<"select conversation,
  retract,
  type,
  conversation_thread,
  read_until,
  delivered_until,
  displayed_until,
  updated_at
  from conversation_metadata where username = '">>,SUser,<<"' and 
  updated_at > '">>,Timestamp,<<"'">>],
  PageClause = case Chat of
                 B when is_binary(B) ->
                   case Direction of
                     before ->
                       [<<" AND updated_at > '">>, Chat,<<"' ">>];
                     'after' ->
                       [<<" AND updated_at < '">>, Chat,<<"' ">>];
                     _ ->
                       []
                   end;
                 _ ->
                   []
               end,
  Query = case ejabberd_sql:use_new_schema() of
            true ->
              [Conversations,<<" and server_host='">>,
                SServer, <<"' ">>,PageClause];
            false ->
              [Conversations,PageClause]
          end,
  QueryPage =
    case Direction of
      before ->
        % ID can be empty because of
        % XEP-0059: Result Set Management
        % 2.5 Requesting the Last Page in a Result Set
        [<<"SELECT * FROM (">>, Query,
          <<" GROUP BY conversation, retract, type, conversation_thread, read_until, delivered_until, displayed_until,
  updated_at ORDER BY updated_at ASC ">>,
          LimitClause, <<") AS c ORDER BY updated_at DESC;">>];
      _ ->
        [Query, <<" GROUP BY conversation, retract, type, conversation_thread, read_until, delivered_until,  displayed_until, updated_at
        ORDER BY updated_at DESC ">>,
          LimitClause, <<";">>]
    end,
  case ejabberd_sql:use_new_schema() of
    true ->
      {QueryPage,[<<"SELECT COUNT(*) FROM (">>,Conversations,<<" and server_host='">>,
        SServer, <<"' ">>,
        <<" GROUP BY conversation, retract, type, conversation_thread, read_until, delivered_until,  displayed_until, updated_at) as subquery;">>]};
    false ->
      {QueryPage,[<<"SELECT COUNT(*) FROM (">>,Conversations,
        <<" GROUP BY conversation, retract, type, conversation_thread, read_until, delivered_until,  displayed_until, updated_at) as subquery;">>]}
  end.


get_max_direction_chat(RSM) ->
  case RSM of
    #rsm_set{max = Max, before = Before} when is_binary(Before) ->
      {Max, before, Before};
    #rsm_set{max = Max, 'after' = After} when is_binary(After) ->
      {Max, 'after', After};
    #rsm_set{max = Max} ->
      {Max, undefined, undefined};
    _ ->
      {undefined, undefined, undefined}
  end.

delete_conversations(UserJID,Conversations) ->
  LUser = UserJID#jid.luser,
  LServer = UserJID#jid.lserver,
  ConvList = form_conv_list(parse_conv(Conversations)),
  case ejabberd_sql:sql_query(
    LServer,
    [<<"delete from conversation_metadata where username= '">>, LUser,<<"' and ">>,ConvList]) of
    {updated,_N} ->
      ok;
    _ ->
      bad
  end.

parse_conv(Convs) ->
  lists:map(fun(Con) ->
    #xabber_conversation{jid = JID} = Con,
    jid:to_string(jid:remove_resource(JID))
            end, Convs).

form_conv_list(UIDs) ->
  Length = length(UIDs),
  case Length of
    0 ->
      error;
    1 ->
      [<<"conversation = '">>] ++ UIDs ++ [<<"'">>];
    _ when Length > 1 ->
      [F|R] = UIDs,
      Rest = lists:map(fun(N) ->
        <<" or conversation = '", N/binary, "'">>
                       end, R),
      [<<"(conversation = '", F/binary, "'">>] ++ Rest ++ [<<")">>];
    _ ->
      error
  end.

%% request jobs

set_request_job(ServerID, {LUser,LServer,LResource}, {PUser,PServer}) ->
  RequestJob = #request_job{server_id = ServerID, usr = {LUser,LServer,LResource}, cs = {PUser,PServer}},
  mnesia:dirty_write(RequestJob).

get_request_job(ServerID,{PUser,PServer},{LUser,LServer,LResource}) ->
  FN = fun()->
    mnesia:match_object(request_job,
      {request_job, ServerID,{PUser,PServer},{LUser,LServer,LResource}},
      read)
       end,
  {atomic,Jobs} = mnesia:transaction(FN),
  Jobs.

-spec delete_job(#request_job{}) -> ok.
delete_job(#request_job{} = J) ->
  mnesia:dirty_delete_object(J).

%% last chat information

get_last_ccc_state(_Acc,LServer,Chat) ->
  ChatJID = jid:from_string(Chat),
  Stamp = 0,
  LUser = ChatJID#jid.luser,
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select
    @(conversation)s,
    @(retract)d,
    @(type)s,
    @(conversation_thread)s,
    @(read_until)s,
    @(delivered_until)s,
    @(displayed_until)s,
    @(updated_at)d
     from conversation_metadata"
    " where username=%(LUser)s and updated_at >= %(Stamp)d and %(LServer)H order by updated_at desc limit 1")) of
    {selected,[<<>>]} ->
      {stop,not_ok};
    {selected,[]} ->
      {stop,not_ok};
    {selected,[Sync]} ->
      Sync;
    _ ->
      {stop,not_ok}
  end.

make_responce_to_sync(Sync,_LServer,Chat) ->
  {Conversation,Retract,_T,Thread,_Read,Delivered,Display,UpdateAt} = Sync,
  {PUser, PServer,_} = jid:tolower(jid:from_string(Chat)),
  LastRead = get_groupchat_last_readed(PServer,PUser),
  Chat = jid:to_string(jid:make(PUser,PServer)),
  Count = get_count_groupchat_messages(PServer,PUser,binary_to_integer(LastRead),Conversation),
  LastMessage = get_last_groupchat_message(PServer,PUser),
  Unread = #xabber_conversation_unread{count = Count, 'after' = LastRead},
  XabberDelivered = #xabber_conversation_delivered{id = Delivered},
  XabberDisplayed = #xabber_conversation_displayed{id = Display},
  Conv = #xabber_conversation{retract = #xabber_conversation_retract{version = Retract},
    jid = jid:from_string(Chat),
    type = <<"groupchat">>,
    thread = Thread,
    stamp = integer_to_binary(UpdateAt),
    delivered = XabberDelivered,
    displayed = XabberDisplayed,
    last = LastMessage,
    unread = Unread},
  Res = #xabber_synchronization{conversation = [Conv], stamp = integer_to_binary(UpdateAt)},
  {stop,{ok,Res}}.