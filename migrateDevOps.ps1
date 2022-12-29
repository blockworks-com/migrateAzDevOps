param([string]$sourcePAT, [string]$targetPAT)

#####################################
# Variables
#####################################
# MUST CHANGE
$sourceOrganization = "" # MUST CHANGE
$targetOrganization = "" # MUST CHANGE
$projects = @(
    [pscustomobject]@{source = "eTrack"; target = "" }
) # MUST CHANGE
# Can leave as defaults
$workItemBatchSize = 5000
$test = $false
$templatePath = "$pwd"

function PromptForPAT([string] $whichOne) {
    $i = 0
    while ($i -lt 3) {
        $i++
        $answer = Read-Host -Prompt "Enter the Personal Access Token (PAT) for $whichOne (ex. 82ejnd73nsdjf7emsdnfkj)"
        try {
            # 20 is a made up minimum to ensure a valid PAT was entered since they are fairly long
            if ($answer.Length -ge 20) { return $answer }
        }
        catch {
            write-host -ForegroundColor Yellow "Invalid since the value entered was less than 20 characters. Please provide a valid PAT."
        }
    }

    write-host "ERROR: You entered an invalid PAT three times. Exit"
    throw "ERROR: Invalid PAT"
}

#####################################
# Setup
#####################################
# Install Chocolatey if not installed
if (! (test-path -PathType container "C:\ProgramData\chocolatey\bin")) {
    Set-ExecutionPolicy Bypass -Scope Process -Force; iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
}
# Install vsts-sync-migrator if not installed
if (! (test-path -PathType container "c:\tools\MigrationTools\")) {
    choco install -y vsts-sync-migrator
}
# Install git if not installed
if (! (test-path -PathType container "C:\Program Files\Git\cmd\")) {
    choco install -y git
}
# Install azure cli if not installed
if (! (test-path -PathType container "C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\wbin\")) {
    choco install -y azure-cli
    C:\"Program Files (x86)\Microsoft SDKs"\Azure\CLI2\wbin\az extension add --name azure-devops
}

#####################################
# Prompt for our PAT values, if not supplied
#####################################
if ([string]::IsNullOrWhiteSpace($sourcePAT)) {
    $sourcePAT = PromptForPAT "$sourceOrganization"
}
if ([string]::IsNullOrWhiteSpace($targetPAT)) {
    $targetPAT = PromptForPAT "$targetOrganization"
}

# Verify valid template folder
if (! (test-path -PathType container "$templatePath")) {
    Write-Error "ERROR template folder does not exist and is required. Folder = $templatePath."
    Read-Host "Press ENTER to exit."
    return
}

# Log into source azure cli
# set environment variable for current process
# C:\"Program Files (x86)\Microsoft SDKs"\Azure\CLI2\wbin\az login --use-device-code
$originalEnvAzureDevOpsExtPAT = $env:AZURE_DEVOPS_EXT_PAT
$env:AZURE_DEVOPS_EXT_PAT = $sourcePAT
echo $sourcePAT | cmd /c C:\"Program Files (x86)\Microsoft SDKs"\Azure\CLI2\wbin\az devops login --organization=$sourceOrganization

# Do the migrations
pushd "c:\tools\MigrationTools\"
foreach ($project in $projects) {
    # NOTE: ALWAYS migrate code first before migrating work items so the links are fixed.
    $sourceProject = $project.source
    if ([string]::IsNullOrWhiteSpace($targetProject)) {
        # default to be the same as the source project name
        $targetProject = $project.source
    }
    else {
        $targetProject = $project.target
    }
    write-host "*** PROJECT: $sourceProject"

    mkdir $sourceProject | Out-Null
    pushd $sourceProject
    # Migrate git repos
    write-host "Step 1: Start migratating repos for $sourceProject"
    $repos = $(cmd /c C:\"""Program Files (x86)\Microsoft SDKs"""\Azure\CLI2\wbin\az repos list --organization=$sourceOrganization --project="""$sourceProject""" | ConvertFrom-Json)
    write-host "... there are $($repos.count) git repos for $sourceProject"
    foreach ($repo in $repos) {
        $repoName = $repo.name
        write-host "Step 1a: Migrate repo: $repoName"

        # Login to source org
        cmd /c C:\"Program Files (x86)\Microsoft SDKs"\Azure\CLI2\wbin\az devops logout
        $env:AZURE_DEVOPS_EXT_PAT = $sourcePAT
        echo $sourcePAT | cmd /c C:\"Program Files (x86)\Microsoft SDKs"\Azure\CLI2\wbin\az devops login --organization=$sourceOrganization

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
        cmd /c C:\"Program Files (x86)\Microsoft SDKs"\Azure\CLI2\wbin\az devops logout
        $env:AZURE_DEVOPS_EXT_PAT = $targetPAT
        echo $targetPAT | cmd /c C:\"Program Files (x86)\Microsoft SDKs"\Azure\CLI2\wbin\az devops login --organization=$targetOrganization

        write-host "... az create target repo: $repoName"
        if ($test -ne $true) {
            $newRepoInfo = $(cmd /c C:\"""Program Files (x86)\Microsoft SDKs"""\Azure\CLI2\wbin\az repos create --name="""$repoName""" --organization=$targetOrganization --project=$targetProject | ConvertFrom-Json)
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
    cmd /c C:\"Program Files (x86)\Microsoft SDKs"\Azure\CLI2\wbin\az devops logout
    $env:AZURE_DEVOPS_EXT_PAT = $targetPAT
    echo $targetPAT | cmd /c C:\"Program Files (x86)\Microsoft SDKs"\Azure\CLI2\wbin\az devops login --organization=$targetOrganization
    $targetRepos = $(cmd /c C:\"""Program Files (x86)\Microsoft SDKs"""\Azure\CLI2\wbin\az repos list --organization=$targetOrganization --project="""$targetProject""" | ConvertFrom-Json)
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
            $destFile = join-path -path $pwd -ChildPath "migrateWorkItems$($i).json"

            Copy-Item $templateFile $destFile
            (Get-Content $destFile).Replace("___sourceCollection___", $sourceOrganization) | Set-Content $destFile
            (Get-Content $destFile).Replace("___sourceProject___", $sourceProject) | Set-Content $destFile
            (Get-Content $destFile).Replace("___sourcePAT___", $sourcePAT) | Set-Content $destFile

            (Get-Content $destFile).Replace("___targetCollection___", $targetOrganization) | Set-Content $destFile
            (Get-Content $destFile).Replace("___targetProject___", $targetProject) | Set-Content $destFile
            (Get-Content $destFile).Replace("___targetPAT___", $targetPAT) | Set-Content $destFile

            Copy-Item $destFile .\migrateWorkItemsRemaining.json

            (Get-Content $destFile).Replace("___i___", $i) | Set-Content $destFile
            (Get-Content $destFile).Replace("___iAndBatchSize___", $($i + $workItemBatchSize)) | Set-Content $destFile

            (Get-Content .\migrateWorkItemsRemaining.json).Replace("___i___", $($i + $workItemBatchSize)) | Set-Content .\migrateWorkItemsRemaining.json
            (Get-Content .\migrateWorkItemsRemaining.json).Replace("___iAndBatchSize___", 999999999) | Set-Content .\migrateWorkItemsRemaining.json
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
    $destFile = join-path -path $pwd -ChildPath "migrateTestPlans.json"

    Copy-Item $templateFile $destFile
    (Get-Content $destFile).Replace("___sourceCollection___", $sourceOrganization) | Set-Content $destFile
    (Get-Content $destFile).Replace("___sourceProject___", $sourceProject) | Set-Content $destFile
    (Get-Content $destFile).Replace("___sourcePAT___", $sourcePAT) | Set-Content $destFile

    (Get-Content $destFile).Replace("___targetCollection___", $targetOrganization) | Set-Content $destFile
    (Get-Content $destFile).Replace("___targetProject___", $targetProject) | Set-Content $destFile
    (Get-Content $destFile).Replace("___targetPAT___", $targetPAT) | Set-Content $destFile

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
    $destFile = join-path -path $pwd -ChildPath "migratePipelines.json"

    Copy-Item $templateFile $destFile
    (Get-Content $destFile).Replace("___sourceCollection___", $sourceOrganization) | Set-Content $destFile
    (Get-Content $destFile).Replace("___sourceProject___", $sourceProject) | Set-Content $destFile
    (Get-Content $destFile).Replace("___sourcePAT___", $sourcePAT) | Set-Content $destFile

    (Get-Content $destFile).Replace("___targetCollection___", $targetOrganization) | Set-Content $destFile
    (Get-Content $destFile).Replace("___targetProject___", $targetProject) | Set-Content $destFile
    (Get-Content $destFile).Replace("___targetPAT___", $targetPAT) | Set-Content $destFile

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
$env:AZURE_DEVOPS_EXT_PAT = $originalEnvAzureDevOpsExtPAT

popd # c:\tools\MigrationTools\

Write-Host "You will need to delete empty default git repos for the target projects. It may not needed after the migration."
Read-Host "Press ENTER to continue. This is the last step."

