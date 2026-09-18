NFS Most Wanted Recompiled - Nintendo Switch homebrew
======================================================

EXPERIMENTAL: the game runs, but nothing is drawn yet. The screen shows a
status line (guest fps, frames, RAM) and the log. Graphics need a GPU backend
that does not exist for the Switch yet.

WHERE THINGS GO
  This whole folder goes to the SD card as:

    sdmc:/switch/nfsmw-recomp/
      nfsmw-recomp.nro     the game
      README.txt           this file
      game/                put YOUR extracted game files here:
        default.xex          game/default.xex must exist
        NFS/
        Movies/
      saves/               created on first run (profile, save games)
      logs/                created on first run (one log per run)
      nfsmw.toml           optional settings, same format as on PC

  Extract your own disc image into game/, e.g.:
      extract-xiso -x "Need for Speed Most Wanted.iso" -d game
  ISO files are not read on the Switch, only the extracted folder.

LAUNCHING
  Needs Atmosphere and about 1.5 GB of RAM: hold R while starting any
  installed game, then pick NFS Most Wanted Recompiled in the Homebrew Menu.
  The Homebrew Menu from the Album does not have enough memory.

  Quit with HOME > Close. If startup fails the log stays on screen; press +
  to exit, and send logs/ (and crash.txt if present) with the report.

CONTROLS (by position, like an Xbox pad)
  A/B/X/Y = B/A/Y/X    LB/RB = L/R    LT/RT = ZL/ZR
  Start/Back = +/-     sticks and D-pad as usual
