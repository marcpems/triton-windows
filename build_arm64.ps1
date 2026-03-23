#Requires -Version 5.1
<#
.SYNOPSIS
    Builds Triton for ARM64 Windows natively from a fresh clone.

.DESCRIPTION
    This script performs a complete offline build of Triton on Windows ARM64.
    It applies necessary source patches for ARM64 support, clones and builds
    LLVM (with MLIR and LLD), downloads nlohmann/json, installs Python build
    dependencies, and builds Triton via pip.

    Must be run from an "ARM64 Native Tools Command Prompt for VS 2022"
    (or equivalent shell where the ARM64 cl.exe is on PATH).

.PARAMETER LLVMBuildJobs
    Number of parallel jobs for the LLVM build. Default: 8.

.PARAMETER Branch
    Branch to checkout before building. Default: release/3.6.x-windows.

.PARAMETER SkipLLVM
    Skip the LLVM clone/build step (use if LLVM is already built).

.PARAMETER SkipJson
    Skip the JSON download step (use if JSON is already downloaded).

.PARAMETER SkipPatches
    Skip applying source patches (use if patches were already applied).

.EXAMPLE
    .\build_arm64.ps1
    .\build_arm64.ps1 -LLVMBuildJobs 16
    .\build_arm64.ps1 -SkipLLVM -SkipJson -SkipPatches
#>
param(
    [int]$LLVMBuildJobs = 8,
    [string]$Branch = "release/3.6.x-windows",
    [switch]$SkipLLVM,
    [switch]$SkipJson,
    [switch]$SkipPatches,
    [switch]$SkipCudaTests
)

$ErrorActionPreference = "Stop"
$TritonRoot = $PSScriptRoot
$LLVMDir = Join-Path $TritonRoot "llvm-project"
$LLVMBuild = Join-Path $LLVMDir "build"
$JsonDir = Join-Path $TritonRoot "json"
$LLVMHash = (Get-Content (Join-Path $TritonRoot "cmake\llvm-hash.txt") -Raw).Trim()
$JsonVersion = (Get-Content (Join-Path $TritonRoot "cmake\json-version.txt") -Raw).Trim()

Write-Host "=== Triton ARM64 Windows Build Script ===" -ForegroundColor Cyan
Write-Host "Triton root:  $TritonRoot"
Write-Host "LLVM commit:  $LLVMHash"
Write-Host "JSON version: $JsonVersion"
Write-Host ""

# ---------------------------------------------------------------------------
# Helper: apply a single string replacement in a file
# ---------------------------------------------------------------------------
function Patch-File {
    param(
        [string]$Path,
        [string]$Find,
        [string]$Replace,
        [string]$Description
    )
    $content = Get-Content -Raw $Path
    if (-not $content.Contains($Find)) {
        # Already patched or pattern changed
        Write-Host "  [skip] $Description (pattern not found, may already be applied)" -ForegroundColor DarkYellow
        return
    }
    $content = $content.Replace($Find, $Replace)
    # Write without BOM, preserving LF line endings
    [System.IO.File]::WriteAllText($Path, $content)
    Write-Host "  [done] $Description" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Step 0: Verify ARM64 environment
# ---------------------------------------------------------------------------
Write-Host "--- Verifying ARM64 environment ---" -ForegroundColor Yellow

if ($Env:PROCESSOR_ARCHITECTURE -ne "ARM64") {
    Write-Error @"
This script must be run natively on an ARM64 machine.
Detected PROCESSOR_ARCHITECTURE = '$Env:PROCESSOR_ARCHITECTURE'.
If you are on an ARM64 device, make sure you are using a native ARM64 shell
(not x64 emulation). Use the "ARM64 Native Tools Command Prompt for VS 2022".
"@
    exit 1
}

# Verify cl.exe is the ARM64 variant
$clPath = (Get-Command cl.exe -ErrorAction SilentlyContinue).Source
if (-not $clPath) {
    Write-Error @"
cl.exe not found on PATH.
Run this script from an "ARM64 Native Tools Command Prompt for VS 2022".
"@
    exit 1
}

if ($clPath -notmatch "arm64" -and $clPath -notmatch "Hostarm64") {
    Write-Warning @"
cl.exe found at: $clPath
This does not appear to be an ARM64 native compiler.
Expected path to contain 'Hostarm64\arm64'.
The build may produce x64 binaries instead of ARM64.
Continuing anyway in case the path layout is non-standard...
"@
}

Write-Host "ARM64 environment verified." -ForegroundColor Green
Write-Host ""

# ---------------------------------------------------------------------------
# Step 1: Check prerequisites
# ---------------------------------------------------------------------------
Write-Host "--- Step 1: Checking prerequisites ---" -ForegroundColor Yellow

$missing = @()
if (-not (Get-Command python -ErrorAction SilentlyContinue)) { $missing += "python" }
if (-not (Get-Command cmake -ErrorAction SilentlyContinue))  { $missing += "cmake" }
if (-not (Get-Command ninja -ErrorAction SilentlyContinue))  { $missing += "ninja" }
if (-not (Get-Command git -ErrorAction SilentlyContinue))    { $missing += "git" }

if ($missing.Count -gt 0) {
    Write-Error "Missing required tools: $($missing -join ', '). Please install them and ensure they are on PATH."
    exit 1
}

Write-Host "All prerequisites found." -ForegroundColor Green
Write-Host ""

# ---------------------------------------------------------------------------
# Step 2: Ensure correct branch
# ---------------------------------------------------------------------------
$currentBranch = (git -C $TritonRoot rev-parse --abbrev-ref HEAD 2>$null)
if ($currentBranch -ne $Branch) {
    Write-Host "--- Step 2: Switching to branch $Branch ---" -ForegroundColor Yellow
    git -C $TritonRoot fetch origin $Branch
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to fetch branch $Branch"; exit 1 }
    git -C $TritonRoot checkout $Branch
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to checkout branch $Branch"; exit 1 }

    $LLVMHash = (Get-Content (Join-Path $TritonRoot "cmake\llvm-hash.txt") -Raw).Trim()
    $JsonVersion = (Get-Content (Join-Path $TritonRoot "cmake\json-version.txt") -Raw).Trim()
    Write-Host "LLVM commit (updated): $LLVMHash"
    Write-Host "JSON version (updated): $JsonVersion"
}
Write-Host ""

# ---------------------------------------------------------------------------
# Step 3: Apply ARM64 source patches
# ---------------------------------------------------------------------------
if (-not $SkipPatches) {
    Write-Host "--- Step 3: Applying ARM64 source patches ---" -ForegroundColor Yellow

    # --- Patch CMakeLists.txt: case-insensitive ARM64 processor match ---
    # Windows ARM64 reports CMAKE_SYSTEM_PROCESSOR as "ARM64" (uppercase)
    # but the existing regex only matches lowercase "arm64".
    $cmakePath = Join-Path $TritonRoot "CMakeLists.txt"
    Patch-File -Path $cmakePath `
        -Find  '     CMAKE_SYSTEM_PROCESSOR MATCHES "arm64" OR # macOS arm64' `
        -Replace '     CMAKE_SYSTEM_PROCESSOR MATCHES "[Aa][Rr][Mm]64" OR # macOS/Windows arm64' `
        -Description "CMakeLists.txt: case-insensitive ARM64 processor detection"

    # --- Patch setup.py: add uppercase ARM64 to arch dict ---
    # platform.machine() returns "ARM64" (uppercase) on Windows ARM64
    $setupPath = Join-Path $TritonRoot "setup.py"
    Patch-File -Path $setupPath `
        -Find  '{"x86_64": "x64", "AMD64": "x64", "arm64": "arm64", "aarch64": "arm64"}' `
        -Replace '{"x86_64": "x64", "AMD64": "x64", "arm64": "arm64", "ARM64": "arm64", "aarch64": "arm64"}' `
        -Description "setup.py: recognize uppercase ARM64 from platform.machine()"

    # --- Patch windows_utils.py: architecture-aware MSVC/SDK/CUDA paths ---
    # The file hardcodes "Hostx64", "x64" everywhere. Add arch detection
    # constants and replace the hardcoded values.
    $winUtilsPath = Join-Path $TritonRoot "python\triton\windows_utils.py"

    # 3a. Add arch-detection constants after imports
    Patch-File -Path $winUtilsPath `
        -Find  'from typing import Callable, Optional' `
        -Replace @'
from typing import Callable, Optional

# Architecture-specific directory names for MSVC and Windows SDK
_MSVC_HOST_DIR = "Hostarm64" if platform.machine().upper() == "ARM64" else "Hostx64"
_LIB_ARCH_DIR = "arm64" if platform.machine().upper() == "ARM64" else "x64"
'@ `
        -Description "windows_utils.py: add _MSVC_HOST_DIR / _LIB_ARCH_DIR constants"

    # 3b. check_msvc: cl.exe path
    Patch-File -Path $winUtilsPath `
        -Find  'msvc_base_path / version / "bin" / "Hostx64" / "x64" / "cl.exe",' `
        -Replace 'msvc_base_path / version / "bin" / _MSVC_HOST_DIR / _LIB_ARCH_DIR / "cl.exe",' `
        -Description "windows_utils.py: check_msvc cl.exe path"

    # 3c. check_msvc: vcruntime.lib path
    Patch-File -Path $winUtilsPath `
        -Find  'msvc_base_path / version / "lib" / "x64" / "vcruntime.lib",' `
        -Replace 'msvc_base_path / version / "lib" / _LIB_ARCH_DIR / "vcruntime.lib",' `
        -Description "windows_utils.py: check_msvc vcruntime.lib path"

    # 3d. find_msvc return: cl.exe path (same pattern as check_msvc, appears a second time)
    # After the first replacement above consumed the check_msvc occurrence,
    # this catches the find_msvc return value occurrence.
    Patch-File -Path $winUtilsPath `
        -Find  'str(msvc_base_path / version / "bin" / "Hostx64" / "x64" / "cl.exe")' `
        -Replace 'str(msvc_base_path / version / "bin" / _MSVC_HOST_DIR / _LIB_ARCH_DIR / "cl.exe")' `
        -Description "windows_utils.py: find_msvc return cl.exe path"

    # 3e. find_msvc return: lib dir
    Patch-File -Path $winUtilsPath `
        -Find  '[str(msvc_base_path / version / "lib" / "x64")]' `
        -Replace '[str(msvc_base_path / version / "lib" / _LIB_ARCH_DIR)]' `
        -Description "windows_utils.py: find_msvc return lib path"

    # 3f. check_winsdk: ucrt.lib path
    Patch-File -Path $winUtilsPath `
        -Find  'winsdk_base_path / "Lib" / version / "ucrt" / "x64" / "ucrt.lib"' `
        -Replace 'winsdk_base_path / "Lib" / version / "ucrt" / _LIB_ARCH_DIR / "ucrt.lib"' `
        -Description "windows_utils.py: check_winsdk ucrt.lib path"

    # 3g. find_winsdk return: ucrt lib dir
    Patch-File -Path $winUtilsPath `
        -Find  'str(winsdk_base_path / "Lib" / version / "ucrt" / "x64")' `
        -Replace 'str(winsdk_base_path / "Lib" / version / "ucrt" / _LIB_ARCH_DIR)' `
        -Description "windows_utils.py: find_winsdk ucrt lib path"

    # 3h. find_winsdk return: um lib dir
    Patch-File -Path $winUtilsPath `
        -Find  'str(winsdk_base_path / "Lib" / version / "um" / "x64")' `
        -Replace 'str(winsdk_base_path / "Lib" / version / "um" / _LIB_ARCH_DIR)' `
        -Description "windows_utils.py: find_winsdk um lib path"

    # 3i. check_and_find_cuda: pip layout - cuda.lib check
    Patch-File -Path $winUtilsPath `
        -Find  'base_path / "cuda_runtime" / "lib" / "x64" / "cuda.lib"' `
        -Replace 'base_path / "cuda_runtime" / "lib" / _LIB_ARCH_DIR / "cuda.lib"' `
        -Description "windows_utils.py: check_and_find_cuda pip cuda.lib path"

    # 3j. check_and_find_cuda: pip layout - return lib dir
    Patch-File -Path $winUtilsPath `
        -Find  '[str(base_path / "cuda_runtime" / "lib" / "x64")]' `
        -Replace '[str(base_path / "cuda_runtime" / "lib" / _LIB_ARCH_DIR)]' `
        -Description "windows_utils.py: check_and_find_cuda pip lib return"

    # 3k. check_and_find_cuda: bundled layout - cuda.lib check
    Patch-File -Path $winUtilsPath `
        -Find  'base_path / "lib" / "x64" / "cuda.lib"' `
        -Replace 'base_path / "lib" / _LIB_ARCH_DIR / "cuda.lib"' `
        -Description "windows_utils.py: check_and_find_cuda bundled cuda.lib path"

    # 3l. check_and_find_cuda: bundled layout - return lib dir
    Patch-File -Path $winUtilsPath `
        -Find  '[str(base_path / "lib" / "x64")]' `
        -Replace '[str(base_path / "lib" / _LIB_ARCH_DIR)]' `
        -Description "windows_utils.py: check_and_find_cuda bundled lib return"

    Write-Host ""
    Write-Host "ARM64 patches applied." -ForegroundColor Green
} else {
    Write-Host "--- Step 3: Skipping patches (-SkipPatches) ---" -ForegroundColor Yellow
}
Write-Host ""

# ---------------------------------------------------------------------------
# Step 4: Clone and build LLVM (with MLIR + LLD)
# ---------------------------------------------------------------------------
if (-not $SkipLLVM) {
    Write-Host "--- Step 4: Building LLVM ---" -ForegroundColor Yellow

    if (-not (Test-Path $LLVMDir)) {
        Write-Host "Cloning LLVM (shallow)..."
        git clone --filter=blob:none https://github.com/llvm/llvm-project.git $LLVMDir
        if ($LASTEXITCODE -ne 0) { Write-Error "Failed to clone LLVM"; exit 1 }
    }

    Push-Location $LLVMDir
    try {
        Write-Host "Checking out LLVM commit $LLVMHash..."
        git checkout $LLVMHash
        if ($LASTEXITCODE -ne 0) { Write-Error "Failed to checkout LLVM commit"; exit 1 }

        Write-Host "Configuring LLVM with CMake (ARM64 native)..."
        cmake -B build -G Ninja `
            -DCMAKE_BUILD_TYPE=Release `
            -DLLVM_ENABLE_PROJECTS="mlir;llvm;lld" `
            -DLLVM_TARGETS_TO_BUILD="host;NVPTX;AMDGPU" `
            -DLLVM_BUILD_TOOLS=ON `
            -DLLVM_CCACHE_BUILD=ON `
            -DLLVM_ENABLE_DIA_SDK=OFF `
            llvm
        if ($LASTEXITCODE -ne 0) { Write-Error "LLVM CMake configuration failed"; exit 1 }

        Write-Host "Building LLVM with $LLVMBuildJobs parallel jobs..."
        cmake --build build -j $LLVMBuildJobs --config Release
        if ($LASTEXITCODE -ne 0) { Write-Error "LLVM build failed"; exit 1 }
    }
    finally {
        Pop-Location
    }

    # Validate key artifacts
    $requiredFiles = @(
        "bin\mlir-tblgen.exe",
        "bin\FileCheck.exe",
        "bin\lld.exe",
        "lib\cmake\mlir\MLIRConfig.cmake",
        "lib\cmake\lld\LLDConfig.cmake"
    )
    foreach ($f in $requiredFiles) {
        $fullPath = Join-Path $LLVMBuild $f
        if (-not (Test-Path $fullPath)) {
            Write-Error "LLVM build missing expected artifact: $f"
            exit 1
        }
    }
    Write-Host "LLVM build completed successfully." -ForegroundColor Green
} else {
    Write-Host "--- Step 4: Skipping LLVM build (-SkipLLVM) ---" -ForegroundColor Yellow
}
Write-Host ""

# ---------------------------------------------------------------------------
# Step 5: Download nlohmann/json
# ---------------------------------------------------------------------------
if (-not $SkipJson) {
    Write-Host "--- Step 5: Downloading nlohmann/json $JsonVersion ---" -ForegroundColor Yellow

    if (-not (Test-Path (Join-Path $JsonDir "include"))) {
        $jsonUrl = "https://github.com/nlohmann/json/releases/download/$JsonVersion/include.zip"
        $jsonZip = Join-Path $TritonRoot "json-include.zip"

        Write-Host "Downloading $jsonUrl..."
        Invoke-WebRequest -Uri $jsonUrl -OutFile $jsonZip -UseBasicParsing
        if (-not (Test-Path $jsonZip)) { Write-Error "Failed to download JSON"; exit 1 }

        Write-Host "Extracting..."
        Expand-Archive -Path $jsonZip -DestinationPath $JsonDir -Force
        Remove-Item $jsonZip -ErrorAction SilentlyContinue

        if (-not (Test-Path (Join-Path $JsonDir "include"))) {
            Write-Error "JSON extraction failed - 'include' directory not found in $JsonDir"
            exit 1
        }
    } else {
        Write-Host "JSON already present at $JsonDir"
    }
    Write-Host "JSON ready." -ForegroundColor Green
} else {
    Write-Host "--- Step 5: Skipping JSON download (-SkipJson) ---" -ForegroundColor Yellow
}
Write-Host ""

# ---------------------------------------------------------------------------
# Step 6: Install Python build dependencies
# ---------------------------------------------------------------------------
Write-Host "--- Step 6: Installing Python build dependencies ---" -ForegroundColor Yellow
pip install setuptools "cmake>=3.20,<4.0" "ninja>=1.11.1" "pybind11>=2.13.1"
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to install Python build dependencies"; exit 1 }
Write-Host "Python dependencies installed." -ForegroundColor Green
Write-Host ""

# ---------------------------------------------------------------------------
# Step 7: Build Triton
# ---------------------------------------------------------------------------
Write-Host "--- Step 7: Building Triton ---" -ForegroundColor Yellow

# Clean previous build
$tritonBuild = Join-Path $TritonRoot "build"
if (Test-Path $tritonBuild) {
    Write-Host "Removing previous build directory..."
    Remove-Item -Recurse -Force $tritonBuild
}

# Set environment variables for offline build
$Env:TRITON_OFFLINE_BUILD = "1"
$Env:LLVM_SYSPATH = $LLVMBuild
$Env:JSON_SYSPATH = $JsonDir
$Env:TRITON_BUILD_PROTON = "0"
$Env:TRITON_BUILD_UT = "0"
$Env:TRITON_BUILD_BINARY = "0"

Write-Host "Environment:"
Write-Host "  TRITON_OFFLINE_BUILD = $Env:TRITON_OFFLINE_BUILD"
Write-Host "  LLVM_SYSPATH         = $Env:LLVM_SYSPATH"
Write-Host "  JSON_SYSPATH         = $Env:JSON_SYSPATH"
Write-Host "  TRITON_BUILD_PROTON  = $Env:TRITON_BUILD_PROTON"
Write-Host "  TRITON_BUILD_UT      = $Env:TRITON_BUILD_UT"
Write-Host "  TRITON_BUILD_BINARY  = $Env:TRITON_BUILD_BINARY"
Write-Host ""

Push-Location $TritonRoot
try {
    pip install --no-build-isolation --verbose -e .
    if ($LASTEXITCODE -ne 0) { Write-Error "Triton build failed"; exit 1 }
}
finally {
    Pop-Location
}

Write-Host ""

# ---------------------------------------------------------------------------
# Step 8: Validate
# ---------------------------------------------------------------------------
Write-Host "--- Step 8: Validating installation ---" -ForegroundColor Yellow
$version = python -c "import triton; print(triton.__version__)" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Triton import failed: $version"
    exit 1
}
Write-Host "Triton $version installed successfully for ARM64!" -ForegroundColor Green
Write-Host ""

# ---------------------------------------------------------------------------
# Step 9: Run non-CUDA tests
# ---------------------------------------------------------------------------
Write-Host "--- Step 9: Running non-CUDA tests ---" -ForegroundColor Yellow

# Install test dependencies
pip install pytest pytest-forked pytest-instafail pytest-xdist
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to install test dependencies"; exit 1 }

# Copy FileCheck.exe into the triton package so _filecheck.py can find it
$fileCheckSrc = Join-Path $LLVMBuild "bin\FileCheck.exe"
$fileCheckDst = Join-Path $TritonRoot "python\triton\FileCheck.exe"
if (Test-Path $fileCheckSrc) {
    Copy-Item $fileCheckSrc $fileCheckDst -Force
    Write-Host "Copied FileCheck.exe to python\triton\"
} else {
    Write-Warning "FileCheck.exe not found at $fileCheckSrc - filecheck tests will fail"
}

$testFiles = @(
    "python/test/unit/test_filecheck.py",
    "python/test/unit/runtime/test_build.py::test_compile_module",
    "python/test/unit/tools/test_linear_layout.py",
    "python/test/unit/language/test_frontend.py"
)

$testsFailed = $false
foreach ($t in $testFiles) {
    Write-Host "`nRunning: pytest $t" -ForegroundColor Cyan
    Push-Location $TritonRoot
    pytest $t -s --tb=short
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "FAILED: $t"
        $testsFailed = $true
    }
    Pop-Location
}

if ($testsFailed) {
    Write-Warning "Some non-CUDA tests failed. Review the output above."
} else {
    Write-Host "`nAll non-CUDA tests passed!" -ForegroundColor Green
}
Write-Host ""

# ---------------------------------------------------------------------------
# Step 10: Run CUDA tests (requires NVIDIA GPU + PyTorch with CUDA)
# ---------------------------------------------------------------------------
if (-not $SkipCudaTests) {
    Write-Host "--- Step 10: Running CUDA tests ---" -ForegroundColor Yellow

    # Check for CUDA-enabled PyTorch
    $torchCuda = python -c "import torch; print(torch.cuda.is_available())" 2>&1
    if ($torchCuda -ne "True") {
        Write-Warning "PyTorch with CUDA support is not installed (torch.cuda.is_available() = $torchCuda)."
        $torchVersion = python -c "import torch; print(torch.__version__)" 2>&1
        Write-Host "  Current torch version: $torchVersion" -ForegroundColor DarkYellow
        Write-Host ""
        $response = Read-Host "Install CUDA-enabled PyTorch now? (Y/n)"
        if ($response -eq '' -or $response -match '^[Yy]') {
            Write-Host "Installing PyTorch with CUDA support..."
            pip install torch --force-reinstall --index-url https://download.pytorch.org/whl/cu126
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Failed to install CUDA PyTorch. Skipping CUDA tests."
                $SkipCudaTests = $true
            }
        } else {
            Write-Warning "Skipping CUDA tests (no CUDA-enabled PyTorch)."
            $SkipCudaTests = $true
        }
    }
}

if (-not $SkipCudaTests) {
    $cudaTestFiles = @(
        "python/test/unit/cuda/test_mixed_io.py::test_add",
        "python/test/unit/language/test_core.py::test_addptr"
    )

    $cudaTestsFailed = $false
    foreach ($t in $cudaTestFiles) {
        Write-Host "`nRunning: pytest $t" -ForegroundColor Cyan
        Push-Location $TritonRoot
        pytest $t -s --tb=short
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "FAILED: $t"
            $cudaTestsFailed = $true
        }
        Pop-Location
    }

    if ($cudaTestsFailed) {
        Write-Warning "Some CUDA tests failed. Review the output above."
    } else {
        Write-Host "`nAll CUDA tests passed!" -ForegroundColor Green
    }
} else {
    Write-Host "--- Step 10: Skipping CUDA tests (-SkipCudaTests) ---" -ForegroundColor Yellow
}
