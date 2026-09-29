#Requires -Version 7.5
[CmdletBinding(DefaultParameterSetName='Run')]
param(
    [Parameter(Mandatory)][ValidateSet('Run','Read')][string]$Operation,
    [Parameter(Mandatory,ParameterSetName='Run')][string]$BindingsPath,
    [Parameter(Mandatory,ParameterSetName='Run')][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedBindingsSha256,
    [Parameter(Mandatory,ParameterSetName='Read')][string]$ObservationPath,
    [Parameter(Mandatory,ParameterSetName='Read')][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedObservationSha256
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 3.0
try{
    . (Join-Path $PSScriptRoot 'lib\c1b-candidate-host-stages.ps1')
    if($Operation-ceq'Run'){
        if($PSCmdlet.ParameterSetName-cne'Run'){throw 'Run requires bindings parameters.'}
        $result=Invoke-C1bCandidateHostStage -BindingsPath $BindingsPath -ExpectedBindingsSha256 $ExpectedBindingsSha256 -InvokerPath $PSCommandPath
    }else{
        if($PSCmdlet.ParameterSetName-cne'Read'){throw 'Read requires observation parameters.'}
        $result=Read-C1bCandidateHostStage -ObservationPath $ObservationPath -ExpectedObservationSha256 $ExpectedObservationSha256
    }
    ConvertTo-Json -InputObject $result -Compress -Depth 24
    if($result.status-cne'passed'){exit 1}
    exit 0
}catch{
    # Actual outer capture observes this native exit and raw stderr. No self exit receipt.
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
