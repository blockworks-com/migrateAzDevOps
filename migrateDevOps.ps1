param([string]$sourceOrg, [string]$targetOrg, 
    [string]$sourcePAT, [string]$targetPAT, 
    [switch]$verbose = $false)

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
$test = $false
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
    cmd /c C:\"Program Files (x86)\Microsoft SDKs"\Azure\CLI2\wbin\az devops logout | Out-Null

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

    try {
        # Make sure we are logged into the Source before proceeding
        LoginAzureDevOps "Source" $sourceOrg $sourcePAT
    }
    catch {
        throw "Failed to connect to Azure DevOps. Error: $_"
    }

    # Do the migrations
    pushd "c:\tools\MigrationTools\"
    foreach ($project in $projects) {
        # NOTE: ALWAYS migrate code first before migrating work items so the links are fixed.
        $sourceProject = $project.source
        if ([string]::IsNullOrWhiteSpace($targetProject)) {
            # default to be the same as the source project name
            Write-Verbose "Target project defaulting to the same name as source for project $sourceProject."
            $targetProject = $project.source
        }
        else {
            $targetProject = $project.target
        }
        write-host "*** PROJECT: $sourceProject"

        if (Test-Path $sourceProject) {
            Remove-Item $sourceProject -Force
        }
        mkdir $sourceProject | Out-Null
        pushd $sourceProject
        # Migrate git repos
        # write-host "Step 1: Start migratating repos for $sourceProject"
        # $repos = $(cmd /c C:\"""Program Files (x86)\Microsoft SDKs"""\Azure\CLI2\wbin\az repos list --organization=$sourceOrg --project="""$sourceProject""" | ConvertFrom-Json)
        $repos = (GetListOfRepos $sourceOrg $sourcePAT $sourceProject)
        write-host "... there are $($repos.value.count) git repos for $sourceProject"
        foreach ($repo in $repos.value) {
            $repoName = $repo.name
            write-host "Step 1a: Migrate repo: $repoName"

            # Login to source org
            LoginAzureDevOps "Source" $sourceOrg $sourcePAT

            write-host "... git clone: $repoName"
            if ($test -ne $true) {
                C:\"Program Files"\Git\cmd\git clone --bare --mirror $repo.remoteUrl $repoName
            }
            else { mkdir $repoName | Out-Null }
            if (! (test-path -PathType container (Join-Path -Path $pwd -ChildPath "$repoName"))) {
                Write-Error "Folder $repoName does not exist so clone failed."
                Read-Host -Prompt "Press ENTER to continue after fatal error."
            }
            write-host "...Done git clone $repoName"

            pushd $repoName

            # Login to target org
            LoginAzureDevOps "Target" $targetOrg $targetPAT

            write-host "... az create target repo: $repoName"
            if ($test -ne $true) {
                $newRepoInfo = $(cmd /c C:\"""Program Files (x86)\Microsoft SDKs"""\Azure\CLI2\wbin\az repos create --name="""$repoName""" --organization=$targetOrg --project=$targetProject | ConvertFrom-Json)
            }
            else {
                write-host "mimic repo creation" #TODO: mimic the creation 
            }
            # TODO: Verify
            write-host "...Done az create target repo: $repoName"
            # write-host "new remote url: "$newRepoInfo.remoteUrl

            write-host "... git push: $repoName"
            if ($test -ne $true) {
                C:\"Program Files"\Git\cmd\git push --mirror $newRepoInfo.remoteUrl
            }
            else {
                write-host "mimic git push" #TODO: mimic git push
            }
            # TODO: Verify
            write-host "... Done git push: $repoName"
            popd # $repoName

            Remove-Item -Recurse -Force $repoName
            write-host "Done migrate repo: $repoName"
        }
        # Verify the repos were created 
        # Login to target org
        LoginAzureDevOps "Target" $targetOrg $targetPAT
        $targetRepos = $(cmd /c C:\"""Program Files (x86)\Microsoft SDKs"""\Azure\CLI2\wbin\az repos list --organization=$targetOrg --project="""$targetProject""" | ConvertFrom-Json)
        foreach ($repo in $repos) {
            #TODO: $matches = $repo.name | Where-Object { $targetRepos.Name -eq $_ }
        }

        # Logout since we're now done with the az commands
        cmd /c C:\"Program Files (x86)\Microsoft SDKs"\Azure\CLI2\wbin\az devops logout
        write-host "Done migratating repos for $sourceProject"

        write-host "Step 2: Start migratating work items for $sourceProject"
        for ($i = 0; $i -le 100000; $i = $i + $workItemBatchSize) {
            # $count = $(cmd /c C:\"""Program Files (x86)\Microsoft SDKs"""\Azure\CLI2\wbin\az boards query --wiql="select id from workitems where [System.ID] >= $($i) AND [System.WorkItemType] NOT IN ('Test Suite', 'Test Plan','Shared Steps','Shared Parameter','Feedback Request')" --organization=https://dev.azure.com/tmp-blockworkscom/ --project=source2 | ConvertFrom-Json).count
            $count = 1 # TODO: figure out how many work items there are in total to avoid running so many times
            if ($count -gt 0) {
                $templateFile = join-path -path $templatePath -childpath "migrateWorkItemsTemplate.json"
                UpdateConfigFile $templateFile (join-path -path $pwd -ChildPath "migrateWorkItems$($i).json")
                UpdateConfigFile $templateFile ".\migrateWorkItemsRemaining.json"
            }
            if ($test -ne $true) {
                write-host "...migrate work items using $destFile"
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
                write-host "...mimic migrate work items" #TODO: mimic migrate work items
            }
        }
        write-host "*** Import Remaining Work Items"
        write-host "...migrate work items using .\migrateWorkItemsRemaining.json"
        c:\tools\MigrationTools\migration.exe execute --config .\migrateWorkItemsRemaining.json 2>&1 | Tee-Object -Variable result
        if ($? -ne $true) { 
            Write-Error "ERROR found step 204!!! Exit"
            Read-Host "Press ENTER to continue or Ctrl-C to stop."
        }

        # TODO: Verify
        write-host "Done migratating work items for $sourceProject"

        write-host "Step 3: Start migratating test plans for $sourceProject"
        $templateFile = join-path -path $templatePath -childpath "migrateTestPlansTemplate.json"
        UpdateConfigFile $templateFile (join-path -path $pwd -ChildPath "migrateTestPlans.json")

        if ($test -ne $true) {
            write-host "...migrate test plans using $destFile"
            c:\tools\MigrationTools\migration.exe execute --config $destFile 2>&1 | Tee-Object -Variable result
            if ($? -ne $true) { 
                Write-Error "ERROR found step 227!!! Exit"
                Read-Host "Press ENTER to continue or Ctrl-C to stop."
            }
        }
        else {
            write-host "mimic migrate test plans" #TODO: mimic migrate test plans
        }
        # TODO: Verify
        write-host "Done migratating test plans for $sourceProject"

        write-host "Step 4: Start migratating pipelines for $sourceProject"
        $templateFile = join-path -path $templatePath -childpath "migratePipelinesTemplate.json"
        UpdateConfigFile $templateFile (join-path -path $pwd -ChildPath "migratePipelines.json")

        if ($test -ne $true) {
            write-host "...migrate pipelines using $destFile"
            c:\tools\MigrationTools\migration.exe execute --config $destFile 2>&1 | Tee-Object -Variable result
            if ($? -ne $true) { 
                Write-Error "ERROR found step 252!!! Exit"
                Read-Host "Press ENTER to continue or Ctrl-C to stop."
            }
        }
        else {
            write-host "mimic migrated pipelines" #TODO: mimic migrate pipelines
        }
        # TODO: Verify
        write-host "Done migratating pipelines for $sourceProject"

        popd # $sourceProject
        Remove-Item -Recurse -Force "$sourceProject"
        write-host "Done migratating $sourceProject"
    }

    popd # c:\tools\MigrationTools\

    Write-Host "You will need to delete empty default git repos for the target projects. It may not needed after the migration."
    # Read-Host "Press ENTER to continue. This is the last step."
}
catch {
    Write-Error "Failed with error: $_"
    return 0
}
finally {
    $env:AZURE_DEVOPS_EXT_PAT = $originalEnvAzureDevOpsExtPAT
    $VerbosePreference = $originalVerbose
}
