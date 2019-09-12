%%%-------------------------------------------------------------------
%%% File    : mod_groupchat_iq_handler.erl
%%% Author  : Andrey Gagarin <andrey.gagarin@redsolution.com>
%%% Purpose : Handle iq for group chats
%%% Created : 9 May 2018 by Andrey Gagarin <andrey.gagarin@redsolution.com>
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

-module(mod_groupchat_iq_handler).
-author('andrey.gagarin@redsolution.com').
-behavior(gen_mod).
-include("ejabberd.hrl").
-include("logger.hrl").
-include("xmpp.hrl").
-export([start/2, stop/1, depends/2, mod_options/1, mod_opt_type/1,disco_sm_features/5]).
-export([process_groupchat/1,process_iq/1,make_action/1]).

start(Host, _Opts) ->
  ejabberd_hooks:add(disco_sm_features, Host, ?MODULE, disco_sm_features, 50),
  gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_GROUPCHAT, ?MODULE, process_groupchat),
  ok.

stop(Host) ->
  ejabberd_hooks:delete(disco_sm_features, Host, ?MODULE, disco_sm_features, 50),
  gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_GROUPCHAT),
  ok.

depends(_Host, _Opts) ->
  [].

mod_opt_type(xabber_global_indexs) ->
  fun (L) -> lists:map(fun iolist_to_binary/1, L) end.

mod_options(_Host) -> [
  {xabber_global_indexs, []}
].

process_iq(#iq{to = To} = Iq) ->
  process_iq(mod_groupchat_sql:search_for_chat(To#jid.server,To#jid.user),Iq).

process_iq({selected,[]},Iq) ->
  Iq;
process_iq({selected,[_Name]},Iq) ->
  make_action(Iq).

process_groupchat(#iq{type = set, to = To, from = From,
  sub_els = [#xabbergroupchat_create{name = undefined, anonymous= undefined, localpart= undefined,
    searchable = undefined, description = undefined, model = undefined, pinned = undefined, domains = undefined, contacts = undefined, peer = Peer}]} = Iq) ->
  Creator = jid:to_string(jid:remove_resource(From)),
  Server = To#jid.lserver,
  Result = ejabberd_hooks:run_fold(groupchat_peer_to_peer, Server, [], [Server,Creator,Peer]),
  case Result of
    {ok,Created} ->
      xmpp:make_iq_result(Iq, Created);
    {exist,ExistedChat} ->
      ExistedChatJID = jid:from_string(ExistedChat),
      NewSub = [#xabbergroupchat_x{jid = ExistedChatJID}],
      NewIq = xmpp:set_els(Iq,NewSub),
      xmpp:make_error(NewIq, xmpp:err_conflict());
    _ ->
      xmpp:make_error(Iq, xmpp:err_not_allowed(<<"You have no permission to invite">>,<<"en">>))
  end;
process_groupchat(#iq{type = set, to = To, from = From, lang = Lang,
  sub_els = [#xabbergroupchat_create{name = Name, anonymous=Anon, localpart=LocalJid,
  searchable = Searchable, description = Description, model = Model, pinned = Message, domains = Domains, contacts = Contacts, peer = undefined} = X]} = Iq) ->
  Creator = From#jid.luser,
  Server = To#jid.lserver,
  Host = From#jid.lserver,
  case mod_groupchat_inspector:create_chat(Creator,Host,Server,Name,Anon,LocalJid,Searchable,Description,Model,Message,Contacts,Domains) of
    {ok,Created} ->
      ChatJID = jid:make(LocalJid,Server,<<"Groupchat">>),
      User = jid:to_string(jid:remove_resource(From)),
      mod_groupchat_presence:send_info_to_index(Server,ChatJID),
      mod_groupchat_service_message:created_chat(X,User,ChatJID,Lang),
      xmpp:make_iq_result(Iq, Created);
    exist ->
      xmpp:make_error(Iq, xmpp:err_conflict());
    fail ->
      xmpp:make_error(Iq, xmpp:err_not_allowed());
    _ ->
      xmpp:make_error(Iq, xmpp:err_not_allowed())
  end;
process_groupchat(#iq{type=get, to= To, from = From,
  sub_els = [#xabbergroupchat_search{name = Name, anonymous = Anon, description = Desc, model = Model}]} = Iq) ->
  Server = To#jid.lserver,
  UserHost = From#jid.lserver,
  UserJid = jid:to_string(jid:remove_resource(From)),
  Query = mod_groupchat_inspector:search(Server,Name,Anon,Model,Desc,UserJid,UserHost),
  xmpp:make_iq_result(Iq,Query);
process_groupchat(_Iq) ->
  xmpp:make_iq_result(_Iq).

make_action(#iq{to = To, from = From, type = get, sub_els = [#xmlel{name = <<"query">>,
  attrs = [{<<"xmlns">>,<<"http://xabber.com/protocol/groupchat#block">>}],
  children = []}]} = Iq) ->
  Server = To#jid.lserver,
  Chat = jid:to_string(jid:remove_resource(To)),
  User = jid:to_string(jid:remove_resource(From)),
  RightToBlock = mod_groupchat_restrictions:is_permitted(<<"block-participants">>,User,Chat),
  case mod_groupchat_inspector_sql:check_user(User,Server,Chat) of
    exist when RightToBlock == yes ->
      ejabberd_router:route(xmpp:make_iq_result(Iq,mod_groupchat_block:query(To)));
    _ ->
      ejabberd_router:route(xmpp:make_error(Iq, xmpp:err_not_allowed()))
  end;
make_action(#iq{to = To, type = set, sub_els = [#xmlel{name = <<"unblock">>,
  attrs = [{<<"xmlns">>,<<"http://xabber.com/protocol/groupchat#block">>}]}]} = Iq) ->
  Server = To#jid.lserver,
  Result = ejabberd_hooks:run_fold(groupchat_unblock_hook, Server, [], [Iq]),
  case Result of
    not_ok ->
      ejabberd_router:route(xmpp:make_error(Iq,xmpp:err_not_allowed()));
    ok ->
      ejabberd_router:route(xmpp:make_iq_result(Iq))
  end;
make_action(#iq{to = To, type = set, sub_els = [#xmlel{name = <<"block">>,
  attrs = [{<<"xmlns">>,<<"http://xabber.com/protocol/groupchat#block">>}]}]} = Iq) ->
  Server = To#jid.lserver,
  Result = ejabberd_hooks:run_fold(groupchat_block_hook, Server, [], [Iq]),
  case Result of
    not_ok ->
      ejabberd_router:route(xmpp:make_error(Iq,xmpp:err_not_allowed()));
    ok ->
      ejabberd_router:route(xmpp:make_iq_result(Iq))
  end;
make_action(#iq{to = To,from = From, type = set, sub_els = [#xmlel{name = <<"query">>,
  attrs = [{<<"xmlns">>,<<"http://xabber.com/protocol/groupchat#rights">>}], children = _Children }] = Els} = Iq) ->
  DecEls = lists:map(fun(N)-> xmpp:decode(N) end, Els),
  Query = lists:keyfind(xabbergroupchat_query_rights,1,DecEls),
  User = jid:to_string(jid:remove_resource(From)),
  Chat = jid:to_string(jid:remove_resource(To)),
  Permission = mod_groupchat_restrictions:is_permitted(<<"administrator">>,User,Chat),
  Result = case Query of
             false ->
               xmpp:err_not_allowed();
             _ when Permission == yes->
               mod_groupchat_default_restrictions:restrictions(Query,Iq);
             _ ->
               xmpp:err_not_allowed()
           end,
  ejabberd_router:route(Result);
make_action(#iq{to = To, lang = Lang, type = get, sub_els = [#xmlel{name = <<"query">>,
  attrs = [{<<"xmlns">>,<<"http://xabber.com/protocol/groupchat#rights">>}],
  children = []}]} = Iq) ->
  Chat = jid:to_string(jid:remove_resource(To)),
  {selected,_Tables,Permissions} = mod_groupchat_restrictions:show_permissions(To#jid.lserver,Chat),
  TranslatedPermissions = lists:map(fun(N) ->
    [Name,Desc,Type,Action] = N,
    [Name,translate:translate(Lang,Desc),Type,Action] end, Permissions
  ),
  ejabberd_router:route(xmpp:make_iq_result(Iq,query_chat(TranslatedPermissions)));

make_action(#iq{to = To, from = From, lang = Lang, type = get, sub_els = [#xmlel{name = <<"query">>,
  attrs = [{<<"xmlns">>,<<"http://xabber.com/protocol/groupchat#members">>},{<<"id">>, UserId}]
  }]} = Iq) ->
  Server = To#jid.lserver,
  Chat = jid:to_string(jid:remove_resource(To)),
  UserRequester = jid:to_string(jid:remove_resource(From)),
  User = case UserId of
           <<>> ->
             jid:to_string(jid:remove_resource(From));
           _ ->
             mod_groupchat_inspector:get_user_by_id(Server,Chat,UserId)
         end,
  case mod_groupchat_inspector:user_rights(Server,User,Chat,UserRequester,Lang) of
    not_ok ->
      ejabberd_router:route(xmpp:make_error(Iq, xmpp:err_item_not_found()));
    {ok,Query} when User =/= none ->
      ejabberd_router:route(xmpp:make_iq_result(Iq,Query));
    _  when User == none ->
      ejabberd_router:route(xmpp:make_error(Iq, xmpp:err_item_not_found()));
    _ ->
      ejabberd_router:route(xmpp:make_error(Iq, xmpp:err_not_allowed()))
  end;
make_action(#iq{from = From, to = To, type = get, sub_els = [#xmlel{name = <<"query">>,
  attrs = [{<<"xmlns">>,<<"http://xabber.com/protocol/groupchat#members">>},{<<"version">>,_Version}],
  children = []}]} = Iq) ->
  Server = To#jid.lserver,
  Chat = jid:to_string(jid:remove_resource(To)),
  User = jid:to_string(jid:remove_resource(From)),
  case mod_groupchat_inspector_sql:check_user(User,Server,Chat) of
    exist ->
      mod_groupchat_users:get_users_list_with_version(Iq);
    _ ->
      ejabberd_router:route(xmpp:make_error(Iq, xmpp:err_not_allowed()))
  end;
make_action(#iq{from = From, to = To, type = get, sub_els = [#xmlel{name = <<"query">>,
  attrs = [{<<"xmlns">>,<<"http://xabber.com/protocol/groupchat#members">>}],
  children = []}]} = Iq) ->
  Server = To#jid.lserver,
  Chat = jid:to_string(jid:remove_resource(To)),
  User = jid:to_string(jid:remove_resource(From)),
  case mod_groupchat_inspector_sql:check_user(User,Server,Chat) of
    exist ->
      mod_groupchat_users:get_users_from_chat(Iq);
    _ ->
      ejabberd_router:route(xmpp:make_error(Iq, xmpp:err_not_allowed()))
  end;
make_action(#iq{lang = Lang, from = From, to = To, type = set, sub_els = [#xmlel{ name = <<"query">> ,
  attrs = [{<<"xmlns">>,<<"http://xabber.com/protocol/groupchat#members">>}]}] = Sub } = Iq) ->
  Server = To#jid.lserver,
  Chat = jid:to_string(jid:remove_resource(To)),
  Server = To#jid.lserver,
  Admin = jid:to_string(jid:remove_resource(From)),
  [Els|_Rest] = Sub,
  E = xmpp:decode(Els),
  case ejabberd_hooks:run_fold(groupchat_update_user_hook, Server, [], [{Server,Chat,Admin,E,Lang}]) of
    ok ->
      ejabberd_router:route(xmpp:make_iq_result(Iq));
    _ ->
      ejabberd_router:route(xmpp:make_error(Iq, xmpp:err_not_allowed()))
  end;
make_action(#iq{type = get, sub_els = [#xmlel{name = <<"query">>,
  attrs = [{<<"xmlns">>,<<"jabber:iq:version">>}]}]} = Iq) ->
  Result = mod_groupchat_vcard:give_client_vesrion(),
  ejabberd_router:route(xmpp:make_iq_result(Iq,Result));
make_action(#iq{type = get, sub_els = [#xmlel{name = <<"query">>,
  attrs = [{<<"xmlns">>,<<"jabber:iq:last">>}]}]} = Iq) ->
  Result = mod_groupchat_vcard:iq_last(),
  ejabberd_router:route(xmpp:make_iq_result(Iq,Result));
make_action(#iq{type = get, sub_els = [#xmlel{name = <<"time">>,
  attrs = [{<<"xmlns">>,<<"urn:xmpp:time">>}]}]} = Iq) ->
  R = mod_time:process_local_iq(Iq),
  ejabberd_router:route(R);
make_action(#iq{to=To, type = get, sub_els = [#xmlel{name = <<"vCard">>, 
            attrs = [{<<"xmlns">>,<<"vcard-temp">>}]}]} = Iq) ->
  Chat = To#jid.luser,
  Server = To#jid.lserver,
  Vcard = mod_vcard:get_vcard(Chat,Server),
  A = case length(Vcard) of
        0 ->
          #vcard_temp{};
        _ ->
          [F|_R] = Vcard,
          F
      end,
  ejabberd_router:route(xmpp:make_iq_result(Iq,A));
make_action(#iq{type = result, sub_els = [#xmlel{name = <<"vCard">>,
  attrs = [{<<"xmlns">>,<<"vcard-temp">>}], children = _Children}]} = Iq) ->
  mod_groupchat_vcard:handle(Iq);
make_action(#iq{type = set, to = To, from = From,
  sub_els = [#xmlel{name = <<"update">>, attrs = [
  {<<"xmlns">>,?NS_GROUPCHAT}], children = _Children} = X]} = Iq) ->
  User = jid:to_string(jid:remove_resource(From)),
  Server = To#jid.lserver,
  ChatJid = jid:to_string(jid:remove_resource(To)),
  IsOwner = mod_groupchat_restrictions:is_owner(Server,ChatJid,User),
  case mod_groupchat_restrictions:is_permitted(<<"administrator">>,User,ChatJid) of
    yes ->
      Xa = xmpp:decode(X),
      NewOwner = Xa#xabbergroupchat_update.owner,
      case NewOwner of
        undefined ->
          case mod_groupchat_inspector:update_chat(Server,To,ChatJid,Xa) of
            ok ->
              ejabberd_router:route(xmpp:make_iq_result(Iq));
            _ ->
              drop
          end;
        _  when IsOwner == yes->
          Expires = <<"1000 years">>,
          Rule1 = <<"owner">>,
          Rule2 = <<"change-restriction">>,
          Rule3 = <<"Block participants">>,
          Rule4 = <<"remove-member">>,
          Rule5 = <<"block-member">>,
          IssuedBy = User,
          mod_groupchat_restrictions:insert_rule(Server,ChatJid,NewOwner,Rule1,Expires,IssuedBy),
          mod_groupchat_restrictions:insert_rule(Server,ChatJid,NewOwner,Rule2,Expires,IssuedBy),
          mod_groupchat_restrictions:insert_rule(Server,ChatJid,NewOwner,Rule3,Expires,IssuedBy),
          mod_groupchat_restrictions:insert_rule(Server,ChatJid,NewOwner,Rule4,Expires,IssuedBy),
          mod_groupchat_restrictions:insert_rule(Server,ChatJid,NewOwner,Rule5,Expires,IssuedBy),
          mod_groupchat_restrictions:delete_rule(Server,ChatJid,User,<<"owner">>)
      end;
    _ ->
      ejabberd_router:route(xmpp:make_error(Iq,xmpp:err_not_allowed()))
  end;
make_action(#iq{type = set, sub_els = [#xmlel{name = <<"pubsub">>,
  attrs = [{<<"xmlns">>,<<"http://jabber.org/protocol/pubsub">>}]}]} = Iq) ->
  mod_groupchat_vcard:handle_pubsub(Iq);
make_action(#iq{type = get, sub_els = [#xmlel{name = <<"pubsub">>,
  attrs = [{<<"xmlns">>,<<"http://jabber.org/protocol/pubsub">>}]}]} = Iq) ->
  mod_groupchat_vcard:handle_request(Iq);
make_action(#iq{type = set, sub_els = [#xmlel{name = <<"invite">>,
  attrs = [{<<"xmlns">>,<<"http://xabber.com/protocol/groupchat#invite">>}]}]} = Iq) ->
  #iq{from = From, to = To, sub_els = Sub} = Iq,
  Server = To#jid.lserver,
  Admin = jid:to_string(jid:remove_resource(From)),
  Chat = jid:to_string(jid:remove_resource(To)),
  DecEls = lists:map(fun(N)-> xmpp:decode(N) end, Sub),
  Invite = lists:keyfind(xabbergroupchat_invite,1,DecEls),
  #xabbergroupchat_invite{jid = User, reason = _Reason, send = _Send} = Invite,
  Result = ejabberd_hooks:run_fold(groupchat_invite_hook, Server, [], [{Admin,Chat,Server,Invite}]),
  case Result of
    forbidden ->
      ejabberd_router:route(xmpp:make_error(Iq,xmpp:err_not_allowed(<<"You have no permission to invite">>,<<>>)));
    ok ->
      ejabberd_router:route(xmpp:make_iq_result(Iq));
    exist ->
      ResIq = xmpp:make_error(Iq,xmpp:err_conflict(<<"User ",User/binary," was already invited">>,<<>>)),
      ejabberd_router:route(ResIq);
    not_ok ->
      ejabberd_router:route(xmpp:make_error(Iq,xmpp:err_not_allowed(<<"User ",User/binary," is in ban list">>,<<>>)))
  end;
make_action(#iq{type = get, lang = Lang, sub_els = [#xmlel{name = <<"query">>,
  attrs = [{<<"xmlns">>,<<"http://xabber.com/protocol/groupchat#invite">>}]}]} = Iq) ->
  #iq{from = From, to = To} = Iq,
  Server = To#jid.lserver,
  Admin = jid:to_string(jid:remove_resource(From)),
  Chat = jid:to_string(jid:remove_resource(To)),
  case mod_groupchat_restrictions:is_permitted(<<"block-participants">>,Admin,Chat) of
    yes ->
      Query = mod_groupchat_inspector:get_invited_users(Server,Chat),
      ResIq = xmpp:make_iq_result(Iq,Query),
      ejabberd_router:route(ResIq);
    no ->
      ejabberd_router:route(xmpp:make_error(Iq,xmpp:err_not_allowed(<<"You have no permission to see list of invited users">>,Lang)))
  end;
make_action(#iq{to = To, type = get, sub_els = [#xmlel{name = <<"query">>,
  attrs = [{<<"xmlns">>,<<"http://jabber.org/protocol/disco#items">>}]}]} = Iq) ->
  Chat = jid:to_string(jid:remove_resource(To)),
  Data = #xmlel{name = <<"item">>, attrs = [{<<"jid">>,Chat},{<<"node">>,<<"urn:xmpp:avatar:data">>}]},
  MetaData = #xmlel{name = <<"item">>, attrs = [{<<"jid">>,Chat},{<<"node">>,<<"urn:xmpp:avatar:metadata">>}]},
  Children = [Data,MetaData],
  Query = #xmlel{name = <<"query">>, attrs = [{<<"xmlns">>,<<"http://jabber.org/protocol/disco#items">>}],
  children = Children},
  ejabberd_router:route(xmpp:make_iq_result(Iq,Query));
make_action(#iq{type = set, sub_els = [#xmlel{name = <<"revoke">>,
  attrs = [{<<"xmlns">>,<<"http://xabber.com/protocol/groupchat#invite">>}]}]} = Iq) ->
  #iq{from = From, to = To,sub_els = Sub} = Iq,
  Server = To#jid.lserver,
  Admin = jid:to_string(jid:remove_resource(From)),
  Chat = jid:to_string(jid:remove_resource(To)),
  DecEls = lists:map(fun(N)-> xmpp:decode(N) end, Sub),
  Revoke = lists:keyfind(xabbergroupchat_revoke,1,DecEls),
  #xabbergroupchat_revoke{jid = User} = Revoke,
  case mod_groupchat_restrictions:is_permitted(<<"administrator">>,Admin,Chat) of
    yes ->
      case mod_groupchat_inspector:revoke(Server,User,Chat) of
        ok ->
          ResIq = xmpp:make_iq_result(Iq),
          ejabberd_router:route(ResIq);
        _ ->
          Err = xmpp:err_item_not_found(),
          ejabberd_router:route(xmpp:make_error(Iq,Err))
      end;
    no ->
      ejabberd_router:route(xmpp:make_error(Iq,xmpp:err_not_allowed(<<"You have no permission to see list of invited users">>,<<"en">>)))
  end;
make_action(#iq{to = To,type = get, sub_els = [#xmlel{name = <<"query">>,
  attrs = [{<<"xmlns">>,<<"http://jabber.org/protocol/disco#info">>}]}]} = Iq) ->
  ChatJID = jid:to_string(jid:tolower(jid:remove_resource(To))),
  Server = To#jid.lserver,
  {selected,[{Name,Anonymous,_Search,Model,Desc,_Message,_ContactList,_DomainList}]} =
    mod_groupchat_sql:get_information_of_chat(ChatJID,Server),
  Identity = #xmlel{name = <<"identity">>,
  attrs = [{<<"category">>,<<"conference">>},{<<"type">>,<<"groupchat">>},{<<"name">>,Name}]},
  FeatureList = [<<"urn:xmpp:avatar:metadata">>,<<"urn:xmpp:avatar:data">>,
    <<"jabber:iq:last">>,<<"urn:xmpp:time">>,<<"jabber:iq:version">>,<<"urn:xmpp:avatar:metadata+notify">>,
    <<"http://xabber.com/protocol/groupchat">>,<<"http://xabber.com/protocol/groupchat#voice-permissions">>,
  <<"http://jabber.org/protocol/disco#info">>,<<"http://jabber.org/protocol/disco#items">>],
  Features = lists:map(fun(N) ->
    #xmlel{name = <<"feature">>,
      attrs = [{<<"var">>,N}]} end, FeatureList
  ),
  X = x_element_chat(Desc,Anonymous,Model),
  Els = [Identity]++Features++[X],
  Q = query_disco_info(Els),
  ejabberd_router:route(xmpp:make_iq_result(Iq,Q));
make_action(#iq{type = set, sub_els = [#xmlel{name = <<"query">>, attrs = [{<<"xmlns">>,<<"urn:xmpp:mam:2">>},{<<"queryid">>,_QID}]}]} = Iq) ->
  process_mam_iq(Iq);
make_action(#iq{type = set, sub_els = [#xmlel{name = <<"query">>, attrs = [{<<"xmlns">>,<<"urn:xmpp:mam:1">>},{<<"queryid">>,_QID}]}]} = Iq) ->
  process_mam_iq(Iq);
make_action(#iq{type = set, sub_els = [#xmlel{name = <<"query">>, attrs = [{<<"xmlns">>,<<"urn:xmpp:mam:2">>}]}]} = Iq) ->
  process_mam_iq(Iq);
make_action(#iq{type = set, sub_els = [#xmlel{name = <<"query">>, attrs = [{<<"xmlns">>,<<"urn:xmpp:mam:1">>}]}]} = Iq) ->
  process_mam_iq(Iq);
make_action(#iq{from = From, to = To, type = set,
  sub_els =
  [#xmlel{name = <<"activate">>, attrs = [{<<"xmlns">>,?NS_XABBER_REWRITE}]}] = SubEls } = IQ) ->
  User = jid:to_string(jid:remove_resource(From)),
  Chat = jid:to_string(jid:remove_resource(To)),
  Server = To#jid.lserver,
  SubDecoded = lists:map(fun(N) -> xmpp:decode(N) end, SubEls ),
  X = lists:keyfind(xabber_retract_activate,1,SubDecoded),
  #xabber_retract_activate{version = Version, 'less-than' = Less} = X,
  Result = ejabberd_hooks:run_fold(retract_query, Server, [], [{Server,User,Chat,Version,Less}]),
  case Result of
    ok ->
      ejabberd_router:route(xmpp:make_iq_result(IQ));
    _ ->
      ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_not_allowed()))
  end;
make_action(#iq{from = From, to = To, type = set,
  sub_els =
  [#xmlel{name = <<"activate">>, attrs = [{<<"xmlns">>,?NS_XABBER_REWRITE},{<<"version">>,_V}]}] = SubEls } = IQ) ->
  User = jid:to_string(jid:remove_resource(From)),
  Chat = jid:to_string(jid:remove_resource(To)),
  Server = To#jid.lserver,
  SubDecoded = lists:map(fun(N) -> xmpp:decode(N) end, SubEls ),
  X = lists:keyfind(xabber_retract_activate,1,SubDecoded),
  #xabber_retract_activate{version = Version, 'less-than' = Less} = X,
  Result = ejabberd_hooks:run_fold(retract_query, Server, [], [{Server,User,Chat,Version,Less}]),
  case Result of
    ok ->
      ejabberd_router:route(xmpp:make_iq_result(IQ));
    _ ->
      ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_not_allowed()))
  end;
make_action(#iq{from = From, to = To, type = set,
  sub_els =
  [#xmlel{name = <<"activate">>, attrs = [{<<"xmlns">>,?NS_XABBER_REWRITE},{<<"version">>,_V},{<<"less_than">>,_L}]}] = SubEls } = IQ) ->
  User = jid:to_string(jid:remove_resource(From)),
  Chat = jid:to_string(jid:remove_resource(To)),
  FromChat = jid:replace_resource(To,<<"Groupchat">>),
  Server = To#jid.lserver,
  SubDecoded = lists:map(fun(N) -> xmpp:decode(N) end, SubEls ),
  X = lists:keyfind(xabber_retract_activate,1,SubDecoded),
  #xabber_retract_activate{version = Version, 'less-than' = Less} = X,
  Result = ejabberd_hooks:run_fold(retract_query, Server, [], [{Server,User,Chat,Version,Less}]),
  case Result of
    ok ->
      ejabberd_router:route(xmpp:make_iq_result(IQ));
    too_much ->
      CurrentVersion = mod_groupchat_retract:get_version(Server,Chat),
      Invalidate = #xabber_retract_invalidate{version = CurrentVersion},
      ejabberd_router:route(#message{from = FromChat, to = From, id = randoms:get_string(), type = headline, sub_els = [Invalidate]});
    _ ->
      ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_not_allowed()))
  end;
make_action(#iq{from = From, to = To, type = set,
  sub_els =
  [#xmlel{name = <<"retract-message">>, attrs = [{<<"xmlns">>,?NS_XABBER_REWRITE},{<<"id">>,_IDRaw},{<<"symmetric">>,_Sym},{<<"by">>,_By}]}] = SubEls } = IQ) ->
  User = jid:to_string(jid:remove_resource(From)),
  Chat = jid:to_string(jid:remove_resource(To)),
  Server = To#jid.lserver,
  SubDecoded = lists:map(fun(N) -> xmpp:decode(N) end, SubEls ),
  X = lists:keyfind(xabber_retract_message,1,SubDecoded),
  ID = X#xabber_retract_message.id,
  Symmetric = X#xabber_retract_message.symmetric,
  case Symmetric of
    true ->
      Version = binary_to_integer(mod_groupchat_retract:get_version(Server,Chat)) + 1,
      Retract = #xabber_retract_message{
        symmetric = true,
        id = ID,
        by = jid:remove_resource(From),
        conversation = jid:remove_resource(To),
        version = Version,
        xmlns = ?NS_XABBER_REWRITE_NOTIFY
      },
      Result = ejabberd_hooks:run_fold(retract_message, Server, [], [{Server,User,Chat,ID,Retract,Version}]),
      case Result of
        ok ->
          ejabberd_router:route(xmpp:make_iq_result(IQ));
        no_message ->
          ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_item_not_found()));
        _ ->
          ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_not_allowed()))
      end;
    _ ->
      ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_bad_request()))
  end;
make_action(#iq{from = From, to = To, type = set,
  sub_els =
  [#xmlel{name = <<"retract-user">>, attrs = [{<<"xmlns">>,?NS_XABBER_REWRITE},{<<"id">>,_IDRaw},{<<"symmetric">>,_Sym}]}] = SubEls } = IQ) ->
  User = jid:to_string(jid:remove_resource(From)),
  Chat = jid:to_string(jid:remove_resource(To)),
  Server = To#jid.lserver,
  SubDecoded = lists:map(fun(N) -> xmpp:decode(N) end, SubEls ),
  X = lists:keyfind(xabber_retract_user,1,SubDecoded),
  ID = X#xabber_retract_user.id,
  Symmetric = X#xabber_retract_user.symmetric,
  case Symmetric of
    true ->
      Version = binary_to_integer(mod_groupchat_retract:get_version(Server,Chat)) + 1,
      Retract = #xabber_retract_user{
        id = ID,
        symmetric = true,
        conversation = jid:remove_resource(To),
        by = jid:remove_resource(From),
        version = Version,
        xmlns = ?NS_XABBER_REWRITE_NOTIFY
      },
      Result = ejabberd_hooks:run_fold(retract_user, Server, [], [{Server,User,Chat,ID,Retract,Version}]),
      case Result of
        ok ->
          ejabberd_router:route(xmpp:make_iq_result(IQ));
        no_user ->
          ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_item_not_found()));
        _ ->
          ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_not_allowed()))
      end;
    _ ->
      ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_bad_request()))
  end;
make_action(#iq{from = From, to = To, type = set,
  sub_els =
  [#xmlel{name = <<"retract-all">>, attrs = [{<<"xmlns">>,?NS_XABBER_REWRITE},{<<"symmetric">>,_Sym}]}] = SubEls } = IQ) ->
  User = jid:to_string(jid:remove_resource(From)),
  Chat = jid:to_string(jid:remove_resource(To)),
  Server = To#jid.lserver,
  SubDecoded = lists:map(fun(N) -> xmpp:decode(N) end, SubEls ),
  X = lists:keyfind(xabber_retract_all,1,SubDecoded),
  Symmetric = X#xabber_retract_all.symmetric,
  case Symmetric of
    true ->
      Version = binary_to_integer(mod_groupchat_retract:get_version(Server,Chat)) + 1,
      Retract = #xabber_retract_all{
        symmetric = true,
        conversation = jid:remove_resource(To),
        version = Version,
        xmlns = ?NS_XABBER_REWRITE_NOTIFY
      },
      Result = ejabberd_hooks:run_fold(retract_all, Server, [], [{Server,User,Chat,<<"0000">>,Retract,Version}]),
      case Result of
        ok ->
          ejabberd_router:route(xmpp:make_iq_result(IQ));
        _ ->
          ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_not_allowed()))
      end;
    _ ->
      ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_bad_request()))
  end;
make_action(#iq{from = From, to = To, type = set,
  sub_els =
  [#xmlel{name = <<"replace">>, attrs = [{<<"xmlns">>,?NS_XABBER_REWRITE},{<<"id">>,ID}]}] = SubEls } = IQ) ->
  User = jid:to_string(jid:remove_resource(From)),
  Chat = jid:to_string(jid:remove_resource(To)),
  Server = To#jid.lserver,
  SubDecoded = lists:map(fun(N) -> xmpp:decode(N) end, SubEls ),
  X = lists:keyfind(xabber_replace,1,SubDecoded),
  Message = X#xabber_replace.xabber_replace_message,
  Text = Message#xabber_replace_message.body,
  Version = binary_to_integer(mod_groupchat_retract:get_version(Server,Chat)) + 1,
  Replaced = #replaced{stamp = erlang:timestamp()},
  StanzaID = #stanza_id{id = ID, by = jid:remove_resource(To)},
  NewMessage = Message#xabber_replace_message{replaced = Replaced, stanza_id = StanzaID},
  Replace = #xabber_replace{
    xabber_replace_message = NewMessage,
    id = binary_to_integer(ID),
    version = Version,
    conversation = jid:remove_resource(To),
    xmlns = ?NS_XABBER_REWRITE_NOTIFY
  },
  Result = ejabberd_hooks:run_fold(replace_message, Server, [], [{Server,User,Chat,ID,Text,Replace,Version}]),
  case Result of
    ok ->
      ejabberd_router:route(xmpp:make_iq_result(IQ));
    _ ->
      ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_not_allowed()))
  end;
make_action(#iq{from = From, to = To, type = get,
  sub_els =
  [#xmlel{name = <<"query">>, attrs = [{<<"xmlns">>,?NS_XABBER_SYNCHRONIZATION},{<<"stamp">>,Stamp}]}]} = IQ) ->
  User = jid:to_string(jid:remove_resource(From)),
  Chat = jid:to_string(jid:remove_resource(To)),
  LServer = To#jid.lserver,
  Result = ejabberd_hooks:run_fold(synchronization_request, LServer, [], [LServer,User,Chat,Stamp]),
  case Result of
    {ok,Sync} ->
      ?DEBUG("Send iq ~p~n res ~p",[IQ,Sync]),
      ejabberd_router:route(xmpp:make_iq_result(IQ,Sync));
    _ ->
      ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_not_allowed()))
  end;
make_action(#iq{from = UserJID, to = ChatJID, type = result, sub_els = [#pubsub{items = #ps_items{node = <<"urn:xmpp:avatar:metadata">>, items = [#ps_item{id = Hash, sub_els = Subs}]}}]}) ->
  ?DEBUG("Catch pubsub meta ~p",[Subs]),
  MD = lists:map(fun(E) -> xmpp:decode(E) end, Subs),
  Meta = lists:keyfind(avatar_meta,1,MD),
  mod_groupchat_vcard:handle_pubsub(ChatJID,UserJID,Meta);
make_action(#iq{from = UserJID, to = ChatJID, type = result, sub_els = [#pubsub{items = #ps_items{node = <<"urn:xmpp:avatar:data">>, items = [#ps_item{id = Hash, sub_els = Subs}]}}]}) ->
  ?DEBUG("Catch pubsub data result1 iq ~p",[Hash]),
  MD = lists:map(fun(E) -> xmpp:decode(E) end, Subs),
  Data = lists:keyfind(avatar_data,1,MD),
  mod_groupchat_vcard:handle_pubsub(ChatJID,UserJID,Hash,Data);
make_action(#iq{type = result, sub_els = [#xmlel{name = <<"pubsub">>, attrs = _Attrs, children = _Children}] = SubEls} = IQ) ->
  ?DEBUG("Catch pubsub result2 iq ~p",[IQ]),
  SubElsDec = lists:map(fun(El) -> xmpp:decode(El) end, SubEls),
  DECIQ = IQ#iq{sub_els = SubElsDec},
  make_action(DECIQ);
make_action(#iq{type = result} = IQ) ->
  ?DEBUG("Drop result iq ~p",[IQ]);
make_action(#iq{type = error} = IQ) ->
  ?DEBUG("Drop error iq ~p", [IQ]);
make_action(Iq) ->
  ?DEBUG("Not supported iq ~p", [Iq]),
  ejabberd_router:route(xmpp:make_error(Iq, xmpp:err_not_allowed())).


-spec disco_sm_features({error, stanza_error()} | {result, [binary()]} | empty,
                                             jid(), jid(), binary(), binary()) ->
                                {error, stanza_error()} | {result, [binary()]}.
disco_sm_features({error, Err}, _From, _To, _Node, _Lang) ->
        {error, Err};
disco_sm_features(empty, _From, _To, <<"">>, _Lang) ->
        {result, [?NS_GROUPCHAT,?NS_GROUPCHAT_RETRACT,?NS_GROUPCHAT_RETRACT_HISTORY]};
disco_sm_features({result, Feats}, _From, _To, <<"">>, _Lang) ->
        {result, [?NS_GROUPCHAT_RETRACT_HISTORY|[?NS_GROUPCHAT_RETRACT|[?NS_GROUPCHAT|Feats]]]};
disco_sm_features(Acc, _From, _To, _Node, _Lang) ->
        Acc.


%% Internal Functions
x_element_chat(Desc,Anon,Model) ->
  DescField = xdata_field(<<"description">>,<<"Description">>,Desc),
  AnonField = xdata_field(<<"anonymous">>,<<"Anonymous">>,Anon),
  ModelField = xdata_field(<<"model">>,<<"Access model">>,Model),
  HiddenField = hidden_field(),
  Fields = [HiddenField,DescField,AnonField,ModelField],
  #xmlel{name = <<"x">>, attrs = [{<<"xmlns">>,<<"jabber:x:data">>},{<<"type">>,<<"result">>}],
    children = Fields}.

hidden_field() ->
  #xmlel{name = <<"field">>, attrs = [{<<"var">>,<<"FORM_TYPE">>},{<<"type">>,<<"hidden">>}],
    children = [#xmlel{name = <<"value">>,
      children = [{xmlcdata,<<"http://xabber.com/protocol/groupchat#info">>}]}]}.

xdata_field(Var,Label,Value) ->
  #xmlel{name = <<"field">>, attrs = [{<<"var">>,Var},{<<"label">>,Label}],
    children = [#xmlel{name = <<"value">>, children = [{xmlcdata,Value}]}]}.

query_chat(Items) ->
  {xmlel,<<"query">>,[{<<"xmlns">>,<<"http://xabber.com/protocol/groupchat#rights">>}],
    items(Items,[])}.

query_disco_info(Items) ->
  {xmlel,<<"query">>,[{<<"xmlns">>,?NS_DISCO_INFO}],
    Items}.

items([],Acc)->
  Acc;
items(Users,Acc) ->
  [User|Rest] = Users,
  items(Rest,[item(User)|Acc]).


item(User) ->
  [Name,TranslatedName,Type,Action] = User,
  case Action of
    null ->
      {xmlel,Type,[{<<"name">>,Name},{<<"translation">>,TranslatedName}],[]};
    _ ->
      {xmlel,Type,[{<<"name">>,Name},{<<"translation">>,TranslatedName},{<<"expires">>,Action}],[]}
  end.

process_mam_iq(#iq{from = From, lang = Lang, id = Id, to = To, meta = Meta, type = Type,
  sub_els = [SubEl]} = Iq) ->
  User = jid:to_string(jid:remove_resource(From)),
  Server = To#jid.lserver,
  Chat = jid:to_string(jid:remove_resource(To)),
  GlobalIndexs = mod_groupchat_presence:get_global_index(Server),
  IsIndex = lists:member(User,GlobalIndexs),
  IsRestrictedToRead = mod_groupchat_restrictions:is_restricted(<<"read-messages">>,User,Chat),
  IsAnon = mod_groupchat_chats:is_anonim(Server,Chat),
  IsGlobalIndexed = mod_groupchat_chats:is_global_indexed(Server,Chat),
  SubElD = xmpp:decode(SubEl),
  IQDecoded = #iq{from = To, lang = Lang, to = From, meta = Meta, sub_els = [SubElD], type = Type, id = Id},
  Query = get_query(SubElD,Lang),
  With = proplists:is_defined(with, Query),
  case mod_groupchat_inspector_sql:check_user(User,Server,Chat) of
    exist when IsRestrictedToRead == no andalso With =/= false ->
      WithValue = jid:to_string(proplists:get_value(with, Query)),
      M1 = change_id_to_jid(SubElD,Server,Chat,WithValue),
      IQDecoded2 = #iq{from = To, lang = Lang, to = From, meta = Meta, sub_els = [M1], type = Type, id = Id},
      mod_mam:process_iq_v0_3(IQDecoded2);
    exist when IsRestrictedToRead == no andalso With == false ->
      mod_mam:process_iq_v0_3(IQDecoded);
    exist when IsRestrictedToRead == no andalso IsAnon == yes andalso With == false ->
      mod_mam:process_iq_v0_3(IQDecoded);
    _ when IsIndex == true andalso IsGlobalIndexed == yes ->
      mod_mam:process_iq_v0_3(IQDecoded);
    _ ->
      ?DEBUG("not allowed",[]),
      ejabberd_router:route(xmpp:make_error(Iq, xmpp:err_not_allowed()))
  end.

get_query(SubEl,Lang)->
  case mod_mam:parse_query(SubEl, Lang) of
    {ok, Query} ->
      Query;
    {error, _Err} ->
      []
  end.


change_id_to_jid(Mam,Server,Chat,ID) ->
  JID = mod_groupchat_users:get_user_by_id(Server,Chat,ID),
  #xdata{type = Type, instructions = Inst, title = Title, reported = Rep,  items = Items} = Mam#mam_query.xdata,
  NewFields = [#xdata_field{type = 'hidden', var = <<"FORM_TYPE">>, values = [Mam#mam_query.xmlns]},
    #xdata_field{var = <<"with">>, values = [JID]}],
  NewXdata = #xdata{type = Type, instructions = Inst, title = Title, reported = Rep,  items = Items, fields = NewFields},
  #mam_query{id = Mam#mam_query.id, rsm = Mam#mam_query.rsm, xmlns = Mam#mam_query.xmlns, start = Mam#mam_query.start, 'end' = Mam#mam_query.'end', withtext = Mam#mam_query.withtext, xdata = NewXdata, with = Mam#mam_query.with}.