import os, sys
import numpy as np
from kokoro_onnx import Kokoro
import logging
logging.basicConfig(level=logging.DEBUG)
# Set espeak-ng data path explicitly
os.environ["ESPEAK_DATA_PATH"] = "/opt/homebrew/Cellar/espeak-ng/1.52.0/share/espeak-ng-data"

def resource_path(filename):
    return os.path.join(os.path.dirname(__file__), filename)
    
def trace(msg):
    print(f"[Python TRACE] {msg}", file=sys.stderr)

trace("Script started.")
text = " ".join(sys.argv[1:-2])
voice = sys.argv[-2]
lang = sys.argv[-1]
trace(f"Arguments parsed: text='{text}', voice='{voice}', lang='{lang}'")

model_path = "kokoro-v1.0.onnx"
voices_path = "voices-v1.0.bin"

kokoro = Kokoro(model_path, voices_path)
trace("Kokoro initialized successfully.")
samples, sr = kokoro.create(text, voice=voice, lang=lang)
trace("Audio created successfully.")

samples = np.clip(samples, -1.0, 1.0)
samples = (samples * 32767).astype(np.int16)
sys.stdout.buffer.write(samples.tobytes())
trace("Wrote samples to stdout. Exiting normally.")
