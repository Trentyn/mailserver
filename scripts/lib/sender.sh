# From: header check, shared by setup.sh and upgrade.sh.
# shellcheck shell=bash

# Postfix checks only the envelope sender against sender_login_maps, so a
# mailbox could still put someone else's address of a hosted domain in the
# From: header that recipients see, and Rspamd would DKIM-sign it. This rule
# applies the same map to the From: header of authenticated mail: a mailbox may
# show only its own address, its aliases and its send-as grants. Inbound mail
# and mail generated on the server (bounces, Sieve) have no user and pass.
write_rspamd_from_check() {
    install -d -m 0755 /etc/rspamd/lua.local.d
    cat > /etc/rspamd/lua.local.d/mailserver_from.lua << 'EOF'
-- Managed by mailserver: an authenticated mailbox may use only addresses it
-- may send as (/etc/postfix/sender_login_maps) in the From: header.
local owners = rspamd_config:add_map({
  type = 'map',
  url = '/etc/postfix/sender_login_maps',
  description = 'mailserver: who may send as each address',
})

-- Postfix order: the address, the address without +extension, then @domain.
-- The first key found decides, as in Postfix.
local function may_send_as(addr, user)
  local localpart, domain = addr:match('^([^@]+)@(.+)$')
  if not localpart then return false end
  local keys = { addr }
  local base = localpart:match('^([^+]+)%+')
  if base then keys[#keys + 1] = base .. '@' .. domain end
  keys[#keys + 1] = '@' .. domain
  for _, key in ipairs(keys) do
    local logins = owners and owners:get_key(key)
    if logins then
      for login in tostring(logins):gmatch('[^,%s]+') do
        if login:lower() == user then return true end
      end
      return false
    end
  end
  return false
end

rspamd_config:register_symbol({
  name = 'MAILSERVER_FROM_NOT_ALLOWED',
  type = 'prefilter',
  priority = 10,
  flags = 'empty,nostat',
  callback = function(task)
    local user = task:get_user()
    if not user then return end
    user = user:lower()
    local from = task:get_from('mime')
    if not from or #from ~= 1 or not from[1].addr or from[1].addr == '' then
      task:set_pre_result('reject', 'The From: header must hold exactly one address', 'mailserver')
      return
    end
    local addr = from[1].addr:lower()
    if not may_send_as(addr, user) then
      task:set_pre_result('reject',
        string.format('%s may not send as %s (From: header)', user, addr), 'mailserver')
    end
  end,
})
EOF
}
