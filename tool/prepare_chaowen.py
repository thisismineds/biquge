"""Prepare the pinned Piper Chaowen model for Sherpa's Chinese frontend."""

import json
import sys
from pathlib import Path
from tempfile import TemporaryDirectory

import onnx
from onnxruntime.quantization import QuantType, quantize_dynamic

source, target = map(Path, sys.argv[1:3])
filename = source / "zh_CN-chaowen-medium.onnx"
config = json.loads(filename.with_suffix(".onnx.json").read_text(encoding="utf-8"))
if (config["phoneme_type"], config["num_speakers"], config["audio"]["sample_rate"]) != (
    "pinyin", 1, 22050,
):
    raise ValueError("Unexpected Chinese voice configuration")

dictionary = {}
for symbol, ids in config["phoneme_id_map"].items():
    if symbol == "\n":
        continue
    if len(ids) != 1 or symbol in dictionary:
        raise ValueError("Unexpected Chinese phoneme mapping")
    dictionary[symbol] = ids[0]

model = onnx.load(filename)
# Piper writes cmn in its config. Sherpa's Mandarin frontend uses zh + has_g2pw.
onnx.helper.set_model_props(model, {
    "model_type": "vits", "comment": "piper", "language": "Chinese",
    "voice": "zh", "version": "1", "has_espeak": "0", "has_g2pw": "1",
    "n_speakers": "1", "sample_rate": "22050",
})
target.mkdir(parents=True, exist_ok=True)
with TemporaryDirectory(dir=source) as temp:
    temp = Path(temp)
    intermediate = temp / "full.onnx"
    quantized = temp / "quantized.onnx"
    onnx.save(model, intermediate)
    quantize_dynamic(intermediate, quantized, weight_type=QuantType.QUInt8)
    tokens = temp / "tokens.txt"
    tokens.write_text(
        "".join(f"{symbol} {index}\n" for symbol, index in dictionary.items()),
        encoding="utf-8", newline="\n",
    )
    tokens.replace(target / "tokens.txt")
    quantized.replace(target / "model.onnx")
