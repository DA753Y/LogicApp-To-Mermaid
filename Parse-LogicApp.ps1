<#
.SYNOPSIS
    Parses Azure Logic App workflow definitions or ARM templates and converts them into Mermaid.js flowcharts.
.DESCRIPTION
    This script extracts Logic App workflow definitions from raw JSON, Javascript variable files,
    or ARM templates. It recursively parses triggers and nested actions (Scopes, Loops, Conditions, Switches)
    and constructs a highly detailed, styled Mermaid.js flowchart.
    
    The output is optimized for direct copy-pasting into Excalidraw, Mermaid Live Editor, or markdown documents.
.PARAMETER Path
    The absolute or relative path to the input file (JSON, TXT, or JS).
.PARAMETER OutputPath
    The path where the generated Mermaid diagram (.mmd or .txt) should be saved.
.PARAMETER Clipboard
    If specified, copies the generated Mermaid syntax directly to the clipboard.
.PARAMETER Direction
    The orientation of the flowchart. Valid values: TD (Top-Down), LR (Left-to-Right), BU (Bottom-Up), RL (Right-to-Left). Default is TD.
.PARAMETER Theme
    The visual theme to apply to the diagram. Valid values: default, dark, forest, neutral. Default is default.
.EXAMPLE
    .\Parse-LogicApp.ps1 -Path ".\samples\simple.json" -Clipboard
    Parses a simple Logic App and copies the Mermaid text to the clipboard.
.EXAMPLE
    .\Parse-LogicApp.ps1 -Path ".\samples\arm.json" -OutputPath ".\output.mmd" -Direction LR
    Parses an ARM template, outputs a Left-to-Right flowchart, and saves it to output.mmd.
#>
param (
    [Parameter(Mandatory = $true, ValueFromPipeline = $true, Position = 0)]
    [string]$Path,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [switch]$Clipboard,

    [Parameter(Mandatory = $false)]
    [ValidateSet("TD", "BU", "LR", "RL")]
    [string]$Direction = "TD",

    [Parameter(Mandatory = $false)]
    [ValidateSet("default", "dark", "forest", "neutral")]
    [string]$Theme = "default"
)

# Set ActionPreference to stop on errors for critical operations
$ErrorActionPreference = "Stop"

# --- HELPER FUNCTIONS ---

function Get-SafeId {
    param([string]$name)
    # Convert spaces/hyphens and special chars to underscores
    $safe = $name -replace '[^a-zA-Z0-9_]', '_'
    # Ensure it starts with a letter or underscore
    if ($safe -match '^[0-9]') {
        $safe = "node_" + $safe
    }
    return $safe
}

function Get-NodeLabelAndShape {
    param(
        [string]$name, 
        [string]$type, 
        [PSCustomObject]$definition
    )
    
    $shapeStart = "["
    $shapeEnd = "]"
    $connectorName = $type
    
    switch -Regex ($type) {
        "Request|Response" {
            $connectorName = $type
        }
        "Http" {
            $method = $definition.inputs.method
            if ($null -ne $method) { $connectorName = "HTTP $method" } else { $connectorName = "HTTP" }
        }
        "InitializeVariable|SetVariable|IncrementVariable|DecrementVariable|AppendToArrayVariable|AppendToStringVariable" {
            $varName = $null
            if ($null -ne $definition.inputs) {
                if ($null -ne $definition.inputs.variables) {
                    $varName = $definition.inputs.variables[0].name
                } elseif ($null -ne $definition.inputs.name) {
                    $varName = $definition.inputs.name
                }
            }
            if ($null -ne $varName) { $connectorName = "Variable: $varName" } else { $connectorName = "Variable" }
        }
        "Compose" {
            $connectorName = "Compose"
        }
        "ApiConnection|ApiConnectionWebhook" {
            $apiName = $null
            if ($null -ne $definition.inputs -and $null -ne $definition.inputs.host -and $null -ne $definition.inputs.host.api) {
                $apiName = $definition.inputs.host.api.id -replace '.*/', ''
            }
            if ($null -ne $apiName) { $connectorName = $apiName } else { $connectorName = "API Connection" }
        }
        "Function" {
            $connectorName = "Function"
        }
        "If|Expression" {
            $shapeStart = "{"
            $shapeEnd = "}"
            $connectorName = "If"
        }
        "Switch" {
            $shapeStart = "{"
            $shapeEnd = "}"
            $connectorName = "Switch"
        }
        "Foreach" {
            $shapeStart = "[["
            $shapeEnd = "]]"
            $connectorName = "ForEach"
        }
        "Until" {
            $shapeStart = "[["
            $shapeEnd = "]]"
            $connectorName = "Until"
        }
        "Trigger" {
            $shapeStart = "(["
            $shapeEnd = "])"
            $connectorName = "Trigger"
        }
        Default {
            $connectorName = $type
        }
    }
    
    $cleanName = $name -replace '_', ' '
    $label = "$cleanName ($connectorName)"
    
    return [PSCustomObject]@{
        Label = $label
        ShapeStart = $shapeStart
        ShapeEnd = $shapeEnd
    }
}

function Register-Actions {
    param(
        [PSCustomObject]$actionsObj,
        [string]$parentName = $null
    )
    if ($null -eq $actionsObj) { return }
    
    foreach ($prop in $actionsObj.PSObject.Properties) {
        $actionName = $prop.Name
        $actionDef = $prop.Value
        
        $type = $actionDef.type
        $children = @()
        $branches = @{}
        
        # Determine children and branches recursively
        if ($type -eq "Scope" -or $type -eq "Foreach" -or $type -eq "Until") {
            if ($null -ne $actionDef.actions) {
                Register-Actions -actionsObj $actionDef.actions -parentName $actionName
                foreach ($childProp in $actionDef.actions.PSObject.Properties) {
                    $children += $childProp.Name
                }
            }
        } elseif ($type -eq "If" -or $type -eq "Expression") {
            if ($null -ne $actionDef.actions) {
                Register-Actions -actionsObj $actionDef.actions -parentName $actionName
                $thenChildren = @()
                foreach ($childProp in $actionDef.actions.PSObject.Properties) {
                    $thenChildren += $childProp.Name
                }
                $branches["then"] = $thenChildren
            } else {
                $branches["then"] = @()
            }
            
            if ($null -ne $actionDef.else -and $null -ne $actionDef.else.actions) {
                Register-Actions -actionsObj $actionDef.else.actions -parentName $actionName
                $elseChildren = @()
                foreach ($childProp in $actionDef.else.actions.PSObject.Properties) {
                    $elseChildren += $childProp.Name
                }
                $branches["else"] = $elseChildren
            } else {
                $branches["else"] = @()
            }
        } elseif ($type -eq "Switch") {
            $caseIndex = 1
            if ($null -ne $actionDef.cases) {
                foreach ($caseObj in $actionDef.cases) {
                    $caseVal = $caseObj.value
                    if ($null -eq $caseVal) { $caseVal = "Case_$caseIndex"; $caseIndex++ }
                    
                    if ($null -ne $caseObj.actions) {
                        Register-Actions -actionsObj $caseObj.actions -parentName $actionName
                        $caseChildren = @()
                        foreach ($childProp in $caseObj.actions.PSObject.Properties) {
                            $caseChildren += $childProp.Name
                        }
                        $branches["case_$caseVal"] = $caseChildren
                    } else {
                        $branches["case_$caseVal"] = @()
                    }
                }
            }
            
            if ($null -ne $actionDef.default -and $null -ne $actionDef.default.actions) {
                Register-Actions -actionsObj $actionDef.default.actions -parentName $actionName
                $defaultChildren = @()
                foreach ($childProp in $actionDef.default.actions.PSObject.Properties) {
                    $defaultChildren += $childProp.Name
                }
                $branches["default"] = $defaultChildren
            } else {
                $branches["default"] = @()
            }
        }
        
        # Add to script registry
        $script:ActionRegistry[$actionName] = [PSCustomObject]@{
            Name        = $actionName
            SafeId      = Get-SafeId $actionName
            Type        = $type
            ParentName  = $parentName
            runAfter    = $actionDef.runAfter
            Definition  = $actionDef
            Children    = $children
            Branches    = $branches
        }
    }
}

function Get-InternalEntryActions {
    param([string[]]$childNames)
    if ($null -eq $childNames -or $childNames.Length -eq 0) { return @() }
    
    $entries = @()
    foreach ($child in $childNames) {
        $act = $script:ActionRegistry[$child]
        $hasInternalParent = $false
        
        if ($null -ne $act.runAfter) {
            foreach ($parentProp in $act.runAfter.PSObject.Properties) {
                $parentName = $parentProp.Name
                if ($childNames -contains $parentName) {
                    $hasInternalParent = $true
                    break
                }
            }
        }
        
        if (-not $hasInternalParent) {
            $entries += $child
        }
    }
    return $entries
}

function Get-InternalLeafActions {
    param([string[]]$childNames)
    if ($null -eq $childNames -or $childNames.Length -eq 0) { return @() }
    
    $leaves = @()
    foreach ($child in $childNames) {
        $isReferenced = $false
        foreach ($other in $childNames) {
            if ($other -eq $child) { continue }
            $otherAct = $script:ActionRegistry[$other]
            if ($null -ne $otherAct -and $null -ne $otherAct.runAfter) {
                foreach ($parentProp in $otherAct.runAfter.PSObject.Properties) {
                    if ($parentProp.Name -eq $child) {
                        $isReferenced = $true
                        break
                    }
                }
            }
            if ($isReferenced) { break }
        }
        
        if (-not $isReferenced) {
            $leaves += $child
        }
    }
    return $leaves
}

function Get-EntryNodes {
    param([string]$actionName)
    
    $act = $script:ActionRegistry[$actionName]
    if ($null -eq $act) {
        return @([PSCustomObject]@{ NodeId = Get-SafeId $actionName; LinkLabel = $null })
    }
    
    $type = $act.Type
    
    if ($type -eq "Scope") {
        $innerEntryActions = Get-InternalEntryActions $act.Children
        $entries = @()
        foreach ($child in $innerEntryActions) {
            $entries += Get-EntryNodes $child
        }
        if ($entries.Count -eq 0) {
            return @([PSCustomObject]@{ NodeId = $act.SafeId; LinkLabel = $null })
        }
        return $entries
    } elseif ($type -eq "Foreach" -or $type -eq "Until" -or $type -eq "If" -or $type -eq "Expression" -or $type -eq "Switch") {
        return @([PSCustomObject]@{ NodeId = $act.SafeId; LinkLabel = $null })
    } else {
        return @([PSCustomObject]@{ NodeId = $act.SafeId; LinkLabel = $null })
    }
}

function Get-LeafNodes {
    param([string]$actionName)
    
    $act = $script:ActionRegistry[$actionName]
    if ($null -eq $act) {
        return @([PSCustomObject]@{ NodeId = Get-SafeId $actionName; LinkLabel = $null })
    }
    
    $type = $act.Type
    
    if ($type -eq "Scope" -or $type -eq "Foreach" -or $type -eq "Until") {
        $innerLeafActions = Get-InternalLeafActions $act.Children
        $leaves = @()
        foreach ($child in $innerLeafActions) {
            $leaves += Get-LeafNodes $child
        }
        if ($leaves.Count -eq 0) {
            return @([PSCustomObject]@{ NodeId = $act.SafeId; LinkLabel = $null })
        }
        return $leaves
    } elseif ($type -eq "If" -or $type -eq "Expression") {
        $leaves = @()
        
        # then branch leaves
        $thenChildren = $act.Branches["then"]
        if ($null -ne $thenChildren -and $thenChildren.Count -gt 0) {
            $thenLeaves = Get-InternalLeafActions $thenChildren
            foreach ($child in $thenLeaves) {
                $leaves += Get-LeafNodes $child
            }
        } else {
            $leaves += [PSCustomObject]@{ NodeId = $act.SafeId; LinkLabel = "Yes" }
        }
        
        # else branch leaves
        $elseChildren = $act.Branches["else"]
        if ($null -ne $elseChildren -and $elseChildren.Count -gt 0) {
            $elseLeaves = Get-InternalLeafActions $elseChildren
            foreach ($child in $elseLeaves) {
                $leaves += Get-LeafNodes $child
            }
        } else {
            $leaves += [PSCustomObject]@{ NodeId = $act.SafeId; LinkLabel = "No" }
        }
        
        return $leaves
    } elseif ($type -eq "Switch") {
        $leaves = @()
        
        # cases leaves
        foreach ($key in $act.Branches.Keys) {
            if ($key -like "case_*") {
                $caseChildren = $act.Branches[$key]
                $caseVal = $key.Substring(5)
                if ($null -ne $caseChildren -and $caseChildren.Count -gt 0) {
                    $caseLeaves = Get-InternalLeafActions $caseChildren
                    foreach ($child in $caseLeaves) {
                        $leaves += Get-LeafNodes $child
                    }
                } else {
                    $leaves += [PSCustomObject]@{ NodeId = $act.SafeId; LinkLabel = $caseVal }
                }
            }
        }
        
        # default branch leaves
        $defaultChildren = $act.Branches["default"]
        if ($null -ne $defaultChildren -and $defaultChildren.Count -gt 0) {
            $defaultLeaves = Get-InternalLeafActions $defaultChildren
            foreach ($child in $defaultLeaves) {
                $leaves += Get-LeafNodes $child
            }
        } else {
            $leaves += [PSCustomObject]@{ NodeId = $act.SafeId; LinkLabel = "Default" }
        }
        
        return $leaves
    } else {
        return @([PSCustomObject]@{ NodeId = $act.SafeId; LinkLabel = $null })
    }
}

function Render-Actions-Nodes {
    param(
        [string[]]$actionNames,
        [int]$indent = 2
    )
    if ($null -eq $actionNames -or $actionNames.Length -eq 0) { return }
    
    $pad = " " * $indent
    
    foreach ($name in $actionNames) {
        $act = $script:ActionRegistry[$name]
        if ($null -eq $act) { continue }
        
        $meta = Get-NodeLabelAndShape -name $act.Name -type $act.Type -definition $act.Definition
        
        if ($act.Type -eq "Scope") {
            $script:outLines.Add("${pad}subgraph $($act.SafeId) [`"$($act.Name) (Scope)`"]")
            Render-Actions-Nodes -actionNames $act.Children -indent ($indent + 2)
            $script:outLines.Add("${pad}end")
        } elseif ($act.Type -eq "Foreach" -or $act.Type -eq "Until") {
            $loopType = if ($act.Type -eq "Foreach") { "ForEach" } else { "Until" }
            
            $script:outLines.Add("${pad}subgraph $($act.SafeId)_container [`"$($act.Name) ($loopType)`"]")
            $script:outLines.Add("${pad}  $($act.SafeId)$($meta.ShapeStart)`"$($meta.Label)`"$($meta.ShapeEnd)")
            
            $script:controlNodes.Add($act.SafeId) | Out-Null
            
            Render-Actions-Nodes -actionNames $act.Children -indent ($indent + 2)
            
            # Connect loop node to internal entries
            $innerEntries = Get-InternalEntryActions $act.Children
            foreach ($entry in $innerEntries) {
                $entryNodes = Get-EntryNodes $entry
                foreach ($en in $entryNodes) {
                    $script:outLines.Add("${pad}  $($act.SafeId) --> $($en.NodeId)")
                }
            }
            
            $script:outLines.Add("${pad}end")
        } elseif ($act.Type -eq "If" -or $act.Type -eq "Expression") {
            $script:outLines.Add("${pad}subgraph $($act.SafeId)_container [`"$($act.Name) (If)`"]")
            $script:outLines.Add("${pad}  $($act.SafeId)$($meta.ShapeStart)`"$($meta.Label)`"$($meta.ShapeEnd)")
            
            $script:controlNodes.Add($act.SafeId) | Out-Null
            
            # Render branches
            $thenChildren = $act.Branches["then"]
            if ($null -ne $thenChildren -and $thenChildren.Count -gt 0) {
                $script:outLines.Add("${pad}  subgraph $($act.SafeId)_then [`"Yes Branch`"]")
                Render-Actions-Nodes -actionNames $thenChildren -indent ($indent + 4)
                $script:outLines.Add("${pad}  end")
                
                $thenEntries = Get-InternalEntryActions $thenChildren
                foreach ($entry in $thenEntries) {
                    $entryNodes = Get-EntryNodes $entry
                    foreach ($en in $entryNodes) {
                        $script:outLines.Add("${pad}  $($act.SafeId) -- Yes --> $($en.NodeId)")
                    }
                }
            }
            
            $elseChildren = $act.Branches["else"]
            if ($null -ne $elseChildren -and $elseChildren.Count -gt 0) {
                $script:outLines.Add("${pad}  subgraph $($act.SafeId)_else [`"No Branch`"]")
                Render-Actions-Nodes -actionNames $elseChildren -indent ($indent + 4)
                $script:outLines.Add("${pad}  end")
                
                $elseEntries = Get-InternalEntryActions $elseChildren
                foreach ($entry in $elseEntries) {
                    $entryNodes = Get-EntryNodes $entry
                    foreach ($en in $entryNodes) {
                        $script:outLines.Add("${pad}  $($act.SafeId) -- No --> $($en.NodeId)")
                    }
                }
            }
            
            $script:outLines.Add("${pad}end")
        } elseif ($act.Type -eq "Switch") {
            $script:outLines.Add("${pad}subgraph $($act.SafeId)_container [`"$($act.Name) (Switch)`"]")
            $script:outLines.Add("${pad}  $($act.SafeId)$($meta.ShapeStart)`"$($meta.Label)`"$($meta.ShapeEnd)")
            
            $script:controlNodes.Add($act.SafeId) | Out-Null
            
            # Render branches
            foreach ($key in $act.Branches.Keys) {
                $branchChildren = $act.Branches[$key]
                $branchLabel = $key
                if ($key -like "case_*") {
                    $branchLabel = $key.Substring(5)
                }
                
                if ($null -ne $branchChildren -and $branchChildren.Count -gt 0) {
                    $script:outLines.Add("${pad}  subgraph $($act.SafeId)_$($key) [`"$branchLabel Branch`"]")
                    Render-Actions-Nodes -actionNames $branchChildren -indent ($indent + 4)
                    $script:outLines.Add("${pad}  end")
                    
                    $branchEntries = Get-InternalEntryActions $branchChildren
                    foreach ($entry in $branchEntries) {
                        $entryNodes = Get-EntryNodes $entry
                        foreach ($en in $entryNodes) {
                            $script:outLines.Add("${pad}  $($act.SafeId) -- $($branchLabel) --> $($en.NodeId)")
                        }
                    }
                }
            }
            
            $script:outLines.Add("${pad}end")
        } else {
            # Simple Node
            $script:outLines.Add("${pad}$($act.SafeId)$($meta.ShapeStart)`"$($meta.Label)`"$($meta.ShapeEnd)")
        }
    }
}

function Render-Connections {
    param([string[]]$actionNames)
    if ($null -eq $actionNames -or $actionNames.Length -eq 0) { return }
    
    foreach ($name in $actionNames) {
        $act = $script:ActionRegistry[$name]
        if ($null -eq $act) { continue }
        
        if ($null -ne $act.runAfter) {
            foreach ($parentProp in $act.runAfter.PSObject.Properties) {
                $parentName = $parentProp.Name
                $statuses = $parentProp.Value
                
                # Check status conditions for arrow styling
                $arrow = "-->"
                if ($statuses -contains "Failed" -and $statuses.Count -eq 1) {
                    $arrow = "-. Failed .->"
                } elseif (-not ($statuses -contains "Succeeded")) {
                    $statusStr = $statuses -join ", "
                    $arrow = "-- `"$statusStr`" -->"
                }
                
                $leaves = Get-LeafNodes $parentName
                $entries = Get-EntryNodes $name
                
                foreach ($leaf in $leaves) {
                    foreach ($entry in $entries) {
                        if ($null -ne $leaf.LinkLabel) {
                            if ($arrow -eq "-->") {
                                $script:outLines.Add("  $($leaf.NodeId) -- $($leaf.LinkLabel) --> $($entry.NodeId)")
                            } else {
                                $script:outLines.Add("  $($leaf.NodeId) -. $($leaf.LinkLabel) & $($statuses -join ', ') .-> $($entry.NodeId)")
                            }
                        } else {
                            $script:outLines.Add("  $($leaf.NodeId) $($arrow) $($entry.NodeId)")
                        }
                    }
                }
            }
        }
        
        # Recurse through childrens' connections
        if ($act.Children.Count -gt 0) {
            Render-Connections -actionNames $act.Children
        }
        if ($null -ne $act.Branches) {
            foreach ($key in $act.Branches.Keys) {
                Render-Connections -actionNames $act.Branches[$key]
            }
        }
    }
}

function Get-MermaidStyles {
    param([string]$theme)
    
    $styles = @()
    if ($theme -eq "dark") {
        $styles += "  %% Dark Theme Styles"
        $styles += "  classDef default fill:#1e1e24,stroke:#3a3a43,stroke-width:1px,color:#e0e0e6;"
        $styles += "  classDef trigger fill:#0f3c26,stroke:#1e7e4c,stroke-width:2px,color:#a3e2c9;"
        $styles += "  classDef control fill:#4d2a00,stroke:#995400,stroke-width:2px,color:#ffd8a8;"
    } elseif ($theme -eq "forest") {
        $styles += "  %% Forest Theme Styles"
        $styles += "  classDef default fill:#f4f9f4,stroke:#70a170,stroke-width:1px,color:#1e351e;"
        $styles += "  classDef trigger fill:#e3f2fd,stroke:#1e88e5,stroke-width:2px,color:#0d47a1;"
        $styles += "  classDef control fill:#fff8e1,stroke:#ffb300,stroke-width:2px,color:#5d4037;"
    } elseif ($theme -eq "neutral") {
        $styles += "  %% Neutral Theme Styles"
        $styles += "  classDef default fill:#fafafa,stroke:#757575,stroke-width:1px,color:#212121;"
        $styles += "  classDef trigger fill:#f5f5f5,stroke:#9e9e9e,stroke-width:2px,color:#212121;"
        $styles += "  classDef control fill:#eeeeee,stroke:#616161,stroke-width:2px,color:#212121;"
    } else {
        # Default Theme - Premium Clean HSL pastel
        $styles += "  %% Premium Pastel Theme Styles"
        $styles += "  classDef default fill:#e8f0fe,stroke:#1a73e8,stroke-width:1.5px,color:#1967d2;"
        $styles += "  classDef trigger fill:#e6f4ea,stroke:#137333,stroke-width:2px,color:#137333;"
        $styles += "  classDef control fill:#fef7e0,stroke:#b06000,stroke-width:2px,color:#b06000;"
    }
    return $styles
}

# --- MAIN EXECUTION ---

# Verify file existence
if (-not (Test-Path $Path)) {
    Write-Error "Input file not found at path: $Path"
    return
}

Write-Host "Reading file: $Path"
$rawText = Get-Content -Path $Path -Raw

# Extract JSON if JavaScript variable assignment
if ($rawText -notmatch '^\s*[\{\[]') {
    Write-Host "Non-JSON format detected. Attempting Javascript extraction..."
    if ($rawText -match '(?ms)(\{.*\})') {
        $rawText = $Matches[1]
    } else {
        Write-Error "Failed to extract JSON object from file content."
        return
    }
}

# Parse JSON
Write-Host "Parsing JSON content..."
try {
    $jsonObj = $rawText | ConvertFrom-Json
} catch {
    Write-Error "JSON Parsing failed: $_"
    return
}

# Extract Workflow Definitions
$definitions = [System.Collections.Generic.List[PSCustomObject]]::new()

# Look for ARM resources
if ($null -ne $jsonObj.resources -and $jsonObj.resources.Count -gt 0) {
    Write-Host "ARM template structure detected. Scanning resources..."
    foreach ($res in $jsonObj.resources) {
        if ($res.type -eq "Microsoft.Logic/workflows" -or $res.type -eq "Microsoft.Logic/workflows/") {
            $wfName = $res.name
            # Handle resource parameterized names
            if ($null -ne $wfName -and $wfName.StartsWith("[parameters(")) {
                $paramMatch = [regex]::Match($wfName, "parameters\('([^']+)'\)")
                if ($paramMatch.Success) {
                    $paramName = $paramMatch.Groups[1].Value
                    if ($null -ne $jsonObj.parameters -and $null -ne $jsonObj.parameters.$paramName -and $null -ne $jsonObj.parameters.$paramName.defaultValue) {
                        $wfName = $jsonObj.parameters.$paramName.defaultValue
                    }
                }
            }
            # Clean brackets and quotes
            $wfName = $wfName -replace '[\[\]\(\)]', ''
            $wfName = $wfName -replace "'", ""
            $wfName = $wfName -replace '"', ""
            
            $wfDef = $null
            if ($null -ne $res.properties -and $null -ne $res.properties.definition) {
                $wfDef = $res.properties.definition
            }
            if ($null -ne $wfDef) {
                $definitions.Add([PSCustomObject]@{
                    Name = $wfName
                    Definition = $wfDef
                })
            }
        }
    }
}

# Fallback/Direct parsing
if ($definitions.Count -eq 0) {
    $wfDef = $null
    $wfName = (Split-Path $Path -Leaf) -replace '\.[^.]+$',''
    
    if ($null -ne $jsonObj.properties -and $null -ne $jsonObj.properties.definition) {
        $wfDef = $jsonObj.properties.definition
        if ($null -ne $jsonObj.name) { $wfName = $jsonObj.name }
    } elseif ($null -ne $jsonObj.definition) {
        $wfDef = $jsonObj.definition
        if ($null -ne $jsonObj.name) { $wfName = $jsonObj.name }
    } elseif ($null -ne $jsonObj.actions -and $null -ne $jsonObj.triggers) {
        $wfDef = $jsonObj
    }
    
    if ($null -ne $wfDef) {
        $definitions.Add([PSCustomObject]@{
            Name = $wfName
            Definition = $wfDef
        })
    }
}

if ($definitions.Count -eq 0) {
    Write-Error "No valid Logic App workflow definition found in the provided file."
    return
}

Write-Host "Found $($definitions.Count) workflow(s). Generating Mermaid flowcharts..."

$allWorkflowsMermaid = @()

foreach ($wf in $definitions) {
    $wfName = $wf.Name
    $definition = $wf.Definition
    
    Write-Host "Processing workflow: $wfName"
    
    # Initialize script scope lists for this workflow
    $script:ActionRegistry = @{}
    $script:triggerNodes = [System.Collections.Generic.List[string]]::new()
    $script:controlNodes = [System.Collections.Generic.List[string]]::new()
    $script:outLines = [System.Collections.Generic.List[string]]::new()
    
    # Register actions
    Register-Actions -actionsObj $definition.actions
    
    # 1. Output triggers
    if ($null -ne $definition.triggers) {
        $script:outLines.Add("  %% Triggers")
        foreach ($trigProp in $definition.triggers.PSObject.Properties) {
            $trigName = $trigProp.Name
            $trigDef = $trigProp.Value
            $meta = Get-NodeLabelAndShape -name $trigName -type "Trigger" -definition $trigDef
            $trigSafeId = Get-SafeId $trigName
            $script:outLines.Add("  $trigSafeId$($meta.ShapeStart)`"$($meta.Label)`"$($meta.ShapeEnd)")
            $script:triggerNodes.Add($trigSafeId) | Out-Null
        }
    }
    
    # 2. Output action nodes
    if ($null -ne $definition.actions) {
        $script:outLines.Add("  %% Action Nodes")
        $rootActions = $definition.actions.PSObject.Properties.Name
        Render-Actions-Nodes -actionNames $rootActions -indent 2
    }
    
    # 3. Output connections between triggers and root actions
    if ($null -ne $definition.triggers -and $null -ne $definition.actions) {
        $script:outLines.Add("  %% Trigger to Action Connections")
        $rootActions = $definition.actions.PSObject.Properties.Name
        $rootEntries = Get-InternalEntryActions $rootActions
        
        foreach ($trigProp in $definition.triggers.PSObject.Properties) {
            $trigSafeId = Get-SafeId $trigProp.Name
            foreach ($entryName in $rootEntries) {
                $entries = Get-EntryNodes $entryName
                foreach ($en in $entries) {
                    $script:outLines.Add("  $trigSafeId --> $($en.NodeId)")
                }
            }
        }
    }
    
    # 4. Output action connections
    if ($null -ne $definition.actions) {
        $script:outLines.Add("  %% Action Connections")
        $rootActions = $definition.actions.PSObject.Properties.Name
        Render-Connections -actionNames $rootActions
    }
    
    # 5. Apply style classes
    $script:outLines.Add("  %% Style Assignments")
    if ($script:triggerNodes.Count -gt 0) {
        $script:outLines.Add("  class $($script:triggerNodes -join ',') trigger;")
    }
    if ($script:controlNodes.Count -gt 0) {
        $script:outLines.Add("  class $($script:controlNodes -join ',') control;")
    }
    
    # Wrap workflow in a top-level subgraph if there are multiple workflows
    $wfSafeId = Get-SafeId $wfName
    $wfTitle = "Workflow: $wfName"
    
    $wfLines = [System.Collections.Generic.List[string]]::new()
    if ($definitions.Count -gt 1) {
        $wfLines.Add("  subgraph $wfSafeId [`"$wfTitle`"]")
        foreach ($line in $script:outLines) {
            $wfLines.Add("    $line")
        }
        $wfLines.Add("  end")
    } else {
        foreach ($line in $script:outLines) {
            $wfLines.Add($line)
        }
    }
    
    $allWorkflowsMermaid += $wfLines -join "`n"
}

# Combine everything
$mermaidText = @()
$mermaidText += "flowchart $Direction"
$mermaidText += ""
$mermaidText += $allWorkflowsMermaid -join "`n`n"
$mermaidText += ""
$mermaidText += Get-MermaidStyles -theme $Theme
$mermaidText = $mermaidText -join "`n"

# Output execution
if ($null -ne $OutputPath) {
	Set-Content -Path $OutputPath -Value $mermaidText -Encoding utf8
        Write-Host "Saved Mermaid diagram to: $OutputPath"
}

if ($Clipboard) {
        Set-Clipboard -Value $mermaidText -ErrorAction Stop
        Write-Host "Copy to clipboard complete! Ready to paste into Excalidraw or Mermaid editor."
    }
}

# Return the Mermaid diagram string to the pipeline
return $mermaidText
