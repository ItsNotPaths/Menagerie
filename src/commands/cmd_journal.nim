## commands/cmd_journal.nim
## ────────────────────────
## Journal command — opens the journal overlay in the UI.
## Aliased to "j" in commands/core.nim.

import engine/state
import commands/core


proc cmdJournal(state: var GameState; args: seq[string]): CmdResult =
  CmdResult(openJournal: true)


proc initCmdJournal*() =
  registerAny("journal", cmdJournal)
