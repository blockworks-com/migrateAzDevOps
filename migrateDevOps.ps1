param([string]$sourceOrg, [string]$sourcePAT, 
    [string]$targetOrg, [string]$targetPAT, 
    [string]$projects,
    [switch]$getProjectList = $false, [switch]$verbose = $false, [switch]$WhatIf = $false, [switch]$skipRepos = $false, [switch]$skipWorkItems = $false)

#####################################
# Variables
#####################################
$projectsArray = $null
# 1. Pass project list via command line with: -projects '[{"""source""": """source3-agile""", """target""": """"""},{"""source2-scrum""": """target2-scrum""", """target""": """"""}]'
# 2. Or add the project list here: $projectsArray = @([pscustomobject]@{source = "source3-agile"; target = "" })
# 3. If both are blank, user will be prompt for each project in Source

# Can leave as defaults
$workItemBatchSize = 5000
$templatePath = "$pwd"

#####################################
# Commandline
#####################################
$originalVerbose = $VerbosePreference
if ($verbose) {
    $VerbosePreference = "continue" 
    Write-Verbose "Verbose on"
}
[bool]$onlyProjectList = $false
switch ($getProjectList) {    
    $true {
        $onlyProjectList = $true
        Write-Verbose "Get Source Project List is true"
    }    
}
$originalWhatIfPreference = $WhatIfPreference
switch ($WhatIf) {    
    $true {
        $WhatIfPreference = $true
        Write-Verbose "WhatIf set to true to test without performing destructive commands"
    }    
}
[bool]$migrateRepos = $true
switch ($skipRepos) {    
    $true {
        $migrateRepos = $false
        Write-Verbose "Skipping Repository Migration"
    }    
}
[bool]$migrateWorkItems = $true
switch ($skipWorkItems) {    
    $true {
        $migrateWorkItems = $false
        Write-Verbose "Skipping Work Item Migration"
    }    
}
if ($projects.Length -gt 0) {
    # projects were passed as a parameter so convert from json string
    try {
        $projectsArray = $projects | ConvertFrom-Json
        Write-Verbose "Projects passed as parameter converted to array containing $($projectsArray.Length) projects"
    }
    catch {
        Write-Warning "Invalid projects parameter. Fix the parameter json string. Follow this syntax:"
        Write-Warning "-projects '[{`"`"`"source`"`"`": `"`"`"source3-agile`"`"`", `"`"`"target`"`"`": `"`"`"`"`"`"},{`"`"`"source2-scrum`"`"`": `"`"`"target2-scrum`"`"`", `"`"`"target`"`"`": `"`"`"`"`"`"}]'"
        Write-Error "Failed to convert projects parameter to an array. EXIT"
        return 0
    }
}

function PromptForOrganization([string] $whichOne) {
    $i = 0
    while ($i -lt 3) {
        $i++
        $answer = Read-Host -Prompt "Enter the url for the $whichOne Azure DevOps Organization/Collection (ex. https://dev.azure.com/myOrg39/)"
        try {
            # 20 is a made up minimum to ensure a valid PAT was entered since they are fairly long
            if ($answer.Length -ge 20) {
                return $answer
                Write-Verbose "$whichOne Url: $answer"
            }
        }
        catch {
            Write-Warning "Invalid since the value entered was less than 20 characters. Please provide a valid PAT."
        }
    }

    Write-Warning "You entered an invalid Azure DevOps Organization/Collection three times."
    throw "Invalid $whichOne Organization/Collection"
}

function PromptForPAT([string] $whichOne) {
    $i = 0
    while ($i -lt 3) {
        $i++
        $answer = Read-Host -Prompt "Enter the Personal Access Token (PAT) for $whichOne (ex. 82ejnd73nsdjf7emsdnfkj)"
        try {
            # 20 is a made up minimum to ensure a valid PAT was entered since they are fairly long
            if ($answer.Length -ge 20) {
                Write-Verbose "$whichOne PAT: $answer"
                return $answer
            }
        }
        catch {
            Write-Warning "Invalid since the value entered was less than 20 characters. Please provide a valid PAT."
        }
    }

    Write-Warning "You entered an invalid Personal Access Token three times."
    throw "Invalid $whichOne Personal Access Token"
}

function PromptIfMigrateProject([string] $projectName) {
    $i = 0
    while ($i -lt 3) {
        $i++
        $answer = Read-Host -Prompt "Should $projectName be migrated (y/n)?"
        if ($answer.Equals('y')) { 
            Write-Verbose "Migrate $($projectName): $answer"
            return $true 
        }
        elseif ($answer.Equals('n')) { 
            Write-Verbose "Migrate $($projectName): $answer"
            return $false
        }
        else {
            Write-Warning "Invalid response. Please enter 'y' or 'no'."
        }
    }

    Write-Warning "You entered an invalid Azure DevOps Organization/Collection three times."
    throw "Invalid $whichOne Organization/Collection"
}

function UpdateConfigFile([string] $templateFile, [string] $destFile, [int]$min, [int]$max) {
    Write-Verbose "Update config file $destFile"
    Copy-Item $templateFile $destFile
    (Get-Content $destFile).Replace("___sourceCollection___", $sourceOrg) | Set-Content $destFile
    (Get-Content $destFile).Replace("___sourceProject___", $sourceProject) | Set-Content $destFile
    (Get-Content $destFile).Replace("___sourcePAT___", $sourcePAT) | Set-Content $destFile

    (Get-Content $destFile).Replace("___targetCollection___", $targetOrg) | Set-Content $destFile
    (Get-Content $destFile).Replace("___targetProject___", $targetProject) | Set-Content $destFile
    (Get-Content $destFile).Replace("___targetPAT___", $targetPAT) | Set-Content $destFile

    (Get-Content $destFile).Replace("___i___", $min) | Set-Content $destFile
    (Get-Content $destFile).Replace("___iAndBatchSize___", $max) | Set-Content $destFile
    Write-Verbose "$destFile config file updated"
}

function UpdateRemainingConfigFile([string] $templateFile, [string] $destFile, [int]$min) {
    Write-Verbose "Update Remaining config file $destFile"
    $specialMaxValue = -1

    UpdateConfigFile $templateFile $destFile $min $specialMaxValue
    (Get-Content $destFile).Replace("AND [System.ID] < $specialMaxValue AND", "AND") | Set-Content $destFile

    Write-Verbose "$destFile config file updated"
}

function GetListOfProjects([string]$org, [string]$token) {
    Write-Verbose "Query $org for list of projects" 

    try {
        # Create header with PAT
        $encodedToken = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$($token)"))
        $header = @{authorization = "Basic $encodedToken" }

        # Get the list of all projects in the organization
        $projectsUrl = "$org/_apis/projects?api-version=7.0"
        $result = Invoke-RestMethod -Uri $projectsUrl -Method Get -ContentType "application/json" -Headers $header

        if ($verbose) {
            foreach ($tmpProject in $result.value) {
                Write-Verbose "$($tmpProject.id) $($tmpProject.name)"
            }
        }

        Write-Verbose "Done querying for list of projects" 
        return $result
    }
    catch {
        throw "Azure DevOps API call failed. $_"
    }
}

function GetProjectDetails([string]$org, [string]$token, [string]$project) {
    Write-Verbose "Get details for project `"$project`" in $org" 

    try {
        # Create header with PAT
        $encodedToken = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$($token)"))
        $header = @{authorization = "Basic $encodedToken" }

        # Get project details
        $projectUrl = "$org/_apis/projects/" + [uri]::EscapeDataString($project) + "?api-version=7.0"
        $result = Invoke-RestMethod -Uri $projectUrl -Method Get -ContentType "application/json" -Headers $header

        Write-Verbose "Done getting project details"
        return $result
    }
    catch {
        throw "Azure DevOps API call failed. $_"
    }
}

function GetListOfRepos([string]$org, [string]$token, [string]$project) {
    Write-Verbose "Query $org for list of repositories for project $project" 

    try {
        # Create header with PAT
        $encodedToken = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$($token)"))
        $header = @{authorization = "Basic $encodedToken" }

        # Get the list of all repos in the project
        $reposUrl = "$org/" + [uri]::EscapeDataString($project) + "/_apis/git/repositories?api-version=7.0"
        $result = Invoke-RestMethod -Uri $reposUrl -Method Get -ContentType "application/json" -Headers $header

        if ($verbose) {
            foreach ($tmpRepo in $result.value) {
                Write-Verbose "$($tmpRepo.id) $($tmpRepo.name)"
            }
        }

        Write-Verbose "Done querying for list of repositories" 
        return $result
    }
    catch {
        throw "Azure DevOps API call failed. $_"
    }
}

function CreateRepo([string]$org, [string]$token, [string]$project, [string]$repo) {
    Write-Verbose "Create repo `"$repo`" in project `"$project`" in $org" 

    try {
        # Create header with PAT
        $encodedToken = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$($token)"))
        $header = @{authorization = "Basic $encodedToken" }

        $repoJson = @{name = "$($repo)" } | ConvertTo-Json

        # Create repo
        $repoUrl = "$org/" + [uri]::EscapeDataString($project) + "/_apis/git/repositories?api-version=7.0"
        $result = Invoke-RestMethod -Uri $repoUrl -Method Post -ContentType "application/json" -Headers $header -Body ($repoJson)

        Write-Verbose "Done creating repository" 
        return $result
    }
    catch {
        throw "Azure DevOps API call failed. $_"
    }
}

function GetRepoDetails([string]$org, [string]$token, [string]$project, [string]$repo) {
    Write-Verbose "Get details for repo `"$repo`" in project `"$project`" in $org" 

    try {
        # Create header with PAT
        $encodedToken = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$($token)"))
        $header = @{authorization = "Basic $encodedToken" }

        # Get repo details
        $repoUrl = "$org/" + [uri]::EscapeDataString($project) + "/_apis/git/repositories/" + [uri]::EscapeDataString($repo) + "?api-version=7.0"
        $result = Invoke-RestMethod -Uri $repoUrl -Method Get -ContentType "application/json" -Headers $header

        Write-Verbose "Done getting repository details" 
        return $result
    }
    catch {
        throw "Azure DevOps API call failed. $_"
    }
}

function QueryResultCount([string]$org, [string]$token, [string]$project, [int]$min) {
    Write-Verbose "Run query to determine if there are any results in project `"$project`" in $org" 

    try {
        # Create header with PAT
        $encodedToken = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$($token)"))
        $header = @{authorization = "Basic $encodedToken" }

        $wiqlJson = @{
            query = "Select [System.Id] From WorkItems Where [System.ID] >= $min AND [System.ID] < $($min + $workItemBatchSize) AND [System.WorkItemType] NOT IN ('Test Suite', 'Test Plan','Shared Steps','Shared Parameter','Feedback Request')"
        } | ConvertTo-Json

        # Run query
        $wiqlUrl = "$org/" + [uri]::EscapeDataString($project) + "/_apis/wit/wiql?api-version=7.0"
        $result = Invoke-RestMethod -Uri $wiqlUrl -Method Post -ContentType "application/json" -Headers $header -Body ($wiqlJson)

        Write-Verbose "Done running query" 
        return $result.workItems.Length
    }
    catch {
        throw "Azure DevOps API call failed. $_"
    }
}

function QueryRemainingResultCount([string]$org, [string]$token, [string]$project, [int]$min) {
    Write-Verbose "Run remaining query to determine if there are any results in project `"$project`" in $org" 

    try {
        # Create header with PAT
        $encodedToken = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$($token)"))
        $header = @{authorization = "Basic $encodedToken" }

        $wiqlJson = @{
            query = "Select [System.Id] From WorkItems Where [System.ID] >= $min AND [System.WorkItemType] NOT IN ('Test Suite', 'Test Plan','Shared Steps','Shared Parameter','Feedback Request')"
        } | ConvertTo-Json

        # Run query
        $wiqlUrl = "$org/" + [uri]::EscapeDataString($project) + "/_apis/wit/wiql?api-version=7.0"
        $result = Invoke-RestMethod -Uri $wiqlUrl -Method Post -ContentType "application/json" -Headers $header -Body ($wiqlJson)

        Write-Verbose "Done running remaining query" 
        return $result.workItems.Length
    }
    catch {
        throw "Azure DevOps API call failed. $_"
    }
}

function Invoke-Process([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$FilePath, 
    [Parameter()][ValidateNotNullOrEmpty()][string]$ArgumentList) {
    Write-Verbose "Invoke process `"$FilePath`" with arguments `"$ArgumentList`"" 
    $ErrorActionPreference = 'Stop'

    try {
        $stdOutTempFile = "$env:TEMP\$((New-Guid).Guid)"
        Write-Verbose "stdOutTempFile: $stdOutTempFile"
        $stdErrTempFile = "$env:TEMP\$((New-Guid).Guid)"
        Write-Verbose "stdErrTempFile: $stdErrTempFile"

        $startProcessParams = @{
            FilePath               = $FilePath
            ArgumentList           = $ArgumentList
            RedirectStandardError  = $stdErrTempFile
            RedirectStandardOutput = $stdOutTempFile
            Wait                   = $true;
            PassThru               = $true;
            NoNewWindow            = $true;
        }
        
        Write-Verbose "Start process"
        $cmd = Start-Process @startProcessParams
        Write-Verbose "Process done"

        $cmdOutput = Get-Content -Path $stdOutTempFile -Raw
        $cmdError = Get-Content -Path $stdErrTempFile -Raw
        if ($cmd.ExitCode -ne 0) {
            if ($cmdError) {
                throw $cmdError.Trim()
            }
            if ($cmdOutput) {
                throw $cmdOutput.Trim()
            }
        }
        else {
            if ($verbose) {
                if ([string]::IsNullOrEmpty($cmdOutput) -eq $false) {
                    Write-Output $cmdOutput
                }
                if ([string]::IsNullOrEmpty($cmdError) -eq $false) {
                    Write-Output $cmdError
                }
            }
        }

        Write-Verbose "Done invoking process"
    }
    catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
    finally {
        Remove-Item -Path $stdOutTempFile, $stdErrTempFile -Force -ErrorAction Ignore
    }
}

function InstallDependencies([string] $whichOne) {
    $alreadyInstalled = $true
    Write-Verbose "Install dependencies"

    # Install Chocolatey if not installed
    if (! (test-path -PathType container "C:\ProgramData\chocolatey\bin")) {
        $alreadyInstalled = $false
        Write-Verbose "Install Chocolately"
        Set-ExecutionPolicy Bypass -Scope Process -Force; iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
        if (! (test-path -PathType container "C:\ProgramData\chocolatey\bin")) {
            Write-Warning "Chocolatey still not installed."
            throw "Chocolatey not installed"
        }
    }
    Write-Verbose "Chocolately Installed"

    # Install vsts-sync-migrator if not installed
    if (! (test-path -PathType container "c:\tools\MigrationTools\")) {
        $alreadyInstalled = $false
        Write-Verbose "Install vsts-sync-migrator"
        choco install -y vsts-sync-migrator
        if (! (test-path -PathType container "c:\tools\MigrationTools\")) {
            Write-Warning "vsts-sync-migrator still not installed."
            throw "vsts-sync-migrator not installed"
        }
    }
    Write-Verbose "vsts-sync-migrator Installed"

    # Install git if not installed
    if (! (test-path -PathType container "C:\Program Files\Git\cmd\")) {
        $alreadyInstalled = $false
        Write-Verbose "Install git"
        choco install -y git
        if (! (test-path -PathType container "C:\Program Files\Git\cmd\")) {
            Write-Warning "git still not installeds"
            throw "git not installed"
        }
    }
    Write-Verbose "git Installed"

    Write-Verbose "Dependencies Installed"
    return $alreadyInstalled
}


#####################################
# MAIN
#####################################
$originalEnvAzureDevOpsExtPAT = $env:AZURE_DEVOPS_EXT_PAT

try {
    # Verify valid template folder
    if (! (test-path -PathType container "$templatePath")) {
        Write-Error "Template folder does not exist and is required. Folder = $templatePath."
        throw "Template folder does not exist and is required. Folder = $templatePath."
    }

    try {
        $alreadyInstalled = InstallDependencies
        # if (! $alreadyInstalled) {
        #     Write-Warning "Dependencies had to be installed. You must close and open a new Powershell and run the script again. Exit"
        #     return 1
        # }
    }
    catch {
        throw "Failed to install dependencies. Error: $_"
    }

    try {
        # Prompt for our Org and PAT values, if not supplied
        if ([string]::IsNullOrWhiteSpace($sourceOrg)) {
            $sourceOrg = (PromptForOrganization "Source")
        }
        if ([string]::IsNullOrWhiteSpace($sourcePAT)) {
            $sourcePAT = (PromptForPAT "$sourceOrg")
        }

        if ([string]::IsNullOrWhiteSpace($targetOrg)) {
            $targetOrg = (PromptForOrganization "Target")
        }
        if ([string]::IsNullOrWhiteSpace($targetPAT)) {
            $targetPAT = (PromptForPAT "$targetOrg")
        }
    }
    catch {
        throw "Failed to provide valid variable values. Error: $_"
    }

    try {
        # Verify Source and Target urls and personal access tokens
        Write-Verbose "Verify Source and Target urls and personal access tokens by logging into both."
        # LoginAzureDevOps "Target" $targetOrg $targetPAT
        # LoginAzureDevOps "Source" $sourceOrg $sourcePAT
    }
    catch {
        throw "Failed to connect to Azure DevOps. Error: $_"
    }

    if ($onlyProjectList) {
        Write-Verbose "Retrieve project list and exit" 
        $projectList = (GetListOfProjects $sourceOrg $sourcePAT)
        $strProjectList = "`$projects = @(`n"
        foreach ($project in $projectList.value) {
            $strProjectList += "`t[pscustomobject]@{source = `"$($project.name)`"; target = `"`" },`n"
        }
        $strProjectList += ")"
        $strProjectList = $strProjectList.Replace("},`n)", "}`n)")
        Write-Host $strProjectList
    }
    else {
        try {
            # Make sure we are logged into the Source before proceeding
            # LoginAzureDevOps "Source" $sourceOrg $sourcePAT
        }
        catch {
            throw "Failed to connect to Azure DevOps. Error: $_"
        }

        if ($projectsArray.count -le 0) {
            Write-Host "Project List is empty. Query source for list of projects and prompt if each project should be migrated" 
            $projectList = (GetListOfProjects $sourceOrg $sourcePAT)
            foreach ($project in $projectList.value) {
                Write-Verbose "Project: `"$($project.name)`""
                if (PromptIfMigrateProject $project.name) {
                    Write-Verbose "Migrate `"$($project.name)`""
                    $obj = New-Object psobject
                    $obj | Add-Member -type NoteProperty -name "source" -Value "$($project.name)"
                    $obj | Add-Member -type NoteProperty -name "target" -Value ""
                    $projectsArray += $obj
                }
            }
        }

        if ($verbose) {
            Write-Verbose "There are $($projectsArray.count) projects to migrate. Show list:"
            foreach ($p in $projectsArray) {
                Write-Verbose "`"$($p.source)`""
            }
            Write-Verbose "Done showing list of projects to migrate"
        }

        # Verify project exists in both Source and Target
        # Do this before the main loop so we find errors before the real work begins
        $success = $true
        foreach ($project in $projectsArray) {
            $sourceProject = $project.source
            if ([string]::IsNullOrWhiteSpace($project.target)) {
                # default to be the same as the source project name
                Write-Verbose "Target project defaulting to the same name as source for project `"$sourceProject`""
                $targetProject = $project.source
            }
            else {
                $targetProject = $project.target
            }
            try {
                Write-Verbose "Verify `"$sourceProject`" in Source"
                GetProjectDetails $sourceOrg $sourcePAT $sourceProject | Out-Null
                Write-Verbose "`"$sourceProject`" does exist in Source"
            }
            catch {
                $success = $false 
                Write-Warning "`"$sourceProject`" does not exist in $sourceOrg"
            }
            try {
                Write-Verbose "Verify `"$targetProject`" in Target"
                GetProjectDetails $targetOrg $targetPAT $targetProject | Out-Null
                Write-Verbose "`"$targetProject`" does exist in Target"
            }
            catch { 
                $success = $false 
                Write-Warning "`"$targetProject`" does not exist in $targetOrg"
            }
        }
        if (! $success) {
            Write-Verbose "One or more projects does not exist in both Source and Target."
            throw "One or more projects does not exist in both Source and Target."
        }
        else {
            Write-Verbose "All projects exist in both Source and Target"
        }

        # Do the migrations
        pushd "c:\tools\MigrationTools\"
        foreach ($project in $projectsArray) {
            # NOTE: ALWAYS migrate code first before migrating work items so the links are fixed.
            $sourceProject = $project.source
            if ([string]::IsNullOrWhiteSpace($project.target)) {
                # default to be the same as the source project name
                Write-Verbose "Target project defaulting to the same name as source for project `"$sourceProject`""
                $targetProject = $project.source
            }
            else {
                $targetProject = $project.target
            }
            write-host "*** PROJECT: `"$sourceProject`""

            if ($migrateRepos) {
                if (Test-Path $sourceProject) {
                    Remove-Item "$sourceProject" -Recurse -Force
                }
                mkdir "$sourceProject" | Out-Null
                pushd "$sourceProject"
                # Migrate git repos
                $repos = (GetListOfRepos $sourceOrg $sourcePAT $sourceProject)
                Write-Verbose "There are $($repos.value.count) repos for `"$sourceProject`""
                foreach ($repo in $repos.value) {
                    $repoName = $repo.name
                    write-host "Migrate repo: `"$repoName`""
                
                    # Login to source org
                    # LoginAzureDevOps "Source" $sourceOrg $sourcePAT

                    Write-Verbose "git clone: `"$repoName`""
                    try {
                        Invoke-Process -FilePath "C:\Program Files\Git\cmd\git.exe" -ArgumentList "clone --bare --mirror --progress --verbose $($repo.remoteUrl) `"$repoName`"" | Tee-Object -Variable result
                    }
                    catch {
                        $ex = $_
                        write-host $result
                        write-error $ex
                        Read-Host "Press ENTER to continue or Ctrl-C to break"
                    }

                    if (! (test-path -PathType container (Join-Path -Path $pwd -ChildPath "$repoName"))) {
                        Write-Error "Folder `"$repoName`" does not exist so clone failed."
                        Read-Host -Prompt "Press ENTER to continue after fatal error."
                    }
                    Write-Verbose "Done git clone `"$repoName`""

                    pushd "$repoName"

                    # Login to target org
                    # LoginAzureDevOps "Target" $targetOrg $targetPAT

                    Write-Verbose "Create target repo: `"$repoName`""
                    if ($originalWhatIfPreference -eq $false) {
                        $newRepoInfo = (CreateRepo $targetOrg $targetPAT $targetProject $repoName)
                    }
                    else {
                        Write-Verbose "Test Only: Mock creating repo `"$repoName`" in Target"
                    }
                    Write-Verbose "Done creating target repo: `"$repoName`""

                    Write-Verbose "git push: `"$repoName`""
                    if ($originalWhatIfPreference -eq $false) {
                        try {
                            Invoke-Process -FilePath "C:\Program Files\Git\cmd\git.exe" -ArgumentList "push --mirror --progress --verbose $($newRepoInfo.remoteUrl)" | Tee-Object -Variable result
                        }
                        catch {
                            $ex = $_
                            write-host $result
                            write-error $ex
                            Read-Host "Press ENTER to continue or Ctrl-C to break"
                        }

                        # Verify
                        Start-Sleep 1 # allow DevOps to recognize the git push
                        $newRepoDetails = (GetRepoDetails $targetOrg $targetPAT $targetProject $repoName)
                        if ($newRepoDetails.size -ne $repo.size) {
                            Write-Warning "Size difference between original and new repo `"$repoName`". Source size = $($repo.size) and Target size = $($newRepoDetails.size)"
                            Read-Host "Press ENTER to continue or Ctrl-C to break"
                        }
                    }
                    else {
                        Write-Verbose "Test Only: Mock git push"
                    }
                    Write-Verbose "Done git push: `"$repoName`""
                    popd # $repoName

                    Remove-Item -Recurse -Force "$repoName"
                    Write-Verbose "Done migrate repo: `"$repoName`""
                }

                popd # $sourceProject
                Remove-Item -Recurse -Force "$sourceProject"
                Write-Verbose "Done migratating repos for `"$sourceProject`""
            }
            else {
                Write-Verbose "Skipping repository migrations"
            }

            if ($migrateWorkItems) {
                if (Test-Path $sourceProject) {
                    Remove-Item "$sourceProject" -Recurse -Force
                }
                mkdir "$sourceProject" | Out-Null
                pushd "$sourceProject"

                Write-Host "Migrate work items for `"$sourceProject`""
                $templateFile = join-path -path $templatePath -childpath "migrateWorkItemsTemplate.json"
                $success = $false
                for ($i = 0; $i -le 100000; $i = $i + $workItemBatchSize) {
                    $count = (QueryResultCount $sourceOrg $sourcePAT $sourceProject $i)
                    write-verbose "There are $count work items for batch $i"
                    if ($count -gt 0) {
                        $destFile = (join-path -path $pwd -ChildPath "migrateWorkItems$($i).json")
                        UpdateConfigFile $templateFile $destFile $i $($i + $workItemBatchSize)
                        UpdateRemainingConfigFile $templateFile (join-path -path $pwd -ChildPath "migrateWorkItemsRemaining.json") $($i + $workItemBatchSize)
                        if ($originalWhatIfPreference -eq $false) {
                            Write-Verbose "Migrate work items using $destFile"
                            c:\tools\MigrationTools\migration.exe execute --config $destFile 2>&1 | Tee-Object -Variable result
                            # $LastExitCode
                            if (([string]$result).contains(" FTL]") -or ([string]$result).contains(" ERR]")) { 
                                Write-Error "ERROR while running migration for $destFile"
                                Read-Host "Press ENTER to continue or Ctrl-C to stop."
                            }
                        }
                        else {
                            Write-Verbose "Test Only: Mock migrate work items using $destFile" #TODO: mimic migrate work items
                        }
                    }
                    else { 
                        Write-Verbose "Check remaining count"
                        $remainingCount = (QueryRemainingResultCount $sourceOrg $sourcePAT $sourceProject $i)
                        Write-Verbose "There are $remainingCount work items for remaining batch"
                        if ($remainingCount -lt 10000) {
                            $success = $true
                            break
                        }
                        else {
                            # 10,000 is the max number of items returned by DevOps API
                            Write-Verbose "There are still more than 10,000 work items in the remaining query so continue with batches"
                        }
                    }
                }
                if (! $success) {
                    Write-Warning "Failed to migrate all work items due to max loops"
                    Read-Host "Press ENTER to continue or Ctrl-C to stop."
                }

                Write-Verbose "Import Remaining Work Items"
                Write-Verbose "Migrate work items using $(join-path -path $pwd -ChildPath migrateWorkItemsRemaining.json)"
                if ($originalWhatIfPreference -eq $false) {
                    c:\tools\MigrationTools\migration.exe execute --config (join-path -path $pwd -ChildPath "migrateWorkItemsRemaining.json") 2>&1 | Tee-Object -Variable result
                    if (([string]$result).contains(" FTL]") -or ([string]$result).contains(" ERR]")) { 
                        Write-Error "ERROR while running migration for $destFile"
                        Read-Host "Press ENTER to continue or Ctrl-C to stop."
                    }
                }
                else {
                    Write-Verbose "Test Only: Mock migrate work items using $(join-path -path $pwd -ChildPath migrateWorkItemsRemaining.json)" #TODO: mimic migrate work items
                }

                # TODO: Verify
                Write-Verbose "Done migratating work items for `"$sourceProject`""

                Write-Host "Migrate test plans for `"$sourceProject`""
                $templateFile = join-path -path $templatePath -childpath "migrateTestPlansTemplate.json"
                $destFile = (join-path -path $pwd -ChildPath "migrateTestPlans.json")
                UpdateConfigFile $templateFile $destFile 0

                if ($originalWhatIfPreference -eq $false) {
                    Write-Verbose "Migrate test plans using $destFile"
                    c:\tools\MigrationTools\migration.exe execute --config $destFile 2>&1 | Tee-Object -Variable result
                    if (([string]$result).contains(" FTL]") -or ([string]$result).contains(" ERR]")) { 
                        Write-Error "ERROR while running migration for $destFile"
                        Read-Host "Press ENTER to continue or Ctrl-C to stop."
                    }
                }
                else {
                    Write-Verbose "Test Only: Mock migrate test plans using $destFile" #TODO: mimic migrate test plans
                }
                # TODO: Verify
                Write-Verbose "Done migratating test plans for `"$sourceProject`""

                Write-Host "Migrate pipelines for `"$sourceProject`""
                $templateFile = join-path -path $templatePath -childpath "migratePipelinesTemplate.json"
                $destFile = (join-path -path $pwd -ChildPath "migratePipelines.json")
                UpdateConfigFile $templateFile $destFile 0

                if ($originalWhatIfPreference -eq $false) {
                    Write-Verbose "Migrate pipelines using $destFile"
                    c:\tools\MigrationTools\migration.exe execute --config $destFile 2>&1 | Tee-Object -Variable result
                    if (([string]$result).contains(" FTL]") -or ([string]$result).contains(" ERR]")) { 
                        Write-Error "ERROR while running migration for $destFile"
                        Read-Host "Press ENTER to continue or Ctrl-C to stop."
                    }
                }
                else {
                    Write-Verbose "Test Only: Mock migrate pipelines using $destFile" #TODO: mimic migrate pipelines
                }
                # TODO: Verify
                Write-Verbose "Done migratating pipelines for `"$sourceProject`""

                popd # $sourceProject
                Remove-Item -Recurse -Force "$sourceProject"
            }
            else {
                Write-Verbose "Skipping work item migrations"
            }
        
            write-host "Done migratating `"$sourceProject`""
        }

        popd # c:\tools\MigrationTools\

        Write-Host ""
        Write-Host "TO-DO:"
        Write-Host "`t1. Delete Personal Access Tokens. Git creates a PAT for Source and Target as well"
        Write-Host "`t2. Delete the _default_ git repo if it's not needed (when each project was created on Target)"
    }
}
catch {
    Write-Error "Failed with error: $_"
    return 0
}
finally {
    $env:AZURE_DEVOPS_EXT_PAT = $originalEnvAzureDevOpsExtPAT
    $WhatIfPreference = $originalWhatIfPreference
    $VerbosePreference = $originalVerbose
}
