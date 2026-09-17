#requires -Version 7.4
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.7.1' }

BeforeAll {
    Set-StrictMode -Version Latest
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $script:modulePath = Join-Path $repoRoot 'modules/ALZSecurity.psm1'
    Import-Module $script:modulePath -Force
}

AfterAll {
    Remove-Module ALZSecurity -ErrorAction SilentlyContinue
}

Describe 'ConvertTo-ALZPlainText' {
    It 'returns the original plain text for an ordinary synthetic secret' {
        $expected = 'SYNTH-Ordinary-Secret-123'
        $secure = ConvertTo-SecureString $expected -AsPlainText -Force

        ConvertTo-ALZPlainText -Secure $secure | Should -BeExactly $expected
    }

    It 'returns an empty string for an empty SecureString instance' {
        $secure = [System.Security.SecureString]::new()

        $actual = ConvertTo-ALZPlainText -Secure $secure

        $actual | Should -BeExactly ''
    }

    It 'preserves special characters in a synthetic secret' {
        $expected = ('SYNTH-[[]]-"-\' + "`n" + '-END')
        $secure = ConvertTo-SecureString $expected -AsPlainText -Force

        ConvertTo-ALZPlainText -Secure $secure | Should -BeExactly $expected
    }
}

Describe 'Clear-ALZSecretFromFile' {
    It 'redacts every occurrence of a synthetic secret and preserves unrelated content' {
        $secret = 'SYNTH-SECRET-[[]]-!@#-123'
        $path = Join-Path $TestDrive 'transcript.log'
        @(
            'prefix line'
            "token one: $secret"
            'keep this line'
            "token two: $secret"
            'suffix line'
        ) | Set-Content -Path $path -Encoding UTF8

        Clear-ALZSecretFromFile -Path $path -Secret $secret

        $content = Get-Content -Path $path -Raw
        $content | Should -Not -Match ([regex]::Escape($secret))
        ([regex]::Matches($content, [regex]::Escape('***REDACTED***'))).Count | Should -Be 2
        $content | Should -Match 'prefix line'
        $content | Should -Match 'keep this line'
        $content | Should -Match 'suffix line'
    }

    It 'does nothing when the file is missing' {
        $path = Join-Path $TestDrive 'missing.log'

        { Clear-ALZSecretFromFile -Path $path -Secret 'SYNTH-MISSING-SECRET' } | Should -Not -Throw
        Test-Path $path | Should -BeFalse
    }

    It 'does nothing when the secret is empty' {
        $path = Join-Path $TestDrive 'no-redaction.log'
        $original = "safe line`nSYNTH-visible-value`n"
        [System.IO.File]::WriteAllText($path, $original, [System.Text.UTF8Encoding]::new($false))

        Clear-ALZSecretFromFile -Path $path -Secret ''

        [System.IO.File]::ReadAllText($path) | Should -BeExactly $original
    }
}

Describe 'Format-ALZSafeValue' {
    It 'returns an empty string for null input' {
        Format-ALZSafeValue -Value $null | Should -BeExactly ''
    }

    It 'returns an empty string for an empty input string' {
        Format-ALZSafeValue -Value '' | Should -BeExactly ''
    }

    It 'removes quote characters' {
        Format-ALZSafeValue -Value 'SYNTH-"quoted"-value' | Should -BeExactly 'SYNTH-quoted-value'
    }

    It 'removes newline characters' {
        Format-ALZSafeValue -Value "SYNTH-line1`r`nline2" | Should -BeExactly 'SYNTH-line1line2'
    }

    It 'removes backslash characters' {
        Format-ALZSafeValue -Value 'SYNTH-path\segment\leaf' | Should -BeExactly 'SYNTH-pathsegmentleaf'
    }

    It 'sanitizes mixed quote, newline, and backslash input and trims the result' {
        $value = ('  SYNTH-"quoted\value"' + "`n  ")

        Format-ALZSafeValue -Value $value | Should -BeExactly 'SYNTH-quotedvalue'
    }
}
