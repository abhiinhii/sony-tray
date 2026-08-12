<#
.SYNOPSIS
    Generates the Sony Tray application icon at src/SonyTray/Assets/app.ico.

.DESCRIPTION
    Draws a 256x256 badge in memory and writes it out as a minimal single-entry
    .ico container whose one image is a PNG (Windows Vista+ supports PNG-compressed
    ICO entries, which keeps this file small and avoids hand-rolling a BMP/DIB mask).

    Visual language (original artwork - see .superpowers/sdd/task-13-brief.md and
    the amended global constraint prohibiting imitation of Sony's Headphones Connect
    icon or any Sony logo):
      - Rounded-square badge, r=48, filled with a vertical linear gradient
        #1976D2 (top) -> #0D47A1 (bottom).
      - White headphone glyph: a rounded-cap arc headband plus two rounded-rect
        ear cups, mirrored left/right of center. The brief gives one ear-cup
        rect (40,140,52,76,r=18); the second cup is that same rect mirrored
        horizontally (x' = 256 - 40 - 52 = 164) so the glyph reads as a pair of
        headphones rather than two cups stacked on top of each other.
    TrayIconFactory.cs (32px runtime tray icon) and this script intentionally
    share the same proportions, scaled by 32/256, so the tray glyph and the
    exe/window icon read as the same mark at different sizes.

.NOTES
    Re-run whenever the icon design changes: `pwsh -File tooling/make-icon.ps1`.
    No external dependencies - only System.Drawing, already required by the
    WPF/.NET Desktop runtime this repo targets.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing

function New-RoundedRectPath {
    param(
        [single]$X,
        [single]$Y,
        [single]$Width,
        [single]$Height,
        [single]$Radius
    )
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $Radius * 2
    $path.AddArc($X, $Y, $d, $d, 180, 90)
    $path.AddArc(($X + $Width - $d), $Y, $d, $d, 270, 90)
    $path.AddArc(($X + $Width - $d), ($Y + $Height - $d), $d, $d, 0, 90)
    $path.AddArc($X, ($Y + $Height - $d), $d, $d, 90, 90)
    $path.CloseFigure()
    return $path
}

function Write-UInt16LE {
    param([System.IO.Stream]$Stream, [uint16]$Value)
    $Stream.Write([System.BitConverter]::GetBytes($Value), 0, 2)
}

function Write-UInt32LE {
    param([System.IO.Stream]$Stream, [uint32]$Value)
    $Stream.Write([System.BitConverter]::GetBytes($Value), 0, 4)
}

$size = 256

# --- Draw the badge ---
$bmp = New-Object System.Drawing.Bitmap ($size, $size)
$g = [System.Drawing.Graphics]::FromImage($bmp)
try {
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)

    # Rounded-square gradient background
    $badgePath = New-RoundedRectPath -X 0 -Y 0 -Width $size -Height $size -Radius 48
    $colorTop = [System.Drawing.ColorTranslator]::FromHtml('#1976D2')
    $colorBottom = [System.Drawing.ColorTranslator]::FromHtml('#0D47A1')
    $gradRect = New-Object System.Drawing.RectangleF (0, 0, $size, $size)
    $badgeBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $gradRect, $colorTop, $colorBottom, [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
    $g.FillPath($badgeBrush, $badgePath)
    $badgeBrush.Dispose()
    $badgePath.Dispose()

    # White headphone headband (arc, round caps)
    $band = New-Object System.Drawing.Pen ([System.Drawing.Color]::White, 22)
    $band.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $band.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $g.DrawArc($band, 48, 52, 160, 120, 180, 180)
    $band.Dispose()

    # White ear cups, mirrored left/right
    $earBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
    $leftCup = New-RoundedRectPath -X 40 -Y 140 -Width 52 -Height 76 -Radius 18
    $g.FillPath($earBrush, $leftCup)
    $leftCup.Dispose()
    $rightCup = New-RoundedRectPath -X ($size - 40 - 52) -Y 140 -Width 52 -Height 76 -Radius 18
    $g.FillPath($earBrush, $rightCup)
    $rightCup.Dispose()
    $earBrush.Dispose()
}
finally {
    $g.Dispose()
}

# --- Encode as PNG into memory ---
$pngStream = New-Object System.IO.MemoryStream
$bmp.Save($pngStream, [System.Drawing.Imaging.ImageFormat]::Png)
$pngBytes = $pngStream.ToArray()
$pngStream.Dispose()
$bmp.Dispose()

# --- Wrap the PNG payload in a minimal single-entry ICO container ---
# ICONDIR (6 bytes):        reserved=0 (u16), type=1/icon (u16), count=1 (u16)
# ICONDIRENTRY (16 bytes):  width=0/=256 (u8), height=0/=256 (u8), colors=0 (u8),
#                           reserved=0 (u8), planes=1 (u16), bitcount=32 (u16),
#                           bytesInRes=<png length> (u32), imageOffset=22 (u32)
# followed immediately by the raw PNG bytes.
$icoStream = New-Object System.IO.MemoryStream

Write-UInt16LE -Stream $icoStream -Value 0   # ICONDIR.idReserved
Write-UInt16LE -Stream $icoStream -Value 1   # ICONDIR.idType (1 = icon)
Write-UInt16LE -Stream $icoStream -Value 1   # ICONDIR.idCount

$icoStream.WriteByte(0)                       # bWidth (0 => 256px)
$icoStream.WriteByte(0)                       # bHeight (0 => 256px)
$icoStream.WriteByte(0)                       # bColorCount (0 => no palette)
$icoStream.WriteByte(0)                       # bReserved
Write-UInt16LE -Stream $icoStream -Value 1    # wPlanes
Write-UInt16LE -Stream $icoStream -Value 32   # wBitCount
Write-UInt32LE -Stream $icoStream -Value ([uint32]$pngBytes.Length)  # dwBytesInRes
Write-UInt32LE -Stream $icoStream -Value 22   # dwImageOffset (6 + 16)

$icoStream.Write($pngBytes, 0, $pngBytes.Length)

$repoRoot = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $repoRoot 'src\SonyTray\Assets'
if (-not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}
$outPath = Join-Path $outDir 'app.ico'
[System.IO.File]::WriteAllBytes($outPath, $icoStream.ToArray())
$icoStream.Dispose()

Write-Host "Wrote $outPath ($($pngBytes.Length) byte PNG payload, $((Get-Item $outPath).Length) byte ICO)"

# --- Self-validate: confirm the ICO loads via System.Drawing.Icon ---
$icon = [System.Drawing.Icon]::new($outPath)
Write-Host "Validated: Icon loaded OK ($($icon.Width)x$($icon.Height) reported)"
$icon.Dispose()
