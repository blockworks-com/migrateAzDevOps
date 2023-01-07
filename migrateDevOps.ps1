param([string]$sourceOrg, [string]$sourcePAT, 
    [string]$targetOrg, [string]$targetPAT, 
    [switch]$getProjectList = $false, [switch]$verbose = $false, [switch]$test = $false)

#####################################
# Variables
#####################################
# MUST CHANGE
# If blank, user will be prompt for each project in Source
$projects = @(
    # [pscustomobject]@{source = "source2-agile"; target = "" }
)

# Can leave as defaults
$workItemBatchSize = 5000
$templatePath = "$pwd"

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
            write-host -ForegroundColor Yellow "Invalid since the value entered was less than 20 characters. Please provide a valid PAT."
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
            write-host -ForegroundColor Yellow "Invalid since the value entered was less than 20 characters. Please provide a valid PAT."
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
            Write-Host -ForegroundColor Yellow "Invalid response. Please enter 'y' or 'no'."
        }
    }

    Write-Warning "You entered an invalid Azure DevOps Organization/Collection three times."
    throw "Invalid $whichOne Organization/Collection"
}

function UpdateConfigFile([string] $templateFile, [string] $destFile) {
    Write-Verbose "Update config file $destFile"
    Copy-Item $templateFile $destFile
    (Get-Content $destFile).Replace("___sourceCollection___", $sourceOrg) | Set-Content $destFile
    (Get-Content $destFile).Replace("___sourceProject___", $sourceProject) | Set-Content $destFile
    (Get-Content $destFile).Replace("___sourcePAT___", $sourcePAT) | Set-Content $destFile

    (Get-Content $destFile).Replace("___targetCollection___", $targetOrg) | Set-Content $destFile
    (Get-Content $destFile).Replace("___targetProject___", $targetProject) | Set-Content $destFile
    (Get-Content $destFile).Replace("___targetPAT___", $targetPAT) | Set-Content $destFile

    (Get-Content $destFile).Replace("___i___", $i) | Set-Content $destFile
    (Get-Content $destFile).Replace("___iAndBatchSize___", $($i + $workItemBatchSize)) | Set-Content $destFile
    Write-Verbose "$destFile config file updated"
}

function LoginAzureDevOps([string]$whichOne, [string]$org, [string]$token) {
    # Clear credential for all organizations
    Write-Verbose "Clear Azure DevOps credentials"
    cmd /c C:\"Program Files (x86)\Microsoft SDKs"\Azure\CLI2\wbin\az devops logout 2>&1 | Out-Null

    # Log in specific organization with token
    Write-Verbose "Log into $whichOne Azure DevOps"
    # $env:AZURE_DEVOPS_EXT_PAT = $token
    echo $token | cmd /c C:\"Program Files (x86)\Microsoft SDKs"\Azure\CLI2\wbin\az devops login --organization=$org

    # Verify connected
    Write-Verbose "Verify login to $whichOne by checking if projects are found."
    $projectList = $(cmd /c C:\"""Program Files (x86)\Microsoft SDKs"""\Azure\CLI2\wbin\az devops project list --organization=$org)
    if ([string]::IsNullOrWhiteSpace($projectList)) {
        Write-Warning "Project list is empty for $org"
        throw "Failed to connect to $whichOne because project list is empty for $org"
    }
    Write-Verbose "Successful, projects found."
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
        foreach ($tmpProject in $result.value) {
            Write-Verbose "$($tmpProject.id) $($tmpProject.name)"
        }

        Write-Verbose "Done querying for list of projects" 
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
        foreach ($tmpRepo in $result.value) {
            Write-Verbose "$($tmpRepo.id) $($tmpRepo.name)"
        }

        Write-Verbose "Done querying for list of repositories" 
        return $result
    }
    catch {
        throw "Azure DevOps API call failed. $_"
    }
}

function InstallDependencies([string] $whichOne) {
    Write-Verbose "Install dependencies"
    # Install Chocolatey if not installed
    if (! (test-path -PathType container "C:\ProgramData\chocolatey\bin")) {
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
        Write-Verbose "Install git"
        choco install -y git
        if (! (test-path -PathType container "C:\Program Files\Git\cmd\")) {
            Write-Warning "git still not installeds"
            throw "git not installed"
        }
    }
    Write-Verbose "git Installed"

    # Install azure cli if not installed
    if (! (test-path -PathType container "C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\wbin\")) {
        Write-Verbose "Install azure-cli"
        choco install -y azure-cli
        Write-Verbose "Install azure-devopos extension"
        C:\"Program Files (x86)\Microsoft SDKs"\Azure\CLI2\wbin\az extension add --name azure-devops
        if (! (test-path -PathType container "C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\wbin\")) {
            Write-Warning "azure-cli still not installed."
            throw "azure-cli not installed"
        }
    }
    Write-Verbose "azure-cli and devops extension Installed"
    Write-Verbose "Dependencies Installed"
}


#####################################
# MAIN
#####################################
$originalEnvAzureDevOpsExtPAT = $env:AZURE_DEVOPS_EXT_PAT
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
[bool]$onlyTest = $false
switch ($test) {    
    $true {
        $onlyTest = $true
        Write-Verbose "Test only without migrating"
    }    
}

try {
    # Verify valid template folder
    if (! (test-path -PathType container "$templatePath")) {
        Write-Error "Template folder does not exist and is required. Folder = $templatePath."
        throw "Template folder does not exist and is required. Folder = $templatePath."
    }

    try {
        InstallDependencies
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
        LoginAzureDevOps "Target" $targetOrg $targetPAT
        LoginAzureDevOps "Source" $sourceOrg $sourcePAT
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
            LoginAzureDevOps "Source" $sourceOrg $sourcePAT
        }
        catch {
            throw "Failed to connect to Azure DevOps. Error: $_"
        }

        if ($projects.count -le 0) {
            Write-Host "Project List is empty. Query source for list of projects and prompt if each project should be migrated" 
            $projectList = (GetListOfProjects $sourceOrg $sourcePAT)
            foreach ($project in $projectList.value) {
                Write-Verbose "Project: `"$($project.name)`""
                if (PromptIfMigrateProject $project.name) {
                    Write-Verbose "Migrate `"$($project.name)`""
                    $obj = New-Object psobject
                    $obj | Add-Member -type NoteProperty -name "source" -Value "$($project.name)"
                    $obj | Add-Member -type NoteProperty -name "target" -Value ""
                    $projects += $obj
                }
            }
        }

        Write-Verbose "There are $($projects.count) projects to migrate. Show list:"
        foreach ($p in $projects) {
            Write-Verbose "`"$p.source`""
        }
        Write-Verbose "Done showing list of projects to migrate"

        # Do the migrations
        pushd "c:\tools\MigrationTools\"
        foreach ($project in $projects) {
            # NOTE: ALWAYS migrate code first before migrating work items so the links are fixed.
            $sourceProject = $project.source
            if ([string]::IsNullOrWhiteSpace($targetProject)) {
                # default to be the same as the source project name
                Write-Verbose "Target project defaulting to the same name as source for project `"$sourceProject`""
                $targetProject = $project.source
            }
            else {
                $targetProject = $project.target
            }
            write-host "*** PROJECT: `"$sourceProject`""

            if (Test-Path $sourceProject) {
                Remove-Item "$sourceProject" -Recurse -Force
            }
            mkdir "$sourceProject" | Out-Null
            pushd "$sourceProject"
            # Migrate git repos
            # write-host "Step 1: Start migratating repos for `"$sourceProject`""
            # $repos = $(cmd /c C:\"""Program Files (x86)\Microsoft SDKs"""\Azure\CLI2\wbin\az repos list --organization=$sourceOrg --project="""$sourceProject""" | ConvertFrom-Json)
            $repos = (GetListOfRepos $sourceOrg $sourcePAT $sourceProject)
            Write-Verbose "There are $($repos.value.count) repos for `"$sourceProject`""
            foreach ($repo in $repos.value) {
                $repoName = $repo.name
                write-host "Migrate repo: `"$repoName`""
                
                # Login to source org
                LoginAzureDevOps "Source" $sourceOrg $sourcePAT

                Write-Verbose "git clone: `"$repoName`""
                C:\"Program Files"\Git\cmd\git clone --bare --mirror $repo.remoteUrl $repoName
                if (! (test-path -PathType container (Join-Path -Path $pwd -ChildPath "$repoName"))) {
                    Write-Error "Folder `"$repoName`" does not exist so clone failed."
                    Read-Host -Prompt "Press ENTER to continue after fatal error."
                }
                Write-Verbose "Done git clone `"$repoName`""

                pushd "$repoName"

                # Login to target org
                LoginAzureDevOps "Target" $targetOrg $targetPAT

                Write-Verbose "az create target repo: `"$repoName`""
                if ($onlyTest -eq $false) {
                    $newRepoInfo = $(cmd /c C:\"""Program Files (x86)\Microsoft SDKs"""\Azure\CLI2\wbin\az repos create --name="""$repoName""" --organization=$targetOrg --project=$targetProject | ConvertFrom-Json)
                    # TODO: Verify
                }
                else {
                    write-host "Test Only: Mock creating repo `"$repoName`" in Target" #TODO: mimic the creation 
                }
                Write-Verbose "Done az create target repo: `"$repoName`""
                # Write-Verbose "new remote url: "$newRepoInfo.remoteUrl

                Write-Verbose "git push: `"$repoName`""
                if ($onlyTest -eq $false) {
                    C:\"Program Files"\Git\cmd\git push --mirror $newRepoInfo.remoteUrl
                    # TODO: Verify
                }
                else {
                    write-host "Test Only: Mock git push" #TODO: mimic git push
                }
                Write-Verbose "Done git push: `"$repoName`""
                popd # $repoName

                Remove-Item -Recurse -Force "$repoName"
                Write-Verbose "Done migrate repo: `"$repoName`""
            }
            # Verify the repos were created 
            # Login to target org
            LoginAzureDevOps "Target" $targetOrg $targetPAT
            $targetRepos = $(cmd /c C:\"""Program Files (x86)\Microsoft SDKs"""\Azure\CLI2\wbin\az repos list --organization=$targetOrg --project="""$targetProject""" | ConvertFrom-Json)
            foreach ($repo in $repos) {
                #TODO: $matches = $repo.name | Where-Object { $targetRepos.Name -eq $_ }
            }

            # Logout since we're now done with the az commands
            cmd /c C:\"Program Files (x86)\Microsoft SDKs"\Azure\CLI2\wbin\az devops logout 2>&1 | Out-Null
            Write-Verbose "Done migratating repos for `"$sourceProject`""

            Write-Verbose "Migratate work items for `"$sourceProject`""
            $templateFile = join-path -path $templatePath -childpath "migrateWorkItemsTemplate.json"
            for ($i = 0; $i -le 100000; $i = $i + $workItemBatchSize) {
                # $count = $(cmd /c C:\"""Program Files (x86)\Microsoft SDKs"""\Azure\CLI2\wbin\az boards query --wiql="select id from workitems where [System.ID] >= $($i) AND [System.WorkItemType] NOT IN ('Test Suite', 'Test Plan','Shared Steps','Shared Parameter','Feedback Request')" --organization=https://dev.azure.com/tmp-blockworkscom/ --project=source2 | ConvertFrom-Json).count
                $count = 1 # TODO: figure out how many work items there are in total to avoid running so many times
                if ($count -gt 0) {
                    $destFile = (join-path -path $pwd -ChildPath "migrateWorkItems$($i).json")
                    UpdateConfigFile $templateFile $destFile
                    UpdateConfigFile $templateFile ".\migrateWorkItemsRemaining.json"
                    if ($onlyTest -eq $false) {
                        Write-Verbose "Migrate work items using $destFile"
                        c:\tools\MigrationTools\migration.exe execute --config $destFile 2>&1 | Tee-Object -Variable result
                        if ($? -ne $true) { 
                            Write-Error "ERROR found step 191!!! Exit"
                            Read-Host "Press ENTER to continue or Ctrl-C to stop."
                            #            } else {
                            #                if ($result -like "*0 Work Items*") {
                            #                    break
                            #                }
                        }
                    }
                    else {
                        write-host "Test Only: Mock migrate work items using $destFile" #TODO: mimic migrate work items
                    }
                }
            }
            Write-Verbose "Import Remaining Work Items"
            Write-Verbose "Migrate work items using .\migrateWorkItemsRemaining.json"
            if ($onlyTest -eq $false) {
                c:\tools\MigrationTools\migration.exe execute --config .\migrateWorkItemsRemaining.json 2>&1 | Tee-Object -Variable result
                if ($? -ne $true) { 
                    Write-Error "ERROR found step 204!!! Exit"
                    Read-Host "Press ENTER to continue or Ctrl-C to stop."
                }
            }
            else {
                write-host "Test Only: Mock migrate work items using .\migrateWorkItemsRemaining.json" #TODO: mimic migrate work items
            }

            # TODO: Verify
            Write-Verbose "Done migratating work items for `"$sourceProject`""

            Write-Verbose "Migratate test plans for `"$sourceProject`""
            $templateFile = join-path -path $templatePath -childpath "migrateTestPlansTemplate.json"
            $destFile = (join-path -path $pwd -ChildPath "migrateTestPlans.json")
            UpdateConfigFile $templateFile $destFile

            if ($onlyTest -eq $false) {
                Write-Verbose "Migrate test plans using $destFile"
                c:\tools\MigrationTools\migration.exe execute --config $destFile 2>&1 | Tee-Object -Variable result
                if ($? -ne $true) { 
                    Write-Error "ERROR found step 227!!! Exit"
                    Read-Host "Press ENTER to continue or Ctrl-C to stop."
                }
            }
            else {
                write-host "Test Only: Mock migrate test plans using $destFile" #TODO: mimic migrate test plans
            }
            # TODO: Verify
            Write-Verbose "Done migratating test plans for `"$sourceProject`""

            Write-Verbose "Migratate pipelines for `"$sourceProject`""
            $templateFile = join-path -path $templatePath -childpath "migratePipelinesTemplate.json"
            $destFile = (join-path -path $pwd -ChildPath "migratePipelines.json")
            UpdateConfigFile $templateFile $destFile

            if ($onlyTest -eq $false) {
                Write-Verbose "Migrate pipelines using $destFile"
                c:\tools\MigrationTools\migration.exe execute --config $destFile 2>&1 | Tee-Object -Variable result
                if ($? -ne $true) { 
                    Write-Error "ERROR found step 252!!! Exit"
                    Read-Host "Press ENTER to continue or Ctrl-C to stop."
                }
            }
            else {
                write-host "Test Only: Mock migrate pipelines using $destFile" #TODO: mimic migrate pipelines
            }
            # TODO: Verify
            Write-Verbose "Done migratating pipelines for `"$sourceProject`""

            popd # $sourceProject
            Remove-Item -Recurse -Force "$sourceProject"
            write-host "Done migratating `"$sourceProject`""
        }

        popd # c:\tools\MigrationTools\

        Write-Host "Cleanup:"
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
    $VerbosePreference = $originalVerbose
}
