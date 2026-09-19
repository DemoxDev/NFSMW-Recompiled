NFS Most Wanted Recompiled - macOS (Apple Silicon)
==================================================

EXPERIMENTAL: the game runs and renders through Vulkan on MoltenVK
(Khronos' Vulkan implementation of Apple's Metal).

WHERE THINGS GO
  This whole folder is self-contained:

    build/mac/
      nfsmw                 the game
      librexgpu-xenos.dylib the GPU plugin (dlopen'ed next to the game)
      lib/                  dylibs: librexgpu-xenos, runtime, Tracy,
                            Vulkan loader, MoltenVK (do not delete any)
      share/vulkan/icd.d/   MoltenVK_icd.json (points at ../lib)
      nfsmw.toml            settings, same format as on PC
      README.txt            this file
      game/  saves/  logs/  yours

  Put YOUR game files next to nfsmw, either a disc image (an .iso is
  read in place) or the extracted folder named game_root:
      game_root/default.xex   must exist

LAUNCHING
  From a terminal:
      ./nfsmw
  or with flags (everything is overridable):
      ./nfsmw --game_data_root=/path/to/game --user_data_root="$PWD/saves"

  Quit with Cmd+Q (or the window close button).

TROUBLE
  The log is logs/nfsmw_NNN.log. If the screen stays black with
  gpu_backend = "vulkan", try "null" in nfsmw.toml (no rendering, but the
  game runs) and send the log with the report.
