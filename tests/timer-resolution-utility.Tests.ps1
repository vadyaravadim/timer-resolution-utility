BeforeDiscovery {
    $script:isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $script:bcdValueCases = @(
        @{ Name = 'disabledynamictick'; Ok = $true; Expect = 'Yes' }
        @{ Name = 'useplatformtick'; Ok = $true; Expect = 'No' }
        @{ Name = 'useplatformclock'; Ok = $true; Expect = $null }
        @{ Name = 'useplatform'; Ok = $true; Expect = $null }
        @{ Name = 'disabledynamictick'; Ok = $false; Expect = $null }
    )
    $script:onWords = @(
        'Yes'
        ([string][char]0x0414 + [char]0x0430)
        'Oui'
        'Ja'
        ('S' + [char]0x00ED)
        'Evet'
    )
    $script:offWords = @(
        'No'
        ([string][char]0x041D + [char]0x0435 + [char]0x0442)
        'Non'
        'Nein'
        ('N' + [char]0x00E3 + 'o')
        ('Hay' + [char]0x0131 + 'r')
    )
    $script:onCases = @($onWords | ForEach-Object { @{ Word = $_ } })
    $script:offCases = @($offWords | ForEach-Object { @{ Word = $_ } })
}

BeforeAll {
    $script:scriptPath = Join-Path $PSScriptRoot '..\timer-resolution-utility.ps1'
    $script:scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)

    function Find-ScriptNode([scriptblock]$Predicate) {
        $scriptAst.Find($Predicate, $true)
    }

    function Get-ShippedFunctionText([string]$Name) {
        $fn = Find-ScriptNode { param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }
        if (-not $fn) { throw "timer-resolution-utility.ps1 defines no $Name" }
        $fn.Extent.Text
    }
}

Describe 'PSScriptInfo version placeholder' {
    It 'is exactly .VERSION 0.0.0, the line release.yml stamps' {
        $lines = @(Select-String -LiteralPath $scriptPath -Pattern '^\.VERSION\b' | ForEach-Object Line)
        $lines.Count | Should -Be 1
        $lines[0] | Should -BeExactly '.VERSION 0.0.0'
    }
}

Describe 'the irm | iex rerun forwards the mode switches to powershell.exe -File' {
    BeforeAll {
        $script:rerunCode = {
            param([string]$StubBody, [object[]]$Bound)
            $forwarder = Get-ShippedFunctionText 'Get-ForwardedSwitchList'
            $bootstrap = Find-ScriptNode { param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq '-not $PSCommandPath' }
            $rerun = @($bootstrap.Clauses[0].Item2.Statements | Where-Object { $_.Extent.Text -match '^(\$fwd\s*=|powershell\s)' })
            $rerun.Count | Should -Be 2
            $stub = Join-Path $TestDrive 'rerun-stub.ps1'
            Set-Content -LiteralPath $stub -Value $StubBody -Encoding Ascii
            $code = @('param($Status, $Measure, $Samples, $saved)', $forwarder) + @($rerun | ForEach-Object { $_.Extent.Text })
            & ([scriptblock]::Create($code -join "`n")) $Bound[0] $Bound[1] $Bound[2] $stub
        }
        $script:stubBody = 'param([switch]$Status, [switch]$Measure, [int]$Samples = 30, [switch]$Undo, [switch]$Reset) "Status=$Status Measure=$Measure Samples=$Samples"'
    }

    It 'binds -Status in the rerun when it is the only forwarded switch' {
        & $rerunCode $stubBody @($true, $false, 30) | Should -Be 'Status=True Measure=False Samples=30'
    }

    It 'binds -Measure and -Samples in the rerun' {
        & $rerunCode $stubBody @($false, $true, 5) | Should -Be 'Status=False Measure=True Samples=5'
    }
}

Describe 'Get-ForwardedSwitchList' {
    BeforeAll {
        $script:forwardCode = [scriptblock]::Create('param($Status, $Measure, $Samples, $Undo, $Reset, $Hold, $Elevated, $LogonUser)' + "`n" + (Get-ShippedFunctionText 'Get-ForwardedSwitchList') + "`n" + '@(Get-ForwardedSwitchList)')
        $help = $scriptAst.GetHelpContent()
        $script:documented = if ($help -and $help.Parameters.Count) {
            @($help.Parameters.Keys)
        } else {
            @(Select-String -LiteralPath $scriptPath -Pattern '^\.PARAMETER\s+(\w+)' | ForEach-Object { $_.Matches[0].Groups[1].Value })
        }
        $script:documentedSwitches = @($scriptAst.ParamBlock.Parameters |
            Where-Object { $_.StaticType -eq [System.Management.Automation.SwitchParameter] -and $_.Name.VariablePath.UserPath -in $documented } |
            ForEach-Object { $_.Name.VariablePath.UserPath })
    }

    It 'forwards every documented switch and -Samples when -Measure is given' {
        $documentedSwitches.Count | Should -BeGreaterThan 0
        $bound = @{ Hold = $true; Elevated = $true; LogonUser = 'DOM\user'; Samples = 7 }
        foreach ($name in $documentedSwitches) { $bound[$name] = $true }
        $actual = @(& $forwardCode @bound | ForEach-Object { "$_" } | Sort-Object) -join ' '
        $expected = @(($documentedSwitches | ForEach-Object { "-$_" }) + '-Samples' + '7' | Sort-Object) -join ' '
        $actual | Should -BeExactly $expected
    }

    It 'forwards -Samples only together with -Measure' {
        $actual = @(& $forwardCode -Status $true -Samples 7 | ForEach-Object { "$_" }) -join ' '
        $actual | Should -BeExactly '-Status'
    }

    It 'never forwards the internal -Hold, -Elevated or -LogonUser' {
        $actual = @(& $forwardCode -Status $true -Measure $true -Samples 7 -Undo $true -Reset $true -Hold $true -Elevated $true -LogonUser 'DOM\user' | ForEach-Object { "$_" })
        $actual | Should -Not -Contain '-Hold'
        $actual | Should -Not -Contain '-Elevated'
        $actual | Should -Not -Contain '-LogonUser'
    }
}

Describe 'Get-BcdValue' {
    BeforeAll {
        . ([scriptblock]::Create((Get-ShippedFunctionText 'Get-BcdValue')))
        $script:bcdSample = @(
            'Windows Boot Loader'
            '-------------------'
            'identifier              {current}'
            'device                  partition=C:'
            'disabledynamictick      Yes'
            'useplatformtick         No'
        )
    }

    It 'reads <Name> as <Expect> when the BCD store was read: <Ok>' -ForEach $bcdValueCases {
        $script:bcdOk = $Ok
        $script:bcdRaw = $bcdSample
        $result = Get-BcdValue $Name
        if ($null -eq $Expect) { $result | Should -BeNullOrEmpty } else { $result | Should -BeExactly $Expect }
    }
}

Describe 'ConvertTo-BcdBool' {
    BeforeAll {
        . ([scriptblock]::Create((Get-ShippedFunctionText 'Test-BcdOn')))
        . ([scriptblock]::Create((Get-ShippedFunctionText 'ConvertTo-BcdBool')))
    }

    It 'canonicalizes the on word <Word> to yes' -ForEach $onCases {
        ConvertTo-BcdBool $Word | Should -BeExactly 'yes'
    }

    It 'canonicalizes the off word <Word> to no' -ForEach $offCases {
        ConvertTo-BcdBool $Word | Should -BeExactly 'no'
    }

    It 'keeps $null as $null' {
        ConvertTo-BcdBool $null | Should -BeNullOrEmpty
    }

    It 'passes an unrecognized value through unchanged' {
        ConvertTo-BcdBool '{default}' | Should -BeExactly '{default}'
    }
}

Describe 'Invoke-Bcdedit against a stub bcdedit' {
    BeforeAll {
        . ([scriptblock]::Create((Get-ShippedFunctionText 'Invoke-Bcdedit')))
        $script:stub = Join-Path $TestDrive 'bcdedit.cmd'
        Set-Content -LiteralPath $stub -Value "@echo stub bcdedit %*`r`n@exit /b %STUB_EXIT%" -Encoding Ascii
        $script:savedPath = $env:PATH
        $script:savedExit = $env:STUB_EXIT
        $env:PATH = "$TestDrive;$env:PATH"
        if ((Get-Command bcdedit).Source -ne $stub) {
            throw 'the bcdedit stub is not first on PATH: the test would run the real bcdedit'
        }
    }

    AfterAll {
        $env:PATH = $savedPath
        $env:STUB_EXIT = $savedExit
    }

    It 'returns the output of a call that exits 0' {
        $env:STUB_EXIT = '0'
        Invoke-Bcdedit /set disabledynamictick yes | Should -Be 'stub bcdedit /set disabledynamictick yes'
    }

    It 'throws with the output when the call exits nonzero' {
        $env:STUB_EXIT = '1'
        { Invoke-Bcdedit /set disabledynamictick yes } | Should -Throw '*stub bcdedit*'
    }
}

Describe 'the grid check on Windows Server Core' {
    BeforeAll {
        $script:copy = Join-Path $TestDrive 'timer-resolution-utility.ps1'
        Copy-Item -LiteralPath $scriptPath -Destination $copy
        $script:stub = Join-Path $TestDrive 'bcdedit.cmd'
        Set-Content -LiteralPath $stub -Value "@echo off`r`necho identifier              {current}`r`nexit /b 0" -Encoding Ascii
        $script:savedPath = $env:PATH
        $env:PATH = "$TestDrive;$env:PATH"
        if ((Get-Command bcdedit).Source -ne $stub) {
            throw 'the bcdedit stub is not first on PATH: the whole-script test would change this machine''s boot configuration'
        }
        Mock Get-CimInstance { 'mock reached' } -ParameterFilter { $ClassName -eq 'Win32_PesterMockProbe' }
        $probe = Join-Path $TestDrive 'mock-probe.ps1'
        Set-Content -LiteralPath $probe -Value 'Get-CimInstance Win32_PesterMockProbe -ErrorAction SilentlyContinue' -Encoding Ascii
        $probeResult = $null
        try { $probeResult = & $probe } catch { $probeResult = $null }
        if ($probeResult -ne 'mock reached') {
            throw 'Pester mocks do not reach a script run with &: the whole-script tests would touch this machine'
        }
    }

    AfterAll {
        $env:PATH = $savedPath
    }

    It 'says so and stops before it opens the grid' -Skip:(-not $isAdmin) {
        Mock Get-ItemProperty { [pscustomobject]@{ ServerCore = 1 } } -ParameterFilter { "$Path$LiteralPath" -like '*\Windows NT\CurrentVersion\Server\ServerLevels' }
        Mock Test-Path { $true } -ParameterFilter { "$Path$LiteralPath" -like '*\Windows NT\CurrentVersion\Server\ServerLevels' }
        Mock Get-ScheduledTask { }
        Mock Get-PnpDevice { }
        Mock Out-GridView { }
        Mock Read-Host { }
        Mock Start-Process { }
        Mock Register-ScheduledTask { }
        Mock Unregister-ScheduledTask { }
        Mock Start-ScheduledTask { }
        Mock Stop-ScheduledTask { }
        Mock Export-ScheduledTask { }
        Mock New-Item { }
        Mock New-ItemProperty { }
        Mock Set-ItemProperty { }
        Mock Remove-ItemProperty { }
        Mock Set-Content { }
        Mock Rename-Item { }
        Mock Start-Sleep { }
        Mock Write-Host { }
        & $copy
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { "$Object" -like 'Out-GridView is not available*' }
        Should -Invoke Out-GridView -Times 0 -Exactly -Because 'Server Core cannot open the grid window'
    }
}

Describe 'PSScriptInfo metadata for the PowerShell Gallery' {
    BeforeAll {
        $script:infoValue = {
            param([string]$Key)
            $line = @(Select-String -LiteralPath $scriptPath -Pattern "^\.$Key\b" | ForEach-Object Line)
            $line.Count | Should -Be 1 -Because "PSScriptInfo has exactly one .$Key line"
            ($line[0] -replace "^\.$Key\s*", '').Trim()
        }
    }

    It 'PSScriptInfo copyright is the LICENSE copyright line' {
        $license = Join-Path $PSScriptRoot '..\LICENSE'
        & $infoValue 'COPYRIGHT' | Should -BeExactly (Get-Content -LiteralPath $license)[2]
    }

    It 'PSScriptInfo tags list PSEdition_Desktop and PSEdition_Core' {
        $tags = (& $infoValue 'TAGS') -split '\s+'
        $tags | Should -Contain 'PSEdition_Desktop'
        $tags | Should -Contain 'PSEdition_Core'
    }

    It 'PSScriptInfo release notes are the CHANGELOG of .PROJECTURI' {
        & $infoValue 'RELEASENOTES' | Should -BeExactly ((& $infoValue 'PROJECTURI') + '/blob/main/CHANGELOG.md')
    }
}
