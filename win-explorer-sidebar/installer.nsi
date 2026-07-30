Unicode true
RequestExecutionLevel user
SetCompressor /SOLID lzma
CRCCheck on
ShowInstDetails nevershow
ShowUninstDetails nevershow

!include "MUI2.nsh"

!ifndef APP_NAME
  !error "APP_NAME is required"
!endif
!ifndef APP_EXE
  !error "APP_EXE is required"
!endif
!ifndef APP_ID
  !error "APP_ID is required"
!endif
!ifndef PAYLOAD_DIR
  !error "PAYLOAD_DIR is required"
!endif
!ifndef OUTPUT_FILE
  !error "OUTPUT_FILE is required"
!endif
!ifndef APP_ICON
  !error "APP_ICON is required"
!endif
; 版本由 build_release.sh 的 FOLDERIS_APP_VERSION 注入（与 csproj 的 -p:Version 同源）：
; APP_VERSION 是展示版本（如 1.1.0），APP_VERSION_FULL 是补齐四段的资源版本（如 1.1.0.0）。
!ifndef APP_VERSION
  !error "APP_VERSION is required"
!endif
!ifndef APP_VERSION_FULL
  !error "APP_VERSION_FULL is required"
!endif

Name "${APP_NAME}"
OutFile "${OUTPUT_FILE}"
InstallDir "$LOCALAPPDATA\Programs\${APP_NAME}"
InstallDirRegKey HKCU "Software\Folderis\${APP_ID}" "InstallDir"
Icon "${APP_ICON}"
UninstallIcon "${APP_ICON}"

VIProductVersion "${APP_VERSION_FULL}"
VIAddVersionKey /LANG=1033 "ProductName" "${APP_NAME}"
VIAddVersionKey /LANG=1033 "CompanyName" "Folderis"
VIAddVersionKey /LANG=1033 "LegalCopyright" "Copyright 2026 Folderis"
VIAddVersionKey /LANG=1033 "FileDescription" "${APP_NAME} Setup"
VIAddVersionKey /LANG=1033 "FileVersion" "${APP_VERSION_FULL}"
VIAddVersionKey /LANG=1033 "ProductVersion" "${APP_VERSION}"

!define MUI_ABORTWARNING
!define MUI_ICON "${APP_ICON}"
!define MUI_UNICON "${APP_ICON}"
!define MUI_FINISHPAGE_RUN "$INSTDIR\${APP_EXE}"
!define MUI_FINISHPAGE_RUN_TEXT "Launch ${APP_NAME}"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "SimpChinese"
!insertmacro MUI_LANGUAGE "English"

Function .onInit
  ; /S 静默安装必须零 UI：跳过语言选择框。
  ; 静默模式下 MUI 的欢迎/目录/进度/完成页本身就不显示。
  IfSilent skip_langdll
  !insertmacro MUI_LANGDLL_DISPLAY
  skip_langdll:
FunctionEnd

Section "Install" SEC_MAIN
  SectionIn RO
  SetShellVarContext current

  DetailPrint "Stopping an older ${APP_NAME} process if present..."
  nsExec::ExecToLog 'taskkill /F /IM "${APP_EXE}"'
  Sleep 300

  SetDetailsPrint textonly
  DetailPrint "正在清理旧版 Folderis 组件，请稍候..."
  SetDetailsPrint none
  RMDir /r "$LOCALAPPDATA\Sider\python"
  RMDir /r "$LOCALAPPDATA\Sider\skills"
  Delete "$LOCALAPPDATA\Sider\skills.py"
  Delete "$LOCALAPPDATA\Sider\catalog.txt"
  Delete "$LOCALAPPDATA\Sider\RUNTIME_VERSION"
  Delete "$LOCALAPPDATA\Sider\SKILLS_VERSION"

  SetDetailsPrint textonly
  DetailPrint "正在安装 ${APP_NAME}，请稍候..."
  SetDetailsPrint none
  RMDir /r "$INSTDIR"
  SetOutPath "$INSTDIR"
  SetOverwrite on
  File /r "${PAYLOAD_DIR}\*"
  SetDetailsPrint textonly
  DetailPrint "正在完成安装..."

  IfFileExists "$INSTDIR\${APP_EXE}" payload_ok
    ; /SD IDOK：静默安装时不弹窗（否则会卡住无人值守的自动更新），直接失败退出
    MessageBox MB_ICONSTOP|MB_OK "Folderis.exe is missing from the installer payload." /SD IDOK
    Abort
  payload_ok:

  WriteUninstaller "$INSTDIR\Uninstall.exe"
  WriteRegStr HKCU "Software\Folderis\${APP_ID}" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_ID}" \
    "DisplayName" "${APP_NAME}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_ID}" \
    "DisplayIcon" "$INSTDIR\${APP_EXE}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_ID}" \
    "DisplayVersion" "${APP_VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_ID}" \
    "Publisher" "Folderis"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_ID}" \
    "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_ID}" \
    "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_ID}" \
    "NoRepair" 1

  CreateShortCut "$DESKTOP\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}" "" \
    "$INSTDIR\${APP_EXE}" 0 SW_SHOWNORMAL "" "${APP_NAME}"
  CreateDirectory "$SMPROGRAMS\Folderis"
  CreateShortCut "$SMPROGRAMS\Folderis\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}" "" \
    "$INSTDIR\${APP_EXE}" 0 SW_SHOWNORMAL "" "${APP_NAME}"
  CreateShortCut "$SMPROGRAMS\Folderis\Uninstall ${APP_NAME}.lnk" "$INSTDIR\Uninstall.exe"
SectionEnd

Section "Uninstall"
  SetShellVarContext current
  nsExec::ExecToLog 'taskkill /F /IM "${APP_EXE}"'
  Sleep 300
  Delete "$DESKTOP\${APP_NAME}.lnk"
  Delete "$SMPROGRAMS\Folderis\${APP_NAME}.lnk"
  Delete "$SMPROGRAMS\Folderis\Uninstall ${APP_NAME}.lnk"
  RMDir "$SMPROGRAMS\Folderis"
  DeleteRegKey HKCU "Software\Folderis\${APP_ID}"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_ID}"
  RMDir /r "$INSTDIR"
SectionEnd
