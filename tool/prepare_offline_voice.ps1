$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$target = Join-Path $repo 'android/app/offline-tts'
$voices = Join-Path $target 'aishell-assets/tts'
New-Item -ItemType Directory -Path $voices -Force | Out-Null

function Get-VerifiedFile($url, $path, $sha256) {
    if ((Test-Path -LiteralPath $path -PathType Leaf) -and
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq $sha256) { return }
    & curl.exe -fL --retry 3 --connect-timeout 20 --max-time 600 -o "$path.partial" $url
    if ($LASTEXITCODE -ne 0) { throw "Download failed: $url" }
    if ((Get-FileHash -LiteralPath "$path.partial" -Algorithm SHA256).Hash -ne $sha256) {
        throw "SHA256 mismatch: $path"
    }
    Move-Item -LiteralPath "$path.partial" -Destination $path -Force
}

$release = 'https://github.com/k2-fsa/sherpa-onnx/releases/download'
$aarName = 'sherpa-onnx-static-link-onnxruntime-2.0.1.aar'
$modelName = 'vits-icefall-zh-aishell3.tar.bz2'
$model = Join-Path $target $modelName
Get-VerifiedFile "$release/v2.0.1/$aarName" (Join-Path $target $aarName) '07e042d97f3a6bd5b7fe74d4eef0513dc01a714b16c15a903250095aba43a575'
Get-VerifiedFile "$release/tts-models/$modelName" $model 'ab468db3a3308cdd861495e0db2f25d79418a0c00639f74944c7cdf5dd8c6ec1'
Get-VerifiedFile 'https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v2.0.1/LICENSE' (Join-Path $voices 'sherpa-onnx-APACHE-LICENSE.txt') 'cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30'
Get-VerifiedFile 'https://raw.githubusercontent.com/microsoft/onnxruntime/v1.28.2/LICENSE' (Join-Path $voices 'onnx-runtime-MIT-LICENSE.txt') '2f07c72751aed99790b8a4869cf2311df85a860b22ded05fa22803587a48922c'

$oldPath = $env:Path
Push-Location $target
try {
    $tar = "$env:SystemRoot/System32/tar.exe"
    if (-not (Get-Command bzip2.exe -ErrorAction SilentlyContinue)) {
        $gitInstall = Split-Path -Parent (Split-Path -Parent (Get-Command git.exe).Source)
        $gitTools = Join-Path $gitInstall 'usr/bin'
        $env:Path = "$gitTools;$oldPath"
        $tar = Join-Path $gitTools 'tar.exe'
    }
    if (-not (Get-Command bzip2.exe -ErrorAction SilentlyContinue)) {
        throw 'Install Git for Windows or add bzip2.exe to PATH to extract the voice archive.'
    }
    $members = @('model.onnx', 'lexicon.txt', 'tokens.txt', 'phone.fst', 'date.fst', 'number.fst') |
        ForEach-Object { "vits-icefall-zh-aishell3/$_" }
    & $tar -xjf $modelName -C 'aishell-assets/tts' @members
    if ($LASTEXITCODE -ne 0) { throw 'Offline voice extraction failed.' }
} finally {
    Pop-Location
    $env:Path = $oldPath
}

@'
Offline narration uses Sherpa-ONNX v2.0.1 (Apache License 2.0).
https://github.com/k2-fsa/sherpa-onnx/tree/v2.0.1
ONNX Runtime (MIT License): https://github.com/microsoft/onnxruntime

The Mandarin voices use the Icefall VITS AISHELL-3 model (Apache License 2.0).
https://huggingface.co/csukuangfj/icefall-tts-aishell3-vits-low-2024-04-06
AISHELL-3 Mandarin speech corpus: Beijing Shell Shell Technology Co., Ltd.
https://www.openslr.org/93/
'@ | Set-Content -LiteralPath (Join-Path $voices 'offline-voice-attribution.txt') -Encoding UTF8
