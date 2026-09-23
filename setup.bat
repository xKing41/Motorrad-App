@echo off
setlocal EnableExtensions
title Schraeglage - Automatische Einrichtung und APK-Build (v4.7)

REM ================================================================
REM  SCHRAEGLAGE  -  Ein-Klick-Setup fuer Windows  (v4.7)
REM  Laedt alles Noetige (Git, Java, Flutter, Android-Tools),
REM  baut die App und legt die fertige APK auf den Desktop.
REM  Erzeugt den Android-Ordner bei jedem Lauf frisch neu und ersetzt
REM  den Code-Ordner lib komplett (keine Reste alter Versionen).
REM ================================================================

set "BASE=C:\dev"
set "TOOLS=%BASE%\moto-tools"
set "PROJ=%BASE%\schraeglage"
set "SRC=%~dp0app"
set "PS=powershell -NoProfile -ExecutionPolicy Bypass -Command"

echo ==============================================================
echo    SCHRAEGLAGE  -  Automatische Einrichtung + APK-Build v4.7
echo ==============================================================
echo.
echo  Beim ersten Lauf werden ca. 1-2 GB heruntergeladen.
echo  Bereits erledigte Schritte werden uebersprungen.
echo.
echo  WICHTIG: Fenster einfach offen lassen, nichts schliessen.
echo ==============================================================
echo.

if not exist "%SRC%\lib\main.dart" (
    echo [FEHLER] Quellcode nicht gefunden!
    echo Diese setup.bat muss im entpackten Ordner liegen -
    echo direkt neben dem Ordner "app".
    goto :end
)

mkdir "%BASE%" 2>nul
mkdir "%TOOLS%" 2>nul
if not exist "%TOOLS%" (
    echo [FEHLER] Konnte den Ordner %TOOLS% nicht anlegen.
    goto :end
)

set "GRADLE_USER_HOME=%TOOLS%\gradle"
set "PUB_CACHE=%TOOLS%\pub"

REM ---------------- [1/6] Git ----------------
where git >nul 2>&1
if not errorlevel 1 (
    echo [1/6] Git ist bereits installiert - ok.
    goto :git_done
)
if exist "%TOOLS%\git\cmd\git.exe" (
    echo [1/6] Portables Git bereits vorhanden - ok.
    goto :git_path
)
echo [1/6] Lade portables Git herunter...
%PS% "$ProgressPreference='SilentlyContinue';[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;$r=Invoke-RestMethod 'https://api.github.com/repos/git-for-windows/git/releases/latest';$a=$r.assets | Where-Object {$_.name -like 'MinGit-*-64-bit.zip'} | Select-Object -First 1;Invoke-WebRequest $a.browser_download_url -OutFile '%TOOLS%\git.zip'"
if not exist "%TOOLS%\git.zip" goto :dl_fail
%PS% "Expand-Archive -LiteralPath '%TOOLS%\git.zip' -DestinationPath '%TOOLS%\git' -Force"
del "%TOOLS%\git.zip" 2>nul
:git_path
set "PATH=%TOOLS%\git\cmd;%PATH%"
:git_done

REM ---------------- [2/6] Java (JDK 21, portabel) ----------------
if exist "%TOOLS%\jdk" goto :jdk_find
echo [2/6] Lade Java JDK herunter...
%PS% "$ProgressPreference='SilentlyContinue';[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;Invoke-WebRequest 'https://api.adoptium.net/v3/binary/latest/21/ga/windows/x64/jdk/hotspot/normal/eclipse?project=jdk' -OutFile '%TOOLS%\jdk.zip'"
if not exist "%TOOLS%\jdk.zip" goto :dl_fail
%PS% "Expand-Archive -LiteralPath '%TOOLS%\jdk.zip' -DestinationPath '%TOOLS%\jdk' -Force"
del "%TOOLS%\jdk.zip" 2>nul
:jdk_find
set "JAVA_HOME="
for /d %%D in ("%TOOLS%\jdk\jdk-*") do set "JAVA_HOME=%%D"
if not defined JAVA_HOME (
    echo [FEHLER] Java-Installation nicht gefunden.
    goto :end
)
set "PATH=%JAVA_HOME%\bin;%PATH%"
echo [2/6] Java ok: %JAVA_HOME%

REM ---------------- [3/6] Flutter ----------------
if exist "%TOOLS%\flutter\bin\flutter.bat" (
    echo [3/6] Flutter bereits vorhanden - ok.
    goto :flutter_path
)
echo [3/6] Lade Flutter herunter (groesster Download, bitte warten)...
%PS% "$ProgressPreference='SilentlyContinue';[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;$j=Invoke-RestMethod 'https://storage.googleapis.com/flutter_infra_release/releases/releases_windows.json';$h=$j.current_release.stable;$r=$j.releases | Where-Object {$_.hash -eq $h} | Select-Object -First 1;Invoke-WebRequest ($j.base_url+'/'+$r.archive) -OutFile '%TOOLS%\flutter.zip'"
if not exist "%TOOLS%\flutter.zip" goto :dl_fail
echo [3/6] Entpacke Flutter (dauert ein paar Minuten)...
%PS% "Expand-Archive -LiteralPath '%TOOLS%\flutter.zip' -DestinationPath '%TOOLS%' -Force"
del "%TOOLS%\flutter.zip" 2>nul
:flutter_path
set "PATH=%TOOLS%\flutter\bin;%PATH%"

REM ---------------- [4/6] Android-Tools + Lizenzen ----------------
set "ANDROID_HOME=%TOOLS%\android"
set "SDKMGR=%ANDROID_HOME%\cmdline-tools\latest\bin\sdkmanager.bat"
if exist "%SDKMGR%" (
    echo [4/6] Android-Tools bereits vorhanden - ok.
    goto :android_done
)
echo [4/6] Lade Android-Tools herunter...
%PS% "$ProgressPreference='SilentlyContinue';[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;Invoke-WebRequest 'https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip' -OutFile '%TOOLS%\cmdtools.zip'"
if not exist "%TOOLS%\cmdtools.zip" goto :dl_fail
%PS% "Expand-Archive -LiteralPath '%TOOLS%\cmdtools.zip' -DestinationPath '%TOOLS%\_cmdtmp' -Force"
del "%TOOLS%\cmdtools.zip" 2>nul
mkdir "%ANDROID_HOME%\cmdline-tools" 2>nul
move "%TOOLS%\_cmdtmp\cmdline-tools" "%ANDROID_HOME%\cmdline-tools\latest" >nul
rmdir /s /q "%TOOLS%\_cmdtmp" 2>nul
:android_done
set "PATH=%ANDROID_HOME%\platform-tools;%PATH%"
echo [4/6] Akzeptiere Android-Lizenzen (auch neu hinzugekommene)...
(for /L %%i in (1,1,50) do @echo y) | cmd /c ""%SDKMGR%" --sdk_root="%ANDROID_HOME%" --licenses" >nul 2>&1
echo y|cmd /c ""%SDKMGR%" --sdk_root="%ANDROID_HOME%" platform-tools" >nul 2>&1
(for /L %%i in (1,1,50) do @echo y) | cmd /c ""%SDKMGR%" --sdk_root="%ANDROID_HOME%" "platforms;android-36" "build-tools;36.0.0"" >nul 2>&1

REM ---------------- [5/6] Projekt anlegen / reparieren ----------------
echo [5/6] Richte Flutter ein und erneuere das Projekt...
call flutter config --no-analytics >nul 2>&1
call flutter config --android-sdk "%ANDROID_HOME%" >nul 2>&1
call flutter config --jdk-dir "%JAVA_HOME%" >nul 2>&1
REM Lizenzen zusaetzlich ueber Flutter bestaetigen. Die des sdkmanagers
REM allein akzeptiert "flutter doctor" nicht. Muss NACH --android-sdk laufen.
(for /L %%i in (1,1,50) do @echo y) | cmd /c "flutter doctor --android-licenses" >nul 2>&1
if not exist "%PROJ%\pubspec.yaml" (
    call flutter create "%PROJ%" --platforms=android --project-name schraeglage
    if errorlevel 1 goto :build_fail
)
cd /d "%PROJ%"
REM Android-Ordner immer frisch aus der aktuellen Flutter-Vorlage erzeugen.
REM Das behebt Fehler durch veraltete oder beschaedigte Build-Dateien.
if exist "%PROJ%\android\gradlew.bat" call "%PROJ%\android\gradlew.bat" --stop >nul 2>&1
rmdir /s /q "%PROJ%\android" 2>nul
call flutter create . --platforms=android --project-name schraeglage >nul
if errorlevel 1 goto :build_fail
copy /Y "%SRC%\pubspec.yaml" "%PROJ%\pubspec.yaml" >nul
REM lib vorher komplett loeschen: xcopy ueberschreibt nur, es entfernt
REM nichts. Eine in der neuen Version geloeschte oder umbenannte Datei
REM bliebe sonst liegen, wuerde mitgebaut und kann den Build brechen.
if exist "%PROJ%\lib" rmdir /s /q "%PROJ%\lib"
xcopy /Y /E /I "%SRC%\lib" "%PROJ%\lib" >nul
if exist "%SRC%\android" xcopy /Y /E /I "%SRC%\android" "%PROJ%\android" >nul
REM minSdk auf 24 setzen - OHNE BOM schreiben (WriteAllText = UTF-8 ohne BOM).
REM Repariert dabei auch Dateien, die frueher versehentlich ein BOM bekamen.
echo [5/6] Setze Android-Versionen (compileSdk 36)...
%PS% "$targets=@('%PROJ%\android\app\build.gradle.kts','%PROJ%\android\app\build.gradle'); foreach($p in $targets){ if(Test-Path $p){ $c=[System.IO.File]::ReadAllText($p); $c=$c -replace 'flutter\.minSdkVersion','24' -replace 'flutter\.compileSdkVersion','36' -replace 'flutter\.targetSdkVersion','36'; [System.IO.File]::WriteAllText($p,$c) } }"
REM Alle Plugin-Module ebenfalls auf compileSdk 36 heben. Ohne das
REM blockiert ein einzelnes veraltetes Plugin den gesamten Build.
%PS% "$root='%PROJ%\android\build.gradle.kts'; $fix='%PROJ%\android\compilesdk-fix.txt'; if((Test-Path $root) -and (Test-Path $fix)){ $c=[System.IO.File]::ReadAllText($root); if($c -notmatch 'erzwingt compileSdk 36'){ [System.IO.File]::WriteAllText($root, $c + [Environment]::NewLine + [System.IO.File]::ReadAllText($fix)) } }"
call flutter clean >nul 2>&1
call flutter pub get
if errorlevel 1 goto :build_fail

REM ---------------- [6/6] APK bauen ----------------
echo.
echo [6/6] Baue die App... (beim ersten Mal 5-20 Minuten,
echo        es werden weitere Android-Komponenten nachgeladen)
echo.
call flutter build apk --release
if errorlevel 1 goto :build_fail

set "APK=%PROJ%\build\app\outputs\flutter-apk\app-release.apk"
if not exist "%APK%" goto :build_fail

copy /Y "%APK%" "%USERPROFILE%\Desktop\Schraeglage.apk" >nul 2>&1
if exist "%USERPROFILE%\Desktop\Schraeglage.apk" (
    set "APK=%USERPROFILE%\Desktop\Schraeglage.apk"
)

REM Bequemes Neubau-Skript fuer spaeter erzeugen
(
    echo @echo off
    echo title Schraeglage neu bauen
    echo set "JAVA_HOME=%JAVA_HOME%"
    echo set "ANDROID_HOME=%ANDROID_HOME%"
    echo set "GRADLE_USER_HOME=%GRADLE_USER_HOME%"
    echo set "PUB_CACHE=%PUB_CACHE%"
    echo set "PATH=%TOOLS%\flutter\bin;%JAVA_HOME%\bin;%TOOLS%\git\cmd;%%PATH%%"
    echo cd /d "%PROJ%"
    echo call flutter build apk --release
    echo copy /Y "%PROJ%\build\app\outputs\flutter-apk\app-release.apk" "%%USERPROFILE%%\Desktop\Schraeglage.apk"
    echo pause
) > "%BASE%\schraeglage-neu-bauen.bat"

echo.
echo ==============================================================
echo    FERTIG! Die App wurde erfolgreich gebaut.
echo ==============================================================
echo.
echo  Deine APK liegt hier:
echo    %APK%
echo.
echo  So kommt sie aufs Handy:
echo    1. Datei "Schraeglage.apk" aufs Handy uebertragen
echo       (USB-Kabel, WhatsApp an dich selbst, E-Mail, ...)
echo    2. Am Handy antippen und installieren
echo    3. Falls gefragt: "Unbekannte Apps installieren" erlauben
echo    4. Beim ersten App-Start: Standort-Berechtigung ERLAUBEN
echo    5. Karte + Routenplanung: Tab KARTE unten in der App
echo.
echo  Fuer spaetere Aenderungen: C:\dev\schraeglage-neu-bauen.bat
echo.
explorer /select,"%APK%"
goto :end

:dl_fail
echo.
echo [FEHLER] Ein Download ist fehlgeschlagen.
echo Bitte Internetverbindung pruefen (Firewall/Antivirus?) und
echo setup.bat einfach nochmal starten - es macht dort weiter,
echo wo es aufgehoert hat.
goto :end

:build_fail
echo.
echo [FEHLER] Der Build ist fehlgeschlagen.
echo Tipp: setup.bat einfach nochmal starten - oft hilft das schon.
echo Details zur Fehlersuche:
call flutter doctor
goto :end

:end
echo.
pause
