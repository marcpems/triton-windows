#Requires -Version 5.1
<#
.SYNOPSIS
    Builds Triton for x64 Windows from a fresh clone.

.DESCRIPTION
    This script performs a complete offline build of Triton on Windows x64.
    It clones and builds LLVM (with MLIR and LLD), downloads nlohmann/json,
    installs Python build dependencies, and builds Triton via pip.

.PARAMETER LLVMBuildJobs
    Number of parallel jobs for the LLVM build. Default: 8.

.PARAMETER Branch
    Branch to checkout before building. Default: release/3.6.x-windows.

.PARAMETER SkipLLVM
    Skip the LLVM clone/build step (use if LLVM is already built).

.PARAMETER SkipJson
    Skip the JSON download step (use if JSON is already downloaded).

.EXAMPLE
    .\build.ps1
    .\build.ps1 -LLVMBuildJobs 16
    .\build.ps1 -SkipLLVM -SkipJson
#>
param(
    [int]$LLVMBuildJobs = 8,
    [string]$Branch = "release/3.6.x-windows",
    [switch]$SkipLLVM,
    [switch]$SkipJson
)

$ErrorActionPreference = "Stop"
$TritonRoot = $PSScriptRoot
$LLVMDir = Join-Path $TritonRoot "llvm-project"
$LLVMBuild = Join-Path $LLVMDir "build"
$JsonDir = Join-Path $TritonRoot "json"
$LLVMHash = (Get-Content (Join-Path $TritonRoot "cmake\llvm-hash.txt") -Raw).Trim()
$JsonVersion = (Get-Content (Join-Path $TritonRoot "cmake\json-version.txt") -Raw).Trim()

Write-Host "=== Triton Windows Build Script ===" -ForegroundColor Cyan
Write-Host "Triton root:  $TritonRoot"
Write-Host "LLVM commit:  $LLVMHash"
Write-Host "JSON version: $JsonVersion"
Write-Host ""

# ---------------------------------------------------------------------------
# Prerequisites check
# ---------------------------------------------------------------------------
Write-Host "--- Checking prerequisites ---" -ForegroundColor Yellow

$missing = @()
if (-not (Get-Command python -ErrorAction SilentlyContinue)) { $missing += "python" }
if (-not (Get-Command cmake -ErrorAction SilentlyContinue))  { $missing += "cmake" }
if (-not (Get-Command ninja -ErrorAction SilentlyContinue))  { $missing += "ninja" }
if (-not (Get-Command git -ErrorAction SilentlyContinue))    { $missing += "git" }
if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) { $missing += "cl.exe (MSVC)" }

if ($missing.Count -gt 0) {
    Write-Error "Missing required tools: $($missing -join ', '). Please install them and ensure they are on PATH."
    exit 1
}

Write-Host "All prerequisites found." -ForegroundColor Green
Write-Host ""

# ---------------------------------------------------------------------------
# Ensure correct branch
# ---------------------------------------------------------------------------
$currentBranch = (git -C $TritonRoot rev-parse --abbrev-ref HEAD 2>$null)
if ($currentBranch -ne $Branch) {
    Write-Host "--- Switching to branch $Branch ---" -ForegroundColor Yellow
    git -C $TritonRoot fetch origin $Branch
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to fetch branch $Branch"; exit 1 }
    git -C $TritonRoot checkout $Branch
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to checkout branch $Branch"; exit 1 }

    # Re-read hashes after branch switch (they may differ per branch)
    $LLVMHash = (Get-Content (Join-Path $TritonRoot "cmake\llvm-hash.txt") -Raw).Trim()
    $JsonVersion = (Get-Content (Join-Path $TritonRoot "cmake\json-version.txt") -Raw).Trim()
    Write-Host "LLVM commit (updated): $LLVMHash"
    Write-Host "JSON version (updated): $JsonVersion"
}
Write-Host ""

# ---------------------------------------------------------------------------
# Step 1: Clone and build LLVM (with MLIR + LLD)
# ---------------------------------------------------------------------------
if (-not $SkipLLVM) {
    Write-Host "--- Step 1: Building LLVM ---" -ForegroundColor Yellow

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

        Write-Host "Configuring LLVM with CMake..."
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
    Write-Host "--- Step 1: Skipping LLVM build (--SkipLLVM) ---" -ForegroundColor Yellow
}
Write-Host ""

# ---------------------------------------------------------------------------
# Step 2: Download nlohmann/json
# ---------------------------------------------------------------------------
if (-not $SkipJson) {
    Write-Host "--- Step 2: Downloading nlohmann/json $JsonVersion ---" -ForegroundColor Yellow

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
    Write-Host "--- Step 2: Skipping JSON download (--SkipJson) ---" -ForegroundColor Yellow
}
Write-Host ""

# ---------------------------------------------------------------------------
# Step 3: Install Python build dependencies
# ---------------------------------------------------------------------------
Write-Host "--- Step 3: Installing Python build dependencies ---" -ForegroundColor Yellow
pip install setuptools "cmake>=3.20,<4.0" "ninja>=1.11.1" "pybind11>=2.13.1"
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to install Python build dependencies"; exit 1 }
Write-Host "Python dependencies installed." -ForegroundColor Green
Write-Host ""

# ---------------------------------------------------------------------------
# Step 4: Build Triton
# ---------------------------------------------------------------------------
Write-Host "--- Step 4: Building Triton ---" -ForegroundColor Yellow

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
# Step 5: Validate
# ---------------------------------------------------------------------------
Write-Host "--- Step 5: Validating installation ---" -ForegroundColor Yellow
$version = python -c "import triton; print(triton.__version__)" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Triton import failed: $version"
    exit 1
}
Write-Host "Triton $version installed successfully!" -ForegroundColor Green
