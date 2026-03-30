@echo off
setlocal EnableExtensions EnableDelayedExpansion

REM ==================================================
REM FESTE KONFIGURATION
REM ==================================================
set "sourceDir=C:\Users\WindowsKiste\Documents\isar_community\isar-community"
set "outputFile=C:\Users\WindowsKiste\Documents\isar_community\isar-community\quellcode.txt"

REM ==================================================
REM ERLAUBTE DATEIENDUNGEN (Trennzeichen: Leerzeichen)
REM ==================================================
set "allowedTypes=dart xml yaml swift plist xcconfig sh entitlements lproj storyboard java kt gradle properties pro json pbxproj xcscheme xcworkspacedata modulemap h m"

REM ==================================================
REM EXAKTE DATEINAMEN OHNE ENDUNG
REM ==================================================
set "exactFiles=Jenkinsfile Dockerfile"

REM ==================================================
REM ORDNER DIE IGNORIERT WERDEN SOLLEN
REM ==================================================
set "ignoreDirs=\build\ \assets\ \.dart_tool\ \.idea\ \.gradle\ \.pub-cache\ \.pub\ \.android\ \.ios\ \.plugin_symlinks\ \Generated.xcconfig\ \Pods\ \.symlinks\ \ephemeral\ \FlutterMacOS.framework\ \App.framework\ \Flutter.framework\ \node_modules\ \.git\ \.vscode\ \outputs\ \res\ \mipmap\"

REM ==================================================
REM BINAER-ENDUNGEN DIE IMMER IGNORIERT WERDEN
REM ==================================================
set "binaryExts=\.png$ \.jpg$ \.jpeg$ \.gif$ \.bmp$ \.webp$ \.ico$ \.svg$ \.ttf$ \.otf$ \.woff$ \.woff2$ \.eot$ \.so$ \.dylib$ \.dll$ \.exe$ \.jar$ \.class$ \.dex$ \.apk$ \.aab$ \.ipa$ \.zip$ \.tar$ \.gz$ \.rar$ \.7z$ \.pdf$ \.doc$ \.docx$ \.xls$ \.xlsx$ \.mp3$ \.mp4$ \.wav$ \.ogg$ \.avi$ \.mov$ \.flv$ \.db$ \.sqlite$ \.lock$ \.log$ \.o$ \.a$ \.lib$ \.obj$ \.pdb$ \.iml$ \.keystore$ \.jks$ \.p12$ \.cer$ \.der$ \.crt$ \.DS_Store$"

REM Temp-Dateien
set "tmpAll=%TEMP%\fc_all.txt"
set "tmpIgnore=%TEMP%\fc_ignore.txt"
set "tmpBinary=%TEMP%\fc_binary.txt"
set "tmpAllow=%TEMP%\fc_allow.txt"
set "tmpExact=%TEMP%\fc_exact.txt"
set "tmpFiltered=%TEMP%\fc_filtered.txt"

echo.
echo ===================================================
echo   Flutter Projekt Quellcode Sammler
echo ===================================================
echo Quelle:  "%sourceDir%"
echo Ausgabe: "%outputFile%"
echo.

REM Alte Ausgabedatei loeschen
if exist "%outputFile%" del "%outputFile%"

REM --------------------------------------------------
REM SCHRITT 1: Alle Dateien auflisten (sehr schnell)
REM --------------------------------------------------
echo [1/4] Alle Dateien auflisten ...
dir /S /B /A:-D "%sourceDir%" > "%tmpAll%" 2>nul

set /a totalAll=0
for /F %%A in ('type "%tmpAll%" ^| find /C /V ""') do set /a totalAll=%%A
echo        %totalAll% Dateien im Projekt gefunden.

REM --------------------------------------------------
REM SCHRITT 2: Ignorierte Ordner rausfiltern (1 Aufruf)
REM --------------------------------------------------
echo [2/4] Ignorierte Ordner herausfiltern ...

REM Ignore-Muster in Datei schreiben
if exist "%tmpIgnore%" del "%tmpIgnore%"
for %%D in (%ignoreDirs%) do (
  >> "%tmpIgnore%" echo %%D
)

REM Alles rauswerfen was einen ignorierten Ordner im Pfad hat
findstr /V /I /G:"%tmpIgnore%" "%tmpAll%" > "%tmpFiltered%" 2>nul

set /a afterIgnore=0
for /F %%A in ('type "%tmpFiltered%" ^| find /C /V ""') do set /a afterIgnore=%%A
set /a ignoredCount=totalAll-afterIgnore
echo        %ignoredCount% Dateien in ignorierten Ordnern uebersprungen.

REM --------------------------------------------------
REM SCHRITT 3: Nur erlaubte Endungen + exakte Namen
REM --------------------------------------------------
echo [3/4] Nach Dateitypen filtern ...

REM Erlaubte Endungen als Muster
if exist "%tmpAllow%" del "%tmpAllow%"
for %%T in (%allowedTypes%) do (
  >> "%tmpAllow%" echo \.%%T$
)

REM Binaer-Endungen ausschliessen und erlaubte Endungen einschliessen
if exist "%tmpBinary%" del "%tmpBinary%"
for %%B in (%binaryExts%) do (
  >> "%tmpBinary%" echo %%B
)

REM Erst Binaer raus
findstr /V /I /R /G:"%tmpBinary%" "%tmpFiltered%" > "%tmpAll%" 2>nul
copy /Y "%tmpAll%" "%tmpFiltered%" >nul

REM Dann nur erlaubte Endungen behalten
findstr /I /R /G:"%tmpAllow%" "%tmpFiltered%" > "%tmpAll%" 2>nul

REM Exakte Dateinamen separat suchen
if exist "%tmpExact%" del "%tmpExact%"
for %%N in (%exactFiles%) do (
  >> "%tmpExact%" echo \\%%N$
)
findstr /I /R /G:"%tmpExact%" "%tmpFiltered%" >> "%tmpAll%" 2>nul

REM Output-Datei selbst ausschliessen
findstr /V /I /L /C:"%outputFile%" "%tmpAll%" > "%tmpFiltered%" 2>nul

set /a total=0
for /F %%A in ('type "%tmpFiltered%" ^| find /C /V ""') do set /a total=%%A
echo        %total% passende Dateien nach Filterung.
echo.

if %total% equ 0 (
  echo Keine passenden Dateien gefunden. Abbruch.
  pause
  goto :cleanup
)

REM --------------------------------------------------
REM SCHRITT 4: Dateien zusammenfuehren
REM --------------------------------------------------
echo [4/4] Sammle %total% Dateien ...
echo.

set /a processed=0
set "lastDir="

for /F "usebackq delims=" %%f in ("%tmpFiltered%") do (
  set /a processed+=1
  set "currentDir=%%~dpf"
  set "relDir=!currentDir:%sourceDir%\=!"

  REM Ordnerwechsel anzeigen
  if not "!currentDir!"=="!lastDir!" (
    set "lastDir=!currentDir!"
    echo.
    echo   --- !relDir! ---
  )

  echo   [!processed!/%total%] %%~nxf

  >> "%outputFile%" echo ========================================
  >> "%outputFile%" echo Datei: %%f
  >> "%outputFile%" echo ========================================
  type "%%f" >> "%outputFile%"
  >> "%outputFile%" echo.
)

echo.
echo ===================================================
echo   Fertig! %processed% von %totalAll% Dateien gesammelt.
echo   Ausgabe: "%outputFile%"
echo ===================================================

:cleanup
if exist "%tmpAll%" del "%tmpAll%"
if exist "%tmpIgnore%" del "%tmpIgnore%"
if exist "%tmpBinary%" del "%tmpBinary%"
if exist "%tmpAllow%" del "%tmpAllow%"
if exist "%tmpExact%" del "%tmpExact%"
if exist "%tmpFiltered%" del "%tmpFiltered%"
pause