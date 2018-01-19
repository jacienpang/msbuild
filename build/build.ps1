[CmdletBinding(PositionalBinding=$false)]
Param(
  [switch] $build,
  [switch] $ci,
  [string] $configuration = "Debug",
  [switch] $help,
  [switch] $nolog,
  [switch] $pack,
  [switch] $prepareMachine,
  [switch] $rebuild,
  [switch] $norestore,
  [switch] $sign,
  [switch] $skiptests,
  [switch] $bootstrapOnly,
  [string] $verbosity = "minimal",
  [string] $hostType,
  [Parameter(ValueFromRemainingArguments=$true)][String[]]$properties
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Print-Usage() {
    Write-Host "Common settings:"
    Write-Host "  -configuration <value>  Build configuration Debug, Release"
    Write-Host "  -verbosity <value>      Msbuild verbosity (q[uiet], m[inimal], n[ormal], d[etailed], and diag[nostic])"
    Write-Host "  -help                   Print help and exit"
    Write-Host ""
    Write-Host "Actions:"
    Write-Host "  -norestore              Don't automatically run restore"
    Write-Host "  -build                  Build solution"
    Write-Host "  -rebuild                Rebuild solution"
    Write-Host "  -skipTests              Don't run tests"
    Write-Host "  -bootstrapOnly          Don't run build again with bootstrapped MSBuild"
    Write-Host "  -sign                   Sign build outputs"
    Write-Host "  -pack                   Package build outputs into NuGet packages and Willow components"
    Write-Host ""
    Write-Host "Advanced settings:"
    Write-Host "  -ci                     Set when running on CI server"
    Write-Host "  -nolog                  Disable logging"
    Write-Host "  -prepareMachine         Prepare machine for CI run"
    Write-Host "  -hostType                   Host / MSBuild flavor to use.  Possible values: full, core"
    Write-Host ""
    Write-Host "Command line arguments not listed above are passed through to MSBuild."
    Write-Host "The above arguments can be shortened as much as to be unambiguous (e.g. -co for configuration, -t for test, etc.)."
}

function Create-Directory([string[]] $Path) {
  if (!(Test-Path -Path $Path)) {
    New-Item -Path $Path -Force -ItemType "Directory" | Out-Null
  }
}

function GetVersionsPropsVersion([string[]] $Name) {
  [xml]$Xml = Get-Content $VersionsProps

  foreach ($PropertyGroup in $Xml.Project.PropertyGroup) {
    if (Get-Member -InputObject $PropertyGroup -name $Name) {
        return $PropertyGroup.$Name
    }
  }

  throw "Failed to locate the $Name property"
}

function InstallDotNetCli {
  $DotNetCliVersion = GetVersionsPropsVersion -Name "DotNetCliVersion"
  $DotNetInstallVerbosity = ""

  if (!$env:DOTNET_INSTALL_DIR) {
    $env:DOTNET_INSTALL_DIR = Join-Path $RepoRoot "artifacts\.dotnet\$DotNetCliVersion\"
  }

  $DotNetRoot = $env:DOTNET_INSTALL_DIR
  $DotNetInstallScript = Join-Path $DotNetRoot "dotnet-install.ps1"

  if (!(Test-Path $DotNetInstallScript)) {
    Create-Directory $DotNetRoot
    Invoke-WebRequest "https://dot.net/v1/dotnet-install.ps1" -UseBasicParsing -OutFile $DotNetInstallScript
  }

  if ($verbosity -eq "diagnostic") {
    $DotNetInstallVerbosity = "-Verbose"
  }

  # Install a stage 0
  $SdkInstallDir = Join-Path $DotNetRoot "sdk\$DotNetCliVersion"

  if (!(Test-Path $SdkInstallDir)) {
    # Use Invoke-Expression so that $DotNetInstallVerbosity is not positionally bound when empty
    Invoke-Expression -Command "$DotNetInstallScript -Version $DotNetCliVersion $DotNetInstallVerbosity"

    if($LASTEXITCODE -ne 0) {
      throw "Failed to install stage0"
    }
  }

  # Put the stage 0 on the path
  $env:PATH = "$DotNetRoot;$env:PATH"

  # Disable first run since we want to control all package sources
  $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1

  # Don't resolve runtime, shared framework, or SDK from other locations
  $env:DOTNET_MULTILEVEL_LOOKUP=0
}

function InstallNuGet {
  $NugetInstallDir = Join-Path $RepoRoot "artifacts\.nuget"
  $NugetExe = Join-Path $NugetInstallDir "nuget.exe"

  if (!(Test-Path -Path $NugetExe)) {
    Create-Directory $NugetInstallDir
    Invoke-WebRequest "https://dist.nuget.org/win-x86-commandline/latest/nuget.exe" -UseBasicParsing -OutFile $NugetExe
  }
}

function InstallRepoToolset {
  $RepoToolsetVersion = GetVersionsPropsVersion -Name "RoslynToolsRepoToolsetVersion"
  $RepoToolsetDir = Join-Path $NuGetPackageRoot "roslyntools.repotoolset\$RepoToolsetVersion\tools"
  $RepoToolsetBuildProj = Join-Path $RepoToolsetDir "Build.proj"

  $logCmd = GetLogCmd("Toolset")

  if (!(Test-Path -Path $RepoToolsetBuildProj)) {
    $ToolsetProj = Join-Path $PSScriptRoot "Toolset.proj"
    # Piping to Out-Null is important here, as otherwise the MSBuild output will be included in the return value
    # of the function (Powershell handles return values a bit... weirdly)
    CallMSBuild $ToolsetProj /t:restore /m /nologo /clp:Summary /warnaserror /v:$verbosity @logCmd | Out-Null

    if($LASTEXITCODE -ne 0) {
      throw "Failed to build $ToolsetProj"
    }
  }

  return $RepoToolsetBuildProj
}

function LocateVisualStudio {
  $VSWhereVersion = GetVersionsPropsVersion -Name "VSWhereVersion"
  $VSWhereDir = Join-Path $ArtifactsDir ".tools\vswhere\$VSWhereVersion"
  $VSWhereExe = Join-Path $vsWhereDir "vswhere.exe"

  if (!(Test-Path $VSWhereExe)) {
    Create-Directory $VSWhereDir
    Invoke-WebRequest "http://github.com/Microsoft/vswhere/releases/download/$VSWhereVersion/vswhere.exe" -UseBasicParsing -OutFile $VSWhereExe
  }

  $VSInstallDir = & $VSWhereExe -latest -property installationPath -requires Microsoft.Component.MSBuild -requires Microsoft.VisualStudio.Component.VSSDK -requires Microsoft.Net.Component.4.6.TargetingPack -requires Microsoft.VisualStudio.Component.Roslyn.Compiler -requires Microsoft.VisualStudio.Component.VSSDK

  if (!(Test-Path $VSInstallDir)) {
    throw "Failed to locate Visual Studio (exit code '$LASTEXITCODE')."
  }

  return $VSInstallDir
}

function Build {
  InstallDotNetCli
  InstallNuget

  if ($hostType -eq 'full')
  {
    $msbuildHost = $null
  }
  elseif ($hostType -eq 'core')
  {
    $msbuildHost = Join-Path $env:DOTNET_INSTALL_DIR "dotnet.exe"
    $env:DOTNET_HOST_PATH = $msbuildHost
  }
  else
  {
    throw "Unknown hostType parameter: $hostType"
  }

  $RepoToolsetBuildProj = InstallRepoToolset

  if ($prepareMachine) {
    Create-Directory $NuGetPackageRoot
    dotnet nuget locals all --clear

    if($LASTEXITCODE -ne 0) {
      throw "Failed to clear NuGet cache"
    }
  }

  $logCmd = GetLogCmd("Build")

  $solution = Join-Path $RepoRoot "MSBuild.sln"

  $commonMSBuildArgs = "/m", "/nologo", "/clp:Summary", "/v:$verbosity", "/p:Configuration=$configuration", "/p:SolutionPath=$solution", "/p:CIBuild=$ci"
  if ($ci)
  {
    # Only enable warnaserror on CI runs.  For local builds, we will generate a warning if we can't run EditBin because
    # the C++ tools aren't installed, and we don't want this to fail the build
    $commonMSBuildArgs = $commonMSBuildArgs + "/warnaserror" 
  }
  
  # Only test using stage 0 MSBuild if -bootstrapOnly is specified
  $testStage0 = $false
  if ($bootstrapOnly)
  {
    $testStage0 = $test
  }

  CallMSBuild $RepoToolsetBuildProj @commonMSBuildArgs @logCmd /p:Restore=$restore /p:Build=$build /p:Rebuild=$rebuild /p:Test=$testStage0 /p:Sign=$sign /p:Pack=$pack /p:CreateBootstrap=true $properties

  if (-not $bootstrapOnly)
  {
    $bootstrapRoot = Join-Path $ArtifactsConfigurationDir "bootstrap"

    if ($hostType -eq 'full')
    {
      $msbuildToUse = Join-Path $bootstrapRoot "net46\MSBuild\15.0\Bin\MSBuild.exe"

      if ($configuration -eq "Debug-MONO" -or $configuration -eq "Release-MONO")
      {
        # Copy MSBuild.dll to MSBuild.exe so we can run it without a host
        $sourceDll = Join-Path $bootstrapRoot "net46\MSBuild\15.0\Bin\MSBuild.dll"
        Copy-Item -Path $sourceDll -Destination $msbuildToUse
      }
    }
    else
    {
      $msbuildToUse = Join-Path $bootstrapRoot "netcoreapp2.0\MSBuild\\MSBuild.dll"
    }

    # Use separate artifacts folder for stage 2
    $env:ArtifactsDir = Join-Path $ArtifactsDir "2\"

    $logCmd = GetLogCmd("BuildWithBootstrap")

    try
    {
      # When using bootstrapped MSBuild:
      # - Turn off node reuse (so that bootstrapped MSBuild processes don't stay running and lock files)
      # - Don't sign
      # - Don't pack
      # - Do run tests (if not skipped)
      # - Don't try to create a bootstrap deployment
      CallMSBuild $RepoToolsetBuildProj @commonMSBuildArgs /nr:false @logCmd /p:Restore=$restore /p:Build=$build /p:Rebuild=$rebuild /p:Test=$test /p:Sign=false /p:Pack=false /p:CreateBootstrap=false $properties
    }
    finally
    {
      # Kill compiler server and MSBuild node processes from bootstrapped MSBuild (otherwise a second build will fail to copy files in use)
      foreach ($process in Get-Process | Where-Object {'msbuild', 'dotnet', 'vbcscompiler' -contains $_.Name})
      {
        if ($process.Path.StartsWith( $RepoRoot, [StringComparison]::InvariantCultureIgnoreCase))
        {
          taskkill /f /pid $process.Id
        }
      }
    }
  }

  if ($ci)
  {
#    CallMSBuild $ToolsetProj /t:restore /m /nologo /clp:Summary /warnaserror /v:$verbosity @logCmd | Out-Null
    git status | Out-Null
    git --no-pager diff HEAD --word-diff=plain --exit-code | Out-Null

    if($LASTEXITCODE -ne 0) {
      throw "[ERROR] After building, there are changed files.  Please build locally and include these changes in your pull request."
    }
  }

}
function CallMSBuild
{
  if ($msbuildHost)
  {
    & $msbuildHost $msbuildToUse $args
  }
  else
  {
    & $msbuildToUse $args
  }

    if($LASTEXITCODE -ne 0) {
      throw "Failed to build $args"
  }
}

function GetLogCmd([string] $logName)
{
  $logCmd = @()
  if ($ci -or $log) {
    Create-Directory $LogDir
    $logCmd = $logCmd + ("/bl:" + (Join-Path $LogDir "$logName.binlog"))

    # When running under CI, also create a text log, so it can be viewed in the Jenkins UI
    if ($ci) {
      $logCmd = $logCmd + ("/flp:Verbosity=diag;LogFile=" + '"' + (Join-Path $LogDir "$logName.log") + '"')
    }
  }

  return $logCmd;
}

function Stop-Processes() {
  Write-Host "Killing running build processes..."
  Get-Process -Name "msbuild" -ErrorAction SilentlyContinue | Stop-Process
  Get-Process -Name "vbcscompiler" -ErrorAction SilentlyContinue | Stop-Process
}

if ($help -or (($properties -ne $null) -and ($properties.Contains("/help") -or $properties.Contains("/?")))) {
  Print-Usage
  exit 0
}

$RepoRoot = Join-Path $PSScriptRoot "..\"
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot);
$ArtifactsDir = Join-Path $RepoRoot "artifacts"
$ArtifactsConfigurationDir = Join-Path $ArtifactsDir $configuration
$LogDir = Join-Path $ArtifactsConfigurationDir "log"
$VersionsProps = Join-Path $PSScriptRoot "Versions.props"

$log = -not $nolog
$restore = -not $norestore
$test = -not $skiptests

if ($hostType -eq '')
{
  $hostType = 'full'
}

# TODO: If host type is full, either make sure we're running in a developer command prompt, or attempt to locate VS, or fail

$msbuildHost = $null
$msbuildToUse = "msbuild"



try {
  if ($ci) {
    $TempDir = Join-Path $ArtifactsConfigurationDir "tmp"
    Create-Directory $TempDir

    $env:TEMP = $TempDir
    $env:TMP = $TempDir
  }

  if (!($env:NUGET_PACKAGES)) {
    $env:NUGET_PACKAGES = Join-Path $env:UserProfile ".nuget\packages"
  }

  $NuGetPackageRoot = $env:NUGET_PACKAGES

  Build
  exit $lastExitCode
}
catch {
  Write-Host $_
  Write-Host $_.Exception
  Write-Host $_.ScriptStackTrace
  exit 1
}
finally {
  Pop-Location
  if ($ci -and $prepareMachine) {
    Stop-Processes
  }
}