#Requires -Version 7.5
# Offline parser for the diagnostic envelope; never grants layout or action capability.
Set-StrictMode -Version 3.0

$script:C1bInventorySchema = 'tablet-c1b-inventory-result/v1'
$script:C1bInventoryStopKeys = [string[]]@(
    'window_type_read_failed', 'window_type_invalid',
    'window_display_read_failed', 'window_display_invalid',
    'window_layer_read_failed', 'window_layer_invalid',
    'window_touchable_bounds_read_failed', 'window_touchable_bounds_invalid',
    'window_active_read_failed', 'window_focus_read_failed',
    'window_id_read_failed', 'window_id_invalid'
)

function New-C1bInventoryParseFailure([string]$Reason) {
    [pscustomobject]@{ Valid=$false; ReasonCode=$Reason; ObservationRaw=$null; ObservationBytes=$null;
        Observation=$null; InventoryFrames=$null }
}

function Assert-C1bInventoryScalarString([AllowEmptyString()][string]$Value) {
    try { [void][Text.UTF8Encoding]::new($false, $true).GetByteCount($Value) }
    catch { throw [FormatException]::new('encoding_invalid') }
}

# JsonProperty.Name may replace an escaped lone surrogate rather than throw. Inspect
# the original string tokens after syntax parsing, before any decoded names are used.
function Assert-C1bInventoryJsonEscapes([string]$Raw) {
    foreach ($match in [regex]::Matches($Raw, '"(?:[^"\\]|\\.)*"')) {
        $token = $match.Value
        for ($i = 1; $i -lt $token.Length - 1; $i++) {
            if ($token[$i] -ne '\') { continue }
            if ($token[$i + 1] -ne 'u') { $i++; continue }
            $code = [Convert]::ToInt32($token.Substring($i + 2, 4), 16)
            if ($code -ge 0xD800 -and $code -le 0xDBFF) {
                if ($i + 12 -gt $token.Length - 1 -or $token.Substring($i + 6, 2) -cne '\u') {
                    throw [FormatException]::new('encoding_invalid')
                }
                $low = [Convert]::ToInt32($token.Substring($i + 8, 4), 16)
                if ($low -lt 0xDC00 -or $low -gt 0xDFFF) { throw [FormatException]::new('encoding_invalid') }
                $i += 11
            }
            elseif ($code -ge 0xDC00 -and $code -le 0xDFFF) { throw [FormatException]::new('encoding_invalid') }
            else { $i += 5 }
        }
    }
}

function Assert-C1bInventoryJsonTree([Text.Json.JsonElement]$Element) {
    switch ($Element.ValueKind) {
        Object {
            $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($property in $Element.EnumerateObject()) {
                try { $name = $property.Name }
                catch { throw [FormatException]::new('encoding_invalid') }
                Assert-C1bInventoryScalarString $name
                if (-not $names.Add($name)) { throw [FormatException]::new('duplicate_key') }
                Assert-C1bInventoryJsonTree $property.Value
            }
        }
        Array { foreach ($child in $Element.EnumerateArray()) { Assert-C1bInventoryJsonTree $child } }
        String {
            try { $value = $Element.GetString() }
            catch { throw [FormatException]::new('encoding_invalid') }
            Assert-C1bInventoryScalarString $value
        }
        Number {
            $number = 0L
            if ($Element.GetRawText() -cnotmatch '\A-?(0|[1-9][0-9]*)\z' -or
                -not $Element.TryGetInt64([ref]$number)) { throw [FormatException]::new('shape_invalid') }
        }
    }
}

function Read-C1bInventoryStrictJson([AllowEmptyString()][string]$Raw) {
    if (-not $Raw.Length -or $Raw[0] -eq [char]0xFEFF) { throw [FormatException]::new('encoding_invalid') }
    Assert-C1bInventoryScalarString $Raw
    $document = $null
    try {
        $options = [Text.Json.JsonDocumentOptions]::new()
        $options.MaxDepth = 100
        try { $document = [Text.Json.JsonDocument]::Parse($Raw, $options) }
        catch { throw [FormatException]::new('encoding_invalid') }
        Assert-C1bInventoryJsonEscapes $Raw
        Assert-C1bInventoryJsonTree $document.RootElement
        if ($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) {
            throw [FormatException]::new('shape_invalid')
        }
        return ConvertFrom-Json -InputObject $Raw -Depth 100 -DateKind String -ErrorAction Stop
    }
    finally { if ($null -ne $document) { $document.Dispose() } }
}

function Test-C1bInventoryKeys($Value, [string[]]$Keys) {
    if ($Value -isnot [pscustomobject]) { return $false }
    $actual = @($Value.PSObject.Properties.Name)
    if ($actual.Count -ne $Keys.Count) { return $false }
    foreach ($name in $actual) { if ($name -cnotin $Keys) { return $false } }
    return $true
}

function Test-C1bInventoryInteger($Value, [long]$Minimum, [long]$Maximum) {
    return ($Value -is [long] -or $Value -is [int]) -and $Value -ge $Minimum -and $Value -le $Maximum
}

function ConvertFrom-C1bInventoryResult {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    if ($Bytes.Length -lt 1 -or $Bytes.Length -gt 1048576) { return New-C1bInventoryParseFailure 'output_size_exceeded' }
    try { $raw = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes) }
    catch { return New-C1bInventoryParseFailure 'encoding_invalid' }
    try {
        $envelope = Read-C1bInventoryStrictJson $raw
        if ($null -ne $envelope.PSObject.Properties['schema'] -and
            ($envelope.schema -isnot [string] -or $envelope.schema -cne $script:C1bInventorySchema)) {
            return New-C1bInventoryParseFailure 'version_mismatch'
        }
        if (-not (Test-C1bInventoryKeys $envelope @('schema','observation_json','inventory_frames'))) {
            return New-C1bInventoryParseFailure 'shape_invalid'
        }
        if ($envelope.schema -isnot [string] -or $envelope.schema -cne $script:C1bInventorySchema) {
            return New-C1bInventoryParseFailure 'version_mismatch'
        }
        if ($envelope.observation_json -isnot [string] -or $envelope.inventory_frames -isnot [array] -or
            $envelope.inventory_frames.Count -ne 2) { return New-C1bInventoryParseFailure 'shape_invalid' }
        $observationRaw = $envelope.observation_json
        $observation = Read-C1bInventoryStrictJson $observationRaw
        $observationBytes = [Text.UTF8Encoding]::new($false, $true).GetBytes($observationRaw)
        if ($observationBytes.Length -lt 1 -or $observationBytes.Length -gt 1048576) { return New-C1bInventoryParseFailure 'output_size_exceeded' }
        foreach ($frame in $envelope.inventory_frames) {
            if (-not (Test-C1bInventoryKeys $frame @('capture_id','capture_token','enumeration_status','count_status',
                'maximum_windows','input_count','unattempted_count','attempted_count','saved_count','dropped_count','first_stop_counts'))) {
                return New-C1bInventoryParseFailure 'shape_invalid'
            }
            if ($frame.capture_id -isnot [string] -or $frame.capture_id -cnotmatch '\A[a-z0-9][a-z0-9._-]{0,79}\z' -or
                $frame.capture_token -isnot [string] -or $frame.capture_token -cnotin @('c1','c2') -or
                $frame.enumeration_status -isnot [string] -or $frame.enumeration_status -cnotin @('complete','failed') -or
                $frame.count_status -isnot [string] -or $frame.count_status -cnotin @('exact','unavailable','overflow') -or
                -not (Test-C1bInventoryInteger $frame.maximum_windows 1 16)) {
                return New-C1bInventoryParseFailure 'shape_invalid'
            }
            foreach ($key in @('input_count','unattempted_count')) {
                if ($null -ne $frame.$key -and -not (Test-C1bInventoryInteger $frame.$key 0 2147483647)) {
                    return New-C1bInventoryParseFailure 'shape_invalid'
                }
            }
            foreach ($key in @('attempted_count','saved_count','dropped_count')) {
                if (-not (Test-C1bInventoryInteger $frame.$key 0 $frame.maximum_windows)) {
                    return New-C1bInventoryParseFailure 'shape_invalid'
                }
            }
            if (-not (Test-C1bInventoryKeys $frame.first_stop_counts $script:C1bInventoryStopKeys)) {
                return New-C1bInventoryParseFailure 'shape_invalid'
            }
            foreach ($key in $script:C1bInventoryStopKeys) {
                if (-not (Test-C1bInventoryInteger $frame.first_stop_counts.$key 0 $frame.maximum_windows)) {
                    return New-C1bInventoryParseFailure 'shape_invalid'
                }
            }
        }
        return [pscustomobject]@{ Valid=$true; ReasonCode=$null; ObservationRaw=$observationRaw;
            ObservationBytes=$observationBytes; Observation=$observation; InventoryFrames=$envelope.inventory_frames }
    }
    catch {
        $reason = $_.Exception.Message
        if ($reason -cnotin @('encoding_invalid','duplicate_key','shape_invalid')) { $reason = 'shape_invalid' }
        return New-C1bInventoryParseFailure $reason
    }
}

function Test-C1bInventoryCounts {
    param([Parameter(Mandatory)]$Result)
    $reason = $null
    try {
        if (-not $Result.Valid) { $reason = $Result.ReasonCode }
        elseif ($Result.Observation.frames -isnot [array] -or $Result.Observation.frames.Count -ne 2) {
            $reason = 'observation_invalid'
        }
        else {
            for ($index = 0; $index -lt 2; $index++) {
                $frame = $Result.InventoryFrames[$index]
                $observed = $Result.Observation.frames[$index]
                $token = @('c1','c2')[$index]
                if ($observed.capture_id -isnot [string] -or $observed.capture.token -isnot [string] -or
                    $observed.a11y_windows -isnot [array] -or $observed.windows_truncated -isnot [bool]) {
                    $reason = 'observation_invalid'; break
                }
                if ($frame.capture_token -cne $token -or $observed.capture.token -cne $token -or
                    $frame.capture_id -cne $observed.capture_id) { $reason = 'capture_binding_mismatch'; break }
                $sum = 0L
                foreach ($key in $script:C1bInventoryStopKeys) { $sum += [long]$frame.first_stop_counts.$key }
                $a = [long]$frame.attempted_count; $s = [long]$frame.saved_count; $d = [long]$frame.dropped_count
                $state = "$($frame.enumeration_status)/$($frame.count_status)"
                if ($state -ceq 'complete/exact') {
                    if ($null -eq $frame.input_count -or $null -eq $frame.unattempted_count) { $reason = 'shape_invalid'; break }
                    $n = [long]$frame.input_count; $u = [long]$frame.unattempted_count
                    if ($a -ne [Math]::Min($n, [long]$frame.maximum_windows) -or $n -ne $a + $u -or
                        $a -ne $s + $d -or $d -ne $sum -or $s -ne $observed.a11y_windows.Count -or
                        $observed.windows_truncated -ne ($u -gt 0 -or $d -gt 0)) { $reason = 'count_mismatch'; break }
                }
                elseif ($state -ceq 'failed/unavailable') {
                    if ($null -ne $frame.input_count -or $null -ne $frame.unattempted_count) { $reason = 'shape_invalid'; break }
                    if ($a -ne 0 -or $s -ne 0 -or $d -ne 0 -or $sum -ne 0 -or
                        $observed.a11y_windows.Count -ne 0 -or -not $observed.windows_truncated) { $reason = 'count_mismatch'; break }
                }
                elseif ($state -ceq 'complete/overflow') {
                    if ($null -ne $frame.input_count -or $null -ne $frame.unattempted_count) { $reason = 'shape_invalid'; break }
                    $reason = if ($a -ne $s + $d -or $d -ne $sum -or $s -ne $observed.a11y_windows.Count) {
                        'count_mismatch'
                    } else { 'count_overflow' }
                    break
                }
                else { $reason = 'shape_invalid'; break }
            }
        }
    }
    catch { $reason = 'observation_invalid' }
    return [pscustomobject]@{ Valid=($null -eq $reason); ReasonCode=$reason }
}
