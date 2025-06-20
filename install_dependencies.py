import subprocess
import sys

REQUIRED_PACKAGES = [
    "onnxruntime",
    "numpy",
    "phonemizer",
    "colorlog",
    "espeakng"
]

def install_packages():
    for package in REQUIRED_PACKAGES:
        try:
            __import__(package)
        except ImportError:
            subprocess.check_call([sys.executable, "-m", "pip", "install", "--user", package])

if __name__ == "__main__":
    install_packages()