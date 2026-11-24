@echo off
rem Molehill Manager, for scripts and for anything that reads the output or the exit code.
rem
rem MolehillManager.exe is a windowed program, so that double-clicking it does not leave an empty
rem console window behind the screen. The price is that most shells do not wait for a windowed
rem child. Measured on Windows 11, running --selftest-setup which takes about 18 seconds:
rem
rem                                       waited   exit code              redirected output
rem   PowerShell      .exe                no       $LASTEXITCODE not set  file left empty
rem   cmd prompt      .exe                no       stale                  filled in afterwards
rem   cmd /c a.cmd    .exe                yes      correct                complete
rem   PowerShell      .cmd  (this file)   yes      correct                complete
rem   cmd             .cmd  (this file)   yes      correct                complete
rem
rem So a batch file calling the .exe is fine, and everything a person actually types is not. Run
rem this instead and it behaves the way a console program always did:
rem
rem   .\MolehillManager.cmd --selftest
rem   .\MolehillManager.cmd --install
rem
rem Nothing inside the .exe can fix this, which is why there are two files in the folder rather
rem than one. Double-clicking the .exe is still all anyone needs in order to use the app.

start /wait /b "" "%~dp0MolehillManager.exe" %*
exit /b %ERRORLEVEL%
