###########################################################################
# ALZSECURITY.PSM1
# SECRET HANDLING AND INPUT SANITIZATION HELPERS
###########################################################################
# Purpose: Centralize safe secret conversion and value sanitization so no
#          token leaks into unmanaged memory, transcripts, or generated files.
# Author: Zac Larsen
# Date: Created for the ALZ Accelerator orchestrator app
#
# Description:
# 1. ConvertTo-ALZPlainText converts a SecureString and frees the BSTR.
# 2. Clear-ALZSecretFromFile scrubs a secret value out of a file (transcript).
# 3. Format-ALZSafeValue strips characters that could break generated YAML.
#
# Prerequisites:
# - PowerShell 7.4+
#
# Usage: Imported by Start-ALZDelivery.ps1 via Import-Module.
###########################################################################

function ConvertTo-ALZPlainText {
    param([securestring]$Secure)
    if (-not $Secure) { return $null }
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        # Zero and free the unmanaged copy so the plaintext does not linger.
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Clear-ALZSecretFromFile {
    param([string]$Path, [string]$Secret)
    if (-not $Secret -or -not (Test-Path $Path)) { return }
    try {
        $content = Get-Content -Path $Path -Raw
        if ($content -and $content.Contains($Secret)) {
            $content.Replace($Secret, '***REDACTED***') | Set-Content -Path $Path -Encoding UTF8
        }
    }
    catch {
        # Best effort: if scrubbing fails, remove the file entirely rather than leave a secret.
        Remove-Item -Path $Path -Force -ErrorAction SilentlyContinue
    }
}

function Format-ALZSafeValue {
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    # Remove characters that could break a double-quoted YAML scalar or inject content.
    return ($Value -replace '["\r\n\\]', '').Trim()
}

Export-ModuleMember -Function ConvertTo-ALZPlainText, Clear-ALZSecretFromFile, Format-ALZSafeValue
