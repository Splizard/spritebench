# Idempotent provisioning for the Windows benchmark runner. Invoked on the
# Windows machine by run-windows.sh (via a one-shot scheduled task so the
# long installs survive ssh disconnects). Installs toolchains via winget,
# Godot editors + Windows export templates, and pinned third-party sources
# under $env:USERPROFILE\spritebench-bench.
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

# Keep these in sync with the ARGs in bench/Containerfile.
$GODOT_VERSION = "4.6-stable"
$GODOT_NEXT_VERSION = "4.7-stable"
$ODIN_VERSION = "dev-2026-07a"
$TOXIN_COMMIT = "9b4652e"
$GD_CLASSES_COMMIT = "958d411"
$GODOT_CPP_COMMIT = "60b5a4196de8442b43b32ba68ebe1e79cfcb762f"

$ROOT = "$env:USERPROFILE\spritebench-bench"
foreach ($d in "bin", "godot", "cache", "work", "results") {
    New-Item -ItemType Directory -Force -Path "$ROOT\$d" | Out-Null
}

function Log($msg) { Write-Output "-- $msg" }

function WingetEnsure($id, $extra) {
    $listed = winget list --id $id --accept-source-agreements 2>$null | Select-String $id
    if ($listed) { Log "$id already installed"; return }
    Log "installing $id"
    $args = @("install", "--id", $id, "-e", "--silent",
              "--accept-package-agreements", "--accept-source-agreements",
              "--disable-interactivity")
    if ($extra) { $args += $extra }
    & winget @args | Select-Object -Last 3
}

# MSVC toolchain: required by godot-cpp (scons), rust (msvc ABI), odin
# (link.exe) and swift. This is the big one (~30+ min on first install).
# Installed via the official bootstrapper: winget's --override route kept
# failing with 1602 even elevated.
if (-not (Test-Path "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC")) {
    Log "installing VS Build Tools (VC workload, takes a while)"
    Invoke-WebRequest -Uri "https://aka.ms/vs/17/release/vs_BuildTools.exe" -OutFile "$env:TEMP\vs_BuildTools.exe"
    $p = Start-Process -FilePath "$env:TEMP\vs_BuildTools.exe" -ArgumentList `
        "--quiet", "--wait", "--norestart", "--nocache", `
        "--add", "Microsoft.VisualStudio.Workload.VCTools", "--includeRecommended" `
        -Wait -PassThru
    Log "vs_BuildTools exit code: $($p.ExitCode)"
    Remove-Item "$env:TEMP\vs_BuildTools.exe" -ErrorAction SilentlyContinue
} else {
    Log "VS Build Tools already installed"
}

WingetEnsure "Rustlang.Rustup" $null
WingetEnsure "Microsoft.DotNet.SDK.10" $null
WingetEnsure "Python.Python.3.12" $null
WingetEnsure "Swift.Toolchain" $null

# Refresh PATH from the registry so tools installed above resolve now.
$env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
            [Environment]::GetEnvironmentVariable("Path", "User")

Log "rust stable toolchain"
& rustup default stable 2>&1 | Select-Object -Last 1

# The WindowsApps store stub shadows the real python on PATH; resolve the
# actual interpreter explicitly.
$python = Get-ChildItem "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe", `
                        "C:\Program Files\Python3*\python.exe" `
          -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $python) { Write-Output "!! real python not found; scons will be missing" }
else {
    Log "scons via pip ($($python.FullName))"
    & $python.FullName -m pip install --quiet scons 2>&1 | Select-Object -Last 1
    Set-Content -Path "$ROOT\python-path.txt" -Value $python.FullName -NoNewline
}

Log "mingw-w64 gcc (cgo needs a C compiler for the Go graphics.gd build)"
if (-not (Test-Path "$ROOT\mingw64\bin\gcc.exe")) {
    $url = "https://github.com/brechtsanders/winlibs_mingw/releases/download/14.2.0posix-19.1.1-12.0.0-ucrt-r2/winlibs-x86_64-posix-seh-gcc-14.2.0-mingw-w64ucrt-12.0.0-r2.zip"
    Invoke-WebRequest -Uri $url -OutFile "$env:TEMP\mingw.zip"
    Expand-Archive -Path "$env:TEMP\mingw.zip" -DestinationPath "$ROOT" -Force
    Remove-Item "$env:TEMP\mingw.zip"
}

function FetchGodot($zip, $sub, $exeGlob) {
    $dest = "$ROOT\godot\$sub"
    if (Test-Path "$dest\ok") { Log "godot $sub already present"; return }
    Log "godot: $zip"
    $ver = ($zip -replace "^Godot_v", "") -replace "_.*$", ""
    Remove-Item -Recurse -Force $dest -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    $url = "https://github.com/godotengine/godot/releases/download/$ver/$zip"
    Invoke-WebRequest -Uri $url -OutFile "$env:TEMP\godot-dl.zip"
    Expand-Archive -Path "$env:TEMP\godot-dl.zip" -DestinationPath $dest -Force
    Remove-Item "$env:TEMP\godot-dl.zip"
    $exe = Get-ChildItem -Path $dest -Recurse -Filter $exeGlob |
        Where-Object { $_.Name -notmatch "console" } | Select-Object -First 1
    if (-not $exe) { Write-Output "!! no editor exe found in $zip"; return }
    Set-Content -Path "$dest\editor-path.txt" -Value $exe.FullName -NoNewline
    Set-Content -Path "$dest\ok" -Value "ok"
}
FetchGodot "Godot_v${GODOT_VERSION}_win64.exe.zip"      "godot"      "Godot_*win64.exe"
FetchGodot "Godot_v${GODOT_VERSION}_mono_win64.zip"     "godot-mono" "Godot_*win64.exe"
FetchGodot "Godot_v${GODOT_NEXT_VERSION}_win64.exe.zip" "godot-next" "Godot_*win64.exe"

# bash-style shims (no extension, LF endings) so the shared bench scripts
# can invoke godot/godot-mono/godot-next by name from git-bash.
foreach ($pair in @(@("godot", "godot"), @("godot-mono", "godot-mono"), @("godot-next", "godot-next"))) {
    $sub, $name = $pair
    $exePath = Get-Content "$ROOT\godot\$sub\editor-path.txt" -ErrorAction SilentlyContinue
    if ($exePath) {
        $msysPath = "/" + ($exePath -replace "\\", "/" -replace ":", "")
        $shim = "#!/bin/sh`nexec `"$msysPath`" `"`$@`"`n"
        [IO.File]::WriteAllText("$ROOT\bin\$name", $shim.Replace("`r`n", "`n"))
    }
}

function FetchTemplates($ver, $tpz, $sub) {
    $dest = "$env:APPDATA\Godot\export_templates\$sub"
    if ((Test-Path "$dest\windows_release_x86_64.exe")) { Log "templates $sub already present"; return }
    Log "export templates: $sub"
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    $url = "https://github.com/godotengine/godot/releases/download/$ver/$tpz"
    # A .tpz is a zip with a templates/ prefix, but Expand-Archive refuses
    # anything not named .zip, so download it under that name.
    Invoke-WebRequest -Uri $url -OutFile "$env:TEMP\godot-t.zip"
    Expand-Archive -Path "$env:TEMP\godot-t.zip" -DestinationPath "$env:TEMP\godot-t" -Force
    foreach ($f in "windows_debug_x86_64.exe", "windows_release_x86_64.exe",
                   "windows_debug_x86_64_console.exe", "windows_release_x86_64_console.exe") {
        Copy-Item "$env:TEMP\godot-t\templates\$f" "$dest\$f" -ErrorAction SilentlyContinue
    }
    Remove-Item -Recurse -Force "$env:TEMP\godot-t", "$env:TEMP\godot-t.zip" -ErrorAction SilentlyContinue
}
$TVER = $GODOT_VERSION -replace "-", "."
$TNVER = $GODOT_NEXT_VERSION -replace "-", "."
FetchTemplates $GODOT_VERSION "Godot_v${GODOT_VERSION}_export_templates.tpz" $TVER
FetchTemplates $GODOT_VERSION "Godot_v${GODOT_VERSION}_mono_export_templates.tpz" "$TVER.mono"
FetchTemplates $GODOT_NEXT_VERSION "Godot_v${GODOT_NEXT_VERSION}_export_templates.tpz" $TNVER

Log "odin $ODIN_VERSION"
if (-not (Test-Path "$ROOT\odin\odin.exe")) {
    $url = "https://github.com/odin-lang/Odin/releases/download/$ODIN_VERSION/odin-windows-amd64-$ODIN_VERSION.zip"
    Invoke-WebRequest -Uri $url -OutFile "$env:TEMP\odin.zip"
    Expand-Archive -Path "$env:TEMP\odin.zip" -DestinationPath "$env:TEMP\odin-x" -Force
    $odinExe = Get-ChildItem -Path "$env:TEMP\odin-x" -Recurse -Filter odin.exe | Select-Object -First 1
    Remove-Item -Recurse -Force "$ROOT\odin" -ErrorAction SilentlyContinue
    Move-Item $odinExe.Directory.FullName "$ROOT\odin"
    Remove-Item -Recurse -Force "$env:TEMP\odin.zip", "$env:TEMP\odin-x" -ErrorAction SilentlyContinue
}

Log "odin bindings (pinned)"
if (-not (Test-Path "$ROOT\odin\shared\GDWrapper")) {
    New-Item -ItemType Directory -Force -Path "$ROOT\odin\shared" | Out-Null
    $tmp = "$env:TEMP\odin-bindings"
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    git clone -q https://github.com/Ferinzz/Toxin.git "$tmp\Toxin"
    git -C "$tmp\Toxin" checkout -q $TOXIN_COMMIT
    git clone -q https://github.com/Ferinzz/Godot_Odin_Binds.git "$tmp\Godot_Odin_Binds"
    git -C "$tmp\Godot_Odin_Binds" checkout -q $GD_CLASSES_COMMIT
    Copy-Item -Recurse "$tmp\Toxin\Toxin" "$ROOT\odin\shared\Toxin"
    Copy-Item -Recurse "$tmp\Toxin\GDWrapper" "$ROOT\odin\shared\GDWrapper"
    Copy-Item -Recurse "$tmp\Godot_Odin_Binds" "$ROOT\odin\shared\Godot_Odin_Binds"
    Remove-Item -Recurse -Force $tmp
}

Log "godot-cpp (pinned $($GODOT_CPP_COMMIT.Substring(0,10)))"
if (-not (Test-Path "$ROOT\cache\godot-cpp\.git")) {
    git init -q "$ROOT\cache\godot-cpp"
    git -C "$ROOT\cache\godot-cpp" remote add origin https://github.com/godotengine/godot-cpp
    git -C "$ROOT\cache\godot-cpp" fetch -q --depth=1 origin $GODOT_CPP_COMMIT
    git -C "$ROOT\cache\godot-cpp" checkout -q FETCH_HEAD
}

Log "setup complete ($ROOT)"
