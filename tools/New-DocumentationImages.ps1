<#
.SYNOPSIS
    Transport Sizer - pictures of the window for the documentation (PNG), light and dark.

.DESCRIPTION
    Builds the window with a scenario and a calibration, shows it off screen, lets WPF lay it out and
    renders it to PNG files (RenderTargetBitmap). Nothing is clicked and no report is written.

.EXAMPLE
    .\tools\New-DocumentationImages.ps1 -Scenario .\examples\Edge-Internet.json -Calibration .\tests\data\Calibration-Test.json -OutputPath .\docs\images

.NOTES
    Author  : Nicolas Fabert
    Version : 1.9.0
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Scenario,
    [string]$Calibration,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [ValidateSet('Light', 'Dark')][string[]]$Theme = @('Light', 'Dark'),
    [int]$Width = 1440,
    [int]$Height = 940,
    [string]$Prefix = 'gui'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'TransportSizer.psd1') -Force
if (-not (Test-Path -LiteralPath $OutputPath)) { [void](New-Item -ItemType Directory -Path $OutputPath -Force) }

$loaded = $null
if ($Scenario) { $loaded = Import-TsScenario -Path $Scenario }
if ($Calibration) {
    if (-not $loaded) { $loaded = Get-TsDefaultScenario -Role Edge }
    $loaded.Calibration = Import-TsCalibration -Path $Calibration
}

foreach ($look in $Theme) {
    $form = New-TsSizerForm -Scenario $loaded -OutputPath '.\reports' -Theme $look
    $window = $form.Form
    $window.WindowStartupLocation = 'Manual'
    $window.Left = -20000
    $window.Top = 0
    $window.Width = $Width
    $window.Height = $Height
    $window.ShowInTaskbar = $false
    $window.Show()
    $frame = [Windows.Threading.DispatcherFrame]::new()
    $timer = [Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(900)
    $timer.Add_Tick({ $timer.Stop(); $frame.Continue = $false })
    $timer.Start()
    [Windows.Threading.Dispatcher]::PushFrame($frame)
    $content = $window.Content
    $dpi = [Windows.Media.VisualTreeHelper]::GetDpi($window)
    $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new([int]($content.ActualWidth * $dpi.DpiScaleX), [int]($content.ActualHeight * $dpi.DpiScaleY), 96 * $dpi.DpiScaleX, 96 * $dpi.DpiScaleY, [Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($content)
    $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $path = Join-Path $OutputPath ('{0}-{1}.png' -f $Prefix, $look.ToLowerInvariant())
    $stream = [IO.File]::Create($path)
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
    $window.Close()
    Get-Item -LiteralPath $path
}
