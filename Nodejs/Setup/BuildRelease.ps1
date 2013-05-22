<#
.Synopsis
    Builds a release of Node.js Tools for Visual Studio from this branch.

.Description
    This script is used to build a set of installers for Node.js Tools for
    Visual Studio based on the code in this branch.
    
    The assembly and file versions are generated automatically and provided by
    modifying .\Build\AssemblyVersion.cs.
    
    The source is determined from the location of this script; to build another
    branch, use its Copy-Item of BuildRelease.ps1.

.Parameter outdir
    Directory to store the build.
    
    If `release` is specified, defaults to '\\pytools\release\<build number>'.

.Parameter vstarget
    [Optional] The VS version to build for. If omitted, builds for all versions
    that are installed.
    
    Valid values: "10.0", "11.0", "12.0"

.Parameter name
    [Optional] A suffix to append to the name of the build.
    
    Typical values: "Alpha", "RC1", "My Feature Name"
    (Avoid: "RTM", "2.0")

.Parameter release
    When specified:
    * `outdir` will default to \\pytools\release if unspecified
    * A build number is generated and appended to `outdir`
     - The build number includes an index
    * Debug configurations are not built
    * Binaries and symbols are sent for indexing
    * Binaries and installers are sent for signing
    
    This switch requires the code signing object to be installed, and a smart
    card and reader must be available.
    
    See also: `mockrelease`.

.Parameter internal
    When specified:
    * `outdir` will default to \\pytools\release\Internal\$name if
      unspecified
    * A build number is generated and appended to `outdir`
     - The build number includes an index
    * Both Release and Debug configurations are built
    * No binaries are sent for indexing or signing
    
    See also: `release`, `mockrelease`

.Parameter mockrelease
    When specified:
    * A build number is generated and appended to `outdir`
     - The build number includes an index
    * Both Release and Debug configurations are built
    * Indexing requests are displayed in the output but are not sent
    * Signing requests are displayed in the output but are not sent
    
    Note that `outdir` is required and has no default.
    
    This switch requires the code signing object to be installed, but no smart
    card or reader is necessary.
    
    See also: `release`, `internal`

.Parameter scorch
    If specified, the enlistment is cleaned before and after building.

.Parameter skiptests
    If specified, test projects are not built.

.Parameter skipclean
    If specified, the output directory is not cleaned before building. This has
    no effect when used with `release`, since the output directory will not
    exist before the build.

.Parameter skipcopy
    If specified, does not copy the source files to the output directory.

.Parameter skipdebug
    If specified, does not build Debug configurations.

.Example
    .\BuildRelease.ps1 -release
    
    Creates signed installers for public release in \\pytools\release\<version>

.Example
    .\BuildRelease.ps1 -name "Beta" -release
    
    Create installers for a public beta in \\pytools\release\<version>

.Example
    .\BuildRelease.ps1 -name "My Feature" -internal
    
    Create installers for an internal feature test in 
    \\pytools\release\Internal\My Feature\<version>

#>
[CmdletBinding()]
param( [string] $outdir, [string] $vsTarget, [string] $name, [switch] $release, [switch] $internal, [switch] $mockrelease, [switch] $scorch, [switch] $skiptests, [switch] $skipclean, [switch] $skipcopy, [switch] $skipdebug)

# This value is used to determine the most significant digit of the build number.
$base_year = 2012

$buildroot = (Split-Path -Parent $MyInvocation.MyCommand.Definition)
while ((Test-Path $buildroot) -and -not (Test-Path "$buildroot\build.root")) {
    $buildroot = (Split-Path -Parent $buildroot)
}
Write-Output "Build Root: $buildroot"

if (-not (get-command msbuild -EA 0)) {
    Write-Error -EA:Stop "
    Visual Studio build tools are required."
}

if (-not $outdir) {
    if ($release -or $internal) {
        $outdir = Get-Item \\pytools\Release\Nodejs -EA 0
    }
    if (-not $outdir) {
        Write-Error -EA:Stop "
    Invalid output directory '$outdir'"
    }
}

if ($name -eq "RTM") {
    $result = $host.ui.PromptForChoice(
        "Build Name",
        "'RTM' is not a recommended build name. Final releases should have a blank name.",
        [System.Management.Automation.Host.ChoiceDescription[]](
            (New-Object System.Management.Automation.Host.ChoiceDescription "&Continue", "Continue anyway"),
            (New-Object System.Management.Automation.Host.ChoiceDescription "&Abort", "Abort the build"),
            (New-Object System.Management.Automation.Host.ChoiceDescription "C&lear", "Clear the build name and continue")
        ),
        2
    )
    if ($result -eq 1) {
        exit 0
    } elseif ($result -eq 2) {
        $name = ""
    }
}

$spacename = ""
if ($name) {
    $spacename = " $name"
} elseif ($internal) {
    Write-Error -EA:Stop "
    '-name [build name]' must be specified when using '-internal'"
}

if ($internal) {
    $outdir = "$outdir\Internal\$name"
}

if ($release -or $mockrelease) {
    $approvers = "smortaz", "dinov", "stevdo", "pminaev", "arturl", "zacha", "gilbertw", "huvalo"
    $approvers = @($approvers | Where-Object {$_ -ne $env:USERNAME})
    $symbol_contacts = "$env:username;dinov;smortaz;stevdo;gilbertw"
    
    $projectName = "Node.js Tools for Visual Studio"
    $projectUrl = "http://nodejstools.codeplex.com"
    $projectKeywords = "NTVS; Visual Studio; Node.js"

    Push-Location (Split-Path -Parent $MyInvocation.MyCommand.Definition)
    if ($mockrelease) {
        Set-Variable -Name DebugPreference -Value "Continue" -Scope "global"
        Import-Module -force $buildroot\Common\Setup\ReleaseMockHelpers.psm1
    } else {
        Import-Module -force $buildroot\Common\Setup\ReleaseHelpers.psm1
    }
    Pop-Location
}

# Add new products here
# $($_.name) is currently unused
# $($_.msi) is the name of the built MSI
# $($_.outname1)$(buildname) $(targetvs.name)$($_.outname2) is the name of the final MSI
$products = @(
    @{name="NodejsTools";
      msi="NodejsToolsInstaller.msi";
      signtag="";
      outname1="NTVS"; outname2=".msi"
    }
)

Push-Location $buildroot

$asmverfileBackedUp = 0
$asmverfile = Get-ChildItem Build\AssemblyVersion.cs
# Force use of a backup if there are pending changes to $asmverfile
$asmverfileUseBackup = 0
if ((tf status $asmverfile /format:detailed | Select-String ": edit")) {
    Write-Output "$asmverfile has pending changes. Using backup instead of tf undo."
    $asmverfileUseBackup = 1
}
$asmverfileIsReadOnly = $asmverfile.Attributes -band [io.fileattributes]::ReadOnly


$buildnumber = '{0}{1:MMdd}.{2:D2}' -f (((Get-Date).Year - $base_year), (Get-Date), 0)
if ($release -or $mockrelease -or $internal) {
    for ($buildindex = 0; $buildindex -lt 10000; $buildindex += 1) {
        $buildnumber = '{0}{1:MMdd}.{2:D2}' -f (((Get-Date).Year - $base_year), (Get-Date), $buildindex)
        if (-not (Test-Path $outdir\$buildnumber)) {
            break
        }
        $buildnumber = ''
    }
}
if (-not $buildnumber) {
    Write-Error -EA:Stop "
    Cannot create version number. Try another output folder."
}
if ([int]::Parse([regex]::Match($buildnumber, '^[0-9]+').Value) -ge 65535) {
    Write-Error -EA:Stop "
    Build number $buildnumber is invalid. Update `$base_year in this script.
    (If the year is not yet $($base_year + 7) then something else has gone wrong.)"
}

$releaseVersion = [regex]::Match((Get-Content $asmverfile), 'ReleaseVersion = "([0-9.]+)";').Groups[1].Value
$minorVersion = [regex]::Match((Get-Content $asmverfile), 'MinorVersion = "([0-9.]+)";').Groups[1].Value
$version = "$releaseVersion.$buildnumber"

if ($release -or $mockrelease -or $internal) {
    $outdir = "$outdir\$buildnumber"
}

$supportedVersions = @{number="12.0"; name="VS 2013"}, @{number="11.0"; name="VS 2012"}
$targetVersions = @()

foreach ($targetVs in $supportedVersions) {
    if (-not $vstarget -or ($vstarget -match $targetVs.number)) {
        $vspath = Get-ItemProperty -Path "HKLM:\Software\Wow6432Node\Microsoft\VisualStudio\$($targetVs.number)" -EA 0
        if (-not $vspath) {
            $vspath = Get-ItemProperty -Path "HKLM:\Software\Microsoft\VisualStudio\$($targetVs.number)" -EA 0
        }
        if ($vspath -and $vspath.InstallDir -and (Test-Path -Path $vspath.InstallDir)) {
            $targetVersions += $targetVs
        }
    }
}

if (-not $targetVersions) {
    Write-Error -EA:Stop "
    No supported versions of Visual Studio installed."
}

if ($skipdebug -or $release) {
    $targetConfigs = ("Release")
} else {
    $targetConfigs = ("Debug", "Release")
}

$target = "Rebuild"
if ($skipclean) {
    $target = "Build"
}


Write-Output "Output Dir: $outdir"
Write-Output ""
Write-Output "Product version: $releaseversion.$minorversion.`$(VS version)"
Write-Output "File version: $version"
foreach ($targetVs in $targetversions) {
    Write-Output "Building for: $($targetVs.name)"
}
Write-Output ""

if (-not $skipclean) {
    if (Test-Path $outdir) {
        Write-Output "Cleaning previous release in $outdir"
        rmdir -Recurse -Force $outdir -EA 0
        while (Test-Path $outdir) {
            Write-Output "Failed to clean release. Retrying in five seconds. (Press Ctrl+C to abort)"
            Sleep -Seconds 5
            rmdir -Recurse -Force $outdir -EA 0
        }
    }
    mkdir $outdir -EA 0 | Out-Null
    if (-not $?) {
        Write-Error -EA:Stop "
    Could not make output directory: $outdir"
    }
}

if ($scorch) {
    tfpt scorch /noprompt
}

try {
    $successful = $false
    if ($asmverfileUseBackup -eq 0) {
        tf edit $asmverfile
    }
    if ($asmverfileUseBackup -or $LASTEXITCODE -gt 0) {
        # running outside of MS
        Copy-Item -force $asmverfile "$($asmverfile).bak"
        $asmverfileBackedUp = 1
    }
    Set-ItemProperty $asmverfile -Name IsReadOnly -Value $false
    (Get-Content $asmverfile) | %{ $_ -replace ' = "4100.00"', (' = "' + $buildnumber + '"') } | Set-Content $asmverfile


    foreach ($targetVs in $targetVersions) {
        foreach ($config in $targetConfigs)
        {
            $bindir = "Binaries\$config$($targetVs.number)"
            $destdir = "$outdir\$($targetVs.name)\$config"
            mkdir $destdir -EA 0 | Out-Null
            
            if (-not $skiptests)
            {
                msbuild /m /v:m /fl /flp:"Verbosity=n;LogFile=BuildRelease.$config.$($targetVs.number).tests.log" `
                    /t:$target `
                    /p:Configuration=$config `
                    /p:WixVersion=$version `
                    /p:VSTarget=$($targetVs.number) `
                    /p:VisualStudioVersion=$($targetVs.number) `
                    /p:"CustomBuildIdentifier=$($name)" `
                    Nodejs\Tests\dirs.proj
                if ($LASTEXITCODE -gt 0) {
                    Write-Error -EA:Continue "Test build failed: $config"
                    continue
                }
            }
            
            msbuild /v:n /m /fl /flp:"Verbosity=n;LogFile=BuildRelease.$config.$($targetVs.number).log" `
                /t:$target `
                /p:Configuration=$config `
                /p:WixVersion=$version `
                /p:VSTarget=$($targetVs.number) `
                /p:VisualStudioVersion=$($targetVs.number) `
                /p:"CustomBuildIdentifier=$($name)" `
                Nodejs\Setup\dirs.proj
            if ($LASTEXITCODE -gt 0) {
                Write-Error -EA:Continue "Build failed: $config"
                continue
            }
            
            Copy-Item -force $bindir\*.msi $destdir\
            Copy-Item -force Nodejs\Prerequisites\*.reg $destdir\
            
            mkdir $destdir\Symbols -EA 0 | Out-Null
            Copy-Item -force -recurse $bindir\*.pdb $destdir\Symbols\
            
            mkdir $destdir\Binaries -EA 0 | Out-Null
            Copy-Item -force -recurse $bindir\*.dll $destdir\Binaries\
            Copy-Item -force -recurse $bindir\*.exe $destdir\Binaries\
            Copy-Item -force -recurse $bindir\*.pkgdef $destdir\Binaries\
            
            mkdir $destdir\Binaries\ReplWindow -EA 0 | Out-Null
            Copy-Item -force -recurse Nodejs\Product\InteractiveWindow\obj\Dev$($targetVs.number)\$config\extension.vsixmanifest $destdir\Binaries\InteractiveWindow
            
            ######################################################################
            ##  BEGIN SIGNING CODE
            ######################################################################
            if ($release -or $mockrelease) {                
                submit_symbols "NTVS$spacename" "$buildnumber $($targetvs.name)" "symbols" "$destdir\Symbols" $symbol_contacts

                Write-Output "Signing binaries..."

                $managed_files = @((
                    "Microsoft.NodejsTools.NodeLogConverter.exe", 
                    "Microsoft.NodejsTools.dll", 
                    "Microsoft.NodejsTools.AjaxMin.dll", 
                    "Microsoft.NodejsTools.InteractiveWindow.dll",
                    "Microsoft.NodejsTools.Profiling.dll"                    
                    ) | ForEach {@{path="$destdir\Binaries\$_"; name=$projectName}})
                                
                $job1 = begin_sign_files $managed_files "$destdir\SignedBinaries" $approvers `
                    $projectName $projectUrl "$projectName - managed code" $projectKeywords `
                    "authenticode;strongname"

                end_sign_files @(,$job1)
                Write-Output "Signing binaries Completed"

                Copy-Item "$destdir\SignedBinaries" $bindir -Recurse -Force

                submit_symbols "NTVS$spacename" "$buildnumber $($targetvs.name)" "binaries" "$destdir\SignedBinaries" $symbol_contacts
                
                foreach ($cmd in (Get-Content "BuildRelease.$config.$($targetVs.number).log") | Select-String "light.exe.+-out") {
                    $targetdir = [regex]::Match($cmd, 'Nodejs\\Setup\\([^\\]+)').Groups[1].Value

                    Write-Output "Rebuilding MSI in $targetdir"

                    try {
                        Push-Location $buildroot\Nodejs\Setup\$targetdir
                    } catch {
                        Write-Error "Unable to cd to $targetdir to execute line $cmd"
                        Write-Output "Enter directory name to cd to: "
                        $targetDir = [Console]::ReadLine()
                        Push-Location $targetdir
                    }

                    try {
                        Invoke-Expression $cmd | Out-Null
                    } finally {
                        Pop-Location
                    }
                }

                mkdir $destdir\UnsignedMsi -EA 0 | Out-Null
                mkdir $destdir\SignedBinariesUnsignedMsi -EA 0 | Out-Null
                
                Move-Item $destdir\*.msi $destdir\UnsignedMsi -Force
                Move-Item $bindir\*.msi $destdir\SignedBinariesUnsignedMsi -Force
                
                $msi_files = @($products | 
                    ForEach {@{
                        path="$destdir\SignedBinariesUnsignedMsi\$($_.msi)";
                        name="Node.js Tools for Visual Studio$($_.signtag)"
                    }}
                )
                Write-Output "Signing MSIs..."
                $job = begin_sign_files $msi_files $destdir $approvers `
                    $projectName $projectUrl "$projectName - installer" $projectKeywords `
                    "authenticode"
                end_sign_files @(,$job)
                Write-Output "Signing MSIs Completed"
            }
            ######################################################################
            ##  END SIGNING CODE
            ######################################################################
        }
        
        foreach ($product in $products) {
            Copy-Item "$destdir\$($product.msi)" "$outdir\$($product.outname1)$spacename $($targetvs.name)$($product.outname2)" -Force -EA:0
            if (-not $?) {
                Write-Output "Failed to copy $destdir\$($product.msi)"
            }
        }
    }
    
    if ($scorch) {
        tfpt scorch /noprompt
    }
    
    if (-not $skipcopy) {
        Write-Output "Copying source files"
        robocopy /s . $outdir\Sources /xd Python Layouts TestResults Binaries Servicing obj | Out-Null
    }
    $successful = $true
} finally {
    if ($asmverfileBackedUp) {
        Move-Item "$($asmverfile).bak" $asmverfile -Force
        if ($asmverfileIsReadOnly) {
            Set-ItemProperty $asmverfile -Name IsReadOnly -Value $true
        }
    } elseif (-not $asmverfileUseBackup) {
        tf undo /noprompt $asmverfile
    }
    
    if (-not (Get-Content $asmverfile) -match ' = "4100.00"') {
        Write-Error "Failed to undo $asmverfile"
    }
    
    Pop-Location
}

if ($successful) {
    Write-Output ""
    Write-Output "Build complete"
    Write-Output ""
    Write-Output "Installers were output to:"
    Write-Output "    $outdir"
}
