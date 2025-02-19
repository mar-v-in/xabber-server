%%%-------------------------------------------------------------------
%%% File    : mod_groupchat_messages.erl
%%% Author  : Andrey Gagarin <andrey.gagarin@redsolution.com>
%%% Purpose : Work with message in group chats
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

-module(mod_groupchat_messages).
-author('andrey.gagarin@redsolution.com').
-compile([{parse_transform, ejabberd_sql_pt}]).
-behavior(gen_mod).
-behaviour(gen_server).
-export([start/2, stop/1, depends/2, mod_options/1]).
-export([process_message/1,send_message/3]).
-export([init/1, handle_call/3, handle_cast/2,
  handle_info/2, terminate/2, code_change/3]).
-export([
  message_hook/1,
  check_permission_write/2,
  check_permission_media/2,
  add_path/3,
  strip_stanza_id/2,
  send_displayed/3,
  get_items_from_pep/3, check_invite/2, get_actual_user_info/2, get_displayed_msg/4, shift_references/2, binary_length/1
]).
-export([get_last/1, seconds_since_epoch/1]).

-record(state, {host :: binary()}).

-record(displayed_msg,
{
  chat = {<<"">>, <<"">>}                     :: {binary(), binary()} | '_',
  bare_peer = {<<"">>, <<"">>, <<"">>}        :: ljid() | '_',
  stanza_id = <<>>                            :: binary() | '_',
  origin_id = <<>>                            :: binary() | '_'
}
).

-record(groupchat_blocked_user, {user :: binary(), timestamp :: integer() }).
-export([form_groupchat_message_body/5,send_service_message/3, send_received/4]).
-include("ejabberd.hrl").
-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").

start(Host, Opts) ->
  gen_mod:start_child(?MODULE, Host, Opts).


stop(Host) ->
  gen_mod:stop_child(?MODULE, Host).

depends(_Host, _Opts) -> [].

mod_options(_Opts) -> [].

%%====================================================================
%% gen_server callbacks
%%====================================================================
init([Host, _Opts]) ->
  ejabberd_hooks:add(groupchat_message_hook, Host, ?MODULE, check_invite, 5),
  ejabberd_hooks:add(groupchat_message_hook, Host, ?MODULE, check_permission_write, 10),
  ejabberd_hooks:add(groupchat_message_hook, Host, ?MODULE, check_permission_media, 15),
  init_db(),
  {ok, #state{host = Host}}.

init_db() ->
  ejabberd_mnesia:create(?MODULE, displayed_msg,
    [{disc_only_copies, [node()]},
      {type, bag},
      {attributes, record_info(fields, displayed_msg)}]),
  ejabberd_mnesia:create(?MODULE, groupchat_blocked_user,
    [{ram_copies, [node()]},
      {attributes, record_info(fields, groupchat_blocked_user)}]).

handle_call(_Call, _From, State) ->
  {noreply, State}.

handle_cast(Msg, State) ->
  ?WARNING_MSG("unexpected cast: ~p", [Msg]),
  {noreply, State}.


handle_info(Info, State) ->
  ?WARNING_MSG("unexpected info: ~p", [Info]),
  {noreply, State}.

terminate(_Reason, #state{host = Host}) ->
  ejabberd_hooks:delete(groupchat_message_hook, Host, ?MODULE, check_invite, 5),
  ejabberd_hooks:delete(groupchat_message_hook, Host, ?MODULE, check_permission_write, 10),
  ejabberd_hooks:delete(groupchat_message_hook, Host, ?MODULE, check_permission_media, 15).

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%
message_hook(#message{id = Id,to =To, from = From, sub_els = Els, type = Type, meta = Meta, body = Body} = Pkt) ->
  User = jid:to_string(jid:remove_resource(From)),
  Chat = jid:to_string(jid:remove_resource(To)),
  Server = To#jid.lserver,
  UserExits = mod_groupchat_inspector_sql:check_user(User,Server,Chat),
  Result = ejabberd_hooks:run_fold(groupchat_message_hook, Server, Pkt, [{User,Chat,UserExits,Els}]),
  case Result of
    not_ok ->
      Text = <<"You have no permission to write in this chat">>,
      IdSer = randoms:get_string(),
      TypeSer = chat,
      BodySer = [#text{lang = <<>>,data = Text}],
      ElsSer = [#xabbergroupchat_x{no_permission = <<>>}],
      MetaSer = #{},
      MessageNew = construct_message(To,From,IdSer,TypeSer,BodySer,ElsSer,MetaSer),
      UserID = mod_groupchat_inspector:get_user_id(Server,User,Chat),
      send_message_no_permission_to_write(UserID,MessageNew);
    blocked ->
      Text = <<"You are blocked in this chat">>,
      IdSer = randoms:get_string(),
      TypeSer = chat,
      BodySer = [#text{lang = <<>>,data = Text}],
      UserID = mod_groupchat_inspector:get_user_id(Server,User,Chat),
      UserJID = jid:from_string(User),
      UserCard = #xabbergroupchat_user_card{id = UserID, jid = UserJID},
      ElsSer = [#xabbergroupchat_x{xmlns = ?NS_GROUPCHAT_USER_KICK, sub_els = [UserCard]}],
      MetaSer = #{},
      MessageNew = construct_message(To,From,IdSer,TypeSer,BodySer,ElsSer,MetaSer),
      send_message_no_permission_to_write(UserID,MessageNew);
    {ok,Sub} ->
      Message = change_message(Id,Type,Body,Sub,Meta,To,From),
      transform_message(Message);
    _ ->
      ok
  end.

check_invite(Pkt, {_User,_Chat,_UserExits,_Els}) ->
  case xmpp:get_subtag(Pkt, #xabbergroupchat_invite{}) of
    false ->
      ok;
    _ ->
      ?DEBUG("Drop message with invite",[]),
      {stop, do_nothing}
  end.

check_permission_write(_Acc, {User,Chat,UserExits,_Els}) ->
  ChatJID = jid:from_string(Chat),
  UserJId =  jid:from_string(User),
  Domain = UserJId#jid.lserver,
  Server = ChatJID#jid.lserver,
  Block = mod_groupchat_block:check_block(Server,Chat,User,Domain),
  case mod_groupchat_restrictions:is_restricted(<<"send-messages">>,User,Chat) of
    no when UserExits == exist ->
      ok;
    _  when UserExits == exist->
      {stop,not_ok};
    _ when Block == {stop,not_ok} ->
      {stop,blocked};
    _ ->
      {stop, do_nothing}
  end.

check_permission_media(_Acc,{User,Chat,_UserExits,Els}) ->
  X = [Children || {xmlel,<<"x">>,_Attrs,Children} <- Els],
  case length(X) of
    0 ->
      {stop,{ok,Els}};
    _ ->
      [Field] = X,
      MediaList = [Children || {xmlel,<<"field">>,_Attrs,Children} <- Field],
      case length(MediaList) of
        0 ->
          {stop,{ok,Els}};
        _ ->
          [Med|_Another] = MediaList,
          [Media|_Rest] = Med,
          M = xmpp:decode(Media),
          MediaUriRare = M#media.uri,
          [MediaUri|_Re] = MediaUriRare,
          case check_permissions(MediaUri#media_uri.type,User,Chat) of
            yes ->
              {stop,not_ok};
            no ->
              {stop,{ok,Els}}
          end
      end
  end.

check_permissions(Media,User,Chat) ->
  [Type,_F] =  binary:split(Media,<<"/">>),
  Allowed = case Type of
              <<"audio">> ->
                mod_groupchat_restrictions:is_restricted(<<"send-audio">>,User,Chat);
              <<"image">> ->
                mod_groupchat_restrictions:is_restricted(<<"send-images">>,User,Chat);
              _ ->
                no
            end,
  Allowed.

process_message(Message) ->
  do_route(Message).

send_message(Message,[],From) ->
  mod_groupchat_presence:send_message_to_index(From, Message),
  ok;
send_message(Message,Users,From) ->
  [{User}|RestUsers] = Users,
  To = jid:from_string(User),
  ejabberd_router:route(From,To,Message),
  send_message(Message,RestUsers,From).

send_service_message(To,Chat,Text) ->
  Jid = jid:to_string(To),
  From = jid:from_string(Chat),
  FromChat = jid:replace_resource(From,<<"Groupchat">>),
  Id = randoms:get_string(),
  Type = chat,
  Body = [#text{lang = <<>>,data = Text}],
  {selected, AllUsers} = mod_groupchat_sql:user_list_to_send(From#jid.lserver,Chat),
  Users = AllUsers -- [{Jid}],
  Els = [service_message(Chat,Text)],
  Meta = #{},
  send_message(construct_message(Id,Type,Body,Els,Meta),Users,FromChat).

%% Internal functions
do_route(#message{from = From, to = From, body=[], sub_els = Sub, type = headline} = Message) ->
  Event = lists:keyfind(ps_event,1,Sub),
  FromChat = jid:replace_resource(From,<<"Groupchat">>),
  case Event of
    false ->
      ok;
    _ ->
      Chat = jid:to_string(From),
      #ps_event{items = Items} = Event,
      #ps_items{items = ItemList, node = Node} = Items,
      Item = lists:keyfind(ps_item,1,ItemList),
      #ps_item{sub_els = Els} = Item,
      Decoded = lists:map(fun(N) -> xmpp:decode(N) end, Els),
      [El|_R] = Decoded,
      case El of
        {nick,Nickname} when Node == <<"http://jabber.org/protocol/nick">> ->
          mod_groupchat_vcard:change_nick_in_vcard(From#jid.luser,From#jid.lserver,Nickname),
          {selected, AllUsers} = mod_groupchat_sql:user_list_to_send(From#jid.lserver,Chat),
          send_message(Message,AllUsers,FromChat);
        {avatar_meta,AvatarInfo,_Smth} when Node == <<"urn:xmpp:avatar:metadata">> ->
          [AvatarI|_RestInfo] = AvatarInfo,
          IdAvatar = AvatarI#avatar_info.id,
          {selected, AllUsers} = mod_groupchat_sql:user_list_to_send(From#jid.lserver,Chat),
          send_message(Message,AllUsers,FromChat),
          mod_groupchat_inspector:update_chat_avatar_id(From#jid.lserver,Chat,IdAvatar),
          Presence = mod_groupchat_presence:form_presence_vcard_update(IdAvatar),
          send_message(Presence,AllUsers,FromChat);
        {avatar_meta,_AvatarInfo,_Smth} ->
          {selected, AllUsers} = mod_groupchat_sql:user_list_to_send(From#jid.lserver,Chat),
          send_message(Message,AllUsers,FromChat);
        {nick,_Nickname} ->
          {selected, AllUsers} = mod_groupchat_sql:user_list_to_send(From#jid.lserver,Chat),
          send_message(Message,AllUsers,FromChat);
        _ ->
          ok
      end
  end;
do_route(#message{from = From, to = To, body=[], sub_els = Sub, type = headline} = Message) ->
  Event = lists:keyfind(ps_event,1,Sub),
  Chat = jid:to_string(jid:remove_resource(To)),
  User = jid:to_string(jid:remove_resource(From)),
  LServer = To#jid.lserver,
  case Event of
    false ->
      ok;
    _ ->
      #ps_event{items = Items} = Event,
      #ps_items{items = ItemList, node = Node} = Items,
      Item = lists:keyfind(ps_item,1,ItemList),
      #ps_item{sub_els = Els} = Item,
      Decoded = lists:map(fun(N) -> xmpp:decode(N) end, Els),
      [El|_R] = Decoded,
      case El of
        {avatar_meta,AvatarInfo,_Smth} when Node == <<"urn:xmpp:avatar:metadata">> ->
          [AvatarI|_RestInfo] = AvatarInfo,
          IdAvatar = AvatarI#avatar_info.id,
          OldID = mod_groupchat_vcard:get_image_id(LServer,User, Chat),
          case OldID of
            IdAvatar ->
              ?INFO_MSG("Do nothing",[]);
            _ ->
              ?INFO_MSG("try update",[]),
              ejabberd_router:route(jid:replace_resource(To,<<"Groupchat">>),jid:remove_resource(From),mod_groupchat_vcard:get_pubsub_meta())
          end;
        _ ->
          ok
      end
  end;
do_route(#message{body=[], from = From, type = chat, to = To} = Msg) ->
  Displayed = xmpp:get_subtag(Msg, #message_displayed{}),
  case Displayed of
    #message_displayed{id = MessageID,sub_els = _Sub} ->
      {LName,LServer,_} = jid:tolower(To),
      ChatJID = jid:make(LName,LServer),
      Displayed2 = filter_packet(Displayed,ChatJID),
      StanzaID = get_stanza_id(Displayed2,ChatJID),
      ejabberd_hooks:run(groupchat_got_displayed,LServer,[From,ChatJID,StanzaID]),
      send_displayed(ChatJID,StanzaID,MessageID);
    _ ->
      ok
  end;
do_route(#message{body=Body} = Message) ->
  Text = xmpp:get_text(Body),
  Len = string:len(unicode:characters_to_list(Text)),
  case Text of
    <<>> ->
      ok;
    _  when Len > 0 ->
      message_hook(Message);
    _ ->
      ok
  end.

send_displayed(ChatJID,StanzaID,MessageID) ->
  #jid{lserver = LServer, luser = LName} = ChatJID,
  Msgs = get_displayed_msg(LName,LServer,StanzaID, MessageID),
  lists:foreach(fun(Msg) ->
    #displayed_msg{bare_peer = {PUser,PServer,_}, stanza_id = StanzaID, origin_id = MessageID} = Msg,
    Displayed = #message_displayed{id = MessageID, sub_els = [#stanza_id{id = StanzaID, by = jid:remove_resource(ChatJID)}]},
    M = #message{type = chat, from = ChatJID, to = jid:make(PUser,PServer), sub_els = [Displayed], id=randoms:get_string()},
    ejabberd_router:route(M)
                end, Msgs),
  delete_old_messages(LName,LServer,StanzaID).

get_displayed_msg(LName,LServer,StanzaID, MessageID) ->
  FN = fun()->
    mnesia:match_object(displayed_msg,
      {displayed_msg, {LName,LServer}, {'_','_','_'}, StanzaID, MessageID},
      read)
       end,
  {atomic,Msgs} = mnesia:transaction(FN),
  Msgs.

delete_old_messages(LName,LServer,StanzaID) ->
  FN = fun()->
    mnesia:match_object(displayed_msg,
      {displayed_msg, {LName,LServer}, {'_','_','_'}, '_','_'},
      read)
       end,
  {atomic,Msgs} = mnesia:transaction(FN),
  MsgToDel = [X || X <- Msgs, X#displayed_msg.stanza_id =< StanzaID],
  lists:foreach(fun(M) ->
    mnesia:dirty_delete_object(M) end, MsgToDel).

get_stanza_id(Pkt,BareJID) ->
  case xmpp:get_subtag(Pkt, #stanza_id{}) of
    #stanza_id{by = BareJID, id = StanzaID} ->
      StanzaID;
    _ ->
      empty
  end.

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

binary_length(Binary) ->
  B1 = binary:replace(Binary,<<"&">>,<<"&amp;">>,[global]),
  B2 = binary:replace(B1,<<">">>,<<"&gt;">>,[global]),
  B3 = binary:replace(B2,<<"<">>,<<"&lt;">>,[global]),
  B4 = binary:replace(B3,<<"\"">>,<<"&quot;">>,[global]),
  B5 = binary:replace(B4,<<"\'">>,<<"&apos;">>,[global]),
  string:len(unicode:characters_to_list(B5)).

transform_message(#message{id = Id, type = Type, to = To,from = From,
                      body = Body, meta = Meta} = Pkt) ->
  Text = xmpp:get_text(Body),
  Server = To#jid.lserver,
  LUser = To#jid.luser,
  Chat = jid:to_string(jid:remove_resource(To)),
  Jid = jid:to_string(jid:remove_resource(From)),
  UserCard = mod_groupchat_users:form_user_card(Jid,Chat),
  User = mod_groupchat_users:choose_name(UserCard),
  Username = <<User/binary, ":", "\n">>,
  Length = binary_length(Username),
  Reference = #xmppreference{type = <<"groupchat">>, 'begin' = 0, 'end' = Length - 1, sub_els = [UserCard]},
  NewBody = [#text{lang = <<>>,data = <<Username/binary, Text/binary >>}],
  {selected, AllUsers} = mod_groupchat_sql:user_list_to_send(Server,Chat),
  {selected, NoReaders} = mod_groupchat_users:user_no_read(Server,Chat),
  UsersWithoutSender = AllUsers -- [{Jid}],
  Users = UsersWithoutSender -- NoReaders,
  PktSanitarized1 = strip_x_elements(Pkt),
  PktSanitarized = strip_reference_elements(PktSanitarized1),
  Els2 = shift_references(PktSanitarized, Length),
  NewEls = [Reference|Els2],
  ToArchived = jid:remove_resource(From),
  ArchiveMsg = message_for_archive(Id,Type,NewBody,NewEls,Meta,From,ToArchived),
  OriginID = get_origin_id(xmpp:get_subtag(ArchiveMsg, #origin_id{})),
  RequestReceive = xmpp:get_subtag(ArchiveMsg, #unique_request{}),
  case RequestReceive of
    _ when RequestReceive#unique_request.retry == <<"true">> andalso OriginID /= false ->
      case mod_unique:get_message(Server, LUser, OriginID) of
            #message{} = Found ->
              send_received(Found, From, OriginID,To);
        _ ->
          Pkt0 = strip_stanza_id(ArchiveMsg,Server),
          Pkt1 = mod_unique:remove_request(Pkt0,RequestReceive),
          {Pkt2, _State2} = ejabberd_hooks:run_fold(
            user_send_packet, Server, {Pkt1, #{jid => To}}, []),
          case RequestReceive of
            false ->
              send_message(Pkt2,Users,To);
            _ when OriginID /= false ->
              send_received(Pkt2,From,OriginID,To),
              send_message(Pkt2,Users,To)
          end
      end;
    _ ->
      Pkt0 = strip_stanza_id(ArchiveMsg,Server),
      Pkt1 = mod_unique:remove_request(Pkt0,RequestReceive),
      {Pkt2, _State2} = ejabberd_hooks:run_fold(
        user_send_packet, Server, {Pkt1, #{jid => To}}, []),
      ejabberd_hooks:run(groupchat_send_message,Server,[From,To,Pkt2]),
      case RequestReceive of
        false ->
%%          send_received(Pkt2,From,OriginID,To),
          send_message(Pkt2,Users,To);
        _ when OriginID /= false ->
          send_received(Pkt2,From,OriginID,To),
          send_message(Pkt2,Users,To)
      end
  end.

get_origin_id(OriginId) ->
  case OriginId of
    false ->
      false;
    _ ->
      #origin_id{id = ID} = OriginId,
      ID
  end.

message_for_archive(Id,Type,Body,Els,Meta,From,To)->
  #message{id = Id,from = From, to = To, type = Type, body = Body, sub_els = Els, meta = Meta}.

construct_message(Id,Type,Body,Els,Meta) ->
  M = #message{id = Id, type = Type, body = Body, sub_els = Els, meta = Meta},
  M.

construct_message(From,To,Id,Type,Body,Els,Meta) ->
  M = #message{from = From, to = To, id = Id, type = Type, body = Body, sub_els = Els, meta = Meta},
  M.


change_message(Id,Type,Body,Els,Meta,To,From) ->
  #message{id = Id, type = Type, body = Body, sub_els = Els, meta = Meta, to = To, from = From}.

form_groupchat_message_body(Server,Jid,Chat,Text,Lang) ->
  Request = mod_groupchat_restrictions:get_user_rules(Server,Jid,Chat),
  case Request of
    {selected,_Tables,[]} ->
      not_ok;
    {selected,_Tables,Items} ->
      {Nick,Badge,A} = mod_groupchat_inspector:parse_items_for_message(Items),
      Children = A ++ [body(Text,Lang)],
      {Nick,Badge,#xmlel{
        name = <<"x">>,
        attrs = [
          {<<"xmlns">>,?NS_GROUPCHAT}
        ],
        children = Children
      }};
    _ ->
      not_ok
  end.

body(Data,Lang) ->
   Attrs = [{<<"xml:lang">>,Lang},{<<"xmlns">>,<<"urn:ietf:params:xml:ns:xmpp-streams">>}],
  #xmlel{name = <<"body">>, attrs = Attrs, children = [{xmlcdata, Data}]}.

parse_item(#iq{sub_els = Sub}) ->
  Pubsub = lists:keyfind(pubsub,1,Sub),
  #pubsub{items = ItemList} = Pubsub,
  #ps_items{items = Items} = ItemList,
  Item = lists:keyfind(ps_item,1,Items),
  case Item of
    false ->
      <<>>;
    _ ->
      #ps_item{sub_els = Els} = Item,
      Decoded = lists:map(fun(N) -> xmpp:decode(N) end, Els),
      Result = case Decoded of
                 [{nick,Nickname}] ->
                   Nickname;
                 [{avatar_meta,AvatarInfo,_Smth}] ->
                   AvatarInfo;
                 _ ->
                   <<>>
               end,
      Result
  end.


iq_get_item_from_pubsub(Chat,Node,ItemId) ->
  Item = #ps_item{id = ItemId},
  Items = #ps_items{items = [Item],node = Node},
  Pubsub = #pubsub{items = Items},
  #iq{type = get, id = randoms:get_string(), to = Chat, from = Chat, sub_els = [Pubsub]}.

get_items_from_pep(User,Chat,Hash) ->
  ChatJid = jid:from_string(Chat),
  UserMetadataNode = <<"urn:xmpp:avatar:metadata#",User/binary>>,
  UserNickNode = <<"http://jabber.org/protocol/nick#",User/binary>>,
  Avatar = parse_item(mod_pubsub:iq_sm(iq_get_item_from_pubsub(ChatJid,UserMetadataNode,Hash))),
  Nick = parse_item(mod_pubsub:iq_sm(iq_get_item_from_pubsub(ChatJid,UserNickNode,<<"0">>))),
  {Avatar,Nick}.

add_path(Server,Photo,JID) ->
  case bit_size(Photo) of
    0 ->
      mod_groupchat_sql:set_update_status(Server,JID,<<"true">>),
      <<>>;
    _ ->
      <<Server/binary, ":5280/pictures/", Photo/binary>>
  end.

service_message(JID,Text) ->
  #xmlel{
    name = <<"groupchat">>,
    attrs = [
      {<<"from">>, JID}
    ],
    children = [{xmlcdata, Text}]
  }.

-spec strip_reference_elements(stanza()) -> stanza().
strip_reference_elements(Pkt) ->
  Els = xmpp:get_els(Pkt),
  NewEls = lists:filter(
    fun(El) ->
      Name = xmpp:get_name(El),
      NS = xmpp:get_ns(El),
      if (Name == <<"reference">> andalso NS == ?NS_REFERENCE_0) ->
        try xmpp:decode(El) of
          #xmppreference{type = <<"groupchat">>} ->
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
  xmpp:set_els(Pkt, NewEls).

-spec clean_reference(stanza()) -> stanza().
clean_reference(Pkt) ->
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
  xmpp:set_els(Pkt, NewEls).

-spec strip_x_elements(stanza()) -> stanza().
strip_x_elements(Pkt) ->
  Els = xmpp:get_els(Pkt),
  NewEls = lists:filter(
    fun(El) ->
      Name = xmpp:get_name(El),
      NS = xmpp:get_ns(El),
      if (Name == <<"x">> andalso NS == ?NS_GROUPCHAT) ->
        try xmpp:decode(El) of
          #xabbergroupchat_x{} ->
            false
        catch _:{xmpp_codec, _} ->
          false
        end;
        true ->
          true
      end
    end, Els),
  xmpp:set_els(Pkt, NewEls).

-spec strip_stanza_id(stanza(), binary()) -> stanza().
strip_stanza_id(Pkt, LServer) ->
  Els = xmpp:get_els(Pkt),
  NewEls = lists:filter(
    fun(El) ->
      Name = xmpp:get_name(El),
      NS = xmpp:get_ns(El),
      if (Name == <<"archived">> andalso NS == ?NS_MAM_TMP);
      (Name == <<"time">> andalso NS == ?NS_UNIQUE);
      (Name == <<"stanza-id">> andalso NS == ?NS_SID_0) ->
        try xmpp:decode(El) of
          #mam_archived{by = By} ->
            By#jid.lserver == LServer;
          #unique_time{by = By} ->
            By#jid.lserver == LServer;
          #stanza_id{by = By} ->
            By#jid.lserver == LServer
        catch _:{xmpp_codec, _} ->
          false
        end;
        true ->
          true
      end
    end, Els),
  xmpp:set_els(Pkt, NewEls).

send_received(
    Pkt,
    JID,
    OriginID,ChatJID) ->
  JIDBare = jid:remove_resource(JID),
  #message{meta = #{mam_archived := true, stanza_id := StanzaID}} = Pkt,
  case store_origin_id(ChatJID#jid.lserver, StanzaID, OriginID) of
    ok ->
      Pkt2 = xmpp:set_from_to(Pkt,JID,ChatJID),
      set_displayed(ChatJID,JID,StanzaID,OriginID),
      UniqueReceived = #unique_received{
        forwarded = #forwarded{sub_els = [Pkt2]}},
      Confirmation = #message{
        from = ChatJID,
        to = JIDBare,
        type = headline,
        sub_els = [UniqueReceived]},
      ejabberd_router:route(Confirmation);
    _ ->
      ok
  end.

set_displayed(ChatJID,UserJID,StanzaID,OriginID) ->
  {LName,LServer,_} = jid:tolower(ChatJID),
  {PUser,PServer,_} = jid:tolower(UserJID),
  Msg = #displayed_msg{chat = {LName,LServer}, stanza_id = integer_to_binary(StanzaID), origin_id = OriginID, bare_peer = {PUser,PServer,<<>>}},
  mnesia:dirty_write(Msg).

store_origin_id(LServer, StanzaID, OriginID) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL_INSERT(
      "origin_id",
      ["id=%(OriginID)s",
        "server_host=%(LServer)s",
        "stanza_id=%(StanzaID)d"])) of
    {updated, _} ->
      ok;
    Err ->
      Err
  end.

%% Actual information about user

get_actual_user_info(_Server, []) ->
  [];
get_actual_user_info(Server, Msgs) ->
  UsersIDs = lists:map(fun(Pkt) ->
    {_ID, _IDInt, El} = Pkt,
    #forwarded{sub_els = [Msg]} = El,
    Msg2 = clean_reference(Msg),
    X = xmpp:get_subtag(Msg2, #xmppreference{type = <<"groupchat">>}),
    case X of
      false ->
        {false,false};
      _ ->
        Card = xmpp:get_subtag(X, #xabbergroupchat_user_card{}),
        case Card of
          false ->
            {false,false};
          _ ->
            {jid:to_string(jid:remove_resource(Msg#message.from)),
              Card#xabbergroupchat_user_card.id}
        end
    end
    end, Msgs
  ),
  UniqUsersIDs = lists:usort(UsersIDs),
  Chats = lists:usort([C || {C,_ID} <- UsersIDs]),
  ChatandUserCards = lists:map(fun(Chat) ->
    case Chat of
      false ->
        {false,[]};
      _ ->
        Users = [U ||{C,U} <- UniqUsersIDs ,C == Chat],
        AllUserCards = lists:map(fun(UsID) ->
          User = mod_groupchat_users:get_user_by_id(Server,Chat,UsID),
          case User of
            none ->
              {none,none};
            _ ->
              UserCard = mod_groupchat_users:form_user_card(User,Chat),
              {UsID, UserCard}
          end end, Users),
        UserCards = [{UID,Card}|| {UID,Card} <- AllUserCards, UID =/= none],
        {Chat, UserCards}
    end end, Chats),
  change_all_messages(ChatandUserCards,Msgs).
%%  [Chat] = Chats,
%%  case Chat of
%%    false ->
%%      Msgs;
%%    _ ->
%%      JIDsRaw = lists:usort(lists:map(fun(UserID) ->
%%        {mod_groupchat_users:get_user_by_id(Server,Chat,UserID), UserID} end, UniqIDs
%%      )),
%%      NoneJIDs = [{none,U}||{none,U} <- JIDsRaw],
%%      JIDs = JIDsRaw -- NoneJIDs,
%%      UserCards = lists:map(fun(UserInfo) ->
%%        {User,UID} = UserInfo,
%%        {UID,mod_groupchat_users:form_user_card(User,Chat)} end, JIDs
%%      ),
%%      lists:map(fun(Pkt) ->
%%        {ID, IDInt, El} = Pkt,
%%        #forwarded{sub_els = [Msg]} = El,
%%        Msg2 = clean_reference(Msg),
%%        Xtag = xmpp:get_subtag(Msg2, #xmppreference{type = <<"groupchat">>}),
%%        OldCard = xmpp:get_subtag(Xtag, #xabbergroupchat_user_card{}),
%%        CurrentUserID = OldCard#xabbergroupchat_user_card.id,
%%        IDNewCard = lists:keyfind(CurrentUserID,1,UserCards),
%%        case IDNewCard of
%%          false ->
%%            Pkt;
%%          _ ->
%%            {CurrentUserID, NewCard} = IDNewCard,
%%            Pkt2 = strip_reference_elements(Msg),
%%            Sub2 = xmpp:get_els(Pkt2),
%%            X = Xtag#xmppreference{type = <<"groupchat">>, sub_els = [NewCard]},
%%            XEl = xmpp:encode(X),
%%            Sub3 = [XEl|Sub2],
%%            {ID,IDInt,El#forwarded{sub_els = [Msg#message{sub_els = Sub3}]}}
%%        end end, Msgs
%%      )
%%  end.

change_all_messages(ChatandUsers, Msgs) ->
  lists:map(fun(Pkt) ->
    {_ID, _IDInt, El} = Pkt,
    #forwarded{sub_els = [Msg]} = El,
    Msg2 = clean_reference(Msg),
    X = xmpp:get_subtag(Msg2, #xmppreference{type = <<"groupchat">>}),
    case X of
      false ->
        Pkt;
      _ ->
        Card = xmpp:get_subtag(X, #xabbergroupchat_user_card{}),
        change_message(Card,ChatandUsers,Pkt)
    end
            end
    , Msgs
  ).

change_message(false,_ChatandUsers,Pkt) ->
  Pkt;
change_message(OldCard,ChatandUsers,Pkt) ->
  {ID, IDInt, El} = Pkt,
  #forwarded{sub_els = [Msg]} = El,
  Msg2 = clean_reference(Msg),
  Xtag = xmpp:get_subtag(Msg2, #xmppreference{type = <<"groupchat">>}),
  CurrentUserID = OldCard#xabbergroupchat_user_card.id,
  Chat = jid:to_string(jid:remove_resource(Msg#message.from)),
  {Chat,UserCards} = lists:keyfind(Chat,1,ChatandUsers),
  IDNewCard = lists:keyfind(CurrentUserID,1,UserCards),
  case IDNewCard of
      false ->
        Pkt;
      _ ->
        {CurrentUserID, NewCard} = IDNewCard,
        Pkt2 = strip_reference_elements(Msg),
        Sub2 = xmpp:get_els(Pkt2),
        X = Xtag#xmppreference{type = <<"groupchat">>, sub_els = [NewCard]},
        XEl = xmpp:encode(X),
        Sub3 = [XEl|Sub2],
        {ID,IDInt,El#forwarded{sub_els = [Msg#message{sub_els = Sub3}]}}
    end.


shift_references(Pkt, Length) ->
  Els = xmpp:get_els(Pkt),
  NewEls = lists:filtermap(
    fun(El) ->
      Name = xmpp:get_name(El),
      NS = xmpp:get_ns(El),
      if (Name == <<"reference">> andalso NS == ?NS_REFERENCE_0) ->
        try xmpp:decode(El) of
          #xmppreference{type = Type, 'begin' = undefined, 'end' = undefined, uri = Uri, sub_els = Sub} ->
            {true, #xmppreference{type = Type, 'begin' = undefined, 'end' = undefined, uri = Uri, sub_els = Sub}};
          #xmppreference{type = Type, 'begin' = Begin, 'end' = End, uri = Uri, sub_els = Sub} ->
            {true, #xmppreference{type = Type, 'begin' = Begin + Length, 'end' = End + Length, uri = Uri, sub_els = Sub}}
        catch _:{xmpp_codec, _} ->
          false
        end;
        true ->
          true
      end
    end, Els),
  NewEls.

%% Block to write

send_message_no_permission_to_write(User,Message) ->
  Last = get_last(User),
  case Last of
    [] ->
      write_new_ts(User),
      ejabberd_router:route(Message);
    [Blocked] ->
      check_and_send(Blocked,Message)
  end.

check_and_send(Last,Message) ->
  Now = seconds_since_epoch(0),
  LastTime = Last#groupchat_blocked_user.timestamp,
  User = Last#groupchat_blocked_user.user,
  Diff = Now - LastTime,
  case Diff of
    _  when Diff > 60 ->
      clean_last(Last),
      ejabberd_router:route(Message),
      write_new_ts(User);
    _ ->
      ok
  end.

get_last(User) ->
  FN = fun()->
    mnesia:match_object(groupchat_blocked_user,
      {groupchat_blocked_user, User, '_'},
      read) end,
  {atomic,Last} = mnesia:transaction(FN),
  Last.

clean_last(Last) ->
  mnesia:dirty_delete_object(Last).

write_new_ts(User) ->
  TS = seconds_since_epoch(0),
  B = #groupchat_blocked_user{user = User, timestamp = TS},
  mnesia:dirty_write(B).

-spec seconds_since_epoch(integer()) -> non_neg_integer().
seconds_since_epoch(Diff) ->
  {Mega, Secs, _} = os:timestamp(),
  Mega * 1000000 + Secs + Diff.