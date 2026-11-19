; Windows 10 미만이면 설치를 멈춘다(tauri.conf.json 에는 윈도우 최소 버전 키가 없다).
; 문구는 영어로 둔다 — BOM 없는 UTF-8 .nsh 의 한글은 NSIS 에서 깨질 수 있다.
!include "LogicLib.nsh"
!include "WinVer.nsh"

!macro NSIS_HOOK_PREINSTALL
  ${IfNot} ${AtLeastWin10}
    MessageBox MB_ICONSTOP "EarShot requires Windows 10 or later."
    Abort
  ${EndIf}
!macroend
