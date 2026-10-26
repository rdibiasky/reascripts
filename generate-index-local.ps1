param(
    [string]$RepositoryName = "rdibiasky ReaScripts",
    [string]$Branch = "main",
    [string]$OutputPath = (Join-Path $PSScriptRoot "index.xml")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-Git {
    param([string[]]$Arguments)

    $output = & git -C $PSScriptRoot @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Git command failed: git $($Arguments -join ' ')`n$output"
    }
    return ($output -join "`n").Trim()
}

function Get-GitHubRepositoryPath {
    param([string]$Remote)

    if ($Remote -match '^git@github\.com:(?<path>.+)$') {
        $path = $Matches.path
    }
    else {
        $uri = $null
        if (-not [Uri]::TryCreate($Remote, [UriKind]::Absolute, [ref]$uri) -or
            $uri.Host -ne "github.com") {
            throw "The origin remote must point to a GitHub repository: $Remote"
        }
        $path = $uri.AbsolutePath.Trim("/")
    }

    $path = $path -replace '\.git$', ''
    if ($path -notmatch '^[^/]+/[^/]+$') {
        throw "Could not determine the GitHub owner and repository from: $Remote"
    }
    return $path
}

function ConvertTo-UrlPath {
    param([string]$Path)

    return (($Path -split '/') | ForEach-Object {
        [Uri]::EscapeDataString($_)
    }) -join '/'
}

function Get-ScriptMetadata {
    param([string[]]$Lines, [string]$Path)

    $metadata = @{}
    foreach ($line in $Lines) {
        if ($line -match '^\s*--\s*@(?<key>description|version|author)\s+(?<value>.*?)\s*$') {
            $metadata[$Matches.key] = $Matches.value.Trim()
        }
    }

    foreach ($key in @("description", "version", "author")) {
        if (-not $metadata.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($metadata[$key])) {
            throw "Missing -- @$key metadata in $Path"
        }
    }

    $metadata.author = $metadata.author -replace '\s*\([^)]*\)\s*$', ''
    if ([string]::IsNullOrWhiteSpace($metadata.author)) {
        throw "The -- @author value is empty in $Path"
    }
    return $metadata
}

$repositoryPath = Get-GitHubRepositoryPath (Invoke-Git @("remote", "get-url", "origin"))
$commit = Invoke-Git @("rev-parse", "HEAD")
$sourceBase = "https://raw.githubusercontent.com/$repositoryPath/$(ConvertTo-UrlPath $Branch)"

$existingVersions = @{}
if (Test-Path -LiteralPath $OutputPath) {
    $existingIndex = New-Object System.Xml.XmlDocument
    $existingIndex.Load((Resolve-Path -LiteralPath $OutputPath).Path)
    foreach ($package in $existingIndex.SelectNodes("/index/category/reapack")) {
        $existingVersions[$package.GetAttribute("name")] = $package.SelectNodes("version")
    }
}

$scripts = @(Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File -Filter "*.lua" |
    Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' } |
    Sort-Object FullName)
if ($scripts.Count -eq 0) {
    throw "No Lua scripts were found under $PSScriptRoot"
}

$packages = @()
$packageNames = @{}
foreach ($script in $scripts) {
    $relativePath = $script.FullName.Substring($PSScriptRoot.TrimEnd('\').Length).
        TrimStart('\', '/') -replace '\\', '/'
    $pathParts = $relativePath -split '/'
    $category = if ($pathParts.Count -gt 1) { $pathParts[0] } else { "General" }
    $packageName = [IO.Path]::GetFileName($relativePath)

    if ($packageNames.ContainsKey($packageName)) {
        throw "Duplicate ReaPack package name '$packageName': $($packageNames[$packageName]) and $relativePath"
    }
    $packageNames[$packageName] = $relativePath

    $metadata = Get-ScriptMetadata (Get-Content -LiteralPath $script.FullName) $relativePath
    $urlPath = ConvertTo-UrlPath $relativePath
    $versionTime = $script.LastWriteTimeUtc.ToString(
        "yyyy-MM-dd'T'HH:mm:ss'Z'",
        [Globalization.CultureInfo]::InvariantCulture
    )

    $packages += [pscustomobject]@{
        Category = $category
        Name = $packageName
        Description = $metadata.description
        Version = $metadata.version
        Author = $metadata.author
        Time = $versionTime
        Source = "$sourceBase/$urlPath"
    }
}

$document = New-Object System.Xml.XmlDocument
$document.PreserveWhitespace = $false
$declaration = $document.CreateXmlDeclaration("1.0", "utf-8", $null)
[void]$document.AppendChild($declaration)
$index = $document.CreateElement("index")
$index.SetAttribute("version", "1")
$index.SetAttribute("commit", $commit)
$index.SetAttribute("name", $RepositoryName)
[void]$document.AppendChild($index)

foreach ($categoryGroup in ($packages | Group-Object Category | Sort-Object Name)) {
    $categoryNode = $document.CreateElement("category")
    $categoryNode.SetAttribute("name", $categoryGroup.Name)
    [void]$index.AppendChild($categoryNode)

    foreach ($package in ($categoryGroup.Group | Sort-Object Name)) {
        $packageNode = $document.CreateElement("reapack")
        $packageNode.SetAttribute("name", $package.Name)
        $packageNode.SetAttribute("type", "script")
        $packageNode.SetAttribute("desc", $package.Description)

        if ($existingVersions.ContainsKey($package.Name)) {
            foreach ($oldVersion in $existingVersions[$package.Name]) {
                if ($oldVersion.GetAttribute("name") -ne $package.Version) {
                    [void]$packageNode.AppendChild($document.ImportNode($oldVersion, $true))
                }
            }
        }

        $versionNode = $document.CreateElement("version")
        $versionNode.SetAttribute("name", $package.Version)
        $versionNode.SetAttribute("author", $package.Author)
        $versionNode.SetAttribute("time", $package.Time)
        $sourceNode = $document.CreateElement("source")
        $sourceNode.SetAttribute("main", "main")
        $sourceNode.InnerText = $package.Source
        [void]$versionNode.AppendChild($sourceNode)
        [void]$packageNode.AppendChild($versionNode)
        [void]$categoryNode.AppendChild($packageNode)
    }
}

$outputFullPath = [IO.Path]::GetFullPath($OutputPath)
$outputDirectory = [IO.Path]::GetDirectoryName($outputFullPath)
if (-not (Test-Path -LiteralPath $outputDirectory)) {
    [void](New-Item -ItemType Directory -Path $outputDirectory)
}

$settings = New-Object System.Xml.XmlWriterSettings
$settings.Encoding = New-Object System.Text.UTF8Encoding($false)
$settings.Indent = $true
$settings.IndentChars = "  "
$settings.NewLineChars = "`n"
$settings.NewLineHandling = [System.Xml.NewLineHandling]::Replace
$writer = [System.Xml.XmlWriter]::Create($outputFullPath, $settings)
try {
    $document.Save($writer)
}
finally {
    $writer.Dispose()
}

Write-Host "Generated $outputFullPath with $($packages.Count) script(s)."
Write-Host "Package sources target $repositoryPath on branch '$Branch'."
