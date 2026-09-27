Param(
    [Parameter(Mandatory = $true)]
    [hashtable] $parameters
)

# AL-Go dot-sources this script once per project - run in a child scope to avoid overwriting the Deliver action's variables
& {
    $errorActionPreference = "Stop"; $ProgressPreference = "SilentlyContinue"; Set-StrictMode -Version 2.0

    function Compare-AppFiles {
        Param(
            [Parameter(Mandatory = $true)]
            [string] $AppFile1,
            [Parameter(Mandatory = $true)]
            [string] $AppFile2
        )

        $tempFolder1 = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
        $tempFolder2 = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
        try {
            Extract-AppFileToFolder -appFilename $AppFile1 -appFolder $tempFolder1 -generateAppJson
            Extract-AppFileToFolder -appFilename $AppFile2 -appFolder $tempFolder2 -generateAppJson

            foreach ($folder in @($tempFolder1, $tempFolder2)) {
                Get-ChildItem -Path $folder -Recurse -Filter '*.zip' | ForEach-Object {
                    Expand-Archive -Path $_.FullName -DestinationPath (Join-Path $_.DirectoryName $_.BaseName) -Force
                    Remove-Item $_.FullName -Force
                }
            }

            $files1 = @(Get-ChildItem -Path $tempFolder1 -Recurse -File | ForEach-Object { $_.FullName.Substring($tempFolder1.Length) })
            $files2 = @(Get-ChildItem -Path $tempFolder2 -Recurse -File | ForEach-Object { $_.FullName.Substring($tempFolder2.Length) })

            # Files which differ between builds of the same source code
            $ignoreFiles = @('navigation.xml', 'DocComments.xml', 'MediaIdListing.xml', 'SymbolReference.json', '[Content_Types].xml', 'NavxManifest.xml')
            $allFiles = @($files1 + $files2 | Select-Object -Unique | Where-Object { [System.IO.Path]::GetFileName($_) -notin $ignoreFiles })

            $differentFiles = @()
            foreach ($relativePath in $allFiles) {
                $file1Path = Join-Path $tempFolder1 $relativePath
                $file2Path = Join-Path $tempFolder2 $relativePath
                if (-not (Test-Path $file1Path) -or -not (Test-Path $file2Path)) {
                    $differentFiles += $relativePath
                    continue
                }
                if ((Get-FileHash -Path $file1Path -Algorithm SHA256).Hash -eq (Get-FileHash -Path $file2Path -Algorithm SHA256).Hash) {
                    continue
                }
                if ([System.IO.Path]::GetFileName($relativePath) -eq 'app.json') {
                    $json1 = Get-Content -Path $file1Path -Encoding UTF8 -Raw | ConvertFrom-Json
                    $json2 = Get-Content -Path $file2Path -Encoding UTF8 -Raw | ConvertFrom-Json
                    $json1.version = $null
                    $json2.version = $null
                    if (($json1 | ConvertTo-Json -Depth 99) -eq ($json2 | ConvertTo-Json -Depth 99)) {
                        continue
                    }
                }
                $differentFiles += $relativePath
            }

            if ($differentFiles.Count -gt 0) {
                Write-Host "Files that differ:"
                $differentFiles | ForEach-Object { Write-Host "  $_" }
                return $false
            }
            return $true
        }
        finally {
            if (Test-Path $tempFolder1) { Remove-Item $tempFolder1 -Recurse -Force }
            if (Test-Path $tempFolder2) { Remove-Item $tempFolder2 -Recurse -Force }
        }
    }

    # State shared across the per-project invocations (script scope is the Deliver action's script scope)
    if (-not (Get-Variable -Name 'deliverToNuGetState' -Scope Script -ErrorAction SilentlyContinue)) {
        $script:deliverToNuGetState = @{
            "processedPackages" = @()
            "manifestEntries"   = @()
        }
    }
    $state = $script:deliverToNuGetState

    # The delivery target is taken from the file name (DeliverToNuGet.ps1 or DeliverToGitHubPackages.ps1)
    $deliveryTarget = [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath) -replace '^DeliverTo', ''

    # Only continuous delivery to NuGet uses the preview tag
    $preReleaseTag = ''
    if ($parameters.type -eq 'CD') {
        $preReleaseTag = 'preview'
    }

    try {
        $nuGetAccount = $parameters.Context | ConvertFrom-Json | ConvertTo-HashTable
        $nuGetServerUrl = $nuGetAccount.ServerUrl
        # Returns a PAT unaltered, exchanges a GitHub App secret for an access token
        $nuGetToken = GetAccessToken -token $nuGetAccount.Token -permissions @{"packages"="write";"contents"="read";"metadata"="read"}
        if (-not $nuGetServerUrl -or -not $nuGetToken) {
            throw
        }
    }
    catch {
        throw "$($deliveryTarget)Context secret is malformed. Needs to be formatted as Json, containing serverUrl and token as a minimum."
    }
    Write-Host "Delivering to $nuGetServerUrl"

    # Do not search trusted NuGet feeds for packages when looking for whether packages have been delivered
    $bcContainerHelperConfig.TrustedNuGetFeeds = @()

    foreach ($artifactType in @('apps', 'testApps')) {
        $folder = $parameters["$($artifactType)Folder"]
        if (-not $folder) {
            continue
        }
        foreach ($appFile in @(Get-ChildItem -Path (Join-Path $folder '*.app'))) {
            $newAppFile = $appFile.FullName
            $appJson = Get-AppJsonFromAppFile -appFile $newAppFile
            $packageName = Get-BcNuGetPackageId -publisher $appJson.publisher -name $appJson.name -id $appJson.id -version $appJson.version
            if ($state.processedPackages -contains $packageName) {
                Write-Host "Package $packageName has already been delivered in this run, skipping"
                continue
            }

            $searchVersion = $appJson.version
            if ($preReleaseTag) {
                $searchVersion += "-$preReleaseTag"
            }
            $feed, $packageId, $packageVersion = Find-BcNugetPackage -nuGetServerUrl $nuGetServerUrl -nuGetToken $nuGetToken -packageName $packageName -version $searchVersion -select Exact -allowPrerelease
            if ($feed) {
                Write-Host "Package $packageName version $searchVersion already exists on the feed"
                continue
            }

            $pushNewPackage = $true
            $packageFolder = Get-BcNuGetPackage -nuGetServerUrl $nuGetServerUrl -nuGetToken $nuGetToken -packageName $packageName -select Latest -allowPrerelease:($preReleaseTag -ne '')
            if ($packageFolder) {
                $oldAppFile = Get-ChildItem -Path (Join-Path $packageFolder '*.app') | Select-Object -First 1
                if ($oldAppFile) {
                    $pushNewPackage = -not (Compare-AppFiles -AppFile1 $newAppFile -AppFile2 $oldAppFile.FullName)
                    if (-not $pushNewPackage) {
                        Write-Host "The last published package $packageName is identical to the one being delivered, skipping"
                    }
                }
            }

            if ($pushNewPackage) {
                Write-Host "Pushing new package $packageName to $nuGetServerUrl"
                $package = New-BcNuGetPackage -gitHubRepository "$ENV:GITHUB_SERVER_URL/$ENV:GITHUB_REPOSITORY" -preReleaseTag $preReleaseTag -appFile $newAppFile
                Push-BcNuGetPackage -nuGetServerUrl $nuGetServerUrl -nuGetToken $nuGetToken -bcNuGetPackage $package
                if ($artifactType -eq 'Apps') {
                    $state.manifestEntries += [PSCustomObject]@{
                        "id"             = "$($appJson.id)"
                        "name"           = "$($appJson.name)"
                        "publisher"      = "$($appJson.publisher)"
                        "version"        = "$($appJson.version)"
                        "project"        = "$($parameters.Project)"
                        "packageName"    = "$packageName"
                        "deliveryTarget" = "$deliveryTarget"
                    }
                }
            }
            $state.processedPackages += $packageName
        }
    }

    # Rewritten after every project, so the file holds the complete manifest once the last project has been delivered
    $manifestFolder = [System.IO.Path]::GetTempPath()
    $manifestPath = Join-Path $manifestFolder "DeliveryManifest-$($deliveryTarget).json"
    $deliveryManifest = [PSCustomObject]@{
        "schemaVersion"  = 1
        "repository"     = "$ENV:GITHUB_REPOSITORY"
        "runId"          = "$ENV:GITHUB_RUN_ID"
        "runAttempt"     = "$ENV:GITHUB_RUN_ATTEMPT"
        "headSha"        = "$ENV:GITHUB_SHA"
        "deliveryTarget" = "$deliveryTarget"
        "apps"           = [object[]] $state.manifestEntries
    }
    ConvertTo-Json -InputObject $deliveryManifest -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8
    Write-Host "Delivery manifest with $($state.manifestEntries.Count) package(s) written to $manifestPath"

    # TODO: need to upload file: $manifestPath (DeliveryManifest-<deliveryTarget>.json) somewhere
}
