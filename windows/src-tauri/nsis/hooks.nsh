; Uninstall hooks for the NSIS installer.
;
; The app stages coucou-hook.exe into %LOCALAPPDATA%\Coucou\bin at launch, so the
; installer never recorded it and the default uninstaller leaves it behind. The
; inbox, the log (with its rotation and export) and crash reports live in the
; same place and are ours too.
;
; Claude Code's own settings.json is deliberately NOT touched here: it belongs to
; the user, it may contain hooks from other tools, and rewriting somebody's
; config from an uninstaller with no diff and no consent is exactly what the rest
; of this app goes out of its way not to do. A relay that is gone exits 0 without
; printing anything, so a leftover entry costs nothing beyond a dead path.

!macro NSIS_HOOK_PREUNINSTALL
  RMDir /r "$LOCALAPPDATA\Mochi\bin"
  RMDir /r "$LOCALAPPDATA\Mochi\inbox"
  RMDir /r "$LOCALAPPDATA\Mochi\crashes"
  RMDir /r "$LOCALAPPDATA\Mochi\audit"
  Delete "$LOCALAPPDATA\Mochi\mochi.log"
  Delete "$LOCALAPPDATA\Mochi\mochi.log.1"
  Delete "$LOCALAPPDATA\Mochi\mochi-log-export.txt"
  RMDir /r "$LOCALAPPDATA\Coucou\bin"
  RMDir /r "$LOCALAPPDATA\Coucou\inbox"
  RMDir /r "$LOCALAPPDATA\Coucou\crashes"
  Delete "$LOCALAPPDATA\Coucou\coucou.log"
  Delete "$LOCALAPPDATA\Coucou\coucou.log.1"
  Delete "$LOCALAPPDATA\Coucou\coucou-log-export.txt"
!macroend
