# Dangerous attachments: rejected by type, without a virus scanner.
# shellcheck shell=bash

ATTACHMENTS_FILE=/etc/mailserver/attachments

# The policy for macro-enabled Office files: reject (default), junk or allow.
attachment_macros_policy() {
    local policy
    policy=$(awk -F= '$1 == "macros" {print $2}' "$ATTACHMENTS_FILE" 2>/dev/null)
    echo "${policy:-reject}"
}

# write_rspamd_attachment_check: install the Rspamd rule for the current policy.
#
# Blocked file types follow the default "common attachments filter" of
# Microsoft Defender for Office 365, plus scripts, disk images and shortcuts
# that malware uses. A file is checked by its name (the last extension, so
# "invoice.pdf.exe" counts as .exe), inside zip, rar and 7z archives, and by
# its content, so an executable renamed to .pdf is caught as well. Encrypted
# archives that hide their file names cannot be checked and go to Junk.
# Inbound and outbound mail get the same rules, so a stolen account cannot
# spread malware either.
write_rspamd_attachment_check() {
    local macros
    macros=$(attachment_macros_policy)
    install -d -m 0755 /etc/rspamd/lua.local.d
    {
        echo "-- Managed by mailserver (scripts/attachments.sh); edit through that script."
        echo "local MACROS = '${macros}'"
        cat << 'EOF'

local function set_of(list)
  local s = {}
  for ext in list:gmatch('%S+') do s[ext] = true end
  return s
end

local BLOCKED = set_of([[
  ace ade adp apk app appx ani arj bat cab chm class cmd com cpl deb dex dll
  dmg elf exe gadget hlp hta img inf ins iso isp jar jnlp js jse kext lha lib
  library lnk lzh macho mde msc msh msh1 msh2 mshxml msi msix msp mst ocx pif
  ps1 ps1xml ps2 ps2xml psc1 psc2 psm1 reg rev scf scr sct shb shs sys uif url
  vb vbe vbs vhd vhdx vxd website ws wsc wsf wsh xll xz z
]])
local MACRO = set_of([[
  docm dotm xlsm xltm xlam pptm potm ppam ppsm sldm
]])
-- Types Rspamd recognises from the content, whatever the file is called.
local BLOCKED_CONTENT = set_of('exe elf lnk msi jar apk class iso dmg')

local function extension(name)
  if not name then return nil end
  name = name:lower():gsub('[%s%.]+$', '')
  return name:match('%.([%w_-]+)$')
end

local id = rspamd_config:register_symbol({
  name = 'MAILSERVER_ATTACHMENT_CHECK',
  type = 'callback',
  flags = 'nostat',
  callback = function(task)
    local blocked, macro, hidden

    local function check(name, where)
      local ext = extension(name)
      if not ext then return end
      if BLOCKED[ext] then
        blocked = blocked or string.format('%s%s', name, where)
      elseif MACRO[ext] then
        macro = macro or string.format('%s%s', name, where)
      end
    end

    for _, part in ipairs(task:get_parts() or {}) do
      local name = part:get_filename()
      check(name, '')
      local detected = part:get_detected_ext()
      if detected and BLOCKED_CONTENT[detected] then
        blocked = blocked or string.format('%s (the content is .%s)', name or 'an attachment', detected)
      end
      if part:is_archive() then
        local archive = part:get_archive()
        local files = archive:get_files_full(1000) or {}
        for _, f in ipairs(files) do
          check(f.name, string.format(' (inside %s)', name or 'an archive'))
        end
        if #files == 0 and (archive:is_encrypted() or archive:is_unreadable()) then
          hidden = name or 'an encrypted archive'
        end
      end
    end

    if blocked then
      task:set_pre_result('reject', string.format(
        'Attachment %s is not allowed: executable or script file types are blocked. ' ..
        'Share it as a link instead.', blocked), 'mailserver')
    elseif macro and MACROS == 'reject' then
      task:set_pre_result('reject', string.format(
        'Attachment %s is not allowed: Office files with macros are blocked. ' ..
        'Send it without macros (.docx, .xlsx, .pptx) or as a link.', macro), 'mailserver')
    elseif macro and MACROS == 'junk' then
      task:insert_result('MAILSERVER_MACRO_ATTACHMENT', 1.0, macro)
    end
    if hidden then
      task:insert_result('MAILSERVER_HIDDEN_ARCHIVE', 1.0, hidden)
    end
  end,
})

-- Enough to reach "add header" (Junk) but not "reject".
rspamd_config:register_symbol({
  name = 'MAILSERVER_MACRO_ATTACHMENT', type = 'virtual', parent = id, score = 10.0,
  description = 'Office file with macros (mailserver policy: junk)', group = 'mailserver',
})
rspamd_config:register_symbol({
  name = 'MAILSERVER_HIDDEN_ARCHIVE', type = 'virtual', parent = id, score = 10.0,
  description = 'Encrypted archive whose file names cannot be checked', group = 'mailserver',
})
EOF
    } > /etc/rspamd/lua.local.d/mailserver_attachments.lua
}
