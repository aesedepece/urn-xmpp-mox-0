--[[

  https://github.com/waalt/urn-xmpp-mox-0
  XEP-xxxx: Money Over XMPP (MOX)
                                    ###
   #    #   ####   #    #          #   #
   ##  ##  #    #   #  #          # #   #
   # ## #  #    #    ##    #####  #  #  #
   #    #  #    #    ##           #   # #
   #    #  #    #   #  #           #   #
   #    #   ####   #    #           ###
 
  The MIT License (MIT)

  Copyright (c) 2014 Waalt Communications (@waaltcom)
  Copyright (c) 2014 Adán Sánchez de Pedro Crespo (@adansdpc)

  Permission is hereby granted, free of charge, to any person obtaining a copy
  of this software and associated documentation files (the "Software"), to deal
  in the Software without restriction, including without limitation the rights
  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  copies of the Software, and to permit persons to whom the Software is
  furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in all
  copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
  SOFTWARE.

]]--


local st = require "util.stanza"; -- Import Prosody's stanza API into 'st'
local jid_bare = require "util.jid".bare;
local json = require "util.json";
local servers = {};
local idx = {}; -- This holds data for processing answers to forwarded stanzas
local xmlns_mox = "urn:xmpp:mox:0";

module:add_feature(xmlns_mox);
module:log("info", "Started "..xmlns_mox);

function BitcoinAPI(rpcaddress, rpcport, rpcuser, rpcpass)
  local self = {
    public_field = 0
  }

  local rpcaddress = rpcaddress;
  local rpcport = rpcport;
  local rpcuser = rpcuser;
  local rpcpass = rpcpass;
  
  local exec = function (method, params)
    local obj = nil;
    local cmd = "curl --user "..rpcuser..":"..rpcpass.." --data-binary "..
    "'{\"jsonrpc\": \"1.0\", \"id\":\"mox\", \"method\": \""..method.."\", "..
    "\"params\": "..json.encode(params).." }' -H 'content-type: text/plain;' "..
    "http://"..rpcaddress..":"..rpcport.." 2>/dev/null";
    --module:log("debug", cmd);
    local f = io.popen(cmd);
    local out = f:read("*a"):gsub("\n", ""):gsub("  ", "");
    --module:log("debug", out);
    if string.len(out) > 0 then
      if json.test(out) then
        module:log("debug", "JSON OUT "..out.." ");
        obj = json.decode(out);
      end
    else
      module:log("warn", "Command failed! [ "..cmd.." ]");
    end
    return obj;
  end
  
  function self.register(account)
    return exec("getaccountaddress", {account}).result;
  end
  
  function self.addressGet(account) 
    return exec("getaddressesbyaccount", {account}).result;
  end
  
  function self.balanceGet(account)
    return exec("getbalance", {account}).result;
  end
  
  function self.accountGet(address)
    return exec("getaccount", {address});
  end
  
  function self.send(from, to, amount, comment)
    local ret = 0;
    local account = self.accountGet(to);
    if account.result ~= "" and account.result ~= "null" then
      -- Local transaction
      local to = account.result;
      local res = exec("move", {from, to, amount, comment});
      ret = "local";
    else
      -- Remote transaction
      local res = exec("sendfrom", {from, to, amount, comment});
      if json.encode(res.error) == "null" then
        ret = res.result;
      else
        ret = res.error.code;
      end
    end
    return ret;
  end
  
  module:log("info", "Added BitcoinAPI in "..rpcaddress..":"..rpcport);
  return self
end

function post(stanza)
  module:log("debug", "POST: ["..tostring(stanza).."]");
  core_post_stanza(hosts[module.host], stanza);
end

function errorPost(stanza, errorCode, where)
  local errors = {
    insufficientFunds = {"wait", "resource-constraint"},
    unsupportedQuery = {"modify", "feature-not-implemented"},
    unavailableWallet = {"cancel", "service-unavailable"},
    unsupportedCurrency = {"modify", "bad-request"},
    wrongAmount = {"modify", "bad-request"}
  };
  module:log("error", errorCode);
  post(st.error_reply(stanza, 
    errors[errorCode][1], errors[errorCode][2], errorCode));
end

function preIqGet(data)
  local query = data.stanza.tags[1];
  local child = query.tags[1];
  if (child) then
    local currency = child.attr.currency;
    local parse = {
      account = function (data)
        local reply = nil;
        if data.to == nil then -- process query
          local address = servers[currency].addressGet(jid_bare(data.from))[1];
          local balance = servers[currency].balanceGet(jid_bare(data.from));
          if address ~= nil and balance ~= nil then
            reply = st.reply(data.stanza)
              :tag("query", {xmlns=xmlns_mox})
                :tag("account", {currency=currency, balance=balance})
                  :tag("address"):text(address);
          end
        else
          idx[data.id] = data;
          reply = data.stanza; -- forward query to other server
        end
        return reply;
      end
    };
    if parse[child.name] then
      if currency and servers[currency] ~= nil then
        local reply = parse[child.name](data);
        if reply ~= nil then post(reply)
        else errorPost(data.stanza, "unavailableWallet", "pre-get") end
      else errorPost(data.stanza, "unsupportedCurrency") end
    else errorPost(data.stanza, "unsupportedQuery") end
  else
    reply = st.reply(data.stanza)
      :tag("query", {xmlns=xmlns_mox});
    for key,value in pairs(servers) do
      reply:tag("account", {currency=key});
    end
    post(reply);
  end
  return true;
end

function preIqSet(data)
  local query = data.stanza.tags[1];    
  local child = query.tags[1];
  data.currency = child.attr.currency;
  data.amount = tonumber(child.attr.amount);
  data.comment = child.attr.comment;
  local reply = nil;
  local parse = {
    send = function (data)
      if child.attr.to ~= nil then
        -- Non-MOX transaction
        module:log("info", "Non-MOX transaction to "..child.attr.to);
        local transID = servers[data.currency].send(
          jid_bare(data.from), child.attr.to, data.amount, data.comment);
        if type(transID) == "string" then
          reply = st.iq({type="result", id=data.id, to=data.from})
            :tag("query", {xmlns=xmlns_mox})
                :tag("send", {currency=data.currency, amount=data.amount, 
                  comment=data.comment, to=child.attr.to, transid=transID});
        else
          reply = transID;
        end
      else
        -- MOX transaction
        -- Remote address query
        module:log("info", "MOX transaction to "..data.to);
        idx[data.id] = data;
        reply = st.iq({type="get", id=data.id, from=data.from, to=data.to})
          :tag("query", {xmlns=xmlns_mox})
              :tag("account", {currency=data.currency});
      end
      return reply;
    end,
    account = function (data)
      local address = servers[data.currency].register(jid_bare(data.from));
      if address ~= nil then
        reply = st.reply(data.stanza)
          :tag("query", {xmlns=xmlns_mox})
            :tag("account", {currency=data.currency})
              :tag("address"):text(address);
      end
      return reply;
    end
  }
  local errors = {}
  errors[-6] = "insufficientFunds";
  if parse[child.name] then
    if data.currency and servers[data.currency] ~= nil then
      local reply = parse[child.name](data);
      if reply ~= nil then
        if type(reply) == "number" then
          errorPost(data.stanza, errors[reply]);
        else
          if child.name == "send" then
            if data.amount and data.amount > 0 then post(reply)
            else errorPost(data.stanza, "wrongAmount") end
          else
            post(reply);
          end
        end
      else errorPost(data.stanza, "unavailableWallet", "pre-set") end
    else errorPost(data.stanza, "unsupportedCurrency") end
  else errorPost(data.stanza, "unsupportedQuery") end
  return true;
end

function preIqResult(data)
  return false;
end

function postIqGet(data)
  local query = data.stanza.tags[1];
  local child = query.tags[1];
  local currency = child.attr.currency;
  local reply = nil;
  local parse = {
    account = function (data)
      if data.to ~= nil then
        local address = servers[currency].addressGet(jid_bare(data.to))[1];
        if address ~= nil then
          reply = st.reply(data.stanza)
            :tag("query", {xmlns=xmlns_mox})
              :tag("account", {currency=currency})
                :tag("address"):text(address);
          reply.attr.to = jid_bare(data.from);
        end
      end
      return reply;
    end
  };
  if parse[child.name] then
    if currency and servers[currency] ~= nil then
      reply = parse[child.name](data);
      if reply ~= nil then post(reply)
      else errorPost(data.stanza, "unavailableWallet", "post-get") end
    else errorPost(data.stanza, "unsupportedCurrency") end
  else errorPost(data.stanza, "unsupportedQuery") end
  return true;
end

function postIqSet(data)
  return false;
end

function postIqResult(data)
  local query = data.stanza.tags[1];
  local child = query.tags[1];
  local currency = child.attr.currency;
  local reply = nil;
  local parse = {
    account = function (data)
      local oData = idx[data.id];
      local oType = oData.stanza.attr.type;
      if oType == "get" then
        local address = child.tags[1]:get_text();
        reply = st.reply(oData.stanza)
          :tag("query", {xmlns=xmlns_mox})
            :tag("account", {currency=currency})
              :text(address);
      elseif oType == "set" then
        local address = child.tags[1]:get_text();
        local amount = tonumber(oData.stanza.tags[1].tags[1].attr.amount);
        local comment = oData.stanza.tags[1].tags[1].attr.comment;
        if amount then
          local transID = servers[currency].send(
            jid_bare(oData.from), address, amount, comment);
          module:log("debug", "transID is "..transID);
          if type(transID) == "string" then
            reply = st.iq({type="result", id=data.id, to=oData.from})
              :tag("query", {xmlns=xmlns_mox})
                  :tag("send", {currency=data.currency, amount=data.amount, 
                    comment=data.comment, to=child.attr.to, transid=transID});
          else
            reply = transID;
          end
        end
      end
      idx[data.id] = nil;
      return reply;
    end
  }; 
  local errors = {}
  errors[-6] = "insufficientFunds";
  if parse[child.name] then
    if currency and servers[currency] ~= nil then
      reply = parse[child.name](data);
      if reply ~= nil then
        if type(reply) == "number" then
          errorPost(data.stanza, errors[reply]);
        else
          if child.name == "send" then
            if data.amount and data.amount > 0 then post(reply)
            else errorPost(data.stanza, "wrongAmount") end
          else
            post(reply);
          end
        end
      else errorPost(data.stanza, "unavailableWallet", "post-result") end
    else errorPost(data.stanza, "unsupportedCurrency") end
  else errorPost(data.stanza, "unsupportedQuery") end
  return true;
end


function iqParse(data, dest)
  local route = {
    pre = {get = preIqGet, set = preIqSet, result = preIqResult},
    post = {get = postIqGet, set = postIqSet, result = postIqResult}
  };
  local iqType = data.stanza.attr.type;
  if iqType and route[dest][iqType] ~= nil then
    --module:log("debug", dest..":"..iqType);
    return route[dest][iqType](data);
  else errorPost(data.stanza, "unsupportedQuery") end
end

function on(event, cb)
  local function hook(event)
    local data = {
      origin = event.origin,
      stanza = event.stanza,
      from = event.stanza.attr.from,
      to = event.stanza.attr.to,
      id = event.stanza.attr.id
    };
    if event.stanza:child_with_ns(xmlns_mox) then
      module:log("debug", "GOT ["..tostring(event.stanza).."]");
      return cb(data);
    end
  end
  module:hook(event, hook);
  module:log("debug", "HOOKED "..event);
end

-- Process stanzas from local clients
on("pre-iq/bare", function(data)
  return iqParse(data, "pre");
end);
-- Process stanzas from third parts
on("iq/bare", function(data)
  return iqParse(data, "post");
end);

-- Load configuration
for key,val in pairs(module:get_option("mox_servers")) do
  servers[key] = BitcoinAPI(unpack(val));
end
