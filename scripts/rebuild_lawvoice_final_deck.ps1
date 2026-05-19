Add-Type -AssemblyName System.Drawing
$ErrorActionPreference = 'Stop'

$source = 'F:\GitHub\vangZ_strict_patched_plus_voice_assistant\docs\defense\LawVoice_Defense_Presentation_EN_revised.pptx'
$target = 'F:\GitHub\vangZ_strict_patched_plus_voice_assistant\docs\defense\LawVoice_Defense_Presentation_EN_final.pptx'
$pdf = 'F:\GitHub\vangZ_strict_patched_plus_voice_assistant\docs\defense\LawVoice_Defense_Presentation_EN_final.pdf'
$renderDir = 'F:\GitHub\vangZ_strict_patched_plus_voice_assistant\docs\defense\_render_final'

$fontTitle = 'HSE Slab Black'
$fontLabel = 'HSE Slab Regular'
$fontBody = 'HSE Sans Regular'
$fontChrome = 'HSESans-SemiBold'

function New-Rgb([int]$r, [int]$g, [int]$b) {
  return $r + (256 * $g) + (65536 * $b)
}

$lightText = New-Rgb 248 250 252
$softLight = New-Rgb 214 228 245
$darkText = New-Rgb 24 43 73
$accentDark = New-Rgb 40 73 122

function Get-ShapeText($shape) {
  return [string]$shape.TextFrame.TextRange.Text
}

function Get-ShapeRole([int]$slideIndex, [string]$text, [double]$currentSize) {
  $trim = $text.Trim()
  if (-not $trim) { return 'skip' }
  if ($slideIndex -eq 1 -and $currentSize -ge 20) { return 'title' }
  if ($slideIndex -eq 18 -and $currentSize -ge 16) { return 'title' }
  if ($trim -match '^[0-9]{1,2}$') { return 'chrome' }
  if ($trim -in @('Faculty of Computer Science', 'Data Science and Business Analytics', 'LawVoice: Voice-Based Legal Assistant')) { return 'chrome' }
  if ($currentSize -ge 22) { return 'title' }
  if ($currentSize -le 9.5) { return 'chrome' }
  if ($trim.Length -le 38 -and $currentSize -le 18.5) { return 'label' }
  return 'body'
}

function Get-TargetSize([string]$role, [string]$text, [double]$currentSize, [int]$slideIndex) {
  $trim = $text.Trim()
  $len = $trim.Length
  $lines = ([regex]::Matches($trim, "`r?`n")).Count + 1

  switch ($role) {
    'title' {
      if ($slideIndex -eq 1) { return 20.5 }
      if ($slideIndex -eq 18) { return 18.5 }
      if ($len -gt 34) { return 21.5 }
      return 22.5
    }
    'chrome' {
      if ($trim -match '^[0-9]{1,2}$' -and $currentSize -ge 10) { return 9.5 }
      if ($currentSize -le 8.5) { return 7.5 }
      return 8.5
    }
    'label' {
      if ($len -le 12) { return 14.0 }
      if ($len -le 22) { return 13.2 }
      return 12.2
    }
    default {
      if ($len -gt 260 -or $lines -gt 8) { return 12.2 }
      if ($len -gt 200 -or $lines -gt 6) { return 13.0 }
      if ($len -gt 140 -or $lines -gt 4) { return 13.8 }
      if ($len -gt 90 -or $lines -gt 3) { return 14.6 }
      return 15.2
    }
  }
}

function Get-FontName([string]$role) {
  switch ($role) {
    'title' { return $fontTitle }
    'label' { return $fontLabel }
    'chrome' { return $fontChrome }
    default { return $fontBody }
  }
}

function Get-AverageLuminance($bitmap, $shape, [double]$slideWidth, [double]$slideHeight) {
  $left = [Math]::Max(0, [Math]::Min($bitmap.Width - 1, [int](($shape.Left / $slideWidth) * $bitmap.Width)))
  $top = [Math]::Max(0, [Math]::Min($bitmap.Height - 1, [int](($shape.Top / $slideHeight) * $bitmap.Height)))
  $right = [Math]::Max($left + 1, [Math]::Min($bitmap.Width, [int]((($shape.Left + $shape.Width) / $slideWidth) * $bitmap.Width)))
  $bottom = [Math]::Max($top + 1, [Math]::Min($bitmap.Height, [int]((($shape.Top + $shape.Height) / $slideHeight) * $bitmap.Height)))

  $width = [Math]::Max(1, $right - $left)
  $height = [Math]::Max(1, $bottom - $top)
  $xs = @(0.08, 0.50, 0.92)
  $ys = @(0.08, 0.50, 0.92)
  $samples = New-Object System.Collections.Generic.List[double]

  foreach ($xf in $xs) {
    foreach ($yf in $ys) {
      $x = [Math]::Min($bitmap.Width - 1, $left + [int]([Math]::Round($width * $xf)))
      $y = [Math]::Min($bitmap.Height - 1, $top + [int]([Math]::Round($height * $yf)))
      $c = $bitmap.GetPixel($x, $y)
      $lum = (0.2126 * $c.R) + (0.7152 * $c.G) + (0.0722 * $c.B)
      $samples.Add($lum)
    }
  }

  return ($samples | Measure-Object -Average).Average
}

function Get-TextColor([string]$role, [double]$luminance) {
  $darkBackground = $luminance -lt 145
  if ($darkBackground) {
    if ($role -eq 'chrome' -or $role -eq 'label') { return $softLight }
    return $lightText
  }

  if ($role -eq 'chrome' -or $role -eq 'label') { return $accentDark }
  return $darkText
}

if (-not (Test-Path $source)) {
  throw "Source file not found: $source"
}

$fontRegistryHit = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts').PSObject.Properties |
  Where-Object { $_.Name -like 'HiSier*' }
if (-not $fontRegistryHit) {
  Write-Output 'No installed HiSier* fonts found. Using available HSE Sans / HSE Slab family as the local HSE-branded fallback.'
}

Copy-Item $source $target -Force
Remove-Item $renderDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $renderDir | Out-Null

$ppt = $null
$pres = $null
try {
  $ppt = New-Object -ComObject PowerPoint.Application
  $pres = $ppt.Presentations.Open($target, $false, $false, $false)
  $slideWidth = [double]$pres.PageSetup.SlideWidth
  $slideHeight = [double]$pres.PageSetup.SlideHeight

  foreach ($slide in $pres.Slides) {
    $pngPath = Join-Path $renderDir (('slide-{0:D2}.png') -f $slide.SlideIndex)
    $slide.Export($pngPath, 'PNG', 2000, 1125)
  }

  foreach ($slide in $pres.Slides) {
    $pngPath = Join-Path $renderDir (('slide-{0:D2}.png') -f $slide.SlideIndex)
    $bitmap = [System.Drawing.Bitmap]::FromFile($pngPath)
    try {
      foreach ($shape in $slide.Shapes) {
        if (-not $shape.HasTextFrame) { continue }
        if (-not $shape.TextFrame.HasText) { continue }

        $text = Get-ShapeText $shape
        $trim = $text.Trim()
        if (-not $trim) { continue }

        $currentSize = [double]$shape.TextFrame.TextRange.Font.Size
        $role = Get-ShapeRole $slide.SlideIndex $trim $currentSize
        if ($role -eq 'skip') { continue }

        $targetSize = Get-TargetSize $role $trim $currentSize $slide.SlideIndex
        $fontName = Get-FontName $role
        $luminance = Get-AverageLuminance $bitmap $shape $slideWidth $slideHeight
        $fontColor = Get-TextColor $role $luminance

        $shape.TextFrame2.WordWrap = -1
        $shape.TextFrame2.AutoSize = 2
        $shape.TextFrame.TextRange.Font.Name = $fontName
        $shape.TextFrame.TextRange.Font.Size = $targetSize
        $shape.TextFrame.TextRange.Font.Color.RGB = $fontColor
        $shape.TextFrame.TextRange.ParagraphFormat.SpaceAfter = 0
        $shape.TextFrame.TextRange.ParagraphFormat.SpaceWithin = 1
      }
    } finally {
      $bitmap.Dispose()
    }
  }

  $pres.Save()
  if (Test-Path $pdf) { Remove-Item $pdf -Force }
  $pres.SaveAs($pdf, 32)
  Write-Output "Saved presentation: $target"
  Write-Output "Saved PDF: $pdf"
} finally {
  if ($pres) { $pres.Close() }
  if ($ppt) { $ppt.Quit() }
}
