@echo off
setlocal EnableExtensions
chcp 936 >nul

if not defined HERMES_BASEURL set "HERMES_BASEURL=http://192.0.2.44:18090"
set "BASEURL=%HERMES_BASEURL%"
set "STARTPS=D:\start.ps1"
set "WORKDIR=%TEMP%\hermes-win-agent"
set "HOSTFILE=%TEMP%\hermes-win-agent-hostid.txt"

:ensure_startps
if not exist "%STARTPS%" goto download_startps
goto menu

:download_startps
echo.
echo [Hermes] 首次运行，正在下载 start.ps1 ...
powershell -NoProfile -ExecutionPolicy Bypass -Command "iwr -UseBasicParsing '%BASEURL%/start.ps1' -OutFile '%STARTPS%'"
if errorlevel 1 goto error
echo [完成] start.ps1 已下载到 %STARTPS%
goto menu

:menu
cls
echo ==================================================
echo              Hermes 远程管理菜单
echo ==================================================
echo.
call :quick_status
echo.
echo  连接/重连被控端：
echo    1.  win-lab-a  - 192.0.2.44:19101
echo    2.  win-lab-b  - 192.0.2.44:19102
echo    3.  win-test-c  - 192.0.2.44:19103
echo    4.  win04  - 192.0.2.44:19104
echo    5.  win05  - 192.0.2.44:19105
echo    6.  win06  - 192.0.2.44:19106
echo    7.  win07  - 192.0.2.44:19107
echo    8.  win08  - 192.0.2.44:19108
echo    9.  win09  - 192.0.2.44:19109
echo    10. win10  - 192.0.2.44:19110
echo.
echo  管理功能：
echo    S.  查看详细状态
echo    C.  检查环境
echo    T.  停止/断开
echo    R.  重启上次选择的编号
echo    U.  安全更新 start.ps1
echo    A.  同步全部文件（agent/config/scripts）
echo    O.  打开工作目录
echo    L.  查看日志
echo    Q.  退出
echo.
set /p "CHOICE=请选择: "

if /i "%CHOICE%"=="Q" exit /b 0
if /i "%CHOICE%"=="S" goto status
if /i "%CHOICE%"=="C" goto check
if /i "%CHOICE%"=="T" goto stop
if /i "%CHOICE%"=="R" goto restart
if /i "%CHOICE%"=="U" goto update
if /i "%CHOICE%"=="A" goto sync_all
if /i "%CHOICE%"=="O" goto open_dir
if /i "%CHOICE%"=="L" goto logs

if "%CHOICE%"=="1" set "HOSTID=win-lab-a"& goto start_host
if "%CHOICE%"=="2" set "HOSTID=win-lab-b"& goto start_host
if "%CHOICE%"=="3" set "HOSTID=win-test-c"& goto start_host
if "%CHOICE%"=="4" set "HOSTID=win04"& goto start_host
if "%CHOICE%"=="5" set "HOSTID=win05"& goto start_host
if "%CHOICE%"=="6" set "HOSTID=win06"& goto start_host
if "%CHOICE%"=="7" set "HOSTID=win07"& goto start_host
if "%CHOICE%"=="8" set "HOSTID=win08"& goto start_host
if "%CHOICE%"=="9" set "HOSTID=win09"& goto start_host
if "%CHOICE%"=="10" set "HOSTID=win10"& goto start_host

echo 选择无效，请重试。
pause
goto menu

:quick_status
set "LASTHOST=未选择"
if exist "%HOSTFILE%" set /p LASTHOST=<"%HOSTFILE%"
set "AGENT=已停止"
set "CHISEL=已停止"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p=Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort 18888 -State Listen -ErrorAction SilentlyContinue; if($p){exit 0}else{exit 1}" >nul 2>nul
if not errorlevel 1 set "AGENT=运行中"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p=Get-CimInstance Win32_Process -Filter \"Name='chisel.exe'\" -ErrorAction SilentlyContinue | ? { $_.CommandLine -like '*hermes-win-agent*' }; if($p){exit 0}else{exit 1}" >nul 2>nul
if not errorlevel 1 set "CHISEL=运行中"
echo  当前状态：Agent=%AGENT%  Chisel=%CHISEL%  上次编号=%LASTHOST%
echo  工作目录：%WORKDIR%
exit /b 0

:start_host
echo %HOSTID%>"%HOSTFILE%"
echo.
echo 正在启动 %HOSTID% ...
powershell -NoProfile -ExecutionPolicy Bypass -File "%STARTPS%" -HostId %HOSTID% -Action start -BaseUrl "%BASEURL%"
echo.
echo 健康检查：
curl.exe -s http://127.0.0.1:18888/health
echo.
pause
goto menu

:restart
if exist "%HOSTFILE%" set /p HOSTID=<"%HOSTFILE%"
if not defined HOSTID (
  echo 没有上次选择的编号，请先选 1-10 连接一次。
  pause
  goto menu
)
echo 正在重启 %HOSTID% ...
powershell -NoProfile -ExecutionPolicy Bypass -File "%STARTPS%" -Action stop
powershell -NoProfile -ExecutionPolicy Bypass -File "%STARTPS%" -HostId %HOSTID% -Action start -BaseUrl "%BASEURL%"
pause
goto menu

:status
powershell -NoProfile -ExecutionPolicy Bypass -File "%STARTPS%" -Action status
pause
goto menu

:check
powershell -NoProfile -ExecutionPolicy Bypass -File "%STARTPS%" -Action check -BaseUrl "%BASEURL%"
pause
goto menu

:stop
powershell -NoProfile -ExecutionPolicy Bypass -File "%STARTPS%" -Action stop
pause
goto menu

:update
echo.
echo [Hermes] 正在安全更新 start.ps1 ...
powershell -NoProfile -ExecutionPolicy Bypass -Command "iwr -UseBasicParsing '%BASEURL%/start.ps1' -OutFile '%STARTPS%.new'"
if errorlevel 1 (
  echo [失败] 新版下载失败，旧版 start.ps1 已保留
  del "%STARTPS%.new" 2>nul
  pause
  goto menu
)
move /Y "%STARTPS%.new" "%STARTPS%" >nul
if errorlevel 1 (
  echo [失败] 替换失败（磁盘空间或文件占用）。旧版 start.ps1 已保留
  del "%STARTPS%.new" 2>nul
  pause
  goto menu
)
echo [完成] start.ps1 已更新：%STARTPS%
pause
goto menu

:sync_all
echo.
echo [Hermes] 从 %BASEURL% 同步全部文件（agent/config/scripts）...
powershell -NoProfile -ExecutionPolicy Bypass -File "%STARTPS%" -Action check -BaseUrl "%BASEURL%"
echo.
echo [完成] 同步完毕。如 agent 已在运行，需重启生效：先选 T 停止，再选主机编号启动。
pause
goto menu

:open_dir
for %%I in ("%STARTPS%") do set "PSDIR=%%~dpI"
if not exist "%PSDIR%" mkdir "%PSDIR%" 2>nul
start "" explorer "%PSDIR%"
goto menu

:logs
echo.
echo chisel 客户端日志：
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-Content '$env:TEMP\hermes-win-agent\logs\chisel-client.err.log' -Tail 80 -ErrorAction SilentlyContinue"
echo.
echo agent 运行日志：
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-Content '$env:TEMP\hermes-win-agent\logs\agent.stderr.log' -Tail 40 -ErrorAction SilentlyContinue"
echo.
pause
goto menu

:error
echo.
echo 失败。请检查网络，或以管理员 PowerShell 手动运行。
pause
exit /b 1
