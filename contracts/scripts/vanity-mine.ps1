#!/usr/bin/env pwsh
# vanity-mine.ps1 — grind userSalt for 0x4663 CREATE2 prefix (docs/03)
# Prefer: node contracts/scripts/vanity-mine.mjs (same algorithm)
# Usage:
#   .\contracts\scripts\vanity-mine.ps1 -Factory 0xF -Deployer 0xD -InitCodeHash 0xH
#   .\contracts\scripts\vanity-mine.ps1 -Mode eoa -Deployer 0xD -InitCodeHash 0xH
param(
  [ValidateSet('factory','eoa')][string]$Mode = 'factory',
  [string]$Factory,
  [Parameter(Mandatory=$true)][string]$Deployer,
  [Parameter(Mandatory=$true)][string]$InitCodeHash,
  [long]$Max = 1000000
)

$ErrorActionPreference = 'Stop'
$node = Join-Path $PSScriptRoot 'vanity-mine.mjs'
$args = @($node, '--mode', $Mode, '--deployer', $Deployer, '--initCodeHash', $InitCodeHash, '--max', "$Max")
if ($Mode -eq 'factory') {
  if (-not $Factory) { throw '-Factory required in factory mode' }
  $args += @('--factory', $Factory)
}
& node @args
