-- Fallback clipboard provider for sandbox sessions. Installed into
-- $VIMRUNTIME/plugin (see Dockerfile) so it loads for every config,
-- including lazy.nvim setups whose performance.rtp reset strips /etc/xdg
-- from the runtimepath - and loads *after* the user's init, so a config
-- that brings its own g:clipboard (e.g. via SANDBOX_EXTRA_MOUNTS) wins.
--
-- Why this exists: nvim 0.11+ only auto-enables its OSC 52 provider after
-- a DA1/XTGETTCAP terminal-capability handshake, which never completes
-- through the docker tty chain - so a container with no clipboard tools
-- ends at "clipboard: No provider" even though a plain OSC 52 write
-- delivers fine through docker -> tmux -> ssh -> terminal. Copy is that
-- plain write; paste is deliberately a no-op (OSC 52 *reads* are
-- inconsistently supported and can hang waiting for a reply - paste into
-- the sandbox via the terminal's own native paste instead).
if vim.env.CLAUDE_SANDBOX == nil or vim.g.clipboard ~= nil then
  return
end

local osc52 = require('vim.ui.clipboard.osc52')
vim.g.clipboard = {
  name = 'sandbox-osc52',
  copy = { ['+'] = osc52.copy('+'), ['*'] = osc52.copy('*') },
  paste = {
    ['+'] = function() return {} end,
    ['*'] = function() return {} end,
  },
}
