
This is just some random information I want to remember.

## Updating my neo-marimo

When I want to update my neo-marimo with a new update, I need to:

1. Do `git -C ~/.local/share/nvim/site/pack/core/opt/neo-marimo pull` to grab the most recent version (make sure I start with `!` if I am doing this in neovim, which I have been doing)
2. Make sure it actually pulled it and shows that in the output
3. Restart neovim
4. can got the git command again if I want to verify that is "Already Updated"
5. Can then use it

Checkhealth will give a warning for this because it is not updating the "normal" way for vim.pack. That is fine as long as I do this.

Using `:MarimoWsDebug`

 So the correct workflow for WS debug logging is:

  1. :MarimoWsDebug — enable logging
  2. :MarimoStop — stop the server if running
  3. :MarimoEdit — start the server and open browser (this sets up the WS callback)
  4. tail -f /tmp/neo-marimo-ws.log

  Were you using :MarimoOpen instead of :MarimoEdit?
