<#
.SYNOPSIS
    为 Android 交叉编译 LuaJIT（含 lovely 注入层），产出可直接给 love-android 使用的
    libluajit.a。支持 4 个 ABI。

.DESCRIPTION
    流程：
      1. 用 MSVC 编出 host 工具 minilua（一次即可）和 buildvm（每个 ABI 一份）
      2. 用 minilua + dynasm 生成 host/buildvm_arch.h，生成 luajit.h
      3. 用 NDK 的 GNU make 交叉编译出 libluajit.a
      4. 用 cargo 把 module/lovely 编成 liblovely.a
      5. 把两者合并成一个 libluajit.a（lovely 的符号必须在同一个库里，
         因为 ljamalg.o 和 Rust 侧互相引用，分开放会需要 --start-group）

    产物：android/<abi>/libluajit.a + luajit.h

.PARAMETER Abi
    arm64-v8a（默认）| armeabi-v7a | x86 | x86_64

.NOTES
    前置条件：
      * Visual Studio 2022（提供 host 编译器）
      * Android NDK 25.2.9519653（环境变量 ANDROID_NDK_HOME / ANDROID_NDK_ROOT 指向它）
      * Rust nightly + 对应 ABI 的 target
#>
[CmdletBinding()]
param(
    [ValidateSet("arm64-v8a", "armeabi-v7a", "x86", "x86_64")]
    [string]$Abi    = "arm64-v8a",
    [string]$Api    = "21",
    [string]$Ndk    = "",
    [string]$MsvcRoot = "",
    [string]$WinSdkRoot = "",
    [string]$WinSdkVer  = "",
    [switch]$Clean,
    [switch]$SkipHostTools
)

$ErrorActionPreference = "Stop"

function Step($msg) { Write-Host ""; Write-Host "==> $msg" -ForegroundColor Cyan }
function Fail($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }

# ABI -> (NDK clang triple, Rust target, LuaJIT arch)
$AbiMap = @{
    "arm64-v8a"   = @{ Clang = "aarch64-linux-android";       Rust = "aarch64-linux-android";  LjArch = "ARM64" }
    "armeabi-v7a" = @{ Clang = "armv7a-linux-androideabi";    Rust = "armv7-linux-androideabi"; LjArch = "ARM" }
    "x86"         = @{ Clang = "i686-linux-android";          Rust = "i686-linux-android";     LjArch = "X86" }
    "x86_64"      = @{ Clang = "x86_64-linux-android";        Rust = "x86_64-linux-android";   LjArch = "X64" }
}
$Target = $AbiMap[$Abi]

$RepoRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
$SrcDir    = Join-Path $RepoRoot "src"
$LovelyDir = Join-Path $RepoRoot "module\lovely"
$OutDir    = Join-Path $RepoRoot "android\$Abi"
$AbiMarker = Join-Path $SrcDir ".last_abi"

# ---------------------------------------------------------------- NDK
Step "检查工具链"
if (-not $Ndk) {
    foreach ($envName in @("ANDROID_NDK_HOME", "ANDROID_NDK_ROOT", "ANDROID_NDK")) {
        $v = [Environment]::GetEnvironmentVariable($envName)
        if ($v -and (Test-Path $v)) { $Ndk = $v; break }
    }
}
if (-not $Ndk) {
    $guess = "D:\86133\Android\Sdk\ndk\25.2.9519653"
    if (Test-Path $guess) { $Ndk = $guess }
}
if (-not $Ndk -or -not (Test-Path $Ndk)) {
    Fail "找不到 NDK，请设置 ANDROID_NDK_HOME 或用 -Ndk 指定"
}

$Tc    = Join-Path $Ndk "toolchains\llvm\prebuilt\windows-x86_64\bin"
$Make  = Join-Path $Ndk "prebuilt\windows-x86_64\bin\make.exe"
$Clang = Join-Path $Tc "$($Target.Clang)$Api-clang.cmd"
$ClangXx = Join-Path $Tc "$($Target.Clang)$Api-clang++.cmd"
$Ar    = Join-Path $Tc "llvm-ar.exe"

if (-not (Test-Path $Clang)) { Fail "找不到 NDK clang: $Clang" }
if (-not (Test-Path $Make))  { Fail "找不到 NDK make: $Make" }
if (-not (Test-Path $LovelyDir)) { Fail "找不到 lovely 源码目录: $LovelyDir" }
Write-Host "  ABI   : $Abi"
Write-Host "  NDK   : $Ndk"
Write-Host "  Clang : $Clang"

# ---------------------------------------------------------------- MSVC
if (-not $MsvcRoot) {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $inst = & $vswhere -latest -products * -property installationPath
        if ($inst) { $MsvcRoot = Join-Path $inst "VC\Tools\MSVC" }
    }
}
if (-not $MsvcRoot -or -not (Test-Path $MsvcRoot)) { Fail "找不到 MSVC，请用 -MsvcRoot 指定" }
$MsvcVer = (Get-ChildItem $MsvcRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
if (-not $MsvcVer) { Fail "MSVC 目录下没有版本子目录: $MsvcRoot" }

# ---------------------------------------------------------------- Windows SDK
# 注意：有些机器上 $env:WindowsSdkDir 只有盘符（如 "D:"），直接 Join-Path 会得到
# 盘符相对路径（"D:Include"）并悄悄相对当前目录解析。所以必须先校验是绝对路径。
if (-not $WinSdkRoot) {
    $cands = New-Object System.Collections.Generic.List[string]
    if ($env:WindowsSdkDir) { $cands.Add($env:WindowsSdkDir) }
    foreach ($p in @("C:\Program Files (x86)\Windows Kits\10",
                     "C:\Program Files\Windows Kits\10",
                     "D:\Windows Kits\10")) { $cands.Add($p) }

    foreach ($c in $cands) {
        if ($c -notmatch '^[A-Za-z]:\\') { continue }          # 必须是 D:\ 这种绝对路径
        $inc = Join-Path $c "Include"
        if ((Test-Path $inc) -and (Get-ChildItem $inc -Directory -ErrorAction SilentlyContinue |
                                   Where-Object { $_.Name -like "10.*" })) {
            $WinSdkRoot = $c; break
        }
    }
}
if (-not $WinSdkRoot) { Fail "找不到 Windows SDK，请用 -WinSdkRoot 指定（形如 C:\Program Files (x86)\Windows Kits\10）" }
if (-not $WinSdkVer) {
    $WinSdkVer = (Get-ChildItem (Join-Path $WinSdkRoot "Include") -Directory |
                  Where-Object { $_.Name -like "10.*" } |
                  Sort-Object Name -Descending | Select-Object -First 1).Name
}
if (-not $WinSdkVer) { Fail "找不到 Windows SDK 版本（$WinSdkRoot）" }
Write-Host "  MSVC  : $MsvcVer"
Write-Host "  WinSDK: $WinSdkRoot $WinSdkVer"

$Cl = Join-Path $MsvcVer "bin\Hostx64\x64\cl.exe"
$env:INCLUDE = "$MsvcVer\include;$WinSdkRoot\Include\$WinSdkVer\ucrt;$WinSdkRoot\Include\$WinSdkVer\shared;$WinSdkRoot\Include\$WinSdkVer\um"
$env:LIB     = "$MsvcVer\lib\x64;$WinSdkRoot\Lib\$WinSdkVer\ucrt\x64;$WinSdkRoot\Lib\$WinSdkVer\um\x64"

# ---------------------------------------------------------------- 目标架构探测
# 直接从目标编译器预处理 lj_arch.h 拿宏，和 Makefile 的做法一致，
# 这样 dynasm 标志和 buildvm 的 -D 永远和目标 ABI 对得上，不用手写。
Step "探测目标架构宏"
Push-Location $SrcDir
try {
    $defs = (& $Clang -E lj_arch.h -dM 2>$null) -join "`n"
    if (-not $defs) { Fail "预处理 lj_arch.h 失败" }

    $dasm = New-Object System.Collections.Generic.List[string]
    $tdef = New-Object System.Collections.Generic.List[string]
    $tdef.Add("/DLUAJIT_TARGET=LUAJIT_ARCH_$($Target.LjArch)")
    # 关键：host 是 Windows，但目标是 Linux/Android。不声明这个的话 lj_arch.h 会认为
    # LJ_TARGET_WINDOWS=1，buildvm_peobj.c 里只有 64 位架构才有 PEOBJ_* 定义，
    # 32 位架构会编译失败。Makefile 对 host 编译也带这个 define。
    $tdef.Add("/DLUAJIT_OS=LUAJIT_OS_LINUX")

    if ($defs -match "LJ_LE 1") { $dasm.AddRange([string[]]@("-D","ENDIAN_LE")) } else { $dasm.AddRange([string[]]@("-D","ENDIAN_BE")) }
    if ($defs -match "LJ_ARCH_BITS 64") { $dasm.AddRange([string[]]@("-D","P64")) }
    if ($defs -match "LJ_HASJIT 1")     { $dasm.AddRange([string[]]@("-D","JIT")) }
    if ($defs -match "LJ_HASFFI 1")     { $dasm.AddRange([string[]]@("-D","FFI")) }
    if ($defs -match "LJ_DUALNUM 1")    { $dasm.AddRange([string[]]@("-D","DUALNUM")) }

    if ($defs -match "LJ_ARCH_HASFPU 1") { $dasm.AddRange([string[]]@("-D","FPU")); $tdef.Add("/DLJ_ARCH_HASFPU=1") }
    else                                 { $tdef.Add("/DLJ_ARCH_HASFPU=0") }

    if ($defs -notmatch "LJ_ABI_SOFTFP 1") { $dasm.AddRange([string[]]@("-D","HFABI")); $tdef.Add("/DLJ_ABI_SOFTFP=0") }
    else                                   { $tdef.Add("/DLJ_ABI_SOFTFP=1") }

    if ($defs -match "LJ_NO_UNWIND 1")     { $dasm.AddRange([string[]]@("-D","NO_UNWIND")); $tdef.Add("/DLUAJIT_NO_UNWIND") }
    if ($defs -match "LJ_ABI_PAUTH 1")     { $dasm.AddRange([string[]]@("-D","PAUTH")); $tdef.Add("/DLJ_ABI_PAUTH=1") }
    if ($defs -match "LJ_ABI_BRANCH_TRACK 1") { $dasm.AddRange([string[]]@("-D","BRANCH_TRACK")); $tdef.Add("/DLJ_ABI_BRANCH_TRACK=1") }
    if ($defs -match "LJ_ABI_SHADOW_STACK 1") { $dasm.AddRange([string[]]@("-D","SHADOW_STACK")); $tdef.Add("/DLJ_ABI_SHADOW_STACK=1") }

    $DynArch = ($Target.LjArch).ToLower()
    $DasmDasc = "vm_$DynArch.dasc"
    if (-not (Test-Path $DasmDasc)) { Fail "找不到 $DasmDasc（LuaJIT 不支持这个架构？）" }
    Write-Host "  LuaJIT arch : $DynArch"
    Write-Host "  dynasm      : $($dasm -join ' ')"
    Write-Host "  buildvm -D  : $($tdef -join ' ')"
} finally { Pop-Location }

# ---------------------------------------------------------------- 清理
# 换 ABI 必须清掉上次的目标文件，否则 make 会复用旧 ABI 的 .o
$needClean = $Clean
if (-not $needClean -and (Test-Path $AbiMarker)) {
    if ((Get-Content $AbiMarker -Raw).Trim() -ne $Abi) { $needClean = $true }
}
if ($needClean) {
    Step "清理旧产物（ABI 变了或指定了 -Clean）"
    Get-ChildItem $SrcDir -Include *.o,*.a -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $SrcDir "lj_vm.S") -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $SrcDir "host\buildvm_arch.h") -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $SrcDir "host\buildvm.exe") -Force -ErrorAction SilentlyContinue
    foreach ($n in @("buildvm","buildvm_asm","buildvm_peobj","buildvm_lib","buildvm_fold")) {
        Remove-Item (Join-Path $SrcDir "host\$n.obj"),(Join-Path $SrcDir "host\$n.o") -Force -ErrorAction SilentlyContinue
    }
}
Set-Content -Path $AbiMarker -Value $Abi -NoNewline

# ---------------------------------------------------------------- minilua（与 ABI 无关）
if (-not $SkipHostTools) {
    Step "编译 host 工具 minilua（MSVC）"
    Push-Location $SrcDir
    try {
        New-Item -ItemType Directory -Force -Path "host" | Out-Null
        & $Cl /nologo /O2 /MD /D_CRT_SECURE_NO_WARNINGS /I. /Fe:host/minilua.exe /Fo:host/minilua.o host/minilua.c
        if ($LASTEXITCODE -ne 0) { Fail "minilua 编译失败" }
    } finally { Pop-Location }
}

# ---------------------------------------------------------------- 生成头文件
# 顺序：buildvm.c 会 #include "luajit.h"，而 luajit.h 要用 minilua 生成，所以先生成再编 buildvm。
Step "生成 luajit.h / buildvm_arch.h"
Push-Location $SrcDir
try {
    & git show -s --format=%ct | Out-File -Encoding ascii -NoNewline luajit_relver.txt
    & ".\host\minilua.exe" "host\genversion.lua"
    if ($LASTEXITCODE -ne 0) { Fail "生成 luajit.h 失败" }

    & ".\host\minilua.exe" "..\dynasm\dynasm.lua" @dasm -o "host\buildvm_arch.h" $DasmDasc
    if ($LASTEXITCODE -ne 0) { Fail "dynasm 生成 buildvm_arch.h 失败" }
} finally { Pop-Location }

# ---------------------------------------------------------------- buildvm（每个 ABI 一份）
if (-not $SkipHostTools) {
    Step "编译 host 工具 buildvm（MSVC）"
    Push-Location $SrcDir
    try {
        & $Cl /nologo /O2 /MD /D_CRT_SECURE_NO_WARNINGS /I. /Ihost @tdef `
              /Fe:host/buildvm.exe /Fo:host/ `
              host/buildvm.c host/buildvm_asm.c host/buildvm_peobj.c host/buildvm_lib.c host/buildvm_fold.c
        if ($LASTEXITCODE -ne 0) { Fail "buildvm 编译失败" }

        foreach ($n in @("buildvm","buildvm_asm","buildvm_peobj","buildvm_lib","buildvm_fold")) {
            Copy-Item "host\$n.obj" "host\$n.o" -Force
        }
        (Get-Item "host\minilua.exe").LastWriteTime = Get-Date
        (Get-Item "host\buildvm.exe").LastWriteTime = Get-Date
    } finally { Pop-Location }
}

# ---------------------------------------------------------------- LuaJIT
Step "交叉编译 LuaJIT（amalg / static，$Abi）"
Push-Location $SrcDir
try {
    & $Make all "LJCORE_O=ljamalg.o" BUILDMODE=static HOST_SYS=Windows TARGET_SYS=Linux `
        "CROSS=$($Target.Clang)-" `
        "STATIC_CC=`"$Clang`" -fPIC" `
        "TARGET_AR=`"$Ar`" rcus" `
        "TARGET_STRIP=" `
        "HOST_CC=cmd /c exit 0" `
        "HOST_LUA=./host/minilua.exe"
    # 末尾构建 luajit 可执行文件那一步会失败（需要交叉 gcc），libluajit.a 此时已产出
    if (-not (Test-Path "libluajit.a")) { Fail "libluajit.a 未生成" }
} finally { Pop-Location }

# ---------------------------------------------------------------- lovely
Step "交叉编译 liblovely（cargo，$($Target.Rust)）"
$envName = $Target.Rust -replace "-", "_"
Set-Item -Path "env:CARGO_TARGET_$($Target.Rust.ToUpper() -replace '-','_')_LINKER" -Value $Clang
Set-Item -Path "env:CC_$envName" -Value $Clang
if (Test-Path $ClangXx) { Set-Item -Path "env:CXX_$envName" -Value $ClangXx }
Set-Item -Path "env:AR_$envName" -Value $Ar
Set-Item -Path "env:RANLIB_$envName" -Value (Join-Path $Tc "llvm-ranlib.exe")

Push-Location $LovelyDir
try {
    & cargo build -p liblovely --release --target $($Target.Rust)
    if ($LASTEXITCODE -ne 0) { Fail "liblovely 编译失败（检查 rustup target add $($Target.Rust) --toolchain nightly）" }
} finally { Pop-Location }
$LovelyLib = Join-Path $LovelyDir "target\$($Target.Rust)\release\liblovely.a"
if (-not (Test-Path $LovelyLib)) { Fail "找不到 liblovely.a: $LovelyLib" }

# ---------------------------------------------------------------- 合并
Step "合并 liblovely 进 libluajit.a"
Push-Location $SrcDir
try {
    # 不用 llvm-ar 的 MRI 脚本（往原生程序 stdin 送数据会带 BOM，llvm-ar 会报 unknown command）。
    # 改成：把两个归档解包到临时目录，再分块重打包。成员名已确认无冲突。
    $tmp = Join-Path $env:TEMP "luajit_merge_$Abi"
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null

    Push-Location $tmp
    try {
        & $Ar x (Join-Path $SrcDir "libluajit.a")
        if ($LASTEXITCODE -ne 0) { Fail "解包 libluajit.a 失败" }
        & $Ar x $LovelyLib
        if ($LASTEXITCODE -ne 0) { Fail "解包 liblovely.a 失败" }

        $objs = Get-ChildItem -Path $tmp -Filter *.o | Select-Object -ExpandProperty Name
        if ($objs.Count -lt 2) { Fail "解包后没有目标文件" }

        $merged = Join-Path $SrcDir "libluajit-merged.a"
        Remove-Item $merged -Force -ErrorAction SilentlyContinue
        $chunk = 100
        for ($i = 0; $i -lt $objs.Count; $i += $chunk) {
            $end   = [Math]::Min($i + $chunk - 1, $objs.Count - 1)
            $batch = $objs[$i..$end]
            if ($i -eq 0) { & $Ar rcs $merged @batch } else { & $Ar rs $merged @batch }
            if ($LASTEXITCODE -ne 0) { Fail "打包失败（第 $i 批）" }
        }
    } finally { Pop-Location }
} finally { Pop-Location }

# ---------------------------------------------------------------- 输出
Step "输出到 android/$Abi"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Copy-Item (Join-Path $SrcDir "libluajit-merged.a") (Join-Path $OutDir "libluajit.a") -Force
Copy-Item (Join-Path $SrcDir "luajit.h")            (Join-Path $OutDir "luajit.h")   -Force
$JitOut = Join-Path $OutDir "jit"
New-Item -ItemType Directory -Force -Path $JitOut | Out-Null
Copy-Item (Join-Path $SrcDir "jit\*.lua") $JitOut -Force -ErrorAction SilentlyContinue

$final = Join-Path $OutDir "libluajit.a"
Write-Host ""
Write-Host "完成：$final  ($([math]::Round((Get-Item $final).Length/1MB,1)) MB)" -ForegroundColor Green
Write-Host "验证符号（NDK 自带的 llvm-nm 是 LLVM 14，读不了新版 Rust 的 .o，报错可忽略）："
$prevEap = $ErrorActionPreference
$ErrorActionPreference = "Continue"
& (Join-Path $Tc "llvm-nm.exe") $final 2>$null |
    Select-String -Pattern " T (luaL_loadbufferx|lovely_loadbufferx|lovely_init|lovely_apply_patches)$"
$ErrorActionPreference = $prevEap
