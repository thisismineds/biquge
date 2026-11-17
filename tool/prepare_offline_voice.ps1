param([string]$Python = 'python', [string]$BroadcastSource)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$target = Join-Path $repo 'android/app/offline-tts'
$voices = Join-Path $target 'library-assets/tts'
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
$modelDir = 'kokoro-int8-multi-lang-v1_1'
$modelName = "$modelDir.tar.bz2"
Get-VerifiedFile "$release/v2.0.1/$aarName" (Join-Path $target $aarName) '07e042d97f3a6bd5b7fe74d4eef0513dc01a714b16c15a903250095aba43a575'
Get-VerifiedFile "$release/tts-models/$modelName" (Join-Path $target $modelName) '259c9c8bc906d6078e4e0570421885dabb68b539c2f970fcbb890a58eeaf3e9c'
Get-VerifiedFile 'https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v2.0.1/LICENSE' (Join-Path $voices 'sherpa-onnx-APACHE-LICENSE.txt') 'cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30'
Get-VerifiedFile 'https://raw.githubusercontent.com/microsoft/onnxruntime/v1.28.2/LICENSE' (Join-Path $voices 'onnx-runtime-MIT-LICENSE.txt') '2f07c72751aed99790b8a4869cf2311df85a860b22ded05fa22803587a48922c'

$piper = 'https://hf-mirror.com/rhasspy/piper-voices/resolve/cf910fb59f1d79ab3b625a63993a108751c6c25d/zh/zh_CN/chaowen/medium'
$voiceName = 'zh_CN-chaowen-medium.onnx'
$piperSource = Join-Path $target 'chaowen-source'
$fastVoice = Join-Path $voices 'chaowen-fast'
New-Item -ItemType Directory -Path $piperSource, $fastVoice -Force | Out-Null
Get-VerifiedFile "$piper/$voiceName" (Join-Path $piperSource $voiceName) '83a5268616ad0aa2d3e2b67158824b5e23b24e0973473ce28859c059457b824e'
Get-VerifiedFile "$piper/$voiceName.json" (Join-Path $piperSource "$voiceName.json") '57cf9bf947aa74a4e2ba41e5653b80564061c2f2d47525e8aa28c24817c19f75'
Get-VerifiedFile "$piper/MODEL_CARD" (Join-Path $fastVoice 'MODEL_CARD') '4f9386b738601ccfdcca09ba34deef9b976e60930a010c7d5444716d3cfdb0ef'
Get-VerifiedFile "$release/tts-models/lexicon-zh-g2pw.txt" (Join-Path $fastVoice 'lexicon.txt') '003e76f89fec389ec109b557f47cc315a1ac31a99091f0cc9d15949f9024416b'
$rules = 'https://hf-mirror.com/csukuangfj/icefall-tts-aishell3-vits-low-2024-04-06/resolve/main/data'
Get-VerifiedFile "$rules/phone.fst" (Join-Path $fastVoice 'phone.fst') '1ac2b6fa56b1442320c4de7db08353bab8963a2b57f365eebcdd3a2d3562f8d7'
Get-VerifiedFile "$rules/date.fst" (Join-Path $fastVoice 'date.fst') 'eb8aa079ae3cb81d8f4404992f39d61a0cb990947512b5b8d1e54d1f6980e718'
Get-VerifiedFile "$rules/number.fst" (Join-Path $fastVoice 'number.fst') '743f402181fcfebf76cc2f0546b71fa26476e626fbe4e460fb7b4c3a7a8bd5bd'
if (-not (Test-Path -LiteralPath (Join-Path $fastVoice 'model.onnx') -PathType Leaf) -or
    -not (Test-Path -LiteralPath (Join-Path $fastVoice 'tokens.txt') -PathType Leaf)) {
    & $Python (Join-Path $PSScriptRoot 'prepare_chaowen.py') $piperSource $fastVoice
    if ($LASTEXITCODE -ne 0) {
        throw 'Voice conversion needs Python 3 with onnx==1.23.2 and onnxruntime==1.28.0.'
    }
}

if ($BroadcastSource) {
    # The approved voice pack stays on the build machine, outside Git.
    $pack = @{
        'lm/browser_poc_manifest.json'                       = '097d80e993dc29f0bae427590b4f77084a161cb578b50d82c29f455d5faa9eee'
        'lm/tts_browser_onnx_meta.json'                       = '3edf25232dcd0af3d061c837e9a968a39e2f8592e06777d740503c4f2244f95c'
        'lm/tokenizer.onnx'                                   = 'ceb5b5991cc6ba074c2884a32664ddaec66de5e7c72f7b74343d6bd83c059f6d'
        'lm/moss_tts_prefill.onnx'                            = '25409338ab270f9cad4faea12e5ae9ee29dbc3cacb8ee9eafbc16fc85706b095'
        'lm/moss_tts_decode_step.onnx'                        = '854d6d905f230e58b03fd12ca9a930d852086db231d10c00d21fb66f8a567aee'
        'lm/moss_tts_local_fixed_sampled_frame.onnx'           = '3baf66aac8bb52e4d7adc9204299a4947788b100efdd07af198f117a59f120a6'
        'lm/moss_tts_global_shared_int8.data'                  = 'b127207a2274826b113fd3f2c4917ef366535c3324dd0f8fe95d6355626a85bb'
        'lm/moss_tts_local_fixed_sampled_frame_int8.data'      = 'dbbdde4c10bf59e7d63087c6688ca18bad46088d5e4c8c0b7d9e858304d44aa4'
        'codec/codec_browser_onnx_meta.json'                   = '3e291c883bb7d11ff2fe8e964e3e495519760358859f35c951254c7741592731'
        'codec/moss_audio_tokenizer_decode_step.onnx'          = '9527c86a29e1837edec1f74db57d5eeaadb3a715af3382703566460afed25855'
        'codec/moss_audio_tokenizer_decode_shared.data'        = 'e69d52e0f4e84ca27850557ee54face46632d3a5a16c89bd246c7c408466dcad'
        'qwen-reference-rvq.json'                             = 'c430d28ec05eaff6d24798a27ccb5933b3c7163caafbf470a0431b36272fdcd9'
    }
    foreach ($component in $pack.Keys) {
        $source = Join-Path $BroadcastSource $component
        if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or
            (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $pack[$component]) {
            throw "Broadcast voice component is missing or differs from the approved pack: $source"
        }
    }
    $broadcastVoice = Join-Path $voices 'broadcast-moss-v1'
    New-Item -ItemType Directory -Path $broadcastVoice -Force | Out-Null
    foreach ($component in $pack.Keys) {
        Copy-Item -LiteralPath (Join-Path $BroadcastSource $component) -Destination $broadcastVoice
    }
    $oldDecoder = Join-Path $broadcastVoice 'moss_audio_tokenizer_decode_full.onnx'
    if (Test-Path -LiteralPath $oldDecoder -PathType Leaf) {
        Remove-Item -LiteralPath $oldDecoder
    }
    @'
The original broadcast voice uses a synthetic Qwen3-TTS VoiceDesign reference.
Qwen3-TTS (Apache-2.0): https://github.com/QwenLM/Qwen3-TTS
MOSS-TTS-Nano and audio tokenizer (Apache-2.0): https://github.com/OpenMOSS/MOSS-TTS-Nano
INT8 ONNX export (Apache-2.0): https://huggingface.co/REALBITS/MOSS-TTS-Nano-100M-ONNX-int8
ONNX Runtime Extensions (MIT): https://github.com/microsoft/onnxruntime-extensions
'@ | Set-Content -LiteralPath (Join-Path $broadcastVoice 'MODEL_CARD') -Encoding UTF8
}

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
    $members = @('model.int8.onnx', 'voices.bin', 'tokens.txt', 'lexicon-us-en.txt', 'lexicon-zh.txt', 'phone-zh.fst', 'date-zh.fst', 'number-zh.fst', 'LICENSE') |
        ForEach-Object { "$modelDir/$_" }
    & $tar -xjf $modelName -C 'library-assets/tts' @members
    if ($LASTEXITCODE -ne 0) { throw 'Offline voice extraction failed.' }
} finally {
    Pop-Location
    $env:Path = $oldPath
}

@'
Offline narration uses Sherpa-ONNX v2.0.1 (Apache License 2.0).
https://github.com/k2-fsa/sherpa-onnx/tree/v2.0.1
ONNX Runtime (MIT License): https://github.com/microsoft/onnxruntime

The Mandarin voices use hexgrad/Kokoro-82M-v1.1-zh (Apache License 2.0).
https://huggingface.co/hexgrad/Kokoro-82M-v1.1-zh
Chinese voice data attribution: LongMaoData.

The lightweight Mandarin voice uses the Nov 2026 Piper Chaowen model,
adapted to Sherpa and dynamically quantized for mobile use.
https://huggingface.co/rhasspy/piper-voices/tree/cf910fb59f1d79ab3b625a63993a108751c6c25d/zh/zh_CN/chaowen/medium
Chaowen recordings: OHF Voice datasets (CC0).
Base voice: Hi-Fi TTS reader 92, Cori Samuel (CC BY 4.0).
https://www.openslr.org/109/ — https://creativecommons.org/licenses/by/4.0/
Model details and attribution are retained in tts/chaowen-fast/MODEL_CARD.
'@ | Set-Content -LiteralPath (Join-Path $voices 'offline-voice-attribution.txt') -Encoding UTF8
