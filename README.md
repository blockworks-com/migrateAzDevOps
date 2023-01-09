# migrateDevOps

Powershell script to help with migrating projects from Azure DevOps to Azure DevOps. It uses git and <https://github.com/nkdAgility/azure-devops-migration-tools>. It's rough but worth sharing since many people have to migrate in a hurry.

## Prerequisites on Azure DevOps

### On Source Azure DevOps

1. Right click Agile and Create Inherited, name it something like "Agile-migration"
2. Add the field "ReflectedWorkItemId" to each work item type
3. Repeat for Scrum, named "Scrum-migration"
4. You can ignore CMMI since it’s probably not used
5. Go to your project and change the process to "Agile-migration" or "Scrum-migration" as appropriate

### On Target Azure DevOps

1. Right click Agile and Create Inherited, name it something like "Agile-migration"
2. Add the field "ReflectedWorkItemId" to each work item type.
3. Repeat for Scrum, named "Scrum-migration".
4. You can ignore CMMI since it’s probably not used.
5. Go to your project and change the process to "Agile-migration" or "Scrum-migration" as appropriate

### Get Personal Access Tokens

1. Get Personal Access Tokens for Source Azure DevOps
2. Get Personal Access Tokens for Target Azure DevOps

### Update Script Variables

1. Notepad migrateDevOps.ps1
    * Update $sourceOrganization (at top of file)
    * Update $targetOrganization (at top of file)
    * Update $projects (at top of file)

## Run script

1. Open Powershell window. Replace <xyz> with actual value
2. Powershell.exe -ExecutionPolicy Bypass -File ./migrateDevOps.ps1 -sourceOrg <sourceUrl> -sourcePAT <sourcePAT> -targetOrg <targetUrl> -targetPAT <targetPAT>
    * Monitor the console for errors until it’s done
3. Verify target is correct
4. Clean up by removing migration process on Source Azure DevOps
    * Go to your project and change the process to back to Agile or Scrum
    * Right click "Agile-migration" and delete.
    * Right click "Scrum-migration" and delete.
    * You can ignore CMMI since it’s probably not used.
5. Clean up project on Target Azure DevOps
    * Go to your project and change the process to back to Agile or Scrum
6. Inherited processes can be removed after all the migrations are complete

### Optional Parameters

* -projects: pass in the json list of projects to migrate.
    * -projects '[{"""source""": """source3-agile""", """target""": """"""},{"""source2-scrum""": """target2-scrum""", """target""": """"""}]'
* -getProjectList: this will query SourceOrg and display a list of all projects in SourceOrg
* -verbose: display verbose messages
* -WhatIf: testing mode to see what would happen without actually migrating
* -skipRepo: do not migrate repos
* -skipWorkItems: do not migrate work items


## Caution

This is for developers with DevOps admin knowledge. Read all about the migration tool <https://github.com/nkdAgility/azure-devops-migration-tools> before using.
