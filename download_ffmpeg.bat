@echo off
setlocal

:: Set the destination folder to ./ffmpeg
:: note: %~dp0 is the drive and path of the currently executing script, ending with a backslash
set "dest=%~dp0ffmpeg"

:: Check for previous installs in the destination folder and prompt the user to reinstall if the folder already exists.
if exist "%dest%" (
    choice /C YN /N /M "ffmpeg folder already exists. Reinstall (delete and redownload)? [Y/N] "
    :: errorlevel reflects choice position, so check the higher option (N) first
    if errorlevel 2 goto :eof
    rmdir /s /q "%dest%" || goto :fail
)

:: Download and extract FFmpeg to a temporary location
:: note: %RANDOM% generates a random number to avoid leftovers from a previous failed run
set "zip=%temp%\ffmpeg-%RANDOM%.zip"
set "extract=%temp%\ffmpeg-extract-%RANDOM%"

echo Downloading FFmpeg release essentials (x64)...
curl -L -o "%zip%" "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"
if errorlevel 1 (
    echo Download failed.
    goto :fail
)

:: Unblock the downloaded zip to avoid mark-of-the-web issues
:: note: curl marks the zip as downloaded-from-internet; Expand-Archive would propagate that
::       mark-of-the-web stream to every extracted file, which some network shares reject
:: uncomment the following line if you ran into issues
:: powershell -NoProfile -Command "Unblock-File -LiteralPath '%zip%'"

:: Extract FFmpeg from the downloaded zip
echo Extracting FFmpeg...
powershell -NoProfile -Command "Expand-Archive -LiteralPath '%zip%' -DestinationPath '%extract%' -Force"
if errorlevel 1 (
    echo Extraction failed.
    goto :fail
)

set "pkg="
:: the zip contains a single top-level folder (e.g. ffmpeg-7.1-essentials_build); name varies by version
for /d %%D in ("%extract%\*") do set "pkg=%%D"
if not defined pkg (
    echo Extraction produced no folder.
    goto :fail
)

:: Move the extracted FFmpeg files to the destination folder
:: robocopy instead of move: retries if antivirus briefly locks the freshly extracted
:: .exe files, and handles cross-volume/network destinations more reliably
robocopy "%pkg%" "%dest%" /E /MOVE /R:3 /W:2 /NFL /NDL /NJH
:: robocopy exit codes 0-7 are success; only 8+ means a real failure
if errorlevel 8 (
    echo Failed to move extracted files to %dest%.
    goto :fail
)

:: Clean up temporary extraction and zip files
rmdir /s /q "%extract%" 2>nul
del "%zip%" 2>nul

:: Notify the user that the download and extraction are complete
echo Download complete: %dest%\bin\ffmpeg.exe
pause
exit /b 0

:: Keep a terminal window open to let the user see the error message before exiting
:fail
pause
exit /b 1
