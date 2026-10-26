<#
.SYNOPSIS
    为 Android arm64 交叉编译 LuaJIT（含 lovely 注入层），产出可直接给 love-android 使用的
    libluajit.a。

.DESCRIPTION
    流程：
      1. 用 MSVC 编出 host 工具 minilua.exe / buildvm.exe（本机没有 gcc/clang）
      2. 用 minilua + dynasm 生成 host/buildvm_arch.h，生成 luajit.h
      3. 用 NDK 的 GNU make 交叉编译出 libluajit.a
      4. 用 cargo 把 module/lovely 编成 liblovely.a（aarch64-linux-android）
      5. 把两者合并成一个 libluajit.a（lovely 的符号必须在同一个库里，
         因为 ljamalg.o 和 Rust 侧互相引用，分开放会需要 --start-group）

    产物：android/<abi>/libluajit.a + luajit.h

.NOTES
    前置条件：
      * Visual Studio 2022（提供 host 编译器）
      * Android NDK 25.2.9519653（提供交叉编译器 + make）
      * Rust nightly + aarch64-linux-android target
        rustup toolchain install nightly
        rustup target add aarch64-linux-android --toolchain nightly
#>
[CmdletBinding()]
param(
    [string]$Ndk      = "D:\86133\Android\Sdk\ndk\25.2.9519653",
    [string]$Api      = "21",
    [string]$Abi      = "arm64-v8a",
    [string]$Triple   = "aarch64-linux-android",
    [string]$DynArch  = "arm64",
    [string]$MsvcRoot = "",
    [string]$SdkRoot  = "D:\Windows Kits\10",
    [string]$SdkVer   = "",
    [switch]$Clean,
    [switch]$SkipHostTools
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$SrcDir   = Join-Path $RepoRoot "src"
$LovelyDir = Join-Path $RepoRoot "module\lovely"
$OutDir   = Join-Path $RepoRoot "android\$Abi"
$Tc       = Join-Path $Ndk "toolchains\llvm\prebuilt\windows-x86_64\bin"
$Make     = Join-Path $Ndk "prebuilt\windows-x86_64\bin\make.exe"
$Clang    = Join-Path $Tc "$Triple$Api-clang.cmd"
$Ar       = Join-Path $Tc "llvm-ar.exe"

function Step($msg) { Write-Host ""; Write-Host "==> $msg" -ForegroundColor Cyan }
function Fail($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------- 环境检查
Step "检查工具链"
if (-not (Test-Path $Clang)) { Fail "找不到 NDK clang: $Clang" }
if (-not (Test-Path $Make))  { Fail "找不到 NDK make: $Make" }
if (-not (Test-Path $LovelyDir)) { Fail "找不到 lovely 源码目录: $LovelyDir" }
Write-Host "  NDK   : $Ndk"
Write-Host "  Clang : $Clang"

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

if (-not $SdkVer) {
    $SdkVer = (Get-ChildItem (Join-Path $SdkRoot "Include") -Directory |
               Where-Object { $_.Name -like "10.*" } |
               Sort-Object Name -Descending | Select-Object -First 1).Name
}
if (-not $SdkVer) { Fail "找不到 Windows SDK（-SdkRoot $SdkRoot）" }
Write-Host "  MSVC  : $MsvcVer"
Write-Host "  SDK   : $SdkRoot $SdkVer"

$Cl = Join-Path $MsvcVer "bin\Hostx64\x64\cl.exe"
$env:INCLUDE = "$MsvcVer\include;$SdkRoot\Include\$SdkVer\ucrt;$SdkRoot\Include\$SdkVer\shared;$SdkRoot\Include\$SdkVer\um"
$env:LIB     = "$MsvcVer\lib\x64;$SdkRoot\Lib\$SdkVer\ucrt\x64;$SdkRoot\Lib\$SdkVer\um\x64"

# ---------------------------------------------------------------- 清理
if ($Clean) {
    Step "清理旧产物"
    Get-ChildItem $SrcDir -Include *.o,*.obj,*.a,luajit.h,lj_vm.S -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    foreach ($h in @("lj_bcdef.h","lj_ffdef.h","lj_folddef.h","lj_libdef.h","lj_recdef.h","vmdef.lua")) {
        Remove-Item (Join-Path $SrcDir $h) -Force -ErrorAction SilentlyContinue
    }
    Remove-Item (Join-Path $SrcDir "host\buildvm_arch.h") -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $SrcDir "host\minilua.exe"),(Join-Path $SrcDir "host\buildvm.exe") -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- host 工具（第一步：minilua）
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
# 注意顺序：buildvm.c 会 #include "luajit.h"，而 luajit.h 要用 minilua 生成，
# 所以必须先跑这一步，再编 buildvm。
Step "生成 luajit.h / buildvm_arch.h"
Push-Location $SrcDir
try {
    & git show -s --format=%ct | Out-File -Encoding ascii -NoNewline luajit_relver.txt
    & ".\host\minilua.exe" "host\genversion.lua"
    if ($LASTEXITCODE -ne 0) { Fail "生成 luajit.h 失败" }

    $dasmFlags = @("-D","ENDIAN_LE","-D","P64","-D","JIT","-D","FFI","-D","DUALNUM","-D","FPU","-D","HFABI")
    & ".\host\minilua.exe" "..\dynasm\dynasm.lua" @dasmFlags -o "host\buildvm_arch.h" "vm_$DynArch.dasc"
    if ($LASTEXITCODE -ne 0) { Fail "dynasm 生成 buildvm_arch.h 失败" }
} finally { Pop-Location }

# ---------------------------------------------------------------- host 工具（第二步：buildvm）
if (-not $SkipHostTools) {
    Step "编译 host 工具 buildvm（MSVC）"
    Push-Location $SrcDir
    try {
        # 必须带目标架构宏，否则 vm_<arch>.dasc 里的 #error 会触发（host 是 x64，LJ_DUALNUM=0）
        & $Cl /nologo /O2 /MD /D_CRT_SECURE_NO_WARNINGS /I. /Ihost `
              /DLUAJIT_TARGET=LUAJIT_ARCH_$DynArch /DLJ_ARCH_HASFPU=1 /DLJ_ABI_SOFTFP=0 `
              /Fe:host/buildvm.exe /Fo:host/ `
              host/buildvm.c host/buildvm_asm.c host/buildvm_peobj.c host/buildvm_lib.c host/buildvm_fold.c
        if ($LASTEXITCODE -ne 0) { Fail "buildvm 编译失败" }

        # make 期望 .o，cl 产出 .obj，做一份副本并让 exe 更新
        foreach ($n in @("buildvm","buildvm_asm","buildvm_peobj","buildvm_lib","buildvm_fold")) {
            Copy-Item "host\$n.obj" "host\$n.o" -Force
        }
        (Get-Item "host\minilua.exe").LastWriteTime = Get-Date
        (Get-Item "host\buildvm.exe").LastWriteTime = Get-Date
    } finally { Pop-Location }
}

# ---------------------------------------------------------------- LuaJIT
Step "交叉编译 LuaJIT（amalg / static）"
Push-Location $SrcDir
try {
    & $Make all "LJCORE_O=ljamalg.o" BUILDMODE=static HOST_SYS=Windows TARGET_SYS=Linux `
        "CROSS=$Triple-" `
        "STATIC_CC=`"$Clang`" -fPIC" `
        "TARGET_AR=`"$Ar`" rcus" `
        "TARGET_STRIP=" `
        "HOST_CC=cmd /c exit 0" `
        "HOST_LUA=./host/minilua.exe"
    # 末尾构建 luajit 可执行文件那一步会失败（需要交叉 gcc），libluajit.a 此时已产出
    if (-not (Test-Path "libluajit.a")) { Fail "libluajit.a 未生成" }
} finally { Pop-Location }

# ---------------------------------------------------------------- lovely
Step "交叉编译 liblovely（cargo）"
$env:CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER = $Clang
$env:CC_aarch64_linux_android                 = $Clang
$env:CXX_aarch64_linux_android                = Join-Path $Tc "$Triple$Api-clang++.cmd"
$env:AR_aarch64_linux_android                 = $Ar
$env:RANLIB_aarch64_linux_android             = Join-Path $Tc "llvm-ranlib.exe"
Push-Location $LovelyDir
try {
    & cargo build -p liblovely --release --target $Triple
    if ($LASTEXITCODE -ne 0) { Fail "liblovely 编译失败" }
} finally { Pop-Location }
$LovelyLib = Join-Path $LovelyDir "target\$Triple\release\liblovely.a"
if (-not (Test-Path $LovelyLib)) { Fail "找不到 liblovely.a: $LovelyLib" }

# ---------------------------------------------------------------- 合并
Step "合并 liblovely 进 libluajit.a"
Push-Location $SrcDir
try {
    # 不用 llvm-ar 的 MRI 脚本（PowerShell 往原生程序 stdin 送数据会带 BOM，
    # llvm-ar 会把 BOM 当成命令的一部分报 "unknown command"）。
    # 改成：把两个归档解包到临时目录，再一次性重打包。成员名已确认无冲突。
    $tmp = Join-Path $env:TEMP "luajit_merge_tmp"
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
# jit 运行时模块（require("jit.v") 之类要用）
$JitOut = Join-Path $OutDir "jit"
New-Item -ItemType Directory -Force -Path $JitOut | Out-Null
Copy-Item (Join-Path $SrcDir "jit\*.lua") $JitOut -Force -ErrorAction SilentlyContinue

$final = Join-Path $OutDir "libluajit.a"
Write-Host ""
Write-Host "完成：$final  ($([math]::Round((Get-Item $final).Length/1MB,1)) MB)" -ForegroundColor Green
Write-Host "验证符号："
& (Join-Path $Tc "llvm-nm.exe") $final | Select-String -Pattern " T (luaL_loadbufferx|lovely_loadbufferx|lovely_init|lovely_apply_patches)$"
