%%%-------------------------------------------------------------------
%%% File    : mod_xabber_api.erl
%%% Author  : Andrey Gagarin <andrey.gagarin@redsolution.com>
%%% Purpose : Xabber API methods
%%% Created : 05 Jul 2019 by Andrey Gagarin <andrey.gagarin@redsolution.com>
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

-module(mod_xabber_api).
-author('andrey.gagarin@redsolution.com').

-behaviour(gen_mod).

-include("logger.hrl").
-include("ejabberd_sql_pt.hrl").
-compile([{parse_transform, ejabberd_sql_pt}]).
-export([start/2, stop/1, reload/3, mod_options/1, xabber_commands/0,
  get_commands_spec/0, depends/2]).

% Commands API
-export([


  % Accounts
  xabber_registered_chats/3, xabber_registered_users/3, xabber_register_chat/9,
  xabber_registered_chats_count/1, xabber_registered_users_count/1,
  set_password/3, check_user/2, xabber_revoke_user_token/2,
  % Vcard
  set_vcard/4,set_vcard/5,set_nickname/3,get_vcard_multi/4,get_vcard/3,get_vcard/4, oauth_issue_token/5,

  % Count user
  xabber_num_online_users/1
]).


-include("ejabberd.hrl").
-include("ejabberd_commands.hrl").
-include("mod_roster.hrl").
-include("mod_privacy.hrl").
-include("ejabberd_sm.hrl").
-include("xmpp.hrl").

%%%
%%% gen_mod
%%%

start(_Host, _Opts) ->
  ejabberd_commands:register_commands(get_commands_spec()).

stop(Host) ->
  case gen_mod:is_loaded_elsewhere(Host, ?MODULE) of
    false ->
      ejabberd_commands:unregister_commands(get_commands_spec());
    true ->
      ok
  end.

reload(_Host, _NewOpts, _OldOpts) ->
  ok.

depends(_Host, _Opts) ->
  [].

mod_options(_) -> [].

%%%
%%% Register commands
%%%

get_commands_spec() ->
  Vcard1FieldsString = "Some vcard field names in get/set_vcard are:\n"
  " FN		- Full Name\n"
  " NICKNAME	- Nickname\n"
  " BDAY		- Birthday\n"
  " TITLE		- Work: Position\n"
  " ROLE		- Work: Role",

  Vcard2FieldsString = "Some vcard field names and subnames in get/set_vcard2 are:\n"
  " N FAMILY	- Family name\n"
  " N GIVEN	- Given name\n"
  " N MIDDLE	- Middle name\n"
  " ADR CTRY	- Address: Country\n"
  " ADR LOCALITY	- Address: City\n"
  " TEL HOME      - Telephone: Home\n"
  " TEL CELL      - Telephone: Cellphone\n"
  " TEL WORK      - Telephone: Work\n"
  " TEL VOICE     - Telephone: Voice\n"
  " EMAIL USERID	- E-Mail Address\n"
  " ORG ORGNAME	- Work: Company\n"
  " ORG ORGUNIT	- Work: Department",

  VcardXEP = "For a full list of vCard fields check XEP-0054: vcard-temp at "
  "http://www.xmpp.org/extensions/xep-0054.html",
    [
      #ejabberd_commands{name = xabber_revoke_user_token, tags = [xabber],
        desc = "Delete user's token",
        longdesc = "Type 'jid token' to delete selected token. Type 'jid all' - if you want to delete all tokens of user",
        module = ?MODULE, function = xabber_revoke_user_token,
        args_desc = ["User's jid", "Token (all - to delete all tokens)"],
        args_example = [<<"juliet@capulet.lit">>, <<"all">>],
        args = [{jid, binary}, {token, binary}],
        result = {res, rescode},
        result_example = 0,
        result_desc = "Returns integer code:\n"
        " - 0: operation succeeded\n"
        " - 1: error: sql query error"},
      #ejabberd_commands{name = xabber_num_online_users, tags = [xabber],
        desc = "Get number of users active in the last DAYS ",
        longdesc = "",
        module = ?MODULE, function = xabber_num_online_users,
        args_desc = ["Name of HOST to check"],
        args_example = [<<"capulet.lit">>],
        args = [{host, binary}],
        result = {users, integer},
        result_example = 123,
        result_desc = "Number of users online, exclude duplicated resources"},
      #ejabberd_commands{name = xabber_registered_users, tags = [accounts],
        desc = "List all registered users in HOST",
        module = ?MODULE, function = xabber_registered_users,
        args_desc = ["Local vhost"],
        args_example = [<<"example.com">>,30,1],
        result_desc = "List of registered accounts usernames",
        result_example = [<<"user1">>, <<"user2">>],
        args = [{host, binary},{limit,integer},{page,integer}],
        result = {users, {list, {username, string}}}},
      #ejabberd_commands{name = xabberuser_change_password, tags = [accounts],
        desc = "Change the password of an account",
        module = ?MODULE, function = set_password,
        args = [{user, binary}, {host, binary}, {newpass, binary}],
        args_example = [<<"peter">>, <<"myserver.com">>, <<"blank">>],
        args_desc = ["User name", "Server name",
          "New password for user"],
        result = {res, rescode},
        result_example = ok,
        result_desc = "Status code: 0 on success, 1 otherwise"},
      #ejabberd_commands{name = xabberuser_set_nickname, tags = [vcard],
        desc = "Set nickname in a user's vCard",
        module = ?MODULE, function = set_nickname,
        args = [{user, binary}, {host, binary}, {nickname, binary}],
        args_example = [<<"user1">>,<<"myserver.com">>,<<"User 1">>],
        args_desc = ["User name", "Server name", "Nickname"],
        result = {res, rescode}},
      #ejabberd_commands{name = xabberuser_get_vcard, tags = [vcard],
        desc = "Get content from a vCard field",
        longdesc = Vcard1FieldsString ++ "\n" ++ Vcard2FieldsString ++ "\n\n" ++ VcardXEP,
        module = ?MODULE, function = get_vcard,
        args = [{user, binary}, {host, binary}, {name, binary}],
        args_example = [<<"user1">>,<<"myserver.com">>,<<"NICKNAME">>],
        args_desc = ["User name", "Server name", "Field name"],
        result_example = "User 1",
        result_desc = "Field content",
        result = {content, string}},
      #ejabberd_commands{name = xabberuser_get_vcard2, tags = [vcard],
        desc = "Get content from a vCard subfield",
        longdesc = Vcard2FieldsString ++ "\n\n" ++ Vcard1FieldsString ++ "\n" ++ VcardXEP,
        module = ?MODULE, function = get_vcard,
        args = [{user, binary}, {host, binary}, {name, binary}, {subname, binary}],
        args_example = [<<"user1">>,<<"myserver.com">>,<<"N">>, <<"FAMILY">>],
        args_desc = ["User name", "Server name", "Field name", "Subfield name"],
        result_example = "Schubert",
        result_desc = "Field content",
        result = {content, string}},
      #ejabberd_commands{name = xabberuser_get_vcard2_multi, tags = [vcard],
        desc = "Get multiple contents from a vCard field",
        longdesc = Vcard2FieldsString ++ "\n\n" ++ Vcard1FieldsString ++ "\n" ++ VcardXEP,
        module = ?MODULE, function = get_vcard_multi,
        args = [{user, binary}, {host, binary}, {name, binary}, {subname, binary}],
        result = {contents, {list, {value, string}}}},

      #ejabberd_commands{name = xabberuser_set_vcard, tags = [vcard],
        desc = "Set content in a vCard field",
        longdesc = Vcard1FieldsString ++ "\n" ++ Vcard2FieldsString ++ "\n\n" ++ VcardXEP,
        module = ?MODULE, function = set_vcard,
        args = [{user, binary}, {host, binary}, {name, binary}, {content, binary}],
        args_example = [<<"user1">>,<<"myserver.com">>, <<"URL">>, <<"www.example.com">>],
        args_desc = ["User name", "Server name", "Field name", "Value"],
        result = {res, rescode}},
      #ejabberd_commands{name = xabberuser_set_vcard2, tags = [vcard],
        desc = "Set content in a vCard subfield",
        longdesc = Vcard2FieldsString ++ "\n\n" ++ Vcard1FieldsString ++ "\n" ++ VcardXEP,
        module = ?MODULE, function = set_vcard,
        args = [{user, binary}, {host, binary}, {name, binary}, {subname, binary}, {content, binary}],
        args_example = [<<"user1">>,<<"myserver.com">>,<<"TEL">>, <<"NUMBER">>, <<"123456">>],
        args_desc = ["User name", "Server name", "Field name", "Subfield name", "Value"],
        result = {res, rescode}},
      #ejabberd_commands{name = xabberuser_set_vcard2_multi, tags = [vcard],
        desc = "Set multiple contents in a vCard subfield",
        longdesc = Vcard2FieldsString ++ "\n\n" ++ Vcard1FieldsString ++ "\n" ++ VcardXEP,
        module = ?MODULE, function = set_vcard,
        args = [{user, binary}, {host, binary}, {name, binary}, {subname, binary}, {contents, {list, {value, binary}}}],
        result = {res, rescode}},
      #ejabberd_commands{name = xabber_register_chat, tags = [accounts],
        desc = "Create xabber groupchat with owner",
        module = ?MODULE, function = xabber_register_chat,
        args = [{host, binary},
          {user, binary},
          {userhost, binary},
          {name, binary},
          {localpart, binary},
          {privacy, binary},
          {index, binary},
          {membership, binary},
          {description, binary}
        ],
        args_example = [
          <<"myserver.com">>,
          <<"user1">>,
          <<"someserver.com">>,
          <<"Group 3">>,
          <<"group3">>,
          <<"public">>,
          <<"global">>,
          <<"open">>,
          <<"Group number 3">>
        ],
        args_desc = ["Host","Username", "User server name", "Groupchat name",
          "Groupchat identifier", "Groupchat privacy", "Groupchat index",
          "Groupchat membership", "Groupchat description"],
        result = {res, rescode},
        result_example = 0,
        result_desc = "Returns integer code:\n"
      " - 0: chat was created\n"
      " - 1: error: chat is exist\n"
      " - 2: error: bad params"},
      #ejabberd_commands{name = xabber_registered_chats, tags = [accounts],
        desc = "List all registered chats in HOST",
        module = ?MODULE, function = xabber_registered_chats,
        args_desc = ["Local vhost"],
        args_example = [<<"example.com">>,30,1],
        result_desc = "List of registered chats",
        result_example = [{<<"chat1">>,<<"user1@example.com">>,123}, {<<"chat2">>,<<"user@xabber.com">>,456,202}],
        args = [{host, binary},{limit,integer},{page,integer}],
        result = {chats, {list, {chats, {tuple,[
          {name, string},
          {owner,string},
          {number, integer},
          {private_chats, integer}
        ]
        }
        }}}},
      #ejabberd_commands{name = xabber_registered_chats_count, tags = [accounts],
        desc = "Count all registered chats in HOST",
        module = ?MODULE, function = xabber_registered_chats_count,
        args_desc = ["Local vhost"],
        args_example = [<<"example.com">>],
        result_desc = "Number of registered chats",
        result_example = [100500],
        args = [{host, binary}],
        result = {number, integer}
        },
      #ejabberd_commands{name = xabber_oauth_issue_token, tags = [xabber],
        desc = "Issue an oauth token for the given jid",
        module = ?MODULE, function = oauth_issue_token,
        args = [{jid, string},{ttl, integer}, {scopes, string}, {browser, binary}, {ip, binary}],
        policy = restricted,
        args_example = ["user@server.com", 3600, "connected_users_number;muc_online_rooms","Firefox 155", "192.168.100.111"],
        args_desc = ["Jid for which issue token",
          "Time to live of generated token in seconds",
          "List of scopes to allow, separated by ';'",
          "Name of web browser",
          "IP address"],
        result = {result, {tuple, [{token, string}, {scopes, string}, {expires_in, string}]}}
      },
      #ejabberd_commands{name = xabber_registered_users_count, tags = [accounts],
        desc = "Count all registered users in HOST",
        module = ?MODULE, function = xabber_registered_users_count,
        args_desc = ["Local vhost"],
        args_example = [<<"example.com">>],
        result_desc = "Number of registered users",
        result_example = [100500],
        args = [{host, binary}],
        result = {number, integer}
      }
    ].

oauth_issue_token(Jid, TTLSeconds, ScopesString,Browser,IP) ->
  Scopes = [list_to_binary(Scope) || Scope <- string:tokens(ScopesString, ";")],
  try jid:decode(list_to_binary(Jid)) of
    #jid{luser =Username, lserver = Server} ->
      case oauth2:authorize_password({Username, Server},  Scopes, admin_generated) of
        {ok, {_Ctx,Authorization}} ->
          {ok, {_AppCtx2, Response}} = oauth2:issue_token(Authorization, [{expiry_time, TTLSeconds}]),
          {ok, AccessToken} = oauth2_response:access_token(Response),
          {ok, VerifiedScope} = oauth2_response:scope(Response),
          ejabberd_hooks:run(xabber_oauth_token_issued, Server, [Username, Server, AccessToken, TTLSeconds, Browser, IP]),
          {AccessToken, VerifiedScope, integer_to_list(TTLSeconds) ++ " seconds"};
        {error, Error} ->
          {error, Error}
      end
  catch _:{bad_jid, _} ->
    {error, "Invalid JID: " ++ Jid}
  end.

set_password(User, Host, Password) ->
  mod_admin_extra:set_password(User, Host, Password).

set_nickname(User, Host, Nickname) ->
  mod_admin_extra:set_nickname(User, Host, Nickname).

get_vcard(User, Host, Name) ->
  mod_admin_extra:get_vcard(User, Host, Name).

get_vcard(User, Host, Name, Subname) ->
  mod_admin_extra:get_vcard(User, Host, Name, Subname).

get_vcard_multi(User, Host, Name, Subname) ->
  mod_admin_extra:get_vcard_multi(User, Host, Name, Subname).

set_vcard(User, Host, Name, SomeContent) ->
  mod_admin_extra:set_vcard(User, Host, Name, SomeContent).

set_vcard(User, Host, Name, Subname, SomeContent) ->
  mod_admin_extra:set_vcard(User, Host, Name, Subname, SomeContent).

xabber_all_registered_users(Host) ->
  Users = ejabberd_auth:get_users(Host),
  SUsers = lists:sort(Users),
  Usernames = lists:map(fun({U, _S}) -> U end, SUsers),
  Usernames -- xabber_chats(Host).

xabber_chats(Host) ->
  Chats = mod_groupchat_chats:get_all(Host),
  SChats = lists:sort(Chats),
  lists:map(fun({U}) -> U end, SChats).

xabber_registered_chats(Host,Limit,Page) ->
  mod_groupchat_chats:get_all_info(Host,Limit,Page).

xabber_registered_users(Host,Limit,Page) ->
  mod_groupchat_users:get_users_page(Host,Limit,Page).

xabber_registered_chats_count(Host) ->
  mod_groupchat_chats:get_count_chats(Host).

xabber_registered_users_count(Host) ->
  length(xabber_all_registered_users(Host)).

xabber_register_chat(Server,Creator,Host,Name,LocalJid,Anon,Searchable,Model,Description) ->
  case validate(Anon,Searchable,Model) of
    ok ->
      case mod_groupchat_inspector:create_chat(Creator,Host,Server,Name,Anon,LocalJid,Searchable,Description,Model,undefined,undefined,undefined) of
        {ok, _Created} ->
          ok;
        _ ->
          1
      end;
    _ ->
      2
  end.

xabber_num_online_users(Host) ->
  xabber_num_active_users(0, Host).

xabber_num_active_users(Days, Host) when Days == 0 ->
  xabber_num_active_users(Host, 0, 0);
xabber_num_active_users(Days, Host) ->
  case get_last_from_db(Days, Host) of
    {error, db_failure} ->
      0;
    {ok, UserLastList} ->
      xabber_num_active_users(UserLastList, Host, 0, 0)
  end.

xabber_revoke_user_token(BareJID,Token) ->
  ejabberd_oauth_sql:revoke_user_token(BareJID,Token).

xabber_num_active_users(Host, Offset, UserCount) ->
%%  UsersList = ejabberd_admin:registered_users(Host),
  Limit = 500,
  case ejabberd_auth:get_users(Host, [{limit, Limit}, {offset, Offset}]) of
    [] ->
      UserCount;
    UsersList ->
      UsersList2 = lists:filtermap(
        fun(U) ->
          {User, Host} = U,
          case ejabberd_sm:get_user_resources(User, Host) of
            [] ->
              false;
            _ ->
              {true, 0}
          end
        end,UsersList),
      xabber_num_active_users(Host, Offset+Limit, UserCount+length(UsersList2))
  end.

xabber_num_active_users(UserLastList, Host, Offset, UserCount) ->
  Limit = 500,
  case ejabberd_auth:get_users(Host, [{limit, Limit}, {offset, Offset}]) of
    [] ->
      UserCount;
    UsersList ->
      UsersList2 = lists:filtermap(
        fun(U) ->
          {User, Host} = U,
          case ejabberd_sm:get_user_resources(User, Host) of
            [] ->
              case lists:member({User},UserLastList) of
                false ->
                  false;
                true ->
                  {true, 0}
              end;
            _ ->
              {true, 0}
          end
        end,UsersList),
      xabber_num_active_users(UserLastList, Host, Offset+Limit, UserCount+length(UsersList2))
  end.

get_last_from_db(Days, LServer) ->
  CurrentTime = p1_time_compat:system_time(seconds),
  Diff = Days * 24 * 60 * 60,
  TimeStamp = CurrentTime - Diff,
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(username)s from last where seconds >= %(TimeStamp)s and %(LServer)H")) of
    {selected, LastList} ->
      {ok, LastList};
    _Reason ->
      {error, db_failure}
  end.

validate(Anon,Searchable,Model) ->
  IsPrivacyOkey = validate_privacy(Anon),
  IsMembershipOkey = validate_membership(Model),
  IsIndexOkey = validate_index(Searchable),
  case IsPrivacyOkey of
    true when IsMembershipOkey == true andalso IsIndexOkey == true ->
      ok;
    _ ->
      not_ok
  end.

xabber_commands() ->
  [xabberuser_change_password,
    xabberuser_set_vcard,
    xabberuser_set_vcard2,
    xabberuser_set_vcard2_multi,
    xabberuser_set_nickname,
    xabberuser_get_vcard,
    xabberuser_get_vcard2,
    xabberuser_get_vcard2_multi].

check_user(#{caller_module := mod_http_api} = Auth,Args) ->
#{usr := USR} = Auth,
  {U,S,_R} = USR,
  [User|Rest] = Args,
  [Server|_R2] = Rest,
  case User of
    U  when S == Server ->
      ok;
    _ ->
      false
  end;
check_user(_Auth,_Args) ->
  ok.


validate_privacy(Privacy) ->
  lists:member(Privacy,[<<"public">>, <<"incognito">>]).

validate_membership(Membership) ->
  lists:member(Membership,[<<"open">>, <<"member-only">>]).

validate_index(Index) ->
  lists:member(Index,[<<"none">>, <<"local">>, <<"global">>]).