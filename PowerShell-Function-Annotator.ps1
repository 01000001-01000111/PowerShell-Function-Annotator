<#
Created by Aric Galloso
3/26/2025

Description: This PowerShell script, automates the process of documenting PowerShell functions by leveraging Gemini-1.5-pro API to generate descriptions based on the function's code.  It provides a structured way to request and integrate function descriptions into the script itself, improving readability and maintainability.

The PowerShell function called `Invoke-PowerShellFunctionAnnotation` processes PowerShell scripts, either individually or in batch, and applies annotation or transformation using a Gemini-1.5-pro API Key. The function sets up the parameter handling and path resolution to prepare for this processing.


#>
function Invoke-PowerShellFunctionAnnotation {
    [CmdletBinding(DefaultParameterSetName='Batch')]
    param (
        [Parameter(Mandatory, ParameterSetName='Single')]
        [Parameter(Mandatory, ParameterSetName='Batch')]
        [string]$ApiKey,

        [Parameter(Mandatory, ParameterSetName='Single')]
        [string]$SingleScriptPath,

        [Parameter(Mandatory, ParameterSetName='Batch')]
        [string]$SourceDirectory,

        [Parameter(Mandatory, ParameterSetName='Single')]
        [Parameter(Mandatory, ParameterSetName='Batch')]
        [string]$DestinationPath
    )

    # Helper function to resolve paths with quote handling
    function Resolve-QuotedPath {
        param([string]$Path)
        $cleanPath = $Path.Trim().Trim('"''')
        try {
            $fullPath = Resolve-Path $cleanPath -ErrorAction Stop
            return $fullPath.Path
        }
        catch {
            return $cleanPath
        }
    }

    # Helper function to add function descriptions
    <#
 Description: This PowerShell function Add-FunctionDescriptions takes PowerShell code as input and uses Gemini-1.5-pro API to generate descriptions for each function defined within the code.

Here's a breakdown:

1. **`Add-FunctionDescriptions` Function:**
   - Takes two parameters: `$ScriptCode` (the PowerShell code to analyze) and `$ApiKey` (the API key for accessing the external service).
   
2. **`Get-FunctionDescription` Nested Helper Function:**
   - Takes two parameters: `$FunctionCode` (the code of a single function extracted from `$ScriptCode`) and `$ApiKey`.
   - Constructs a prompt that asks the API to describe the provided `$FunctionCode`. This prompt is crucial as it structures the request sent to the API.  It effectively says, "Please describe what this PowerShell function does:" followed by the function's code.
   - Creates a request body in a hashtable format suitable for sending to the API. This request body contains the generated prompt.  

#>
function Add-FunctionDescriptions {
        param(
            [string]$ScriptCode,
            [string]$ApiKey
        )
        
        # Nested helper function to extract function descriptions
        function Get-FunctionDescription {
            param(
                [string]$FunctionCode,
                [string]$ApiKey
            )
            
            $prompt = "Please provide a description of what the following PowerShell Script does:
$FunctionCode"
            
            $requestBody = @{
                contents = @(
                    @{
                        parts = @(
                            @{
                                text = $prompt
                            }
                        )
                    }
                )
            }
            
            $bodyJson = ConvertTo-Json -Depth 10 $requestBody
            
            $headers = @{
                "Content-Type" = "application/json"
                "x-goog-api-key" = $ApiKey
            }
            
            $apiUrl = "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-pro:generateContent"
            
            try {
                Write-Host "Sending request to Gemini API for function description..."
                
                $response = Invoke-RestMethod -Uri $apiUrl -Method Post -Headers $headers -Body $bodyJson -ErrorAction Stop
                
                if ($response.candidates -and $response.candidates.Count -gt 0 -and 
                    $response.candidates[0].content -and 
                    $response.candidates[0].content.parts -and 
                    $response.candidates[0].content.parts.Count -gt 0) {
                    
                    return $response.candidates[0].content.parts[0].text.Trim()
                }
                
                Write-Warning "Could not extract description from Gemini API response."
                return "# Could not extract description from Gemini API response."
            }
            catch {
                Write-Error "An error occurred during the API call: $($_.Exception.Message)"
                return "# Error during API call: $($_.Exception.Message)"
            }
        }
        
        # Regex to find function definitions
        $functionRegex = '(?s)function\s+[\w-]+\s*\{.*?\}'
        $functions = [regex]::Matches($ScriptCode, $functionRegex) | ForEach-Object { $_.Value }
        
        # If no functions found, return original code
        if ($functions.Count -eq 0) {
            return $ScriptCode
        }
        
        # Annotate each function
        $annotatedCode = $ScriptCode
        foreach ($func in $functions) {
            $description = Get-FunctionDescription -FunctionCode $func -ApiKey $ApiKey
            $annotatedFunction = "<#
 Description: $description
#>
$func"
            $annotatedCode = $annotatedCode.Replace($func, $annotatedFunction)
        }
        
        return $annotatedCode
    }

    # Resolve and validate paths
    $ApiKey = $ApiKey
    
    # Determine if processing single script or batch
    $isSingleScript = $PSCmdlet.ParameterSetName -eq 'Single'
    
    # Resolve source and destination paths
    $sourcePath = if ($isSingleScript) { 
        Resolve-QuotedPath -Path $SingleScriptPath 
    } else { 
        Resolve-QuotedPath -Path $SourceDirectory 
    }
    $destPath = Resolve-QuotedPath -Path $DestinationPath

    # Validate source path
    if (-not (Test-Path $sourcePath -PathType ($isSingleScript ? 'Leaf' : 'Container'))) {
        throw "Source path does not exist: $sourcePath"
    }

    # Ensure destination directory exists
    $destDir = if ($isSingleScript) { Split-Path $destPath -Parent } else { $destPath }
    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir | Out-Null
    }

    # Determine scripts to process
    $scriptsToProcess = if ($isSingleScript) { 
        Get-Item $sourcePath 
    } else { 
        Get-ChildItem -Path $sourcePath -Filter "*.ps1" -Recurse 
    }

    # Process scripts
    $successCount = 0
    $failedScripts = @()

    foreach ($script in $scriptsToProcess) {
        try {
            # Read script content
            $originalCode = Get-Content $script.FullName -Raw

            # Annotate the script
            $annotatedCode = Add-FunctionDescriptions -ScriptCode $originalCode -ApiKey $ApiKey

            # Determine destination file path
            $destinationFilePath = if ($isSingleScript) { 
                $destPath 
            } else { 
                $relativePath = $script.FullName.Substring($sourcePath.Length).TrimStart('\')
                Join-Path -Path $destPath -ChildPath $relativePath
            }

            # Ensure destination subdirectory exists for batch processing
            if (-not $isSingleScript) {
                $destinationDir = Split-Path -Path $destinationFilePath -Parent
                if (-not (Test-Path -Path $destinationDir)) {
                    New-Item -ItemType Directory -Path $destinationDir | Out-Null
                }
            }

            # Save annotated script
            $annotatedCode | Out-File -FilePath $destinationFilePath -Encoding UTF8

            Write-Host "Annotated: $($script.Name)"
            $successCount++
        }
        catch {
            Write-Error "Failed to annotate script $($script.Name): $($_.Exception.Message)"
            $failedScripts += $script.Name
        }
    }

    # Provide summary
    Write-Host "
Annotation Complete
------------------
Total Scripts: $($scriptsToProcess.Count)
Successfully Annotated: $successCount
Failed Scripts: $($failedScripts.Count)"

    if ($failedScripts.Count -gt 0) {
        Write-Host "Failed Scripts:"
        $failedScripts | ForEach-Object { Write-Host "- $_" }
    }
}

# Main Script
try {
    Write-Host "PowerShell Script Annotator"
    Write-Host "==========================="

    # Prompt for processing type
    $processingType = Read-Host "Do you want to annotate a single PowerShell script or a batch of scripts? (single/batch)"

    # Validate processing type
    while ($processingType -notin @('single', 'batch')) {
        Write-Error "Invalid option. Please enter 'single' or 'batch'."
        $processingType = Read-Host "Do you want to annotate a single PowerShell script or a batch of scripts? (single/batch)"
    }

    # Prepare parameters for the main function
    $params = @{}

    # Get API key first
    $params['ApiKey'] = Read-Host "Enter your Google Cloud Generative AI API Key"

    # Source path handling
    $sourcePrompt = if ($processingType -eq 'single') {
        "Enter the full path of the PowerShell script to annotate"
    } else {
        "Enter the full path of the source directory containing PowerShell scripts"
    }
    $sourcePath = Read-Host $sourcePrompt

    # Destination path handling
    $destPrompt = if ($processingType -eq 'single') {
        "Enter the full path for the annotated script (including filename)"
    } else {
        "Enter the full path of the destination directory for annotated scripts"
    }
    $destPath = Read-Host $destPrompt

    # Add source and destination parameters based on processing type
    if ($processingType -eq 'single') {
        $params['SingleScriptPath'] = $sourcePath
    } else {
        $params['SourceDirectory'] = $sourcePath
    }
    $params['DestinationPath'] = $destPath

    # Confirm before processing
    $confirmMessage = if ($processingType -eq 'single') {
        "Are you sure you want to annotate the script $sourcePath and save it to $destPath? (y/n)"
    } else {
        "Are you sure you want to annotate all PowerShell scripts in $sourcePath and save them too $destPath? (y/n)"
    }

    $confirmation = Read-Host $confirmMessage

    if ($confirmation -eq 'y') {
        # Call the main function with appropriate parameters
        Invoke-PowerShellFunctionAnnotation @params
    }
    else {
        Write-Host "Annotation cancelled."
    }
}
catch {
    Write-Error "An error occurred: $($_.Exception.Message)"
}
